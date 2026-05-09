# AutoObject Probe 粗筛选

从 `SceneVoxel`（`SV`）中提取可放置 anchor，用 `AutoObject.semantic_probes` 对目标体素采样评分，输出每个 anchor 的候选 `AutoObject` top-K，减少后续 GPU footprint scoring 的 dispatch 数量。

粗筛只负责语义匹配筛选，物理可行性由 `score_voxel_tile.glsl` 精筛完成。

---

## 目标与非目标

```text
SV / TargetSV → anchor 提取 → probe 采样 → top-K 选择 → tile 聚合 → dispatch
```

- **目标** — 排除不可放置位置；按 probe 语义匹配排序 asset；输出 `autoobject_candidate_tiles` 限定 dispatch。
- **非目标** — 不替代 footprint 精筛；不做 mesh/SDF 精确检测；不使用 `AutoObject.scale`（强制 `Vector3.ONE`）。

---

## 输入 / 输出

### 输入

| 数据 | 来源 | 用途 |
| --- | --- | --- |
| `SV` | 当前场景体素 | anchor 可放置性、占用/碰撞/支撑 |
| `TargetSV` | 目标场景体素 | probe 采样目标结构 |
| `AutoObject[]` | 可用资产列表 | `semantic_probes`、`allowed_anchor_kinds`、颜色、复杂度、碰撞 voxel |
| `dirty_tiles` | 编辑/生成阶段 | 限制粗筛范围 |

Buffer 映射：

| 字段 | Buffer |
| --- | --- |
| 当前占用 | `scene_occupancy` |
| 当前碰撞 | `collision_occupancy` |
| 目标强度 | `target_occupancy` |
| 目标颜色/复杂度 | `target_color` (packed `RGBA8`) |

### 输出

| 输出 | 含义 |
| --- | --- |
| `placeable_anchor_buffer` | 通过可放置测试的 anchor voxel |
| `anchor_autoobject_topk` | 每个 anchor 的优质 `AutoObject` top-K |
| `autoobject_candidate_tiles` | 按 `AutoObject` 聚合的 tile 坐标列表 |
| `debug_prefilter_score` | 可选调试体素 |

---

## 阶段 1：Anchor 提取

Anchor 分两层提取：

- **Ground anchor** — 现有地面/支撑层，用于 anchor 在底部或脚点的资产。
- **Target top anchor** — 从 `TargetSV` 每个 XZ column 提取最高目标体素，用于 anchor 在顶部的资产，例如部分 rock。

Ground anchor 对 dirty tile 内每个 voxel 判断是否可放置：

```text
scene_occupancy[p]     <= 0.15   // 基本为空
collision_occupancy[p] <= 0.05   // 无明显碰撞
support_below(p)       >= 0.25   // 下方有支撑
target_occupancy[p]    >= 0.01   // 目标有需求
```

`support_below(p)` 初版定义：

```text
support_below = max(scene_occupancy[p + down], collision_occupancy[p + down])
```

Target top anchor 对 dirty tile 覆盖的 XZ column 从全局 Y 顶部向下扫描：

```text
p = highest voxel in whole XZ column where target_occupancy[p] >= 0.01
target_occupancy[p + up] < 0.01 or out_of_bounds(p + up)
scene_occupancy[p]     <= 0.15
collision_occupancy[p] <= 0.05
```

`target_top` 不强制 `support_below >= MIN_SUPPORT`，因为它是语义对齐点，不一定是物理落点。最终物理可行性仍由 footprint scoring 确认。

Anchor 记录：

```text
PlaceableAnchor {
  id: uint,
  voxel_pos: ivec3,
  tile_id: uint,
  anchor_kind: ground | target_top,
  support: float,
  target_value: float
}
```

---

## 阶段 2：Probe 定义

通过 `auto_object.get_semantic_probes(density, anchor_kind)` 获取。约束：`scale = Vector3.ONE`，`offset` 按 asset/local space 使用。

`probe.offset` 必须相对当前资产声明的 anchor 原点生成：

- **ground** — offset 相对底部/脚点 anchor。
- **target_top** — offset 相对顶部 anchor，适合石头顶部对齐。

同一个 `AutoObject` 若同时支持多种 `anchor_kind`，需要为不同 anchor 原点烘焙对应 probe offset。

| 字段 | 用途 |
| --- | --- |
| `offset` | 相对 anchor 的采样偏移 |
| `expected_rgba8` | 期望颜色与复杂度 |
| `expected_collision` | 期望碰撞/实体强度 |
| `flags` | 控制参与哪些评分项 |
| `weight` | probe 权重 |
| `kind` | `positive` / `negative` |
| `source` | `convex` / `voxel_interior` / `surface` |

`AutoObject.allowed_anchor_kinds` 控制资产参与哪类 anchor：

```text
vegetation / ground props → [ground]
rock top-aligned assets    → [target_top]
generic assets             → [ground, target_top]
```

`target_top` rock 不应强制依赖 support probe；物理支撑与碰撞仍交给 footprint scoring。

---

## 阶段 3：Probe 采样与评分

```text
score_autoobject(anchor, auto_object):
  total_score = 0, total_weight = 0
  for probe in auto_object.semantic_probes:
    sample_pos = anchor.voxel_pos + voxelize(probe.offset)
    sample = read TargetSV at sample_pos
    probe_score = score_probe(sample, probe)
    total_score += probe_score * probe.weight
    total_weight += probe.weight
  return total_score / max(total_weight, epsilon)
```

