# Auto Asset Scripting

这份文档把新增通用物体 / 新增植被的手工步骤收拢到脚本入口，并同步当前字段契约。所有资产种类的默认语义定义见 [`asset-descriptor.md`](asset-descriptor.md)。

![AutoObject asset properties map](diagrams/autoobject_asset_properties.svg)

![AutoAssetFactory relationships](diagrams/autoassetfactory_relationships.svg)

| File | Purpose |
| --- | --- |
| `scripts/auto_asset_factory.gd` | mesh 加载 helper（`load_mesh` / `load_source_mesh`：mesh 树查找、UE collision-helper 过滤、变换烘焙）。 |
| `scripts/auto_object.gd` | canonical descriptor 创建（`create_voxel_descriptor`）与 ISWS 构造（`make_instance_stamp_write_spec`）。 |
| `scripts/asset_descriptor.gd` | 持久化 descriptor-backed `AutoObject` 资产默认语义，并保存 mesh / scatter / visual helper。 |

## 核心契约

- [`AssetDescriptor`](asset-descriptor.md) 是资产默认体素语义的 canonical source；脚本化资产不要把 profile 或 metadata 当成第二套权威。
- `AutoVoxelProfile` 只作为已有资产 / 导入 preset fallback；新脚手架不再输出单独的 profile 产物。
- 物体和植被都走 descriptor-backed `AutoObject` / `AssetDescriptor` 路径；旧 typed 子类不再作为资产定义入口。
- 运行时写入 payload 统一称为 `instance_stamp_write_spec` / `ISWS`；canonical 构造入口是 `AutoObject.make_instance_stamp_write_spec()`。

## 范围与生命周期

| 项 | 当前契约 |
| --- | --- |
| 职责 | 将手写 object / vegetation 资源步骤收拢到 `AutoAssetFactory` 静态 helper。 |
| 输入 | JSON config、已有 mesh / `mesh_height_texture`、descriptor shared fields。 |
| 输出 | `AutoObject` scene 或 `AssetDescriptor` resource。 |
| 生命周期 | JSON -> factory normalize -> resource write -> runtime load descriptor-backed asset -> GPU placement / source write 构造 `ISWS`。 |
| Source of truth | 脚手架只写入 source assets；运行时默认语义仍以 `AssetDescriptor` / descriptor-backed getter 为准。 |
| Placement 边界 | 脚手架产物可被 object placement、vegetation placement 和 voxel placement 使用；prefilter candidate regions、physical score 和 commit 不在本文维护。 |
| Core runtime 边界 | `ISWS` 进入 source voxel / committed `SceneVoxel` 的规则见 `scene-voxel-field-system.md`；metadata 只作为查询 handle。 |
| GPU runtime 边界 | `GPUAutoObjectRuntime` / profile container 只消费脚手架产物编译出的 profile；本文不新增 runtime object schema，也不提供 CPU runtime fallback。 |

## 脚本入口

`AutoAssetFactory`（`scripts/auto_asset_factory.gd`）现在只保留 mesh 加载 helper（`load_mesh` / `load_source_mesh`，含 UE collision-helper 过滤和变换烘焙）。descriptor 创建、ISWS 构造这些语义已收敛到 canonical `AutoObject`（`scripts/auto_object.gd`）：`AutoObject.create_voxel_descriptor()`、`AutoObject.make_instance_stamp_write_spec()`。资源落盘直接用 `ResourceSaver.save()`。从编辑器脚本或 `@tool` 节点直接调用即可。

物体 mesh 加载（`AutoObject` 原型）：`AutoAssetFactory` 现在只保留 mesh 加载 helper（`load_mesh` / `load_source_mesh`）。物体资产本身用 `AutoObject` 直接配置，descriptor 语义用 `AutoObject.create_voxel_descriptor()` 创建。

```gdscript
# 已有 mesh 存在：geo/cliff_01.FBX、geo/cliff_02.FBX。
var mesh := AutoAssetFactory.load_mesh("res://geo/cliff_01.FBX")
var obj := AutoObject.new()
obj.configure_object({
    "mesh": mesh,
    "mesh_size": 4.2,
    "color": Color(0.55, 0.5, 0.45, 1.0),   # a 与 complexity 同步
    "complexity": 1.0,
    "collision": [],
})
```

