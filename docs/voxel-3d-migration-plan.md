# 体素空间物体放置设计

本文只讨论一件事：在 3D voxel field 中如何判断一个物体能不能放置。这里不假设旧 2.5D heightfield fitting 可以直接沿用；3D 放置应从体素占用、碰撞、支撑和局部 footprint 重新定义。

第一版定位为粗略放置判断，不处理薄片、叶片、细枝等 mesh 级细节。放入场景的物体最终仍是浮点变换的 mesh；粗 voxel pass 只判断大致空间、支撑和碰撞度是否合理。薄片和复杂外形先抽象成复杂度、软占用或碰撞度，后续再用更细的 mesh / SDF 检查处理。

## 当前完成度

当前最小 GPU 原型已经落地为独立于旧 2.5D `CliffGenerator` 的 `VoxelPlacementGenerator`，用于验证 3D voxel-space 放置判断本身。

| 项目 | 状态 | 代码位置 |
| --- | --- | --- |
| `AssetFootprint` 输入 | 已实现，最多 `128` 个 footprint voxel | `scripts/voxel_placement_generator.gd` |
| `SceneOccupancy` / `CollisionOccupancy` 分离 | 已实现，均为 compact `storage buffer` | `scripts/voxel_placement_generator.gd` |
| `CandidateTiles` compact tile 输入 | 已实现；未传时默认全 grid | `score_voxel_tile.glsl`、`VoxelPlacementGenerator.run_minimal()` |
| `score_voxel_tile` | 已实现 `8x8x8` workgroup、safe sample、support / collision / overlap / clearance / ignored debug 分量 | `shaders/score_voxel_tile.glsl` |
| `TargetOccupancy` 放置 mask | 已实现；传入 target 时，`target_occupancy[candidate_origin] <= 0.01` 的候选直接无效 | `shaders/score_voxel_tile.glsl`、`tools/test_voxel_target_debug.gd` |
| 感受野扩大 | 已实现可选 `search_radius`，当前限制到每轴 `0..4` voxel | `shaders/score_voxel_tile.glsl` |
| Tile 内 top K | 已实现 `top_k = 1..8`，并按 origin 去重 | `shaders/score_voxel_tile.glsl` |
| `reduce_voxel_tiles` | 已实现第一版串行全局 reduce 和最小距离去重 | `shaders/reduce_voxel_tiles.glsl` |
| `stamp_voxel_field` | 已实现按 result 写回 scene / collision occupancy 和 `VoxelStampDeltaBuffer` | `shaders/stamp_voxel_field.glsl` |
| stamp 后再评分 | 已验证，第二轮会读到上一轮写入的 collision | `tools/test_voxel_placement_generator.gd` |
| Footprint 自动烘焙 | 已实现 `bake_footprint_from_collision_voxels()`，支持 cylinder shape、support / clearance 自动标记、去重、容量截断 | `scripts/voxel_placement_generator.gd` |
| `24` 个 yaw `rotation_index` 版本 | 已实现 `bake_rotated_footprints()` 和 `rotate_footprint_y()`，对非对称 footprint 做 2D 旋转+去重 | `scripts/voxel_placement_generator.gd` |
| GPU result → 世界坐标转换 | 已实现 `results_to_world()`，过滤无效 candidate、映射 voxel origin 到世界位置、rotation_index 到 yaw 角度 | `scripts/voxel_placement_generator.gd` |
| Footprint 烘焙集成测试 | 已验证 cylinder 烘焙、旋转、24 yaw 预烘焙、完整 pipeline（bake→score→stamp→再评分）、世界坐标转换 | `tools/test_voxel_footprint_bake.gd` |
| 多 asset 顺序 pipeline | 已实现 `run_multi_asset()`，顺序烘焙+评分+stamp，前一 asset 的 collision 自动影响后续 asset | `scripts/voxel_placement_generator.gd` |
| `PlacementResult` → Godot 节点实例化 | 已实现 `instantiate_placement()` / `instantiate_placements()`，支持 canopy_tree / midstory_tree / bush / grass / rock 节点类型 | `scripts/voxel_placement_generator.gd` |
| `PlacementResult` → `voxel_record` / `SceneVoxel` commit | 已实现可选 `create_voxel_record` 和 `vegetation_exclusion` 提交路径；实例化时可生成 record metadata，并通过 `VegetationExclusion.apply_mesh_voxel_record()` 发布 `AutoSceneVoxel` / `SceneVoxel` / `GlobalVoxelField` | `scripts/voxel_placement_generator.gd`、`tools/test_voxel_placement_record_commit.gd` |
| 多 asset + 实例化/record 集成测试 | 已验证双 asset pipeline、节点类型和属性、跨 asset collision 避让，以及实例化后 record 提交链路 | `tools/test_voxel_multi_asset.gd`、`tools/test_voxel_placement_record_commit.gd` |
| `GlobalVoxelField` dirty tile → 按需候选上传 | 已实现 `tile_id_to_pos()` / `tile_pos_to_id()` / `get_dirty_tile_positions()` / `get_tile_voxel_bounds()` / `clear_dirty_tiles()` | `scripts/global_voxel_field.gd` |
| `run_placement_dirty()` dirty tile 驱动 pipeline | 已实现：自动收集 dirty tile 作为 candidate_tiles、执行多 asset pipeline、可选 apply stamp deltas 回写、可选 clear processed dirty tiles | `scripts/global_voxel_field.gd` |
| `apply_stamp_deltas()` 选择性体素回写 | 已实现：逐条应用 GPU stamp delta 到 scene/collision occupancy，自动标记受影响 tile 为 dirty | `scripts/global_voxel_field.gd` |
| Dirty tile 集成测试 | 已验证 tile_id 往返、dirty 追踪、stamp delta 应用、dirty tile 驱动 placement、处理后 dirty 清除、无 dirty 返回空 | `tools/test_voxel_dirty_tile_upload.gd` |
| 多 asset 优先级、随机权重、global quota | 已实现 `_sort_asset_defs_by_priority_weight()`、`_weighted_shuffle()`；`run_multi_asset()` 支持 `priority`、`weight`、`global_quota`、`seed`；结果包含 `processing_order` 和 `skipped_quota` | `scripts/voxel_placement_generator.gd` |
| 优先级/权重/quota 集成测试 | 已验证 priority 排序、seeded weight 随机可复现、global_quota 截断、quota 截断后的 skipped_quota 标记、GPU pipeline 中 priority 生效 | `tools/test_voxel_asset_priority.gd` |
| CPU 角色 | 仅负责 instantiate_placement() 创建节点，不做 mesh 筛选/过滤 | `scripts/voxel_placement_generator.gd` |

