# Asset Semantic Probes — 资产语义采样点生成

## 目标

第一版 semantic routing 可以只考虑地面 / 可支撑表面的 anchor。

每个 asset 预先烘焙一组 semantic probes，用于描述：

```text
如果这个 asset 放在某个 ground anchor，
它希望在 TargetSceneVoxel 的哪些相对位置看到什么颜色、复杂度、碰撞/占用意图。
```

运行时：

```text
ground anchor
  -> for each asset
  -> sample TargetSceneVoxel at asset.semantic_probes
  -> compute semantic score
  -> keep voxel_asset_topK
```

这样可以避免把上方信息压缩成浑浊的通用平均值，也不需要让 `TargetSceneVoxel` 写入 asset 类型标签。

---

## Probe 数据结构

每个 probe 表示 asset anchor 的一个相对采样点。

```text
SemanticProbe:
  offset: ivec3
  expected_rgba8: uint
  expected_collision: uint8
  weight: float or uint8
  flags: uint
```

含义：

| 字段 | 含义 |
|------|------|
| `offset` | 相对 asset anchor 的采样位置 |
| `expected_rgba8` | 期望颜色与复杂度，`RGB=color`，`A=complexity` |
| `expected_collision` | 期望碰撞/实体强度，可选 |
| `weight` | 该 probe 对语义评分的权重 |
| `flags` | 是否要求颜色、复杂度、碰撞、空白等 |

GPU buffer 可以拆成 SoA：

```text
asset_probe_offset_buffer
asset_probe_expected_rgba8_buffer
asset_probe_weight_buffer
asset_probe_range_buffer  # asset_id -> start/count
```

---

## Probe 类型

### Positive probe

表示 asset 希望 target field 在此处有目标结构。

```text
sample complexity high
color close expected color
collision close expected collision
```

示例：

```text
tree canopy probe:
  offset = (2, 7, 1)
  expected color = green
  expected complexity = high
```

### Negative / empty probe

表示 asset 希望此处保持空白或低复杂度。

```text
sample complexity should be low
sample collision should be low
```

示例：

```text
tree side clearance probe:
  offset = (4, 1, 0)
  expected complexity = low
```

### Support probe

表示 asset 需要 anchor 附近有支撑。

```text
sample below anchor or support surface
expected support >= threshold
```

支撑最终仍由 `score_voxel_tile.glsl` 精筛；这里只做语义粗筛。

### Color probe

表示视觉颜色偏好。

```text
color_distance(sample.rgb, expected.rgb)
```

适合树冠、草、岩石等明显颜色结构。

### Complexity / mass probe

表示目标复杂度偏好。

```text
abs(sample.a - expected.a)
```

适合区分空地、草地、灌木、树冠、岩石体积。

---

## 从 asset 自动生成 probes

### 输入

```text
mesh triangles (surface_get_arrays)
mesh convex hull points (Mesh.create_convex_shape)
affected_bands (color/complexity per height)
density, max_count
```

每个 asset 需要统一 anchor 坐标系：

```text
offset = voxel_position - asset_anchor_position
```

---

## 生成策略（三层优先级）

`generate_from_mesh` 按优先级生成三类候选点，选择阶段严格按优先级逐层填充。

### Priority 1（最高）: Convex Hull 表面点

从 `Mesh.create_convex_shape(true, false)` 获取凸包顶点。

```text
shape_source = "convex"
importance = weight * 1.6
```

- 代表 asset 的简化实体轮廓。
- 选择阶段首先填充，保证凸包外壳的关键形状位置有 probe 覆盖。
- 适合所有 asset 类型。

### Priority 2: AutoObject Collision Voxel 内部点

内部 probe 直接来自 `AutoObject.collision_voxels` / `AutoVegetationAsset.get_collision_voxels()`：

```text
shape_source = "voxel_interior"
flags include FLAG_COLLISION
expected_collision = collision_voxel.value
importance = weight * lerp(1.1, 1.4, expected_collision)
```

- 对 `cylinder` collision voxel：按半径与 `y_min/y_max` 生成体积内采样点。
- 对 `box/cube` collision voxel：按 `half_extents` 或 `size` 生成体积内采样点。
- 没有 collision voxel 的 asset 不生成内部 probe。
- 该策略避免 mesh 三角形级内部判定的同步卡顿。

### Priority 3（最低）: Poisson Disk 表面采样

