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
	var result: Array[Dictionary] = []
	for raw_collision in source:
		if not raw_collision is Dictionary:
			continue
		var collision := (raw_collision as Dictionary).duplicate(true)
		if _is_point_collision_sample(collision):
			var voxel := VoxelGeneral.vector3i_from_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3i.ZERO))), Vector3i.ZERO)
			collision["voxel"] = voxel
			collision["collision_strength"] = clampf(float(collision.get("collision_strength", 1.0)), 0.0, 1.0)
			if not collision.has("weight"):
				collision["weight"] = 1.0
			result.append(collision)
			continue
		if not collision.has("shape"):
			collision["shape"] = "cylinder"
		if not collision.has("radius") or float(collision.radius) <= 0.0:
			collision["radius"] = default_radius
		if not collision.has("y_min"):
			collision["y_min"] = 0.0
		if not collision.has("y_max"):
			collision["y_max"] = 2.0
		if not collision.has("erosion_radius"):
			collision["erosion_radius"] = 0.0
		if not collision.has("dilation_radius"):
			collision["dilation_radius"] = 0.0
		if not collision.has("collision_strength"):
			collision["collision_strength"] = 1.0
		collision["collision_strength"] = clampf(float(collision.get("collision_strength", 1.0)), 0.0, 1.0)
		result.append(collision)
	return result


static func _is_point_collision_sample(collision: Dictionary) -> bool:
	return collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset")


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
