# Auto Asset Scripting

这份文档把新增岩石 / 新增植被的手工步骤收拢到脚本入口，并同步当前字段契约。

![AutoObject asset properties map](../graphs/autoobject_asset_properties.svg)

![AutoAssetFactory relationships](../graphs/autoassetfactory_relationships.svg)

| File | Purpose |
| --- | --- |
| `scripts/auto_asset_factory.gd` | 脚手架 / 导入 helper；创建和保存 `AutoRock`、`AutoVoxelDescriptor`、`AutoVoxelProfile`，并提供 ISWS wrapper。 |
| `scripts/auto_rock.gd` | typed `AutoRock` façade；保存岩石 mesh、height texture、随机参数、`asset_id` 和 profile fallback。 |
| `scripts/auto_vegetation.gd` | typed `AutoVegetation` façade；保存植被 scatter channel / radius 和 profile fallback。 |
| `scripts/auto_voxel_descriptor.gd` | 持久化植被资产：默认语义、mesh、scatter、visual layer、group 和可选 `vegetation_script`。 |
| `tools/scaffold_auto_asset.gd` | Godot 命令行脚手架，按 JSON 生成资源和子类脚本。 |

## 核心契约

- `AutoVoxelDescriptor` 是资产默认体素语义的 canonical source；脚本化资产不要把 profile 或 metadata 当成第二套权威。
- `AutoVoxelProfile` 是 preset / shared data fallback。岩石脚手架会保存 `profile_path` 方便复用，但 `AutoRock` 仍通过 descriptor-backed getter 产出写入字段；profile 不替代 descriptor，也不由 `ISWS` 反向生成。
- `AutoRock` / `AutoVegetation` 是 typed façade：保存 mesh、scatter、随机参数和实例配置入口，再把共享语义交给 `AutoObject` / descriptor-backed 字段。
- 运行时写入 payload 统一称为 `instance_stamp_write_spec` / `ISWS`；当前 helper 同时提供 canonical wrapper 和 legacy `make_*_voxel_write_spec()` 名称。

## 范围与生命周期

| 项 | 当前契约 |
| --- | --- |
| 职责 | 将手写 rock / vegetation 资源步骤收拢到 `AutoAssetFactory` 和 `tools/scaffold_auto_asset.gd`。 |
| 输入 | JSON config、已有 mesh / height texture、可选 profile、`class_name` / `script_path`。 |
| 输出 | `AutoRock` scene、`AutoVoxelDescriptor` resource、可选 `AutoVoxelProfile`、可选 typed façade script。 |
| 生命周期 | JSON -> factory normalize -> resource / script write -> runtime load descriptor-backed asset -> GPU placement / source write 构造 `ISWS`。 |
| Source of truth | 脚手架只写入 source assets；运行时默认语义仍以 `AutoVoxelDescriptor` / descriptor-backed getter 为准。 |
| Placement 边界 | 脚手架产物可被 rock placement、vegetation placement 和 voxel placement 使用；prefilter candidate regions、physical score 和 commit 不在本文维护。 |
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
| `type` | 脚手架 dispatch 字段；当前只接受 `rock` 或 `vegetation`。 |
| `asset_path` | 岩石保存 `AutoRock` scene；植被保存 `AutoVoxelDescriptor` `.tres`。 |
| `descriptor_path` | 植被旧配置 fallback；新配置使用 `asset_path`。 |
| `class_name` / `script_path` | typed façade 脚本输出；植被有默认值，岩石只有两者都提供时才生成子类。 |
| `asset_id` | 具体资产身份 / debug / profile 去重输入；不是 runtime subtype。 |
| `subtype` | 脚手架兼容字段；用于默认脚本名、group、typed façade / descriptor 的 `object_subtype`，不是新的语义门。 |
| `collision` | canonical 输入；写入 descriptor / typed asset，并作为生成 config 的唯一 collision 字段。 |
| `color` / `complexity` | 进入 descriptor-backed shared fields；`color.a` 与 `complexity` 同步。 |
| `channel` | 植被 scatter channel，不进入 `SharedPropertyType.SHARED_FIELD_KEYS`。 |
| `radius` | 植被 scatter radius；岩石只用作 profile 默认半径。 |
| `profile_path` | 岩石 `AutoVoxelProfile` preset / fallback 输出路径，不是唯一语义权威。 |
| `mesh` | 资源 mesh 输入；岩石必需，除非 `asset_path` 已有 mesh；植被可选。 |
| `height_texture` / `height` | 岩石高度图输入；`.raw` 使用 `raw_width` / `raw_height`，默认 256。 |
| `mesh_create_method` | 只用于植被 descriptor 内置 mesh 工厂，必须在白名单中。 |

