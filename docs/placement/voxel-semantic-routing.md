# Voxel Semantic Routing — 候选资产与 Voxel Region 路由

![Voxel semantic routing overview](../graphs/voxel-semantic-routing.svg)

本文记录当前 placement routing 的契约：上游 GPU probe prefilter 先筛出候选资产和候选 voxel regions，`VoxelPlacementGenerator` 只对命中的区域做物理放置评分。语义 rerank、context pooling 和 learned matcher 仍是 TODO，不应写成现行主路径。

## 术语

| 术语 | 含义 |
| --- | --- |
| `volume` | 整个 voxel data domain / buffer；不是单个元素。 |
| `voxel` | `volume` 中的单个 `(x, y, z)` cell / element。 |
| `tile` | 底层固定大小 block，用作 storage key、workgroup key 或 sparse dispatch key。 |
| `voxel region` | 高层 routing / placement 候选区域；当前通常映射到一个 `8x8x8` tile。 |

文档优先使用 `voxel region`。代码中的 `candidate_voxel_sparses*`、`voxel_sparse`、`dirty_tiles`、`tile_id` 是 debug 或底层命名，语义上按 candidate / dirty voxel regions 理解。

## 当前状态

GPU probe prefilter、CPU readback debug view、Candidate region expansion、`candidate_route_profiles`、`run_multi_asset()` 路由消费均已实现。以下为未完成项：

| 层 | 状态 | 契约 |
| --- | --- | --- |
| 同类型 AutoObject 互斥 | 规划中 | 复用 per-voxel object refs、`SceneVoxelTile` 粗过滤和 `GPUAutoObjectRuntime` object/profile buffers。 |
| Semantic rerank / context pooling | TODO | `semantic_score`、`route_score`、`voxel_context_buffer`、`target_scene_context_rgba8_buffer` 只保留为候选内验证计划。 |

## 数据流

```text
BlendSV-backed SV[t - 1] resident fields + TargetSV_B + AutoObject registry
  -> collect position-only anchors
  -> score descriptor-backed semantic probes
  -> select anchor top-K assets
  -> reduce to per-asset voxel-region votes
  -> readback + conservative expansion
  -> candidate_voxel_regions_by_asset / legacy candidate_voxel_sparses_by_asset debug view
  -> VoxelPlacementGenerator.run_multi_asset()
  -> future GPU same-type exclusion
  -> score_voxel_tile.glsl physical scoring
  -> accepted placements
  -> optional GPUAutoObjectRuntime writeback
  -> optional instance_stamp_writeback / SceneVoxelCommitter source write
```

`run_minimal()` 只有在没有传入 `candidate_voxel_regions` / legacy `candidate_voxel_sparses` 时才枚举 full grid。只要显式传入空 candidate list，或 `run_multi_asset()` 在 route dictionary 中找不到该 asset 的候选区域，就直接 skip。

## Score 阶段边界

`score_voxel_tile.glsl` 是物理和 target fit 精筛 shader。当前它读取：

- `scene_field`
- `collision_field`
- footprint buffers
- candidate voxel-region ids
- `target_occupancy`
- packed `RGBA8` `target_color`

这是候选级 placement score，不是 placement 结束后的 result feedback score。结果级 feedback 在 `BlendSV[tick]` 发布后，由 `SceneVoxelCommitter.score_blendsv_feedback_against_target()` 拿 committed result 与 `TargetSV_B` / `TargetSV` 对比。

它不做以下事情：

- 不读 `asset_embedding_buffer`。
- 不生成 `voxel_asset_topk_buffer` / `tile_asset_topk_buffer`。
- 不计算 semantic dot、MLP、`semantic_score` 或 `route_score`。
- 不做 target neighborhood pooling 或 candidate route validation。

因此，语义 rerank 和 context pooling 只能作为上游候选内验证 TODO，不能写成 physical score shader 的现行能力。

## Candidate Route 契约

当前 route 输入：

```gdscript
common_settings["candidate_voxel_regions_by_asset"] = {
	asset_index: Array[Vector3i] # candidate voxel-region coords
}
```

每个 asset 也可以直接携带：

```gdscript
asset_def["candidate_voxel_regions"] = [Vector3i(...)]
```

优先级与行为：

- asset 自带 `candidate_voxel_regions` 时优先使用它。
- 否则使用 `candidate_voxel_regions_by_asset[asset_index]` 或字符串形式的 `asset_index`。
- `candidate_voxel_sparses` / `candidate_voxel_sparses_by_asset` 是 legacy alias，会归一化到同一条 candidate voxel-region 路径。
- 显式空 list 表示该 asset 被 prefilter 剪掉，结果标记 `skipped_prefilter = true`。
- 空 candidate regions 不会触发 full grid fallback。
- 候选区域进入 physical scoring 前，后续可由 GPU same-type exclusion 继续剪枝。

## Candidate Region 扩张

GPU reduce shader 先把 anchor top-K 聚合成 per-asset tile votes。readback 时再按 asset route profile 扩张：

```text
candidate_region =
  voted_anchor_tile
  + asset_footprint_aabb
  + semantic_probe_offset_bounds
  + context_sensing_radius
  + interpolation_guard_voxels
```

当前实现细节：

