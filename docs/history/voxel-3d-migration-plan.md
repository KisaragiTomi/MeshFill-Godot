# 体素空间物体放置设计

Status: historical record. The migration checklist in this document has been completed; current placement ownership is summarized in `../core/meshfill-framework.md` and `../core/scene-voxel-field-system.md`.

![MeshFill compute shader 3D placement flow](../graphs/meshfill_compute_shader_3d_placement.svg)

本文只保留 3D voxel-space placement 的历史设计摘要。实现细节以当前代码和主文档为准：

- **框架归属**：`docs/../core/meshfill-framework.md`
- **SceneVoxel / collision 语义**：`docs/../core/scene-voxel-field-system.md`
- **放置实现**：`scripts/voxel_placement_generator.gd`
- **全局体素场**：`scripts/global_voxel_field.gd`
- **核心 shader**：`shaders/score_voxel_tile.glsl`、`shaders/reduce_voxel_tiles.glsl`、`shaders/stamp_voxel_field.glsl`

## 历史结论

3D 放置不直接沿用旧 2.5D heightfield fitting，而是把物体简化为局部体素 `AssetFootprint`，在候选落点上采样场景体素并给出物理评分。

```text
AssetFootprint
  -> score_voxel_tile
  -> reduce_voxel_tiles
  -> PlacementResult
  -> stamp_voxel_field
  -> optional CPU readback for instance / record commit
```

已落地的核心链路：

- **footprint 烘焙**：从 `collision_voxels` 生成局部 footprint，支持 support / clearance / solid 标记。
- **离散旋转**：预烘焙绕 Godot `Y` 轴的 `24` 个 yaw 版本，每个 candidate 只测试一个 `rotation_index`。
- **GPU 评分**：`score_voxel_tile.glsl` 使用 `8x8x8` workgroup，对候选 voxel 区域做 support / collision / overlap / clearance / ignored sample 累计。
- **Tile top K 与汇总**：tile 内输出 top K，`reduce_voxel_tiles.glsl` 做跨 tile 汇总、去重和 quota 处理。
- **GPU stamp**：`stamp_voxel_field.glsl` 将结果写回 scene / collision occupancy，并输出 `VoxelStampDeltaBuffer`。
- **多 asset 顺序放置**：`run_multi_asset()` 按优先级、权重和 quota 顺序处理，前一 asset 的 stamp 会影响后一 asset。
- **Dirty tile 驱动**：`GlobalVoxelField.run_placement_dirty()` 用 dirty tile 作为 compact candidate 输入。
- **CPU 角色**：CPU 只负责最终实例化、metadata / `voxel_record` 生成和提交，不做 mesh 级二次筛选。

## 数据分层

| 数据 | 用途 |
| --- | --- |
| `SceneOccupancy` | 生态或可视占用，例如树冠、草、岩石表面 |
| `CollisionOccupancy` | 刚体互斥层，例如树干、岩体、不可穿透物 |
| `TargetOccupancy` | 可选目标 mask；`candidate_origin` 对应值为 `0` 时不生成 placement |
| `CandidateTiles` | compact tile 输入，用于 dirty 或局部区域放置 |
| `AssetFootprint` | 物体局部简化体素 |
| `PlacementResult` | compact pose / score / debug 输出 |

`SceneOccupancy` 和 `CollisionOccupancy` 必须分离。草、叶、细枝可以写 scene occupancy，但不应默认阻挡刚体 collision placement。

## Footprint 规则

物体不直接用完整 mesh 做粗放置测试，而是转成小 footprint。典型字段包括：

| 字段 | 说明 |
| --- | --- |
| `local_pos` | 物体局部体素坐标 |
| `collision_degree` | `0-255` 碰撞强度；超过阈值视为 solid |
| `flags` | `support`、`clearance` 等 bit flags |
| `weight` | 对 score / debug 分量的权重 |

推荐语义：

- **`collision_degree = 0`**：不参与碰撞，只作为可视或复杂度信息。
- **`collision_degree = 1-191`**：soft 区间，允许重叠但扣分。
- **`collision_degree >= 192`**：solid 区间，累计到 hard collision 分量。
- **`support`**：底部接触点需要下方有支撑。
- **`clearance`**：预留空间，重叠会扣分或 reject。