采样字段：`target_color.rgb` → color, `target_color.a` → complexity, `target_occupancy` → collision, `scene_occupancy` → occupied, `SV[p+down]` → support。

### 评分公式

**Positive probe**：

```text
color_fit      = 1 - distance(sample.rgb, expected.rgb) / sqrt(3)
complexity_fit = 1 - abs(sample.a - expected.a)
collision_fit  = 1 - abs(sample_collision - expected_collision)
probe_score    = color_fit * w_color + complexity_fit * w_complexity + collision_fit * w_collision
```

**Empty/negative probe**：`1 - max(sample_complexity, sample_collision, sample_scene_occupied)`

**Support probe**：`clamp(sample_support, 0, 1)`

### Flag 控制

| Flag | 行为 |
| --- | --- |
| `FLAG_COLOR` | 参与 `color_fit` |
| `FLAG_COMPLEXITY` | 参与 `complexity_fit` |
| `FLAG_COLLISION` | 参与 `collision_fit` |
| `FLAG_EMPTY` | 使用 `empty_score` |
| `FLAG_SUPPORT` | 使用 `support_score` |

---

## 阶段 4：Top-K 选择与 Tile 聚合

每个 anchor 先检查自身 256 个 asset 的 probe 汇总评分，过滤低质量结果，再按得分降序取 top-K（`top_k = 4`）。最终是否放置仍由后续 placement 精筛决定。

Tile 聚合：

```text
for anchor in tile:
  for autoobject in anchor.topK:
    for affected_tile in asset_footprint_tiles(anchor, autoobject):
      vote[autoobject][affected_tile] += anchor.score
tile_autoobject_topK = topK(vote)
// 输出: autoobject_candidate_tiles[autoobject_id] = [tile_pos: Vector3i...]
```

`run_multi_asset()` 只对命中 tile 运行 footprint scoring。

`target_top` anchor 的资产 footprint 可能位于 anchor 下方，因此 tile 聚合必须按 asset 的 anchor-relative footprint AABB 扩展候选 tile，不能只使用 anchor 所在 tile。

---

## 实现伪代码

基于现有 `GlobalVoxelField`、`AutoObject`、`SemanticProbeProfile` 接口。

当前 CPU 落地实现：

| 文件 | 作用 |
| --- | --- |
| `scripts/autoobject_probe_prefilter.gd` | CPU 版双 anchor 层收集、probe 评分、anchor top-K、tile 聚合 |
| `scripts/auto_object.gd` | `allowed_anchor_kinds`、pivot → anchor kind 推导、按 anchor kind remap semantic probe offset |
| `scripts/global_voxel_field.gd` | `run_prefiltered_placement_dirty()` 将 prefilter 输出接到 `candidate_tiles_by_asset` |
| `scripts/voxel_placement_generator.gd` | `candidate_tiles_by_asset` 按 asset 限定 GPU footprint scoring tile |

`autoobject_candidate_tiles` 的 CPU API 输出为 `Vector3i` tile 坐标，而不是 GPU shader 内部的线性 `tile_id`。`VoxelPlacementGenerator` 会在 `_candidate_tile_to_id()` 中按自身 `tile_counts` 转换，避免不同模块的线性 tile 展开顺序耦合。

### 常量与数据结构

```gdscript
const TILE_SIZE := 8
const ANCHOR_TOPK := 4
const MAX_SCENE_OCC := 0.15
const MAX_COLLISION_OCC := 0.05
const MIN_SUPPORT := 0.25
const MIN_TARGET_INTEREST := 0.01
const MIN_PREFILTER_SCORE := 0.35
const EPSILON := 1e-6

const ANCHOR_KIND_GROUND := "ground"
const ANCHOR_KIND_TARGET_TOP := "target_top"
const ANCHOR_KIND_GROUND_ID := 0
const ANCHOR_KIND_TARGET_TOP_ID := 1

# SemanticProbeProfile flags
const FLAG_COLOR := 1
const FLAG_COMPLEXITY := 2
const FLAG_COLLISION := 4
const FLAG_EMPTY := 8
const FLAG_SUPPORT := 16
```

### 入口函数

```gdscript
func run_probe_prefilter(
    gvf: GlobalVoxelField,                   # scene_occupancy, collision_occupancy
    target_occupancy: PackedFloat32Array,     # 目标强度 (flat, same layout as gvf)
    target_color: PackedColorArray,           # 目标颜色+复杂度 (RGBA)
    autoobjects: Array[AutoObject],
    dirty_tile_ids: Array[int]
) -> Dictionary:
    # 阶段 1
    var anchors := _collect_anchors(gvf, target_occupancy, dirty_tile_ids)
    # 阶段 2-3
    var anchor_topk := _score_and_select(anchors, autoobjects, gvf, target_occupancy, target_color)
    # 阶段 4
    var tile_candidates := _reduce_to_tiles(anchors, anchor_topk, autoobjects, gvf)
    return {
        "anchors": anchors,
        "anchor_autoobject_topk": anchor_topk,
        "autoobject_candidate_tiles": tile_candidates,
    }
```

### 阶段 1：Anchor 提取

