# GPU Optimization Audit

审计时间：2026-06-04 11:02 CST

范围：当前工作区的 `scripts/`、`shaders/`、`docs/`、`tools/`。本文件只评估运行时和高频路径中还值得继续 GPU 优化的内容；测试脚本、debug overlay、资源导入和 authoring 工具只在它们影响主流程时纳入。

## 结论概览

项目已经不是 CPU-first 原型。当前 `shaders/` 下有 84 个 `.glsl` compute shader，核心路径已经包含 GPU probe prefilter、TargetSV read buffer、VoxelPlacementGenerator score/stamp、accepted placement 写入 GPUAutoObjectRuntime、SceneVoxel source resolve / commit、SceneVoxelTile resident buffers，以及 dirty delta -> object-ref update pass。

还值得继续优化的重点不再是“把算法搬到 GPU”，而是减少主流程中的 CPU readback、CPU dictionary bridge 和 per-asset/pivot 之间的 CPU 状态链。当前脚本里仍有约 145 处 `buffer_get_data` / `texture_get_data` / `get_image` / `get_data` 类读回或 CPU 数据抽取，其中大量属于 debug/UI，但下面这些仍处在运行时链路上。

## 已经 GPU 化或不应重复做的部分

| 区域 | 当前状态 | 证据 |
| --- | --- | --- |
| AutoObject probe prefilter | 已是 GPU-only 主路径。`collect_sv_anchors`、`score_anchor_asset_probes`、`select_anchor_topk`、`reduce_anchor_topk_to_voxel_regions` 已存在；CPU fallback 不应恢复。 | `scripts/autoobject_probe_prefilter_gpu.gd`, `docs/placement/autoobject-probe-prefilter.md` |
| Candidate route handoff | 已有 resident route payload / SPA handoff / VPG binding。`use_gpu_candidate_route_pack` 当前默认可启用，SPA 在有 payload 时默认尝试 resident handoff。 | `scripts/autoobject_probe_prefilter_gpu.gd::_run_candidate_route_gpu_pack_pass`, `scripts/scene_placement_actor.gd::_should_use_resident_candidate_route_handoff`, `scripts/voxel_placement_generator.gd::_prepare_candidate_route_binding` |
| VPG physical score / stamp | `score_voxel_tile.glsl`、reduce、stamp 已在 GPU；目标不是重写 score，而是让输入/输出常驻 GPU。 | `scripts/voxel_placement_generator.gd::run_minimal`, `shaders/score_voxel_tile.glsl` |
| Accepted placement -> GPU runtime | 已有 `autoobject_apply_accepted_placements.glsl`，VPG 会通过 batched accepted-placement records 写入 `GPUAutoObjectRuntime`。 | `scripts/gpu_autoobject_runtime.gd::_try_apply_accepted_placement_record_shader`, `scripts/voxel_placement_generator.gd::_write_accepted_placements_to_gpu_runtime` |
| Dirty delta -> SceneVoxelTile object refs | 已有 `scene_voxel_tile_object_ref_update.glsl` 和 default resident path，失败时才回 CPU bridge。 | `scripts/gpu_autoobject_runtime.gd::flush_to_scene_voxel_committer`, `scripts/scene_voxel_committer.gd::try_apply_gpu_autoobject_object_ref_update_pass_from_buffer` |
| SceneVoxel source resolve / commit | source candidate 仲裁和 committed payload 合成已经有 GPU pass，且有 resident source stream / committed payload buffer 方向。 | `scripts/scene_voxel_committer.gd::_try_resolve_scene_voxel_source_candidates_gpu`, `_try_blend_scene_voxel_commit_payloads_gpu`, `_try_make_sv_scene_field_from_source_streams_gpu_result` |

## P0：最值得优先做

### 1. VPG 直接消费 resident `scene_field` / `collision_field`

当前 CPU 痕迹：

- `ScenePlacementActor.run_placement_pipeline()` 从 `sv["scene_field"]` / `sv["collision_field"]` 取 `PackedFloat32Array`，再传给 `VoxelPlacementGenerator.run_multi_asset()`。
- `VoxelPlacementGenerator.run_minimal()` 会 `_normalize_float_array()`，再 `storage_buffer_from_floats(scene_data)` / `storage_buffer_from_floats(collision_data)`。
- placement 后默认读回 `scene_buffer` / `collision_buffer`；compact state chain 虽能关闭 full-field readback，但仍通过 CPU `stamp_deltas` 更新 `current_scene` / `current_collision`。

