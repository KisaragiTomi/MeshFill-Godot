# stamp 逻辑重复精简方案

本方案来自 2026-07-13 的 stamp 逻辑重复审计（6 范围并行细读 → 按组对抗核实 → 补盲，19 条候选、0 条纯误报），已对照 2026-07-10 冗余审计冻结名单去重。产出：**15 条确认值得做**（约 330 行 GDScript + 1 个死 shader 文件）、2 条 real-but-keep、2 条被并行迁移自然解决。本文档是执行工单：按批次划分为多个 subagent 任务，每个 subagent 独占自己的文件集，可在批次内并行。

执行纪律总则：

- 单任务 subagent 总数 ≤ 32（本方案共 7 个执行代理 + 2 个门禁代理，远低于上限）。
- 每个 subagent 一份外科式提交：只含自己任务的 diff，不混入其他改动。
- 不使用 worktree 隔离代理；靠文件所有权划分避免冲突，同文件任务串行。
- 所有行号引用以函数名锚点为准——工作区正被并行迁移改写，行号会漂移。

## 前置状态：并行迁移已落盘（工作区未提交）

> **状态更新（2026-07-13）**：混合资产 stamp 迁移已落盘到本工作区（尚未提交），阶段 1–4 完成记录见 `probe粗筛与细筛冗余分析.md` 第 10.6 节。旧 shader `score_voxel_tile.glsl`、`stamp_voxel_field.glsl`、`reduce_voxel_tiles.glsl` 等已删除，新 shader `stamp_asset_voxels.glsl`、`score_anchor_asset_residual.glsl`、`reduce_anchor_candidates.glsl`、`fine_score_dispatch_finalize.glsl` 已就位，`voxel_placement_generator.gd` 已核心重写。因此下表“迁移 WIP / 等干净”门禁前提已解除：批次 B、C 的目标文件现均为迁移后形态、可启动，但每项前提须按迁移后代码重新核实（见各批次状态块）。

混合资产 stamp 迁移曾是另一会话的未提交 WIP，现已落盘：`stamp_voxel_field.glsl`、`score_voxel_tile.glsl` 已删除，替代者 `stamp_asset_voxels.glsl`、`score_anchor_asset_residual.glsl` 已就位，`voxel_placement_generator.gd` 由 2688 行重写为约 1567 行（stamp 加载点改为 `stamp_asset_voxels.glsl`，并新增 anchor fine pipeline）。

**每个 subagent 启动时仍须先 `git status` 复核自己的文件集**；下表状态列为迁移落盘前的快照，仅供追溯，最新可执行状态以各批次状态块为准。

| 文件 | 2026-07-13 状态 | 归属批次 |
| --- | --- | --- |
| `scripts/scene_voxel_field_builder.gd` | 干净 | A1 |
| `shaders/stamp_r32_disc.glsl` (+`.import`) | 干净 | A1 |
| `shaders/stamp_collect_voxel_disc_3d.glsl` | 干净 | A1（仅注释） |
| `scripts/scene_voxel_committer.gd` | 干净 | A2（B1 二次触碰） |
| `scripts/auto_object.gd` | 干净 | A3 |
| `scripts/utils/sv_field_scatter.gd` | 干净 | B1 |
| `scripts/scene_placement_actor.gd` | M（迁移 WIP） | B1，等干净 |
| `scripts/gpu_autoobject_runtime.gd` | M（迁移 WIP） | B2，等干净 |
| `scripts/voxel_placement_generator.gd` | M（迁移 WIP） | B3，等干净 |
| `scripts/utils/buffer_utils.gd` | MM（迁移 WIP） | B3，等干净 |
| `scripts/utils/voxel_fixtures.gd` | M（迁移 WIP） | B4，等干净 |

批次 A 三个代理的文件集互不相交，可立即并行执行；批次 B、C 原须等迁移提交后启动，现迁移已落盘、门禁解除（见上方状态更新与各批次状态块）。

## 批次 A：干净文件，可立即执行

> **状态：已执行完毕（2026-07-13）**。三份外科式提交 `5159fc9`(A1) / `29206c6`(A2) / `015cf17`(A3)，净 −94 行 + 删除死 shader 对；G1 门禁 PASS（fresh `-e` 零脚本错误、桥应答、`run_stamp_only_commit_check` → ok，scattered=5 field_max=0.70 brush=true feedback_overlap=1）。偏差记录：`volume_xz_resolution` 未入 `_collision_record_meta`（cell 契约面不含该键），由 `_make_source_collision` 调用方补。

| 代理 | 任务 | 文件 | 预计省行 |
| --- | --- | --- | --- |
| A1 | 死 shader 删除 + disc 分支收敛 + 归一化去重 + collision 元数据提取 | `scene_voxel_field_builder.gd`、`stamp_r32_disc.glsl` | ~70 |
| A2 | committer 死 API + 三处重复归一化 | `scene_voxel_committer.gd` | ~22 |
| A3 | auto_object write-spec 家族死码 | `auto_object.gd` | ~18 |