```gdscript
func _collect_anchors(
    gvf: GlobalVoxelField,
    target_occ: PackedFloat32Array,
    dirty_tile_ids: Array[int]
) -> Array[Dictionary]:
    var anchors: Array[Dictionary] = []
    var seen: Dictionary = {}  # "x:y:z:kind" -> true
    for tile_id in dirty_tile_ids:
        var tile_origin := gvf.tile_id_to_pos(tile_id) * TILE_SIZE

        # Ground anchors: scan every voxel in dirty tile.
        for lz in range(TILE_SIZE):
            for ly in range(TILE_SIZE):
                for lx in range(TILE_SIZE):
                    var p := tile_origin + Vector3i(lx, ly, lz)
                    _try_append_ground_anchor(anchors, seen, gvf, target_occ, p, tile_id)

        # Target top anchors: one highest TargetSV anchor per whole XZ column.
        for lz in range(TILE_SIZE):
            for lx in range(TILE_SIZE):
                _try_append_target_top_anchor(anchors, seen, gvf, target_occ, tile_origin, lx, lz)

    return anchors


func _try_append_ground_anchor(
    anchors: Array[Dictionary],
    seen: Dictionary,
    gvf: GlobalVoxelField,
    target_occ: PackedFloat32Array,
    p: Vector3i,
    tile_id: int,
) -> void:
    if not gvf.is_in_bounds(p):
        return
    var idx := gvf.voxel_index(p)
    var scene_val := gvf.scene_occupancy[idx]
    var coll_val := gvf.collision_occupancy[idx]
    var target_val := target_occ[idx] if idx < target_occ.size() else 0.0

    if scene_val > MAX_SCENE_OCC:
        return
    if coll_val > MAX_COLLISION_OCC:
        return
    if target_val < MIN_TARGET_INTEREST:
        return

    var p_down := p + Vector3i(0, -1, 0)
    var support := 0.0
    if gvf.is_in_bounds(p_down):
        support = maxf(gvf.get_scene(p_down), gvf.get_collision(p_down))
    if support < MIN_SUPPORT:
        return

    _append_anchor(anchors, seen, p, tile_id, ANCHOR_KIND_GROUND, support, target_val)


func _try_append_target_top_anchor(
    anchors: Array[Dictionary],
    seen: Dictionary,
    gvf: GlobalVoxelField,
    target_occ: PackedFloat32Array,
    tile_origin: Vector3i,
    lx: int,
    lz: int,
) -> void:
    var x := tile_origin.x + lx
    var z := tile_origin.z + lz
    for y in range(gvf.grid_size.y - 1, -1, -1):
        var p := Vector3i(x, y, z)
        if not gvf.is_in_bounds(p):
            continue
        var idx := gvf.voxel_index(p)
        var target_val := target_occ[idx] if idx < target_occ.size() else 0.0
        if target_val < MIN_TARGET_INTEREST:
            continue

        var p_up := p + Vector3i(0, 1, 0)
        if gvf.is_in_bounds(p_up):
            var up_idx := gvf.voxel_index(p_up)
            var up_target := target_occ[up_idx] if up_idx < target_occ.size() else 0.0
            if up_target >= MIN_TARGET_INTEREST:
                continue

        var scene_val := gvf.scene_occupancy[idx]
        var coll_val := gvf.collision_occupancy[idx]
        if scene_val > MAX_SCENE_OCC:
            return
        if coll_val > MAX_COLLISION_OCC:
            return

        var p_down := p + Vector3i(0, -1, 0)
        var support := 0.0
        if gvf.is_in_bounds(p_down):
            support = maxf(gvf.get_scene(p_down), gvf.get_collision(p_down))

        var tile_id := gvf._tile_id(p)
        _append_anchor(anchors, seen, p, tile_id, ANCHOR_KIND_TARGET_TOP, support, target_val)
        return


func _append_anchor(
    anchors: Array[Dictionary],
    seen: Dictionary,
    p: Vector3i,
    tile_id: int,
    anchor_kind: String,
    support: float,
    target_value: float,
) -> void:
    var key := "%d:%d:%d:%s" % [p.x, p.y, p.z, anchor_kind]
    if seen.has(key):
        return
    seen[key] = true
    anchors.append({
        "id": anchors.size(),
        "voxel_pos": p,
        "tile_id": tile_id,
        "anchor_kind": anchor_kind,
        "support": support,
        "target_value": target_value,
    })
```

### 阶段 2-3：Probe 采样评分与 Top-K 选择