当前测试覆盖：

- 首轮从空 collision 场中生成 placement。
- `stamp_voxel_field` 会写入 solid footprint 的 collision occupancy。
- 第二轮评分会避开上一轮 stamp 的 collision voxel。
- 只 dispatch 一个 compact dirty tile 时，`search_radius` 可以找到邻接 tile 的候选 origin。
- Cylinder collision_voxel → footprint 烘焙，含 support / clearance / solid 标记。
- 90° 旋转验证，identity 旋转保持不变。
- 24 yaw 预烘焙全部非空。
- 完整 pipeline：bake → score → stamp → 再评分避开 collision。
- `results_to_world()` 过滤无效候选、voxel→世界坐标、rotation_index→yaw。
- `run_multi_asset()` 双 asset 顺序 pipeline，各自生成 placement 并带 world_results。
- `instantiate_placements()` 生成正确类型的 AutoCanopyTree / AutoBush 节点，position / mesh / subtype 正确。
- `instantiate_placement(create_voxel_record=true, vegetation_exclusion=...)` 会挂载 `voxel_record` metadata，并提交出 `AutoSceneVoxel` source delta、`SceneVoxel` 和 `GlobalVoxelField` tile。
- 大小两种 cylinder asset 的跨 asset collision 避让：小 asset 不会与大 asset 重叠。
- `tile_id_to_pos()` / `tile_pos_to_id()` 往返一致。
- `set_scene()` / `set_collision()` 自动标记 dirty tile，同 tile 内写入不重复计数。
- `apply_stamp_deltas()` 正确写入 scene/collision 值，越界 delta 被忽略，写入后自动标记 dirty。
- `run_placement_dirty()` 从 dirty tile 生成 candidate_tiles，执行 GPU pipeline 并产出 placement。
- `run_placement_dirty(clear_processed=true)` 处理后 dirty tile 被清除。
- 无 dirty tile 时 `run_placement_dirty()` 直接返回空结果集，不触发 GPU。
- `priority` 排序：高优先级 asset 先处理，同优先级按 `weight` 随机洗牌。
- `seed` 可复现：同一 seed 产出相同顺序；`weight=100` 的 asset 在 100 次随机中 97 次排第一。
- `global_quota` 截断：达到 quota 后剩余 asset 被跳过并标记 `skipped_quota=true`。
- `global_quota` 动态压缩后续 asset 的 `result_capacity` 为 `quota - total_placed`。
- `processing_order` 返回实际执行顺序的原始索引。
- `target_occupancy` 作为目标复杂度 mask：复杂度为 `0` 的 target voxel 不产生正 placement score。
- CPU 仅 instantiate_placement() 创建节点，不做 mesh 级筛选（refine 已移除）。