建议目标：

- 由 `SceneVoxelCommitter` 暴露稳定的 resident field RID contract：scene/collision RID、voxel count、epoch、grid、lifetime、same RD。
- VPG 支持 `scene_field_buffer` / `collision_field_buffer` borrowed input，正常路径不上传 `PackedFloat32Array`。
- 多 asset 之间用 GPU resident intermediate field 或 compact delta apply pass 传递状态，CPU array 只作为 debug snapshot。

验收信号：

- 正常 `run_placement_pipeline()` 结果中 `scene_field_out_source` / `collision_field_out_source` 不再是 full storage-buffer readback。
- `read_full_field_outputs=false` 成为默认 runtime 路径，而不是只在 compact state chain 下局部启用。
- 测试应继续用非 headless Vulkan。

### 2. 多 asset / pivot 状态链留在 GPU

当前 CPU 痕迹：

- `VoxelPlacementGenerator.run_multi_asset()` 按 priority 顺序循环 asset，再循环 pivot variants，每次调用 `run_minimal()`。
- 每个 asset/pivot 之间通过 `current_scene` / `current_collision` CPU arrays 或 `_apply_stamp_deltas_to_cpu_state()` 传递状态。
- `results_to_world()`、`world_results`、`stamp_bounds` 都在 CPU 侧物化后再进入写回阶段。

建议目标：

- 引入 VPG frame-state buffer：scene/collision/current accepted placement/delta range 常驻同一个 RD。
- pivot variants 可以仍由 CPU 调度，但每个 pivot 输出 score/accepted range 到 GPU buffer，由 CPU 只读很小的 winner summary。
- asset 顺序仍可由 CPU 决定，但每个 asset 的 stamp 影响应在 GPU pass 中 apply 到 resident state。

验收信号：

- `cpu_state_chain.mode != "compact_stamp_deltas"` 成为正常路径。
- `asset_results[*].stamp_deltas` 和 `scene_field_out` 只在 debug/readback option 下填充。

### 3. Accepted placement -> SceneVoxel source write buffer

当前 CPU 痕迹：

- VPG 写 GPU runtime 已经有 shader，但写 `SceneVoxelCommitter` 仍走 `_write_accepted_placements_to_scene_voxel_committer()`。
- 该路径构造 CPU `instance_stamp_write_spec` / source dictionaries，再调用 `apply_instance_stamp_write_specs()` 或 `apply_voxel_write_specs()`。
- `SceneVoxelCommitter._apply_voxel_write_spec_batch()` 仍报告 `source_write_handoff_mode="cpu_batch_isws_pending_source_candidate_bridge"`。

建议目标：

- 让 VPG 的 accepted placement buffer 直接生成 resident source candidate records/ranges/payloads。
- `SceneVoxelCommitter` 提供 `apply_accepted_placement_source_buffer()` 这类 RID entry point，消费 buffer 后进入现有 `resolve_scene_voxel_sources.glsl` / commit pipeline。
- CPU dictionaries 保留为 authoring/debug/compat，不作为 pipeline 成功的必要中间态。

验收信号：

- `resident_source_write_buffer=true` 来自 placement accepted buffer，而不是只来自 source candidate staging 后的 committer 内部状态。
- `source_write_handoff_mode` 从 CPU batch bridge 变成 resident source-write buffer handoff。

### 4. Dirty SceneVoxelTile worklist 全程 resident

当前 CPU 痕迹：

- `scene_voxel_tile_object_ref_update.glsl` 已能输出 object refs、stats、dirty tile flags/worklist。
- `SceneVoxelCommitter._update_gpu_autoobject_object_refs_from_dirty_delta_buffer()` 随后读回 stats、dirty worklist、dirty flags，用于 result diagnostics。
- `GPUAutoObjectRuntime.flush_to_scene_voxel_committer()` resident pass 失败时还会读回 dirty deltas 再走 CPU bridge。

建议目标：

