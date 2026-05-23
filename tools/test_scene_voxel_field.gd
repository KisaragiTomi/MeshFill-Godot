extends SceneTree

const CHANNEL_ENTRIES_KEY := "channel_entries"


func _init() -> void:
	var veg := SceneVoxelCommitter.new(32, 32.0, false)

	var record := {
		"id": "test_rock_0",
		"type": "rock",
		"source_voxel_type": "AutoSceneVoxel",
		"source_kind": "rock_placement",
		"producer_stage": "rock_placement",
		"position": Vector3.ZERO,
		"base_pixel": Vector2i(16, 16),
		"voxel_xz": Vector2i(16, 16),
		"volume_xz_resolution": 32,
		"scale": Vector3.ONE,
		"color": Color(0.55, 0.50, 0.45, 1.0),
		"complexity": 1.0,
		"collision_voxels": [{
			"shape": "cylinder",
			"radius": 1.0,
			"y_min": 0.0,
			"y_max": 1.0,
			"value": 1.0,
		}],
	}
	record[CHANNEL_ENTRIES_KEY] = [{
		"channel": 0,
		"base_pixel": Vector2i(16, 16),
		"voxel_xz": Vector2i(16, 16),
		"volume_xz_resolution": 32,
		"radius": 2.0,
		"color": Color(0.55, 0.50, 0.45, 1.0),
		"complexity": 1.0,
		"slice_indices": [],
	}]

	veg.apply_mesh_asset_voxel_record(record)
	veg.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.2, 0.8, 0.2, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var scene_voxels := veg.get_scene_voxels()
	var global_field := veg.get_scene_voxel_runtime()

	if scene_voxels.is_empty():
		push_error("Expected committed SceneVoxel entries")
		quit(1)
		return
	if int(global_field.get("tile_count", 0)) <= 0:
		push_error("Expected SceneVoxelLocal tiles")
		quit(1)
		return
	if int(global_field.get("dirty_tile_count", 0)) <= 0:
		push_error("Expected SceneVoxelLocal dirty tiles from committed writes")
		quit(1)
		return
	var committed_center := veg.get_scene_voxel(0, Vector2i(8, 8))
	if committed_center.is_empty():
		push_error("Expected committed SceneVoxel at center")
		quit(1)
		return
	var committed_color: Color = committed_center.get("color", Color.TRANSPARENT)
	if absf(committed_color.r - 0.55) > 0.001 or absf(committed_color.a - 1.0) > 0.001:
		push_error("Expected shared color to propagate to SceneVoxel")
		quit(1)
		return
	if absf(float(committed_center.get("complexity", -1.0)) - 1.0) > 0.001:
		push_error("Expected shared complexity to propagate to SceneVoxel")
		quit(1)
		return
	if str(committed_center.get("source_type", "")) != "AutoSceneVoxel":
		push_error("Expected committed SceneVoxel to record AutoSceneVoxel source")
		quit(1)
		return
	for removed_key in [
		"record_id",
		"mesh_name",
		"node_path",
		"auto_source",
		"auto_id",
		"auto_instance_id",
		"instance_id",
		"instance_mesh_id",
		"mesh_instance_id",
		"object_subtype",
		"source_voxel_types",
		"dominant_source_type",
		"blend_mode",
	]:
		if committed_center.has(removed_key):
			push_error("Committed SceneVoxel still contains removed per-voxel field '%s'" % removed_key)
			quit(1)
			return
	var committed_collision = committed_center.get("collision_voxels", [])
	if not committed_collision is Array or (committed_collision as Array).is_empty():
		push_error("Expected shared collision_voxels to propagate to SceneVoxel")
		quit(1)
		return

	var stale_record := veg.get_mesh_asset_voxel_record("test_rock_0")
	var stale_write_tick := int(stale_record.get("write_tick", -1))
	var next_tick := veg.begin_generation_tick(veg.get_generation_tick())
	var updated_stale := veg.apply_mesh_asset_voxel_record(stale_record, true, next_tick)
	if int(updated_stale.get("write_tick", -1)) != next_tick:
		push_error("Expected stale voxel_write_spec to be rebound to the current write tick")
		quit(1)
		return
	if int(updated_stale.get("write_tick", -1)) == stale_write_tick:
		push_error("Expected repeated writes to avoid reusing an old write tick")
		quit(1)
		return
	var next_center := veg.get_scene_voxel(0, Vector2i(8, 8))
	if next_center.is_empty() or int(next_center.get("commit_tick", -1)) != next_tick:
		push_error("Expected repeated write to update SceneVoxel under the new tick")
		quit(1)
		return
	veg.blend_scene_voxels(next_tick)

	var erase_tick := veg.begin_generation_tick(veg.get_generation_tick())
	var erase_color := Color(0.0, 0.0, 0.0, 0.0)
	var erase_record := record.duplicate(true)
	erase_record["id"] = "erase_test_0"
	erase_record["source_voxel_type"] = "BrushSceneVoxel"
	erase_record["source_kind"] = "erase"
	erase_record["producer_stage"] = "brush_edit"
	erase_record["auto_mix"] = 0.0
	erase_record["color"] = erase_color
	erase_record["complexity"] = 0.0
	erase_record[CHANNEL_ENTRIES_KEY] = [{
		"channel": 0,
		"base_pixel": Vector2i(16, 16),
		"voxel_xz": Vector2i(16, 16),
		"volume_xz_resolution": 32,
		"radius": 1.0,
		"color": erase_color,
		"complexity": 0.0,
		"slice_indices": [],
	}]
	veg.apply_mesh_asset_voxel_record(erase_record, true, erase_tick)
	var pending_erased_center := veg.get_scene_voxel(0, Vector2i(8, 8))
	if pending_erased_center.is_empty() or bool(pending_erased_center.get("occupied", true)):
		push_error("Expected erase BrushSceneVoxel to write zero-value SceneVoxel")
		quit(1)
		return
	if str(pending_erased_center.get("source_type", "")) != "BrushSceneVoxel":
		push_error("Expected erase SceneVoxel to record BrushSceneVoxel source")
		quit(1)
		return
	veg.blend_scene_voxels(erase_tick)
	var erased_center := veg.get_scene_voxel(0, Vector2i(8, 8))
	if erased_center.is_empty() or bool(erased_center.get("occupied", true)):
		push_error("Expected erase BrushSceneVoxel to commit an unoccupied SceneVoxel")
		quit(1)
		return

	veg.invalidate_global_voxel_rect(Rect2i(Vector2i(12, 12), Vector2i(8, 8)), [0], true)
	if veg.get_global_voxel_dirty_tiles().is_empty():
		push_error("Expected explicit SceneVoxelLocal rect invalidation to mark dirty tiles")
		quit(1)
		return
	var invalidated_field := veg.get_scene_voxel_runtime()
	if int(invalidated_field.get("dirty_tile_count", 0)) <= 0:
		push_error("Expected SceneVoxelLocal rebuild to report invalidated tiles")
		quit(1)
		return

	print("[test_scene_voxel_field] scene_voxels=%d tiles=%d commit_tick=%d erase_tick=%d" % [
		scene_voxels.size(),
		int(invalidated_field.get("tile_count", 0)),
		veg.get_committed_tick(),
		erase_tick,
	])
	quit(0)
