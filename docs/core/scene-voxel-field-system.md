# Scene Voxel Field System

本文整理 MeshFill-Godot 的场景体素场分层、source delta 写入规则、`SceneVoxel` 提交规则，以及 `CollisionVoxel` 和 `GlobalVoxelField` 的职责边界。

核心目标：

- 资产只保存默认语义，不直接修改最终场景。
- 自动生成和画笔编辑先写 source delta，再由统一 blend 阶段提交。
- `CollisionVoxel` 是 `AutoSceneVoxel` / `BrushSceneVoxel` 的 collision 成员，不是独立的顶层来源场。
- `SceneVoxel` 构建时必须把地形高度以下视为保底 collision，后续 source delta 不能覆盖或清除这部分碰撞。
- `GlobalVoxelField` 是当前物理查询缓存；`Global Distance Field` 只是 UE 类比和未来可选升级方向。

## 分层

| 层 | MeshFill 角色 | UE 类比 | 读写原则 |
| --- | --- | --- | --- |
| 资产默认值 | `AutoObject` / `AutoVoxelProfile` | `Mesh Distance Field` 的资产侧输入 | 只保存对象默认语义、visual bands、collision 声明和 probes |
| 目标画布 | `TargetSceneVoxel` | 目标形状 / 引导场 | 表达期望颜色、复杂度、占用和碰撞意图，不写 asset 标签 |
| 来源场 | `AutoSceneVoxel` / `BrushSceneVoxel` | 单个 instance 的 update field | 只写当前 tick 的 delta，包含 visual layers 和 `collision_voxels` |
| 逻辑结果 | `SceneVoxel` | 合并后的场景状态 | `blend_scene_voxels()` commit 后的唯一可读结果 |
| 物理查询缓存 | `GlobalVoxelField` / scene voxel cache | 可选类比 `Global Distance Field` | 只读快照 + dirty 重建；当前是 sparse occupancy，不是 signed distance |

### 关于 `Global Distance Field`

UE 的 `Global Distance Field` 通常是把多个 mesh distance fields 合并成全局 signed distance clipmap，用于 GPU 查询、遮挡、粒子碰撞或全局近似距离采样。

MeshFill 当前不需要直接实现这个概念。当前需要的是：

```text
committed SceneVoxel / collision occupancy
  -> rebuild dirty tiles
  -> GlobalVoxelField.scene_occupancy
  -> GlobalVoxelField.collision_occupancy
  -> placement / validation / debug query
```

因此文档里说“物理缓存”时，当前含义是 `GlobalVoxelField` 的稀疏 occupancy tile cache。只有当后续需要距离查询、软碰撞、GPU 大范围近似查询或多分辨率常驻缓存时，才考虑升级成 signed distance / clipmap。

## `CollisionVoxel` 归属

`CollisionVoxel` 不作为独立来源场存在。它应是来源体素的一组成员，用来描述刚性或互斥占用：

```text
AutoSceneVoxel
  visual_layers / SenceLayerVoxel
  collision_voxels: Array[CollisionVoxel]

BrushSceneVoxel
  visual_layers / SenceLayerVoxel
  collision_voxels: Array[CollisionVoxel]
  modified_voxels
  auto_mix
```

含义：

- 自动放置的岩石、树干等刚性部分写入 `AutoSceneVoxel.collision_voxels`。
- 画笔、擦除、手动 blocker 等写入 `BrushSceneVoxel.collision_voxels`。
- `CollisionVoxel` 不混入生态可视 band，也不替代 `SceneVoxel`。
- commit 后可以生成 `_collision_occupancy`、`_volume["collision_occupancy"]` 或 `GlobalVoxelField.collision_occupancy`，但这些是缓存或查询视图，不是新的 source layer。

## 数据流

```text
AutoObject fields / brush edit / target guidance
  -> make_*_scene_voxel_record()
  -> AutoSceneVoxelDelta[tick] / BrushSceneVoxelDelta[tick]
      visual layers
      collision_voxels
  -> blend_scene_voxels(tick)
  -> SceneVoxel[tick]
  -> rebuild_global_voxel_field()
  -> GlobalVoxelField {
       scene_occupancy,
       collision_occupancy,
       dirty_tiles
     }
```

