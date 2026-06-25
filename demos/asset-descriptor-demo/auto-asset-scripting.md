# Auto Asset Scripting

这份文档把新增通用物体 / 新增植被的手工步骤收拢到脚本入口，并同步当前字段契约。所有资产种类的默认语义定义见 [`auto-voxel-descriptor.md`](auto-voxel-descriptor.md)。

![AutoObject asset properties map](../svg/autoobject_asset_properties.svg)

![AutoAssetFactory relationships](../svg/autoassetfactory_relationships.svg)

| File | Purpose |
| --- | --- |
| `scripts/auto_asset_factory.gd` | 脚手架 / 导入 helper；创建和保存 `AutoObject` asset、`AssetDescriptor`，并提供 ISWS wrapper。 |
| `scripts/auto_voxel_descriptor.gd` | 持久化 descriptor-backed `AutoObject` 资产默认语义，并保存 mesh / scatter / visual helper。 |
| `tools/scaffold_auto_asset.gd` | Godot 命令行脚手架，按 JSON 生成或更新资产资源。 |

## 核心契约

- [`AssetDescriptor`](auto-voxel-descriptor.md) 是资产默认体素语义的 canonical source；脚本化资产不要把 profile 或 metadata 当成第二套权威。
- `AutoVoxelProfile` 只作为已有资产 / 导入 preset fallback；新脚手架不再输出单独的 profile 产物。
- 物体和植被都走 descriptor-backed `AutoObject` / `AssetDescriptor` 路径；旧 typed 子类不再作为资产定义入口。
- 运行时写入 payload 统一称为 `instance_stamp_write_spec` / `ISWS`；当前 helper 同时提供 canonical wrapper 和 legacy `make_*_voxel_write_spec()` 名称。

## 范围与生命周期

| 项 | 当前契约 |
| --- | --- |
| 职责 | 将手写 object / vegetation 资源步骤收拢到 `AutoAssetFactory` 和 `tools/scaffold_auto_asset.gd`。 |
| 输入 | JSON config、已有 mesh / `mesh_height_texture`、descriptor shared fields。 |
| 输出 | `AutoObject` scene 或 `AssetDescriptor` resource。 |
| 生命周期 | JSON -> factory normalize -> resource write -> runtime load descriptor-backed asset -> GPU placement / source write 构造 `ISWS`。 |
| Source of truth | 脚手架只写入 source assets；运行时默认语义仍以 `AssetDescriptor` / descriptor-backed getter 为准。 |
| Placement 边界 | 脚手架产物可被 object placement、vegetation placement 和 voxel placement 使用；prefilter candidate regions、physical score 和 commit 不在本文维护。 |
| Core runtime 边界 | `ISWS` 进入 source voxel / committed `SceneVoxel` 的规则见 `scene-voxel-field-system.md`；metadata 只作为查询 handle。 |
| GPU runtime 边界 | `GPUAutoObjectRuntime` / profile container 只消费脚手架产物编译出的 profile；本文不新增 runtime object schema，也不提供 CPU runtime fallback。 |

## Command

```bash
godot --headless --path . --script tools/scaffold_auto_asset.gd -- --config res://tools/my_asset.json
```

如果本机 Godot 命令不是 `godot`，替换成实际 Godot 4.6 可执行文件。

## 输入规则

| 输入 | 规则 |
| --- | --- |
| `type` | 脚手架 dispatch 字段；当前只接受 `object` 或 `vegetation`。 |
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

`tools/scaffold_auto_asset.gd` 对 rock 和 vegetation 都只读取 `collision`；旧 `collision_voxels` 不再作为 config fallback。

脚手架只负责生成或更新资产文件，不负责把实例直接写入 `SceneVoxel`。落地到 SV 的生命周期从 runtime 加载这些资源后开始：GPU placement 生成实例，prefilter 只收窄 candidate regions，`AutoObject` 或 placement helper 构造 `ISWS`，再交给 `SceneVoxelCommitter`。

## Object Config

