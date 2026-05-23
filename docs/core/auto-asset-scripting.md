# Auto Asset Scripting

这份文档把“新增岩石 / 新增植被”的手工步骤收拢到脚本入口。核心文件：

![AutoObject asset properties map](../graphs/autoobject_asset_properties.svg)

| File | Purpose |
| --- | --- |
| `scripts/auto_asset_factory.gd` | 脚手架 / 导入 helper；创建、加载和保存 `AutoRock` / `AutoVegetation` 资产，并保留到 `AutoObject` helper 的兼容转调 |
| `scripts/auto_voxel_descriptor.gd` | 持久化植被资产：默认语义、mesh、scatter 参数、visual layer、group 和可选 `vegetation_script` |
| `tools/scaffold_auto_asset.gd` | Godot 命令行脚手架，按 JSON 生成资源和子类脚本 |

## Command

```bash
godot --headless --path . --script tools/scaffold_auto_asset.gd -- --config res://tools/my_asset.json
```

如果本机 Godot 命令不是 `godot`，替换成实际 Godot 4.6 可执行文件。

## Rock Config

```json
{
  "type": "rock",
  "asset_path": "res://assets/rocks/cliff_03_asset.tscn",
  "profile_path": "res://assets/rocks/cliff_03_profile.tres",
  "mesh": "res://geo/cliff_03.FBX",
  "height_texture": "res://geo/cliff_03_height.raw",
  "mesh_size": 4.2,
  "color": [0.55, 0.5, 0.45, 1.0],
  "complexity": 1.0,
  "collision_voxels": [
    {"shape": "cylinder", "radius": 1.2, "y_min": 0.0, "y_max": 2.0}
  ],
  "random_rotate": [0.0, 1.0],
  "random_scale": [0.8, 1.2],
  "random_height_offset": [-0.5, 0.5]
}
```

结果：

| Output | Meaning |
| --- | --- |
| `asset_path` | `AutoRock` / `AutoCliffRock` 场景资产，包含 `mesh`、`mesh_height_texture`、`mesh_size`、随机参数和对象体素字段 |
| `profile_path` | 可选 `AutoVoxelProfile` 预设，用于旧岩石资产或导入 fallback |
| Object voxel fields | 新语义应进入 `voxel_descriptor`；`voxel_profile` 和同名 mirror 字段只作为旧入口和配置字典兼容 |

`Main.rock_asset_dir` 默认扫描 `res://assets/rocks` 下的 `.tscn` / `.scn` / `.tres` / `.res`。推荐新岩石资产保存为 `AutoRock` 场景资产；旧 `MeshDataAsset` 仍会在加载时转换为 `AutoCliffRock` 兼容原型。

## Vegetation Config

```json
{
  "type": "vegetation",
  "class_name": "AutoFlower",
  "script_path": "res://scripts/auto_flower.gd",
  "asset_path": "res://assets/vegetation/flower_descriptor.tres",
  "channel": 0,
  "radius": 0.25,
  "color": [0.9, 0.35, 0.5, 0.7],
  "complexity": 0.7,
  "collision_voxels": [],
  "scatter_min_distance": 0.35,
  "scatter_max_count": 800,
  "scatter_max_scale": 0.7,
  "visual_layer": 14,
  "group": "placed_flowers",
  "mesh_create_method": "create_flower_mesh"
}
```

`subtype` 用于默认脚本名、资产名、`object_subtype` 和 group；植被 `asset_path` 直接保存 `AutoVoxelDescriptor`，同一个资源持有默认语义、mesh、scatter 参数和实例化脚本。旧配置里的 `descriptor_path` 仍可作为 `asset_path` fallback。

结果：

| Output | Meaning |
| --- | --- |
| `script_path` | 具体 `AutoVegetation` 子类，例如 `AutoFlower` |
| `asset_path` | `AutoVoxelDescriptor` 资源，保存资产默认语义、mesh、scatter、layer、group 和 `vegetation_script` |

`mesh_create_method` 目前支持 `create_tree_mesh`、`create_midstory_mesh`、`create_bush_mesh`、`create_flower_mesh`。如果有外部模型，也可以改用 `"mesh": "res://geo/flower.glb"`。

草、树叶、细枝这类柔性部分保持 `collision_voxels: []`。只有粗树干或大块刚体才写 collision voxel。

`Main.vegetation_asset_dir` 默认扫描 `res://assets/vegetation` 下的 `AutoVoxelDescriptor` 植被资产。生成植被时，这些资产会按自己的 `vegetation_channel`、`vegetation_radius`、`collision_voxels` 和 scatter 参数参与散布，并实例化具体子类。

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

岩石生成器现在直接使用 `AutoRock` / `AutoCliffRock` 子类原型。生成结果会复制对应原型并落到场景，运行时通过 `AutoRock.make_asset_voxel_record()` / `AutoObject.make_asset_voxel_record()` 按 descriptor-backed 字段派生场景 `voxel_write_spec`；`voxel_profile` 只作为字段为空时的共享预设回退。

## Metadata Rule

脚手架和运行时代码不把 metadata 当作第二套配置面。新增植被资产时写 `AutoVoxelDescriptor`；实例落地后的颜色、channel、collision、像素和 slice 数据写进 `voxel_write_spec`。metadata 只保留 id、来源、类型、实例 id 和 `voxel_write_spec` 这类查询入口。
