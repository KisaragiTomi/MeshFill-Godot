class_name SceneVoxel
extends RefCounted

const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")

const PUBLIC_FIELD_KEYS := [
	"complexity",
	"color",
	"collision",
	"auto_mix",
]
const INTERNAL_FIELD_KEYS := [
	"slice_index",
	"voxel_xz",
	"base_pixel",
]

static func complexity(scene_voxel: Dictionary) -> float:
	return clampf(float(scene_voxel.get("complexity", 0.0)), 0.0, 1.0)

static func accepted(source: Dictionary) -> Dictionary:
	var accepted_complexity := complexity(source)
	var shared_fields := {
		"complexity": accepted_complexity,
	}
	if source.has("color"):
		shared_fields["color"] = source.get("color")
	if source.has("collision"):
		shared_fields["collision"] = source.get("collision")

	var result := SharedPropertyTypeScript.apply_to_scene_voxel(
		{},
		shared_fields,
		accepted_complexity,
		SharedPropertyTypeScript.has_collision_fields(source)
	)
	if source.has("auto_mix"):
		result["auto_mix"] = clampf(float(source.get("auto_mix", 0.0)), 0.0, 1.0)
	return result

static func accepted_internal(source: Dictionary) -> Dictionary:
	var result := accepted(source)
	for key in INTERNAL_FIELD_KEYS:
		if source.has(key):
			result[key] = source[key]
	return result

## accepted_internal + 覆写寻址字段（query 命中体素的规范化出口）
static func accepted_at(source: Dictionary, slice_index: int, voxel_xz: Vector2i) -> Dictionary:
	var result := accepted_internal(source)
	result["slice_index"] = slice_index
	result["voxel_xz"] = voxel_xz
	return result

static func accepted_map(scene_voxels: Dictionary) -> Dictionary:
	var result := {}
	for key in scene_voxels.keys():
		var scene_voxel = scene_voxels[key]
		if scene_voxel is Dictionary:
			result[key] = accepted(scene_voxel as Dictionary)
	return result

static func accepts_key(key: String, include_internal: bool = false) -> bool:
	if PUBLIC_FIELD_KEYS.has(key):
		return true
	return include_internal and INTERNAL_FIELD_KEYS.has(key)

static func has_only_accepted_fields(scene_voxel: Dictionary, include_internal: bool = false) -> bool:
	for key in scene_voxel.keys():
		if not accepts_key(str(key), include_internal):
			return false
	return true