本计划所有项目已完成。

## 核心思路

把物体简化成一组局部体素 footprint。每个候选落点把这个 footprint 变换到场景体素坐标，然后采样 scene occupancy / collision occupancy，判断是否可放置并给出 score。

```text
asset simplified footprint
  -> load footprint chunk into shared memory
  -> each invocation tests one candidate voxel pose
  -> sample scene voxel / collision voxel
  -> reject or score
  -> reduce best placement
```

## 输入数据

| 数据 | 建议格式 | 用途 |
| --- | --- | --- |
| `SceneOccupancy` | 3D texture / storage buffer | 生态或可视占用，例如树冠、草、岩石表面 |
| `CollisionOccupancy` | 3D texture / storage buffer | 刚体互斥层，例如树干、岩体、不可穿透物 |
| `TargetOccupancy` | storage buffer，可选 | 目标 `SceneVoxel` 复杂度 mask；值为 `0` 的 voxel 不能作为放置候选起点 |
| `TargetColor` | storage buffer，可选 | 目标颜色，用于 debug / fit 分量 |
| `CandidateTiles` | compact tile buffer | 只测试 dirty 或可能可放置的区域 |
| `AssetFootprint` | storage buffer | 物体局部简化体素 |
| `PlacementResult` | storage buffer | 输出可放置候选、score、pose |

`SceneOccupancy` 和 `CollisionOccupancy` 必须分开。草、叶、细枝可以写 scene occupancy，但不应该阻挡刚体 collision placement。

Godot 3D 中使用 Y 轴作为高度轴，因此 voxel grid 建议采用 `XZ` 平面较细、`Y` 轴压缩成较少 height slices 的非等方体素。例如 `XZ = 256x256`，`Y = 32 slices`。粗放置 pass 只使用压缩后的 Y 层级，避免候选数量沿高度方向爆炸。

## 简化物体 Footprint

物体不要直接用完整 mesh 做测试，先离线、导入阶段或 GPU 预处理阶段转成小 footprint。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `local_pos` | `ivec3` | 物体局部体素坐标 |
| `collision_degree` | `uint` | `0-255` 碰撞/硬度强度，超过阈值视为 solid |
| `flags` | `uint` | bit flags，例如 `support`、`clearance` |
| `radius` | `float` | 可选，用于膨胀或保守测试 |
| `weight` | `float` | 对 score 的影响 |

示例：

```text
collision_degree = 0       不参与碰撞，只作为可视/复杂度信息
collision_degree = 1-191   soft 区间，允许重叠但会扣分
collision_degree >= 192    solid 区间，累计 solid_collision 后统一结算
flag support               需要下方有支撑，用于底部接触点
flag clearance             预留空间，最好为空，重叠会扣分或 reject
```

薄片、叶、细枝这类细节不需要在粗 footprint 中逐 voxel 表达。第一版可以把它们折算成较低的 `collision_degree`、复杂度或 scene overlap 权重；只有真正会阻挡放置的主体部分才使用超过 solid 阈值的 `collision_degree`。

旋转只绕 Godot 高度轴 `Y`。建议为每个 asset 预烘焙 `24` 个 yaw 角度的 `AssetFootprint` 版本，放置时每个 candidate 只选择其中一个 `rotation_index`，不要对同一个 candidate 遍历 24 个角度。这样延续旧 2.5D 的绕 Y 随机旋转思路，同时避免评分成本乘以 24。

## Shared Memory 策略

一个 workgroup 处理同一个 asset 和一个 voxel tile。先把该 asset 的 footprint chunk 载入 shared memory，再让 group 内多个 candidate 复用它。

