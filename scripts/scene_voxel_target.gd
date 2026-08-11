extends RefCounted
class_name SceneVoxelTarget

const TARGET_TYPE := "TargetSceneVoxel"

const FLAG_TARGET  := 16
const FLAG_ROUTING := 32
const FLAG_SCORING := 64
const FLAG_FEEDBACK := 128

static func is_target_type(source_voxel_type: String) -> bool:
	return source_voxel_type == TARGET_TYPE

static func target_dirty_flags() -> Dictionary:
	return {
		"target": true,
		"routing": true,
		"scoring": true,
		"feedback": true,
	}
