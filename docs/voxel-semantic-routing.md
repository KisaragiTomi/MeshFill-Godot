# Voxel Semantic Routing — 候选资产路由与 Tile Routing

## 目标

当前 `score_voxel_tile.glsl` 主要负责物理评分：

- `support`
- `collision`
- `clearance`
- `overlap`
- 可选 `target_occupancy`
- 可选 packed `RGBA8` `target_color`

本文不再假设通过语义匹配从全资产库选择“最优 asset”。前置筛选阶段已经根据 anchor、probe、TargetSV、规则或资产 profile 得到了可用候选资产；后续语义向量匹配只在这些候选资产内部做 rerank、validate 或 prune。本文负责把保留下来的候选资产整理成可被 placement 使用的 tile routing。

```text
full rebuild / dirty update
  -> upstream asset prefilter
  -> anchor_asset_topK / anchor_autoobject_topk
  -> optional semantic rerank within each anchor candidate set
  -> normalize + deduplicate candidate tile routes
  -> optional context validation / EMPTY pruning
  -> asset_id -> candidate_tiles
  -> score_voxel_tile.glsl 只处理路由命中的 asset/tile
```

核心原则：

- `score_voxel_tile.glsl` 不做语义 dot / MLP / 邻域语义统计。
- 路由阶段不遍历全资产库，只处理上游已经筛选成功的候选资产。
- 如果需要语义向量匹配，它只作为候选集内部重排和置信度调整，不负责发现新 asset。
- 路由只在初始化和 dirty update 阶段更新。
- `EMPTY_ASSET_ID` 是合法结果，用于表示某些 anchor / tile 没有有效候选或应保持为空。

---

## Score 阶段边界

Score 阶段仍然保留现有职责。

| 数据 | 用途 | 是否属于语义查找 |
|------|------|----------------|
| `scene_occupancy[p]` | overlap / support | 否 |
| `collision_occupancy[p]` | collision / clearance | 否 |
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
|------|------|------|
| `anchor_asset_topK` / `anchor_autoobject_topk` | `anchor_id -> candidate assets` | 每个 anchor 已筛选成功的资产列表 |
| `candidate_tiles_by_asset` | `asset_index -> tile_ids` | 每个资产需要进入 score 的 tile 列表 |
| `candidate_score` | candidate record 字段 | 上游 prefilter 的置信度或匹配分 |
| `anchor_kind` | candidate record 字段 | `ground`、`target_top` 等 anchor 层 |

当前 placement 接入点优先使用 `candidate_tiles_by_asset`。如果某个 asset 没有 routed tiles，则该 asset 本轮 placement 可以直接跳过。

### Anchor 粗筛后的语义匹配

每个 anchor voxel 的粗筛结果是后续语义向量匹配的 hard gate。语义匹配不能再遍历全资产库，只能读取该 anchor 已经保留的候选资产：

```text
for anchor in dirty_anchors:
    candidates = anchor_autoobject_topk[anchor.id]

    for candidate in candidates:
        semantic_score = match(anchor_context, candidate.asset_target_pref)
        route_score = combine(candidate_score, semantic_score, support_hint)

    keep candidates where route_score >= min_route_accept
    keep topK candidates by route_score
```

语义匹配阶段不直接输出唯一 `best_asset`。它应保留多个候选 route，让后续 tile 聚合和 `score_voxel_tile.glsl` 继续处理 footprint、support、collision、clearance 等物理精筛。

### TargetSV 采样边界规范

候选 route 验证、semantic probe rerank 和 target context pooling 读取 `TargetSceneVoxel` 时，采样坐标必须先投射到 TargetSV 的有效范围内。若 probe offset、local / wide context 邻域或 asset footprint 推导出的采样位置超出 TargetSV 边界，不直接视为空白或失败，而是投射到最近的有效 TargetSV voxel：