- 将 dirty tile flags/worklist 作为 persistent/pass-owned RID 暴露给 prefilter、summary reduce、VPG route scope，而不是每次读回成 CPU ids。
- resident pass 成功后，后续 pipeline 直接使用 dirty worklist RID；CPU dirty tile snapshot 只做 debug/readback。
- 对 fallback 路径保留显式 blocked reason，但正常路径不再依赖 `gpu_dirty_delta_buffer` readback。

验收信号：

- `transient_dirty_scene_voxel_tile_cpu_metadata_bridge` 保持 `none`，同时下游真正消费 dirty worklist RID。
- prefilter/placement dirty scope 可从 resident worklist 来，而不是由 caller 传 `dirty_tile_ids` CPU array。

### 5. SceneVoxel resident field 发布不再立即读回

当前 CPU 痕迹：

- `_try_make_sv_scene_field_from_source_streams_gpu_result()` 创建 `blend_scene_field_out` 后立刻 `buffer_get_data()` 并解码成 `PackedFloat32Array`。
- `_rebuild_sv()` 将 `scene_field` / `collision_field` CPU arrays 写入 `_sv` snapshot，然后 `ensure_scene_voxel_tile_buffers_uploaded()` 再把这些 arrays pack 回 GPU buffers。
- 即使内部已有 committed payload buffers / resident source streams，public SV 仍以 CPU snapshot 为主。

建议目标：

- `_rebuild_sv()` 以 resident field buffer + metadata 为 primary published state；`scene_field` / `collision_field` arrays 改为 lazy debug projection。
- SceneVoxelTile summary reduce 直接消费 resident field buffers，避免 field buffer -> CPU -> buffer 的往返。
- collision field 与 scene field 一样需要 resident buffer contract，不只保留 summary buffer。

验收信号：

- `_sv["scene_field_runtime_read_source"]` / `_sv["collision_field_runtime_read_source"]` 均指向 resident buffer。
- `ensure_scene_voxel_tile_buffers_uploaded()` 能复用上游 resident field RID 或执行 GPU copy/update，而不是重建 upload bytes。

### 6. SceneVoxelTile object refs 驱动同类型邻域排斥

当前 CPU/GPU 痕迹：

- `score_voxel_tile.glsl::runtime_same_profile_min_spacing_hit()` 当前扫描 `runtime_contract_object_capacity()` 范围内所有 live runtime objects。
- `scene_voxel_tile_object_ref_exclusion` 默认仍为 false，测试也要求当前 same-profile spacing 不冒充 SceneVoxelTile object-ref exclusion。

建议目标：

- placement/exclusion shader 读取 SceneVoxelTile fixed object refs / dirty object refs，再按候选 voxel 周边 tile 或 voxel ref 范围查询 object ids。
- 仅对邻域 object ids 读取 runtime bounds/profile/min_spacing，替代全 runtime scan。
- 保留 full runtime scan 作为小规模/debug fallback，不能成为百万级正常路径。

验收信号：

- `same_type_exclusion_object_ref_read_source="scene_voxel_tile_object_refs"`。
- `scene_voxel_tile_object_ref_exclusion=true`，并有同 profile / same type 的 GPU rejection 统计。

## P1：中优先级优化

### 7. TargetSV_B read buffers 的零读回 handoff

当前 CPU 痕迹：

- `ScenePlacementActor.prepare_target_read_buffers_from_common_gpu()` 即使 `use_resident_target_read_buffer_handoff=true`，也会固定 `buffer_get_data()` 读回 color/occupancy bytes。
- SPA 随后又把 bytes 和 resident RIDs 同时传给 prefilter / VPG。

建议目标：

- resident handoff 成功时默认不读 bytes；只返回 RIDs、byte count、format、lifetime。
- prefilter / VPG 已能借用 target read buffer RID，bytes 仅 debug option 或 tests 使用。

### 8. Candidate route pack 并行化与文档契约清理

当前状态：

- route 已有 resident handoff 和 VPG sparse adapter，不再是纯 CPU 字典路径。
- `pack_candidate_route_records_from_votes.glsl` 当前 `local_size_x=1`，单 invocation 串行遍历 `asset_count * tile_count` 和 radius expansion。
- 文档中仍有“opt-in producer GPU pack / 默认 CPU pack”的描述，而代码侧 `use_gpu_candidate_route_pack` 默认 true，并且 SPA 会默认尝试 resident handoff。