`tools/scaffold_auto_asset.gd` 对 rock 和 vegetation 都只读取 `collision`；旧 `collision_voxels` 不再作为 config fallback。

脚手架只负责生成或更新资产文件，不负责把实例直接写入 `SceneVoxel`。落地到 SV 的生命周期从 runtime 加载这些资源后开始：GPU placement 生成实例，prefilter 只收窄 candidate regions，`AutoObject` 或 placement helper 构造 `ISWS`，再交给 `SceneVoxelCommitter`。

## Rock Config

```json
{
  "type": "rock",
  "asset_id": "cliff_03",
  "class_name": "AutoCliff03Rock",
  "script_path": "res://scripts/auto_cliff_03_rock.gd",
  "subtype": "cliff_rock",
  "asset_path": "res://assets/rocks/cliff_03_asset.tscn",
  "profile_path": "res://assets/rocks/cliff_03_profile.tres",
  "mesh": "res://geo/cliff_03.FBX",
  "height_texture": "res://geo/cliff_03_height.raw",
  "mesh_size": 4.2,
  "color": [0.55, 0.5, 0.45, 1.0],
  "complexity": 1.0,
  "collision": [
    {
      "shape": "cylinder",
      "radius": 1.2,
      "y_min": 0.0,
      "y_max": 2.0,
      "collision_strength": 1.0
    }
  ],
  "random_rotate": [0.0, 1.0],
  "random_scale": [0.8, 1.2],
  "random_height_offset": [-0.5, 0.5]
}
```

| Output | Meaning |
| --- | --- |
| `asset_path` | `AutoRock` 场景资产，含 mesh、height texture、随机参数、`asset_id` 和 descriptor-backed shared fields。 |
| `profile_path` | `AutoVoxelProfile` preset / fallback，用于已有 rock assets 或 import 复用。 |
| `script_path` | 可选 `AutoRock` 子类；只有 `class_name` 和 `script_path` 都存在时生成。 |

`AutoAssetFactory.create_or_update_rock_asset()` 先从 profile 取 `color` / `complexity` / `collision` fallback，再用显式 `collision` 覆盖 collision，并把结果归一化后交给 `configure_asset()` / `configure_rock()`。`sync_exported_fields` 只同步 Inspector mirror；不要把 `voxel_profile` 写成唯一语义权威。

## Vegetation Config

```json
{
  "type": "vegetation",
  "subtype": "flower",
  "asset_id": "flower",
  "class_name": "AutoFlower",
  "script_path": "res://scripts/auto_flower.gd",
  "asset_path": "res://assets/vegetation/flower_descriptor.tres",
  "channel": 0,
  "radius": 0.25,
  "color": [0.9, 0.35, 0.5, 0.7],
  "complexity": 0.7,
  "collision": [],
  "scatter_min_distance": 0.35,
  "scatter_max_count": 800,
  "scatter_max_scale": 0.7,
  "visual_layer": 14,
  "group": "placed_flowers",
  "mesh_create_method": "create_flower_mesh"
}
```

| Output | Meaning |
| --- | --- |
| `script_path` | 具体 `AutoVegetation` 子类，例如 `AutoFlower`。 |
| `asset_path` | `AutoVoxelDescriptor` 资源，保存默认语义、mesh、scatter、layer、group、`asset_id` 和 `vegetation_script`。 |