```gdscript
func _score_and_select(
    anchors: Array[Dictionary],
    autoobjects: Array[AutoObject],
    gvf: GlobalVoxelField,
    target_occ: PackedFloat32Array,
    target_color: PackedColorArray,
) -> Dictionary:
    # 预取所有 AutoObject × anchor_kind 的 probes
    var all_probes: Dictionary = {}
    for obj_idx in range(autoobjects.size()):
        var obj := autoobjects[obj_idx]
        for anchor_kind in obj.get("allowed_anchor_kinds", [ANCHOR_KIND_GROUND]):
            var probe_key := _probe_cache_key(obj_idx, str(anchor_kind))
            all_probes[probe_key] = obj.get_semantic_probes(obj.semantic_probe_density, str(anchor_kind))

    var anchor_topk: Dictionary = {}  # anchor_id -> Array[{autoobject_idx, score}]
    for anchor in anchors:
        var candidates: Array[Dictionary] = []
        var anchor_kind := str(anchor.anchor_kind)
        for obj_idx in range(autoobjects.size()):
            if not _autoobject_accepts_anchor_kind(autoobjects[obj_idx], anchor_kind):
                continue
            var probes: Array = all_probes.get(_probe_cache_key(obj_idx, anchor_kind), [])
            var score := _score_autoobject(anchor, probes, gvf, target_occ, target_color)
            if score < MIN_PREFILTER_SCORE:
                continue
            candidates.append({"autoobject_idx": obj_idx, "score": score})

        candidates.sort_custom(func(a, b): return float(a.score) > float(b.score))
        anchor_topk[int(anchor.id)] = candidates.slice(0, ANCHOR_TOPK)

    return anchor_topk


func _autoobject_accepts_anchor_kind(autoobject: AutoObject, anchor_kind: String) -> bool:
    var allowed: Array = autoobject.get("allowed_anchor_kinds", [ANCHOR_KIND_GROUND])
    return allowed.has(anchor_kind)


func _probe_cache_key(obj_idx: int, anchor_kind: String) -> String:
    return "%d:%s" % [obj_idx, anchor_kind]


func _score_autoobject(
    anchor: Dictionary,
    probes: Array,
    gvf: GlobalVoxelField,
    target_occ: PackedFloat32Array,
    target_color: PackedColorArray,
) -> float:
    var total_score := 0.0
    var total_weight := 0.0
    var anchor_pos: Vector3i = anchor.voxel_pos

    for probe in probes:
        var offset: Vector3 = probe.get("offset", Vector3.ZERO)
        var sample_pos := anchor_pos + _voxelize_offset(offset, gvf.voxel_size)
        if not gvf.is_in_bounds(sample_pos):
            continue

        var w := maxf(float(probe.get("weight", 1.0)), EPSILON)
        var ps := _score_probe(sample_pos, probe, gvf, target_occ, target_color)
        total_score += ps * w
        total_weight += w

    return total_score / maxf(total_weight, EPSILON)


func _voxelize_offset(offset: Vector3, voxel_size: Vector3) -> Vector3i:
    return Vector3i(
        roundi(offset.x / voxel_size.x),
        roundi(offset.y / voxel_size.y),
        roundi(offset.z / voxel_size.z),
    )
```

### Probe 单点评分

```gdscript
func _score_probe(
    p: Vector3i,
    probe: Dictionary,
    gvf: GlobalVoxelField,
    target_occ: PackedFloat32Array,
    target_color: PackedColorArray,
) -> float:
    var idx := gvf.voxel_index(p)
    var flags := int(probe.get("flags", FLAG_COLOR | FLAG_COMPLEXITY))
    var kind := str(probe.get("kind", "positive"))

    # 读取采样值
    var s_color := target_color[idx] if idx < target_color.size() else Color.BLACK
    var s_complexity := s_color.a
    var s_collision := target_occ[idx] if idx < target_occ.size() else 0.0
    var s_scene_occ := gvf.scene_occupancy[idx]

    # Empty / negative probe
    if flags & FLAG_EMPTY or kind == "negative":
        return 1.0 - maxf(s_complexity, maxf(s_collision, s_scene_occ))

    # Support probe
    if flags & FLAG_SUPPORT:
        var p_down := p + Vector3i(0, -1, 0)
        var s_support := 0.0
        if gvf.is_in_bounds(p_down):
            s_support = maxf(gvf.get_scene(p_down), gvf.get_collision(p_down))
        return clampf(s_support, 0.0, 1.0)

    # Positive probe — 加权混合 color / complexity / collision
    var e_color: Color = probe.get("expected_color", Color.WHITE)
    var e_complexity := float(probe.get("expected_complexity", e_color.a))
    var e_collision := float(probe.get("expected_collision", 0.0))

    var score := 0.0
    var weight_sum := 0.0

    if flags & FLAG_COLOR:
        var dist := sqrt(
            (s_color.r - e_color.r) ** 2 +
            (s_color.g - e_color.g) ** 2 +
            (s_color.b - e_color.b) ** 2
        )
        score += (1.0 - dist / sqrt(3.0))
        weight_sum += 1.0

    if flags & FLAG_COMPLEXITY:
        score += (1.0 - absf(s_complexity - e_complexity))
        weight_sum += 1.0

    if flags & FLAG_COLLISION:
        score += (1.0 - absf(s_collision - e_collision))
        weight_sum += 1.0

    return score / maxf(weight_sum, EPSILON)
```

### 阶段 4：Tile 聚合

