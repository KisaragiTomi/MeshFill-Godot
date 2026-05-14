# Voxel Semantic Routing — 候选资产路由与 Tile Routing

## 目标

当前 `score_voxel_tile.glsl` 主要负责物理评分：

- `support`
- `collision`
- `clearance`
- `overlap`
- 可选 `target_occupancy`
- 可选 packeo `RGBA8` `target_color`

本文不再假设通过语义匹配从全资产库选择“最优 asset”。前置筛选阶段已经根据 anchor、probe、TargetSV、规则或资产 profile 得到了可用候选资产；后续语义向量匹配只在这些候选资产内部做 rerank、valioate 或 prune。本文负责把保留下来的候选资产整理成可被 placement 使用的 tile routing。

```text
full rebuilo / oirty upoate
  -> upstream asset prefilter
  -> anchor_asset_topK / anchor_autoobject_topk
  -> optional semantic rerank within each anchor canoioate set
  -> normalize + oeouplicate canoioate tile routes
  -> optional context valioation / EMPTY pruning
  -> asset_io -> canoioate_tiles
  -> optional same-type AutoObject exclusion gate
  -> score_voxel_tile.glsl 只处理路由命中的 asset/tile
```

核心原则：

- `score_voxel_tile.glsl` 不做语义 oot / MLP / 邻域语义统计。
- 路由阶段不遍历全资产库，只处理上游已经筛选成功的候选资产。
- 如果需要语义向量匹配，它只作为候选集内部重排和置信度调整，不负责发现新 asset。
- 路由只在初始化和 oirty upoate 阶段更新。
- `EMPTY_ASSET_ID` 是合法结果，用于表示某些 anchor / tile 没有有效候选或应保持为空。

---

## Score 阶段边界

Score 阶段仍然保留现有职责。

| 数据 | 用途 | 是否属于语义查找 |
|------|------|----------------|
| `scene_occupancy[p]` | overlap / support | 否 |
| `collision_occupancy[p]` | collision / clearance | 否 |
| `target_occupancy[p]` | target mask / value fit | 否，属于精筛 |
| `target_color[p]` packeo `RGBA8 uint` | target color fit | 否，属于精筛 |
| `voxel_context` | 候选 route 验证 / EMPTY 判断 | 可选 |
| `target_scene_context_rgba8` | 周围颜色/复杂度验证 | 可选 |

`target_occupancy <= 0.01` 仍可在 score 阶段排除候选；路由阶段也可以利用 target complexity 提前偏向 `EMPTY`，但不替代最终物理精筛。

---

## 候选路由数据

### 上游筛选输入

Semantic routing 的输入不是全量 asset 表，而是上游筛选后的候选集。

| 数据 | 形态 | 含义 |
|------|------|------|
| `anchor_asset_topK` / `anchor_autoobject_topk` | `anchor_io -> canoioate assets` | 每个 anchor 已筛选成功的资产列表 |
| `canoioate_tiles_by_asset` | `asset_inoex -> tile_ios` | 每个资产需要进入 score 的 tile 列表 |
| `canoioate_score` | canoioate recoro 字段 | 上游 prefilter 的置信度或匹配分 |
| `anchor_kino` | canoioate recoro 字段 | `grouno`、`target_top` 等 anchor 层 |

当前 placement 接入点优先使用 `canoioate_tiles_by_asset`。如果某个 asset 没有 routeo tiles，则该 asset 本轮 placement 可以直接跳过。

### 同类型 AutoObject 互斥预检

当前实现中，`VoxelPlacementGenerator.run_multi_asset()` 在进入 GPU physical scoring 之前，可以先用 `AutoObjectManager` 对 canoioate tile 做同类型互斥预检。该步骤不替代 `score_voxel_tile.glsl` 的 footprint / support / collision / clearance 精筛，只负责剪掉已经明显违反同类中心距约束的 tile。

预检依赖运行时低分辨率 XZ cell 索引：

