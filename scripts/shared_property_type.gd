class_name SharedPropertyType
extends RefCounted

const COLOR_KEY := "color"
const VALUE_KEY := "value"
const COMPLEXITY_KEY := "complexity"
const COLLISION_VOXELS_KEY := "collision_voxels"
const SHARED_FIELD_KEYS := [
	COLOR_KEY,
	COMPLEXITY_KEY,
	COLLISION_VOXELS_KEY,
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


static func normalize_shared_fields(source: Dictionary, fallback: Dictionary = {}, value_override: float = -1.0) -> Dictionary:
	var source_color := color_from_value(source.get(COLOR_KEY, fallback.get(COLOR_KEY, Color.WHITE)), Color.WHITE)
	var source_complexity = source.get(VALUE_KEY, source.get(COMPLEXITY_KEY, fallback.get(VALUE_KEY, fallback.get(COMPLEXITY_KEY, source_color.a))))
	var complexity := clampf(value_override if value_override >= 0.0 else float(source_complexity), 0.0, 1.0)
	var color := source_color
	color.a = complexity
	var result := {
		COLOR_KEY: color,
		COMPLEXITY_KEY: complexity,
	}
	var raw_collision = source.get(COLLISION_VOXELS_KEY, fallback.get(COLLISION_VOXELS_KEY, []))
	if raw_collision is Array:
		result[COLLISION_VOXELS_KEY] = duplicate_dictionary_array(raw_collision)
	return result


static func from_descriptor(descriptor: Resource, default_radius: float = 0.0) -> Dictionary:
	if descriptor == null:
		return normalize_shared_fields({})
	var color := Color.WHITE
	var complexity := 1.0
	var collision_voxels: Array = []
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
	if descriptor.has_method("get_collision_voxels"):
		collision_voxels = descriptor.call("get_collision_voxels", default_radius)
	else:
		var raw_collision = descriptor.get("collision_voxels")
		if raw_collision is Array:
			collision_voxels = AutoVoxelProfile.normalize_collision_voxels(raw_collision, default_radius)
	return normalize_shared_fields({
		COLOR_KEY: color,
		COMPLEXITY_KEY: complexity,
		COLLISION_VOXELS_KEY: collision_voxels,
	})


static func from_profile(profile: AutoVoxelProfile, default_radius: float = 0.0, collision_voxels_override: Array = []) -> Dictionary:
	if profile == null:
		return normalize_shared_fields({})
	var collision_voxels := profile.get_collision_voxels(default_radius)
	if not collision_voxels_override.is_empty():
		collision_voxels = duplicate_dictionary_array(collision_voxels_override)
	return normalize_shared_fields({
		COLOR_KEY: profile.get_color(),
		COMPLEXITY_KEY: profile.get_complexity(),
		COLLISION_VOXELS_KEY: collision_voxels,
	})


static func apply_to_record(record: Dictionary, shared_fields: Dictionary) -> Dictionary:
	var result := record.duplicate(true)
	for key in SHARED_FIELD_KEYS:
		if not shared_fields.has(key):
			continue
		var value = shared_fields[key]
		if value is Array:
			result[key] = duplicate_dictionary_array(value)
		else:
			result[key] = value
	if result.has(COLOR_KEY) or result.has(COMPLEXITY_KEY):
		var normalized := normalize_shared_fields(result)
		result[COLOR_KEY] = normalized[COLOR_KEY]
		result[COMPLEXITY_KEY] = normalized[COMPLEXITY_KEY]
	return result


static func apply_to_scene_voxel(scene_voxel: Dictionary, source_fields: Dictionary, value_override: float = -1.0, include_collision: bool = true) -> Dictionary:
	var result := scene_voxel.duplicate(true)
	var normalized := normalize_shared_fields(source_fields, result, value_override)
	result[COLOR_KEY] = normalized[COLOR_KEY]
	result[VALUE_KEY] = float(normalized[COMPLEXITY_KEY])
	result.erase(COMPLEXITY_KEY)
	if include_collision and normalized.has(COLLISION_VOXELS_KEY):
		result[COLLISION_VOXELS_KEY] = normalized[COLLISION_VOXELS_KEY]
	return result