```gdscript
func _reduce_to_tiles(
    anchors: Array[Dictionary],
    anchor_topk: Dictionary,
    autoobjects: Array[AutoObject],
    gvf: GlobalVoxelField,
) -> Dictionary:
    # autoobject_idx -> { tile_id -> accumulated_score }
    var vote: Dictionary = {}

    for anchor_id in anchor_topk:
        var anchor: Dictionary = anchors[int(anchor_id)]
        var candidates: Array = anchor_topk[anchor_id]
        for c in candidates:
            var obj_idx: int = c.autoobject_idx
            var affected_tiles := _asset_footprint_tiles(anchor, autoobjects[obj_idx], gvf)
            if not vote.has(obj_idx):
                vote[obj_idx] = {}
            var tile_map: Dictionary = vote[obj_idx]
            for tile_id in affected_tiles:
                tile_map[tile_id] = float(tile_map.get(tile_id, 0.0)) + float(c.score)

    # 输出: autoobject_idx -> [tile_pos: Vector3i, ...] (按得分降序)
    var result: Dictionary = {}
    for obj_idx in vote:
        var tile_map: Dictionary = vote[obj_idx]
        var entries: Array[Dictionary] = []
        for tid in tile_map:
            entries.append({"tile_id": tid, "score": tile_map[tid]})
        entries.sort_custom(func(a, b): return float(a.score) > float(b.score))
        var tile_positions: Array[Vector3i] = []
        for e in entries:
            tile_positions.append(gvf.tile_id_to_pos(int(e.tile_id)))
        result[obj_idx] = tile_positions

    return result


func _asset_footprint_tiles(
    anchor: Dictionary,
    autoobject: AutoObject,
    gvf: GlobalVoxelField,
) -> Array[int]:
    var anchor_pos: Vector3i = anchor.voxel_pos
    var anchor_kind := str(anchor.anchor_kind)
    var aabb: AABB = autoobject.get_anchor_relative_footprint_aabb(anchor_kind)
    var min_p := anchor_pos + _voxelize_offset(aabb.position, gvf.voxel_size)
    var max_p := anchor_pos + _voxelize_offset(aabb.position + aabb.size, gvf.voxel_size)
    min_p = _clamp_voxel_pos(min_p, gvf)
    max_p = _clamp_voxel_pos(max_p, gvf)
    var min_tile := _voxel_to_tile_coord(min_p)
    var max_tile := _voxel_to_tile_coord(max_p)
    var tiles: Array[int] = []
    var seen_tiles: Dictionary = {}

    for tz in range(min_tile.z, max_tile.z + 1):
        for ty in range(min_tile.y, max_tile.y + 1):
            for tx in range(min_tile.x, max_tile.x + 1):
                var p := Vector3i(tx, ty, tz) * TILE_SIZE
                var tile_id := gvf._tile_id(p)
                if seen_tiles.has(tile_id):
                    continue
                seen_tiles[tile_id] = true
                tiles.append(tile_id)

    if tiles.is_empty():
        tiles.append(int(anchor.tile_id))
    return tiles


func _clamp_voxel_pos(p: Vector3i, gvf: GlobalVoxelField) -> Vector3i:
    return Vector3i(
        clampi(p.x, 0, gvf.grid_size.x - 1),
        clampi(p.y, 0, gvf.grid_size.y - 1),
        clampi(p.z, 0, gvf.grid_size.z - 1),
    )


func _voxel_to_tile_coord(p: Vector3i) -> Vector3i:
    return Vector3i(
        floori(float(p.x) / float(TILE_SIZE)),
        floori(float(p.y) / float(TILE_SIZE)),
        floori(float(p.z) / float(TILE_SIZE)),
    )
```

---

## GPU Compute Shader

### 约束

```text
MAX_ASSETS_PER_ANCHOR = 256
MAX_PROBES_PER_ASSET  = 128
WORKGROUP_SIZE        = 16 × 16 = 256 threads
ASSET_LANES           = 16 assets / workgroup
PROBE_LANES           = 16 probe lanes / asset
```

### 规模估算

```text
ground anchors     ≈ 256 × 256 = 65536
target_top anchors ≤ 256 × 256 = 65536
assets             = 256
probes             ≤ 128 / asset
总采样             = anchor_count × 256 × 128 (上界，实际按 anchor 层、asset mask、probe 数缩减)
```

### Dispatch 策略：两 Pass, Sharedgroup 归约 Probe

单 Pass 不同时做 "按 asset 的 probe 统计" 和 "每个 anchor 内 256 个 asset 评分筛选"。拆成两个 dispatch：

`anchor_grid_x` 可取 256，`anchor_grid_y = ceil(anchor_count / anchor_grid_x)`。

```text
Pass A — score_anchor_asset_probe_groups.glsl (sharedgroup 统计 probe)
  dispatch       = (anchor_grid_x, anchor_grid_y, ceil(asset_count / 16))
  workgroup_size = (16, 16, 1)
  local_x        = asset lane，1 个 workgroup 覆盖 16 个 asset
  local_y        = probe lane，每个 asset 用 16 条 lane stride 处理自身 probes
  sharedgroup    = shared_score[16][16] + shared_weight[16][16]
  输出           = asset_scores[anchor_id * 256 + asset_id]

Pass B — select_anchor_quality_topk.glsl (anchor 内 asset 筛选)
  dispatch       = (anchor_grid_x, anchor_grid_y, 1)
  workgroup_size = (16, 16, 1)
  local_id       = local_y * 16 + local_x = asset_id 0..255
  sharedgroup    = shared_scores[256]
  行为           = 每个 anchor voxel 检查内部 256 个 asset 的 probe 汇总评分
  输出           = anchor_topk[anchor_count * TOPK]
```

映射关系：

```text
Pass A:
  anchor_id   = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x
  asset_block = gl_WorkGroupID.z
  asset_lane  = gl_LocalInvocationID.x       // 0..15
  probe_lane  = gl_LocalInvocationID.y       // 0..15
  asset_id    = asset_block * 16 + asset_lane
  probe_i     = probe_lane; probe_i < probe_count; probe_i += 16

Pass B:
  anchor_id   = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x
  local_asset = gl_LocalInvocationID.y * 16 + gl_LocalInvocationID.x // 0..255
```

选择理由：