### A1 — field_builder 与 disc shader（独占 `scene_voxel_field_builder.gd`）

四项子任务，一份提交。⚠ 删 shader 须在编辑器关闭时进行（先按 CLAUDE.md 的按命令行过滤方式关闭本项目编辑器）。

1. **删除不可达孪生 shader `stamp_r32_disc.glsl`**（+ 同名 `.import`）。证据链（已核实）：唯一生产调用链 `_stamp_occupancy_channel → _stamp_scalar_image_disc → _stamp_scalar_image_disc_gpu` 恒传 occupancy 图；occupancy 全仓仅两处赋值（committer `build_voxel_volume` 以 `FORMAT_RGBAH` 创建、builder 盖章回写），`use_r32` 恒为 false。配套改动：
   - 删 `_shader_stamp_r32_disc`/`_pipeline_stamp_r32_disc` 成员与 shader spec 表中 `"stamp_r32_disc"` 条目。
   - `_stamp_scalar_image_disc_gpu` 内 5 处 `use_r32` 三元选择收敛为 RGBA 常量（`_shader_stamp_rgba_channel_disc`、`DATA_FORMAT_R16G16B16A16_SFLOAT`、`FORMAT_RGBAH`）。
   - 函数入口加绊线：`if img.get_format() == Image.FORMAT_RF: push_error(...); return null`——显式收窄契约，防未来把 R32 地形碰撞场误接进来。
   - 更新 `stamp_collect_voxel_disc_3d.glsl` 第 9、68 行注释里对 `stamp_r32_disc.glsl` 的引用，改指 `stamp_rgba_channel_disc.glsl`。
   - 禁区：`sample_r32_pixel`/`create_r32_image` 仍活跃，勿动。注意 `_init_collision_gpu` 的 `_gpu_ready` 由 5 shader 门槛降为 4，属预期。
2. **`_normalize_shared_field_layers` 信任 callee**：`collision_from_fields → VoxelGeneral.normalize_collision_samples` 已完成深拷贝、非点过滤、写 `voxel` 键、clamp `collision_strength`（默认 1.0）——包装层重做的四件事全删：去掉 `duplicate(true)`、`is_point_collision_sample` 再过滤、`collision_local_voxel` 重算（直接读 `collision_entry["voxel"]`）、strength 再 clamp。保留：`enabled` 过滤与 builder 特有的富化（`local_pos` 别名、`radius_px`、`effective_radius`、`slice_index` 缺省、`base_pixel`）——这些 callee 不做。
3. **复数/单数盖章去掉双重归一化**：`_stamp_shared_field_layers` 删除批量预归一化，直接遍历原始 `field_layers`，让 `_stamp_shared_field_layer` 内部那次归一化成为唯一一遍（`normalize_collision_samples` 逐条无跨条状态，批量=逐条已证等价）。⚠ 改直接遍历后必须补 `is Dictionary` 守卫（单数形参是 typed Dictionary，原先由 collision_from_fields 挡掉非字典条目）。⚠ **勿删** `_make_source_collision` 内的那次归一化——committer 在盖章零产出时回退喂原始层，该路径仍需要它。
4. **提取 `_collision_record_meta` 帮助函数**：`_make_source_collision` 与 `_stamp_shared_field_layer` 重复推导约 10 个键（`collision_strength`、`base_pixel`、`voxel_xz`、`volume_xz_resolution`、`radius_px`、`collision_shape`、`collision_radius`、`effective_radius`、`source_voxel_type`、`record_id`、`instance_id`——含两处逐字相同的 4 级 `instance_id` 回退链）。两个公开函数的返回键集合不变。⚠ 两处语义差异必须参数化、不能硬统一：
   - `source_voxel_type`/`record_id` 回退序不同（`_make_source_collision` 只取 rec；单数版 layer 优先、rec 回退）→ 由调用方传显式值。
   - `_volume` 为空时 `voxel_xz` 处理不同（单数版跳过转换、`_make_source_collision` 恒走 `_volume_px_from_base`）→ `voxel_px` 由调用方预计算后传入。

验证：`--check-only` 过 `scene_voxel_field_builder.gd` + `scene_voxel_committer.gd`（消费方）；G1 门禁统一做 `-e` 验证。

### A2 — committer 内部清理（独占 `scene_voxel_committer.gd`）

