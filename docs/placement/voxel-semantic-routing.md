# Voxel Semantic Routing — 候选资产路由与 Voxel Region 路由

![Voxel semantic routing overview](../graphs/voxel-semantic-routing.svg)

## 术语约定

| 术语 | 含义 |
| --- | --- |
| `volume` | 整个 voxel data domain / buffer；不是单个元素。 |
| `voxel` | `volume` 中的单个 `(x, y, z)` cell / element。 |
| `tile` | 底层固定大小 block，用于 storage key、dirty rebuild、sparse dispatch 或 workgroup 映射。 |
| `voxel region` | 高层 routing / placement 候选区域；当前通常映射到底层 `tile_id`。 |

本文 prose 优先使用 `voxel region`。当前代码和兼容 API 仍可能出现 `candidate_voxel_sparses*`、`voxel_sparse`、`dirty_tiles`、`tile_id` 等历史或底层命名；这些名称在本文中都按 candidate / dirty voxel regions 或底层 tile key 理解。

## 目标

当前 `score_voxel_tile.glsl` 主要负责物理评分：

- `support`
- `collision`
- `clearance`
- `overlap`
- 可选 `target_occupancy`
- 可选 packed `RGBA8` `target_color`

本文不再假设通过语义匹配从全资产库选择“最优 asset”。前置筛选阶段已经根据 anchor、probe、`TargetSV_B`、规则或资产 profile 得到了可用候选资产；后续语义向量匹配只在这些候选资产内部做 rerank、validate 或 prune。本文负责把保留下来的候选资产整理成可被 placement 使用的 candidate voxel regions。

```text
full rebuild / dirty update
  -> upstream asset prefilter
  -> GPU AnchorState(score/topK) / candidate route buffer
  -> optional semantic rerank within each anchor candidate set
  -> normalize + deduplicate candidate voxel regions
  -> optional context validation / EMPTY pruning
  -> asset_id -> candidate voxel regions
  -> candidate_voxel_sparses_by_asset compat/debug view
  -> optional same-type AutoObject exclusion gate
  -> score_voxel_tile.glsl 只处理路由命中的 asset / voxel regions
```

核心原则：

- `score_voxel_tile.glsl` 不做语义 dot / MLP / 邻域语义统计。
- 路由阶段不遍历全资产库，只处理上游已经筛选成功的候选资产。
- 如果需要语义向量匹配，它只作为候选集内部重排和置信度调整，不负责发现新 asset。
- 路由只在初始化和 dirty update 阶段更新。
- candidate voxel regions 必须偏向召回，按 footprint、probe 插值采样范围和 context 半径保守扩张，不能只保留 anchor 所在区域。
- `EMPTY_ASSET_ID` 是合法结果，用于表示某些 anchor / voxel region 没有有效候选或应保持为空。

---

## Score 阶段边界

Score 阶段仍然保留现有职责。

| 数据 | 用途 | 是否属于语义查找 |
| --- | --- | --- |
| `scene_field[p]` | overlap / support | 否 |
| `collision_field[p]` | collision / clearance | 否 |
| `target_occupancy[p]` | target mask / value fit | 否，属于精筛 |
| `target_color[p]` packed `RGBA8 uint` | target color fit | 否，属于精筛 |
| `voxel_context` | 候选 route 验证 / EMPTY 判断 | 可选 |
| `target_scene_context_rgba8` | 周围颜色/复杂度验证 | 可选 |

`target_occupancy <= 0.01` 仍可在 score 阶段排除候选；路由阶段也可以利用 target complexity 提前偏向 `EMPTY`，但不替代最终物理精筛。

---

## 候选路由数据

### 上游筛选输入

Semantic routing 的输入不是全量 asset 表，而是上游筛选后的候选集。

| 数据 | 形态 | 含义 |
| --- | --- | --- |
| GPU `AnchorState` / `anchor_topk` | `anchor_id -> candidate assets` on GPU | 每个 anchor 已筛选成功的资产列表；score / top-K 正常路径不需要 CPU 回读 |
| GPU candidate route buffer / candidate voxel-region view | `asset_index -> voxel_region_coords` | 每个资产需要进入 score 的 candidate voxel regions；CPU `Dictionary` 仍可能以 `candidate_voxel_sparses_by_asset` 作为兼容 / debug 视图 |
| `candidate_score` | candidate record 字段 | 上游 prefilter 的置信度或匹配分 |
| `anchor_position` / `anchor_id` | candidate record 字段 | position-only anchor 引用；不存 `anchor_kind` |

