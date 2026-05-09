extends SceneTree


func _init() -> void:
	var veg := VegetationExclusion.new(32, 32.0, false)
	veg.add_band("ground", 0.0, 1.0, 32, Color(0.2, 0.8, 0.2, 1.0))

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
		"affected_bands": [{
			"band": "ground",
			"channel": 0,
			"radius": 2.0,
			"color": Color(0.55, 0.50, 0.45, 1.0),
			"complexity": 1.0,
		}],
	}

	veg.apply_mesh_voxel_record(record)
	veg.build_voxel_volume(16, 1)

	var scene_voxels := veg.get_scene_voxels()
	var source_deltas := veg.get_source_voxel_deltas(veg.get_committed_tick())
	var global_field := veg.get_global_voxel_field()

	if scene_voxels.is_empty():
		push_error("Expected committed SceneVoxel entries")
		quit(1)
		return
	if source_deltas.is_empty() or (source_deltas.get("auto", {}) as Dictionary).is_empty():
		push_error("Expected AutoSceneVoxel source delta entries")
		quit(1)
		return
	if int(global_field.get("tile_count", 0)) <= 0:
		push_error("Expected GlobalVoxelField tiles")
		quit(1)
		return
	if int(global_field.get("dirty_tile_count", 0)) <= 0:
		push_error("Expected GlobalVoxelField dirty tiles from committed writes")
		quit(1)
		return

	var stale_record := veg.get_mesh_voxel_record("test_rock_0")
	var stale_write_tick := int(stale_record.get("write_tick", -1))
	var next_tick := veg.begin_generation_tick(veg.get_generation_tick())
	var updated_stale := veg.apply_mesh_voxel_record(stale_record, true, next_tick)
	if int(updated_stale.get("write_tick", -1)) != next_tick:
		push_error("Expected stale voxel record to be rebound to the current write tick")
		quit(1)
		return
	if int(updated_stale.get("write_tick", -1)) == stale_write_tick:
		push_error("Expected repeated writes to avoid reusing an old write tick")
		quit(1)
		return
	var next_delta := veg.get_source_voxel_deltas(next_tick)
	if next_delta.is_empty() or (next_delta.get("auto", {}) as Dictionary).is_empty():
		push_error("Expected repeated source write under the new tick")
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
	erase_record["affected_bands"] = [{
		"band": "ground",
		"channel": 0,
		"radius": 1.0,
		"color": erase_color,
		"complexity": 0.0,
	}]
	erase_record.erase("SenceLayerVoxel")
	veg.apply_mesh_voxel_record(erase_record, true, erase_tick)
	var erase_delta := veg.get_source_voxel_deltas(erase_tick)
	if erase_delta.is_empty() or (erase_delta.get("brush", {}) as Dictionary).is_empty():
		push_error("Expected erase BrushSceneVoxel to write zero-value source voxels")
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
		push_error("Expected explicit GlobalVoxelField rect invalidation to mark dirty tiles")
		quit(1)
		return
	var invalidated_field := veg.get_global_voxel_field()
	if int(invalidated_field.get("dirty_tile_count", 0)) <= 0:
		push_error("Expected GlobalVoxelField rebuild to report invalidated tiles")
		quit(1)
		return

	print("[test_scene_voxel_field] scene_voxels=%d tiles=%d commit_tick=%d erase_tick=%d" % [
		scene_voxels.size(),
		int(invalidated_field.get("tile_count", 0)),
		veg.get_committed_tick(),
		erase_tick,
	])
	quit(0)