1. **删死 API**：单数 `get_instance_stamp_write_spec(mesh_id)`（含两行文档注释共 8 行）全仓零调用。已核实 `autoobject_probe_prefilter_gpu.gd` 里的零参 `call()` 目标是 AutoObject 的同名零参方法，删除后该处 `has_method` 守卫反而更干净。复数版 `get_instance_stamp_write_specs` 有活调用方，保留。`_instance_stamp_write_spec_index` 另有活跃使用，不受影响。
2. **删 `_stamp_volume_slices` 逐体素循环里的 `apply_to_scene_voxel` 自应用**（一行）：其全部效果被下一行 `prepare_source_record`（内部 `apply_to_record → normalize_shared_fields`）完全覆盖，已逐键验证等价；每体素省一次全字典 `duplicate(true)`。二档优化（把 `prepare_source_record` 提升出循环）**本批不做**——tick 传递路径要单独审，另开 diff。
3. **`build_voxel_volume` 直读 descriptor 字段**：`collect_descriptors → descriptor_from_entry` 已保证六键齐全、`subdivisions>=1`、`y_max>y_min`、complexity 已 clamp 且 `color.a==complexity`；消费侧三段重复 coercion 删除，归一化 SSOT 留在 `scene_voxel_volume_channels.descriptor_from_entry`。
4. **channel→slice_indices 扫描循环收敛**：`_update_instance_stamp_write_specs_for_volume` 的内联副本改为复用 `_slice_indices_for_channel_record`。⚠ 必须先 `record.erase("slice_indices")` 再调用（或给 helper 加 `force_recompute` 参数，更防误用）——直接复用会命中已有值分支返回换体积前的陈旧索引。

验证：`--check-only`；G1 门禁 `-e` + 桥调 `run_stamp_only_commit_check`（第 2 项碰盖章热路径）。

### A3 — auto_object write-spec 家族死码（独占 `auto_object.gd`）

1. **删 `instance_stamp_write_spec_from_config`**：全仓零调用（含字符串派发/桥 JS 检查过）。它与 `make_instance_stamp_write_spec` 不是重复（提取已有 record vs 构造新 record），不可合——但它本身已死。
2. **顺带内联 `instance_stamp_write_spec_meta_keys`**：删掉 1 后仅剩 `_get_instance_stamp_write_spec_metadata` 一个调用方，把 `[INSTANCE_STAMP_WRITE_SPEC_META_KEY, VOXEL_WRITE_SPEC_META_KEY]` 内联进去。两个常量本身另有活跃使用，保留。
3. **内联 `get_instance_stamp_write_spec_extra_fields`**：零覆写（项目已无任何 AutoObject 子类，grep `extends AutoObject` 零命中）、单调用方的空转 hook。在 `make_instance_stamp_write_spec` 内联：

```gdscript
var fields := extra_fields.duplicate(true)
if not fields.has("mesh_index"): fields["mesh_index"] = mesh_index
```

验证：`--check-only`；G1 门禁统一 `-e`。

### G1 — 批次 A 门禁（串行，在 A1–A3 提交合入后）

按 CLAUDE.md 单实例纪律：按命令行过滤关闭本项目现有编辑器 → 删陈旧 lock → fresh `-e --rendering-driver vulkan` 启动 → 控制台零脚本错误 + 桥（`127.0.0.1:6800`）应答 ping → 桥调 `run_stamp_only_commit_check`（覆盖 A1/A2 触碰的盖章提交链）。失败则回退对应代理的提交并上报，不带病进入批次 B。

## 批次 B：迁移已落盘，可执行（前提须逐项复核）