```glsl
// sketch only
shared ivec4 s_footprint_pos_degree_flags[128];
shared vec4 s_footprint_weight[128];

if (local_index < footprint_count) {
    s_footprint_pos_degree_flags[local_index] = footprint_pos_degree_flags[asset_offset + local_index];
    s_footprint_weight[local_index] = footprint_weight[asset_offset + local_index];
}
barrier();

// each invocation tests one candidate placement
ivec3 candidate = tile_origin + ivec3(local_x, local_y, local_z);
```

共享内存大小要保守。Vulkan 至少保证 16 KB shared memory；如果 footprint 太大，就分 chunk 测试：

```text
for footprint_chunk:
  load chunk to shared memory
  barrier
  test all local candidates against chunk
  accumulate score components
```

## Candidate 测试规则

每个 candidate pose 对 footprint 中的所有局部体素做采样。为了减少 shader 分支，footprint loop 内尽量只累计分量，循环结束后统一结算 `valid` 和 `score`。

```text
world_voxel = candidate_origin + rotate(local_pos) * scale

solid_mask = step(solid_threshold, collision_degree)
soft_mask = 1.0 - solid_mask
support_mask = flag_support ? 1.0 : 0.0
clearance_mask = flag_clearance ? 1.0 : 0.0

collision_value = CollisionOccupancy(world_voxel)
scene_value = SceneOccupancy(world_voxel)
below_support = SceneOrCollisionOccupancy(world_voxel + ivec3(0, -1, 0))

solid_collision += solid_mask * collision_value
scene_overlap += soft_mask * scene_value * collision_degree
support_total += support_mask
support_hit += support_mask * step(support_threshold, below_support)
clearance_overlap += clearance_mask * max(scene_value, collision_value)
```

最后统一结算：

```text
support_ratio = support_hit / max(support_total, 1)
valid = solid_collision <= collision_limit
     && support_ratio >= min_support_ratio
     && clearance_overlap <= clearance_limit
```

这样 `collision_degree`、`support`、`clearance` 都变成分量累计，不在 footprint loop 里提前 return。需要 hard reject 的条件放到最后统一判断。

由于 Y 轴是压缩高度层，`support` 可以先只检查下方 1 个 height slice，`clearance` 可以保守检查当前和上方 1-2 个 height slices。GPU 评分阶段足以处理空间冲突检测。

## 访问边界与缺省值

体素访问必须区分三种边界：整个场景的 `grid_bounds`、本次 compute 已上传或可读的 `sample_bounds`，以及本次允许写入和标 dirty 的 `write_bounds`。不要把它们混成一个判断。

| 情况 | 读取语义 | 放置影响 |
| --- | --- | --- |
| 在 `grid_bounds` 内，存在 committed `SceneVoxel` | 读取已提交的 scene / collision 值 | 按正常 collision、overlap、support 规则累计 |
| 在 `grid_bounds` 内，没有 `SceneVoxel` key | 视为默认空体素：`scene = 0`、`collision = 0`、`occupied = false` | 可以放置；但它本身不提供支撑 |
| 在 `grid_bounds` 内，存在 `value = 0.0` 的空 `SceneVoxel` | 视为显式空体素，保留 erase / override 语义 | occupancy 与缺省空相同，但 CPU 侧保留编辑语义 |
| 在 `grid_bounds` 内，但超出 `sample_bounds` | 不采样，标记 `SAMPLE_IGNORED` | 不累计 collision / overlap / support，也不因此 reject |
| 超出 `grid_bounds` | 不采样、不写入，标记 `SAMPLE_IGNORED` | 不累计 collision / overlap / support，也不因此 reject；不要 clamp 到边界 |
| 超出 `write_bounds` | 不写入 GPU buffer / texture | scoring 阶段应已避免；如果发生只记录 debug 计数 |

也就是说，逻辑上的 sparse 缺项可以当成空；GPU residency 或 grid 边界之外的缺项只当成 ignored，不当成 empty，也不当成 occupied。`GlobalVoxelField` 或 sparse tile 没有某个 tile，只能在确认该 tile 已经覆盖到本次 `sample_bounds` 后才解释为“全空”。

shader 里建议统一走 safe sample helper，而不是在 footprint loop 里直接算 index：