当前 placement 接入点优先使用 candidate voxel-region route。代码兼容入口仍是 `candidate_voxel_sparses_by_asset`；如果某个 asset 没有 candidate voxel region，则该 asset 本轮 placement 可以直接跳过。

### Candidate voxel region 扩张规则

Candidate voxel region 不是精确采样点集合。Asset probes 后续会对 `TargetSV_B` / `SceneVoxel` 做插值采样，因此路由输出必须保守扩张：

```text
candidate_region =
  anchor_voxel
  + asset_footprint_aabb
  + semantic_probe_offset_bounds
  + context_sensing_radius
  + interpolation_guard_voxels
```

规则：

- `interpolation_guard_voxels` 第一版至少取 `1`，覆盖线性 / 三线性采样可能读取到的相邻 voxel。
- `semantic_probe_offset_bounds` 应按当前 asset 和 anchor kind 的 probe offset 范围计算，不能只按 anchor voxel 近邻估算。
- `context_sensing_radius > 0` 的小型资产要把外围 context probe 感受野也纳入 candidate voxel regions。
- Candidate voxel regions 应宁可多包含 voxel，交给 `score_voxel_tile.glsl` 精筛；不要在 routing 阶段过早裁剪导致高分位置无法被采样。

### 同类型 AutoObject 互斥预检

当前实现中，`VoxelPlacementGenerator.run_multi_asset()` 在进入 GPU physical scoring 之前，可以先用 `AutoObjectManager` 对 candidate voxel regions 做同类型互斥预检。该步骤不替代 `score_voxel_tile.glsl` 的 footprint / support / collision / clearance 精筛，只负责剪掉已经明显违反同类中心距约束的 candidate voxel regions。

预检依赖运行时低分辨率 `Vector3i(x, y, z)` cell 索引。当前 `AutoObjectManager._spatial_y_layer()` 固定返回 `0`，所以实际仍是单层 XZ 查询；保留 `Vector3i` key 是为了兼容后续 3D / 多层互斥逻辑。

| 数据 | 来源 | 用途 |
| --- | --- | --- |
| `auto_object_manager` | `common_settings` 或 `SceneVoxelLocal.auto_object_manager` | 查询已提交的周围 `AutoObject` |
| `object_type` | `asset_def`、`AutoObject` 或兼容配置 | 运行时 grouping / debug metadata；可作为当前 same-type 查询 key |
| `object_subtype` | `asset_def`、`AutoObject` 或兼容配置 | 运行时 grouping / debug metadata；细分 same-type 查询 |
| `min_spacing` | `asset_def` 或对应 `AutoObject` asset | 候选自身互斥半径 |
| 已放置对象 `min_spacing` | `AutoObjectManager` record | 邻居互斥半径 |

当前代码仍维护 `object_type` / `object_subtype`，并用它们作为 same-type exclusion 的运行时 grouping metadata。它们不是资产默认语义来源，也不应替代 `AutoVoxelDescriptor`。如果后续需要更清晰的互斥语义，应引入 `exclusion_group` 或 `placement_group`，再从 `object_type` / `object_subtype` 迁移。

互斥条件：

```text
distance(candidate_voxel_region_xz_range, neighbor_center_xz)
  < candidate.min_spacing + neighbor.min_spacing
```

如果 candidate voxel region 被同类型对象阻挡，该区域会在 physical placement 前被移除；如果该 asset 的所有 candidate voxel regions 都被移除，本轮该 asset 返回：

```gdscript
skipped_same_type_exclusion = true
same_type_exclusion = {
    "blocked_voxel_sparse_count": int,     # compat name, blocked voxel-region count
    "candidate_min_spacing": float,        # candidate spacing radius
    "object_type": String,                 # runtime grouping/debug metadata
    "object_subtype": String,              # runtime grouping/debug metadata
    "first_block": Dictionary,             # first blocked region/debug payload
}
```

`SceneVoxelLocal.run_placement()` / `run_placement_dirty()` / `run_prefiltered_placement_dirty()` 会在配置了 `auto_object_manager` 时把它转发给 `run_multi_asset()`。`run_prefiltered_placement_dirty()` 可用传入的 `autoobjects` 为 `asset_defs` 自动补齐 `asset`、`object_type`、`object_subtype` 和 `min_spacing`。

