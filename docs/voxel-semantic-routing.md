# Voxel Semantic Routing — 语义查找与 Tile Routing

## 目标

当前 `score_voxel_tile.glsl` 主要负责物理评分：

- `support`
- `collision`
- `clearance`
- `overlap`
- 可选 `target_occupancy`
- 可选 packed `RGBA8` `target_color`

语义查找的目标是：在进入 score hot path 之前，先判断 **哪些 asset 适合哪些 voxel / tile**，从而减少不必要的 asset-tile dispatch。

```text
full rebuild / dirty update
  -> precompute voxel semantic context
  -> voxel_context × asset_embedding
  -> voxel_asset_topK
  -> tile_asset_topK
  -> asset_id -> candidate_tiles
  -> score_voxel_tile.glsl 只处理语义命中的 asset/tile
```

核心原则：

- `score_voxel_tile.glsl` 不做语义 dot / MLP / 邻域语义统计。
- 语义只在初始化和 dirty update 阶段更新。
- `EMPTY_ASSET_ID` 是合法结果，用于表示某些 voxel / tile 应保持为空。

---

## Score 阶段边界

Score 阶段仍然保留现有职责。

| 数据 | 用途 | 是否属于语义查找 |
|------|------|----------------|
| `scene_occupancy[p]` | overlap / support | 否 |
| `collision_occupancy[p]` | collision / clearance | 否 |
| `target_occupancy[p]` | target mask / value fit | 否，属于精筛 |
| `target_color[p]` packed `RGBA8 uint` | target color fit | 否，属于精筛 |
| `voxel_context` | asset 语义查找 | 是 |
| `target_scene_context_rgba8` | 周围颜色/复杂度语义查找 | 是 |

`target_occupancy <= 0.01` 仍可在 score 阶段排除候选；语义查找阶段也可以利用 target complexity 提前偏向 `EMPTY`，但不替代最终物理精筛。

---

## 语义查找数据

### `voxel_context`

每个 voxel 保存 16 维 normalized float context，GPU 侧为 4 个 `vec4`。

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

`SceneVoxel` / `TargetSceneVoxel` 的颜色和复杂度用于语义查找时按 `RGBA8 / UNORM8` 存储：

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

每个 pooled cell：

```text
RGB = complexity-weighted average color
A   = average complexity/value
```

语义含义：

- `RGB` 表示周围目标区域的主导颜色。
- `A` 表示周围目标复杂度 / 期望占用强度。
- `A` 很低时可提前提高 `EMPTY` 分数。

### Asset 侧数据

每个 asset 至少提供：

```text
asset_embedding[16 floats]
asset_target_pref_rgba8[16 packed RGBA8 cells]  # 可选
```

第一版可以从 `AutoVoxelProfile` / asset metadata 生成：

- affected bands -> `y_low_free / y_mid_free / y_high_free`
- support requirement -> `support_below`
- collision footprint -> `patch_2x2x2`
- preferred color / complexity -> `asset_target_pref_rgba8`

---

## 语义评分

### Asset 匹配

```text
scene_score  = dot(voxel_context, asset_embedding)
target_score = match(target_scene_context_rgba8, asset_target_pref_rgba8)

semantic_score =
    scene_score  * scene_weight +
    target_score * target_weight
```

`target_score` 只在 asset 提供 target preference 时参与；否则可以设为 0 或跳过。

支撑只用于粗筛，不替代 score 阶段的 footprint 支撑检测：

```text
if asset_requires_support and support_below < asset_min_support_hint:
    reduce semantic_score
```

### EMPTY

```text
EMPTY_ASSET_ID = 0xffffffff
```

`EMPTY` 表示该 voxel 不适合放置任何 asset。它可以由以下条件提高：

- scene density 过高
- 当前体素下方支撑不足
- Y 层空闲度过低
- asset 相似度低于 `min_semantic_accept`
- target complexity 很低
- local target context 接近空白

推荐规则：

```text
if best_asset_score < min_semantic_accept:
    choose EMPTY

if support_below < min_support_hint:
    choose EMPTY or reduce unsupported assets

if current_target_a <= 0.01 and local_avg_target_a <= 0.03:
    choose EMPTY
```

