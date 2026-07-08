extends RefCounted

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

static func scene_voxel_key(slice_index: int, voxel_px: Vector2i) -> String:
	return "%d:%d:%d" % [slice_index, voxel_px.x, voxel_px.y]