```text
sample_pos = anchor_pos + probe_or_context_offset
sample_pos = clamp(sample_pos, target_sv_min, target_sv_max)
sample_value = TargetSV[sample_pos]
```

规范：

- X / Y / Z 三轴都使用最近点投射，即 `clamp` 到 `[0, grid_size - 1]` 或对应 dirty / imported TargetSV bounds。
- 投射只用于读取 TargetSV / target context，不改变 anchor 位置、asset footprint 或最终 placement 坐标。
- 若原始采样点越界，可以记录 `clamped_sample_count` 作为 debug / confidence hint；第一版不要求参与 `route_score`。
- 只有 TargetSV 本身缺失或未启用时，才跳过对应 `semantic_score` / `target_score` 项。

### `voxel_context`

每个 voxel 可选保存 16 维 normalized float context，GPU 侧为 4 个 `vec4`。它不再用于全资产库匹配，只用于候选 route 的局部验证、去噪或 EMPTY 判断。

| 维度 | 名称 | 来源 | 含义 |
|------|------|------|------|
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
`max(scene_occupancy, collision_occupancy)` 表示；后续可扩展为当前 asset footprint 的支撑点数量估计。

`8×8×8 = 512` raw voxel 不直接作为查找 key，而是压缩成 `2×2×2 = 8` 个 patch feature，降低维度和匹配成本。

### `target_scene_context_rgba8`

`SceneVoxel` / `TargetSceneVoxel` 的颜色和复杂度用于候选 route 验证时按 `RGBA8 / UNORM8` 存储：

```text
R8 = round(color.r * 255)
G8 = round(color.g * 255)
B8 = round(color.b * 255)
A8 = round(complexity/value * 255)
```

每个 voxel 保存周围 target scene 的 local + wide 两级摘要：

| Scale | 原始范围 | 分区 | 输出 |
|-------|----------|------|------|
| `local` | `8×8×8` | `2×2×2` | 8 个 packed `RGBA8 uint` |
| `wide` | `16×16×16` | `2×2×2` | 8 个 packed `RGBA8 uint` |

local / wide pooling 的每个采样点都遵循 TargetSV 采样边界规范：超出 TargetSV 范围时投射到最近的有效 TargetSV voxel，再参与 pooled cell 统计。

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
candidate_tiles
candidate_score
anchor_kind
semantic_score                                # optional rerank score
route_score                                   # optional combined score
asset_target_pref_rgba8[16 packed RGBA8 cells]  # 可选验证项
```

第一版不需要强制生成全局 `asset_embedding_buffer`。如果已有 asset target preference，可以只在候选集内部做轻量验证或排序：

- 上游 prefilter 决定 asset 是否进入候选集。
- `candidate_score` 保留上游匹配分。
- `semantic_score` 只在候选集内部参与 rerank，不生成新候选。
- `route_score` 可作为 `candidate_score`、`semantic_score` 和 validation hint 的组合结果。
- `asset_target_pref_rgba8` 只用于候选 route 的 tie-break / confidence adjustment。
- 物理可放置性仍由 score 阶段的 footprint、support、collision、clearance 决定。

---

## 候选路由评分

### Candidate route

```text
prefilter_score = candidate_score
semantic_score  = match(anchor_context, asset_target_pref_rgba8)              # optional candidate-only rerank
target_score    = match(target_scene_context_rgba8, asset_target_pref_rgba8)  # optional route validation
support_hint    = read(voxel_context.support_below)                          # optional
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

Tile 聚合时，`EMPTY` 不作为 asset 输出；但如果一个 tile 内 EMPTY 投票过高，则整个 tile 可跳过候选放置。

```text
if empty_votes / valid_voxels > empty_tile_threshold:
    remove tile from candidate_tiles_by_asset
```

推荐默认：

```text
min_route_accept = 0.25
empty_tile_threshold = 0.65
```

---

## 数据流