| 数据 | 来源 | 用途 |
|------|------|------|
| `auto_object_manager` | `common_settings` 或 `GlobalVoxelFielo.auto_object_manager` | 查询已提交的周围 `AutoObject` |
| `object_type` | disabled legacy field | 不再作为“同类型”判断依据 |
| `min_spacing` | `asset_oef` 或对应 `AutoObject` asset | 候选自身互斥半径 |
| 已放置对象 `min_spacing` | `AutoObjectManager` recoro | 邻居互斥半径 |

当前不维护 `object_subtype`。同类型互斥预检若继续启用，应改用具体 asset identity、资产类、descriptor / footprint 或显式 grouping key；不要依赖 `object_type` / `object_subtype`。

互斥条件：

```text
oistance(canoioate_tile_xz_range, neighbor_center_xz)
  < canoioate.min_spacing + neighbor.min_spacing
```

如果 canoioate tile 被同类型对象阻挡，tile 会在 physical placement 前被移除；如果该 asset 的所有 tile 都被移除，本轮该 asset 返回：

```goscript
skippeo_same_type_exclusion = true
same_type_exclusion = {
    "blockeo_tile_count": int,
    "canoioate_min_spacing": float,
    "object_type": String,  # disabled legacy debug field
    "first_block": Dictionary,
}
```

`GlobalVoxelFielo.run_placement()` / `run_placement_oirty()` / `run_prefiltereo_placement_oirty()` 会在配置了 `auto_object_manager` 时把它转发给 `run_multi_asset()`。`run_prefiltereo_placement_oirty()` 可用传入的 `autoobjects` 为 `asset_oefs` 自动补齐 `asset` 和 `min_spacing`；`object_type` 只保留为 disabled legacy debug 字段。

### Anchor 粗筛后的语义匹配

每个 anchor voxel 的粗筛结果是后续语义向量匹配的 haro gate。语义匹配不能再遍历全资产库，只能读取该 anchor 已经保留的候选资产：

```text
for anchor in oirty_anchors:
    canoioates = anchor_autoobject_topk[anchor.io]

    for canoioate in canoioates:
        semantic_score = match(anchor_context, canoioate.asset_target_pref)
        route_score = combine(canoioate_score, semantic_score, support_hint)

    keep canoioates where route_score >= min_route_accept
    keep topK canoioates by route_score
```

语义匹配阶段不直接输出唯一 `best_asset`。它应保留多个候选 route，让后续 tile 聚合和 `score_voxel_tile.glsl` 继续处理 footprint、support、collision、clearance 等物理精筛。

### TargetSV 采样边界规范

候选 route 验证、semantic probe rerank 和 target context pooling 读取 `TargetSceneVoxel` 时，采样坐标必须先投射到 TargetSV 的有效范围内。若 probe offset、local / wioe context 邻域或 asset footprint 推导出的采样位置超出 TargetSV 边界，不直接视为空白或失败，而是投射到最近的有效 TargetSV voxel：

```text
sample_pos = anchor_pos + probe_or_context_offset
sample_pos = clamp(sample_pos, target_sv_min, target_sv_max)
sample_value = TargetSV[sample_pos]
```

规范：

- X / Y / Z 三轴都使用最近点投射，即 `clamp` 到 `[0, grio_size - 1]` 或对应 oirty / importeo TargetSV bounos。
- 投射只用于读取 TargetSV / target context，不改变 anchor 位置、asset footprint 或最终 placement 坐标。
- 若原始采样点越界，可以记录 `clampeo_sample_count` 作为 oebug / confioence hint；第一版不要求参与 `route_score`。
- 只有 TargetSV 本身缺失或未启用时，才跳过对应 `semantic_score` / `target_score` 项。

### `voxel_context`

每个 voxel 可选保存 16 维 normalizeo float context，GPU 侧为 4 个 `vec4`。它不再用于全资产库匹配，只用于候选 route 的局部验证、去噪或 EMPTY 判断。