> **状态：B1 的 committer 半边（B1a）已执行（2026-07-13，提交 `e735b55`）**：`SvFieldScatter` 新增 `SCATTER_PUSH`（push 布局单一 SSOT）与 `dispatch_scatter(host,...)`，committer `_flush_pending_sv_field_records` 已迁移（失败 reason 逐字不变，前置检查与 pending 清空留调用方）；门禁 PASS（fresh `-e` 零错误 + `run_stamp_only_commit_check` 结果与改前逐字一致）。**剩余 B1b（SPA 侧迁移到同一 helper，调用形如 `SvFieldScatter.dispatch_scatter(self, _brush_sv_complexity_buffer, _brush_sv_collision_buffer, deduped, grid.x, grid.y, 0, "brush_sv_scatter", "spa_brush_sv_scatter")`，随后删 `BRUSH_SV_SCATTER_PUSH`）与 B2/B3/B4 原等迁移提交。**
>
> **迁移已落盘后复核（2026-07-13）**：门禁前提解除，逐项现状：
> - **B1b**：仍有效待做——`BRUSH_SV_SCATTER_PUSH`、`dispatch_scatter` 仍在 `scene_placement_actor.gd`。
> - **B2**：仍有效待做——两入口 `spawn_batch_from_accepted_placement_records`、`spawn_batch_from_accepted_placement_gpu_buffers` 及其四道容量守卫、块分配循环、`resident_gpu_allocator_writeback_blocked_reason` 镜像键均在迁移后存活；提取目标（`_spawn_batch_capacity_reason` / `_allocate_id_block`）未落地。
> - **B3 任务 1**：仍有效待做——`buffer_utils.gd` 尚无 `decode_vec4` / `decoded_record_count`，VPG `_decode_records` / `_decode_stamp_deltas` / `_decode_stamp_bounds` 仍在。
> - **B3 任务 2**：前提已变——迁移删除整条 Candidate route，原“6 个 candidate-route 转发器”半边随之消失；state-chain 半边已抽到新脚本 `voxel_placement_state_chain.gd`。执行前须对迁移后 VPG 重新 grep 转发器清单。
> - **B4**：目标函数 `make_scene_voxel_stamp_record` 仍在，但迁移改用 `AssetVoxelRecord` 走 `stamp_asset_voxels.glsl`，ISWS 生产组装器路径可能已部分被取代；改写前须确认 `AutoObject.make_profile_instance_stamp_write_spec` 等生产入口在迁移后是否仍是 canonical。
>
> **状态：B1b / B2 / B3 / B4 已全部执行（2026-07-13 晚，工作区未提交——与迁移 WIP 同树，无法外科式提交，提交策略待定）。G2 门禁 PASS。**
> - **B1b**：SPA 笔刷散射改调 `SvFieldScatter.dispatch_scatter(self, ..., deduped, grid.x, grid.y, 0, "brush_sv_scatter", "spa_brush_sv_scatter")`；删 `BRUSH_SV_SCATTER_PUSH` 与死别名 `SV_FIELD_SCATTER_SHADER`。偏差：原合并失败 reason `brush_sv_scatter_resources_not_ready` 按 helper 拆为 shader/record_buffer 两个更细 reason（方案已核准“无消费者可统一”）。
> - **B2**：落地 `_spawn_batch_capacity_reason` / `_allocate_id_block` / `_spawn_batch_records_failure`（4 份同形失败 dict 收敛）；两入口守卫优先级逐一保持（not_ready → empty → [invalid_rid] → 容量）。**附加项（post-dispatch 尾块）亲读后判否**：production 分支确实同形（约 5 行），但 debug 分支 stats_ok 条件数 2 vs 6、record 侧独有 dirty_count_mismatch 检查与 `failed_readback_source`/mirror 键、失败 reason 字符串全部不同——参数化需 3 个维度，净省行个位数，不做。
> - **B3**：`decode_vec4` / `decoded_record_count` 落地 buffer_utils；VPG 三解码器改用（双 mini+模除语义逐字保留，Vector4 透传对 float32 源数据 bit-exact）。转发层实测：6 个 state-chain 静态转发全删（内部 3 处调用点加 `VoxelPlacementStateChainScript.` 前缀；`_full_field_readback_contract`/`_compact_delta_state_chain_contract`/`_gpu_resident_state_chain_contract` 三个连内部调用都没有，其底层实现在 `voxel_placement_state_chain.gd` 中现为全仓零调用——迁移会话自查是否死码）；2 个 writeback 实例委托就地内联（内联处需显式 `: Dictionary` 标注，`_ensure_placement_writeback()` 无返回类型推断）。candidate-route 半边确认随迁移消失。`_target_read_buffer_pack`/`_target_read_buffer_summary` 按禁区保留。VPG 1567→1489 行（−78）。
> - **B4**：前置核查通过（`apply_instance_stamp_write_spec`→`prepare_source_record` 盖章链迁移后仍是 demo 手动盖章 canonical；AssetVoxelRecord 只接管 VPG 放置路径）。夹具改调生产组装器；一次性 headless 逐键 diff（新旧 record 各过 `prepare_source_record`）：差异恰为核准集（`type`→`object_type`、新增 rotation_mode/rotation_degrees/y_min=y_max=0.0、`auto_mix` 缺失——全仓无行为读方且 prepare 侧 `.get` 缺省 0.0），共享键零差异。
> - **G2 PASS（2026-07-13 21:4x，fresh `-e` vulkan）**：控制台零脚本错误；桥 ping ok；`run_stamp_only_commit_check` → ok，detail 与 B1a 门禁记录逐字一致（scattered=5 field_max=0.70 brush=true feedback_overlap=1）；`run_resident_placement_writeback_check` → ok（spawned=8 live=0->8 api=spawn_batch_from_accepted_placement_gpu_buffers shader_consumed=true stats_applied=8，恰覆盖 B2 gpu_buffers 入口 + debug stats 分支）；scene_voxel_tile demo 加载零错误（B4 等价性由上述逐键 diff 证成）。

启动前置：迁移已落盘到工作区（未提交），下表文件均为迁移后形态。四个代理文件集互不相交，可并行；B3 内部两项任务同文件，由同一代理串行完成。执行前按批次 B 状态块逐项复核前提（B3 任务 2、B4 前提已随迁移变动）。

| 代理 | 任务 | 文件 | 预计省行 |
| --- | --- | --- | --- |
| B1 | scatter dispatch 半边下沉 SSOT | `sv_field_scatter.gd`、`scene_voxel_committer.gd`、`scene_placement_actor.gd` | ~30 |
| B2 | runtime spawn-batch 守卫/ID 分配/收尾收敛 | `gpu_autoobject_runtime.gd` | ~40 |
| B3 | BufferUtils 解码收敛 + VPG 转发层删除 | `buffer_utils.gd`、`voxel_placement_generator.gd` | ~178 |
| B4 | 夹具改调生产组装器 | `voxel_fixtures.gd` | ~8 |

