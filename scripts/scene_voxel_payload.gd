extends RefCounted

const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")

static func voxel_complexity(voxel: Dictionary) -> float:
	return clampf(float(voxel.get("complexity", 0.0)), 0.0, 1.0)

static func voxel_is_occupied(voxel: Dictionary, occupied_epsilon: float) -> bool:
	return voxel_complexity(voxel) > occupied_epsilon

static func public_payload(scene_voxel: Dictionary) -> Dictionary:
	var complexity := voxel_complexity(scene_voxel)
	var payload := SharedPropertyTypeScript.apply_to_scene_voxel(
		{"complexity": complexity},
		scene_voxel,
		complexity,
		SharedPropertyTypeScript.has_collision_fields(scene_voxel)
	)

	if scene_voxel.has("auto_mix"):
		payload["auto_mix"] = clampf(float(scene_voxel.get("auto_mix", 0.0)), 0.0, 1.0)

	return payload

static func internal_payload(scene_voxel: Dictionary) -> Dictionary:
	var result := public_payload(scene_voxel)
	for key in ["slice_index", "voxel_xz", "base_pixel"]:
		if scene_voxel.has(key):
			result[key] = scene_voxel[key]
	return result

static func public_map(scene_voxels: Dictionary) -> Dictionary:
	var result := {}
	for key in scene_voxels.keys():
		var scene_voxel = scene_voxels[key]
		if scene_voxel is Dictionary:
			result[key] = public_payload(scene_voxel as Dictionary)
	return result

static func flat_index(scene_voxel: Dictionary, xz_res: int, total_slices: int) -> int:
	var voxel_xz = scene_voxel.get("voxel_xz", Vector2i(-1, -1))
	if not voxel_xz is Vector2i:
		return -1

	var px: Vector2i = voxel_xz
	if px.x < 0 or px.x >= xz_res or px.y < 0 or px.y >= xz_res:
		return -1

	var slice_index := int(scene_voxel.get("slice_index", 0))
	if slice_index < 0 or slice_index >= total_slices:
		return -1

	return px.x + xz_res * (px.y + xz_res * slice_index)