```glsl
// sketch only
bool in_grid_bounds(ivec3 p) {
    return p.x >= 0 && p.x < grid_size.x
        && p.y >= 0 && p.y < grid_size.y
        && p.z >= 0 && p.z < grid_size.z;
}

bool in_sample_bounds(ivec3 p) {
    return all(greaterThanEqual(p, sample_min))
        && all(lessThan(p, sample_max));
}

VoxelSample sample_scene_voxel(ivec3 p) {
    VoxelSample s;
    s.scene = 0.0;
    s.collision = 0.0;
    s.flags = 0u;

    if (!in_grid_bounds(p)) {
        s.flags |= SAMPLE_IGNORED;
        return s;
    }
    if (!in_sample_bounds(p)) {
        s.flags |= SAMPLE_IGNORED;
        return s;
    }

    int i = voxel_index(p);
    s.scene = scene_occupancy[i];
    s.collision = collision_occupancy[i];
    return s;
}
```

footprint 测试时建议累计额外分量：

```text
ignored_sample += sample has SAMPLE_IGNORED ? weight : 0

if sample has SAMPLE_IGNORED:
  continue

valid is not changed by ignored samples
```

`support` 的边界仍然要保守：如果 `world_voxel + ivec3(0, -1, 0)` 被标记为 `SAMPLE_IGNORED`，它不算支撑命中，也不算失败。不要把边界 clamp 到 `y = 0`，否则候选会从不存在的体素获得假支撑。如果确实需要“地面边界就是支撑”，应显式加入 terrain / base `SceneVoxel`，或单独增加 `implicit_floor_support` 开关，避免默认行为和场景语义混在一起。

按需上传 GPU 数据时，上传范围需要包含候选范围外扩的 halo。这里不要只用一个固定 `max_footprint_radius`；长条形石头、倒木、横向岩脊这类 asset 的 footprint 可能在某个轴上很长、另一个轴上很窄。更稳的做法是为每个 asset 的每个 `rotation_index` / `scale_index` 预计算采样包围盒：

| Bounds | Meaning |
| --- | --- |
| `footprint_sample_min` / `footprint_sample_max` | footprint 正常碰撞和 scene overlap 会采样的局部体素范围 |
| `support_sample_min` / `support_sample_max` | support 检查会额外访问的局部范围，通常包含 `Y - 1` |
| `clearance_sample_min` / `clearance_sample_max` | clearance 检查会额外访问的局部范围，通常包含当前层和上方几层 |
| `stamp_write_min` / `stamp_write_max` | placement 通过后会实际写入 scene / collision voxel 的局部范围 |

候选范围上传时使用这些 AABB 的并集：

```text
sample_bounds = candidate_bounds
  expanded by rotated footprint_sample bounds
  expanded by rotated support_sample bounds
  expanded by rotated clearance_sample bounds
  clipped to grid_bounds

write_bounds = accepted_candidate_bounds
  expanded by rotated stamp_write bounds
  clipped to grid_bounds
```

如果某个 candidate 的 footprint、support 或 clearance 采样会碰到 `sample_bounds` 外侧，第一版直接标记为 `SAMPLE_IGNORED` 并跳过该采样点。这样长条 asset 不会因为端点越过局部上传范围而整块失败；代价是评分只代表已采样到的部分，`ignored_sample` 必须作为 debug 分量输出。

长条 asset 还需要一个额外规则：candidate 的 owner tile 只负责“谁来评分这个 origin”，不代表 footprint 只能访问这个 tile。一个 `8x8x8` candidate tile 可能需要读取横跨多个 voxel tile 的 scene / collision 数据，也可能在 stamp 时写多个 tile。因此：

- `TileTopKBuffer.tile_id` 记录 origin 所在 tile，用于归属和去重。
- `sample_bounds` 记录该 tile 评分时真正读到的范围，用于 GPU 上传和 ignored 判断。
- `stamp_write_bounds` 记录通过后真正写入的范围，用于标记所有受影响 dirty tile。
- 如果某个 asset 的 `footprint_sample` 超过本次局部上传预算，远端缺失标记为 ignored，不要把它当作空；后续可以按 `ignored_sample` 比例降低优先级、补传重测，或交给长物体专用 pass。

对非常长的石头，第一版可以直接使用 ignore 路径：`candidate_origin + footprint_sample_aabb` 超出 `grid_bounds` 或 `sample_bounds` 的部分不参与 collision、overlap、support 和 clearance。后续优化可以把长 footprint 分成多个 segment，每个 segment 记录自己的局部 AABB 和权重，先统计每段 `ignored_sample`，再决定是否补传或降权。

## Score 建议

```text
score =
  support_ratio       * support_weight
  - solid_collision   * collision_penalty
  - scene_overlap     * overlap_penalty
  - clearance_overlap * clearance_penalty
```