### Anchor 粗筛后的语义匹配

每个 anchor voxel 的粗筛结果是后续语义向量匹配的 hard gate。语义匹配不能再遍历全资产库，只能读取该 anchor 已经保留的候选资产：

```text
for anchor in dirty_anchors:
    candidates = AnchorState.topk(anchor.id)  # GPU state; CPU dict only for debug/compat

    for candidate in candidates:
        semantic_score = match(anchor_context, candidate.asset_target_pref)
        route_score = combine(candidate_score, semantic_score, support_hint)

    keep candidates where route_score >= min_route_accept
    keep topK candidates by route_score
```

语义匹配阶段不直接输出唯一 `best_asset`。它应保留多个候选 route，让后续 voxel region 聚合和 `score_voxel_tile.glsl` 继续处理 footprint、support、collision、clearance 等物理精筛。

### TargetSV_B 采样边界规范

候选 route 验证、semantic probe rerank 和 target context pooling 读取 `TargetSceneVoxel` 时，采样坐标必须先投射到 `TargetSV_B` 的有效范围内。若 probe offset、local / wide context 邻域或 asset footprint 推导出的采样位置超出 `TargetSV_B` 边界，不直接视为空白或失败，而是投射到最近的有效 `TargetSV_B` voxel：

```text
sample_pos = anchor_pos + probe_or_context_offset
sample_pos = clamp(sample_pos, target_sv_min, target_sv_max)
sample_value = TargetSV_B[sample_pos]
```

规范：

- X / Y / Z 三轴都使用最近点投射，即 `clamp` 到 `[0, grid_size - 1]` 或对应 dirty / imported `TargetSV_B` bounds。
- 投射只用于读取 `TargetSV_B` / target context，不改变 anchor 位置、asset footprint 或最终 placement 坐标。
- 若原始采样点越界，可以记录 `clamped_sample_count` 作为 debug / confidence hint；第一版不要求参与 `route_score`。
- 只有 `TargetSV_B` 本身缺失或未启用时，才跳过对应 `semantic_score` / `target_score` 项。

### `voxel_context`

> 待检查：这一层 `voxel_context` 候选验证与现有 probe prefilter 在职责上可能存在重叠。当前不应视为稳定主线设计；是否保留、收窄到非语义 gate，或并回 probe 路径，需后续专门复核。

每个 voxel 可选保存 16 维 normalized float context，GPU 侧为 4 个 `vec4`。它不再用于全资产库匹配，只用于候选 route 的局部验证、去噪或 EMPTY 判断。

| 维度 | 名称 | 来源 | 含义 |
| --- | --- | --- | --- |
| 0 | `reserved` | - | 保留 |
| 1 | `scene_density` | 3×3×3 scene 平均 | 占用密度 |
| 2 | `reserved` | - | 保留 |
| 3 | `support_below` | 当前 voxel 下方支撑采样 | 粗筛支撑强度 |
| 4 | `y_low_free` | 低 Y 段空闲率 | 低层空间 |
| 5 | `y_mid_free` | 中 Y 段空闲率 | 中层空间 |
| 6 | `y_high_free` | 高 Y 段空闲率 | 高层空间 |
| 7 | `reserved` | - | 保留 |
| 8-15 | `patch_2x2x2` | `8×8×8` 感受野池化 | 局部占用形态 |

`support_below` 用于在粗筛阶段提前排除明显悬空的位置。它可以先用当前 voxel 下方一格的
`max(scene_field, collision_field)` 表示；后续可扩展为当前 asset footprint 的支撑点数量估计。

`8×8×8 = 512` raw voxel 不直接作为查找 key，而是压缩成 `2×2×2 = 8` 个 patch feature，降低维度和匹配成本。

### `target_scene_context_rgba8`

> 待检查：这一层 target context pooling 目前更像候选内二次验证，与 probe 对 `TargetSV_B` 的采样语义边界需要重新澄清。当前按计划项理解，不作为已定稿主路径。

`SceneVoxel` / `TargetSceneVoxel` 的颜色和复杂度用于候选 route 验证时按 `RGBA8 / UNORM8` 存储：

```text
R8 = round(color.r * 255)
G8 = round(color.g * 255)
B8 = round(color.b * 255)
A8 = round(complexity/value * 255)
```

每个 voxel 保存周围 target scene 的 local + wide 两级摘要：