```json
{
  "type": "object",
  "asset_id": "cliff_03",
  "subtype": "cliff",
  "asset_path": "res://assets/objects/cliff_03_asset.tscn",
  "mesh": "res://geo/cliff_03.FBX",
  "mesh_height_texture": "res://geo/cliff_03_height.raw",
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
| `asset_path` | `AutoObject` 场景资产，含 mesh、`mesh_height_texture`、随机参数、`asset_id` 和 descriptor-backed shared fields。 |

`AutoAssetFactory.create_or_update_object_asset()` 会从已有 descriptor 读取 shared fields fallback，再用显式 `color` / `complexity` / `collision` 覆盖，并把结果归一化后交给 `configure_object()`。`sync_exported_fields` 只同步 Inspector mirror；不要把 `voxel_profile` 写成唯一语义权威。

## Vegetation Config

```json
{
  "type": "vegetation",
  "subtype": "flower",
  "asset_id": "flower",
  "asset_path": "res://assets/vegetation/flower_descriptor.tres",
  "channel": 0,
  "radius": 0.25,
  "color": [0.9, 0.35, 0.5, 0.7],
  "complexity": 0.7,
  "collision": [],
  "visual_layer": 14,
  "group": "placed_flowers",
  "mesh_create_method": "create_sample_autoobject_mesh"
}
```

| Output | Meaning |
| --- | --- |
| `asset_path` | `AssetDescriptor` 资源；字段分组见 [`auto-voxel-descriptor.md`](auto-voxel-descriptor.md)。 |

`subtype` 是当前脚手架的 specialize 输入：它生成默认 `group`，并写入 descriptor 的 `object_subtype` 兼容字段。它不是新的核心语义来源；新的 GPU runtime object schema 仍不应把 `object_subtype` 当成语义门。更细资产身份优先使用 `asset_id`、descriptor path 或未来 `profile_id`。

`mesh_create_method` 白名单保持很小：当前只保留 `create_sample_autoobject_mesh` 作为脚手架示例。如果有外部模型，改用 `"mesh": "res://geo/flower.glb"`。

草、树叶、细枝这类柔性部分保持 `collision: []`。只有粗树干或大块刚体才写带 `collision_strength` 的 collision sample。

## Runtime Use

```gdscript
var flower_asset := load("res://assets/vegetation/flower_descriptor.tres") as AssetDescriptor
var config := flower_asset.make_instance_config()
register_brush_autoobject(flower_asset.make_instance_config())
```

高度场生成器直接使用 descriptor-backed `AutoObject` 原型。生成结果复制原型并落到场景，运行时从 descriptor-backed 字段派生 `instance_stamp_write_spec` / `ISWS`。当前 `AutoObject.make_instance_stamp_write_spec()` 是 canonical wrapper，`make_voxel_write_spec()` 是 legacy API name。

脚本侧需要直接构造 runtime record 时，使用 canonical `AutoObject.make_instance_stamp_write_spec()`，或使用 `AutoAssetFactory.make_object_voxel_write_spec()`、`make_vegetation_voxel_write_spec()`、profile fallback 的 `make_profile_voxel_write_spec()` 等 helper。这些 helper 返回当前 ISWS payload；函数名里的 `voxel_write_spec` 只保留兼容命名。

高度场 / object placement 可以在 record extra fields 中补 `mesh_index`；descriptor-backed `AutoObject` 可以通过 instance config 提供 `object_subtype`、`channel` 和 `radius`。这些是 runtime record extra，不进入 `SharedPropertyType.SHARED_FIELD_KEYS`。

## Metadata Rule

脚手架和运行时代码不把 metadata 当作第二套配置面。新增资产语义写入 [`AssetDescriptor`](auto-voxel-descriptor.md) 或 descriptor-backed `AutoObject` 字段；实例落地后的颜色、collision、像素和 slice 写入 `instance_stamp_write_spec` / `ISWS`。metadata 只保留 id、来源、`object_type`、实例 id 和 `ISWS` 查询入口；`instance_stamp_write_spec` 是 preferred metadata key，旧 `voxel_write_spec` metadata key 只作为兼容别名。

## 相关文档

- `auto-voxel-descriptor.md`：所有资产种类的 descriptor 定义、字段分组和 authoring 规则。
- `asset-properties.md`：descriptor、shared fields、metadata 和 `ISWS` 边界。
- `asset-semantic-probes.md`：descriptor-backed probes 的生成来源和 prefilter 交接。
- `scene-voxel-field-system.md`：`ISWS` 写入到 source voxel / committed `SceneVoxel` 的数据流。
- `../placement/voxel-semantic-routing.md`：脚手架产物进入 placement 后的 candidate voxel-region 消费边界。

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [资产脚手架总览](../../demos/core-auto-asset-scripting/core-auto-asset-scripting.md) | 测试方法与验收标准 | [`../../demos/core-auto-asset-scripting/core-auto-asset-scripting.tscn`](../../demos/core-auto-asset-scripting/core-auto-asset-scripting.tscn) |
| [Auto Asset Scaffolding](../../demos/modules/auto-asset-scaffolding/auto-asset-scaffolding.md) | 测试方法与验收标准 | [`../../demos/modules/auto-asset-scaffolding/auto-asset-scaffolding.tscn`](../../demos/modules/auto-asset-scaffolding/auto-asset-scaffolding.tscn) |