`subtype` 是当前脚手架的 specialize 输入：它生成默认 `class_name`、`script_path`、`group`，并写入 descriptor / typed façade 的 `object_subtype` 兼容字段。它不是新的核心语义来源；新的 GPU runtime object schema 仍不应把 `object_subtype` 当成语义门。更细资产身份优先使用 `asset_id`、descriptor path 或未来 `profile_id`。

`mesh_create_method` 白名单保持很小：`create_tree_mesh`、`create_midstory_mesh`、`create_bush_mesh`、`create_flower_mesh`。如果有外部模型，改用 `"mesh": "res://geo/flower.glb"`。

草、树叶、细枝这类柔性部分保持 `collision: []`。只有粗树干或大块刚体才写带 `collision_strength` 的 collision sample。

## Runtime Use

```gdscript
var flower_asset := load("res://assets/vegetation/flower_descriptor.tres") as AutoVoxelDescriptor
var flower := flower_asset.instantiate_vegetation({
	"name": "Flower_001",
	"position": Vector3(0.0, 0.0, 0.0),
	"scale": Vector3.ONE * 0.6,
})
add_child(flower)
register_brush_vegetation(flower, flower_asset.make_instance_config())
```

岩石生成器直接使用 `AutoRock` 原型。生成结果复制原型并落到场景，运行时从 descriptor-backed 字段派生 `instance_stamp_write_spec` / `ISWS`。当前 `AutoObject.make_instance_stamp_write_spec()` 是 canonical wrapper，`make_voxel_write_spec()` 是 legacy API name。

脚本侧需要直接构造 runtime record 时，使用 canonical `AutoObject.make_instance_stamp_write_spec()`，或使用 `AutoAssetFactory.make_rock_voxel_write_spec()`、`make_vegetation_voxel_write_spec()`、profile fallback 的 `make_profile_voxel_write_spec()` 等 legacy-named helper。这些 helper 返回当前 ISWS payload；函数名里的 `voxel_write_spec` 只保留兼容命名。

`AutoRock` 会在 record extra fields 中补 `mesh_index`；`AutoVegetation` 会补 `object_subtype`、`channel` 和 `radius`。这些是 runtime record extra，不进入 `SharedPropertyType.SHARED_FIELD_KEYS`。

## Metadata Rule

脚手架和运行时代码不把 metadata 当作第二套配置面。新增资产语义写入 `AutoVoxelDescriptor` 或 typed asset 的 descriptor-backed 字段；实例落地后的颜色、collision、像素和 slice 写入 `instance_stamp_write_spec` / `ISWS`。metadata 只保留 id、来源、`object_type`、实例 id 和 `ISWS` 查询入口；`instance_stamp_write_spec` 是 preferred metadata key，旧 `voxel_write_spec` metadata key 只作为兼容别名。

## 相关文档

- `asset-properties.md`：descriptor、shared fields、metadata 和 `ISWS` 边界。
- `asset-semantic-probes.md`：descriptor-backed probes 的生成来源和 prefilter 交接。
- `scene-voxel-field-system.md`：`ISWS` 写入到 source voxel / committed `SceneVoxel` 的数据流。
- `../placement/voxel-semantic-routing.md`：脚手架产物进入 placement 后的 candidate voxel-region 消费边界。

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [资产脚手架总览](../../demos/core-auto-asset-scripting/core-auto-asset-scripting.md) | 测试方法与验收标准 | [`../../demos/core-auto-asset-scripting/core-auto-asset-scripting.tscn`](../../demos/core-auto-asset-scripting/core-auto-asset-scripting.tscn) |
| [Auto Asset Scaffolding](../../demos/modules/auto-asset-scaffolding/auto-asset-scaffolding.md) | 测试方法与验收标准 | [`../../demos/modules/auto-asset-scaffolding/auto-asset-scaffolding.tscn`](../../demos/modules/auto-asset-scaffolding/auto-asset-scaffolding.tscn) |
| [Asset Defaults Descriptor](../../demos/modules/asset-defaults-descriptor/asset-defaults-descriptor.md) | 测试方法与验收标准 | [`../../demos/modules/asset-defaults-descriptor/asset-defaults-descriptor.tscn`](../../demos/modules/asset-defaults-descriptor/asset-defaults-descriptor.tscn) |
