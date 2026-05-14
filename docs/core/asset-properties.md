# Asset Properties

![AutoObject asset properties map](../graphs/autoobject_asset_properties.svg)

本文是当前资产字段、descriptor 兼容入口和 metadata 规则的可靠速查。旧版同名文档曾因编码问题变成 mojibake，已不再作为来源；本版以当前 GDScript 为准。

相关边界：

- `meshfill-framework.md` 说明数据归属和主流程。
- `scene-voxel-field-system.md` 说明 `voxel_record`、source delta、`SceneVoxel` 和 collision cache。
- `asset-semantic-probes.md` 说明资产侧 semantic probes。

## 资产层级

| 类型 | 角色 | 主要文件 |
| --- | --- | --- |
| `AutoObject` | 所有自动放置对象的运行时基类 | `scripts/auto_object.gd` |
| `AutoRock` / `AutoCliffRock` | 岩石对象类型 | `scripts/auto_rock.gd` / `scripts/auto_cliff_rock.gd` |
| `AutoVegetation` 及子类 | 植被对象类型 | `scripts/auto_vegetation.gd` 等 |
| `AutoVegetationAsset` | 植被资源定义，可实例化运行时节点 | `scripts/auto_vegetation_asset.gd` |
| `AutoVoxelDescriptor` | 资产默认体素语义、pivot 和 semantic probe 配置 | `scripts/auto_voxel_descriptor.gd` |
| `AutoVoxelProfile` | 轻量共享体素 profile，保存颜色、复杂度、bands 和 collision | `scripts/auto_voxel_profile.gd` |
| `AutoAssetFactory` | 脚本化创建资产、profile、descriptor 和 `voxel_record` | `scripts/auto_asset_factory.gd` |

## `AutoObject` 运行时字段 / descriptor 兼容入口

`AutoObject` 是场景里的运行时节点，负责对象身份、来源、mesh、放置约束和运行时 `voxel_record`。资产侧体素语义的主结构是 `voxel_descriptor`；表中标为“兼容入口”的字段会同步到 descriptor，用来支持旧资产、Inspector 编辑和配置字典。

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `auto_id` | `String` | 稳定对象 id；为空时可回退到节点名。 |
| `instance_id` | `int` | Godot 运行时实例 id。 |
| `auto_source` | `String` | 来源标记，如 `generated`、`scatter`、`brush`。 |
| `object_type` | `String` | 禁用字段；仅保留旧数据 / 调试兼容，不作为资产分类、routing 或同类互斥依据。 |
| `visual_layer` | `int` | 调试或可视分层。 |
| `min_spacing` | `float` | XZ 中心间距约束；`0` 表示自动计算。 |
| `bound_min_length` | `float` | mesh bounds 最小轴长度，用于默认间距。 |
| `source_mesh` / `source_mesh_path` | `Mesh` / `String` | 原始 mesh 或资源路径。 |
| `voxel_descriptor` | `AutoVoxelDescriptor` / `Resource` | 资产体素语义主结构；集中持有 color、complexity、bands、collision、pivots 和 probes。 |
| `voxel_color` | `Color` | descriptor 兼容入口；同步到 `voxel_descriptor.color`，`a` 与 complexity 同步。 |
| `voxel_complexity` | `float` | descriptor 兼容入口；同步到 `voxel_descriptor.complexity`，范围 `0.0-1.0`。 |
| `affected_bands` | `Array[Dictionary]` | descriptor 兼容入口；同步到 `voxel_descriptor.affected_bands`。 |
| `collision_voxels` | `Array[Dictionary]` | descriptor 兼容入口；同步到 `voxel_descriptor.collision_voxels`。 |
| `pivot_variants` | `Array[Dictionary]` | descriptor 兼容入口；同步到 `voxel_descriptor.pivot_variants`。 |
| `semantic_probe_profile` | `Resource` | descriptor 兼容入口；同步到 `voxel_descriptor.semantic_probe_profile`。 |
| `semantic_probe_density` | `float` | descriptor 兼容入口；同步到 `voxel_descriptor.semantic_probe_density`。 |
| `context_sensing_radius` | `float` | descriptor 兼容入口；同步到 `voxel_descriptor.context_sensing_radius`。 |
| `allowed_anchor_kinds` | `PackedStringArray` | 限制资产可参与的 anchor 类型，如 `ground`、`target_top`。 |
| `voxel_record` | `Dictionary` | 运行时 placement / source voxel record handle；字段结构见 `scene-voxel-field-system.md`。 |

读取资产语义时优先走 `get_voxel_color()`、`get_affected_bands()`、`get_collision_voxels()`、`get_pivot_variants()` 等 getter；这些 getter 会通过 `_ensure_voxel_descriptor()` 使用 descriptor，并返回归一化后的结果。

`AutoObject.configure_auto_object()` 会强制 `scale = Vector3.ONE`。资产运行时缩放不作为 semantic probe 或 voxel 语义来源。

当前不维护 `object_subtype` 字段。需要表达资产差异时，优先使用具体资产类、`voxel_descriptor`、`semantic_probes`、`allowed_anchor_kinds`、footprint 和 collision 语义。

## `AutoVoxelDescriptor`

`AutoVoxelDescriptor` 是当前优先使用的资产侧体素描述资源。

| 字段 | 含义 |
| --- | --- |
| `color` / `complexity` | 默认颜色与复杂度；`get_color()` 会把 alpha 设为 complexity。 |
| `affected_bands` | 可视 / 生态 band 写入声明。 |
| `collision_voxels` | collision voxel 声明，归一化后供 footprint、source collision 和 probe 使用。 |
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

`collision_voxels` 会通过 `AutoVoxelProfile.normalize_collision_voxels()` 归一化。

| 字段 | 类型 | 默认 / 说明 |
| --- | --- | --- |
| `shape` | `String` | 默认 `cylinder`。 |
| `radius` | `float` | 缺失或 `<= 0` 时使用调用方默认半径。 |
| `y_min` / `y_max` | `float` | 默认 `0.0` / `2.0`。 |
| `erosion_radius` | `float` | 默认 `0.0`。 |
| `dilation_radius` | `float` | 默认 `0.0`。 |
| `value` | `float` | 默认 `1.0`；用于 collision 强度。 |

Collision 的最终归属见 `scene-voxel-field-system.md`：自动生成和画笔 source voxel 保存 `collision_voxels` 成员，提交后的 collision occupancy 只是查询缓存。

## 运行时 record 边界

`voxel_record` 属于运行时 SV/source delta 数据，不是资产默认值主结构。本文件只记录它在 `AutoObject` 和 metadata 上的查询入口；字段 schema、source 类型和提交规则见 `scene-voxel-field-system.md`。

## Metadata 规则

运行时 metadata 只用于索引、回查和调试，不是资产默认值的主来源。

| Metadata | 来源 |
| --- | --- |
| `auto_id` | `AutoObject.auto_id` |
| `auto_instance_id` / `instance_id` | `AutoObject.instance_id` |
| `instance_mesh_id` | 实际 `MeshInstance3D.get_instance_id()` |
| `auto_source` | `AutoObject.auto_source` |
| `auto_object_type` | 禁用 / 兼容索引；不作为资产分类依据 |
| `voxel_record` | 当前实例写入场景体素系统的 record handle；字段结构见 `scene-voxel-field-system.md` |

维护规则：新增字段时先判断它属于资产默认值、运行时 record、source delta、TargetSV 目标画布还是最终 `SceneVoxel` 状态，不要把 metadata 当成第二套状态系统。当前不要新增 `subtype` / `object_subtype` 分类字段。