Tile 聚合时，`EMPTY` 不作为 asset 输出；但如果一个 tile 内 EMPTY 投票过高，则整个 tile 可跳过语义放置。

```text
if empty_votes / valid_voxels > empty_tile_threshold:
    tile_asset_topK = [EMPTY, EMPTY, EMPTY, EMPTY]
```

推荐默认：

```text
min_semantic_accept = 0.25
empty_tile_threshold = 0.65
```

---

## 数据流

```text
CPU init
  -> build asset_embedding_buffer
  -> build asset_target_pref_rgba8_buffer

full rebuild
  -> precompute_voxel_context.glsl
  -> precompute_target_scene_context.glsl
  -> select_voxel_assets.glsl
  -> reduce_tile_assets.glsl
  -> build semantic_routing

dirty update
  -> update dirty voxel_context
  -> update affected target_scene_context_rgba8
  -> update affected voxel_asset_topK
  -> update affected tile_asset_topK
  -> rebuild affected semantic_routing

placement
  -> run_multi_asset receives semantic_routing
  -> each asset only dispatches its routed candidate_tiles
  -> score_voxel_tile.glsl remains physical scoring
```

---

## GPU Buffer 布局

### `voxel_context_buffer` — binding 3

```glsl
layout(set = 0, binding = 3, std430) restrict buffer VoxelContext {
    vec4 voxel_context[];  // voxel_id * 4 + group
};
```

每 voxel 4 个 `vec4`，共 16 floats。

### `voxel_asset_topk_buffer` — binding 4

```glsl
layout(set = 0, binding = 4, std430) restrict buffer VoxelAssetTopK {
    uvec4 voxel_asset_topk[];
};
```

每 voxel 最多 top-4 asset id，可包含 `EMPTY_ASSET_ID`。

### `tile_asset_topk_buffer` — binding 5

```glsl
layout(set = 0, binding = 5, std430) restrict buffer TileAssetTopK {
    uvec4 tile_asset_topk[];
};
```

每 tile 最多 top-4 asset id，用于生成 `asset_id -> candidate_tiles`。

### `target_scene_context_rgba8_buffer` — binding 9

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

### `asset_embedding_buffer` — binding 10

```glsl
layout(set = 0, binding = 10, std430) restrict readonly buffer AssetEmbeddings {
    vec4 embeddings[];  // asset_id * 4 + group
};
```

每 asset 4 个 `vec4`，共 16 floats。

### `asset_target_pref_rgba8_buffer` — binding 11

```glsl
layout(set = 0, binding = 11, std430) restrict readonly buffer AssetTargetPrefs {
    uvec4 asset_target_prefs[];  // asset_id * 4 + group
};
```

每 asset 16 个 packed `RGBA8 uint`。如果 asset 不使用 target preference，则填 `A=0`。

---

## Shader 职责

### `precompute_voxel_context.glsl`

输入：

- `scene_occupancy`
- dirty voxel ids / tile ids

输出：

- `voxel_context_buffer`

职责：计算 16D scene context，包括 density、当前 voxel 下方支撑强度、Y 层空闲度和 `8×8×8 -> 2×2×2` patch pooling。

### `precompute_target_scene_context.glsl`

输入：

- packed single-voxel target color / complexity
- dirty target bounds / affected context tiles

输出：

- `target_scene_context_rgba8_buffer`

职责：计算 local `8×8×8` 和 wide `16×16×16` 的颜色/复杂度 pooled context。

### `select_voxel_assets.glsl`

输入：

- `voxel_context_buffer`
- `target_scene_context_rgba8_buffer`
- `asset_embedding_buffer`
- `asset_target_pref_rgba8_buffer`

输出：

- `voxel_asset_topk_buffer`

职责：每 voxel 遍历 assets，计算 semantic score，输出 top-N asset id；必要时输出 `EMPTY_ASSET_ID`。

### `reduce_tile_assets.glsl`

输入：

- `voxel_asset_topk_buffer`
- dirty tile ids

输出：

- `tile_asset_topk_buffer`