### B1 — scatter dispatch 下沉（`sv_field_scatter.gd` 为 SSOT 落点）

committer 提交路径与 SPA 笔刷路径对同一 `scatter_sv_field_records.glsl` 各写一份完整 dispatch 样板（load → pipeline → flatten 上传 → 3-binding uniform set → 4×int push → `dispatch_groups_1d(n, 64)` → sync → gc），返回 dict 形状逐字相同；`SV_FIELD_SCATTER_PUSH` 与 `BRUSH_SV_SCATTER_PUSH` 字节同构仅字段异名。两个独立审计方向各自发现、互相印证。

在 `sv_field_scatter.gd`（已持有 shader 路径/stride/展平契约）新增：

```gdscript
# host: 两个调用方均 extends GodotComputeShaderBase，所需方法全在基类
static func dispatch_scatter(
	host,                      # GodotComputeShaderBase 派生调用方
	complexity_rid: RID,       # binding0 目标场
	collision_rid: RID,        # binding1 目标场
	record_floats: PackedFloat32Array,  # flatten_record_slots 输出
	record_count: int,
	xz_res: int,               # push 字段名以 shader 侧为准
	total_slices: int,
	write_mode: int,           # committer=1(max-by-complexity) / SPA=0(后笔胜)
	label_prefix: String       # 失败 reason 前缀
) -> Dictionary                # {ok, reason, record_count, gpu_dispatched} 键集不变
```

push 布局常量收敛为 SvFieldScatter 内一份（字段名对齐 shader：`xz_res`/`total_slices`/`record_count`/`write_mode`），删除两端各自的声明。

⚠ 边界（已核实）：slot 填充/去重语义（committer 合并写 vs SPA 后笔胜）是 `sv_field_scatter.gd` 头注明确的有意保留，各留原地；committer 成功后清 `_pending_sv_field_records`、SPA 成功后置 `_brush_sv_has_content` + 标脏，留在调用方；SPA 侧 `grid.x→xz_res`、`grid.y→total_slices` 映射勿颠倒（shader 索引 `x + xz_res*(z + xz_res*slice)`）；失败 reason 字符串全项目无消费者，可统一，但日志文案会变。

验证：`--check-only` ×3；G2 门禁 `-e` 后桥上手动盖章 + 笔刷各走一次（`run_stamp_only_commit_check` 覆盖两条路径）。

### B2 — runtime spawn-batch 收敛（独占 `gpu_autoobject_runtime.gd`）

records 路径与 gpu_buffers 路径两条 spawn-batch 入口重复：四道容量守卫（reason 字符串逐字同）、逐个 `_allocate_id` 失败全退回的块分配循环、shader 失败回滚。提取：

```gdscript
func _spawn_batch_capacity_reason(record_count: int) -> String  # "" / "runtime_not_ready" / "capacity_full" / "dirty_delta_capacity_full"
func _allocate_id_block(record_count: int) -> Array[int]        # 失败内部回滚并返回空数组（capacity_full_mid_alloc）
```

⚠ 边界（已核实）：`empty_batch` 判定留调用方（records 路径是 ok:true 成功返回、gpu_buffers 路径还要写 `blocked_reason` 镜像）；`applied_on_gpu` 回滚门留调用方（dispatch 后退 ID 会腐蚀 free list）；gpu_buffers 路径失败时同步写 `resident_gpu_allocator_writeback_blocked_reason` 镜像键，留调用方；两入口返回 dict 契约面不同（大/小键集），只提取内部逻辑不合并报告组装。records 路径 4 份同形失败 dict 收敛为一个局部构造。

附加（先核实再做）：补盲代理报告两入口 post-dispatch 的 stats 校验/dirty-count 推进尾块也重复（约 70→35 行，medium 置信、未对抗核实）——代理执行前须自行亲读两段确认，属实则提取 `_finalize_accepted_placement_dispatch(stats_buffer, dirty_base, record_count, debug_read_stats, strict) -> Dictionary`，两端 stats_ok 严格度差异用 `strict` 参数化，失败键去向留调用方映射。

验证：`--check-only`；G2 门禁 `-e` + 桥调 `run_resident_placement_writeback_check`。

### B3 — BufferUtils 解码收敛 + VPG 转发层（同代理串行，独占 `voxel_placement_generator.gd`）

**任务 1：解码帮助函数下沉 `buffer_utils.gd`**（放 `decode_vec4_xyz`/`encode_vec4` 旁，同风格）：

```gdscript
static func decode_vec4(bytes: PackedByteArray, offset: int) -> Vector4       # 4×decode_float
static func decoded_record_count(bytes: PackedByteArray, expected_count: int, byte_stride: int) -> int
```