`TargetSceneVoxel` 只作为引导和 scoring 输入。它可以影响 placement mask、target fit 和候选路由，但不直接产生最终 `CollisionVoxel`；只有最终实际放置或画笔编辑产生的 `AutoSceneVoxel` / `BrushSceneVoxel` 才写 collision 成员。

## `voxel_record`

`voxel_record` 是运行时 placement / source voxel record，由 `AutoAssetFactory.make_profile_scene_voxel_record()`、typed wrapper 或 placement builder 生成。它把一次实例落点、视觉 band、collision 声明和 source 上下文交给 `apply_mesh_voxel_record()`，后续再写入 source delta 并由 `blend_scene_voxels()` 提交。

| 字段 | 含义 |
| --- | --- |
| `id` | record id。 |
| `type` | 对象大类，如 `rock`、`vegetation`。 |
| `position` / `rotation_degrees` / `scale` | 本次实例的世界变换；`rotation_mode` 当前写为 `XYZ`。 |
| `base_pixel` / `voxel_xz` | XZ 像素 / 体素坐标。 |
| `volume_xz_resolution` | 目标体素体积 XZ 分辨率。 |
| `color` / `complexity` | 本次 source visual 默认值。 |
| `affected_bands` | 从资产 descriptor / profile 取出的 band 声明。 |
| `collision_voxels` | source voxel 的 collision 成员。 |
| `SenceLayerVoxel` | 由 `affected_bands` 派生的 visual layer 列表。 |
| `source_voxel_type` | `AutoSceneVoxel`、`BrushSceneVoxel` 或 `TargetSceneVoxel`。 |
| `source_kind` | 来源种类，如 `rock_placement`、`scatter`、`brush`、`target`。 |
| `producer_stage` | 生产阶段；默认等于 `source_kind`。 |

`TargetSceneVoxel` record 只作为目标画布 / guidance 输入；普通 target source 不生成最终 source collision。`AutoObject` 和 metadata 可以保存 `voxel_record` handle 方便查询，但不能把它当作资产默认值来源。

## 地形保底碰撞

`SceneVoxel` 构建必须先写入 terrain base collision：对每个 `XZ` 位置，地形高度图高度以下的所有 `Y` slice 都视为刚体占用。

这部分 collision 是场景基础约束，不属于 `AutoSceneVoxel`、`BrushSceneVoxel` 或 `TargetSceneVoxel` 的普通覆盖范围：

- 自动放置只能在地形保底 collision 之上追加 visual / collision source，不允许把地形以下 collision 写成空。
- 画笔编辑可以覆盖普通 source voxel，但不能 erase 或降低地形高度以下的保底 collision。
- `TargetSceneVoxel` 的目标 mask 或目标 collision 意图不能清除 terrain base collision。
- `blend_scene_voxels()` 合成后重建 collision occupancy 时，必须保留 terrain base collision，再叠加 committed `SceneVoxel.collision_voxels`。
- 如果后续需要挖洞、洞穴、地道或地下空间，应显式增加 terrain cut / carve source 类型；不能复用普通 erase 语义绕过该不变量。

## 字段职责

| 层 | 关键字段 | 说明 |
| --- | --- | --- |
| `AutoObject` / `AutoVoxelDescriptor` | `voxel_descriptor` 持有 `color`、`complexity`、`affected_bands`、`collision_voxels`、`pivot_variants`；`AutoObject` 保留同名旧入口和 `min_spacing`、`bound_min_length` | descriptor 是资产默认语义主来源；`AutoObject` 同名字段主要用于旧资产、Inspector 和配置字典兼容。 |
| `SourceSceneVoxel` | `source_voxel_type`、`source_kind`、`producer_stage`、`generation_tick`、`read_tick`、`write_tick` | `AutoSceneVoxel` / `BrushSceneVoxel` 的共同上下文字段。 |
| `AutoSceneVoxel` | `SenceLayerVoxel`、`collision_voxels`、`source_kind` | 自动系统输出的当前 tick delta。 |
| `BrushSceneVoxel` | `SenceLayerVoxel`、`collision_voxels`、`modified_voxels`、`auto_mix` | 画笔或手动编辑输出的当前 tick delta。 |
| `SceneVoxel` | `source_voxel_types`、`dominant_source_type`、`blend_mode`、`priority`、`commit_tick` | 描述最终混合结果；不再区分本次来源字段的写入意图。 |
| Terrain base collision | terrain height map、`XZ`、`Y` slice | `SceneVoxel` 构建时的不可覆盖基础碰撞；地形高度以下始终写入 collision cache。 |
| `GlobalVoxelField` | `scene_occupancy`、`collision_occupancy`、`dirty_tiles`、`tile_id`、`bounds` | 当前为 sparse occupancy tile cache，服务 placement、validation 和 debug query。 |

