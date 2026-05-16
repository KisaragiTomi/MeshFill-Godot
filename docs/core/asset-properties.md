# Asset Properties

![AutoObject asset properties map](../graphs/autoobject_asset_properties.svg)

本文是当前资产字段、descriptor 兼容入口和 metadata 规则的可靠速查。旧版同名文档曾因编码问题变成 mojibake，已不再作为来源；本版以当前 GDScript 为准。

资产语义唯一主来源规则：

- `AutoVoxelDescriptor` 是资产体素语义的唯一权威来源。
- `AutoObject.voxel_descriptor` 是运行时节点持有 descriptor 的入口。
- `AutoObject` 上与 descriptor 重复的语义字段只保留为 legacy / Inspector / 配置字典兼容入口。
- 新代码读取资产语义时必须走 descriptor 或 `AutoObject` 的 descriptor-backed getter。
- 新代码写入资产语义时应优先写 descriptor，再按兼容需要同步旧字段；不要把旧字段当成第二套状态。
- 新增语义字段时默认加到 `AutoVoxelDescriptor`；除非明确是运行时身份、放置约束或调试索引，否则不要再加到 `AutoObject`。

相关边界：

- `meshfill-framework.md` 说明数据归属和主流程。
- `scene-voxel-field-system.md` 说明 `voxel_record`、source voxel delta、`SceneVoxel`、同级 `collision_voxels` 字段和派生 collision cache。
- `asset-semantic-probes.md` 说明资产侧 semantic probes。

## 资产层级

| 类型 | 角色 | 主要文件 |
| --- | --- | --- |
| `AutoObject` | 所有自动放置对象的运行时基类；持有 descriptor 入口和运行时状态 | `scripts/auto_object.gd` |
| `AutoRock` / `AutoCliffRock` | 岩石对象类型 | `scripts/auto_rock.gd` / `scripts/auto_cliff_rock.gd` |
| `AutoVegetation` 及子类 | 植被对象类型 | `scripts/auto_vegetation.gd` 等 |
| `AutoVegetationAsset` | 植被资源定义，可实例化运行时节点 | `scripts/auto_vegetation_asset.gd` |
| `AutoVoxelDescriptor` | 资产默认体素语义、pivot 和 semantic probe 配置的唯一权威来源 | `scripts/auto_voxel_descriptor.gd` |
| `AutoVoxelProfile` | 轻量共享体素 profile，保存颜色、复杂度、bands 和 collision | `scripts/auto_voxel_profile.gd` |
| `AutoAssetFactory` | 脚本化创建资产、profile、descriptor 和 `voxel_record` | `scripts/auto_asset_factory.gd` |

## `AutoObject` 运行时字段 / descriptor 兼容入口

`AutoObject` 是场景里的运行时节点，负责对象身份、来源、mesh、放置约束和运行时 `voxel_record`。资产侧体素语义的唯一权威来源是 `voxel_descriptor`；表中标为“兼容入口”的字段会同步到 descriptor，用来支持旧资产、Inspector 编辑和配置字典，不能作为新的语义状态来源。

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `auto_id` | `String` | 稳定对象 id；为空时可回退到节点名。 |
| `instance_id` | `int` | Godot 运行时实例 id。 |
| `auto_source` | `String` | 来源标记，如 `generated`、`scatter`、`brush`。 |
| `object_type` | `String` | 运行时 grouping / debug metadata；可用于 same-type exclusion，但不是资产默认语义来源。 |
| `object_subtype` | `String` | 运行时 grouping / debug metadata；用于细分同类互斥和记录回查，不作为 descriptor 替代来源。 |
| `visual_layer` | `int` | 调试或可视分层。 |
| `min_spacing` | `float` | XZ 中心间距约束；`0` 表示自动计算。 |
| `bound_min_length` | `float` | mesh bounds 最小轴长度，用于默认间距。 |
| `source_mesh` / `source_mesh_path` | `Mesh` / `String` | 原始 mesh 或资源路径。 |
| `voxel_descriptor` | `AutoVoxelDescriptor` / `Resource` | 资产体素语义唯一权威来源；集中持有 color、complexity、bands、collision、pivots 和 probes。 |
| `voxel_color` | `Color` | legacy descriptor 兼容入口；同步到 `voxel_descriptor.color`，`a` 与 complexity 同步。 |
| `voxel_complexity` | `float` | legacy descriptor 兼容入口；同步到 `voxel_descriptor.complexity`，范围 `0.0-1.0`。 |
| `affected_bands` | `Array[Dictionary]` | legacy descriptor 兼容入口；同步到 `voxel_descriptor.affected_bands`。 |
| `collision_voxels` | `Array[Dictionary]` | legacy descriptor 兼容入口；同步到 `voxel_descriptor.collision_voxels`；当前表示浮点 collision voxel 样本。 |
| `pivot_variants` | `Array[Dictionary]` | legacy descriptor 兼容入口；同步到 `voxel_descriptor.pivot_variants`。 |
| `semantic_probe_profile` | `Resource` | legacy descriptor 兼容入口；同步到 `voxel_descriptor.semantic_probe_profile`。 |
| `semantic_probe_density` | `float` | legacy descriptor 兼容入口；同步到 `voxel_descriptor.semantic_probe_density`。 |
| `context_sensing_radius` | `float` | legacy descriptor 兼容入口；同步到 `voxel_descriptor.context_sensing_radius`。 |
| `allowed_anchor_kinds` | `PackedStringArray` | 限制资产可参与的 anchor 类型，如 `ground`、`target_top`。 |
| `voxel_record` | `Dictionary` | SceneVoxel record handle；字段结构见 `scene-voxel-field-system.md`。 |