VPG 三个解码器（`_decode_records`/`_decode_stamp_deltas`/`_decode_stamp_bounds`）改用：记录数前导块 ×3 各收 1 行（⚠ 必须逐字保持双 `mini` 夹紧 + 模除截断到整条记录的语义）、Vector4 四浮点解包 ×6 各收 1 行。同形前导块在 `scene_voxel_tile_codec.gd`、`voxel_placement_output.gd`、`scene_voxel_tile_store.gd`、`auto_voxel_runtime_profile_container.gd`、`debug_buffer_set.gd`、`scene_placement_actor.gd` 另有约 6 处（未逐一核实）——**本批不动**，留作后续可选统一。

**任务 2：删 VPG 转发层**（迁移后 VPG 中锚点仍在：`_apply_stamp_deltas_to_cpu_state`、`_decode_stamp_deltas`、`_merge_gpu_autoobject_runtime_writeback_report` 均存活）：

- 12 个 static 单行转发器（state-chain 6 个 + candidate-route 6 个）零外部调用方 → 删除，约 19 处内部调用点机械加 `VoxelPlacementStateChainScript.` / `VoxelPlacementCandidateRouteScript.` 前缀（两个 preload 常量已存在）。
- 10 个 `_ensure_candidate_route()._x(...)` / `_ensure_placement_writeback()._x(...)` 实例委托零外部调用方 → 就地内联（惰性构造由调用点自行执行，语义不变）。
- ⚠ 禁区：`_target_read_buffer_pack` / `_target_read_buffer_summary` 有 `tools/test_target_sv_buffer_decode.gd` 调用方，**不可删**。
- ⚠ 执行时以迁移后的新版 VPG 为准重新 grep 每个转发器名（调用点集合可能已随迁移变化）；漏改由 parse gate 当场抓住（函数已删）。

验证：`--check-only`（`buffer_utils.gd` + VPG）；G2 门禁统一 `-e`。

### B4 — 夹具改调生产组装器（独占 `voxel_fixtures.gd`）

`make_scene_voxel_stamp_record` 手工重拼 ISWS record schema，与 `AutoObject.make_profile_instance_stamp_write_spec` 重复且已实际漂移（夹具写 `"type"`，生产 canonical 是 `"object_type"`）。改法：保留函数名与签名（demo 调用方不动），实现改为 `AutoObject.create_voxel_profile(...)` + `AutoObject.make_profile_instance_stamp_write_spec(...)`，`slice_index` 经 `extra_fields` 传入。等价链已逐环核实（`prepare_source_record` 在提交入口无条件重归一 `color.a=complexity`；`y_min/y_max` 0/0 与缺省同义；committer 不读 rotation 键；空 collision 空进空出）。爆炸半径 demo-only。

验证：`--check-only`；G2 门禁 `-e` 后打开 scene_voxel_tile demo 场景确认 tile 网格/HUD 统计不变。

### G2 — 批次 B 门禁（串行，在 B1–B4 提交合入后）

同 G1 流程（关旧编辑器 → fresh `-e` → 零脚本错误 + 桥 ping），另加：桥调 `run_stamp_only_commit_check`（B1）与 `run_resident_placement_writeback_check`（B2/B3），scene_voxel_tile demo 目检（B4）。

## 批次 C：collision 场布局改制（R8 字节道 → 每体素 u32）

> **状态：已执行完毕（2026-07-14，工作区未提交，提交策略同迁移批）**。C1 codec（`u32_field_byte_count`/`pack_collision_field_u32_bytes`/`decode_collision_field_u32_bytes`/`u32_bytes_from_r8_bytes`/`r8_bytes_from_u32_bytes`）+ C2 八个写方 shader（CAS 循环→单行 `atomicMax`、字节道 `atomicOr`→整字、compose per-lane→per-voxel max）+ C3 八个读方 shader（word/shift/mask→直接索引）+ C4a/b/c 十五个 CPU 消费方（分配/校验/标签全走新 codec；committer+tile_store 双份 STRIDE 1→4、FORMAT `r8_unorm`→`unorm8_u32` 同步对齐）。全仓 `.gd/.glsl` grep `r8_word|_r8_words` 零残留；GLSL 标识符统一 `*_u32`。
> **G3 门禁 PASS**：改前 golden v2 钉绿（GOLDEN PASS）→ 改后 **GOLDEN PASS**（值逐位不变承诺兑现）；fresh `-e` 零脚本错误；`run_stamp_only_commit_check` 与改前逐字一致（scattered=5 field_max=0.70 brush=true feedback_overlap=1）；`run_resident_placement_writeback_check` ok（spawned=8 shader_consumed=true stats_applied=8）。
> **遗留跟进**：① dict 值 `"target_collision_format": "r8_packed_u32"` 字面已不准确（跨 SPA/target_reader/borrow/prefilter/spa_test 的契约值，未在改名表内）——需一次协调的跨文件改值，暂保持一致未动；② `terrain_collision_volume`/`voxel_collision_erode` 的覆写→`atomicMax` 等价性依赖调用方每次 dispatch 零分配新缓冲（已核实成立）——未来若复用脏缓冲，atomicMax 不会降低旧值；③ 磁盘 baked `.r8` 保持 1B/体素、上传时展开（既有架构，未动）。

