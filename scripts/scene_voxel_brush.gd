extends RefCounted
class_name SceneVoxelBrush

const BRUSH_TYPE := "BrushSceneVoxel"

static func is_brush_type(source_voxel_type: String) -> bool:
	return source_voxel_type == BRUSH_TYPE

static func prepare_brush_record(record: Dictionary, tick: int) -> void:
	if not record.has("auto_mix"):
		record["auto_mix"] = 0.0
	if not record.has("modified_voxels"):
		record["modified_voxels"] = []

static func apply_brush_fields(source_voxel: Dictionary, record: Dictionary) -> void:
	source_voxel["brush_stroke_id"] = str(record.get("brush_stroke_id", record.get("id", "")))
	source_voxel["auto_mix"] = clampf(float(record.get("auto_mix", 0.0)), 0.0, 1.0)
	var modified_voxels: Array = record.get("modified_voxels", [])
	source_voxel["modified_voxels"] = modified_voxels.duplicate(true)
