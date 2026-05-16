# Scene Voxel Field System

本文整理 MeshFill-Godot 的场景体素场分层、source voxel delta 写入规则、`SceneVoxel` 基类字段、提交规则，以及 `CollisionVoxel` 和 `GlobalVoxelField` 的职责边界。

![MeshFill current framework overview](../graphs/meshfill_current_framework.svg)

核心目标：

- 资产只保存默认语义，不直接修改最终场景。
- 自动生成、目标引导和画笔编辑先写 source voxel delta，再由统一 blend 阶段提交。
- `collision_voxels` 与 `color`、`complexity` 一样是资产 / record / source voxel 的同级语义字段。
- `SceneVoxel` 是提交后的唯一 read model；`collision_voxels` 可作为同级提交字段保留，`collision_occupancy` 才是由它派生的查询缓存。
- `SceneVoxel` 构建时必须把地形高度以下视为保底 collision，后续 source voxel delta 不能覆盖或清除这部分碰撞。
- `GlobalVoxelField` 是当前物理查询缓存；`Global Distance Field` 只是 UE 类比和未来可选升级方向。

## 分层

| 层 | MeshFill 角色 | UE 类比 | 读写原则 |
| --- | --- | --- | --- |
| 资产默认值 | `AutoVoxelDescriptor` / `AutoObject.voxel_descriptor` / `AutoVoxelProfile` | `Mesh Distance Field` 的资产侧输入 | descriptor 保存对象默认语义、visual bands、collision 声明和 probes；`AutoObject` 同名字段只作为兼容入口 |
| 目标画布 | `TargetSceneVoxel` | 目标形状 / 引导场 | 表达期望颜色、复杂度、占用和碰撞意图，不写 asset 标签；普通 target source 不提交最终 `collision_voxels` 字段 |
| 来源体素 delta | `SourceSceneVoxel` / `AutoSceneVoxel` / `BrushSceneVoxel` / `TargetSceneVoxel` | 单个 instance 或编辑操作的 update field | 只写当前 tick 的写入意图；`color`、`complexity`、`collision_voxels` 都是 source 语义字段 |
| 提交结果 | `SceneVoxel` | 合并后的场景状态 | `blend_scene_voxels()` commit 后的唯一可读结果；包含基类字段、commit 字段和同级 `collision_voxels` 字段 |
| 物理查询缓存 | `GlobalVoxelField` / scene voxel cache | 可选类比 `Global Distance Field` | 只读 committed `SceneVoxel` 的 scene / collision occupancy 派生视图并做 dirty 重建；当前是 sparse occupancy，不是 signed distance |

### 关于 `Global Distance Field`

UE 的 `Global Distance Field` 通常是把多个 mesh distance fields 合并成全局 signed distance clipmap，用于 GPU 查询、遮挡、粒子碰撞或全局近似距离采样。

MeshFill 当前不需要直接实现这个概念。当前需要的是：

```text
committed SceneVoxel
  -> scene occupancy view
  -> collision_voxels field
  -> collision occupancy cache/view
  -> rebuild dirty tiles
  -> GlobalVoxelField.scene_occupancy
  -> GlobalVoxelField.collision_occupancy
  -> placement / validation / debug query
```

因此文档里说“物理缓存”时，当前含义是 `GlobalVoxelField` 的稀疏 occupancy tile cache。只有当后续需要距离查询、软碰撞、GPU 大范围近似查询或多分辨率常驻缓存时，才考虑升级成 signed distance / clipmap。

## `CollisionVoxel` 归属

`CollisionVoxel` 不作为独立来源场存在，也不是 `SceneVoxel` 的下级对象。它是与 `color`、`complexity`、`affected_bands` 同级的 collision 语义字段，用来描述刚性或互斥占用：

```text
AutoSceneVoxel
  color / complexity
  visual layer fields (SenceLayerVoxel legacy/deprecated)
  collision_voxels: Array[CollisionVoxel]

BrushSceneVoxel
  color / complexity
  visual layer fields (SenceLayerVoxel legacy/deprecated)
  collision_voxels: Array[CollisionVoxel]
  modified_voxels
  auto_mix
```

含义：

- 自动放置的岩石、树干等刚性部分写入 `AutoSceneVoxel.collision_voxels`。
- 画笔、擦除、手动 blocker 等写入 `BrushSceneVoxel.collision_voxels`。
- `collision_voxels` 在 source record、source voxel 和 committed `SceneVoxel` 中都应按同级字段理解；不要把它画成 `SceneVoxel` 的子层级。
- commit 后可以生成 `_collision_occupancy`、`_volume["collision_occupancy"]` 或 `GlobalVoxelField.collision_occupancy`，但这些是由 committed `SceneVoxel.collision_voxels` 派生的查询缓存，不是新的 source layer，也不是新的语义归属。