在 mesh 三角面上按面积加权随机采样，使用 Poisson 最小距离约束：

```text
shape_source = "surface"
importance = weight * 0.8
min_dist = sqrt(total_area / sample_count) * 0.5
```

- 均匀覆盖 mesh 表面。
- 只在 convex 和 voxel_interior 候选不足时补充。
- 使用固定 seed (42) 保证确定性。

---

## 选择算法

### 分层 Maximin Top-K

```text
1. 按 Y 高度分 5 层 bucket
2. 每层按 priority 和 importance 排序
3. 按优先级逐阶段填充:
   Phase 1: 只选 "convex" (逐步放宽 min_distance)
   Phase 2: 只选 "voxel_interior" (逐步放宽)
   Phase 3: 只选 "surface" (逐步放宽)
4. pick_next_candidate 使用 maximin:
   在所有满足 min_distance 的候选中，
   选择离最近已选 probe 最远的点 × priority_boost
```

priority_boost:
- `convex`: × 2.0
- `voxel_interior`: × 1.5
- `surface`: × 1.0

互斥距离使用固定世界空间常量 `PROBE_WORLD_MIN_DISTANCE = 0.35`，并按密度做轻量缩放：

```text
min_distance = clamp(PROBE_WORLD_MIN_DISTANCE / sqrt(density), 0.08, PROBE_WORLD_MIN_DISTANCE)
```

候选点会临时转换为 world offset 做距离判断，因此 probe 互斥不再随物体 mesh 尺寸变大而自动变大。

这保证了空间均匀覆盖 + 严格按类型优先级填充。

---

## Probe 评分

每个 probe 采样：

```text
sample_pos = anchor_pos + probe.offset
sample = TargetSceneVoxel[sample_pos]
```

推荐评分：

```text
color_fit      = 1 - distance(sample.rgb, expected.rgb)
complexity_fit = 1 - abs(sample.a - expected.a)
collision_fit  = 1 - abs(sample_collision - expected_collision)

probe_score =
    color_fit      * color_weight +
    complexity_fit * complexity_weight +
    collision_fit  * collision_weight
```

总分：

```text
asset_score = sum(probe_score * probe.weight) / sum(probe.weight)
```

Negative probe：

```text
empty_score = 1 - sample_complexity
```

Support probe：

```text
support_score = support_below(anchor) or sampled support field
```

---

## Ground anchor 限定

第一版只对 ground anchors 运行：

```text
anchor_count = width * depth
```

anchor 条件：

```text
support_below >= min_support_hint
anchor is inside dirty/active tile
nearby target complexity > threshold
```

后续可以扩展为 support surface anchors：

```text
ground
platform
step
floor
rock surface
```

但第一版不做完整 3D anchor 搜索。

---

## GPU Dispatch

推荐一个 compute shader：

```text
select_ground_anchor_assets.glsl
```

输入：

```text
ground_anchor_buffer
TargetSceneVoxel color/complexity/collision buffers
asset_probe_range_buffer
asset_probe_offset_buffer
asset_probe_expected_rgba8_buffer
asset_probe_weight_buffer
```

输出：

```text
voxel_asset_topK_buffer or ground_anchor_asset_topK_buffer
```

每个 invocation 可以处理：

```text
one ground anchor
```

内部遍历：

```text
for asset in assets:
    score = 0
    for probe in asset.probes:
        sample target
        accumulate score
    keep topK asset ids
```

如果资产数变大，可以拆成两阶段：

```text
anchor_asset_score tiles
reduce topK
```

---

## 与 Projection Cache 的关系

`asset semantic probes` 可以作为第一版主线。

`target_anchor_projection_rgba8` 可以作为后续：

- debug 可视化
- MLP 输入
- 预聚合加速层
- asset probe 的粗略替代

推荐第一版：

```text
ground anchor + asset probes
```

后续再根据性能决定是否引入 projection cache。

---

## 验收标准

- 每个 asset 能导出稳定的 semantic probes。
- probe 数量可控，默认目标约 `32 probes/asset`。
- semantic routing 只遍历 ground anchors。
- `TargetSceneVoxel` 不包含 asset 类型标签。
- probe 匹配能让 tree anchor 通过上方树冠/树干 target 获得高分。
- 输出 top-K asset 后，最终物理可行性仍交给 `score_voxel_tile.glsl`。