植被 / descriptor 资产（`AssetDescriptor` `.tres`）：descriptor 由 canonical `AutoObject.create_voxel_descriptor()` 创建，用 `ResourceSaver.save()` 落盘。

```gdscript
var descriptor := AutoObject.create_voxel_descriptor(
    Color(0.9, 0.35, 0.5, 0.7),    # entry_color
    0.7,                           # entry_complexity
    0.25,                          # default_radius
    [],                            # collision
)
ResourceSaver.save(descriptor, "res://assets/vegetation/leaf_descriptor.tres")
```

> 上面两段为示意用法。`assets/vegetation/` 下已有实际 descriptor `.tres`（见 [AssetDescriptor 统一 Demo](res://demos/asset-descriptor-demo/asset-descriptor.md)），新增资产时优先复制这些现成资源再调整字段。

## 输入规则

| 输入 | 规则 |
| --- | --- |
| `asset_path` | 物体保存 `AutoObject` scene；植被保存 `AssetDescriptor` `.tres`。 |
| `descriptor_path` | 植被旧配置 fallback；新配置使用 `asset_path`。 |
| `asset_id` | 具体资产身份 / debug / profile 去重输入；不是 runtime subtype。 |
| `subtype` | 兼容 / 分组字段；可写入 descriptor 的 `object_subtype`，不是新的语义门。 |
| `collision` | canonical 输入；写入 descriptor-backed asset，并作为生成 config 的唯一 collision 字段。 |
| `color` / `complexity` | 进入 descriptor-backed shared fields；`color.a` 与 `complexity` 同步。 |
| `channel` | 植被 scatter channel，不进入 `SharedPropertyType.SHARED_FIELD_KEYS`。 |
| `radius` | 植被 scatter radius；物体只用作 profile fallback 默认半径。 |
| `mesh` | 资源 mesh 输入；物体必需，除非 `asset_path` 已有 mesh；植被可选。 |
| `mesh_height_texture` | 物体高度场 fitting 输入；`.raw` 使用 `raw_width` / `raw_height`，默认 256。 |
| `mesh_create_method` | 只用于植被 descriptor 内置 mesh 工厂，必须在白名单中。 |

`AutoAssetFactory` 对 rock 和 vegetation 都只读取 `collision`；旧 `collision_voxels` 不再作为 config fallback。

脚手架只负责生成或更新资产文件，不负责把实例直接写入 `SceneVoxel`。落地到 SV 的生命周期从 runtime 加载这些资源后开始：GPU placement 生成实例，prefilter 只收窄 candidate regions，`AutoObject` 或 placement helper 构造 `ISWS`，再交给 `SceneVoxelCommitter`。

## Object Config

以下 config 只描述 `configure_object()` 接受的字段形状（不是命令行工具的输入）；示意用途，`mesh` 指向已有 `geo/cliff_01.FBX`。

```json
{
  "type": "object",
  "asset_id": "cliff_01",
  "subtype": "cliff",
  "asset_path": "res://assets/objects/cliff_01_asset.tscn",
  "mesh": "res://geo/cliff_01.FBX",
  "mesh_size": 4.2,
  "color": [0.55, 0.5, 0.45, 1.0],
  "complexity": 1.0,
  "collision": [],
  "random_rotate": [0.0, 1.0],
  "random_scale": [0.8, 1.2],
  "random_height_offset": [-0.5, 0.5]
}
```

| Output | Meaning |
| --- | --- |
| `asset_path` | `AutoObject` 场景资产，含 mesh、随机参数、`asset_id` 和 descriptor-backed shared fields。 |

`AutoObject.configure_object()` 会从已有 descriptor 读取 shared fields fallback，再用显式 `color` / `complexity` / `collision` 覆盖并归一化。`color.a` 与 `complexity` 同步；不要把 `voxel_profile` 写成唯一语义权威。

## Vegetation Config

以下同为示意 config；实际已有 descriptor 见 `assets/vegetation/sm_test_leaf_test2_asset.tres`。

```json
{
  "type": "vegetation",
  "subtype": "leaf",
  "asset_id": "sm_test_leaf",
  "asset_path": "res://assets/vegetation/sm_test_leaf_test2_asset.tres",
  "channel": 0,
  "radius": 0.25,
  "color": [0.9, 0.35, 0.5, 0.7],
  "complexity": 0.7,
  "collision": [],
  "visual_layer": 14,
  "group": "placed_leaves",
  "mesh_create_method": "create_sample_autoobject_mesh"
}
```

| Output | Meaning |
| --- | --- |
| `asset_path` | `AssetDescriptor` 资源；字段分组见 [`asset-descriptor.md`](asset-descriptor.md)。 |

`subtype` 是当前脚手架的 specialize 输入：它生成默认 `group`，并写入 descriptor 的 `object_subtype` 兼容字段。它不是新的核心语义来源；新的 GPU runtime object schema 仍不应把 `object_subtype` 当成语义门。更细资产身份优先使用 `asset_id`、descriptor path 或未来 `profile_id`。

`mesh_create_method` 白名单保持很小：当前只保留 `create_sample_autoobject_mesh` 作为脚手架示例。如果有外部模型，改用 `"mesh": "res://geo/SM_TestLeaf_Test2.FBX"`。

草、树叶、细枝这类柔性部分保持 `collision: []`。只有粗树干或大块刚体才写带 `collision_strength` 的 collision sample。

## Runtime Use

```gdscript
var leaf_asset := load("res://assets/vegetation/sm_test_leaf_test2_asset.tres") as AssetDescriptor
var config := leaf_asset.make_instance_config()
register_brush_autoobject(leaf_asset.make_instance_config())
```

高度场生成器直接使用 descriptor-backed `AutoObject` 原型。生成结果复制原型并落到场景，运行时从 descriptor-backed 字段派生 `instance_stamp_write_spec` / `ISWS`。当前 `AutoObject.make_instance_stamp_write_spec()` 是 canonical 构造入口。

脚本侧需要直接构造 runtime record 时，使用 canonical `AutoObject.make_instance_stamp_write_spec()`。它返回当前 ISWS payload。（`AutoAssetFactory` 上早先的同类 write-spec wrapper 已删除，统一走 `AutoObject`。）

高度场 / object placement 可以在 record extra fields 中补 `mesh_index`；descriptor-backed `AutoObject` 可以通过 instance config 提供 `object_subtype`、`channel` 和 `radius`。这些是 runtime record extra，不进入 `SharedPropertyType.SHARED_FIELD_KEYS`。

## Metadata Rule

脚手架和运行时代码不把 metadata 当作第二套配置面。新增资产语义写入 [`AssetDescriptor`](asset-descriptor.md) 或 descriptor-backed `AutoObject` 字段；实例落地后的颜色、collision、像素和 slice 写入 `instance_stamp_write_spec` / `ISWS`。metadata 只保留 id、来源、`object_type`、实例 id 和 `ISWS` 查询入口；`instance_stamp_write_spec` 是 preferred metadata key，旧 `voxel_write_spec` metadata key 只作为兼容别名。

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [AssetDescriptor 统一 Demo](res://demos/asset-descriptor-demo/asset-descriptor.md) | 脚手架产物的 descriptor 语义在统一 demo 中验收 | [`asset-descriptor-demo.tscn`](res://demos/asset-descriptor-demo/asset-descriptor-demo.tscn) |

## 相关文档

- `asset-descriptor.md`：所有资产种类的 descriptor 定义、字段分组和 authoring 规则。
- `asset-properties.md`：descriptor、shared fields、metadata 和 `ISWS` 边界。
- `asset-semantic-probes.md`：descriptor-backed probes 的生成来源和 prefilter 交接。
- `scene-voxel-field-system.md`：`ISWS` 写入到 source voxel / committed `SceneVoxel` 的数据流。