读取资产语义时必须走 `voxel_descriptor` 或 `get_voxel_color()`、`get_affected_bands()`、`get_collision_voxels()`、`get_pivot_variants()` 等 getter；这些 getter 会通过 `_ensure_voxel_descriptor()` 使用 descriptor，并返回归一化后的结果。不要在新逻辑中直接读取 `voxel_color`、`voxel_complexity`、`affected_bands`、`collision_voxels`、`pivot_variants`、`semantic_probe_profile`、`semantic_probe_density` 或 `context_sensing_radius` 作为权威语义。

兼容入口降级计划：

| 阶段 | 规则 |
| --- | --- |
| 当前 | 保留 `AutoObject` 同名字段的 export 和双向同步，保证旧资产、Inspector 和配置字典仍可工作。 |
| 新代码 | 只把同名字段当作输入兼容层；读取和运行时决策都使用 descriptor-backed getter。 |
| 迁移后 | 资产文件全部带 `voxel_descriptor` 后，可逐步隐藏或移除同名 export 字段，只保留必要的导入转换。 |
| 禁止 | 不再新增 `AutoObject` 同名语义字段，不把 metadata、`voxel_record` 或旧字段当作 descriptor 的替代来源。 |

`AutoObject.configure_auto_object()` 会强制 `scale = Vector3.ONE`。资产运行时缩放不作为 semantic probe 或 voxel 语义来源。

`object_type` / `object_subtype` 当前仍由 placement、same-type exclusion 和 debug record 使用。它们的边界是“运行时分组 metadata”，不是资产默认体素语义；需要表达资产视觉、collision、probe 或 routing 偏好时，仍应优先使用具体资产类、`voxel_descriptor`、`semantic_probes`、`allowed_anchor_kinds`、footprint 和 collision 语义。后续如果引入 `exclusion_group` 或 `placement_group`，应先从这些字段迁移。

## `AutoVoxelDescriptor`

`AutoVoxelDescriptor` 是资产侧体素描述资源，也是资产语义唯一权威来源。它保存会影响 routing、probe、footprint、source voxel 写入和 target fit 的默认语义。

资产侧 collision 必须进入 `AutoVoxelDescriptor.collision_voxels`。`AutoObject.collision_voxels`、`AutoVegetationAsset.collision_voxels` 和 `AutoVoxelProfile.collision_voxels` 只作为 legacy / authoring fallback，并会同步回 descriptor。

| 字段 | 含义 |
| --- | --- |
| `color` / `complexity` | 默认颜色与复杂度；`get_color()` 会把 alpha 设为 complexity。 |
| `affected_bands` | 可视 / 生态 band 写入声明。 |
| `collision_voxels` | 浮点 collision voxel 样本；与 `color` / `complexity` 同级，归一化后供 footprint、source voxel 写入和 probe 使用。 |
| `pivot_variants` | 显式 pivot 列表；为空时可从 collision 高度自动生成。 |
| `auto_generate_vertical_pivots` | 根据 collision 高度生成 bottom / middle / upper pivot。 |
| `semantic_probe_profile` | 保存或生成 `semantic_probes`。 |
| `semantic_probe_density` | 自动 probe 生成密度。 |
| `context_sensing_radius` | 为小型资产增加 AABB 外围 context probes。 |