```text
upstream prefilter
  -> collect anchors
  -> provide filtered candidate assets
  -> anchor_autoobject_topk

candidate rerank / route validation
  -> read candidates from anchor_autoobject_topk only
  -> optional semantic vector match within candidate set
  -> update semantic_score / route_score
  -> prune low confidence routes / EMPTY routes

full rebuild
  -> normalize surviving candidate routes
  -> optional context validation
  -> build candidate_tiles_by_asset

dirty update
  -> rerun upstream prefilter for affected anchors / target bounds
  -> update affected asset routes
  -> rebuild affected candidate_tiles_by_asset

placement
  -> run_multi_asset receives candidate_tiles_by_asset
  -> each asset only dispatches its routed candidate_tiles
  -> score_voxel_tile.glsl remains physical scoring
```

---

## 路由数据布局

### `candidate_tiles_by_asset`

当前主路径使用 CPU / GDScript `Dictionary` 把上游候选资产映射到 tile 列表：

```gdscript
{
    asset_index: PackedInt32Array(tile_ids)
}
```

这个字典可以直接作为 `VoxelPlacementGenerator.run_multi_asset()` 的 `common_settings["candidate_tiles_by_asset"]`。生成器会为每个 asset 读取自己的 `candidate_tiles`；如果某个 asset 的 routed tiles 为空，则该 asset 本轮跳过。

### `anchor_autoobject_topk`

上游 prefilter 可以保留 anchor 级候选记录，用于 debug、dirty merge 或后续重新聚合：

```text
anchor_id -> [
    { asset_index, score, anchor_kind, tile_id },
    ...
]
```

`anchor_autoobject_topk` 不是 score hot path 的输入；它用于生成或更新 `candidate_tiles_by_asset`。

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

`asset_embedding_buffer`、`voxel_asset_topk_buffer`、`tile_asset_topk_buffer` 只属于旧的“全资产语义查找”方案。当前假设上游已经筛选成功资产，因此第一版不需要这些 buffer。

---

## Shader 职责

### 可选 `precompute_voxel_context.glsl`

输入：

- `scene_occupancy`
- dirty voxel ids / tile ids

输出：

- `voxel_context_buffer`

职责：计算 16D scene context，包括 density、当前 voxel 下方支撑强度、Y 层空闲度和 `8×8×8 -> 2×2×2` patch pooling。结果只作为候选 route 的局部验证信息。

### 可选 `precompute_target_scene_context.glsl`

输入：

- packed single-voxel target color / complexity
- dirty target bounds / affected context tiles

输出：

- `target_scene_context_rgba8_buffer`

职责：计算 local `8×8×8` 和 wide `16×16×16` 的颜色/复杂度 pooled context。结果可用于降低空白区域候选优先级，或对候选 route 做 tie-break。

采样规则：每个 context sample 坐标先按 TargetSV 有效范围 clamp；越界采样读取最近的 TargetSV voxel，而不是写 0 或直接丢弃。

### `route_candidate_tiles`

输入：

- `anchor_autoobject_topk`
- dirty anchor ids / dirty tile ids
- 可选 `voxel_context_buffer`
- 可选 `target_scene_context_rgba8_buffer`
- 可选 `asset_target_pref_rgba8_buffer`

输出：

- `candidate_tiles_by_asset`

职责：把上游候选 anchor 结果归一化、去重并聚合为每个 asset 的 tile 列表。若启用语义向量匹配，它只能在 `anchor_autoobject_topk` 的候选资产内做 rerank / validate / prune，不能回退到全资产库枚举。所有 TargetSV 采样都先 clamp 到最近的有效 TargetSV voxel。它可以先实现为 GDScript/CPU 逻辑；只有在候选量很大时才需要迁移到 compute shader。

---

## Dirty 更新规则

普通 scene occupancy 变化：

```text
dirty tile
  -> rerun upstream prefilter for affected anchors
  -> update candidate_tiles_by_asset entries touched by dirty tile
  -> skip assets whose routed tile list becomes empty
```

Target color / complexity 变化会影响周围 anchor voxel，因此需要扩张更新范围：