## 数据流

```text
AutoVoxelDescriptor / brush edit / target guidance
  -> make_*_scene_voxel_record()
  -> SourceSceneVoxelDelta[tick]
      SceneVoxel base fields
      AutoSceneVoxel / BrushSceneVoxel / TargetSceneVoxel source fields
      visual layer fields
      collision_voxels field
  -> blend_scene_voxels(tick)
  -> SceneVoxel[tick]
      SceneVoxel base fields
      collision_voxels field
      commit fields
      scene_occupancy view
      collision_occupancy derived view
  -> rebuild_global_voxel_field()
  -> GlobalVoxelField {
       scene_occupancy,
       collision_occupancy,
       dirty_tiles
     }
```

`TargetSceneVoxel` 只作为引导和 scoring 输入。它可以影响 placement mask、target fit 和候选路由，但普通 target source 不直接提交最终 `collision_voxels` 字段；只有最终实际放置或画笔编辑产生的 `AutoSceneVoxel` / `BrushSceneVoxel` 才写 collision 语义字段。

## `SceneVoxel` 基类成员变量

当前实现以 `Dictionary` 表达 `SceneVoxel`，不是独立 GDScript class。概念上，`_make_scene_voxel()` 生成下列基类字段；`AutoSceneVoxel`、`BrushSceneVoxel` 和 `TargetSceneVoxel` 在提交前继承这些字段并追加 source 字段；`blend_scene_voxels()` 提交后统一归一为 `type = "SceneVoxel"`。

| 字段组 | 成员变量 | 语义 |
| --- | --- | --- |
| 基本状态 | `type`、`occupied`、`value`、`complexity`、`color`、`collision_voxels` | `type` 在提交后为 `SceneVoxel`；`value` 是占用 / 强度标量；`complexity` 当前跟随 `value`；`color.a` 写入最终强度；`collision_voxels` 是同级 collision 语义字段。 |
| 体素坐标 | `slice_index`、`voxel_xz`、`base_pixel`、`volume_xz_resolution` | 描述该 scene voxel 所在的 `Y` slice、`XZ` 体素 / 像素坐标和体积分辨率。 |
| visual layer | `band`、`channel` | 记录该 voxel 来自哪个视觉 band / channel；`SenceLayerVoxel` 已暂时废弃，不作为新 schema，只因运行时 legacy record 兼容而仍可能出现。 |
| 对象标识 | `record_id`、`mesh_name`、`node_path`、`object_type`、`object_subtype`、`auto_source` | 用于 debug、查询和回查来源对象；不是资产默认值来源。 |
| 实例标识 | `auto_id` / `auto_object_id`、`auto_instance_id` / `instance_id`、`instance_mesh_id` / `mesh_instance_id` | 连接 committed voxel、runtime object 和 metadata 索引的 id 组。 |
| commit 归属 | `source_voxel_types`、`dominant_source_type`、`blend_mode`、`commit_tick` | 由 `_finalize_scene_voxel_from_source()` 或 `_merge_voxel_sources()` 在提交时写入，记录本 voxel 由哪些 source 合成、最终主导来源和提交 tick。 |
| collision 查询视图 | collision occupancy cache/view | `collision_occupancy` 是从 committed `SceneVoxel.collision_voxels` 重建的派生查询缓存，供 `GlobalVoxelField` 和查询系统读取。 |

### `SourceSceneVoxel` 扩展字段

| 来源类型 | 追加字段 | 语义 |
| --- | --- | --- |
| `SourceSceneVoxel` shared | `source_voxel_type`、`source_kind`、`producer_stage`、`generation_tick`、`read_tick`、`write_tick`、可选 `priority` | 提交前的写入意图、来源分类和 tick 上下文；冲突处理时可用 `priority`。 |
| `AutoSceneVoxel` | `collision_voxels`、legacy `SenceLayerVoxel` | 自动放置系统写出的 visual / collision 同级语义字段；`SenceLayerVoxel` 已暂时废弃，仅表示旧 record 中的 visual layer list。 |
| `BrushSceneVoxel` | `collision_voxels`、legacy `SenceLayerVoxel`、`brush_stroke_id`、`modified_voxels`、`auto_mix` | 画笔或手动编辑写出的同级语义字段和编辑上下文；`SenceLayerVoxel` 已暂时废弃，`modified_voxels` 限定本次编辑接管范围。 |
| `TargetSceneVoxel` | `target_mix`、`target_pipeline` | 目标引导 source；参与混合、routing 和 scoring，但普通 target source 不提交最终 `collision_voxels` 字段。 |

## `voxel_record`

