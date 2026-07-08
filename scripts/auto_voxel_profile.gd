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


static func make_collision_sample(
	voxel: Vector3i,
	collision_strength: float = 1.0,
	weight: float = 1.0
) -> Dictionary:
	return {
		"voxel": voxel,
		"local_pos": voxel,
		"collision_strength": clampf(collision_strength, 0.0, 1.0),
		"weight": maxf(weight, 0.0),
	}