```text
local radius = 4 voxels
wide radius  = 8 voxels

affected_context_bounds = dirty_target_bounds.expand(8 voxels)
affected_context_tiles  = tiles overlapped by affected_context_bounds
```

当前 `TILE_SIZE = 8` 时，wide context 通常意味着 target dirty tile 至少影响相邻一圈 tile。

更新完成后只需要重建受影响 asset 的 `candidate_tiles_by_asset`。不需要对所有 asset 重新生成 voxel 级 top-K。

---

## Pipeline 集成

### `GlobalVoxelField`

建议新增持久缓存：

```gdscript
var _anchor_autoobject_topk: Dictionary
var _candidate_tiles_by_asset: Dictionary
var _voxel_context_buffer: PackedFloat32Array       # optional validation cache
var _target_scene_context_rgba8: PackedInt32Array   # optional validation cache
```

建议新增接口：

```gdscript
func run_asset_prefilter(dirty_bounds: AABB = AABB()) -> Dictionary
func build_candidate_tiles_by_asset(anchor_topk: Dictionary) -> Dictionary
func validate_candidate_routes(tile_ids: PackedInt32Array = PackedInt32Array()) -> void
func get_candidate_tiles_by_asset() -> Dictionary
```

### `VoxelPlacementGenerator.run_multi_asset()`

当前可选输入：

```gdscript
"candidate_tiles_by_asset": Dictionary {
    asset_index: PackedInt32Array(tile_ids)
}
```

行为：

- 如果传入 `candidate_tiles_by_asset`，每个 asset 只使用自己的 routed `candidate_tiles`。
- 如果 asset 定义中直接带有 `candidate_tiles`，优先使用 asset 自己的 tile 列表。
- 如果传入路由字典但某个 asset 没有 routed tiles，则该 asset 跳过并标记为 prefilter skip。
- 如果未传入，则回退到当前行为。
- `run_minimal()` 不需要知道路由来源，只继续读取 `settings["candidate_tiles"]`。

---

## 实现步骤

| # | 任务 | 输出 |
|---|------|------|
| 1 | 复用上游 prefilter 输出 `anchor_autoobject_topk` | `scripts/autoobject_probe_prefilter.gd` |
| 2 | 可选在 anchor 候选集内做 semantic rerank / route validation | `scripts/global_voxel_field.gd` |
| 3 | 将存活 anchor routes 聚合为 `candidate_tiles_by_asset` | `scripts/global_voxel_field.gd` |
| 4 | 在 dirty update 中只重算受影响 anchors / tiles | `scripts/global_voxel_field.gd` |
| 5 | 可选实现 route validation context | `shaders/precompute_voxel_context.glsl` / `shaders/precompute_target_scene_context.glsl` |
| 6 | 确认 `run_multi_asset()` 消费 `candidate_tiles_by_asset` | `scripts/voxel_placement_generator.gd` |
| 7 | 添加集成测试：prefilter route、semantic rerank、empty asset skip、dirty route 更新 | `tools/test_voxel_semantic_routing.gd` |

---

## 验收标准

- `score_voxel_tile.glsl` 不新增 semantic dot / MLP / target neighborhood pooling。
- 语义向量匹配只在每个 anchor 的候选资产内执行，不遍历全资产库。
- TargetSV 越界采样会投射到最近的有效 TargetSV voxel，不把边界外直接当作空白。
- full rebuild 能从上游候选集生成 `candidate_tiles_by_asset`。
- dirty update 只更新 dirty / affected tiles。
- 空候选或低置信度候选不会进入 score。
- `candidate_tiles_by_asset` 能减少 asset-tile score dispatch 数量。
- 未启用候选路由时，现有 placement pipeline 行为不变。

---

## 项目 TODO

后续实现事项、暂缓项和 MLP 计划统一记录在通用 TODO 文档：

```text
docs/voxel-semantic-routing-todo.md
```
