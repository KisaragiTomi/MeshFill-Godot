@tool
## 必须带 @tool：本资源作为 voxel_profile 存在烘焙的 AssetDescriptor .tres 里，而
## asset_descriptor.gd / auto_object.gd（两者都是 @tool）在编辑期调用 get_collision() /
## get_color() / get_complexity()。缺 @tool 时编辑器把它加载为占位脚本实例——导出属性可读，
## 但方法调用不执行并返回空值，编辑期取剖面会静默拿到空结果。
class_name AutoVoxelProfile
extends Resource

const VoxelGeneralScript := preload("res://scripts/utils/voxel_general.gd")

@export var color: Color = Color.WHITE
@export_range(0.0, 1.0) var complexity: float = 1.0
@export var collision: Array[Dictionary] = []


func get_color() -> Color:
	var result := color
	result.a = get_complexity()
	return result


func get_complexity() -> float:
	return clampf(complexity, 0.0, 1.0)


func get_collision(default_radius: float = 0.0) -> Array[Dictionary]:
	return VoxelGeneralScript.normalize_collision_samples(collision, default_radius)


static func create_profile(entry_color: Color, entry_complexity: float):
	var profile = load("res://scripts/auto_voxel_profile.gd").new()
	profile.color = entry_color
	profile.complexity = clampf(entry_complexity, 0.0, 1.0)
	return profile