- **固定 16×16** — 每组 256 线程，兼容 Godot/Vulkan compute 的常见 workgroup 规模。
- **按 probe 数分配** — 每个 asset 读取自己的 `probe_count`，16 条 probe lane stride 处理，短 probe asset 自动少循环。
- **sharedgroup 统计** — 线程组内先写 `shared` score/weight，再由每个 asset lane 的 `probe_lane == 0` 做列归约。
- **Pass B 独立筛选** — 每个 anchor 一组，256 线程正好覆盖 256 个 asset score，先阈值过滤再 top-K。
- **二维 anchor dispatch** — `anchor_grid_x * anchor_grid_y >= anchor_count`，避免单维 dispatch 超过设备限制。
- **不依赖 subgroup 扩展** — 不需要 `GL_KHR_shader_subgroup_arithmetic`，避免不同 GPU wave size 差异。

### Buffer 布局

```text
// Probe 扁平打包，按 asset_id 连续排列
asset_probe_range[MAX_ASSETS * 2] // uvec2: { start_index, probe_count }, index = asset_id * 2 + anchor_kind_id
asset_anchor_kind_mask[256]     // uint bitmask: bit0=ground, bit1=target_top
probe_packed[total_probe_count] // 每条 probe = 2 × vec4:
  // vec4[0]: offset.x, offset.y, offset.z, weight
  // vec4[1]: expected_rgba8(as float bits), expected_collision, flags(as float bits), kind(as float bits)

// 场景数据 (已有 buffer 复用)
scene_occupancy[voxel_count]     // float
collision_occupancy[voxel_count] // float
target_occupancy[voxel_count]    // float
target_color[voxel_count]        // uint (packed RGBA8)

// Anchor 输入 (Shader 1 输出)
anchor_buffer[anchor_count]      // uvec4: { voxel_x, voxel_y, voxel_z, anchor_kind_id }
anchor_tile_id[anchor_count]     // uint: tile_id，用于后续 tile 聚合

// 中间 (Pass A 输出 → Pass B 输入)
asset_scores[anchor_count * 256] // float: 每 anchor 固定保留 256 个 asset 汇总评分

// 最终输出
anchor_topk[anchor_count * TOPK] // uvec2: { asset_id, score_as_float_bits }
```

### Shader 总览

| Shader | Dispatch | Workgroup | 说明 |
| --- | --- | --- | --- |
| `collect_ground_sv_anchors.glsl` | `(tile_count, 1, 1)` | `(512, 1, 1)` | tile per workgroup, thread per voxel, append `ground` anchor |
| `collect_target_top_anchors.glsl` | `(dirty_xz_column_count, 1, 1)` | `(64, 1, 1)` | thread per XZ column, scan global Y top-down, append `target_top` anchor |
| `score_anchor_asset_probe_groups.glsl` | `(anchor_grid_x, anchor_grid_y, ceil(asset_count / 16))` | `(16, 16, 1)` | **Pass A** — 16 asset lanes × 16 probe lanes，sharedgroup 归约 |
| `select_anchor_quality_topk.glsl` | `(anchor_grid_x, anchor_grid_y, 1)` | `(16, 16, 1)` | **Pass B** — 每 anchor 检查 256 asset 分数，阈值过滤 + top-K |
| `reduce_anchor_topk_to_tiles.glsl` | `(anchor_count, 1, 1)` | `(TOPK, 1, 1)` | tile 聚合 vote |

### Pass A 伪代码: `score_anchor_asset_probe_groups.glsl`

