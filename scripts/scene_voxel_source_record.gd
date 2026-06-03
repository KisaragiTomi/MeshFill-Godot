extends RefCounted

const COMMIT_SOURCE_AUTO := 1
const COMMIT_SOURCE_BRUSH := 2
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")

static func prepare_source_record(record: Dictionary, tick: int) -> Dictionary:
	var rec := SharedPropertyTypeScript.apply_to_record(
		record,
		SharedPropertyTypeScript.normalize_shared_fields(record)
	)

	var write_tick := maxi(tick, 0)
	var max_read_tick := maxi(write_tick - 1, 0)
	var source_type := str(rec.get("source_voxel_type", ""))

	rec["source_voxel_type"] = source_type
	rec["generation_tick"] = write_tick
	rec["read_tick"] = clampi(int(rec.get("read_tick", max_read_tick)), 0, max_read_tick)
	rec["write_tick"] = write_tick

	if source_type == "BrushSceneVoxel":
		rec["auto_mix"] = clampf(float(rec.get("auto_mix", 0.0)), 0.0, 1.0)
		if not rec.has("modified_voxels"):
			rec["modified_voxels"] = []

	if source_type == "TargetSceneVoxel":
		rec["target_mix"] = clampf(float(rec.get("target_mix", 1.0)), 0.0, 1.0)
		rec["target_pipeline"] = str(rec.get("target_pipeline", "guidance"))

	return rec

static func source_type_code(source_voxel: Dictionary) -> int:
	var source_type := str(source_voxel.get("source_voxel_type", source_voxel.get("type", "")))
	if source_type == "BrushSceneVoxel":
		return COMMIT_SOURCE_BRUSH
	return COMMIT_SOURCE_AUTO

static func source_modifies_key(source_voxel: Dictionary, key: String) -> bool:
	var modified: Array = source_voxel.get("modified_voxels", [])
	if modified.is_empty():
		return true

	for item in modified:
		if item is String and str(item) == key:
			return true
		if item is Dictionary:
			var item_dict := item as Dictionary
			if str(item_dict.get("key", "")) == key:
				return true

			var item_slice := int(item_dict.get("slice_index", source_voxel.get("slice_index", -1)))
			var item_px = item_dict.get("voxel_xz", Vector2i(-1, -1))
			if item_px is Vector2i and scene_voxel_key(item_slice, item_px) == key:
				return true
		if item is Vector2i:
			var item_key := scene_voxel_key(int(source_voxel.get("slice_index", -1)), item)
			if item_key == key:
				return true

	return false

static func scene_voxel_key(slice_index: int, voxel_px: Vector2i) -> String:
	return "%d:%d:%d" % [slice_index, voxel_px.x, voxel_px.y]