## 体素写入规则

当前运行时代码把全局写入规则收敛到 `scripts/vegetation_exclusion.gd`：

| 规则 | 代码入口 | 结果 |
| --- | --- | --- |
| source 只写当前 tick | `apply_mesh_voxel_record()`、`_prepare_source_record()` | 重复提交旧 `voxel_record` 时会把 `generation_tick` 和 `write_tick` 重新绑定到本次 tick。 |
| source delta 分支 | `_source_delta_branch()`、`_write_source_voxel_delta()` | `AutoSceneVoxel` 写入 `auto`，`BrushSceneVoxel` 写入 `brush`，`TargetSceneVoxel` 写入 `target`。 |
| 同 key 冲突按来源优先级处理 | `_source_beats_current()` | `BrushSceneVoxel` 默认优先级高于 `TargetSceneVoxel`，`TargetSceneVoxel` 高于 `AutoSceneVoxel`。 |
| brush 只接管声明范围 | `_source_modifies_key()`、`modified_voxels` | `modified_voxels` 为空表示本次 stamp footprint 全接管；非空时只影响列出的 voxel key。 |
| collision 来源属于 source voxel | `_stamp_collision_voxels()`、`_stamp_collision_volume()` | 从 record 的 `collision_voxels` 生成 source collision 成员和 committed collision occupancy。 |
| 地形以下 collision 不可覆盖 | `SceneVoxel` 构建 / collision cache rebuild | terrain height 以下的 `Y` slices 始终保持 collision；普通 auto / brush / target 写入不能 erase 或降低该值。 |
| 0 值主动编辑也要写 source | `_stamp_volume_slices()` | `erase` / `BrushSceneVoxel` 可以写入 `value = 0.0`，用未占用结果覆盖上一轮结果。 |
| 最终状态只在 blend 发布 | `blend_scene_voxels()` | 只有 `SceneVoxel[commit_tick]` 暴露给查询、验证和全局缓存。 |
| 全局缓存只读 committed occupancy | `_rebuild_global_voxel_field()` | 读取已提交 `SceneVoxel` 和 collision occupancy，重建 dirty tile cache。 |

## 当前实现边界

- `AutoObject` 只负责产出局部对象语义和默认 collision 声明，不直接改最终场景体素。
- `main.gd` 中的 record builder 会先构建 source 语义，再交给 `blend_scene_voxels()`。
- `blend_scene_voxels()` 是最终提交点，之后 `build_voxel_volume()`、`validate_voxel()` 和查询都读已提交结果。
- `vegetation_exclusion.gd` 当前同时承载 source delta、`SceneVoxel` commit、dirty tile/rect API 和 sparse tile cache。
- `GlobalVoxelField` 独立类已经把 `scene_occupancy` 和 `collision_occupancy` 拆成两个 buffer，供 `VoxelPlacementGenerator` 做 physical scoring。
- `CollisionVoxel` 的设计归属是 source voxel 成员；提交后的 collision buffer / collision occupancy 是缓存视图。

## 后续升级顺序

1. 保持 `AutoObject` 作为默认值主归属。
2. 保持 `AutoSceneVoxel` / `BrushSceneVoxel` 作为 source delta 归属。
3. 将 `collision_voxels` 明确作为 source voxel 成员处理。
4. 保持 `blend_scene_voxels()` 为唯一提交点。
5. 保持 `GlobalVoxelField` 作为 sparse occupancy cache。
6. 只有需要距离查询时，再考虑 signed distance / clipmap 版本。