如果提供 `target_occupancy`，它首先作为目标 mask 使用：

```text
if target_occupancy[candidate_origin] <= 0.01:
  reject candidate
```

也就是说，`TargetSceneVoxel` / target occupancy 中复杂度为 `0` 的区域表示“不在目标放置范围内”，即使物理约束可通过也不会被选择。

推荐先输出 debug 分量，不要只输出一个总分：

| 分量 | 说明 |
| --- | --- |
| `support_ratio` | 支撑点通过比例 |
| `solid_collision` | 超过 solid 阈值的 footprint 碰撞累计量 |
| `scene_overlap` | 低硬度 footprint 的 scene overlap 加权量 |
| `clearance_overlap` | clearance 区域被占用量 |
| `ignored_sample` | 超出 `grid_bounds` 或 `sample_bounds` 后被跳过的采样权重；默认不参与 score |
| `target_coverage` | footprint 覆盖到非零 target 的加权比例；有 target 时必须大于 0 |
| `target_density` | footprint 下 target value 的平均密度 |
| `target_value_fit` | target value 与 footprint degree 的匹配度 |
| `target_color_fit` | target color 与 asset color 的匹配度 |
| `valid` | 最后结算后是否通过阈值 |

## Compute Pass 最小链路

当前只需要三步，不必一开始做完整复杂 pipeline。第一版使用 `8^3` workgroup 做 tile 内评分和小汇总，再用后续 pass 做大汇总。

| Pass | 做什么 | 输出 |
| --- | --- | --- |
| `score_voxel_tile` | 一个 `8x8x8` workgroup 处理一个 candidate tile，载入 footprint chunk，采样体素场 | `TileTopKBuffer` |
| `reduce_voxel_tiles` | 汇总多个 tile 的 top K，选出区域或资产级最佳候选 | `PlacementResultBuffer` |
| `stamp_voxel_field` | 按 `PlacementResultBuffer` 在 GPU 上写入 scene / collision voxel delta | `SceneOccupancyOut`、`CollisionOccupancyOut`、`VoxelStampDeltaBuffer` |

粗放置判断和 voxel 场更新尽量保持 GPU-only。CPU 不参与每个候选的写入和测试，只在最终需要实例化 Godot 节点、保存 `voxel_record` 或调试时读回 compact result。

```text
PlacementResultBuffer
  -> stamp_voxel_field
  -> SceneOccupancyOut / CollisionOccupancyOut
  -> next score_voxel_tile pass can test updated field
  -> optional CPU readback for scene instances / persistence
```

## Workgroup 映射

推荐先用简单映射：

```text
workgroup = one asset + one 8x8x8 candidate tile
local invocation = one candidate voxel inside the tile
shared memory = current asset footprint chunk + tile topK scratch
```

第一版建议：

```text
local_size_x = 8
local_size_y = 8
local_size_z = 8
candidate_count_per_group = 512
```

`8^3` group 的好处是每个线程天然对应一个候选体素，group 内可以直接做 shared memory 小汇总。它比 `16^3` 更容易满足 GPU 的 workgroup invocation 限制，也更适合先做正确性验证。

## 感受野扩大

每个线程不一定只测试自己的一个 voxel。可以让每个线程用 `for` 循环测试附近偏移，扩大候选的感受野：

```text
base_candidate = tile_origin + local_id

for dz in search_offsets_z:
  for dy in search_offsets_y:
    for dx in search_offsets_x:
      candidate = base_candidate + ivec3(dx, dy, dz)
      test candidate with shared AssetFootprint
      keep best local candidate for this thread
```

这样一个 `8^3` group 可以覆盖比 `8x8x8` 更大的有效搜索范围，同时不需要把 workgroup 扩成 `16^3`。需要注意：扩大感受野后，不同 group 可能测试到重叠候选，所以后续大汇总 pass 需要做去重或距离过滤。

感受野扩大只决定“origin 往哪里搜索”，不应该被拿来近似 footprint 的实际访问范围。长条 asset 的 `search_offsets` 可能很小，但它的 `footprint_sample_aabb` 很大；上传、采样和 dirty 标记都必须按 footprint AABB 计算，而不是按 search radius 计算。

## Tile 内小汇总

每个线程先得到自己的 best candidate，然后在 group 内用 shared memory 做 top K 小汇总。

```text
thread local best
  -> shared score / pose scratch
  -> barrier
  -> group reduce to tile top K
  -> write TileTopKBuffer
```