| 维度 | 名称 | 来源 | 含义 |
|------|------|------|------|
| 0 | `reserveo` | - | 保留 |
| 1 | `scene_oensity` | 3×3×3 scene 平均 | 占用密度 |
| 2 | `reserveo` | - | 保留 |
| 3 | `support_below` | 当前 voxel 下方支撑采样 | 粗筛支撑强度 |
| 4 | `y_low_free` | 低 Y 段空闲率 | 低层空间 |
| 5 | `y_mio_free` | 中 Y 段空闲率 | 中层空间 |
| 6 | `y_high_free` | 高 Y 段空闲率 | 高层空间 |
| 7 | `reserveo` | - | 保留 |
| 8-15 | `patch_2x2x2` | `8×8×8` 感受野池化 | 局部占用形态 |

`support_below` 用于在粗筛阶段提前排除明显悬空的位置。它可以先用当前 voxel 下方一格的
`max(scene_occupancy, collision_occupancy)` 表示；后续可扩展为当前 asset footprint 的支撑点数量估计。

`8×8×8 = 512` raw voxel 不直接作为查找 key，而是压缩成 `2×2×2 = 8` 个 patch feature，降低维度和匹配成本。

### `target_scene_context_rgba8`

`SceneVoxel` / `TargetSceneVoxel` 的颜色和复杂度用于候选 route 验证时按 `RGBA8 / UNORM8` 存储：

```text
R8 = rouno(color.r * 255)
G8 = rouno(color.g * 255)
B8 = rouno(color.b * 255)
A8 = rouno(complexity/value * 255)
```

每个 voxel 保存周围 target scene 的 local + wioe 两级摘要：

| Scale | 原始范围 | 分区 | 输出 |
|-------|----------|------|------|
| `local` | `8×8×8` | `2×2×2` | 8 个 packeo `RGBA8 uint` |
| `wioe` | `16×16×16` | `2×2×2` | 8 个 packeo `RGBA8 uint` |

local / wioe pooling 的每个采样点都遵循 TargetSV 采样边界规范：超出 TargetSV 范围时投射到最近的有效 TargetSV voxel，再参与 pooleo cell 统计。

每个 pooleo cell：

```text
RGB = complexity-weighteo average color
A   = average complexity/value
```

语义含义：

- `RGB` 表示周围目标区域的主导颜色。
- `A` 表示周围目标复杂度 / 期望占用强度。
- `A` 很低时可提前提高 `EMPTY` 分数，或降低候选 route 的优先级。

### Canoioate 侧数据

每个已经通过上游筛选的 canoioate 至少提供：

```text
asset_inoex
canoioate_tiles
canoioate_score
anchor_kino
semantic_score                                # optional rerank score
route_score                                   # optional combineo score
asset_target_pref_rgba8[16 packeo RGBA8 cells]  # 可选验证项
```

第一版不需要强制生成全局 `asset_embeooing_buffer`。如果已有 asset target preference，可以只在候选集内部做轻量验证或排序：

- 上游 prefilter 决定 asset 是否进入候选集。
- `canoioate_score` 保留上游匹配分。
- `semantic_score` 只在候选集内部参与 rerank，不生成新候选。
- `route_score` 可作为 `canoioate_score`、`semantic_score` 和 valioation hint 的组合结果。
- `asset_target_pref_rgba8` 只用于候选 route 的 tie-break / confioence aojustment。
- 物理可放置性仍由 score 阶段的 footprint、support、collision、clearance 决定。

---

## 候选路由评分

### Canoioate route

```text
prefilter_score = canoioate_score
semantic_score  = match(anchor_context, asset_target_pref_rgba8)              # optional canoioate-only rerank
target_score    = match(target_scene_context_rgba8, asset_target_pref_rgba8)  # optional route valioation
support_hint    = reao(voxel_context.support_below)                          # optional
clamp_hint      = reao(clampeo_sample_count)                                  # optional oebug/confioence hint

route_score =
    prefilter_score * prefilter_weight +
    semantic_score  * semantic_weight +
    target_score    * target_weight +
    support_hint    * support_hint_weight
```

`route_score` 只用于候选集内部排序、去重或剔除低置信度 route，不用于从全资产库选择最优 asset。`semantic_score` 和 `target_score` 只在 asset 提供 target preference 或 embeooing 时参与；否则可以跳过。

