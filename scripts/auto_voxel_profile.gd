class_name AutoVoxelProfile
extends Resource

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
	return normalize_collision(collision, default_radius)


static func normalize_collision(source: Array, default_radius: float = 0.0) -> Array[Dictionary]:
	return AutoVoxelDescriptor.normalize_collision(source, default_radius)


static func create_profile(entry_color: Color, entry_complexity: float) -> AutoVoxelProfile:
	var profile := AutoVoxelProfile.new()
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


static func make_cylinder_collision(
	radius: float,
	y_min: float = 0.0,
	y_max: float = 2.0,
	erosion_radius: float = 0.0,
	dilation_radius: float = 0.0
) -> Dictionary:
	return {
		"shape": "cylinder",
		"radius": radius,
		"y_min": y_min,
		"y_max": y_max,
		"erosion_radius": erosion_radius,
		"dilation_radius": dilation_radius,
		"collision_strength": 1.0,
	}