建议第一版每个 tile 输出 `top 4` 或 `top 8`，不要只输出 top 1。只输出 top 1 容易让一个高分候选遮掉同一 tile 内另一个也可用的位置。

小汇总输出字段：

| 字段 | 说明 |
| --- | --- |
| `tile_id` | 来源 tile |
| `asset_index` | 资产编号 |
| `voxel_origin` | 候选落点 |
| `rotation_index` | `0-23` 绕 Y yaw 角索引 |
| `scale_index` | 离散缩放 |
| `score` | 总分 |
| `debug` | support / collision / overlap 分量 |

## 大汇总 Pass

`reduce_voxel_tiles` 读取所有 tile 的 top K，再按资产、区域或全局需求汇总。

```text
TileTopKBuffer
  -> optional distance dedup
  -> optional per-asset quota
  -> global / region top K
  -> PlacementResultBuffer
```

大汇总应该处理：

- 不同 tile 的感受野重叠。
- 同一资产的数量上限。
- 候选之间的最小距离。
- 多资产之间的优先级或随机权重。

## 放置结果

GPU 输出不需要直接生成完整 Godot `Dictionary` 形式的 `voxel_record`，但应保留足够生成实例、保存记录和继续 GPU 测试的 compact pose / stamp delta。

| 字段 | 说明 |
| --- | --- |
| `voxel_origin` | 候选落点体素坐标 |
| `asset_id` / `asset_index` | 选择的物体 |
| `rotation_index` | `0-23` 绕 Y yaw 角索引，每次 candidate 只选一个 |
| `scale_index` | 离散缩放编号，先不要做任意连续缩放 |
| `score` | 总分 |
| `debug` | support / collision / overlap 等分量 |

先使用 `24` 个绕 Y 的固定 yaw 角和离散缩放更稳。连续旋转会让 footprint 采样、碰撞和支撑判断复杂很多。`rotation_index` 可以由 asset seed、tile id、candidate voxel 和 generation seed 哈希得到，使每次放置只有一个 yaw 姿态被测试。

## 先做的最小原型

1. 选一个小岩石或树干 asset，手工生成 32-128 个带 `collision_degree` 和 `support` flag 的 footprint voxels。
2. 准备一个小的 `CollisionOccupancy` 体素场。
3. 写 `score_voxel_tile.glsl`，使用 `8x8x8` local size。
4. 每个线程用 `for` 循环扩大局部搜索范围，并测试 shared `AssetFootprint`。
5. group 内用 shared memory 汇总 `top 4` 或 `top 8`。
6. 加 `reduce_voxel_tiles.glsl`，做跨 tile 大汇总和去重。
7. 加 `stamp_voxel_field.glsl`，直接在 GPU 上写 `SceneOccupancyOut` / `CollisionOccupancyOut`。
8. 再跑一次 `score_voxel_tile.glsl`，确认新写入的 voxel 会影响下一轮判断。
9. 只在调试或实例化阶段读回 `PlacementResultBuffer` / `VoxelStampDeltaBuffer`。

## 关键问题

- Footprint 最大共享内存预算是多少？建议先限制为 `128` 个 voxel。
- 旋转使用多少离散角度？建议使用绕 Y 轴的 `24` 个 yaw 角；每次放置只随机或哈希选择一个 `rotation_index`。
- 体素场用 3D texture 还是 storage buffer？如果需要随机读写和紧凑布局，优先 storage buffer。
- 支撑规则按“下方一层 occupied”还是按 normal / surface 类型判断？最小版本先用下方占用。
- `solid_threshold` 取多少？建议先用 `192/255`，低于阈值只给 overlap penalty，高于阈值累计到 `solid_collision`，最后统一结算。
- `8^3` group 的感受野扩大到多大？建议先只扩一圈或按 asset 半径设置固定 offset。
- 长条 asset 的 footprint 访问会跨多远？需要按 `rotation_index` / `scale_index` 预计算 `footprint_sample_aabb`，不要用 search radius 近似。
- Tile 内输出 `top K` 取多少？建议先用 `4`，候选密集时再提高到 `8`。
- CPU 仅负责 `instantiate_placement()` 创建节点，不做额外 mesh 级筛选。
- GPU stamp 后如何和 CPU 侧 `voxel_record` 同步？建议先把 GPU result 当作生成缓存，只有最终落地实例时才读回 compact pose 并生成记录。
