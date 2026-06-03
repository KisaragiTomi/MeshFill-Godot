extends RefCounted

static func empty_result(target_role: String) -> Dictionary:
	return {
		"stage": "post_commit_blendsv_feedback",
		"target_role": target_role,
		"score": 0.0,
		"sample_count": 0,
		"scene_occupied_count": 0,
		"target_occupied_count": 0,
		"overlap_occupied_count": 0,
	}
