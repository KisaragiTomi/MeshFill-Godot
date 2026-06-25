class_name SharedPropertyType
extends RefCounted

const AutoVoxelProfile := preload("res://scripts/auto_voxel_profile.gd")
const COLOR_KEY := "color"                         # shared visual color; alpha mirrors complexity
const COMPLEXITY_KEY := "complexity"               # shared occupancy/strength
const COLLISION_KEY := "collision"                 # canonical shared collision field
const SHARED_FIELD_KEYS := [
	COLOR_KEY,                                     # propagated to records and SceneVoxel
	COMPLEXITY_KEY,                                # propagated to records and SceneVoxel
	COLLISION_KEY,                                 # propagated to records and SceneVoxel
]


static func color_from_value(value, fallback: Color = Color.WHITE) -> Color:
	if value is Color:
		return value as Color
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			var alpha := float(arr[3]) if arr.size() >= 4 else fallback.a
			return Color(float(arr[0]), float(arr[1]), float(arr[2]), alpha)
	if value is Dictionary:
		var dict := value as Dictionary
		return Color(
			float(dict.get("r", fallback.r)),
			float(dict.get("g", fallback.g)),
			float(dict.get("b", fallback.b)),
			float(dict.get("a", fallback.a))
		)
	if value is String:
		return Color.from_string(str(value), fallback)
	return fallback


static func duplicate_dictionary_array(source: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_entry in source:
		if raw_entry is Dictionary:
			result.append((raw_entry as Dictionary).duplicate(true))
	return result


static func normalize_shared_fields(source: Dictionary, fallback: Dictionary = {}, complexity_override: float = -1.0) -> Dictionary:
	var source_color := color_from_value(source.get(COLOR_KEY, fallback.get(COLOR_KEY, Color.WHITE)), Color.WHITE)
	var source_complexity = source.get(COMPLEXITY_KEY, fallback.get(COMPLEXITY_KEY, source_color.a))
	var complexity := clampf(complexity_override if complexity_override >= 0.0 else float(source_complexity), 0.0, 1.0)
	var color := source_color
	color.a = complexity
	var result := {
		COLOR_KEY: color,                          # normalized color, alpha == complexity
		COMPLEXITY_KEY: complexity,                # normalized 0.0-1.0 strength
	}
	var raw_collision = source.get(COLLISION_KEY, fallback.get(COLLISION_KEY, []))
	if raw_collision is Array:
		result[COLLISION_KEY] = _normalize_collision(raw_collision, 0.0)
	elif raw_collision is float or raw_collision is int:
		result[COLLISION_KEY] = clampf(float(raw_collision), 0.0, 1.0)
	return result


static func from_descriptor(descriptor: Resource, default_radius: float = 0.0) -> Dictionary:
	if descriptor == null:
		return normalize_shared_fields({})
	var color := Color.WHITE
	var complexity := 1.0
	var collision: Array = []
	if descriptor.has_method("get_color"):
		color = descriptor.call("get_color")
	else:
		var raw_color = descriptor.get("color")
		if raw_color != null:
			color = color_from_value(raw_color, Color.WHITE)
	if descriptor.has_method("get_complexity"):
		complexity = float(descriptor.call("get_complexity"))
	else:
		var raw_complexity = descriptor.get("complexity")
		if raw_complexity != null:
			complexity = float(raw_complexity)
	if descriptor.has_method("get_collision"):
		collision = descriptor.call("get_collision", default_radius)
	else:
		var raw_collision = descriptor.get(COLLISION_KEY)
		if raw_collision is Array:
			collision = _normalize_collision(raw_collision, default_radius)
	return normalize_shared_fields({
		COLOR_KEY: color,
		COMPLEXITY_KEY: complexity,
		COLLISION_KEY: collision,
	})


static func from_profile(profile: AutoVoxelProfile, default_radius: float = 0.0, collision_override: Array = []) -> Dictionary:
	if profile == null:
		return normalize_shared_fields({})
	var collision := profile.get_collision(default_radius)
	if not collision_override.is_empty():
		collision = _normalize_collision(collision_override, default_radius)
	return normalize_shared_fields({
		COLOR_KEY: profile.get_color(),
		COMPLEXITY_KEY: profile.get_complexity(),
		COLLISION_KEY: collision,
	})


static func apply_to_record(record: Dictionary, shared_fields: Dictionary) -> Dictionary:
	var result := record.duplicate(true)
	for key in SHARED_FIELD_KEYS:
		if not shared_fields.has(key):
			continue
		var shared_entry = shared_fields[key]
		if shared_entry is Array:
			result[key] = duplicate_dictionary_array(shared_entry)
		else:
			result[key] = shared_entry
	if result.has(COLOR_KEY) or result.has(COMPLEXITY_KEY) or result.has(COLLISION_KEY):
		var normalized := normalize_shared_fields(result)
		result[COLOR_KEY] = normalized[COLOR_KEY]
		result[COMPLEXITY_KEY] = normalized[COMPLEXITY_KEY]
		if normalized.has(COLLISION_KEY):
			result[COLLISION_KEY] = _duplicate_collision_value(normalized[COLLISION_KEY])
	return result


static func apply_to_scene_voxel(scene_voxel: Dictionary, source_fields: Dictionary, complexity_override: float = -1.0, include_collision: bool = true) -> Dictionary:
	var result := scene_voxel.duplicate(true)
	var normalized := normalize_shared_fields(source_fields, result, complexity_override)
	result[COLOR_KEY] = normalized[COLOR_KEY]
	result[COMPLEXITY_KEY] = float(normalized[COMPLEXITY_KEY])
	if include_collision and normalized.has(COLLISION_KEY):
		result[COLLISION_KEY] = _duplicate_collision_value(normalized[COLLISION_KEY])
	return result


static func collision_from_fields(fields: Dictionary, fallback: Dictionary = {}) -> Array[Dictionary]:
	var raw_collision = fields.get(COLLISION_KEY, fallback.get(COLLISION_KEY, []))
	if raw_collision is Array:
		return _normalize_collision(raw_collision, 0.0)
	return []


static func has_collision_fields(fields: Dictionary) -> bool:
	if not fields.has(COLLISION_KEY):
		return false
	var collision_value = fields[COLLISION_KEY]
	if collision_value is Array:
		return not (collision_value as Array).is_empty()
	return true


static func _normalize_collision(source: Array, default_radius: float = 0.0) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_collision in source:
		if not raw_collision is Dictionary:
			continue
		var collision := (raw_collision as Dictionary).duplicate(true)
		if collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset"):
			var voxel := _vector3i_from_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3i.ZERO))), Vector3i.ZERO)
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


static func _duplicate_collision_value(raw_collision):
	if raw_collision is Array:
		return duplicate_dictionary_array(raw_collision)
	return raw_collision