`voxel_record` 是运行时 placement / source voxel record，由 `AutoAssetFactory.make_profile_scene_voxel_record()`、typed wrapper 或 placement builder 生成。它把一次实例落点、视觉 band、collision 声明和 source 上下文交给 `apply_mesh_voxel_record()`，后续再写入 source voxel delta 并由 `blend_scene_voxels()` 提交。

| 字段 | 含义 |
| --- | --- |
| `id` | record id。 |
| `type` | 对象大类，如 `rock`、`vegetation`。 |
| `position` / `rotation_degrees` / `scale` | 本次实例的世界变换；`rotation_mode` 当前写为 `XYZ`。 |
| `base_pixel` / `voxel_xz` | XZ 像素 / 体素坐标。 |
| `volume_xz_resolution` | 目标体素体积 XZ 分辨率。 |
| `color` / `complexity` | 本次 source visual 默认值。 |
| `affected_bands` | 从资产 descriptor / profile 取出的 band 声明。 |
| `collision_voxels` | 与 `color` / `complexity` 同级的 collision 语义字段；由 descriptor / profile 或画笔输入派生。 |
| `SenceLayerVoxel` | 暂时废弃字段；旧 record 中可能保存由 `affected_bands` 派生的 visual layer 列表，新文档和新数据结构不应继续把它当作标准 schema。 |
| `source_voxel_type` | `AutoSceneVoxel`、`BrushSceneVoxel` 或 `TargetSceneVoxel`。 |
| `source_kind` | 来源种类，如 `rock_placement`、`scatter`、`brush`、`target`。 |
| `producer_stage` | 生产阶段；默认等于 `source_kind`。 |

`TargetSceneVoxel` record 只作为目标画布 / guidance 输入；普通 target source 不提交最终 `collision_voxels` 字段。`AutoObject` 和 metadata 可以保存 `voxel_record` handle 方便查询，但不能把它当作资产默认值来源。

## 地形保底碰撞

`SceneVoxel` 构建必须先写入 terrain base collision：对每个 `XZ` 位置，地形高度图高度以下的所有 `Y` slice 都视为刚体占用。

这部分 collision 是场景基础约束，不属于 `AutoSceneVoxel`、`BrushSceneVoxel` 或 `TargetSceneVoxel` 的普通覆盖范围：

- 自动放置只能在地形保底 collision 之上追加 visual / collision 语义字段，不允许把地形以下 collision 写成空。
- 画笔编辑可以覆盖普通 source voxel，但不能 erase 或降低地形高度以下的保底 collision。
- `TargetSceneVoxel` 的目标 mask 或目标 collision 意图不能清除 terrain base collision。
- `blend_scene_voxels()` 合成后重建 collision occupancy 时，必须保留 terrain base collision，再叠加 committed `SceneVoxel.collision_voxels` 同级字段。
- 如果后续需要挖洞、洞穴、地道或地下空间，应显式增加 terrain cut / carve source 类型；不能复用普通 erase 语义绕过该不变量。

## 字段职责

| 层 | 关键字段 | 说明 |
| --- | --- | --- |
| `AutoVoxelDescriptor` / `AutoObject.voxel_descriptor` | `voxel_descriptor` 持有 `color`、`complexity`、`affected_bands`、`collision_voxels`、`pivot_variants`、`semantic_probe_profile`、`semantic_probe_density`、`context_sensing_radius`；`AutoObject` 保留同名旧入口和 `min_spacing`、`bound_min_length` | descriptor 是资产默认语义唯一权威来源；`AutoObject` 同名字段只作为 legacy / Inspector / 配置字典兼容入口，不能作为新的语义状态来源。 |
| `SourceSceneVoxel` | `source_voxel_type`、`source_kind`、`producer_stage`、`generation_tick`、`read_tick`、`write_tick` | `AutoSceneVoxel` / `BrushSceneVoxel` 的共同上下文字段。 |
| `AutoSceneVoxel` | `color`、`complexity`、`collision_voxels`、legacy `SenceLayerVoxel`、`source_kind` | 自动系统输出的当前 tick source voxel delta；`collision_voxels` 与 `color` / `complexity` 同级，`SenceLayerVoxel` 已暂时废弃，仅保留运行时兼容说明。 |
| `BrushSceneVoxel` | `color`、`complexity`、`collision_voxels`、legacy `SenceLayerVoxel`、`modified_voxels`、`auto_mix` | 画笔或手动编辑输出的当前 tick source voxel delta；`collision_voxels` 与 `color` / `complexity` 同级，`SenceLayerVoxel` 已暂时废弃，仅保留运行时兼容说明。 |
| `SceneVoxel` | `color`、`complexity`、`collision_voxels`、`source_voxel_types`、`dominant_source_type`、`blend_mode`、`priority`、`commit_tick` | 描述最终混合结果；`collision_voxels` 是同级提交字段，collision occupancy cache/view 是提交后的派生查询视图。 |
| Terrain base collision | terrain height map、`XZ`、`Y` slice | `SceneVoxel` 构建时的不可覆盖基础碰撞；地形高度以下始终写入派生 collision occupancy view。 |
| `GlobalVoxelField` | `scene_occupancy`、`collision_occupancy`、`dirty_tiles`、`tile_id`、`bounds` | 当前为从 committed `SceneVoxel` 读取的 sparse occupancy tile cache，服务 placement、validation 和 debug query。 |