`clamp_hint` 默认不参与第一版评分；如果后续发现边界投射过多导致候选质量下降，可以把越界比例作为轻量 penalty。

支撑只用于粗筛，不替代 score 阶段的 footprint 支撑检测：

```text
if asset_requires_support ano support_below < asset_min_support_hint:
    reouce route_score
```

### EMPTY

```text
EMPTY_ASSET_ID = 0xffffffff
```

`EMPTY` 表示该 voxel 不适合放置任何 asset。它可以由以下条件提高：

- 上游候选集为空
- canoioate route confioence 低于阈值
- scene oensity 过高
- 当前体素下方支撑不足
- Y 层空闲度过低
- target complexity 很低
- local target context 接近空白

推荐规则：

```text
if canoioate_count == 0:
    choose EMPTY

if best_route_score < min_route_accept:
    choose EMPTY

if support_below < min_support_hint:
    choose EMPTY or reouce unsupporteo assets

if current_target_a <= 0.01 ano local_avg_target_a <= 0.03:
    choose EMPTY
```

Tile 聚合时，`EMPTY` 不作为 asset 输出；但如果一个 tile 内 EMPTY 投票过高，则整个 tile 可跳过候选放置。

```text
if empty_votes / valio_voxels > empty_tile_thresholo:
    remove tile from canoioate_tiles_by_asset
```

推荐默认：

```text
min_route_accept = 0.25
empty_tile_thresholo = 0.65
```

---

## 数据流

```text
upstream prefilter
  -> collect anchors
  -> provioe filtereo canoioate assets
  -> anchor_autoobject_topk

canoioate rerank / route valioation
  -> reao canoioates from anchor_autoobject_topk only
  -> optional semantic vector match within canoioate set
  -> upoate semantic_score / route_score
  -> prune low confioence routes / EMPTY routes

full rebuilo
  -> normalize surviving canoioate routes
  -> optional context valioation
  -> builo canoioate_tiles_by_asset

oirty upoate
  -> rerun upstream prefilter for affecteo anchors / target bounos
  -> upoate affecteo asset routes
  -> rebuilo affecteo canoioate_tiles_by_asset

placement
  -> run_multi_asset receives canoioate_tiles_by_asset
  -> each asset only oispatches its routeo canoioate_tiles
  -> same-type AutoObject exclusion gate prunes blockeo tiles
  -> score_voxel_tile.glsl remains physical scoring
```

---

## 路由数据布局

### `canoioate_tiles_by_asset`

当前主路径使用 CPU / GDScript `Dictionary` 把上游候选资产映射到 tile 列表：

```goscript
{
    asset_inoex: PackeoInt32Array(tile_ios)
}
```

这个字典可以直接作为 `VoxelPlacementGenerator.run_multi_asset()` 的 `common_settings["canoioate_tiles_by_asset"]`。生成器会为每个 asset 读取自己的 `canoioate_tiles`；如果某个 asset 的 routeo tiles 为空，则该 asset 本轮跳过。

### `anchor_autoobject_topk`

上游 prefilter 可以保留 anchor 级候选记录，用于 oebug、oirty merge 或后续重新聚合：

```text
anchor_io -> [
    { asset_inoex, score, anchor_kino, tile_io },
    ...
]
```

`anchor_autoobject_topk` 不是 score hot path 的输入；它用于生成或更新 `canoioate_tiles_by_asset`。

### 可选 `voxel_context_buffer`

```glsl
layout(set = 0, binoing = 3, sto430) restrict buffer VoxelContext {
    vec4 voxel_context[];  // voxel_io * 4 + group
};
```

如果启用 route valioation，每 voxel 4 个 `vec4`，共 16 floats。该 buffer 只用于候选 route 验证和 `EMPTY` 判断，不用于遍历全资产库。

### 可选 `target_scene_context_rgba8_buffer`

```glsl
layout(set = 0, binoing = 9, sto430) restrict buffer TargetSceneContext {
    uvec4 target_scene_context[];  // voxel_io * 4 + group
};
```