| Scale | 原始范围 | 分区 | 输出 |
| --- | --- | --- | --- |
| `local` | `8×8×8` | `2×2×2` | 8 个 packed `RGBA8 uint` |
| `wide` | `16×16×16` | `2×2×2` | 8 个 packed `RGBA8 uint` |

local / wide pooling 的每个采样点都遵循 `TargetSV_B` 采样边界规范：超出 `TargetSV_B` 范围时投射到最近的有效 `TargetSV_B` voxel，再参与 pooled cell 统计。

每个 pooled cell：

```text
RGB = complexity-weighted average color
A   = average complexity/value
```

语义含义：

- `RGB` 表示周围目标区域的主导颜色。
- `A` 表示周围目标复杂度 / 期望占用强度。
- `A` 很低时可提前提高 `EMPTY` 分数，或降低候选 route 的优先级。

### Candidate 侧数据

每个已经通过上游筛选的 candidate 至少提供：

```text
asset_index
candidate_voxel_regions                         # preferred prose/schema term
candidate_voxel_sparses                         # current compat API key
candidate_score
anchor_position_or_id
semantic_score                                  # optional rerank score
route_score                                     # optional combined score
asset_target_pref_rgba8[16 packed RGBA8 cells]  # optional validation data
```

第一版不需要强制生成全局 `asset_embedding_buffer`。如果已有 asset target preference，可以只在候选集内部做轻量验证或排序：

- 上游 prefilter 决定 asset 是否进入候选集。
- `candidate_score` 保留上游匹配分。
- `semantic_score` 只在候选集内部参与 rerank，不生成新候选。
- `route_score` 可作为 `candidate_score`、`semantic_score` 和 validation hint 的组合结果。
- `asset_target_pref_rgba8` 只用于候选 route 的 tie-break / confidence adjustment。
- 物理可放置性仍由 score 阶段的 footprint、support、collision、clearance 决定。

---

## 候选路由评分（待检查）

### Candidate route

> 待检查：`semantic_score / target_score / route_score` 这套候选内重排分数，和上游 probe prefilter 的排序职责可能重复。当前应把它视为待确认方案，而不是现行稳定评分链路。

```text
prefilter_score = candidate_score
semantic_score  = match(anchor_context, asset_target_pref_rgba8)              # optional candidate-only rerank
target_score    = match(target_scene_context_rgba8, asset_target_pref_rgba8)  # optional route validation
support_hint    = read(voxel_context.support_below)                           # optional
clamp_hint      = read(clamped_sample_count)                                  # optional debug/confidence hint

route_score =
    prefilter_score * prefilter_weight +
    semantic_score  * semantic_weight +
    target_score    * target_weight +
    support_hint    * support_hint_weight
```

`route_score` 只用于候选集内部排序、去重或剔除低置信度 route，不用于从全资产库选择最优 asset。`semantic_score` 和 `target_score` 只在 asset 提供 target preference 或 embedding 时参与；否则可以跳过。

`clamp_hint` 默认不参与第一版评分；如果后续发现边界投射过多导致候选质量下降，可以把越界比例作为轻量 penalty。

支撑只用于粗筛，不替代 score 阶段的 footprint 支撑检测：

```text
if asset_requires_support and support_below < asset_min_support_hint:
    reduce route_score
```

### EMPTY

```text
EMPTY_ASSET_ID = 0xffffffff
```

`EMPTY` 表示该 voxel 不适合放置任何 asset。它可以由以下条件提高：

- 上游候选集为空
- candidate route confidence 低于阈值
- scene density 过高
- 当前体素下方支撑不足
- Y 层空闲度过低
- target complexity 很低
- local target context 接近空白

推荐规则：

```text
if candidate_count == 0:
    choose EMPTY

if best_route_score < min_route_accept:
    choose EMPTY

if support_below < min_support_hint:
    choose EMPTY or reduce unsupported assets

if current_target_a <= 0.01 and local_avg_target_a <= 0.03:
    choose EMPTY
```

Voxel region 聚合时，`EMPTY` 不作为 asset 输出；但如果一个候选区域内 EMPTY 投票过高，则整个区域可跳过候选放置。

```text
if empty_votes / valid_voxels > empty_region_threshold:
    remove voxel region from candidate route buffer
    update candidate_voxel_sparses_by_asset compat view
```

推荐默认：

```text
min_route_accept = 0.25
empty_region_threshold = 0.65
```