- `interpolation_guard_voxels >= 1`，覆盖线性 / 三线性采样可能读取到的相邻 voxel。
- `probe_min` / `probe_max` 来自 `AutoObject.get_semantic_probes()` 的 offset bounds。
- `footprint_min` / `footprint_max` 来自 collision 烘焙后的 footprint bounds。
- `context_radius_voxels` 来自 descriptor 或 descriptor fields `context_sensing_radius`。
- `tile_radius` 是上述 padding 映射到 tile 后的扩张半径。
- `candidate_route_profiles` 只暴露这些 debug 信息，便于检查扩张原因。

Routing 阶段偏向召回，footprint、support、collision、clearance 和 target fit 仍交给 `score_voxel_tile.glsl` 精筛。

## TargetSV_B 边界

`TargetSV_B` 是 `TargetSV + BrushSV` 合成后的 target / guidance 输入：

- prefilter probe scoring 默认读取 `TargetSV_B` 映射出的 `target_occupancy` 与 `target_color`。
- result feedback 阶段以 `TargetSV_B` / `TargetSV` 作为目标侧对比输入，不把 target 写进 committed `SceneVoxel`。
- probe 采样坐标越界时 clamp 到 SV / TargetSV_B 有效范围内，不把边界外直接当作空白。
- `TargetSV_B` 不进入 committed `SceneVoxel`。
- `TargetSceneVoxel` guidance record 会保留为可查询元数据，但跳过 source buffers：`height_buffer_applied = false`、`collision_buffer_applied = false`。

目标场契约详见 [`target-scene-voxel-projection.md`](target-scene-voxel-projection.md)。

## 同类型互斥

同类型互斥不再通过 CPU runtime manager 做 candidate 剪枝。后续实现应复用 `SceneVoxelCommitter` / SV owner 发布的 per-voxel object refs、`SceneVoxelTile` 粗粒度范围和 `GPUAutoObjectRuntime` object/profile buffers：

- `object_type_buffer`：粗粒度 runtime grouping / debug metadata。
- `object_bounds_buffer`：邻居 footprint / radius / min spacing 查询输入。
- per-voxel object refs + `SceneVoxelTile` ranges：按 voxel / tile range 查找邻居 object ids。
- placement / exclusion shader：用 candidate 与邻居的 `min_spacing` 做中心距约束。

该阶段只剪 candidate voxel regions，不替代 footprint / support / collision / clearance 精筛。`object_type` 不是资产默认语义来源，也不替代 `AutoVoxelDescriptor`。不要新增 `object_subtype`；更细的资产差异由 descriptor profile / `profile_id` 表达。

## Route Key 命名

| 当前名称 | 语义 | 状态 |
| --- | --- | --- |
| `candidate_voxel_regions_by_asset` | `run_multi_asset()` 推荐消费的 per-asset route dictionary | docs-facing / current key；归一到现有 candidate route path |
| `candidate_voxel_regions` | 单个 asset 的 candidate voxel regions | docs-facing / current key；优先于 common route dictionary |
| `candidate_voxel_sparses_by_asset` | legacy per-asset route dictionary | 兼容 alias；归一到同一 candidate route path |
| `candidate_voxel_sparses` | 单个 asset 的 candidate voxel regions | legacy alias |
| `autoobject_candidate_voxel_sparses` | per-asset candidate voxel regions | CPU debug / debug API |
| `candidate_route_profiles` | route expansion debug records | 已实现 debug |
| `tile_id` | 底层 tile storage / workgroup key | 保留底层命名 |

## TODO / Open Questions

后续事项统一维护在 [`voxel-semantic-routing-todo.md`](voxel-semantic-routing-todo.md)。当前开放问题：

- 是否把 CPU route dictionary 迁移为 actor 生命周期内的 GPU resident route buffer，并让 placement 直接消费。
- 实现 GPU same-type exclusion pass，并接入 per-voxel object refs、`SceneVoxelTile` ranges 和 `GPUAutoObjectRuntime` object/profile buffers。
- 是否保留独立 `voxel_context_buffer` / `target_scene_context_rgba8_buffer`，或并回 probe prefilter 路径。
- `semantic_score` / `route_score` 的默认权重和阈值尚未实现，不能作为现行验收条件。
- Dirty route rebuild 需要明确只更新 affected voxel regions 的最小边界和测试覆盖。

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [Routing 总览](../../demos/placement-voxel-semantic-routing/placement-voxel-semantic-routing.md) | 测试方法与验收标准 | [`../../demos/placement-voxel-semantic-routing/placement-voxel-semantic-routing.tscn`](../../demos/placement-voxel-semantic-routing/placement-voxel-semantic-routing.tscn) |
| [Candidate Routing Contract](../../demos/modules/candidate-routing-contract/candidate-routing-contract.md) | 测试方法与验收标准 | [`../../demos/modules/candidate-routing-contract/candidate-routing-contract.tscn`](../../demos/modules/candidate-routing-contract/candidate-routing-contract.tscn) |
| [Probe Prefilter Routing](../../demos/modules/probe-prefilter-routing/probe-prefilter-routing.md) | 测试方法与验收标准 | [`../../demos/modules/probe-prefilter-routing/probe-prefilter-routing.tscn`](../../demos/modules/probe-prefilter-routing/probe-prefilter-routing.tscn) |