薄片、叶片、细枝等 mesh 细节不在粗 footprint 中逐 voxel 表达，只折算为低强度占用、复杂度或 soft overlap。

## Candidate 评分

每个 candidate 将 footprint 变换到场景体素坐标后采样 `scene` / `collision`。footprint loop 内只累计分量，最后统一结算 `valid` 和 `score`。

```text
score =
  support_ratio       * support_weight
  - solid_collision   * collision_penalty
  - scene_overlap     * overlap_penalty
  - clearance_overlap * clearance_penalty
```

关键 debug 分量：

| 分量 | 说明 |
| --- | --- |
| `support_ratio` | 支撑点通过比例 |
| `solid_collision` | solid footprint 与 collision occupancy 的重叠 |
| `scene_overlap` | soft footprint 与 scene occupancy 的重叠 |
| `clearance_overlap` | clearance 区域被占用量 |
| `ignored_sample` | 因越界或未上传而跳过的采样权重 |
| `valid` | 阈值结算后的最终有效性 |

如果传入 `TargetOccupancy`，它首先作为目标 mask：

```text
if target_occupancy[candidate_origin] <= 0.01:
  reject candidate
```

## 边界语义

体素访问必须区分三类边界：

| 边界 | 含义 |
| --- | --- |
| `grid_bounds` | 整个逻辑体素场范围 |
| `sample_bounds` | 本次 compute 已上传或可读取的范围 |
| `write_bounds` | 本次允许写入和标 dirty 的范围 |

读取规则：

- **逻辑缺项**：在 `grid_bounds` 内但没有 committed `SceneVoxel` key，视为默认空体素。
- **显式空体素**：`value = 0.0` 的 `SceneVoxel` 与默认空占用相同，但 CPU 侧保留编辑语义。
- **超出 `sample_bounds`**：标记 `SAMPLE_IGNORED`，不当成 empty，也不当成 occupied。
- **超出 `grid_bounds`**：标记 `SAMPLE_IGNORED`，不要 clamp 到边界。
- **超出 `write_bounds`**：不写入，只作为 debug / 异常路径处理。

`support` 边界也要保守：如果下方采样点是 `SAMPLE_IGNORED`，它既不算支撑命中，也不算失败。需要地面支撑时应显式加入 terrain / base voxel，而不是靠 clamp 制造假支撑。

## 长 footprint 与 dirty tile

Candidate 的 owner tile 只表示“由哪个 tile 负责评分这个 origin”，不限制 footprint 访问范围。长条 asset 可能读取或写入多个 tile。

因此需要按 asset、`rotation_index` 和 `scale_index` 预计算：

| Bounds | 用途 |
| --- | --- |
| `footprint_sample_min/max` | footprint 正常采样范围 |
| `support_sample_min/max` | support 额外访问范围 |
| `clearance_sample_min/max` | clearance 额外访问范围 |
| `stamp_write_min/max` | placement 通过后实际写入范围 |

`sample_bounds` 应由 candidate bounds 加上这些 AABB 的并集得到；dirty 标记应覆盖 `stamp_write_bounds` 影响到的所有 tile。不要用 `search_radius` 近似 footprint 的真实访问范围。

## 历史原型参数

这些参数是早期原型约束，当前实现若有差异，以代码为准：

- **Footprint 容量**：先限制到 `128` 个 voxel。
- **旋转**：绕 `Y` 轴 `24` 个 yaw 角。
- **体素存储**：优先使用 compact `storage buffer`。
- **Workgroup**：`8x8x8`，每个 invocation 对应一个 candidate。
- **Tile top K**：`1..8`，密集候选建议 `4` 或 `8`。
- **CPU refine**：已移除；CPU 不做额外 mesh 级筛选。

## 现行维护建议

这份文档只作为迁移历史保留。新增规则不要继续扩写到这里，应更新对应的当前文档：

- **放置流程 / ownership**：更新 `docs/../core/meshfill-framework.md`
- **SceneVoxel / CollisionVoxel 语义**：更新 `docs/../core/scene-voxel-field-system.md`
- **TargetSceneVoxel 与语义候选路由**：更新 `docs/placement/voxel-semantic-routing.md`