`to_record_fields()` 会导出 `color`、`complexity`、`affected_bands`、`collision_voxels`、`pivot_variants`、`semantic_probe_density` 和可选 `semantic_probes`。

## Band 记录

`affected_bands` 会通过 `AutoVoxelProfile.normalize_affected_bands()` 归一化。

| 字段 | 类型 | 默认 / 来源 |
| --- | --- | --- |
| `band` | `String` | band 名，如 `ground`、`understory`、`midstory`、`canopy`。 |
| `channel` | `int` | RGBA channel；`AutoAssetFactory.BAND_CHANNELS` 提供默认映射。 |
| `radius` | `float` | 写入半径；缺失或 `<= 0` 时使用调用方默认半径。 |
| `color` | `Color` | 缺失时使用资产颜色。 |
| `complexity` | `float` | 缺失时使用资产复杂度。 |

## Collision 记录

`collision_voxels` 会通过 `AutoVoxelProfile.normalize_collision_voxels()` 归一化。当前主表示是局部体素坐标上的浮点 collision 强度，不引入复杂距离场、扩散场或软排斥缓存。旧的 `shape` / `radius` 字段仍可作为资产编写辅助输入，但进入 placement 前会被烘焙为浮点 voxel footprint。

| 字段 | 类型 | 默认 / 说明 |
| --- | --- | --- |
| `voxel` / `local_pos` / `voxel_offset` | `Vector3i` / `Vector3` / `Array` / `Dictionary` | 局部 voxel 坐标；归一化后写入 `voxel` 和 `local_pos`。 |
| `value` | `float` | 默认 `1.0`；collision 强度，范围 `0.0-1.0`。 |
| `collision_degree` | `int` | 可选；`0-255` 的内部碰撞强度，缺少 `value` 时会转换为 `value`。 |
| `weight` | `float` | 默认 `1.0`；placement footprint 权重。 |
| `enabled` | `bool` | 默认 `true`；为 `false` 时消费端跳过该 voxel。 |
| `shape` / `radius` / `y_min` / `y_max` | legacy authoring helper | 兼容旧资产；`cylinder` 会烘焙为多个浮点 voxel footprint 样本。 |
| `half_extents` / `size` | legacy authoring helper | 兼容旧资产；`box` / `cube` 会烘焙为多个浮点 voxel footprint 样本。 |

Collision 的最终归属见 `scene-voxel-field-system.md`：`collision_voxels` 与 `color` / `complexity` 同级，从资产默认值进入 record / source voxel，并可作为 committed `SceneVoxel` 的同级字段保留；提交后的 `collision_occupancy` 是由它重建的派生查询缓存视图。

## 运行时 record 边界

`voxel_record` 属于 SceneVoxel record / source voxel delta 数据，不是资产默认值主结构。本文件只记录它在 `AutoObject` 和 metadata 上的查询入口；字段 schema、source 类型和提交规则见 `scene-voxel-field-system.md`。

## Metadata 规则

运行时 metadata 只用于索引、回查和调试，不是资产默认值的主来源。

| Metadata | 来源 |
| --- | --- |
| `auto_id` | `AutoObject.auto_id` |
| `auto_instance_id` / `instance_id` | `AutoObject.instance_id` |
| `instance_mesh_id` | 实际 `MeshInstance3D.get_instance_id()` |
| `auto_source` | `AutoObject.auto_source` |
| `auto_object_type` | 旧兼容索引；新逻辑优先使用 `object_type` / `object_subtype` 或后续显式 grouping key |
| `voxel_record` | 当前实例写入场景体素系统的 record handle；字段结构见 `scene-voxel-field-system.md` |

维护规则：新增字段时先判断它属于资产默认值、运行时 record、source voxel delta、TargetSV 目标画布还是最终 `SceneVoxel` 状态，不要把 metadata 当成第二套状态系统。不要新增另一套 `subtype` 字段；如果现有 `object_type` / `object_subtype` 不够表达互斥或 routing 分组，应新增明确命名的 `exclusion_group` / `placement_group` 并提供迁移路径。
