extends SceneTree

const SVC := preload("res://scripts/scene_voxel_committer.gd")


func _init() -> void:
	var committer := SVC.new(32, 32.0, false)
	committer.build_voxel_volume(16, [
		{"channel": 0, "color": Color.WHITE, "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var target_record := {
		"id": "target_guidance_0",
		"type": "target",
		"source_voxel_type": "TargetSceneVoxel",
		"target_mix": 1.0,
		"position": Vector3.ZERO,
		"base_pixel": Vector2i(16, 16),
		"voxel_xz": Vector2i(16, 16),
		"volume_xz_resolution": 32,
		"scale": Vector3.ONE,
		"color": Color(1.0, 0.0, 1.0, 1.0),
		"complexity": 1.0,
		"collision": [{
			"shape": "cylinder",
			"radius": 1.0,
			"y_min": 0.0,
			"y_max": 1.0,
			"collision_strength": 1.0,
		}],
		"channel": 0,
		"radius": 2.0,
	}

	var target_write := committer.apply_voxel_write_spec(target_record, false, committer.begin_generation_tick(committer.get_generation_tick()))
	if target_write.is_empty():
		push_error("[TargetGuidanceBoundary] Expected TargetSceneVoxel guidance record to remain queryable metadata")
		quit(1)
		return
	if bool(target_write.get("height_buffer_applied", true)) or bool(target_write.get("collision_buffer_applied", true)):
		push_error("[TargetGuidanceBoundary] Expected TargetSceneVoxel guidance record to skip source buffers")
		quit(1)
		return
	if committer.get_voxel_write_spec_count() != 0:
		push_error("[TargetGuidanceBoundary] TargetSceneVoxel guidance should not enter voxel_write_specs")
		quit(1)
		return
	if not committer.get_sv_dirty_tiles().is_empty():
		push_error("[TargetGuidanceBoundary] TargetSceneVoxel guidance should not bridge into legacy source dirty tiles")
		quit(1)
		return
	var dirty_guidance_tiles := committer.get_dirty_scene_voxel_tiles()
	if dirty_guidance_tiles.is_empty():
		push_error("[TargetGuidanceBoundary] TargetSceneVoxel guidance should mark named routing/scoring dirty")
		quit(1)
		return
	var found_target_dirty := false
	for raw_tile in dirty_guidance_tiles.values():
		if not raw_tile is Dictionary:
			continue
		var tile: Dictionary = raw_tile
		var flags: Dictionary = tile.get("dirty_flags", {})
		if bool(flags.get("target", false)) and bool(flags.get("routing", false)) and bool(flags.get("scoring", false)) and bool(flags.get("feedback", false)):
			if bool(flags.get("scene", false)) or bool(flags.get("collision", false)):
				push_error("[TargetGuidanceBoundary] TargetSceneVoxel guidance dirty should not become scene/collision dirty")
				quit(1)
				return
			found_target_dirty = true
			break
	if not found_target_dirty:
		push_error("[TargetGuidanceBoundary] TargetSceneVoxel guidance dirty flags missing target/routing/scoring/feedback")
		quit(1)
		return
	for scene_voxel in committer.get_scene_voxels().values():
		if scene_voxel is Dictionary and str((scene_voxel as Dictionary).get("source_type", "")) == "TargetSceneVoxel":
			push_error("[TargetGuidanceBoundary] TargetSceneVoxel guidance should not enter committed SceneVoxel")
			quit(1)
			return
	var sv_after_target := committer.get_sv()
	var source_ids: Array = sv_after_target.get("scene_voxel_tile_source_ids_debug", [])
	if source_ids.has("target_guidance_0"):
		push_error("[TargetGuidanceBoundary] TargetSceneVoxel guidance should not produce source debug ranges")
		quit(1)
		return
	if not committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("[TargetGuidanceBoundary] TargetSceneVoxel named dirty flags should clear after SV snapshot")
		quit(1)
		return
	for raw_tile in (sv_after_target.get("scene_voxel_tiles", {}) as Dictionary).values():
		if not raw_tile is Dictionary:
			continue
		var tile: Dictionary = raw_tile
		if int(tile.get("source_range_count", 0)) > 0:
			push_error("[TargetGuidanceBoundary] Target-only SceneVoxelTile should not publish source ranges")
			quit(1)
			return

	var target_sv_b := target_record.duplicate(true)
	target_sv_b["id"] = "target_sv_b_0"
	target_sv_b["source_voxel_type"] = "TargetSV_B"
	target_sv_b["type"] = "TargetSV_B"
	target_sv_b["voxel_min"] = Vector3i(4, 0, 4)
	target_sv_b["voxel_max"] = Vector3i(8, 1, 8)
	var target_sv_b_write := committer.apply_voxel_write_spec(target_sv_b, false, committer.begin_generation_tick(committer.get_generation_tick()))
	if str(target_sv_b_write.get("source_voxel_type", "")) != "TargetSceneVoxel" or not bool(target_sv_b_write.get("target_guidance_only", false)):
		push_error("[TargetGuidanceBoundary] TargetSV_B should normalize to guidance-only TargetSceneVoxel")
		quit(1)
		return
	if committer.get_voxel_write_spec_count() != 0:
		push_error("[TargetGuidanceBoundary] TargetSV_B guidance should not enter voxel_write_specs")
		quit(1)
		return
	if not committer.get_sv_dirty_tiles().is_empty():
		push_error("[TargetGuidanceBoundary] TargetSV_B guidance should not bridge into legacy source dirty tiles")
		quit(1)
		return

	print("[TargetGuidanceBoundary] TargetSceneVoxel stays guidance-only")
	quit(0)