```glsl
#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) readonly  buffer AnchorBuf   { uvec4 anchors[];           };
layout(set = 0, binding = 1) readonly  buffer ProbeRange   { uvec2 asset_probe_range[]; };
layout(set = 0, binding = 2) readonly  buffer AnchorMask   { uint  asset_anchor_kind_mask[]; };
layout(set = 0, binding = 3) readonly  buffer ProbeData    { vec4  probe_data[];        };
layout(set = 0, binding = 4) readonly  buffer SceneOcc     { float scene_occ[];         };
layout(set = 0, binding = 5) readonly  buffer CollisionOcc { float collision_occ[];     };
layout(set = 0, binding = 6) readonly  buffer TargetOcc    { float target_occ[];        };
layout(set = 0, binding = 7) readonly  buffer TargetColor  { uint  target_color[];      };
layout(set = 0, binding = 8) writeonly buffer ScoresOut    { float asset_scores[];      };

layout(push_constant) uniform Params {
    ivec4 grid_size;       // xyz = grid dims, w = asset_count
    vec4  voxel_size_inv;  // xyz = 1/voxel_size
    uint  anchor_count;
    uint  anchor_grid_x;
};

const uint MAX_ASSETS      = 256u;
const uint ASSET_LANES     = 16u;
const uint PROBE_LANES     = 16u;
const uint ANCHOR_KIND_GROUND     = 0u;
const uint ANCHOR_KIND_TARGET_TOP = 1u;
const uint FLAG_COLOR      = 1u;
const uint FLAG_COMPLEXITY = 2u;
const uint FLAG_COLLISION  = 4u;
const uint FLAG_EMPTY      = 8u;
const uint FLAG_SUPPORT    = 16u;

shared float shared_score[16][16];
shared float shared_weight[16][16];

int voxel_index(ivec3 p) {
    return p.x + p.y * grid_size.x + p.z * grid_size.x * grid_size.y;
}

bool in_bounds(ivec3 p) {
    return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, grid_size.xyz));
}

vec4 unpack_rgba8(uint packed) {
    return vec4(
        float(packed & 0xFFu) / 255.0,
        float((packed >> 8u) & 0xFFu) / 255.0,
        float((packed >> 16u) & 0xFFu) / 255.0,
        float((packed >> 24u) & 0xFFu) / 255.0
    );
}

float eval_probe(ivec3 sp, uint flags, uint kind, vec4 e_col, float e_coll) {
    int idx = voxel_index(sp);

    // Empty / negative
    if ((flags & FLAG_EMPTY) != 0u || kind == 1u) {
        vec4 sc = unpack_rgba8(target_color[idx]);
        return 1.0 - max(sc.a, max(target_occ[idx], scene_occ[idx]));
    }

    // Support
    if ((flags & FLAG_SUPPORT) != 0u || kind == 2u) {
        ivec3 below = sp + ivec3(0, -1, 0);
        if (!in_bounds(below)) return 0.0;
        int bi = voxel_index(below);
        return clamp(max(scene_occ[bi], collision_occ[bi]), 0.0, 1.0);
    }

    // Positive
    vec4 sc = unpack_rgba8(target_color[idx]);
    float s_coll = target_occ[idx];
    float score = 0.0, wsum = 0.0;
    if ((flags & FLAG_COLOR) != 0u) {
        score += 1.0 - distance(sc.rgb, e_col.rgb) / 1.732;
        wsum += 1.0;
    }
    if ((flags & FLAG_COMPLEXITY) != 0u) {
        score += 1.0 - abs(sc.a - e_col.a);
        wsum += 1.0;
    }
    if ((flags & FLAG_COLLISION) != 0u) {
        score += 1.0 - abs(s_coll - e_coll);
        wsum += 1.0;
    }
    return score / max(wsum, 1e-6);
}

void main() {
    uint anchor_id   = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x;
    uint asset_block = gl_WorkGroupID.z;
    uint asset_lane  = gl_LocalInvocationID.x; // 0..15
    uint probe_lane  = gl_LocalInvocationID.y; // 0..15
    uint asset_count = min(uint(grid_size.w), MAX_ASSETS);
    uint asset_id    = asset_block * ASSET_LANES + asset_lane;

    float lane_score  = 0.0;
    float lane_weight = 0.0;

    if (anchor_id < anchor_count && asset_id < asset_count) {
        uvec4 anchor = anchors[anchor_id];
        ivec3 anchor_pos = ivec3(anchor.xyz);
        uint anchor_kind = anchor.w;
        uint anchor_kind_bit = 1u << anchor_kind;

        if ((asset_anchor_kind_mask[asset_id] & anchor_kind_bit) != 0u) {
            uint probe_range_idx = asset_id * 2u + anchor_kind;
            uvec2 range = asset_probe_range[probe_range_idx];
            uint probe_start = range.x;
            uint probe_count = range.y;

            for (uint i = probe_lane; i < probe_count; i += PROBE_LANES) {
                uint pi = (probe_start + i) * 2u;
                vec4 d0 = probe_data[pi];
                vec4 d1 = probe_data[pi + 1u];

                vec3  offset = d0.xyz;
                float weight = max(d0.w, 0.0);
                uint  rgba8  = floatBitsToUint(d1.x);
                float e_coll = d1.y;
                uint  flags  = floatBitsToUint(d1.z);
                uint  kind   = floatBitsToUint(d1.w);

                ivec3 sp = anchor_pos + ivec3(round(offset * voxel_size_inv.xyz));
                if (in_bounds(sp)) {
                    vec4 e_col = unpack_rgba8(rgba8);
                    float ps = eval_probe(sp, flags, kind, e_col, e_coll);
                    lane_score  += ps * weight;
                    lane_weight += weight;
                }
            }
        }
    }

    shared_score[asset_lane][probe_lane] = lane_score;
    shared_weight[asset_lane][probe_lane] = lane_weight;
    barrier();

    if (probe_lane == 0u && anchor_id < anchor_count && asset_id < MAX_ASSETS) {
        float sum_score = 0.0;
        float sum_weight = 0.0;
        for (uint py = 0u; py < PROBE_LANES; py++) {
            sum_score += shared_score[asset_lane][py];
            sum_weight += shared_weight[asset_lane][py];
        }
        float final_score = asset_id < asset_count ? sum_score / max(sum_weight, 1e-6) : -1.0;
        asset_scores[anchor_id * MAX_ASSETS + asset_id] = final_score;
    }
}
```

### Pass B 伪代码: `select_anchor_quality_topk.glsl`

```glsl
#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) readonly  buffer ScoresIn { float asset_scores[]; };
layout(set = 0, binding = 1) writeonly buffer TopKOut  { uvec2 anchor_topk[];  };

layout(push_constant) uniform Params {
    uint  anchor_count;
    uint  asset_count;
    uint  anchor_grid_x;
    float min_prefilter_score;
};

const uint MAX_ASSETS = 256u;
const uint TOPK = 4u;

shared vec2 shared_scores[256]; // x=score, y=asset_id

void main() {
    uint anchor_id = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x;
    uint tid = gl_LocalInvocationID.y * 16u + gl_LocalInvocationID.x;
    uint asset_count_clamped = min(asset_count, MAX_ASSETS);

    float score = -1.0;
    if (anchor_id < anchor_count && tid < asset_count_clamped) {
        score = asset_scores[anchor_id * MAX_ASSETS + tid];
        if (score < min_prefilter_score) {
            score = -1.0;
        }
    }
    shared_scores[tid] = vec2(score, float(tid));
    barrier();

    if (tid == 0u && anchor_id < anchor_count) {
        for (uint k = 0u; k < TOPK; k++) {
            float best = -1.0;
            uint best_id = 0xFFFFFFFFu;

            for (uint j = 0u; j < asset_count_clamped; j++) {
                if (shared_scores[j].x > best) {
                    best = shared_scores[j].x;
                    best_id = uint(shared_scores[j].y);
                }
            }

            if (best_id == 0xFFFFFFFFu) {
                anchor_topk[anchor_id * TOPK + k] = uvec2(0xFFFFFFFFu, floatBitsToUint(-1.0));
            } else {
                anchor_topk[anchor_id * TOPK + k] = uvec2(best_id, floatBitsToUint(best));
                shared_scores[best_id].x = -2.0;
            }
        }
    }
}
```