---

## 数据流

```text
upstream prefilter
  -> collect anchors
  -> provide filtered candidate assets
  -> GPU AnchorState(score/topK)

candidate rerank / route validation
  -> read candidates from GPU AnchorState / candidate route buffer only
  -> optional semantic vector match within candidate set
  -> update semantic_score / route_score
  -> prune low confidence routes / EMPTY routes

full rebuild
  -> normalize surviving candidate routes
  -> optional context validation
  -> build candidate voxel-region route buffer
  -> update candidate_voxel_sparses_by_asset compat view

dirty update
  -> rerun upstream prefilter for affected anchors / target bounds
  -> update affected asset routes
  -> rebuild affected candidate voxel regions

placement
  -> run_multi_asset receives candidate route buffer or candidate_voxel_sparses_by_asset compat view
  -> each asset only dispatches its routed voxel regions
  -> same-type AutoObject exclusion gate prunes blocked voxel regions
  -> score_voxel_tile.glsl remains physical scoring
```

---

## 路由数据布局

### GPU candidate route buffer / candidate voxel-region compat view

目标主路径应让 GPU candidate route buffer 直接限定后续 placement dispatch。当前兼容路径仍使用 CPU / GDScript `Dictionary` 把上游候选资产映射到 candidate voxel regions：

```gdscript
{
    asset_index: Array[Vector3i]  # voxel-region coords; compat key may say voxel_sparse
}
```

这个字典可以直接作为 `VoxelPlacementGenerator.run_multi_asset()` 的 `common_settings["candidate_voxel_sparses_by_asset"]`。对外语义是“每个 asset 本轮要检查哪些 voxel regions”；当前实现用 `Vector3i` 表示离散 voxel-region/block 坐标，生成器内部会把它们转换成内部 `tile_id`。生成器会为每个 asset 读取自己的 `candidate_voxel_sparses` 兼容 key；候选区域应带有 probe 插值采样 guard，偏向召回而非精确裁剪。如果某个 asset 的候选 voxel region 为空，则该 asset 本轮跳过。该字典不是长期权威状态，后续应被 actor 生命周期内的 GPU route buffer 取代。

### GPU `AnchorState` / `anchor_autoobject_topk` compat view

上游 prefilter 应把 anchor 级候选保留在 GPU `AnchorState` / `anchor_topk` 中，用于同一 SV epoch 内的 route buffer 生成、dirty merge 或后续重新聚合。CPU `anchor_autoobject_topk` 只作为 debug / 兼容视图：

```text
anchor_id -> [
    { asset_index, score, tile_id },
    ...
]
```

`anchor_autoobject_topk` 不是 score hot path 的输入；score hot path 应读取 GPU `AnchorState` / route buffer。当前 CPU 兼容视图可用于生成或更新 candidate voxel-region route，或同步 `candidate_voxel_sparses_by_asset` 兼容视图。

### 可选 `voxel_context_buffer`

```glsl
layout(set = 0, binding = 3, std430) restrict buffer VoxelContext {
    vec4 voxel_context[];  // voxel_id * 4 + group
};
```

如果启用 route validation，每 voxel 4 个 `vec4`，共 16 floats。该 buffer 只用于候选 route 验证和 `EMPTY` 判断，不用于遍历全资产库。

### 可选 `target_scene_context_rgba8_buffer`

```glsl
layout(set = 0, binding = 9, std430) restrict buffer TargetSceneContext {
    uvec4 target_scene_context[];  // voxel_id * 4 + group
};
```

每 voxel 4 个 `uvec4`，共 16 个 packed `RGBA8 uint`：

```text
group 0: local cells 0..3
group 1: local cells 4..7
group 2: wide  cells 0..3
group 3: wide  cells 4..7
```

### 可选 `asset_target_pref_rgba8_buffer`

```glsl
layout(set = 0, binding = 11, std430) restrict readonly buffer AssetTargetPrefs {
    uvec4 asset_target_prefs[];  // asset_id * 4 + group
};
```

每 asset 16 个 packed `RGBA8 uint`。如果 asset 不使用 target preference，则填 `A=0`。该 buffer 只参与候选 route 的 tie-break / confidence adjustment。

### 不再需要的旧 buffer

