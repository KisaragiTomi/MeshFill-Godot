class_name AutoVoxelProfile
extends Resource

@export var color: Color = Color.WHITE
@export_range(0.0, 1.0) var complexity: float = 1.0
@export var affected_bands: Array[Dictionary] = []
@export var collision_voxels: Array[Dictionary] = []


func get_color() -> Color:
	var result := color
	result.a = get_complexity()
	return result


func get_complexity() -> float:
	return clampf(complexity, 0.0, 1.0)


func get_affected_bands(default_radius: float = 1.0) -> Array[Dictionary]:
	return normalize_affected_bands(affected_bands, default_radius, get_color(), get_complexity())


func get_collision_voxels(default_radius: float = 0.0) -> Array[Dictionary]:
	return normalize_collision_voxels(collision_voxels, default_radius)


static func normalize_affected_bands(
	source: Array,
	default_radius: float = 1.0,
	fallback_color: Color = Color.WHITE,
	fallback_complexity: float = 1.0
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var complexity := clampf(fallback_complexity, 0.0, 1.0)
	var color := fallback_color
	color.a = complexity
	for raw_band in source:
		if not raw_band is Dictionary:
			continue
		var band := (raw_band as Dictionary).duplicate(true)
		if not band.has("radius") or float(band.radius) <= 0.0:
			band["radius"] = default_radius
		if not band.has("color"):
			band["color"] = color
		if not band.has("complexity"):
			band["complexity"] = complexity
		result.append(band)
	return result


static func normalize_collision_voxels(source: Array, default_radius: float = 0.0) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_collision in source:
		if not raw_collision is Dictionary:
			continue
		var collision := (raw_collision as Dictionary).duplicate(true)
		if _is_float_collision_voxel(collision):
			var voxel := _vector3i_from_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3i.ZERO))), Vector3i.ZERO)
			collision["voxel"] = voxel
			collision["local_pos"] = voxel
			if not collision.has("value") and collision.has("collision_degree"):
				collision["value"] = clampf(float(collision.get("collision_degree", 255)) / 255.0, 0.0, 1.0)
			if not collision.has("value"):
				collision["value"] = 1.0
			collision["value"] = clampf(float(collision.get("value", 1.0)), 0.0, 1.0)
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
		if not collision.has("value"):
			collision["value"] = 1.0
		result.append(collision)
	return result


static func _is_float_collision_voxel(collision: Dictionary) -> bool:
	return collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset")


static func _vector3i_from_value(value, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	if value is Vector3i:
		return value as Vector3i
	if value is Vector3:
		var v := value as Vector3
		return Vector3i(roundi(v.x), roundi(v.y), roundi(v.z))
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3i(
			int(dict.get("x", fallback.x)),
			int(dict.get("y", fallback.y)),
			int(dict.get("z", fallback.z))
		)
	return fallback


static func make_all_band_entries(entry_color: Color, entry_complexity: float, radius: float = 0.0) -> Array[Dictionary]:
	var c := Color(entry_color.r, entry_color.g, entry_color.b, clampf(entry_complexity, 0.0, 1.0))
	return [
		{"band": "ground", "channel": 0, "radius": radius, "color": c, "complexity": c.a},
		{"band": "understory", "channel": 1, "radius": radius, "color": c, "complexity": c.a},
		{"band": "midstory", "channel": 2, "radius": radius, "color": c, "complexity": c.a},
		{"band": "canopy", "channel": 3, "radius": radius, "color": c, "complexity": c.a},
	]


static func create_all_bands(entry_color: Color, entry_complexity: float, radius: float = 0.0) -> AutoVoxelProfile:
	var profile := AutoVoxelProfile.new()
	profile.color = entry_color
	profile.complexity = clampf(entry_complexity, 0.0, 1.0)
	profile.affected_bands = make_all_band_entries(entry_color, entry_complexity, radius)
	return profile


static func make_collision_voxel(
	voxel: Vector3i,
	value: float = 1.0,
	weight: float = 1.0
) -> Dictionary:
	return {
		"voxel": voxel,
		"local_pos": voxel,
		"value": clampf(value, 0.0, 1.0),
		"weight": maxf(weight, 0.0),
	}


static func make_legacy_cylinder_collision(
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
		"value": 1.0,
	}


static func create_single_band(
	band_name: String,
	channel: int,
	radius: float,
	entry_color: Color,
	entry_complexity: float
) -> AutoVoxelProfile:
	var profile := AutoVoxelProfile.new()
	profile.color = entry_color
	profile.complexity = clampf(entry_complexity, 0.0, 1.0)
	var c := profile.get_color()
	profile.affected_bands = [{
		"band": band_name,
		"channel": channel,
		"radius": radius,
		"color": c,
		"complexity": c.a,
	}]
	return profile