---

## 与现有放置流程的关系

```text
// 现有流程
collision_voxels → bake_footprint → run_minimal → score_voxel_tile → reduce → stamp

// 加入粗筛
SV/TargetSV → probe prefilter → autoobject_candidate_tiles → run_multi_asset (routed tiles) → score_voxel_tile
```

粗筛只减少候选，不直接写入场景。

---

## Debug 输出

| Debug 层 | 含义 |
| --- | --- |
| `placeable_anchor_ground` | 地面/支撑层 anchor |
| `placeable_anchor_target_top` | `TargetSV` 最高表面 anchor |
| `anchor_kind` | `ground` / `target_top` |
| `best_autoobject_id` | 最高分 AutoObject |
| `best_semantic_score` | 最高 probe 分 |
| `rejected_reason` | 支撑不足 / 目标过低 / anchor kind 不匹配 / probe 分数过低 |

---

## 验收标准

- 从 `SV` 稳定提取 `ground` anchor。
- 从 `TargetSV` 每个 dirty XZ column 稳定提取最高 `target_top` anchor。
- `anchor_topk` 按 `anchor.id` 存储，不因同一 voxel 的不同 `anchor_kind` 互相覆盖。
- `AutoObject.allowed_anchor_kinds` 能限制资产只参与匹配的 anchor 层。
- 每个 anchor 遍历所有 `AutoObject.semantic_probes` 并计算分数。
- Pass A 使用 `16×16` 线程组，结合每个 asset 的 `probe_count` 分配 probe lane，并在 sharedgroup 内完成 score/weight 统计。
- Pass B 让每个 anchor voxel 检查自身 256 个 asset 的 probe 汇总评分，过滤低质量结果后输出 anchor 级 top-K。
- 不同 asset 按 probe 匹配得到不同排序。
- 空白/低目标区域不输出大量 asset。
- 粗筛输出转换为 `autoobject_candidate_tiles` 限定 dispatch。
- 最终放置由 footprint scoring 物理确认。

---

## TODO：后续优化

按优先级逐步减少 `anchor_count × asset_count × probe_count` 的完整采样量。

### P0：Asset 粗分流

- [ ] 为 anchor / tile 计算 cheap context signature。
- [ ] 为每个 `AutoObject` 预烘焙 `asset_context_signature`。
- [ ] 先用 context dot / distance 从 256 个 asset 缩到 16~32 个 asset shortlist。
- [ ] 后续 full probe scoring 只处理 shortlist 内 asset。

### P1：Probe 两级评分

- [ ] 将 `semantic_probes` 拆成 `core_probes` 与 `detail_probes`。
- [ ] `core_probes` 保留 support、negative/empty、高权重 convex、关键 collision probe。
- [ ] 第一轮只跑 `core_probes`，淘汰低分 asset。
- [ ] 第二轮只对 core 高分 asset 跑 full probes。

### P2：Probe 排序与提前拒绝

- [ ] 按拒绝能力排序 probe：support → negative/empty → high-weight convex → collision → color/complexity。
- [ ] 每 16 个 probe 做一次 chunk 统计。
- [ ] 根据 `current_score + remaining_weight` 估算最高可能分。
- [ ] 若最高可能分低于 `MIN_PREFILTER_SCORE`，提前拒绝该 asset。

### P3：Probe 数量分桶

- [ ] 按 `probe_count` 分桶：`1~32`、`33~64`、`65~128`。
- [ ] 小 probe asset 使用更短 loop / 专用 dispatch。
- [ ] 避免少 probe asset 与大 probe asset 混合导致 lane 浪费。

### P4：带宽与缓存优化

- [ ] 将 probe buffer 从 `2 × vec4` 压缩为半精度 / packed 格式。
- [ ] 评估 `offset` 使用 `int16` 或 `snorm16`。
- [ ] 评估 `weight` / `expected_collision` 使用 `float16`。
- [ ] 评估 tile-local expanded TargetSV preload，减少相邻 anchor 重复采样。

### P5：结构级优化

- [ ] 增加 tile 级 prefilter：`tile_context → tile_asset_shortlist`。
- [ ] anchor probe scoring 只处理所属 tile 的 asset shortlist。
- [ ] 将 asset 按语义 probe 聚类成 group。
- [ ] 先选择 group top-K，再在 group 内选择 asset top-K。

---

## Open Questions

- `SV` 与 `TargetSV` 是否分离：anchor 可放置性读 `SV`，语义匹配读 `TargetSV`。
- `probe.offset` 到 voxel 坐标的换算是否使用统一 `voxel_size`。
- `FLAG_EMPTY` / `FLAG_SUPPORT` 是否需在 `SemanticProbeProfile` 生成阶段补齐。