`asset_embedding_buffer`、`voxel_asset_topk_buffer`、`tile_asset_topk_buffer` 只属于旧的“全资产语义查找”方案。当前假设上游已经筛选成功资产，因此第一版不需要这些 buffer。这里的 `tile_asset_topk_buffer` 是历史底层 tile 命名，不应作为新的高层 routing 术语恢复。

---

## Shader 职责

状态：混合。当前已实现的主线是上游 prefilter 输出进入 candidate voxel-region route，并通过 `candidate_voxel_sparses_by_asset` 暴露兼容视图；下方 context shader 和 route validation 测试名是计划占位，除非明确标为当前实现。

### 计划 `precompute_voxel_context.glsl`

输入：

- `scene_field`
- dirty voxel ids / tile ids

输出：

- `voxel_context_buffer`

职责：计算 16D scene context，包括 density、当前 voxel 下方支撑强度、Y 层空闲度和 `8×8×8 -> 2×2×2` patch pooling。结果只作为候选 route 的局部验证信息。

### 计划 `precompute_target_scene_context.glsl`

输入：

- packed single-voxel target color / complexity
- dirty target bounds / affected context tiles

输出：

- `target_scene_context_rgba8_buffer`

职责：计算 local `8×8×8` 和 wide `16×16×16` 的颜色/复杂度 pooled context。结果可用于降低空白区域候选优先级，或对候选 route 做 tie-break。

采样规则：每个 context sample 坐标先按 TargetSV_B 有效范围 clamp；越界采样读取最近的有效 TargetSV_B voxel，而不是写 0 或直接丢弃。

### 计划 `route_candidate_voxel_regions`

输入：

- GPU `AnchorState` / `anchor_topk`
- dirty anchor ids / dirty voxel region ids（compat：dirty tile ids）
- 可选 `voxel_context_buffer`
- 可选 `target_scene_context_rgba8_buffer`
- 可选 `asset_target_pref_rgba8_buffer`

输出：

- GPU candidate route buffer / `candidate_voxel_sparses_by_asset` compat view

职责：把上游候选 anchor 结果归一化、去重并聚合为每个 asset 的 candidate voxel region 列表。聚合时必须按 asset footprint、probe offset bounds、context 半径和插值 guard 扩张区域。若启用语义向量匹配，它只能在 GPU `AnchorState` / `anchor_topk` 的候选资产内做 rerank / validate / prune，不能回退到全资产库枚举。所有 TargetSV_B 采样都先 clamp 到最近的有效 TargetSV_B voxel。当前可以先保留 GDScript/CPU 兼容视图；目标是迁移到 actor 生命周期内的 GPU route buffer。

---

## Dirty 更新规则

普通 scene field 变化：

```text
dirty voxel region (compat: dirty tile)
  -> rerun upstream prefilter for affected anchors
  -> update candidate_voxel_sparses_by_asset entries touched by dirty voxel region
  -> skip assets whose routed voxel region list becomes empty
```

Target color / complexity 变化会影响周围 anchor voxel，因此需要扩张更新范围：

```text
local radius = 4 voxels
wide radius  = 8 voxels

affected_context_bounds = dirty_target_bounds.expand(8 voxels)
affected_context_regions = voxel regions overlapped by affected_context_bounds
candidate_region_padding = footprint + probe_offset_bounds + context_radius + interpolation_guard
```

当前内部 block / tile 大小为 `8×8×8` voxels 时，wide context 通常意味着 target dirty voxel region 至少影响相邻一圈区域。

更新完成后只需要重建受影响 asset 的 candidate voxel regions，并同步 `candidate_voxel_sparses_by_asset` 兼容视图。不需要对所有 asset 重新生成 voxel 级 top-K。

---

## Pipeline 集成

### `SceneVoxelActor` / `SceneVoxelLocal`

建议由 `SceneVoxelActor`（暂名）持有与当前 SV epoch 同生命周期的 GPU anchor / route 状态；`SceneVoxelLocal` 负责当前 SV epoch 的 runtime sampling/query view，供 probe 采样、placement footprint 采样、route validation 和 debug query 读取。兼容层可以暂存 CPU 字典视图：

```gdscript
var _anchor_state_gpu: RID                         # AnchorState / anchor_topk / scores
var _candidate_route_buffer: RID                   # asset -> voxel-region votes/routes
var _anchor_autoobject_topk_debug: Dictionary      # optional compat/debug readback
var _candidate_voxel_sparses_by_asset: Dictionary # compat/debug view of voxel regions
var _voxel_context_buffer: PackedFloat32Array       # optional validation cache
var _target_scene_context_rgba8: PackedInt32Array   # optional validation cache
```