> **状态（2026-07-13）**：前置迁移已落盘，批次 C 解除阻塞、可启动；前提经代码复核仍成立（详见下方“前置条件”）。这是继批次 A / B1a 之后最主要的剩余重复精简项。
>
> **状态更新（2026-07-13 晚，批次 B 会话）：C 未启动，两个硬阻塞待清**：
> 1. **改前 golden 基线不绿**：G2 后跑 `node tools/golden_snapshot_check.js` → GOLDEN DIFF。差异特征：平分 gain（-349）处的 yaw slot 位移若干 + 4 处 gain_q1000 ±0.001~0.010 波动。归因分析：approved 文件由迁移会话于 18:32 重批（晚于其全部打分 shader 修改 17:05/17:32/18:02），且差异量不流经批次 B 任何触点（brush 散射/spawn 守卫/bit-exact 解码/夹具均不在 volume-score 细选路径）——特征指向**平分下 GPU 归约序非确定性**或迁移重批后又有行为漂移。**定性方法：同一编辑器会话连跑两次 golden，两次输出互 diff**（互异=非确定性，golden 对 tie 行无效，C 的回归网需改造或换判据；互同=真实漂移，须先归因）。C 启动前必须先把基线整绿或换等价判据（如 collision 场原始字节 readback 对照——C 只动 collision 布局，比对 collision 解码值比对 yaw tie 更贴切）。
> 2. **并行会话活跃**：21:36 本文档被并行会话更新、21:5x `voxel_fixtures.gd` 被其叠改（保留了 B4 改动）、21:57:35 其杀掉 B 会话编辑器并启动自己的编辑器验证。C 的文件集（codec、stamp_asset_voxels.glsl、打分 shader、fixtures、SPA…）与其热 WIP 直接重叠，按“同文件串行、不叠改他人 WIP”纪律，**须等该会话停笔或与其排定顺序后再启动 C**。

用户拍板（2026-07-13）：GPU 侧 collision 场访问方式与 `complexity_field_rgba8` 保持一致（每体素一个 u32、直接按体素索引寻址），接受 4× 显存代价。这是一份跨 shader/CPU 的二进制契约变更，**必须整体一次换、不可分批**。

**新布局契约**：

```glsl
// 旧: 4 体素/word，读写都要 word_index/shift/mask，写须 19 行整-word CAS 循环
// 新: 每体素 1 个 u32，值 = quantize_unorm8(v)（0..255，量化规则不变 ⟹ 解码后数值逐位不变）
layout(...) buffer CollisionField { uint collision_field_u32[]; };   // 命名按词根法则终定
atomicMax(collision_field_u32[index], quantize_unorm8(value));       // 写：单行替代 CAS 循环
float v = float(collision_field_u32[index]) / 255.0;                 // 读：直接索引
```

- 写入正确性：量化值的 uint 大小序 = collision 值大小序，`atomicMax` 即单调 max 语义，无需 CAS。
- 连带收益：6+ 份 `atomic_max_r8` CAS 拷贝全部溶解为单行；"不做清单"里冻结的 CAS 家族只剩 complexity RGBA8 半边（alpha 在低字节、word 序 ≠ alpha 序，仍需 CAS，保留）。
- 显存代价：1→4 B/体素。256³ 每个场实例 16MB→64MB；常驻实例（committed SV / BrushSV / BlendSV / target / terrain + 临时 scratch）合计约 +200-350MB VRAM。用户已接受。

**前置条件（硬）**：迁移已落盘（2026-07-13，工作区未提交）——原“迁移已提交”前置现已满足。契约 owner `scene_voxel_tile_codec.gd`、主写方 `stamp_asset_voxels.glsl`、主读方 `score_anchor_asset_residual.glsl` 均为迁移后形态，C2 / C3 目标 shader 全部在位。**前提仍成立**：`stamp_asset_voxels.glsl` 仍以 R8-word CAS 存写 collision（`collision_field_r8_words[index >> 2u]` + `atomicCompSwap`，约 143–174 行），迁移未改 collision 布局。