建议目标：

- 将 route pack 拆成 parallel mark / prefix or compact / range finalize，避免单线程 shader 成为大 tile/asset 的瓶颈。
- 明确 CPU score-sorted order 与 GPU tile-id ascending order 的影响。如果 placement capacity 或 tie 行为依赖 order，需要在 GPU 侧恢复稳定排序或把差异写成正式 contract。
- 更新 `docs/placement/autoobject-probe-prefilter.md` 与当前默认行为一致。

### 9. Accepted placement shader 后的确认读回最小化

当前状态：

- `autoobject_apply_accepted_placements.glsl` 已写 object buffers 和 dirty deltas。
- 但 runtime 仍读 stats 和 dirty count 来确认 `accepted_placement_record_shader_consumed`。

建议目标：

- 对 release/runtime path 提供 no-readback mode：只保留 fence/barrier + GPU-side status buffer，下一阶段直接消费 dirty delta buffer。
- stats readback 仅 debug/test 开启。

### 10. Source candidate resolve / committed payload debug 投影延迟化

当前状态：

- `SceneVoxelCommitter` 已有 resident committed payload buffer、key coord buffer、public debug cache hydration。
- 多个路径仍会 `buffer_get_data()` 读 payload/key-coord 或 dense field，用于 public/debug map。

建议目标：

- 明确 `get_scene_voxels()` / query/debug APIs 是 lazy debug readback；runtime pipeline 不调用这些 hydration。
- 把 public projection summary 与 runtime read source 分开，避免上层误把 debug map 当 pipeline input。

## P2：低优先级或仅在规模扩大时做

| 内容 | 建议 |
| --- | --- |
| Footprint bake helpers | `bake_box_footprint_gpu()` / cylinder / rotate 已有 GPU helper，但很多函数返回 CPU-decoded footprint。只有当 asset/pivot 数量很大时，才需要把 footprint 常驻 profile buffer 并让 VPG 直接读取。 |
| Runtime visualization / nodes | `instantiate_placement(s)` 和 `AutoObject` 节点创建主要是测试/debug/低数量展示。百万级可视化应走 MultiMesh 或 renderer-side instance buffer，不要恢复 per-object Node。 |
| `main.gd` overlay / mask / preview readback | 大量 `texture_get_data()` / `get_image()` 是 debug UI、截图、mask 预览或保存，不是第一批 runtime 优化目标。 |
| Asset import / scaffold / descriptor normalization | `auto_asset_factory.gd`、`.tres`、JSON、Inspector 字段继续 CPU 更合理；GPU 只消费注册后的 profile buffers。 |

## 建议实施顺序

1. 定义 `SceneVoxelCommitter` -> VPG resident field RID contract，并让 `run_minimal()` 可借用 scene/collision buffers。
2. 把 VPG 多 asset state chain 从 CPU arrays / stamp delta CPU apply 改成 GPU resident intermediate buffers。
3. 打通 accepted placement -> SceneVoxel resident source-write buffer，减少 ISWS dictionary bridge。
4. 让 dirty-delta object-ref pass 的 dirty worklist 成为下游实际输入，而不是只作为 diagnostics readback。
5. 用 SceneVoxelTile object refs 替代 `score_voxel_tile.glsl` 的 full runtime object scan，完成百万级 same-type exclusion。
6. 再做 TargetSV_B zero-readback handoff、route pack 并行化、stats/debug readback opt-in。

## 验证注意事项

- 所有涉及 RenderingDevice、compute shader、storage buffer、GPU readback 的验证都必须使用 Vulkan，不能加 `--headless`。
- 缺 RenderingDevice 时应 skip 或 fail GPU 测试，不能新增 CPU fallback 并报告 GPU path passing。
- 推荐从这些非 headless Vulkan脚本开始分阶段验证：
  - `tools/test_scene_placement_target_read_buffers_gpu.gd`
  - `tools/test_autoobject_probe_prefilter.gd`
  - `tools/test_voxel_candidate_routing_contract.gd`
  - `tools/test_voxel_placement_generator.gd`
  - `tools/test_voxel_multi_asset.gd`
  - `tools/test_gpu_autoobject_runtime_bridge.gd`
  - `tools/test_voxel_dirty_tile_upload.gd`