建议新增接口：

```gdscript
func run_asset_prefilter(dirty_bounds: AABB = AABB()) -> RID
func build_candidate_route_buffer(anchor_state: RID) -> RID
func validate_candidate_routes(voxel_region_ids: PackedInt32Array = PackedInt32Array()) -> void
func get_candidate_voxel_sparses_by_asset() -> Dictionary # compat/debug view
```

### `VoxelPlacementGenerator.run_multi_asset()`

当前可选输入：

```gdscript
"candidate_voxel_sparses_by_asset": Dictionary {
    asset_index: PackedInt32Array(voxel_region_ids)  # compat key, voxel-region ids
}
```

行为：

- 如果传入 `candidate_voxel_sparses_by_asset`，每个 asset 只使用自己的 candidate voxel regions。
- 如果 asset 定义中直接带有 `candidate_voxel_sparses`，优先使用 asset 自己的兼容 candidate voxel-region 列表。
- 如果传入路由字典但某个 asset 没有 candidate voxel region，则该 asset 跳过并标记为 prefilter skip。
- 如果传入 `auto_object_manager`，会在 GPU scoring 前执行同类型 AutoObject 互斥预检。
- 如果同类型互斥预检移除了某个 asset 的所有 candidate voxel regions，则该 asset 跳过并标记为 `skipped_same_type_exclusion`。
- 如果未传入，则回退到当前行为。
- `run_minimal()` 不需要知道路由来源，只继续读取 `settings["candidate_voxel_sparses"]` 兼容 key。

---

## 实现步骤

| # | 任务 | 输出 |
| --- | --- | --- |
| 1 | 复用上游 prefilter 输出 GPU `AnchorState` / `anchor_topk` | `scripts/autoobject_probe_prefilter_gpu.gd` |
| 2 | 可选在 anchor 候选集内做 semantic rerank / route validation | `scripts/scene_voxel_runtime.gd` |
| 3 | 将存活 anchor routes 聚合为 GPU candidate voxel-region route buffer，并保留 `candidate_voxel_sparses_by_asset` 兼容视图 | `scripts/scene_voxel_runtime.gd` |
| 4 | 在 dirty update 中只重算受影响 anchors / voxel regions | `scripts/scene_voxel_runtime.gd` |
| 5 | 可选实现 route validation context | 计划 `shaders/precompute_voxel_context.glsl` / 计划 `shaders/precompute_target_scene_context.glsl` |
| 6 | 确认 `run_multi_asset()` 消费 `candidate_voxel_sparses_by_asset` | `scripts/voxel_placement_generator.gd` |
| 7 | 在 physical placement 前接入同类型 AutoObject 互斥预检 | `scripts/auto_object_manager.gd`、`scripts/voxel_placement_generator.gd`、`tools/test_voxel_same_type_exclusion_gate.gd` |
| 8 | 添加集成测试：prefilter route、semantic rerank、empty asset skip、dirty route 更新 | 计划 `tools/test_voxel_semantic_routing.gd` |

---

## 验收标准

- `score_voxel_tile.glsl` 不新增 semantic dot / MLP / target neighborhood pooling。
- 语义向量匹配只在每个 anchor 的候选资产内执行，不遍历全资产库。
- TargetSV_B 越界采样会投射到最近的有效 TargetSV_B voxel，不把边界外直接当作空白。
- full rebuild 能从上游 GPU `AnchorState` / route buffer 生成 candidate voxel regions；当前兼容视图为 `candidate_voxel_sparses_by_asset`。
- `candidate_voxel_sparses_by_asset` 对 probe 插值采样保守扩张，至少包含 1 voxel interpolation guard。
- dirty update 只更新 dirty / affected voxel regions。
- 空候选或低置信度候选不会进入 score。
- 同类型 `AutoObject` 在 `min_spacing` 互斥范围内时，对应 candidate voxel region 不进入 score。
- GPU route buffer / `candidate_voxel_sparses_by_asset` 兼容视图能减少 asset / voxel-region score dispatch 数量。
- 未启用候选路由时，现有 placement pipeline 行为不变。

---

## 项目 TODO

后续实现事项、暂缓项和 MLP 计划统一记录在通用 TODO 文档：

```text
docs/placement/voxel-semantic-routing-todo.md
```