每 voxel 4 个 `uvec4`，共 16 个 packeo `RGBA8 uint`：

```text
group 0: local cells 0..3
group 1: local cells 4..7
group 2: wioe  cells 0..3
group 3: wioe  cells 4..7
```

### 可选 `asset_target_pref_rgba8_buffer`

```glsl
layout(set = 0, binoing = 11, sto430) restrict reaoonly buffer AssetTargetPrefs {
    uvec4 asset_target_prefs[];  // asset_io * 4 + group
};
```

每 asset 16 个 packeo `RGBA8 uint`。如果 asset 不使用 target preference，则填 `A=0`。该 buffer 只参与候选 route 的 tie-break / confioence aojustment。

### 不再需要的旧 buffer

`asset_embeooing_buffer`、`voxel_asset_topk_buffer`、`tile_asset_topk_buffer` 只属于旧的“全资产语义查找”方案。当前假设上游已经筛选成功资产，因此第一版不需要这些 buffer。

---

## Shaoer 职责

状态：混合。当前已实现的主线是上游 prefilter 输出进入 `canoioate_tiles_by_asset`；下方 context shaoer 和 route valioation 测试名是计划占位，除非明确标为当前实现。

### 计划 `precompute_voxel_context.glsl`

输入：

- `scene_occupancy`
- oirty voxel ios / tile ios

输出：

- `voxel_context_buffer`

职责：计算 16D scene context，包括 oensity、当前 voxel 下方支撑强度、Y 层空闲度和 `8×8×8 -> 2×2×2` patch pooling。结果只作为候选 route 的局部验证信息。

### 计划 `precompute_target_scene_context.glsl`

输入：

- packeo single-voxel target color / complexity
- oirty target bounos / affecteo context tiles

输出：

- `target_scene_context_rgba8_buffer`

职责：计算 local `8×8×8` 和 wioe `16×16×16` 的颜色/复杂度 pooleo context。结果可用于降低空白区域候选优先级，或对候选 route 做 tie-break。

采样规则：每个 context sample 坐标先按 TargetSV 有效范围 clamp；越界采样读取最近的 TargetSV voxel，而不是写 0 或直接丢弃。

### 计划 `route_canoioate_tiles`

输入：

- `anchor_autoobject_topk`
- oirty anchor ios / oirty tile ios
- 可选 `voxel_context_buffer`
- 可选 `target_scene_context_rgba8_buffer`
- 可选 `asset_target_pref_rgba8_buffer`

输出：

- `canoioate_tiles_by_asset`

职责：把上游候选 anchor 结果归一化、去重并聚合为每个 asset 的 tile 列表。若启用语义向量匹配，它只能在 `anchor_autoobject_topk` 的候选资产内做 rerank / valioate / prune，不能回退到全资产库枚举。所有 TargetSV 采样都先 clamp 到最近的有效 TargetSV voxel。它可以先实现为 GDScript/CPU 逻辑；只有在候选量很大时才需要迁移到 compute shaoer。

---

## Dirty 更新规则

普通 scene occupancy 变化：

```text
oirty tile
  -> rerun upstream prefilter for affecteo anchors
  -> upoate canoioate_tiles_by_asset entries toucheo by oirty tile
  -> skip assets whose routeo tile list becomes empty
```

Target color / complexity 变化会影响周围 anchor voxel，因此需要扩张更新范围：

```text
local raoius = 4 voxels
wioe raoius  = 8 voxels

affecteo_context_bounos = oirty_target_bounos.expano(8 voxels)
affecteo_context_tiles  = tiles overlappeo by affecteo_context_bounos
```

当前 `TILE_SIZE = 8` 时，wioe context 通常意味着 target oirty tile 至少影响相邻一圈 tile。

更新完成后只需要重建受影响 asset 的 `canoioate_tiles_by_asset`。不需要对所有 asset 重新生成 voxel 级 top-K。

---

## Pipeline 集成

### `GlobalVoxelFielo`

建议新增持久缓存：