## 体素写入规则

当前运行时代码把全局写入规则收敛到 `scripts/vegetation_exclusion.gd`：

| 规则 | 代码入口 | 结果 |
| --- | --- | --- |
| source 只写当前 tick | `apply_mesh_voxel_record()`、`_prepare_source_record()` | 重复提交旧 `voxel_record` 时会把 `generation_tick` 和 `write_tick` 重新绑定到本次 tick。 |
| source voxel delta 分支 | `_source_delta_branch()`、`_write_source_voxel_delta()` | `AutoSceneVoxel` 写入 `auto`，`BrushSceneVoxel` 写入 `brush`，`TargetSceneVoxel` 写入 `target`。 |
| 同 key 冲突按来源优先级处理 | `_source_beats_current()` | `BrushSceneVoxel` 默认优先级高于 `TargetSceneVoxel`，`TargetSceneVoxel` 高于 `AutoSceneVoxel`。 |
| brush 只接管声明范围 | `_source_modifies_key()`、`modified_voxels` | `modified_voxels` 为空表示本次 stamp footprint 全接管；非空时只影响列出的 voxel key。 |
| collision 与 color / complexity 同级 | `_make_source_scene_voxel()`、`_finalize_scene_voxel_from_source()` | 从 record 的 `collision_voxels` 传递到 source voxel 和 committed `SceneVoxel`，作为同级语义字段参与提交。 |
| 派生 collision occupancy | `_stamp_collision_voxels()`、`_stamp_collision_volume()`、`_rebuild_collision_cache_from_scene_voxels()` | 从 committed `SceneVoxel.collision_voxels` 重建查询缓存；缓存不改变 collision 语义归属。 |
| 地形以下 collision 不可覆盖 | `SceneVoxel` 构建 / collision occupancy rebuild | terrain height 以下的 `Y` slices 始终保持 collision；普通 auto / brush / target 写入不能 erase 或降低该值。 |
| 0 值主动编辑也要写 source | `_stamp_volume_slices()` | `erase` / `BrushSceneVoxel` 可以写入 `value = 0.0`，用未占用结果覆盖上一轮结果。 |
| 最终状态只在 blend 发布 | `blend_scene_voxels()` | 只有 `SceneVoxel[commit_tick]` 暴露给查询、验证和全局缓存。 |
| 全局缓存只读 committed occupancy | `_rebuild_global_voxel_field()` | 读取已提交 `SceneVoxel` 的 scene / collision occupancy 视图，重建 dirty tile cache。 |

## 当前实现边界

- `AutoObject` 只作为运行时节点通过 descriptor-backed getter 提供局部对象语义和默认 collision 声明，不直接改最终场景体素。
- `main.gd` 中的 record builder 会先构建 source 语义，再交给 `blend_scene_voxels()`。
- `blend_scene_voxels()` 是最终提交点，之后 `build_voxel_volume()`、`validate_voxel()` 和查询都读已提交结果。
- `vegetation_exclusion.gd` 当前同时承载 source voxel delta、`SceneVoxel` commit、dirty tile/rect API 和 sparse tile cache。
- `GlobalVoxelField` 独立类已经把来自 committed `SceneVoxel` 的 `scene_occupancy` 和派生 `collision_occupancy` 视图拆成两个 buffer，供 `VoxelPlacementGenerator` 做 physical scoring。
- `CollisionVoxel` 的设计归属是和 `color` / `complexity` 同级的 voxel 语义字段；提交后的 collision buffer / collision occupancy 是从该字段重建的派生查询视图。

## 后续升级顺序

1. 保持 `AutoVoxelDescriptor` 作为资产默认语义唯一主归属。
2. 保持 `AutoSceneVoxel` / `BrushSceneVoxel` 作为 source voxel delta 归属。
3. 将 `collision_voxels` 明确作为与 `color` / `complexity` 同级的 voxel 语义字段处理。
4. 保持 `blend_scene_voxels()` 为唯一提交点。
5. 保持 `GlobalVoxelField` 作为 sparse occupancy cache。
6. 只有需要距离查询时，再考虑 signed distance / clipmap 版本。
