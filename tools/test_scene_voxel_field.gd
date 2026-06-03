extends SceneTree

const SVC := preload("res://scripts/scene_voxel_committer.gd")
const SceneVoxelCommitPayloadScript := preload("res://scripts/scene_voxel_commit_payload.gd")
const SceneVoxelValidationScript := preload("res://scripts/scene_voxel_validation.gd")


func _init() -> void:
	if not _test_commit_payload_decode_byte_trim_contract():
		quit(1)
		return

	if not _has_rendering_device():
		print("[test_scene_voxel_field] SKIP: no RenderingDevice")
		quit(0)
		return

	if not _test_resample_collision_field_contract():
		quit(1)
		return
	if not _test_sv_collision_field_contract():
		quit(1)
		return
	if not _test_occupancy_slice_image_contract():
		quit(1)
		return
	if not _test_voxel_stats_slice_texture_contract():
		quit(1)
		return
	if not _test_static_scene_voxel_validation_slice_texture_contract():
		quit(1)
		return

	var committer := SVC.new(32, 32.0)

	var record := {
		"id": "test_rock_0",
		"type": "rock",
		"source_voxel_type": "AutoSceneVoxel",
		"position": Vector3.ZERO,
		"base_pixel": Vector2i(16, 16),
		"voxel_xz": Vector2i(16, 16),
		"volume_xz_resolution": 32,
		"scale": Vector3.ONE,
		"color": Color(0.55, 0.50, 0.45, 1.0),
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

	committer.apply_voxel_write_spec(record)
	committer.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.2, 0.8, 0.2, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var scene_voxels := committer.get_scene_voxels()
	var sv: Dictionary = committer.get_sv()
	var initial_sv_dirty_scene_tile_count := int(sv.get("dirty_scene_voxel_tile_count", -1))

	if scene_voxels.is_empty():
		push_error("Expected committed SceneVoxel entries")
		quit(1)
		return
	if int(sv.get("tile_count", 0)) <= 0:
		push_error("Expected SV tiles")
		quit(1)
		return
	if int(sv.get("dirty_tile_count", 0)) <= 0:
		push_error("Expected SV dirty tiles from committed writes")
		quit(1)
		return
	if not bool(sv.get("tile_summary_gpu_dispatched", false)):
		push_error("Expected SV tile summaries to be reduced on GPU")
		quit(1)
		return
	if str(sv.get("scene_voxel_tile_summary_source", "")) != "reduce_scene_voxel_tile_summaries_compute":
		push_error("Expected SceneVoxelTile summary compute source, got %s" % str(sv.get("scene_voxel_tile_summary_source", "")))
		quit(1)
		return
	if str(sv.get("legacy_tile_summary_source", "")) != "reduce_scene_voxel_tile_summaries_compute":
		push_error("Expected legacy tile summary compute source, got %s" % str(sv.get("legacy_tile_summary_source", "")))
		quit(1)
		return
	var committed_center := committer.get_scene_voxel(0, Vector2i(8, 8))
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
	var stats := committer.get_voxel_stats()
	if not bool(stats.get("gpu_dispatched", false)):
		push_error("Expected voxel stats to use GPU reduce")
		quit(1)
		return
	if bool(stats.get("cpu_fallback", true)):
		push_error("Voxel stats must not report CPU fallback")
		quit(1)
		return
	if int(stats.get("occupied_voxels", 0)) <= 0:
		push_error("Expected voxel stats to count committed occupancy")
		quit(1)
		return
	var validation := committer.validate_voxel({
		"min_diversity_score": 1,
		"min_channel_occupancy": {0: 1.0},
	})
	if not bool(validation.get("passed", false)):
		push_error("Expected voxel validation to pass with GPU stats: %s" % str(validation))
		quit(1)
		return
	var validation_metrics: Dictionary = validation.get("metrics", {})
	if not bool(validation_metrics.get("gpu_dispatched", false)):
		push_error("Expected voxel validation metrics to report GPU dispatch")
		quit(1)
		return
	if bool(validation_metrics.get("cpu_fallback", true)):
		push_error("Voxel validation must not report CPU fallback")
		quit(1)
		return
	var forbidden_public_payload_keys := [
		"record_id",
		"mesh_name",
		"node_path",
		"auto_source",
		"auto_id",
		"auto_instance_id",
		"instance_id",
		"instance_mesh_id",
		"mesh_instance_id",
		"channel",
		"object_subtype",
		"source_voxel_types",
		"dominant_source_type",
		"blend_mode",
		"occupied",
		"type",
		"source_type",
		"source_voxel_type",
		"source_id",
		"auto_object_id",
		"commit_tick",
		"write_tick",
		"read_tick",
		"generation_tick",
		"value",
		"debug",
	]
	for removed_key in forbidden_public_payload_keys:
		if committed_center.has(removed_key):
			push_error("Committed SceneVoxel still contains removed per-voxel field '%s'" % removed_key)
			quit(1)
			return
	for raw_scene_voxel in scene_voxels.values():
		if not raw_scene_voxel is Dictionary:
			continue
		var public_scene_voxel := raw_scene_voxel as Dictionary
		for removed_key in forbidden_public_payload_keys:
			if public_scene_voxel.has(removed_key):
				push_error("Committed SceneVoxel map still contains removed per-voxel field '%s'" % removed_key)
				quit(1)
				return
	var committed_collision = committed_center.get("collision", [])
	if not committed_collision is Array or (committed_collision as Array).is_empty():
		push_error("Expected shared collision to propagate to SceneVoxel")
		quit(1)
		return
	if committer.has_method("get_scene_voxel_sidecar") or committer.has_method("get_scene_voxel_local"):
		push_error("SceneVoxel CPU sidecar/local query path should be removed")
		quit(1)
		return
	var scene_voxel_tile_size: Vector3i = sv.get("scene_voxel_tile_size", Vector3i(4, 4, 4))
	var center_tile_coord := Vector3i(
		int(8 / maxi(scene_voxel_tile_size.x, 1)),
		0,
		int(8 / maxi(scene_voxel_tile_size.z, 1))
	)
	var center_tile_id := "%d:%d:%d" % [center_tile_coord.x, center_tile_coord.y, center_tile_coord.z]
	var scene_voxel_tiles: Dictionary = sv.get("scene_voxel_tiles", {})
	if not scene_voxel_tiles.has(center_tile_id):
		push_error("Expected SceneVoxelTile to be derived from voxel coord: %s" % center_tile_id)
		quit(1)
		return

	var stale_record := committer.get_voxel_write_spec("test_rock_0")
	var stale_write_tick := int(stale_record.get("write_tick", -1))
	var next_tick := committer.begin_generation_tick(committer.get_generation_tick())
	var updated_stale := committer.apply_voxel_write_spec(stale_record, true, next_tick)
	if int(updated_stale.get("write_tick", -1)) != next_tick:
		push_error("Expected stale voxel_write_spec to be rebound to the current write tick")
		quit(1)
		return
	if int(updated_stale.get("write_tick", -1)) == stale_write_tick:
		push_error("Expected repeated writes to avoid reusing an old write tick")
		quit(1)
		return
	var next_center := committer.get_scene_voxel(0, Vector2i(8, 8))
	if next_center.is_empty() or absf(float(next_center.get("complexity", -1.0)) - 1.0) > 0.001:
		push_error("Expected repeated write to preserve committed SceneVoxel complexity")
		quit(1)
		return
	committer.blend_scene_voxels(next_tick)

	var erase_tick := committer.begin_generation_tick(committer.get_generation_tick())
	var erase_color := Color(0.0, 0.0, 0.0, 0.0)
	var erase_record := record.duplicate(true)
	erase_record["id"] = "erase_test_0"
	erase_record["source_voxel_type"] = "BrushSceneVoxel"
	erase_record["auto_mix"] = 0.0
	erase_record["color"] = erase_color
	erase_record["complexity"] = 0.0
	erase_record["channel"] = 0
	erase_record["radius"] = 1.0
	committer.apply_voxel_write_spec(erase_record, true, erase_tick)
	var pre_blend_erased_center := committer.get_scene_voxel(0, Vector2i(8, 8))
	if pre_blend_erased_center.is_empty() or absf(float(pre_blend_erased_center.get("complexity", -1.0)) - 1.0) > 0.001:
		push_error("Expected deferred erase BrushSceneVoxel to stay out of committed SceneVoxel before blend")
		quit(1)
		return
	committer.blend_scene_voxels(erase_tick)
	var erased_center := committer.get_scene_voxel(0, Vector2i(8, 8))
	if erased_center.is_empty() or float(erased_center.get("complexity", 1.0)) > 0.001:
		push_error("Expected erase BrushSceneVoxel to commit an unoccupied SceneVoxel")
		quit(1)
		return

	committer.invalidate_sv_rect(Rect2i(Vector2i(12, 12), Vector2i(8, 8)), [0], true)
	if committer.get_sv_dirty_tiles().is_empty():
		push_error("Expected explicit SV rect invalidation to mark dirty tiles")
		quit(1)
		return
	var invalidated_sv: Dictionary = committer.get_sv()
	if int(invalidated_sv.get("dirty_tile_count", 0)) <= 0:
		push_error("Expected SV rebuild to report invalidated tiles")
		quit(1)
		return
	if not committer.get_sv_dirty_tiles().is_empty() or not committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("Expected SV rebuild to clear pending dirty storage after snapshot publish")
		quit(1)
		return
	var snapshot_dirty_count := int(invalidated_sv.get("dirty_scene_voxel_tile_count", 0))
	committer.invalidate_sv_tile(0, Vector2i(0, 0), "scene")
	if int(invalidated_sv.get("dirty_scene_voxel_tile_count", 0)) != snapshot_dirty_count:
		push_error("Expected returned SV resident state to be a snapshot, not live dirty storage")
		quit(1)
		return
	if int(sv.get("dirty_scene_voxel_tile_count", -1)) != initial_sv_dirty_scene_tile_count:
		push_error("Expected earlier SV duplicate snapshot to remain stable")
		quit(1)
		return
	if not _test_dirty_tile_limited_source_write():
		quit(1)
		return

	print("[test_scene_voxel_field] scene_voxels=%d tiles=%d commit_tick=%d erase_tick=%d" % [
		scene_voxels.size(),
		int(invalidated_sv.get("tile_count", 0)),
		committer.get_committed_tick(),
		erase_tick,
	])
	committer.dispose(true)
	quit(0)


func _test_commit_payload_decode_byte_trim_contract() -> bool:
	var float_bytes := PackedFloat32Array([1.5, -2.0]).to_byte_array()
	float_bytes.append(0x7f)
	var floats := SceneVoxelCommitPayloadScript.decode_float_buffer(float_bytes, 3)
	if floats.size() != 3:
		push_error("Expected float payload decode to preserve requested logical size")
		return false
	if absf(floats[0] - 1.5) > 0.001 or absf(floats[1] + 2.0) > 0.001 or absf(floats[2]) > 0.001:
		push_error("Expected float payload decode to ignore trailing partial scalar byte: %s" % str(floats))
		return false

	var int_bytes := PackedInt32Array([17, -3]).to_byte_array()
	int_bytes.append(0x7f)
	var ints := SceneVoxelCommitPayloadScript.decode_u32_buffer(int_bytes, 3)
	if ints.size() != 3:
		push_error("Expected u32 payload decode to preserve requested logical size")
		return false
	if ints[0] != 17 or ints[1] != -3 or ints[2] != 0:
		push_error("Expected u32 payload decode to ignore trailing partial scalar byte: %s" % str(ints))
		return false
	return true


func _has_rendering_device() -> bool:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return false
	probe_rd.free()
	return true


func _test_resample_collision_field_contract() -> bool:
	var committer := SVC.new(4, 4.0)
	var source := Image.create(4, 4, false, Image.FORMAT_RF)
	source.fill(Color(0.0, 0.0, 0.0, 0.0))
	source.set_pixelv(Vector2i(0, 0), Color(0.25, 0.0, 0.0, 0.0))
	source.set_pixelv(Vector2i(2, 2), Color(0.75, 0.0, 0.0, 0.0))

	var out := committer._resample_collision_field(source, 2)
	if absf(out.get_pixelv(Vector2i(0, 0)).r - 0.25) > 0.001:
		push_error("Expected resampled collision field to copy source origin")
		return false
	if absf(out.get_pixelv(Vector2i(1, 1)).r - 0.75) > 0.001:
		push_error("Expected resampled collision field to use base-res nearest sample")
		return false
	if out.get_pixelv(Vector2i(1, 0)).r > 0.001:
		push_error("Expected unset resampled collision field pixel to remain empty")
		return false
	committer.dispose(true)
	return true


func _test_sv_collision_field_contract() -> bool:
	var committer := SVC.new(2, 2.0)
	var terrain := Image.create(2, 2, false, Image.FORMAT_RF)
	terrain.fill(Color(0.0, 0.0, 0.0, 0.0))
	terrain.set_pixelv(Vector2i(1, 0), Color(0.6, 0.0, 0.0, 0.0))
	terrain.set_pixelv(Vector2i(0, 1), Color(0.8, 0.0, 0.0, 0.0))
	committer._volume["terrain_base_collision_field"] = terrain

	var collision := {
		"source_override": {
			"slice_index": 1,
			"voxel_xz": Vector2i(0, 0),
			"collision_strength": 0.9,
		},
	}
	var field := committer._make_sv_collision_field(collision, 2, 3)
	if field.size() != 12:
		push_error("Expected 2x2x3 collision volume field")
		return false
	if absf(field[1] - 0.6) > 0.001 or absf(field[9] - 0.6) > 0.001:
		push_error("Expected terrain collision to be expanded through all slices")
		return false
	if absf(field[2] - 0.8) > 0.001:
		push_error("Expected second terrain collision pixel in base slice")
		return false
	if absf(field[4] - 0.9) > 0.001:
		push_error("Expected source collision overlay to max into the collision volume")
		return false
	committer.dispose(true)
	return true


func _test_occupancy_slice_image_contract() -> bool:
	var committer := SVC.new(4, 4.0)
	committer._occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	committer._occupancy.set_pixelv(Vector2i(2, 2), Color(0.0, 0.7, 0.0, 0.0))
	committer._occupancy.set_pixelv(Vector2i(0, 0), Color(0.0, 0.005, 0.0, 0.0))

	var slice_img := committer._make_occupancy_slice_image(1, 2)
	if absf(slice_img.get_pixelv(Vector2i(1, 1)).r - 0.7) > 0.001:
		push_error("Expected occupancy slice image to extract selected channel")
		return false
	if slice_img.get_pixelv(Vector2i(0, 0)).r > 0.001:
		push_error("Expected occupancy slice image to threshold tiny values")
		return false

	var invalid_img := committer._make_occupancy_slice_image(5, 2)
	if invalid_img.get_pixelv(Vector2i(1, 1)).r > 0.001:
		push_error("Expected invalid occupancy channel to produce an empty slice")
		return false
	committer.dispose(true)
	return true


func _test_voxel_stats_slice_texture_contract() -> bool:
	var committer := SVC.new(4, 4.0)
	committer._occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	committer._occupancy.set_pixelv(Vector2i(2, 2), Color(0.0, 0.5, 0.0, 0.0))
	var collision_img := Image.create(4, 4, false, Image.FORMAT_RF)
	collision_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	collision_img.set_pixelv(Vector2i(1, 1), Color(1.0, 0.0, 0.0, 0.0))
	committer.set_terrain_base_collision_field(collision_img)
	committer.build_voxel_volume(4, [
		{"channel": 1, "color": Color(0.2, 0.8, 0.2, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var stats := committer.get_voxel_stats()
	if str(stats.get("stats_source", "")) != "volume_slice_texture":
		push_error("Expected slice texture stats source for volume-only occupancy: %s" % str(stats))
		return false
	if not bool(stats.get("gpu_dispatched", false)) or bool(stats.get("cpu_fallback", true)):
		push_error("Expected slice texture stats to be GPU-only: %s" % str(stats))
		return false
	if int(stats.get("occupied_voxels", 0)) != 1:
		push_error("Expected one occupied voxel from slice texture stats, got %s" % str(stats))
		return false
	if int(stats.get("collision", 0)) != 1:
		push_error("Expected one collision pixel from GPU stats, got %s" % str(stats))
		return false

	var validation := committer.validate_voxel({
		"min_diversity_score": 1,
		"min_channel_occupancy": {1: 1.0},
		"max_channel_occupancy": {1: 10.0},
	})
	if not bool(validation.get("passed", false)):
		push_error("Expected slice texture validation to pass: %s" % str(validation))
		return false
	var metrics: Dictionary = validation.get("metrics", {})
	if str(metrics.get("stats_source", "")) != "volume_slice_texture":
		push_error("Expected validation to reuse slice texture GPU stats: %s" % str(validation))
		return false
	committer.dispose(true)
	return true


func _test_static_scene_voxel_validation_slice_texture_contract() -> bool:
	var slice_a := Image.create(4, 4, false, Image.FORMAT_RF)
	slice_a.fill(Color(0.0, 0.0, 0.0, 0.0))
	slice_a.set_pixelv(Vector2i(0, 0), Color(0.5, 0.0, 0.0, 0.0))
	slice_a.set_pixelv(Vector2i(1, 1), Color(0.6, 0.0, 0.0, 0.0))
	var slice_b := Image.create(4, 4, false, Image.FORMAT_RF)
	slice_b.fill(Color(0.0, 0.0, 0.0, 0.0))
	slice_b.set_pixelv(Vector2i(2, 2), Color(0.7, 0.0, 0.0, 0.0))

	var validation := SceneVoxelValidationScript.validate_volume({
		"xz_res": 4,
		"slices": [slice_a, slice_b],
		"slice_meta": [
			{"channel": 0},
			{"channel": 1},
		],
	}, {
		"min_diversity_score": 2,
		"min_channel_occupancy": {0: 10.0, 1: 5.0},
		"max_channel_occupancy": {0: 20.0, 1: 10.0},
	}, 2, 0.01)
	if not bool(validation.get("passed", false)):
		push_error("Expected static SceneVoxelValidation slice texture path to pass: %s" % str(validation))
		return false
	var metrics: Dictionary = validation.get("metrics", {})
	if not bool(metrics.get("gpu_dispatched", false)) or bool(metrics.get("cpu_fallback", true)):
		push_error("Expected static SceneVoxelValidation to use GPU-only counting: %s" % str(validation))
		return false
	if str(metrics.get("stats_source", "")) != "volume_slice_texture":
		push_error("Expected static SceneVoxelValidation stats source to be volume_slice_texture: %s" % str(validation))
		return false
	var occupancy: Array = metrics.get("channel_occupancy_pct", [])
	if occupancy.size() < 2 or absf(float(occupancy[0]) - 12.5) > 0.001 or absf(float(occupancy[1]) - 6.25) > 0.001:
		push_error("Expected static SceneVoxelValidation occupancy 12.5/6.25, got %s" % str(validation))
		return false
	return true


func _test_dirty_tile_limited_source_write() -> bool:
	var committer := SVC.new(32, 32.0)
	committer.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.2, 0.8, 0.2, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var tick := committer.begin_generation_tick(committer.get_generation_tick())
	var record_a := _make_dirty_scope_record("dirty_scope_a", Vector2i(8, 8), 0.4)
	var record_b := _make_dirty_scope_record("dirty_scope_b", Vector2i(24, 24), 0.6)
	committer.apply_voxel_write_spec(record_a, true, tick)
	committer.apply_voxel_write_spec(record_b, true, tick)
	committer.blend_scene_voxels(tick)

	var before_b := committer.get_scene_voxel(0, Vector2i(12, 12))
	if before_b.is_empty() or absf(float(before_b.get("complexity", -1.0)) - 0.6) > 0.001:
		push_error("Expected second source record to commit before dirty-limited update")
		return false

	var next_tick := committer.begin_generation_tick(committer.get_generation_tick())
	var updated_a := record_a.duplicate(true)
	updated_a["complexity"] = 1.0
	updated_a["color"] = Color(0.9, 0.1, 0.1, 1.0)
	committer.apply_voxel_write_spec(updated_a, true, next_tick)
	committer.blend_scene_voxels(next_tick)

	var summary := committer.get_last_blend_scene_voxel_commit_summary()
	if str(summary.get("mode", "")) != "dirty_scene_voxel_tiles":
		push_error("Expected dirty SceneVoxelTile limited source commit, got %s" % str(summary))
		return false
	if bool(summary.get("cpu_fallback", true)):
		push_error("Dirty-limited source commit must not report CPU fallback")
		return false
	if not bool(summary.get("gpu_first", false)):
		push_error("Dirty-limited source commit should mark gpu_first=true")
		return false
	if str(summary.get("runtime_read_source", "")) != "none":
		push_error("Dirty-limited source commit must not claim runtime read authority")
		return false
	if int(summary.get("processed_source_key_count", 0)) >= int(summary.get("total_source_key_count", 0)):
		push_error("Dirty-limited source commit processed the full source key set: %s" % str(summary))
		return false

	var after_a := committer.get_scene_voxel(0, Vector2i(4, 4))
	if after_a.is_empty() or absf(float(after_a.get("complexity", -1.0)) - 1.0) > 0.001:
		push_error("Expected dirty source record to update inside affected SceneVoxelTile")
		return false
	var after_b := committer.get_scene_voxel(0, Vector2i(12, 12))
	if after_b.is_empty() or absf(float(after_b.get("complexity", -1.0)) - 0.6) > 0.001:
		push_error("Expected untouched SceneVoxelTile source record to remain stable")
		return false

	committer.dispose(true)
	return true


func _make_dirty_scope_record(record_id: String, base_pixel: Vector2i, complexity: float) -> Dictionary:
	return {
		"id": record_id,
		"type": "rock",
		"source_voxel_type": "AutoSceneVoxel",
		"position": Vector3.ZERO,
		"base_pixel": base_pixel,
		"voxel_xz": base_pixel,
		"volume_xz_resolution": 32,
		"scale": Vector3.ONE,
		"color": Color(0.4, 0.4, 0.4, complexity),
		"complexity": complexity,
		"collision": [{
			"shape": "cylinder",
			"radius": 0.5,
			"y_min": 0.0,
			"y_max": 1.0,
			"collision_strength": 1.0,
		}],
		"channel": 0,
		"radius": 1.0,
	}