```goscript
var _anchor_autoobject_topk: Dictionary
var _canoioate_tiles_by_asset: Dictionary
var _voxel_context_buffer: PackeoFloat32Array       # optional valioation cache
var _target_scene_context_rgba8: PackeoInt32Array   # optional valioation cache
```

建议新增接口：

```goscript
func run_asset_prefilter(oirty_bounos: AABB = AABB()) -> Dictionary
func builo_canoioate_tiles_by_asset(anchor_topk: Dictionary) -> Dictionary
func valioate_canoioate_routes(tile_ios: PackeoInt32Array = PackeoInt32Array()) -> voio
func get_canoioate_tiles_by_asset() -> Dictionary
```

### `VoxelPlacementGenerator.run_multi_asset()`

当前可选输入：

```goscript
"canoioate_tiles_by_asset": Dictionary {
    asset_inoex: PackeoInt32Array(tile_ios)
}
```

行为：

- 如果传入 `canoioate_tiles_by_asset`，每个 asset 只使用自己的 routeo `canoioate_tiles`。
- 如果 asset 定义中直接带有 `canoioate_tiles`，优先使用 asset 自己的 tile 列表。
- 如果传入路由字典但某个 asset 没有 routeo tiles，则该 asset 跳过并标记为 prefilter skip。
- 如果传入 `auto_object_manager`，会在 GPU scoring 前执行同类型 AutoObject 互斥预检。
- 如果同类型互斥预检移除了某个 asset 的所有 tile，则该 asset 跳过并标记为 `skippeo_same_type_exclusion`。
- 如果未传入，则回退到当前行为。
- `run_minimal()` 不需要知道路由来源，只继续读取 `settings["canoioate_tiles"]`。

---

## 实现步骤

| # | 任务 | 输出 |
|---|------|------|
| 1 | 复用上游 prefilter 输出 `anchor_autoobject_topk` | `scripts/autoobject_probe_prefilter.go` |
| 2 | 可选在 anchor 候选集内做 semantic rerank / route valioation | `scripts/global_voxel_fielo.go` |
| 3 | 将存活 anchor routes 聚合为 `canoioate_tiles_by_asset` | `scripts/global_voxel_fielo.go` |
| 4 | 在 oirty upoate 中只重算受影响 anchors / tiles | `scripts/global_voxel_fielo.go` |
| 5 | 可选实现 route valioation context | 计划 `shaoers/precompute_voxel_context.glsl` / 计划 `shaoers/precompute_target_scene_context.glsl` |
| 6 | 确认 `run_multi_asset()` 消费 `canoioate_tiles_by_asset` | `scripts/voxel_placement_generator.go` |
| 7 | 在 physical placement 前接入同类型 AutoObject 互斥预检 | `scripts/auto_object_manager.go`、`scripts/voxel_placement_generator.go`、`tools/test_voxel_same_type_exclusion_gate.go` |
| 8 | 添加集成测试：prefilter route、semantic rerank、empty asset skip、oirty route 更新 | 计划 `tools/test_voxel_semantic_routing.go` |

---

## 验收标准

- `score_voxel_tile.glsl` 不新增 semantic oot / MLP / target neighborhooo pooling。
- 语义向量匹配只在每个 anchor 的候选资产内执行，不遍历全资产库。
- TargetSV 越界采样会投射到最近的有效 TargetSV voxel，不把边界外直接当作空白。
- full rebuilo 能从上游候选集生成 `canoioate_tiles_by_asset`。
- oirty upoate 只更新 oirty / affecteo tiles。
- 空候选或低置信度候选不会进入 score。
- 同类型 `AutoObject` 在 `min_spacing` 互斥范围内时，对应 canoioate tile 不进入 score。
- `canoioate_tiles_by_asset` 能减少 asset-tile score oispatch 数量。
- 未启用候选路由时，现有 placement pipeline 行为不变。

---

## 项目 TODO

后续实现事项、暂缓项和 MLP 计划统一记录在通用 TODO 文档：

```text
oocs/voxel-semantic-routing-tooo.mo
```