| 代理 | 任务 | 范围 |
| --- | --- | --- |
| C1 | CPU 契约层：codec pack/decode 家族改 u32 stride、`r8_word_byte_count`→`voxel_count*4`、`r8_bytes_from_word_bytes` 家族删除或退化 | `scene_voxel_tile_codec.gd`、`buffer_utils.gd` |
| C2 | GPU 写方：CAS 循环 → `atomicMax` 单行 | `stamp_asset_voxels.glsl`（双份）、`scatter_sv_field_records.glsl`、`merge_sv_collision_records.glsl`、`compose_blend_sv_fields.glsl`、`terrain_collision_volume.glsl`、`voxel_collision_erode.glsl` |
| C3 | GPU 读方：word/shift/mask 提取 → 直接索引 | `score_anchor_asset_residual.glsl`、`score_anchor_asset_probes.glsl`、`collect_sv_anchors.glsl`、`target_sv_pack_read_buffers.glsl`、`target_scene_voxel.glsl`、`score_blendsv_feedback.glsl`、`reduce_scene_voxel_tile_summaries.glsl`、`pack_prefilter_field_pair.glsl`、`pick_scene_voxel.glsl`、`voxel_field_instances.glsl`（`update_scene_voxel_tile_summary_ranges.glsl` 已在 2026-07-13 tile-store 精简中删除：只加载未派发的死管线） |
| C4 | CPU 分配/校验点：`storage_buffer_zero` 尺寸、byte-count 契约守卫、target reader 校验 | `scene_placement_actor.gd`、`scene_voxel_tile_store.gd`、`scene_voxel_committer.gd`、`scene_voxel_field_builder.gd`、`mesh_voxelizer_gpu.gd`、`voxel_placement_generator.gd`、`voxel_placement_target_reader.gd`、`target_scene_voxel_generator.gd`、`voxel_pick_gpu.gd`、`autoobject_probe_prefilter_gpu.gd` 等 16 文件 68 处 |
| G3 | 门禁：golden-master 前后对照 + `-e` + 三条 check | 见下 |

**注意事项**：

- ⚠ `target_sv_loader.gd`：磁盘 baked TargetSV 若以 R8-word 格式存储，**磁盘格式保持不变**（紧凑），加载时一次性 R8→u32 展开（CPU 或一个 expand pass），避免重烘全部资产。C4 内落实。
- 量化规则不变 ⟹ 解码值逐位不变 ⟹ **golden-master 基线（`tools/golden_snapshot_check.js` + `goldens/`）改前改后各跑一次应全绿**，这是本批次最强的回归网。
- shader 批量编辑须编辑器关闭时做；C1-C4 完成后 G3 一次性验证（`-e` + `run_stamp_only_commit_check` + `run_resident_placement_writeback_check` + 体素点击/target 对比抽查）。
- 缓冲/标识符命名（`collision_field_u32` 或其他）执行前按词根法则记忆终定，全仓一致换名。

## 不做清单（勿再报）

- **CAS 写场算法（`atomic_max_r8`/`atomic_max_rgba8`）多份 shader 拷贝**：落在 2026-07-10 冻结名单的 CAS 家族；迁移落地删掉 `stamp_voxel_field.glsl` 后拷贝数自然减半。迁移稳定后如仍想锁 `dual_commit` 孪生对漂移，可议 @@GEN 参数化 emitter（`emit_atomic_max_*(fn_name, buffer_ident)`，`DebugBufferSet.emit_glsl_block` 有 per-consumer 参数化先例），当前不做。
- **`stamp_voxel_field.glsl` vs `stamp_asset_voxels.glsl` 整套骨架重复**：迁移本身正在解决（旧文件已暂存删除），不插手。
- **@@GEN `yaw_rotation_y` CONSUMERS 换代**：审计中期曾报"门禁覆盖回退"，末期证实是迁移把消费者从旧 shader 换到新 shader 的正常换代，非回归，已了结。
- 补盲代理建议的 apply-accepted-placements 双 shader dirty-delta 20-word 布局 @@GEN 门禁：0 行收益、纯契约锁，medium 置信未核实，暂缓。
- 2026-07-10 冻结名单全部条目（GLSL 微帮助函数、SCENE_VOXEL_TILE_* 常量三份、双 tile-summary 布局等）。

## Open Questions

- ~~迁移已于 2026-07-13 落盘到工作区（尚未 commit），批次 B / C 门禁随之解除~~ 批次 B 已于同日晚在同一未提交工作区内执行完毕（见批次 B 状态块）。仍待定：**提交切分**——B 批改动与迁移 WIP 在同文件交织（SPA/runtime/VPG/buffer_utils/fixtures），无法单独外科提交；须迁移先 commit、B 批再补提交，或两者合并提交，由用户/迁移会话拍板。
- **批次 C 两个硬阻塞**（见批次 C 状态更新）：改前 golden 基线 DIFF 未归因；并行会话活跃且文件集重叠。清阻后按 C1-C4+G3 执行。
- ~~B3 任务 2 的转发器清单、B4 的生产组装器路径需执行代理再就地 grep 确认~~ 已确认并执行（见状态块）。
- ~~B2 的 post-dispatch 尾块重复为 medium 置信，执行代理须先自行核实~~ 已亲读判否（见状态块）。
- `voxel_placement_state_chain.gd` 的三个 contract 静态函数（`_full_field_readback_contract` 等）在 B3 删除 VPG 转发后为全仓零调用，疑似迁移中断的死码——留迁移会话裁决。
- 各条预计省行为审计估值，实际以 diff 为准。
