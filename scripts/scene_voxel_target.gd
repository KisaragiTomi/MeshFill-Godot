extends RefCounted
class_name SceneVoxelTarget

const TARGET_TYPE := "TargetSceneVoxel"

const FLAG_TARGET  := 16
const FLAG_ROUTING := 32
const FLAG_SCORING := 64
const FLAG_FEEDBACK := 128

static func is_target_type(source_voxel_type: String) -> bool:
	return source_voxel_type == TARGET_TYPE

static func prepare_target_record(record: Dictionary, tick: int) -> void:
	if not record.has("target_mix"):
		record["target_mix"] = 1.0
	if not record.has("target_pipeline"):
		record["target_pipeline"] = "guidance"

static func apply_target_fields(source_voxel: Dictionary, record: Dictionary) -> void:
	source_voxel["target_mix"] = clampf(float(record.get("target_mix", 1.0)), 0.0, 1.0)
	source_voxel["target_pipeline"] = str(record.get("target_pipeline", "guidance"))

static func target_dirty_flags() -> Dictionary:
	return {
		"target": true,
		"routing": true,
		"scoring": true,
		"feedback": true,
	}