职责：把 tile 内 512 个 voxel 的 top-N 结果投票聚合成 tile top-K。

---

## Dirty 更新规则

普通 scene occupancy 变化：

```text
dirty tile
  -> update voxel_context inside dirty tile
  -> update voxel_asset_topK inside dirty tile
  -> reduce tile_asset_topK for dirty tile
```

Target color / complexity 变化会影响周围 anchor voxel，因此需要扩张更新范围：

```text
local radius = 4 voxels
wide radius  = 8 voxels

affected_context_bounds = dirty_target_bounds.expand(8 voxels)
affected_context_tiles  = tiles overlapped by affected_context_bounds
```

当前 `TILE_SIZE = 8` 时，wide context 通常意味着 target dirty tile 至少影响相邻一圈 tile。

---

## Pipeline 集成

### `GlobalVoxelField`

建议新增持久缓存：

```gdscript
var semantic_db: VoxelSemanticDB
var _voxel_context_buffer: PackedFloat32Array
var _target_scene_context_rgba8: PackedInt32Array
var _voxel_asset_topk: PackedInt32Array
var _tile_asset_topk: PackedInt32Array
var _semantic_routing: Dictionary
```

建议新增接口：

```gdscript
func precompute_voxel_context(tile_ids: PackedInt32Array = PackedInt32Array()) -> void
func precompute_target_scene_context(tile_ids: PackedInt32Array = PackedInt32Array()) -> void
func select_voxel_assets(top_n: int = 4, tile_ids: PackedInt32Array = PackedInt32Array()) -> void
func reduce_tile_assets(top_k: int = 4, tile_ids: PackedInt32Array = PackedInt32Array()) -> void
func build_semantic_routing(tile_ids: PackedInt32Array = PackedInt32Array()) -> Dictionary
func get_semantic_routing() -> Dictionary
```

### `VoxelPlacementGenerator.run_multi_asset()`

新增可选输入：

```gdscript
"semantic_routing": Dictionary {
    asset_index: PackedInt32Array(tile_ids)
}
```

行为：

- 如果传入 `semantic_routing`，每个 asset 只使用自己的 routed `candidate_tiles`。
- 如果未传入，则回退到当前行为。
- `run_minimal()` 不需要知道语义查找，只继续读取 `settings["candidate_tiles"]`。

---

## 实现步骤

| # | 任务 | 输出 |
|---|------|------|
| 1 | 创建 `VoxelSemanticDB`，负责 asset embedding / target preference 注册与导出 | `scripts/voxel_semantic_db.gd` |
| 2 | 实现 scene context 预计算 | `shaders/precompute_voxel_context.glsl` |
| 3 | 实现 target color / complexity context 预计算 | `shaders/precompute_target_scene_context.glsl` |
| 4 | 实现 voxel 级 asset top-N 查找 | `shaders/select_voxel_assets.glsl` |
| 5 | 实现 tile 级 asset top-K 聚合 | `shaders/reduce_tile_assets.glsl` |
| 6 | 扩展 `GlobalVoxelField`，支持 full rebuild 与 dirty semantic update | `scripts/global_voxel_field.gd` |
| 7 | 扩展 `run_multi_asset()`，支持 `semantic_routing` | `scripts/voxel_placement_generator.gd` |
| 8 | 添加集成测试：full init、dirty update、target context、routing dispatch 削减 | `tools/test_voxel_semantic_routing.gd` |

---

## 验收标准

- `score_voxel_tile.glsl` 不新增 semantic dot / MLP / target neighborhood pooling。
- full rebuild 能生成 `voxel_context`、`target_scene_context_rgba8`、`voxel_asset_topK`、`tile_asset_topK`。
- dirty update 只更新 dirty / affected tiles。
- `EMPTY_ASSET_ID` 能阻止不适合放置的 tile 进入 score。
- `semantic_routing` 能减少 asset-tile score dispatch 数量。
- 未启用语义查找时，现有 placement pipeline 行为不变。

---

## 项目 TODO

后续实现事项、暂缓项和 MLP 计划统一记录在通用 TODO 文档：

```text
docs/voxel-semantic-routing-todo.md
```
