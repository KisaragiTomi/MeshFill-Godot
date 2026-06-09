extends SceneTree

const SVC := preload("res://scripts/scene_voxel_committer.gd")

var _gpu_skip_count := 0


func _init() -> void:
	var ok := true
	ok = ok and _test_sv_control_snapshot_from_commit()
	ok = ok and _test_sv_dirty_rect_invalidation()
	ok = ok and _test_scene_voxel_tile_named_api()
	ok = ok and _test_mark_all_scene_voxel_tiles_dirty()
	ok = ok and _test_full_rebuild_marks_all_scene_voxel_tiles_dirty()
	ok = ok and _test_terrain_base_collision_marks_full_scene_voxel_tile_dirty()
	ok = ok and _test_scene_voxel_tile_gpu_buffers_or_skip()
	ok = ok and _test_scene_voxel_tile_dirty_range_gpu_upload_or_skip()
	ok = ok and _test_scene_voxel_tile_resident_gpu_field_update_or_skip()
	ok = ok and _test_scene_voxel_tile_auto_upload_or_skip()
	ok = ok and _test_committer_import_filter_pipeline_rids_or_skip()
	ok = ok and _test_scene_voxel_tile_project_setting_size()
	ok = ok and _test_gpu_autoobject_dirty_delta_tile_refs()
	ok = ok and _test_gpu_autoobject_dirty_delta_batch_tile_refs()
	ok = ok and _test_gpu_autoobject_object_ref_pending_shader_contract()
	ok = ok and _test_gpu_autoobject_object_ref_update_pass_or_skip()
	ok = ok and _test_clear_sv_dirty()

	if ok:
		if _gpu_skip_count > 0:
			print("[VoxelDirtyTile] TESTS PASSED WITH %d GPU SKIPS" % _gpu_skip_count)
		else:
			print("[VoxelDirtyTile] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[VoxelDirtyTile] SOME TESTS FAILED")
		quit(1)


func _record_gpu_skip(label: String, reason: String) -> void:
	_gpu_skip_count += 1
	print("  SKIP: %s (%s)" % [label, reason])


func _test_sv_control_snapshot_from_commit() -> bool:
	print("[VoxelDirtyTile] test_sv_control_snapshot_from_commit...")
	var committer := _make_committer_with_voxel()
	var sv := committer.get_sv()

	if str(sv.get("type", "")) != "SV":
		push_error("  FAIL: expected SV resident view")
		return false
	if int(sv.get("tile_count", 0)) <= 0:
		push_error("  FAIL: expected committed SV tiles")
		return false
	if int(sv.get("dirty_tile_count", 0)) <= 0:
		push_error("  FAIL: expected dirty tiles from committed writes")
		return false
	if bool(sv.get("cpu_fallback", true)):
		push_error("  FAIL: SV control snapshot must not advertise CPU runtime fallback")
		return false
	if str(sv.get("runtime_read_source", "")) != "none":
		push_error("  FAIL: SV control snapshot must not claim runtime read authority")
		return false
	var gpu_summary: Dictionary = sv.get("scene_voxel_tile_gpu_buffer_summary", {})
	if bool(gpu_summary.get("runtime_ready", true)):
		push_error("  FAIL: SV control snapshot must not imply GPU runtime upload before explicit upload")
		return false
	if bool(gpu_summary.get("cpu_fallback", true)):
		push_error("  FAIL: non-uploaded GPU summary must keep cpu_fallback=false")
		return false
	if str(gpu_summary.get("runtime_read_source", "")) != "none":
		push_error("  FAIL: non-uploaded GPU summary must expose runtime_read_source=none")
		return false

	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var expected_count := grid_size.x * grid_size.y * grid_size.z
	var complexity_field: PackedFloat32Array = sv.get("complexity_field", PackedFloat32Array())
	var collision_field: PackedFloat32Array = sv.get("collision_field", PackedFloat32Array())
	var complexity_field_resident := _sv_complexity_field_is_resident(sv)
	var collision_field_resident := _sv_collision_field_is_resident(sv)
	var resident_field_summary_required := complexity_field_resident or collision_field_resident

	if complexity_field.is_empty() and not complexity_field_resident:
		push_error("  FAIL: CPU complexity_field snapshot is empty without resident GPU field metadata")
		return false
	if collision_field.is_empty() and not collision_field_resident:
		push_error("  FAIL: CPU collision_field snapshot is empty without resident GPU field metadata")
		return false
	if not complexity_field.is_empty() and complexity_field.size() != expected_count:
		push_error("  FAIL: CPU complexity_field snapshot has unexpected size")
		return false
	if not collision_field.is_empty() and collision_field.size() != expected_count:
		push_error("  FAIL: CPU collision_field snapshot has unexpected size")
		return false

	var complexity_max := 0.0
	var collision_max := 0.0
	for value in complexity_field:
		complexity_max = maxf(complexity_max, value)
	for value in collision_field:
		collision_max = maxf(collision_max, value)
	if not complexity_field.is_empty() and complexity_max <= 0.01:
		push_error("  FAIL: expected non-empty CPU complexity_field snapshot")
		return false
	if not collision_field.is_empty() and collision_max <= 0.01:
		push_error("  FAIL: expected non-empty CPU collision_field snapshot")
		return false
	if resident_field_summary_required and not _assert_scene_voxel_tile_resident_field_summary(
		committer,
		expected_count,
		"SV control snapshot"
	):
		return false

	print("  OK: control snapshot tiles=%d voxels=%d complexity_max=%.2f collision_max=%.2f" % [
		int(sv.get("tile_count", 0)),
		expected_count,
		complexity_max,
		collision_max,
	])
	return true


func _test_sv_dirty_rect_invalidation() -> bool:
	print("[VoxelDirtyTile] test_sv_dirty_rect_invalidation...")
	var committer := _make_committer_with_voxel()
	committer.clear_sv_dirty()
	committer.invalidate_sv_rect(Rect2i(Vector2i(12, 12), Vector2i(8, 8)), [0], true)
	if committer.get_sv_dirty_tiles().is_empty():
		push_error("  FAIL: expected dirty tiles after explicit SV rect invalidation")
		return false
	var scene_voxel_tiles := committer.get_dirty_scene_voxel_tiles()
	if scene_voxel_tiles.is_empty():
		push_error("  FAIL: legacy SV rect invalidation should also populate named SceneVoxelTile sidecar")
		return false
	var first_tile: Dictionary = scene_voxel_tiles.values()[0]
	var dirty_flags: Dictionary = first_tile.get("dirty_flags", {})
	if not bool(dirty_flags.get("scene", false)) or not bool(dirty_flags.get("collision", false)):
		push_error("  FAIL: legacy SV rect invalidation should bridge scene/collision dirty flags")
		return false
	var sv := committer.get_sv()
	if int(sv.get("dirty_tile_count", 0)) <= 0:
		push_error("  FAIL: expected SV rebuild to report invalidated dirty tiles")
		return false
	print("  OK: invalidated dirty_tiles=%d" % int(sv.get("dirty_tile_count", 0)))
	return true


func _test_scene_voxel_tile_named_api() -> bool:
	print("[VoxelDirtyTile] test_scene_voxel_tile_named_api...")
	var committer := _make_committer_with_voxel()
	committer.clear_sv_dirty()
	committer.mark_scene_voxel_tile_bounds_dirty(
		Vector3i(8, 0, 8),
		Vector3i(17, 1, 17),
		{"scene": true, "collision": true, "object_refs": true}
	)
	var dirty_tiles := committer.get_dirty_scene_voxel_tiles()
	if dirty_tiles.is_empty():
		push_error("  FAIL: expected named SceneVoxelTile dirty sidecar")
		return false
	if dirty_tiles.size() != 4:
		push_error("  FAIL: expected voxel bounds to map to 4 SceneVoxelTiles, got %d" % dirty_tiles.size())
		return false
	for expected_id in ["2:0:2", "3:0:2", "2:0:3", "3:0:3"]:
		if not dirty_tiles.has(expected_id):
			push_error("  FAIL: missing expected SceneVoxelTile id %s from bounds mapping" % expected_id)
			return false
	var mapped_tile: Dictionary = dirty_tiles.get("2:0:2", {})
	if mapped_tile.get("voxel_min", Vector3i.ZERO) != Vector3i(8, 0, 8):
		push_error("  FAIL: SceneVoxelTile voxel_min did not match tile bounds")
		return false
	if mapped_tile.get("voxel_max", Vector3i.ZERO) != Vector3i(12, 1, 12):
		push_error("  FAIL: SceneVoxelTile voxel_max did not match clipped tile bounds")
		return false
	if mapped_tile.get("base_rect", Rect2i()) != Rect2i(Vector2i(8, 8), Vector2i(4, 4)):
		push_error("  FAIL: SceneVoxelTile base_rect did not match XZ projection")
		return false
	if int(mapped_tile.get("epoch", 0)) <= 0:
		push_error("  FAIL: SceneVoxelTile dirty epoch should increment")
		return false
	var legacy_tiles := committer.get_sv_dirty_tiles()
	if legacy_tiles.is_empty():
		push_error("  FAIL: named SceneVoxelTile API should bridge to legacy dirty tiles")
		return false
	var first_tile: Dictionary = dirty_tiles.values()[0]
	if not first_tile.has("scene_voxel_tile_id") or not first_tile.has("tile_coord"):
		push_error("  FAIL: SceneVoxelTile record missing identity fields")
		return false
	var dirty_flags: Dictionary = first_tile.get("dirty_flags", {})
	if not bool(dirty_flags.get("scene", false)) or not bool(dirty_flags.get("collision", false)):
		push_error("  FAIL: SceneVoxelTile dirty flags did not preserve scene/collision")
		return false
	committer.mark_scene_voxel_tile_dirty(
		Vector3i(2, 0, 2),
		{"scene": true, "object_refs": true},
		{"id": "named_priority_source", "source_id": "named_priority_source"}
	)
	committer.invalidate_sv_tile(0, Vector2i(8, 8), "collision")
	var mixed_tile: Dictionary = committer.get_dirty_scene_voxel_tiles().get("2:0:2", {})
	var mixed_flags: Dictionary = mixed_tile.get("dirty_flags", {})
	if not bool(mixed_flags.get("scene", false)) \
	   or not bool(mixed_flags.get("collision", false)) \
	   or not bool(mixed_flags.get("object_refs", false)):
		push_error("  FAIL: legacy invalidation should merge into named SceneVoxelTile flags")
		return false
	var tile_size: Vector3i = first_tile.get("tile_size", Vector3i.ZERO)
	if tile_size != Vector3i(4, 4, 4):
		push_error("  FAIL: expected default SceneVoxelTile size 4x4x4 voxels, got %s" % str(tile_size))
		return false
	var sv := committer.get_sv()
	if int(sv.get("dirty_scene_voxel_tile_count", 0)) <= 0:
		push_error("  FAIL: SV snapshot should report dirty SceneVoxelTiles")
		return false
	if (sv.get("dirty_scene_voxel_tiles", {}) as Dictionary).is_empty():
		push_error("  FAIL: SV snapshot should retain dirty SceneVoxelTile snapshot for upload")
		return false
	if not committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("  FAIL: SceneVoxelTile dirty flags should clear after SV snapshot publish")
		return false
	var scene_tiles: Dictionary = sv.get("scene_voxel_tiles", {})
	if scene_tiles.is_empty():
		push_error("  FAIL: SV snapshot should keep SceneVoxelTile sidecar")
		return false
	var object_ids: Array = sv.get("scene_voxel_tile_object_ids_debug", [])
	if not object_ids.has("dirty_sv_rock_0"):
		push_error("  FAIL: compact SceneVoxelTile object debug range missing source record id")
		return false
	var found_fixed_range := false
	var scene_tile_ids := scene_tiles.keys()
	scene_tile_ids.sort()
	for raw_tile_id in scene_tile_ids:
		var tile_id := str(raw_tile_id)
		var raw_tile = scene_tiles.get(tile_id, {})
		if not raw_tile is Dictionary:
			continue
		var tile: Dictionary = raw_tile
		var object_count := int(tile.get("object_range_count", 0))
		if object_count <= 0:
			continue
		var object_start := int(tile.get("object_range_start", -1))
		var tile_coord: Vector3i = tile.get("tile_coord", Vector3i.ZERO)
		var tile_grid := _scene_voxel_tile_grid_for(committer.grid_size, tile_size)
		var expected_object_start := _scene_voxel_tile_flattened_index(tile_coord, tile_grid) * SVC.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
		if object_start != expected_object_start:
			push_error("  FAIL: SceneVoxelTile object range should use flattened fixed slots, got %d expected %d" % [object_start, expected_object_start])
			return false
		if object_count > SVC.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT:
			push_error("  FAIL: SceneVoxelTile object range count exceeded fixed per-tile capacity")
			return false
		var object_debug_start := int(tile.get("object_debug_range_start", -1))
		var object_debug_count := int(tile.get("object_debug_range_count", -1))
		if object_debug_start < 0 or object_debug_start + object_debug_count > object_ids.size():
			push_error("  FAIL: SceneVoxelTile compact object debug range outside debug buffer")
			return false
		found_fixed_range = true
		break
	if not found_fixed_range:
		push_error("  FAIL: expected at least one fixed SceneVoxelTile object range")
		return false
	var found_summary := false
	for raw_tile in scene_tiles.values():
		if not raw_tile is Dictionary:
			continue
		var tile: Dictionary = raw_tile
		var summary: Dictionary = tile.get("summary", {})
		if (int(summary.get("scene_voxel_count", 0)) > 0 or int(summary.get("collision_cell_count", 0)) > 0) and int(summary.get("scene_voxel_count", 0)) > 0:
			var minmax: Vector2 = summary.get("scene_minmax", Vector2.ZERO)
			if minmax.y <= 0.01:
				push_error("  FAIL: SceneVoxelTile summary should publish scene complexity min/max")
				return false
			found_summary = true
			break
	if not found_summary:
		push_error("  FAIL: expected SceneVoxelTile summary for committed scene voxels")
		return false
	print("  OK: named SceneVoxelTile API bridged to dirty_tiles=%d scene_voxel_tiles=%d" % [
		legacy_tiles.size(),
		scene_tiles.size(),
	])
	return true


func _test_mark_all_scene_voxel_tiles_dirty() -> bool:
	print("[VoxelDirtyTile] test_mark_all_scene_voxel_tiles_dirty...")
	var committer := _make_committer_with_voxel()
	committer.clear_sv_dirty()

	var result := committer.mark_all_scene_voxel_tiles_dirty(
		{"scene": true, "collision": true, "routing": true},
		{"id": "maintenance_full_rebuild", "source_id": "maintenance_full_rebuild"}
	)
	var tile_grid: Vector3i = result.get("tile_grid_size", Vector3i.ZERO)
	var expected_count := tile_grid.x * tile_grid.y * tile_grid.z
	if expected_count <= 0:
		push_error("  FAIL: full dirty tile grid should be non-empty")
		return false
	if int(result.get("tile_count", -1)) != expected_count:
		push_error("  FAIL: full dirty API returned wrong tile_count")
		return false

	var dirty_tiles := committer.get_dirty_scene_voxel_tiles()
	if dirty_tiles.size() != expected_count:
		push_error("  FAIL: expected %d dirty SceneVoxelTiles, got %d" % [expected_count, dirty_tiles.size()])
		return false
	if int(result.get("dirty_scene_voxel_tile_count", -1)) != expected_count:
		push_error("  FAIL: full dirty API returned wrong dirty_scene_voxel_tile_count")
		return false
	if committer.get_sv_dirty_tiles().is_empty():
		push_error("  FAIL: full dirty SceneVoxelTile API should still bridge legacy dirty storage")
		return false

	var coverage_min := Vector3i(999999, 999999, 999999)
	var coverage_max := Vector3i.ZERO
	for raw_tile in dirty_tiles.values():
		if not raw_tile is Dictionary:
			push_error("  FAIL: dirty SceneVoxelTile snapshot contained a non-dictionary tile")
			return false
		var tile: Dictionary = raw_tile
		var flags: Dictionary = tile.get("dirty_flags", {})
		if not bool(flags.get("scene", false)) or not bool(flags.get("collision", false)) or not bool(flags.get("routing", false)):
			push_error("  FAIL: full dirty SceneVoxelTile flags were not preserved")
			return false
		if not bool(tile.get("dirty", false)) or not bool(tile.get("updated_this_commit", false)):
			push_error("  FAIL: full dirty SceneVoxelTile did not set dirty/update markers")
			return false
		var voxel_min: Vector3i = tile.get("voxel_min", Vector3i.ZERO)
		var voxel_max: Vector3i = tile.get("voxel_max", Vector3i.ZERO)
		coverage_min = Vector3i(
			mini(coverage_min.x, voxel_min.x),
			mini(coverage_min.y, voxel_min.y),
			mini(coverage_min.z, voxel_min.z)
		)
		coverage_max = Vector3i(
			maxi(coverage_max.x, voxel_max.x),
			maxi(coverage_max.y, voxel_max.y),
			maxi(coverage_max.z, voxel_max.z)
		)

	if coverage_min != Vector3i.ZERO or coverage_max != committer.grid_size:
		push_error("  FAIL: full dirty SceneVoxelTile coverage was %s..%s, expected %s..%s" % [
			str(coverage_min),
			str(coverage_max),
			str(Vector3i.ZERO),
			str(committer.grid_size),
		])
		return false

	var origin_tile: Dictionary = dirty_tiles.get("0:0:0", {})
	var edge_id := "%d:%d:%d" % [tile_grid.x - 1, tile_grid.y - 1, tile_grid.z - 1]
	var edge_tile: Dictionary = dirty_tiles.get(edge_id, {})
	if origin_tile.get("voxel_min", Vector3i.ONE) != Vector3i.ZERO:
		push_error("  FAIL: full dirty origin tile bounds should start at grid origin")
		return false
	if edge_tile.get("voxel_max", Vector3i.ZERO) != committer.grid_size:
		push_error("  FAIL: full dirty edge tile bounds should clip to grid_size")
		return false

	var sv := committer.get_sv()
	if int(sv.get("dirty_scene_voxel_tile_count", -1)) != expected_count:
		push_error("  FAIL: SV publish should report full dirty SceneVoxelTile count")
		return false
	var published_dirty: Dictionary = sv.get("dirty_scene_voxel_tiles", {})
	if published_dirty.size() != expected_count:
		push_error("  FAIL: SV publish should retain full dirty SceneVoxelTile snapshot")
		return false
	if not committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("  FAIL: SceneVoxelTile dirty state should clear after SV publish")
		return false

	committer.mark_all_scene_voxel_tiles_dirty(
		{"scene": true, "collision": true},
		{"id": "maintenance_full_rebuild_clear", "source_id": "maintenance_full_rebuild_clear"}
	)
	committer.clear_sv_dirty()
	if not committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("  FAIL: clear_sv_dirty should clear full dirty SceneVoxelTile state")
		return false
	if not committer.get_sv_dirty_tiles().is_empty():
		push_error("  FAIL: clear_sv_dirty should clear legacy dirty storage after full dirty")
		return false
	var cleared_sv := committer.get_sv()
	if int(cleared_sv.get("dirty_scene_voxel_tile_count", -1)) != 0:
		push_error("  FAIL: cleared SV should report dirty_scene_voxel_tile_count=0")
		return false
	if int(cleared_sv.get("dirty_tile_count", -1)) != 0:
		push_error("  FAIL: cleared SV should report dirty_tile_count=0")
		return false

	print("  OK: full dirty tiles=%d coverage=%s..%s" % [
		expected_count,
		str(coverage_min),
		str(coverage_max),
	])
	return true


func _test_full_rebuild_marks_all_scene_voxel_tiles_dirty() -> bool:
	print("[VoxelDirtyTile] test_full_rebuild_marks_all_scene_voxel_tiles_dirty...")
	var committer := _make_committer_with_voxel()
	var sv := committer.get_sv()
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var tile_size: Vector3i = sv.get("scene_voxel_tile_size", SVC.DEFAULT_SCENE_VOXEL_TILE_SIZE)
	var tile_grid := _scene_voxel_tile_grid_for(grid_size, tile_size)
	var expected_count := tile_grid.x * tile_grid.y * tile_grid.z
	var dirty_tiles: Dictionary = sv.get("dirty_scene_voxel_tiles", {})
	if int(sv.get("dirty_scene_voxel_tile_count", -1)) != expected_count:
		push_error("  FAIL: full volume rebuild should publish %d dirty SceneVoxelTiles, got %d" % [
			expected_count,
			int(sv.get("dirty_scene_voxel_tile_count", -1)),
		])
		return false
	if dirty_tiles.size() != expected_count:
		push_error("  FAIL: full volume rebuild dirty snapshot size mismatch")
		return false
	if not _full_dirty_coverage_matches(dirty_tiles, grid_size, tile_grid, "volume rebuild"):
		return false

	committer.clear_sv_dirty()
	_build_default_volume(committer)
	var rebuilt_sv := committer.get_sv()
	var rebuilt_dirty: Dictionary = rebuilt_sv.get("dirty_scene_voxel_tiles", {})
	if rebuilt_dirty.size() != expected_count:
		push_error("  FAIL: repeated full volume rebuild should dirty all SceneVoxelTiles, got %d/%d" % [
			rebuilt_dirty.size(),
			expected_count,
		])
		return false
	if not _full_dirty_coverage_matches(rebuilt_dirty, grid_size, tile_grid, "repeated volume rebuild"):
		return false

	committer.clear_sv_dirty()
	var configured_grid := Vector3i(18, 2, 17)
	committer.configure_scene_voxel_grid(configured_grid, Vector3.ONE, Vector3.ZERO)
	var configured_dirty := committer.get_dirty_scene_voxel_tiles()
	var configured_tile_grid := _scene_voxel_tile_grid_for(configured_grid, tile_size)
	var configured_expected_count := configured_tile_grid.x * configured_tile_grid.y * configured_tile_grid.z
	if configured_dirty.size() != configured_expected_count:
		push_error("  FAIL: grid configure maintenance path should dirty all SceneVoxelTiles, got %d/%d" % [
			configured_dirty.size(),
			configured_expected_count,
		])
		return false
	if not _full_dirty_coverage_matches(configured_dirty, configured_grid, configured_tile_grid, "grid configure"):
		return false

	print("  OK: full rebuild/grid configure dirty all SceneVoxelTiles (%d, %d)" % [
		expected_count,
		configured_expected_count,
	])
	return true


func _test_terrain_base_collision_marks_full_scene_voxel_tile_dirty() -> bool:
	print("[VoxelDirtyTile] test_terrain_base_collision_marks_full_scene_voxel_tile_dirty...")
	var committer := _make_committer_with_voxel()
	var sv := committer.get_sv()
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var tile_size: Vector3i = sv.get("scene_voxel_tile_size", SVC.DEFAULT_SCENE_VOXEL_TILE_SIZE)
	var tile_grid := _scene_voxel_tile_grid_for(grid_size, tile_size)
	var expected_count := tile_grid.x * tile_grid.y * tile_grid.z

	committer.clear_sv_dirty()
	var terrain_collision := Image.create(32, 32, false, Image.FORMAT_RF)
	terrain_collision.fill(Color(1.0, 0.0, 0.0, 0.0))
	committer.set_terrain_base_collision_field(terrain_collision)

	var dirty_tiles := committer.get_dirty_scene_voxel_tiles()
	if dirty_tiles.size() != expected_count:
		push_error("  FAIL: terrain base collision change should dirty all SceneVoxelTiles, got %d/%d" % [
			dirty_tiles.size(),
			expected_count,
		])
		return false
	if committer.get_sv_dirty_tiles().is_empty():
		push_error("  FAIL: terrain base collision full dirty should bridge legacy dirty storage")
		return false
	if not _full_dirty_coverage_matches(dirty_tiles, grid_size, tile_grid, "terrain base collision"):
		return false

	var rebuilt_sv := committer.get_sv()
	var published_dirty: Dictionary = rebuilt_sv.get("dirty_scene_voxel_tiles", {})
	if published_dirty.size() != expected_count:
		push_error("  FAIL: terrain base collision SV publish should retain full dirty snapshot, got %d/%d" % [
			published_dirty.size(),
			expected_count,
		])
		return false
	var collision_field: PackedFloat32Array = rebuilt_sv.get("collision_field", PackedFloat32Array())
	if collision_field.is_empty() or _packed_float_nonzero_count(collision_field) != collision_field.size():
		push_error("  FAIL: terrain base collision resident field should fill every voxel")
		return false
	if not committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("  FAIL: terrain base collision dirty flags should clear after SV publish")
		return false

	print("  OK: terrain base collision dirtied all SceneVoxelTiles and rebuilt resident collision field")
	return true


func _test_scene_voxel_tile_gpu_buffers_or_skip() -> bool:
	print("[VoxelDirtyTile] test_scene_voxel_tile_gpu_buffers_or_skip...")
	var committer := _make_committer_with_voxel()
	committer.clear_sv_dirty()
	committer.mark_scene_voxel_tile_bounds_dirty(
		Vector3i(8, 0, 8),
		Vector3i(17, 1, 17),
		{"scene": true, "collision": true, "object_refs": true},
		{"id": "dirty_sv_rock_0", "source_id": "dirty_sv_rock_0"}
	)
	var dirty_tiles := committer.get_dirty_scene_voxel_tiles()
	if dirty_tiles.is_empty():
		push_error("  FAIL: expected dirty SceneVoxelTiles before GPU upload")
		return false

	if not committer.ensure_scene_voxel_tile_buffers_uploaded(true):
		var skipped_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
		if bool(skipped_summary.get("runtime_ready", true)):
			push_error("  FAIL: failed GPU upload must not report runtime ready")
			return false
		if bool(skipped_summary.get("cpu_fallback", true)):
			push_error("  FAIL: failed GPU upload must not enable CPU fallback")
			return false
		if str(skipped_summary.get("resident_field_read_source", "")) != "none":
			push_error("  FAIL: skipped resident field upload must not report a runtime source")
			return false
		if str(skipped_summary.get("readback_source", "")) != "none":
			push_error("  FAIL: skipped SceneVoxelTile upload must not expose a success readback source")
			return false
		if str(skipped_summary.get("skip_reason", "")) != "no_rendering_device":
			push_error("  FAIL: skipped SceneVoxelTile upload must expose skip_reason=no_rendering_device")
			return false
		_record_gpu_skip("no RenderingDevice for SceneVoxelTile storage buffer upload", str(skipped_summary.get("reason", "")))
		committer.dispose(true)
		return true

	var summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	if not bool(summary.get("runtime_ready", false)):
		push_error("  FAIL: SceneVoxelTile GPU buffer summary should be runtime ready after upload")
		return false
	if str(summary.get("read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: SceneVoxelTile metadata read source should be gpu_storage_buffers")
		return false
	if str(summary.get("runtime_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: SceneVoxelTile runtime read source should be gpu_storage_buffers")
		return false
	if str(summary.get("resident_field_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: SceneVoxelTile scene/collision field source should be GPU resident buffers")
		return false
	if bool(summary.get("cpu_fallback", true)):
		push_error("  FAIL: SceneVoxelTile GPU upload must report cpu_fallback=false")
		return false
	if not bool(summary.get("uploaded_revision_matches_staging", false)):
		push_error("  FAIL: uploaded SceneVoxelTile revision should match staging revision")
		return false
	if bool(summary.get("buffers_stale", true)):
		push_error("  FAIL: freshly uploaded SceneVoxelTile buffers should not be stale")
		return false
	if int(summary.get("tile_count", 0)) <= 0:
		push_error("  FAIL: expected GPU tile record count")
		return false
	if int(summary.get("dirty_tile_count", 0)) != dirty_tiles.size():
		push_error("  FAIL: GPU dirty tile count should match staged dirty tiles, got %d expected %d" % [
			int(summary.get("dirty_tile_count", 0)),
			dirty_tiles.size(),
		])
		return false
	if int(summary.get("resident_field_voxel_count", 0)) <= 0:
		push_error("  FAIL: expected resident scene/collision voxel field count")
		return false

	var uploaded_complexity_field_rid := committer.get_scene_voxel_tile_gpu_buffer(SVC.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER)
	var uploaded_collision_field_rid := committer.get_scene_voxel_tile_gpu_buffer(SVC.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)
	var uploaded_revision := int(summary.get("uploaded_revision", -1))
	committer.mark_scene_voxel_tile_dirty(
		Vector3i(2, 0, 2),
		{"scene": true},
		{"id": "dirty_sv_rock_0", "source_id": "dirty_sv_rock_0"}
	)
	if committer.is_scene_voxel_tile_gpu_ready():
		push_error("  FAIL: mutating SceneVoxelTile staging should stale previous GPU buffers")
		return false
	var stale_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	if not bool(stale_summary.get("buffers_stale", false)):
		push_error("  FAIL: stale SceneVoxelTile summary should mark buffers_stale")
		return false
	if int(stale_summary.get("uploaded_revision", -1)) != uploaded_revision:
		push_error("  FAIL: stale SceneVoxelTile summary should keep previous uploaded revision")
		return false
	if int(stale_summary.get("staging_revision", 0)) <= uploaded_revision:
		push_error("  FAIL: staging revision should advance after SceneVoxelTile mutation")
		return false
	if str(stale_summary.get("runtime_read_source", "")) != "none":
		push_error("  FAIL: stale SceneVoxelTile buffers must not be runtime read source")
		return false
	if str(stale_summary.get("resident_field_read_source", "")) != "none":
		push_error("  FAIL: stale scene/collision field buffers must not be runtime read source")
		return false
	if str(stale_summary.get("readback_source", "")) != "none":
		push_error("  FAIL: stale SceneVoxelTile buffers must not expose a success readback source")
		return false
	var stale_snapshot := committer.readback_scene_voxel_tile_debug_snapshot()
	if bool(stale_snapshot.get("readback_snapshot", true)):
		push_error("  FAIL: stale SceneVoxelTile buffers should not produce a readback snapshot")
		return false
	if not committer.ensure_scene_voxel_tile_buffers_uploaded(true):
		push_error("  FAIL: SceneVoxelTile GPU buffers should re-upload after staging mutation")
		return false
	summary = committer.get_scene_voxel_tile_gpu_buffer_summary()
	if int(summary.get("uploaded_revision", -1)) <= uploaded_revision:
		push_error("  FAIL: SceneVoxelTile GPU upload revision should advance after dirty mutation")
		return false
	if str(summary.get("resident_field_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: re-uploaded scene/collision fields should be GPU resident")
		return false
	if not bool(summary.get("resident_field_buffers_reused", false)):
		push_error("  FAIL: metadata-only SceneVoxelTile upload should reuse resident scene/collision buffers")
		return false
	var reused_buffers: Array = summary.get("last_reused_buffers", [])
	if not reused_buffers.has(SVC.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER) or not reused_buffers.has(SVC.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER):
		push_error("  FAIL: resident field reuse summary missing scene/collision buffer names")
		return false
	if committer.get_scene_voxel_tile_gpu_buffer(SVC.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER) != uploaded_complexity_field_rid:
		push_error("  FAIL: complexity field RID should be preserved when resident field content is unchanged")
		return false
	if committer.get_scene_voxel_tile_gpu_buffer(SVC.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER) != uploaded_collision_field_rid:
		push_error("  FAIL: collision field RID should be preserved when resident field content is unchanged")
		return false

	var buffers: Dictionary = summary.get("buffers", {})
	for buffer_name in SVC.SCENE_VOXEL_TILE_GPU_BUFFER_NAMES:
		var buffer_summary: Dictionary = buffers.get(buffer_name, {})
		if not bool(buffer_summary.get("rid_valid", false)):
			push_error("  FAIL: expected valid SceneVoxelTile GPU buffer RID for %s" % buffer_name)
			return false
	var expected_field_count := int(summary.get("resident_field_voxel_count", 0))
	var expected_object_ref_slots := int(summary.get("tile_count", 0)) * SVC.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
	var object_ref_buffer: Dictionary = buffers.get(SVC.SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, {})
	if int(object_ref_buffer.get("record_count", -1)) != expected_object_ref_slots:
		push_error("  FAIL: object-ref GPU buffer should allocate fixed per-tile slots")
		return false
	if int(summary.get("object_ref_capacity", -1)) != expected_object_ref_slots:
		push_error("  FAIL: object-ref summary capacity should match fixed slot count")
		return false
	var complexity_field_buffer: Dictionary = buffers.get(SVC.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER, {})
	var collision_field_buffer: Dictionary = buffers.get(SVC.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER, {})
	if not bool(complexity_field_buffer.get("reused_last_upload", false)) or not bool(collision_field_buffer.get("reused_last_upload", false)):
		push_error("  FAIL: scene/collision field buffer summaries should report metadata-only reuse")
		return false
	if int(complexity_field_buffer.get("record_count", -1)) != expected_field_count:
		push_error("  FAIL: complexity field GPU record count mismatch")
		return false
	if int(collision_field_buffer.get("record_count", -1)) != expected_field_count:
		push_error("  FAIL: collision field GPU record count mismatch")
		return false
	if int(complexity_field_buffer.get("logical_byte_size", -1)) != expected_field_count * SVC.SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES:
		push_error("  FAIL: complexity field GPU logical byte size mismatch")
		return false
	if int(collision_field_buffer.get("logical_byte_size", -1)) != expected_field_count * SVC.SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES:
		push_error("  FAIL: collision field GPU logical byte size mismatch")
		return false

	var snapshot := committer.readback_scene_voxel_tile_debug_snapshot()
	if not bool(snapshot.get("readback_snapshot", false)):
		push_error("  FAIL: SceneVoxelTile debug snapshot should be GPU readback")
		return false
	var tile_bytes: PackedByteArray = snapshot.get("tile_record_bytes", PackedByteArray())
	var summary_bytes: PackedByteArray = snapshot.get("summary_record_bytes", PackedByteArray())
	var dirty_bytes: PackedByteArray = snapshot.get("dirty_index_bytes", PackedByteArray())
	var object_ref_bytes: PackedByteArray = snapshot.get("object_ref_bytes", PackedByteArray())
	var complexity_field_bytes: PackedByteArray = snapshot.get("complexity_field_bytes", PackedByteArray())
	var collision_field_bytes: PackedByteArray = snapshot.get("collision_field_bytes", PackedByteArray())
	var complexity_field_values: PackedFloat32Array = snapshot.get("complexity_field_values", PackedFloat32Array())
	var collision_field_values: PackedFloat32Array = snapshot.get("collision_field_values", PackedFloat32Array())
	if tile_bytes.size() != int(summary.get("tile_count", 0)) * SVC.SCENE_VOXEL_TILE_RECORD_STRIDE_BYTES:
		push_error("  FAIL: tile record byte size mismatch")
		return false
	if summary_bytes.size() != int(summary.get("tile_count", 0)) * SVC.SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES:
		push_error("  FAIL: summary record byte size mismatch")
		return false
	if dirty_bytes.size() != dirty_tiles.size() * SVC.SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES:
		push_error("  FAIL: dirty index byte size mismatch")
		return false
	if object_ref_bytes.size() != expected_object_ref_slots * SVC.SCENE_VOXEL_TILE_REF_STRIDE_BYTES:
		push_error("  FAIL: fixed object-ref byte size mismatch")
		return false
	if complexity_field_bytes.size() != expected_field_count * SVC.SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES:
		push_error("  FAIL: complexity field byte size mismatch")
		return false
	if collision_field_bytes.size() != expected_field_count * SVC.SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES:
		push_error("  FAIL: collision field byte size mismatch")
		return false
	if complexity_field_values.size() != expected_field_count or collision_field_values.size() != expected_field_count:
		push_error("  FAIL: decoded scene/collision field size mismatch")
		return false
	if _packed_float_max(complexity_field_values) <= 0.01 or _packed_float_max(collision_field_values) <= 0.01:
		push_error("  FAIL: expected non-empty scene/collision field values from GPU readback")
		return false
	var dirty_ids: Array = snapshot.get("dirty_tile_ids", [])
	for expected_id in ["2:0:2", "3:0:2", "2:0:3", "3:0:3"]:
		if not dirty_ids.has(expected_id):
			push_error("  FAIL: GPU dirty index readback missing tile %s" % expected_id)
			return false

	var records: Array = snapshot.get("tile_records", [])
	var found_dirty_record := false
	for raw_record in records:
		if not raw_record is Dictionary:
			continue
		var record: Dictionary = raw_record
		if str(record.get("scene_voxel_tile_id", "")) != "2:0:2":
			continue
		var flags: Dictionary = record.get("dirty_flags", {})
		if not bool(flags.get("scene", false)) or not bool(flags.get("collision", false)) or not bool(flags.get("object_refs", false)):
			push_error("  FAIL: GPU tile record should preserve dirty flags")
			return false
		if record.get("voxel_min", Vector3i.ZERO) != Vector3i(8, 0, 8):
			push_error("  FAIL: GPU tile record voxel_min readback mismatch")
			return false
		var tile_ids: Array = snapshot.get("tile_ids", [])
		var tile_index := tile_ids.find("2:0:2")
		var expected_object_start := tile_index * SVC.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
		if int(record.get("object_range_start", -1)) != expected_object_start:
			push_error("  FAIL: GPU tile record object range start should use fixed slots")
			return false
		if int(record.get("object_range_count", -1)) <= 0 or int(record.get("object_range_count", -1)) > SVC.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT:
			push_error("  FAIL: GPU tile record object range count should fit fixed slots")
			return false
		var object_ref_offset := expected_object_start * SVC.SCENE_VOXEL_TILE_REF_STRIDE_BYTES
		if object_ref_offset < 0 or object_ref_offset >= object_ref_bytes.size() or object_ref_bytes.decode_u32(object_ref_offset) == 0:
			push_error("  FAIL: fixed object-ref slot should contain a packed debug ref hash")
			return false
		found_dirty_record = true
		break
	if not found_dirty_record:
		push_error("  FAIL: expected decoded GPU tile record for dirty tile")
		return false

	var summaries: Array = snapshot.get("summary_records", [])
	var found_non_empty_summary := false
	for raw_summary in summaries:
		if raw_summary is Dictionary:
			var s: Dictionary = raw_summary as Dictionary
			if int(s.get("scene_voxel_count", 0)) > 0 or int(s.get("collision_cell_count", 0)) > 0:
				found_non_empty_summary = true
				break
	if not found_non_empty_summary:
		push_error("  FAIL: expected non-empty SceneVoxelTile summary in GPU readback")
		return false

	committer.clear_sv_dirty()
	var staged_after_clear := committer.get_dirty_scene_voxel_tiles()
	if not staged_after_clear.is_empty():
		push_error("  FAIL: staged dirty tiles should clear before GPU re-upload, got %s" % str(staged_after_clear.keys()))
		return false
	if committer.is_scene_voxel_tile_gpu_ready():
		push_error("  FAIL: clearing dirty flags should stale previous SceneVoxelTile GPU buffers")
		return false
	if not committer.ensure_scene_voxel_tile_buffers_uploaded(true):
		push_error("  FAIL: SceneVoxelTile GPU buffers should re-upload after dirty clear")
		return false
	var cleared_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	if str(cleared_summary.get("resident_field_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: cleared SceneVoxelTile fields should remain GPU resident")
		return false
	if not bool(cleared_summary.get("resident_field_buffers_reused", false)):
		push_error("  FAIL: clearing dirty flags should reuse unchanged resident scene/collision buffers")
		return false
	var cleared_buffers: Dictionary = cleared_summary.get("buffers", {})
	var cleared_dirty_buffer: Dictionary = cleared_buffers.get(SVC.SCENE_VOXEL_TILE_DIRTY_INDEX_BUFFER, {})
	if int(cleared_dirty_buffer.get("record_count", -1)) != 0:
		push_error("  FAIL: dirty index buffer record_count should be zero after clear")
		return false
	if int(cleared_dirty_buffer.get("logical_byte_size", -1)) != 0:
		push_error("  FAIL: dirty index logical byte size should be zero after clear")
		return false
	if int(cleared_dirty_buffer.get("upload_byte_size", 0)) < 4:
		push_error("  FAIL: empty dirty index buffer should still allocate only padded GPU bytes")
		return false
	var cleared_snapshot := committer.readback_scene_voxel_tile_debug_snapshot()
	var cleared_dirty_ids: Array = cleared_snapshot.get("dirty_tile_ids", [])
	if not cleared_dirty_ids.is_empty():
		push_error("  FAIL: dirty index readback should clear after clear_sv_dirty upload, got %s" % str(cleared_dirty_ids))
		return false

	committer.dispose(true)
	print("  OK: SceneVoxelTile metadata and resident fields uploaded/read back from GPU storage buffers")
	return true


func _test_scene_voxel_tile_dirty_range_gpu_upload_or_skip() -> bool:
	print("[VoxelDirtyTile] test_scene_voxel_tile_dirty_range_gpu_upload_or_skip...")
	var committer := _make_committer_with_voxel()
	var initial_sv := committer.get_sv()
	if not committer.ensure_scene_voxel_tile_buffers_uploaded(true):
		var skipped_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
		if bool(skipped_summary.get("runtime_ready", true)):
			push_error("  FAIL: skipped dirty range upload must not report runtime ready")
			return false
		if bool(skipped_summary.get("cpu_fallback", true)):
			push_error("  FAIL: skipped dirty range upload must not enable CPU fallback")
			return false
		if str(skipped_summary.get("runtime_read_source", "none")) != "none":
			push_error("  FAIL: skipped dirty range upload must not expose runtime_read_source")
			return false
		if str(skipped_summary.get("resident_field_read_source", "")) != "none":
			push_error("  FAIL: skipped dirty range upload must not report resident field runtime source")
			return false
		if str(skipped_summary.get("readback_source", "")) != "none":
			push_error("  FAIL: skipped dirty range upload must not expose a success readback source")
			return false
		if str(skipped_summary.get("skip_reason", "")) != "no_rendering_device":
			push_error("  FAIL: skipped dirty range upload must expose skip_reason=no_rendering_device")
			return false
		_record_gpu_skip("no RenderingDevice for dirty range SceneVoxelTile upload", str(skipped_summary.get("reason", "")))
		committer.dispose(true)
		return true

	var initial_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	var full_tile_count := int(initial_summary.get("tile_count", 0))
	var full_field_count := int(initial_summary.get("resident_field_voxel_count", 0))
	var uploaded_complexity_field_rid := committer.get_scene_voxel_tile_gpu_buffer(SVC.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER)
	var uploaded_collision_field_rid := committer.get_scene_voxel_tile_gpu_buffer(SVC.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)
	var scene_voxel_tiles: Dictionary = initial_sv.get("scene_voxel_tiles", {})
	var selected_tile_id := ""
	var selected_tile_coord := Vector3i.ZERO
	for raw_tile_id in scene_voxel_tiles.keys():
		var tile: Dictionary = scene_voxel_tiles.get(raw_tile_id, {})
		if int(tile.get("scene_voxel_count", 0)) <= 0 and int(tile.get("collision_cell_count", 0)) <= 0:
			continue
		selected_tile_id = str(raw_tile_id)
		selected_tile_coord = tile.get("tile_coord", Vector3i.ZERO)
		break
	if selected_tile_id.is_empty():
		push_error("  FAIL: expected an existing SceneVoxelTile to dirty for range upload")
		return false

	committer.mark_scene_voxel_tile_dirty(
		selected_tile_coord,
		{"scene": true, "collision": true},
		{"id": "dirty_sv_rock_0", "source_id": "dirty_sv_rock_0"}
	)
	var dirty_before_publish := committer.get_dirty_scene_voxel_tiles()
	if dirty_before_publish.size() != 1 or not dirty_before_publish.has(selected_tile_id):
		push_error("  FAIL: expected exactly one pending dirty SceneVoxelTile before publish")
		return false
	var published_sv := committer.get_sv()
	if int(published_sv.get("dirty_scene_voxel_tile_count", -1)) != 1:
		push_error("  FAIL: SV publish should retain one dirty SceneVoxelTile snapshot")
		return false
	if not committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("  FAIL: SceneVoxelTile dirty flags should clear after publish")
		return false
	if committer.is_scene_voxel_tile_gpu_ready():
		push_error("  FAIL: clean post-publish metadata should stale previous GPU buffers until upload")
		return false
	if not committer.ensure_scene_voxel_tile_buffers_uploaded(false):
		push_error("  FAIL: clean post-publish dirty range upload should succeed")
		return false

	var range_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	if str(range_summary.get("last_upload_mode", "")) != "dirty_scene_voxel_tile_ranges":
		push_error("  FAIL: expected dirty range upload mode, got %s" % str(range_summary.get("last_upload_mode", "")))
		return false
	var last_upload_ids: Array = range_summary.get("last_upload_tile_ids", [])
	if int(range_summary.get("last_upload_tile_count", -1)) != 1 or not last_upload_ids.has(selected_tile_id):
		push_error("  FAIL: dirty range upload should report only %s, got %s" % [selected_tile_id, str(last_upload_ids)])
		return false
	if int(range_summary.get("last_upload_resident_voxel_count", 0)) <= 0 or int(range_summary.get("last_upload_resident_voxel_count", 0)) >= full_field_count:
		push_error("  FAIL: dirty range resident upload count should be smaller than full field")
		return false
	if int(range_summary.get("last_upload_range_count", 0)) <= 0:
		push_error("  FAIL: dirty range upload should report row range count")
		return false
	if int(range_summary.get("tile_count", 0)) != full_tile_count:
		push_error("  FAIL: dirty range upload should preserve tile record count")
		return false
	if int(range_summary.get("dirty_tile_count", -1)) != 0:
		push_error("  FAIL: clean post-publish dirty index should upload as empty")
		return false
	if str(range_summary.get("resident_field_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: dirty range upload should keep resident fields GPU-backed")
		return false
	if committer.get_scene_voxel_tile_gpu_buffer(SVC.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER) != uploaded_complexity_field_rid:
		push_error("  FAIL: dirty range upload should update complexity field buffer in place")
		return false
	if committer.get_scene_voxel_tile_gpu_buffer(SVC.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER) != uploaded_collision_field_rid:
		push_error("  FAIL: dirty range upload should update collision field buffer in place")
		return false
	var range_snapshot := committer.readback_scene_voxel_tile_debug_snapshot()
	var dirty_ids: Array = range_snapshot.get("dirty_tile_ids", [])
	if not dirty_ids.is_empty():
		push_error("  FAIL: dirty range readback should have empty dirty index after clean publish")
		return false

	committer.dispose(true)
	print("  OK: clean post-publish metadata uploaded one dirty SceneVoxelTile range")
	return true


func _test_scene_voxel_tile_resident_gpu_field_update_or_skip() -> bool:
	print("[VoxelDirtyTile] test_scene_voxel_tile_resident_gpu_field_update_or_skip...")
	var committer := _make_committer_with_voxel()
	if not committer.ensure_scene_voxel_tile_buffers_uploaded(true):
		var skipped_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
		if bool(skipped_summary.get("runtime_ready", true)):
			push_error("  FAIL: skipped resident field upload must not report runtime ready")
			return false
		if bool(skipped_summary.get("cpu_fallback", true)):
			push_error("  FAIL: skipped resident field upload must not enable CPU fallback")
			return false
		if str(skipped_summary.get("runtime_read_source", "none")) != "none":
			push_error("  FAIL: skipped resident field upload must not expose runtime_read_source")
			return false
		if str(skipped_summary.get("resident_field_read_source", "")) != "none":
			push_error("  FAIL: skipped resident field upload must not report resident field runtime source")
			return false
		if str(skipped_summary.get("readback_source", "")) != "none":
			push_error("  FAIL: skipped resident field upload must not expose a success readback source")
			return false
		if str(skipped_summary.get("skip_reason", "")) != "no_rendering_device":
			push_error("  FAIL: skipped resident field upload must expose skip_reason=no_rendering_device")
			return false
		_record_gpu_skip("no RenderingDevice for resident scene/collision field upload", str(skipped_summary.get("reason", "")))
		committer.dispose(true)
		return true

	var previous_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	var previous_revision := int(previous_summary.get("uploaded_revision", -1))
	var previous_snapshot := committer.readback_scene_voxel_tile_debug_snapshot()
	var previous_scene_values: PackedFloat32Array = previous_snapshot.get("complexity_field_values", PackedFloat32Array())
	var previous_collision_values: PackedFloat32Array = previous_snapshot.get("collision_field_values", PackedFloat32Array())
	var previous_scene_count := _packed_float_nonzero_count(previous_scene_values)
	var previous_collision_count := _packed_float_nonzero_count(previous_collision_values)
	if previous_scene_count <= 0 or previous_collision_count <= 0:
		push_error("  FAIL: initial GPU resident field readback should be non-empty")
		return false

	committer.apply_voxel_write_spec(_make_voxel_record("dirty_sv_rock_1", Vector2i(4, 4)))
	_build_default_volume(committer)
	if committer.is_scene_voxel_tile_gpu_ready():
		push_error("  FAIL: committed field update should stale previous GPU field buffers")
		return false
	var stale_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	if not bool(stale_summary.get("buffers_stale", false)):
		push_error("  FAIL: committed field update should mark SceneVoxelTile buffers stale")
		return false
	if str(stale_summary.get("resident_field_read_source", "")) != "none":
		push_error("  FAIL: stale committed fields must not be runtime read source")
		return false
	if str(stale_summary.get("readback_source", "")) != "none":
		push_error("  FAIL: stale committed fields must not expose a success readback source")
		return false
	if bool(stale_summary.get("cpu_fallback", true)):
		push_error("  FAIL: stale committed fields must not fall back to CPU")
		return false

	if not committer.ensure_scene_voxel_tile_buffers_uploaded(true):
		push_error("  FAIL: committed field update should re-upload scene/collision GPU buffers")
		return false
	var updated_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	if int(updated_summary.get("uploaded_revision", -1)) <= previous_revision:
		push_error("  FAIL: committed field upload revision did not advance")
		return false
	if str(updated_summary.get("resident_field_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: committed scene/collision fields should read from GPU buffers after re-upload")
		return false
	var field_update_reused_buffers: Array = updated_summary.get("last_reused_buffers", [])
	if bool(updated_summary.get("resident_field_buffers_reused", false)) or field_update_reused_buffers.has(SVC.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER) or field_update_reused_buffers.has(SVC.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER):
		push_error("  FAIL: committed field content changes must not reuse stale resident scene/collision buffers")
		return false
	var updated_snapshot := committer.readback_scene_voxel_tile_debug_snapshot()
	var updated_scene_values: PackedFloat32Array = updated_snapshot.get("complexity_field_values", PackedFloat32Array())
	var updated_collision_values: PackedFloat32Array = updated_snapshot.get("collision_field_values", PackedFloat32Array())
	if updated_scene_values.size() != int(updated_summary.get("complexity_field_voxel_count", 0)):
		push_error("  FAIL: updated complexity field readback count mismatch")
		return false
	if updated_collision_values.size() != int(updated_summary.get("collision_field_voxel_count", 0)):
		push_error("  FAIL: updated collision field readback count mismatch")
		return false
	if _packed_float_nonzero_count(updated_scene_values) <= previous_scene_count:
		push_error("  FAIL: committed complexity field GPU readback did not include the dirty update")
		return false
	if _packed_float_nonzero_count(updated_collision_values) <= previous_collision_count:
		push_error("  FAIL: committed collision field GPU readback did not include the dirty update")
		return false

	committer.dispose(true)
	print("  OK: dirty committed field update re-uploaded GPU resident scene/collision buffers")
	return true


func _test_scene_voxel_tile_auto_upload_or_skip() -> bool:
	print("[VoxelDirtyTile] test_scene_voxel_tile_auto_upload_or_skip...")
	var committer := _make_committer_with_voxel()
	committer.set_scene_voxel_tile_gpu_auto_upload(true)
	committer.mark_scene_voxel_tile_bounds_dirty(
		Vector3i(4, 0, 4),
		Vector3i(9, 1, 9),
		{"scene": true, "collision": true},
		{"id": "auto_upload_sv_rock_0", "source_id": "auto_upload_sv_rock_0"}
	)
	var sv := committer.get_sv()
	var summary: Dictionary = sv.get("scene_voxel_tile_gpu_buffer_summary", {})
	if not bool(summary.get("runtime_ready", false)):
		if str(summary.get("reason", "")) == "no_rendering_device":
			if str(summary.get("skip_reason", "")) != "no_rendering_device":
				push_error("  FAIL: skipped SceneVoxelTile auto-upload must expose skip_reason=no_rendering_device")
				return false
			_record_gpu_skip("no RenderingDevice for SceneVoxelTile auto-upload", str(summary.get("reason", "")))
			committer.dispose(true)
			return true
		push_error("  FAIL: SceneVoxelTile auto-upload failed without a no-RD skip reason: %s" % str(summary.get("reason", "")))
		return false
	if str(summary.get("runtime_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: auto-uploaded SceneVoxelTile metadata should read from GPU storage buffers")
		return false
	if str(summary.get("resident_field_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: auto-uploaded scene/collision fields should read from GPU storage buffers")
		return false
	if bool(summary.get("buffers_stale", true)):
		push_error("  FAIL: auto-uploaded SceneVoxelTile buffers should not be stale after get_sv publish")
		return false
	if int(summary.get("dirty_tile_count", -1)) != 0:
		push_error("  FAIL: get_sv publish should auto-upload the post-clear dirty index, got %d" % int(summary.get("dirty_tile_count", -1)))
		return false
	if str(sv.get("scene_voxel_tile_runtime_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: SV snapshot should publish SceneVoxelTile GPU runtime source")
		return false
	if str(sv.get("scene_voxel_tile_resident_field_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: SV snapshot should publish resident scene/collision GPU source")
		return false
	var snapshot := committer.readback_scene_voxel_tile_debug_snapshot()
	if not bool(snapshot.get("readback_snapshot", false)):
		push_error("  FAIL: auto-uploaded SceneVoxelTile buffers should read back")
		return false
	var dirty_ids: Array = snapshot.get("dirty_tile_ids", [])
	if not dirty_ids.is_empty():
		push_error("  FAIL: auto-uploaded post-publish dirty index should be empty, got %s" % str(dirty_ids))
		return false

	committer.dispose(true)
	print("  OK: get_sv lifecycle auto-uploaded clean SceneVoxelTile metadata to GPU")
	return true


func _test_committer_import_filter_pipeline_rids_or_skip() -> bool:
	print("[VoxelDirtyTile] test_committer_import_filter_pipeline_rids_or_skip...")
	if RenderingServer.get_rendering_device() == null:
		_record_gpu_skip("no RenderingDevice for committer import/filter pipeline RID validation", "no_rendering_device")
		return true

	var committer := SVC.new(8, 8.0, true)
	if not committer._gpu_ready:
		push_error("  FAIL: committer GPU readiness should require valid import/filter/blend pipeline RIDs")
		return false
	if not committer._pipeline_import.is_valid():
		push_error("  FAIL: import compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._pipeline_filter.is_valid():
		push_error("  FAIL: filter compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._pipeline_blend_complexity_fields.is_valid():
		push_error("  FAIL: blend complexity field compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._pipeline_resolve_scene_sources.is_valid():
		push_error("  FAIL: source resolver compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._pipeline_reduce_scene_voxel_stats.is_valid():
		push_error("  FAIL: voxel stats reduce compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._pipeline_reduce_scene_voxel_tile_summaries.is_valid():
		push_error("  FAIL: SceneVoxelTile summary reduce compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._pipeline_init_scene_voxel_tile_summaries.is_valid():
		push_error("  FAIL: SceneVoxelTile summary init compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._pipeline_compact_scene_voxel_tile_summaries.is_valid():
		push_error("  FAIL: SceneVoxelTile summary compact compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._pipeline_update_scene_voxel_tile_summary_ranges.is_valid():
		push_error("  FAIL: SceneVoxelTile summary dirty range update compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._pipeline_collect_disc_pixels.is_valid():
		push_error("  FAIL: disc pixel collect compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._pipeline_sample_r32_pixel.is_valid():
		push_error("  FAIL: R32 pixel sample compute pipeline RID should be valid when committer reports GPU ready")
		return false
	if not committer._shader_import.is_valid() or not committer._shader_filter.is_valid() or not committer._shader_blend_complexity_fields.is_valid() or not committer._shader_resolve_scene_sources.is_valid() or not committer._shader_reduce_scene_voxel_stats.is_valid() or not committer._shader_reduce_scene_voxel_tile_summaries.is_valid() or not committer._shader_init_scene_voxel_tile_summaries.is_valid() or not committer._shader_compact_scene_voxel_tile_summaries.is_valid() or not committer._shader_update_scene_voxel_tile_summary_ranges.is_valid() or not committer._shader_collect_disc_pixels.is_valid() or not committer._shader_sample_r32_pixel.is_valid():
		push_error("  FAIL: import/filter/blend/source-resolver/reduce/init/compact/summary-range/collector/sample shader RIDs should be valid when committer reports GPU ready")
		return false

	committer.build_voxel_volume(8, [
		{"channel": 0, "color": Color(0.2, 0.8, 0.2, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])
	var write_tick := committer.begin_generation_tick(committer.get_generation_tick())
	var auto_record := _make_gpu_blend_record("gpu_blend_auto", "AutoSceneVoxel", Vector2i(4, 4), 1.0, 1.0)
	var brush_record := _make_gpu_blend_record("gpu_blend_brush", "BrushSceneVoxel", Vector2i(4, 4), 0.2, 0.25)
	committer.apply_voxel_write_spec(auto_record, true, write_tick)
	committer.apply_voxel_write_spec(brush_record, true, write_tick)
	committer.blend_scene_voxels(write_tick)
	var commit_summary := committer.get_last_blend_scene_voxel_commit_summary()
	if str(commit_summary.get("payload_blend_mode", "")) != "merged_resolve_commit_gpu" or not bool(commit_summary.get("gpu_dispatched", false)):
		push_error("  FAIL: expected committed SceneVoxel payload blend from compute, got %s" % str(commit_summary))
		return false
	var sv := committer.get_sv()
	if str(sv.get("complexity_field_source", "")) != "resident_committed_scene_voxel_payload_buffers" \
			or str(sv.get("complexity_field_projection_mode", "")) != "committed_payload_dense_scatter" \
			or str(sv.get("complexity_field_runtime_read_source", "")) != "resident_committed_scene_voxel_payload_buffer" \
			or not bool(sv.get("complexity_field_committed_payload_projection", false)):
		push_error("  FAIL: expected resident complexity_field to project from committed payload buffers, got %s" % str(sv))
		return false
	if not bool(sv.get("tile_summary_gpu_dispatched", false)):
		push_error("  FAIL: expected SceneVoxelTile summaries to come from compute reduce, got %s" % str(sv))
		return false
	var complexity_field: PackedFloat32Array = sv.get("complexity_field", PackedFloat32Array())
	var center_idx := 4 + 8 * (4 + 8 * 0)
	if complexity_field.is_empty():
		var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
		var expected_count := grid_size.x * grid_size.y * grid_size.z
		if not _sv_complexity_field_is_resident(sv):
			push_error("  FAIL: committed-payload complexity_field is empty without resident GPU field metadata")
			return false
		if not _assert_scene_voxel_tile_resident_field_summary(
			committer,
			expected_count,
			"committed-payload projection"
		):
			return false
	else:
		if center_idx >= complexity_field.size() or absf(complexity_field[center_idx] - 0.4) > 0.001:
			push_error("  FAIL: Auto/Brush compute blend value mismatch at center: %s" % str(complexity_field))
			return false
	var source_resolve_summary := committer.get_last_scene_voxel_source_resolve_summary()
	if str(source_resolve_summary.get("mode", "")) != "resolve_resident_source_streams":
		push_error("  FAIL: expected source resolver to report resident source streams, got %s" % str(source_resolve_summary))
		return false

	committer.dispose(true)
	print("  OK: committer import/filter/blend/commit/source-resolver/reduce/init/compact/summary-range/collector/sample shader RIDs and compute passes are ready")
	return true


func _test_scene_voxel_tile_project_setting_size() -> bool:
	print("[VoxelDirtyTile] test_scene_voxel_tile_project_setting_size...")
	var setting := "meshfill/scene_voxel_tile/size_voxels"
	var had_setting := ProjectSettings.has_setting(setting)
	var old_value = ProjectSettings.get_setting(setting) if had_setting else null
	ProjectSettings.set_setting(setting, Vector3i(8, 2, 8))

	var committer := SVC.new(32, 32.0, false)
	committer.mark_scene_voxel_tile_bounds_dirty(
		Vector3i(8, 0, 8),
		Vector3i(17, 1, 17),
		{"scene": true}
	)
	var dirty_tiles := committer.get_dirty_scene_voxel_tiles()
	if dirty_tiles.is_empty():
		push_error("  FAIL: expected dirty SceneVoxelTile with project setting size")
		_restore_scene_voxel_tile_setting(setting, had_setting, old_value)
		return false
	if dirty_tiles.size() != 4:
		push_error("  FAIL: expected override bounds to map to 4 SceneVoxelTiles, got %d" % dirty_tiles.size())
		_restore_scene_voxel_tile_setting(setting, had_setting, old_value)
		return false
	if not dirty_tiles.has("1:0:1") or not dirty_tiles.has("2:0:2"):
		push_error("  FAIL: expected ProjectSettings tile ids 1:0:1 through 2:0:2")
		_restore_scene_voxel_tile_setting(setting, had_setting, old_value)
		return false
	var first_tile: Dictionary = dirty_tiles.values()[0]
	var tile_size: Vector3i = first_tile.get("tile_size", Vector3i.ZERO)
	if tile_size != Vector3i(8, 2, 8):
		push_error("  FAIL: expected ProjectSettings SceneVoxelTile size 8x2x8, got %s" % str(tile_size))
		_restore_scene_voxel_tile_setting(setting, had_setting, old_value)
		return false

	_restore_scene_voxel_tile_setting(setting, had_setting, old_value)
	print("  OK: SceneVoxelTile size follows ProjectSettings override")
	return true


func _test_gpu_autoobject_dirty_delta_tile_refs() -> bool:
	print("[VoxelDirtyTile] test_gpu_autoobject_dirty_delta_tile_refs...")
	var committer := _make_committer_with_voxel()
	committer.clear_sv_dirty()
	var empty_delta := committer.apply_gpu_autoobject_dirty_delta({})
	if bool(empty_delta.get("ok", true)):
		push_error("  FAIL: empty GPU AutoObject dirty delta should be rejected")
		return false
	if bool(empty_delta.get("cpu_fallback", true)):
		push_error("  FAIL: rejected empty dirty delta must not enable CPU fallback")
		return false
	var missing_object_delta := committer.apply_gpu_autoobject_dirty_delta({
		"new_voxel_min": Vector3i.ZERO,
		"new_voxel_max": Vector3i.ONE,
	})
	if bool(missing_object_delta.get("ok", true)) or str(missing_object_delta.get("reason", "")) != "missing_object_id":
		push_error("  FAIL: dirty delta without object id should report missing_object_id")
		return false
	if bool(missing_object_delta.get("cpu_fallback", true)):
		push_error("  FAIL: rejected missing-object dirty delta must not enable CPU fallback")
		return false
	var object_only_delta := committer.apply_gpu_autoobject_dirty_delta({
		"object_id": "gpu_autoobject_missing_bounds",
	})
	if bool(object_only_delta.get("ok", true)) or str(object_only_delta.get("reason", "")) != "missing_dirty_delta_bounds":
		push_error("  FAIL: object-id-only dirty delta should report missing_dirty_delta_bounds")
		return false
	if bool(object_only_delta.get("cpu_fallback", true)):
		push_error("  FAIL: rejected object-id-only dirty delta must not enable CPU fallback")
		return false
	if not committer.get_dirty_scene_voxel_tiles().is_empty() or not committer.get_sv_dirty_tiles().is_empty():
		push_error("  FAIL: rejected object-id-only dirty delta must not dirty any tile")
		return false
	var partial_bounds_delta := committer.apply_gpu_autoobject_dirty_delta({
		"object_id": "gpu_autoobject_partial_bounds",
		"new_voxel_min": Vector3i(4, 0, 4),
	})
	if bool(partial_bounds_delta.get("ok", true)) or str(partial_bounds_delta.get("reason", "")) != "missing_dirty_delta_bounds":
		push_error("  FAIL: partial dirty delta bounds should report missing_dirty_delta_bounds")
		return false
	if bool(partial_bounds_delta.get("cpu_fallback", true)):
		push_error("  FAIL: rejected partial-bounds dirty delta must not enable CPU fallback")
		return false
	if not committer.get_dirty_scene_voxel_tiles().is_empty() or not committer.get_sv_dirty_tiles().is_empty():
		push_error("  FAIL: rejected partial-bounds dirty delta must not dirty any tile")
		return false
	var result := committer.apply_gpu_autoobject_dirty_delta({
		"object_id": "gpu_autoobject_42",
		"old_voxel_min": Vector3i(0, 0, 0),
		"old_voxel_max": Vector3i(4, 1, 4),
		"new_voxel_min": Vector3i(12, 0, 12),
		"new_voxel_max": Vector3i(17, 1, 17),
		"dirty_flags": {"collision": true},
	})
	if result.is_empty():
		push_error("  FAIL: expected GPU AutoObject dirty delta result")
		return false
	if not bool(result.get("ok", false)):
		push_error("  FAIL: valid GPU AutoObject dirty delta should report ok=true")
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: valid GPU AutoObject dirty delta must report cpu_fallback=false")
		return false
	var dirty_tiles: Dictionary = result.get("dirty_scene_voxel_tiles", {})
	if dirty_tiles.is_empty():
		push_error("  FAIL: expected GPU AutoObject delta to dirty SceneVoxelTiles")
		return false
	var found_object_refs := false
	for raw_tile in dirty_tiles.values():
		if not raw_tile is Dictionary:
			continue
		var tile: Dictionary = raw_tile
		var flags: Dictionary = tile.get("dirty_flags", {})
		found_object_refs = found_object_refs or (
			bool(flags.get("auto", false)) and
			bool(flags.get("object_refs", false)) and
			bool(flags.get("collision", false))
		)
	if not found_object_refs:
		push_error("  FAIL: GPU AutoObject delta should mark auto/object_refs/collision dirty flags")
		return false
	var sv := committer.get_sv()
	if int(sv.get("scene_voxel_tile_gpu_autoobject_ref_count", 0)) != 1:
		push_error("  FAIL: expected one GPU AutoObject tile ref in SV snapshot")
		return false
	var object_ids: Array = sv.get("scene_voxel_tile_object_ids_debug", [])
	if not object_ids.has("gpu_autoobject_42"):
		push_error("  FAIL: compact SceneVoxelTile object range missing GPU AutoObject id")
		return false

	print("  OK: GPU AutoObject delta marked dirty tiles and compact object refs")
	return true


func _test_gpu_autoobject_dirty_delta_batch_tile_refs() -> bool:
	print("[VoxelDirtyTile] test_gpu_autoobject_dirty_delta_batch_tile_refs...")
	var committer := _make_committer_with_voxel()
	committer.clear_sv_dirty()

	var result := committer.apply_gpu_autoobject_dirty_deltas([
		{
			"object_id": 7,
			"old_voxel_min": Vector3i(0, 0, 0),
			"old_voxel_max": Vector3i(4, 1, 4),
			"new_voxel_min": Vector3i(12, 0, 12),
			"new_voxel_max": Vector3i(16, 1, 16),
			"dirty_flags": {"collision": true},
		},
		{
			"object_id": 8,
			"old_voxel_min": Vector3i(4, 0, 4),
			"old_voxel_max": Vector3i(8, 1, 8),
			"new_voxel_min": Vector3i(8, 0, 8),
			"new_voxel_max": Vector3i(12, 1, 12),
			"dirty_flags": {"scoring": true},
		},
	])
	if not bool(result.get("ok", false)):
		push_error("  FAIL: dirty-delta batch should apply cleanly")
		return false
	if int(result.get("dirty_delta_count", -1)) != 2 \
	   or int(result.get("commit_result_count", -1)) != 2 \
	   or int(result.get("failed_commit_result_count", -1)) != 0:
		push_error("  FAIL: dirty-delta batch counts were wrong: %s" % str(result))
		return false
	if str(result.get("dirty_delta_apply_api", "")) != "apply_gpu_autoobject_dirty_deltas":
		push_error("  FAIL: dirty-delta batch should report its batch API")
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: dirty-delta batch must not report CPU fallback")
		return false
	if str(result.get("dirty_delta_bridge_mode", "")) != "gpu_scene_voxel_tile_object_ref_update_with_cpu_debug_projection":
		push_error("  FAIL: numeric dirty-delta batch should report resident object-ref update bridge: %s" % str(result))
		return false
	if not bool(result.get("resident_gpu_dirty_delta_update_pass", false)):
		push_error("  FAIL: numeric dirty-delta batch should claim resident GPU update pass")
		return false
	if str(result.get("resident_gpu_dirty_delta_update_pass_owner", "")) != "SceneVoxelCommitter" \
	   or str(result.get("resident_gpu_dirty_delta_update_pass_shader", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME \
	   or int(result.get("resident_gpu_dirty_delta_update_pass_dispatch_count", 0)) != 1:
		push_error("  FAIL: dirty-delta batch resident update-pass diagnostics mismatch: %s" % str(result))
		return false
	if not bool(result.get("object_ref_update_stats_available", false)) \
	   or not bool(result.get("object_ref_update_gpu_dispatched", false)) \
	   or int(result.get("object_ref_update_dispatch_count", 0)) != 1:
		push_error("  FAIL: dirty-delta batch should expose resident object-ref dispatch stats: %s" % str(result))
		return false
	if int(result.get("object_ref_inserted_slot_count", -1)) != 2 \
	   or int(result.get("object_ref_non_numeric_count", -1)) != 0 \
	   or int(result.get("object_ref_overflow_count", -1)) != 0 \
	   or int(result.get("object_ref_invalid_bounds_count", -1)) != 0:
		push_error("  FAIL: dirty-delta batch object-ref update stats mismatch: %s" % str(result))
		return false
	if not _assert_object_ref_range_policy(result, "dirty-delta batch"):
		return false
	if not _assert_transient_dirty_tile_result(
		result,
		["0:0:0", "1:0:1", "2:0:2", "3:0:3"],
		"scene_voxel_tile_dirty_flags",
		"dirty-delta batch"
	):
		return false
	var update_result: Dictionary = result.get("object_ref_update_result", {})
	var resident_worklist_rid := str(update_result.get("resident_dirty_tile_worklist_buffer_rid", "none"))
	var resident_flag_rid := str(update_result.get("resident_dirty_tile_flag_buffer_rid", "none"))
	if resident_worklist_rid == "none" or resident_worklist_rid.is_empty() \
	   or resident_flag_rid == "none" or resident_flag_rid.is_empty():
		push_error("  FAIL: dirty-delta batch should expose resident dirty tile worklist/flag RIDs: %s" % str(update_result))
		return false
	if int(update_result.get("resident_dirty_tile_worklist_capacity", 0)) < int(result.get("transient_dirty_scene_voxel_tile_count", 0)) \
	   or int(update_result.get("resident_dirty_tile_flag_capacity", 0)) < int(result.get("object_ref_tile_count", 0)):
		push_error("  FAIL: dirty-delta batch resident dirty tile capacities mismatch: %s" % str(update_result))
		return false
	if not bool(update_result.get("cpu_readback_debug_only", false)):
		push_error("  FAIL: dirty-delta batch should mark CPU dirty-tile readback as debug-only")
		return false

	var stale_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	if not bool(stale_summary.get("buffers_stale", false)) \
	   or bool(stale_summary.get("runtime_ready", true)) \
	   or str(stale_summary.get("runtime_read_source", "")) != "none" \
	   or str(stale_summary.get("resident_field_read_source", "")) != "none":
		push_error("  FAIL: CPU debug projection should stale SceneVoxelTile runtime reads after resident dispatch: %s" % str(stale_summary))
		return false
	if bool(stale_summary.get("cpu_fallback", true)):
		push_error("  FAIL: stale dirty-delta batch summary must not report CPU fallback")
		return false
	var object_ref_rid := committer.get_scene_voxel_tile_gpu_buffer(SVC.SCENE_VOXEL_TILE_OBJECT_REF_BUFFER)
	var stale_buffers: Dictionary = stale_summary.get("buffers", {})
	var stale_object_ref_buffer: Dictionary = stale_buffers.get(SVC.SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, {})
	if not object_ref_rid.is_valid() or not bool(stale_object_ref_buffer.get("rid_valid", false)):
		push_error("  FAIL: dirty-delta batch should retain a valid resident object-ref buffer RID while metadata is stale")
		return false
	if int(stale_object_ref_buffer.get("record_count", -1)) != int(result.get("object_ref_capacity", -2)):
		push_error("  FAIL: stale object-ref buffer record count should match capacity")
		return false

	if not committer.ensure_scene_voxel_tile_buffers_uploaded(false):
		push_error("  FAIL: dirty-delta batch should re-upload staged CPU debug projection for readback")
		return false
	var gpu_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	if not bool(gpu_summary.get("runtime_ready", false)) \
	   or bool(gpu_summary.get("cpu_fallback", true)) \
	   or str(gpu_summary.get("runtime_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: dirty-delta batch re-upload should restore SceneVoxelTile GPU runtime reads: %s" % str(gpu_summary))
		return false
	var buffers: Dictionary = gpu_summary.get("buffers", {})
	var object_ref_buffer: Dictionary = buffers.get(SVC.SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, {})
	var uploaded_object_ref_rid := committer.get_scene_voxel_tile_gpu_buffer(SVC.SCENE_VOXEL_TILE_OBJECT_REF_BUFFER)
	if not uploaded_object_ref_rid.is_valid() or not bool(object_ref_buffer.get("rid_valid", false)):
		push_error("  FAIL: dirty-delta batch re-uploaded object-ref buffer RID should be valid")
		return false
	if int(object_ref_buffer.get("record_count", -1)) != int(result.get("object_ref_capacity", -2)):
		push_error("  FAIL: re-uploaded object-ref buffer record count should match capacity")
		return false
	var dirty_tiles: Dictionary = result.get("dirty_scene_voxel_tiles", {})
	if dirty_tiles.is_empty():
		push_error("  FAIL: dirty-delta batch should dirty SceneVoxelTiles")
		return false
	for expected_id in ["0:0:0", "1:0:1", "2:0:2", "3:0:3"]:
		if not dirty_tiles.has(expected_id):
			push_error("  FAIL: dirty-delta batch missing SceneVoxelTile %s" % expected_id)
			return false
	var snapshot := committer.readback_scene_voxel_tile_debug_snapshot()
	var object_ref_bytes: PackedByteArray = snapshot.get("object_ref_bytes", PackedByteArray())
	var tile_grid: Vector3i = result.get("object_ref_tile_grid_size", Vector3i.ZERO)
	var refs_per_tile := int(result.get("refs_per_tile", SVC.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT))
	var batch_a_tile_index := _scene_voxel_tile_flattened_index(Vector3i(3, 0, 3), tile_grid)
	var batch_b_tile_index := _scene_voxel_tile_flattened_index(Vector3i(2, 0, 2), tile_grid)
	if not _object_ref_slots_contain(object_ref_bytes, batch_a_tile_index, refs_per_tile, 8):
		push_error("  FAIL: dirty-delta batch should write object_id+1 ref for object 7 into new tile")
		return false
	if not _object_ref_slots_contain(object_ref_bytes, batch_b_tile_index, refs_per_tile, 9):
		push_error("  FAIL: dirty-delta batch should write object_id+1 ref for object 8 into new tile")
		return false
	var sv := committer.get_sv()
	if int(sv.get("scene_voxel_tile_gpu_autoobject_ref_count", 0)) != 2:
		push_error("  FAIL: dirty-delta batch should publish two GPU AutoObject refs")
		return false
	var object_ids: Array = sv.get("scene_voxel_tile_object_ids_debug", [])
	if not object_ids.has("7") or not object_ids.has("8"):
		push_error("  FAIL: dirty-delta batch compact object ids missing batch refs")
		return false

	print("  OK: GPU AutoObject numeric delta batch used resident object-ref update and dirty handoff")
	return true


func _test_gpu_autoobject_object_ref_pending_shader_contract() -> bool:
	print("[VoxelDirtyTile] test_gpu_autoobject_object_ref_update_shader_contract...")
	var committer := _make_committer_with_voxel()
	committer.clear_sv_dirty()

	var result := committer.apply_gpu_autoobject_dirty_delta({
		"object_id": 4,
		"old_voxel_min": Vector3i(0, 0, 0),
		"old_voxel_max": Vector3i(4, 1, 4),
		"new_voxel_min": Vector3i(12, 0, 12),
		"new_voxel_max": Vector3i(16, 1, 16),
		"dirty_flags": {"object_refs": true},
	})
	if not bool(result.get("ok", false)):
		push_error("  FAIL: numeric GPU AutoObject dirty delta should apply through SceneVoxelTile bridge")
		return false
	var diagnostics := committer.get_gpu_autoobject_object_ref_range_policy_diagnostics()
	if not _assert_object_ref_range_policy(diagnostics, "single dirty-delta diagnostics"):
		return false
	if bool(diagnostics.get("object_ref_update_gpu_dispatched", true)):
		push_error("  FAIL: single-delta CPU debug projection must not claim shader dispatch")
		return false

	print("  OK: GPU AutoObject object-ref diagnostics report resident shader availability")
	return true


func _test_gpu_autoobject_object_ref_update_pass_or_skip() -> bool:
	print("[VoxelDirtyTile] test_gpu_autoobject_object_ref_update_pass_or_skip...")
	var committer := _make_committer_with_voxel()
	committer.clear_sv_dirty()
	if not committer.ensure_scene_voxel_tile_buffers_uploaded(true):
		var skipped_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
		if str(skipped_summary.get("gpu_upload_status", "")) == "skip":
			_record_gpu_skip("object-ref update pass", str(skipped_summary.get("skip_reason", "")))
			return true
		push_error("  FAIL: SceneVoxelTile buffers should upload before object-ref update pass: %s" % str(skipped_summary))
		return false

	var result := committer.try_apply_gpu_autoobject_object_ref_update_pass([{
		"object_id": 4,
		"old_voxel_min": Vector3i(0, 0, 0),
		"old_voxel_max": Vector3i(1, 1, 1),
		"new_voxel_min": Vector3i(0, 0, 0),
		"new_voxel_max": Vector3i(4, 1, 4),
		"dirty_flags": {"object_refs": true},
	}])
	if not bool(result.get("ok", false)):
		push_error("  FAIL: opt-in object-ref update pass should dispatch: %s" % str(result))
		return false
	if str(result.get("dirty_delta_apply_api", "")) != "try_apply_gpu_autoobject_object_ref_update_pass":
		push_error("  FAIL: opt-in pass should report its explicit apply API")
		return false
	if str(result.get("dirty_delta_bridge_mode", "")) != "explicit_scene_voxel_tile_object_ref_update_pass":
		push_error("  FAIL: opt-in pass should not report the CPU dirty-delta bridge")
		return false
	if str(result.get("object_ref_range_policy", "")) != "fixed_per_tile_object_ref_update_pass":
		push_error("  FAIL: opt-in pass should report active fixed-slot object-ref policy")
		return false
	if str(result.get("object_ref_range_shader", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME:
		push_error("  FAIL: opt-in pass should report object-ref shader name")
		return false
	if not bool(result.get("object_ref_range_shader_ready", false)):
		push_error("  FAIL: opt-in pass should report shader readiness")
		return false
	if not bool(result.get("resident_gpu_dirty_delta_update_pass", false)):
		push_error("  FAIL: opt-in pass should report resident dispatch success")
		return false
	if str(result.get("resident_gpu_dirty_delta_update_pass_owner", "")) != "SceneVoxelCommitter" \
	   or str(result.get("resident_gpu_dirty_delta_update_pass_shader", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME \
	   or int(result.get("resident_gpu_dirty_delta_update_pass_dispatch_count", 0)) != 1:
		push_error("  FAIL: opt-in pass resident diagnostics mismatch: %s" % str(result))
		return false
	if not bool(result.get("object_ref_update_stats_available", false)) \
	   or not bool(result.get("object_ref_update_gpu_dispatched", false)) \
	   or int(result.get("object_ref_update_dispatch_count", 0)) != 1:
		push_error("  FAIL: opt-in pass should expose dispatched stats")
		return false
	if int(result.get("object_ref_inserted_slot_count", 0)) != 1 \
	   or int(result.get("object_ref_touched_count", 0)) != 1 \
	   or int(result.get("object_ref_overflow_count", -1)) != 0 \
	   or int(result.get("object_ref_non_numeric_count", -1)) != 0:
		push_error("  FAIL: opt-in pass stats mismatch: %s" % str(result))
		return false
	if not _assert_transient_dirty_tile_result(
		result,
		["0:0:0"],
		"scene_voxel_tile_dirty_flags",
		"staged opt-in pass"
	):
		return false
	if not committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("  FAIL: opt-in pass should not mutate CPU SceneVoxelTile dirty metadata")
		return false

	var snapshot := committer.readback_scene_voxel_tile_debug_snapshot()
	var object_ref_bytes: PackedByteArray = snapshot.get("object_ref_bytes", PackedByteArray())
	var tile_grid: Vector3i = result.get("object_ref_tile_grid_size", Vector3i.ZERO)
	var refs_per_tile := int(result.get("refs_per_tile", SVC.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT))
	var tile_index := _scene_voxel_tile_flattened_index(Vector3i(0, 0, 0), tile_grid)
	if not _object_ref_slots_contain(object_ref_bytes, tile_index, refs_per_tile, 5):
		push_error("  FAIL: opt-in pass should write numeric object_id+1 ref into fixed tile slots")
		return false

	var dirty_delta_bytes := _make_object_ref_dirty_delta_bytes(
		10,
		Vector3i(0, 0, 0),
		Vector3i(1, 1, 1),
		Vector3i(4, 0, 4),
		Vector3i(8, 1, 8),
		false,
		true
	)
	var dirty_delta_buffer: RID = committer.storage_buffer_from_bytes(
		dirty_delta_bytes,
		"frame",
		"test_object_ref_dirty_delta_buffer"
	)
	var buffer_result := committer.try_apply_gpu_autoobject_object_ref_update_pass_from_buffer(
		dirty_delta_buffer,
		1,
		1,
		"test_borrowed_dirty_delta_buffer"
	)
	if not bool(buffer_result.get("ok", false)):
		push_error("  FAIL: opt-in object-ref update pass should accept a dirty-delta buffer RID: %s" % str(buffer_result))
		return false
	if str(buffer_result.get("dirty_delta_apply_api", "")) != "try_apply_gpu_autoobject_object_ref_update_pass_from_buffer":
		push_error("  FAIL: borrowed-buffer opt-in pass should report its explicit buffer API")
		return false
	var buffer_update_result: Dictionary = buffer_result.get("object_ref_update_result", {})
	if str(buffer_update_result.get("dirty_delta_source", "")) != "test_borrowed_dirty_delta_buffer":
		push_error("  FAIL: borrowed-buffer opt-in pass should preserve dirty-delta source")
		return false
	if not bool(buffer_result.get("resident_gpu_dirty_delta_update_pass", false)) \
	   or int(buffer_result.get("object_ref_update_dispatch_count", 0)) != 1 \
	   or int(buffer_result.get("object_ref_inserted_slot_count", 0)) != 1:
		push_error("  FAIL: borrowed-buffer opt-in pass dispatch diagnostics mismatch: %s" % str(buffer_result))
		return false
	if not _assert_transient_dirty_tile_result(
		buffer_result,
		["0:0:0", "1:0:1"],
		"scene_voxel_tile_dirty_flags",
		"borrowed-buffer opt-in pass"
	):
		return false
	var buffer_snapshot := committer.readback_scene_voxel_tile_debug_snapshot()
	var buffer_object_ref_bytes: PackedByteArray = buffer_snapshot.get("object_ref_bytes", PackedByteArray())
	var buffer_tile_index := _scene_voxel_tile_flattened_index(Vector3i(1, 0, 1), tile_grid)
	if not _object_ref_slots_contain(buffer_object_ref_bytes, buffer_tile_index, refs_per_tile, 11):
		push_error("  FAIL: borrowed-buffer opt-in pass should write numeric object_id+1 ref into fixed tile slots")
		return false

	var bridge_result := committer.apply_gpu_autoobject_dirty_deltas([{
		"object_id": 6,
		"old_voxel_min": Vector3i(4, 0, 4),
		"old_voxel_max": Vector3i(5, 1, 5),
		"new_voxel_min": Vector3i(4, 0, 4),
		"new_voxel_max": Vector3i(8, 1, 8),
		"dirty_flags": {"object_refs": true},
	}])
	if not bool(bridge_result.get("ok", false)):
		push_error("  FAIL: normal dirty-delta batch should still apply")
		return false
	if str(bridge_result.get("dirty_delta_bridge_mode", "")) != "gpu_scene_voxel_tile_object_ref_update_with_cpu_debug_projection":
		push_error("  FAIL: normal numeric dirty-delta batch should use GPU object-ref update with CPU debug projection")
		return false
	if not bool(bridge_result.get("resident_gpu_dirty_delta_update_pass", false)) \
	   or str(bridge_result.get("resident_gpu_dirty_delta_update_pass_owner", "")) != "SceneVoxelCommitter" \
	   or str(bridge_result.get("resident_gpu_dirty_delta_update_pass_shader", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME \
	   or int(bridge_result.get("resident_gpu_dirty_delta_update_pass_dispatch_count", 0)) != 1:
		push_error("  FAIL: normal numeric dirty-delta batch should dispatch resident object-ref update")
		return false
	if not _assert_object_ref_range_policy(bridge_result, "post-opt-in normal dirty-delta batch"):
		return false

	print("  OK: object-ref shader dispatch updates fixed slots for opt-in, borrowed-buffer, and numeric batch paths")
	return true


func _sv_complexity_field_is_resident(sv: Dictionary) -> bool:
	var runtime_read_source := str(sv.get("complexity_field_runtime_read_source", "none"))
	var projection_read_source := str(sv.get("public_scene_voxel_projection_runtime_read_source", "none"))
	return bool(sv.get("complexity_field_buffer_resident", false)) \
		or bool(sv.get("complexity_field_final_source_stream_resident", false)) \
		or runtime_read_source == "gpu_resident_blend_output" \
		or runtime_read_source.begins_with("resident_") \
		or projection_read_source.begins_with("resident_") \
		or str(sv.get("scene_voxel_tile_resident_field_read_source", "none")) == "gpu_storage_buffers"


func _sv_collision_field_is_resident(sv: Dictionary) -> bool:
	var runtime_read_source := str(sv.get("collision_field_runtime_read_source", "none"))
	return runtime_read_source == "resident_gpu_buffer" \
		or runtime_read_source.begins_with("resident_") \
		or str(sv.get("scene_voxel_tile_resident_field_read_source", "none")) == "gpu_storage_buffers"


func _assert_scene_voxel_tile_resident_field_summary(
	committer: SceneVoxelCommitter,
	expected_count: int,
	label: String
) -> bool:
	if expected_count <= 0:
		push_error("  FAIL: %s expected voxel count must be positive" % label)
		return false
	if not committer.ensure_scene_voxel_tile_buffers_uploaded(true):
		var failed_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
		push_error("  FAIL: %s resident SceneVoxelTile buffer upload failed: %s" % [label, str(failed_summary)])
		return false

	var summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	if not bool(summary.get("runtime_ready", false)):
		push_error("  FAIL: %s resident SceneVoxelTile summary should be runtime ready: %s" % [label, str(summary)])
		return false
	if bool(summary.get("cpu_fallback", true)):
		push_error("  FAIL: %s resident SceneVoxelTile summary must not report CPU fallback" % label)
		return false
	if str(summary.get("resident_field_read_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: %s resident SceneVoxelTile fields should read from GPU storage buffers" % label)
		return false
	if int(summary.get("resident_field_voxel_count", -1)) != expected_count:
		push_error("  FAIL: %s resident field voxel count mismatch: %s" % [label, str(summary)])
		return false
	if int(summary.get("complexity_field_voxel_count", -1)) != expected_count:
		push_error("  FAIL: %s complexity field voxel count mismatch: %s" % [label, str(summary)])
		return false
	if int(summary.get("collision_field_voxel_count", -1)) != expected_count:
		push_error("  FAIL: %s collision field voxel count mismatch: %s" % [label, str(summary)])
		return false

	var buffers: Dictionary = summary.get("buffers", {})
	var complexity_field_buffer: Dictionary = buffers.get(SVC.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER, {})
	var collision_field_buffer: Dictionary = buffers.get(SVC.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER, {})
	if not bool(complexity_field_buffer.get("rid_valid", false)) or not bool(collision_field_buffer.get("rid_valid", false)):
		push_error("  FAIL: %s resident scene/collision buffer RIDs should be valid" % label)
		return false
	if int(complexity_field_buffer.get("record_count", -1)) != expected_count:
		push_error("  FAIL: %s complexity field buffer record count mismatch" % label)
		return false
	if int(collision_field_buffer.get("record_count", -1)) != expected_count:
		push_error("  FAIL: %s collision field buffer record count mismatch" % label)
		return false
	return true


func _assert_transient_dirty_tile_result(
	result: Dictionary,
	expected_tile_ids: Array,
	expected_schema: String,
	label: String
) -> bool:
	if not bool(result.get("transient_dirty_scene_voxel_tile_gpu_emitted", false)):
		push_error("  FAIL: %s should report GPU-emitted transient dirty SceneVoxelTiles" % label)
		return false
	if int(result.get("transient_dirty_scene_voxel_tile_count", -1)) != expected_tile_ids.size():
		push_error("  FAIL: %s transient dirty tile count mismatch: %s" % [label, str(result)])
		return false
	if int(result.get("transient_dirty_scene_voxel_tile_worklist_count", -1)) != expected_tile_ids.size():
		push_error("  FAIL: %s transient dirty worklist count mismatch: %s" % [label, str(result)])
		return false
	if int(result.get("transient_dirty_scene_voxel_tile_worklist_overflow_count", -1)) != 0:
		push_error("  FAIL: %s transient dirty worklist should not overflow: %s" % [label, str(result)])
		return false
	if str(result.get("transient_dirty_scene_voxel_tile_flag_schema", "")) != expected_schema:
		push_error("  FAIL: %s transient dirty flag schema mismatch: %s" % [label, str(result)])
		return false
	if str(result.get("transient_dirty_scene_voxel_tile_cpu_metadata_bridge", "")) != "none":
		push_error("  FAIL: %s should not claim a CPU metadata bridge for transient dirty tiles" % label)
		return false

	var tile_ids: Array = result.get("transient_dirty_scene_voxel_tile_ids", [])
	var flags_by_id: Dictionary = result.get("transient_dirty_scene_voxel_tile_flags", {})
	for raw_id in expected_tile_ids:
		var tile_id := str(raw_id)
		if not tile_ids.has(tile_id):
			push_error("  FAIL: %s missing transient dirty SceneVoxelTile %s in %s" % [label, tile_id, str(tile_ids)])
			return false
		var flags: Dictionary = flags_by_id.get(tile_id, {})
		if not bool(flags.get("auto", false)) or not bool(flags.get("object_refs", false)):
			push_error("  FAIL: %s transient dirty flags missing auto/object_refs for %s: %s" % [label, tile_id, str(flags)])
			return false
	return true


func _assert_object_ref_range_policy(result: Dictionary, label: String) -> bool:
	if str(result.get("object_ref_range_policy", "")) != "fixed_per_tile_object_ref_update_pass":
		push_error("  FAIL: %s should report fixed per-tile object-ref update policy" % label)
		return false
	if str(result.get("object_ref_range_owner", "")) != "SceneVoxelCommitter":
		push_error("  FAIL: %s should report SceneVoxelCommitter as object-ref range owner" % label)
		return false
	if str(result.get("object_ref_range_shader", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME:
		push_error("  FAIL: %s should report the object-ref update shader" % label)
		return false
	if str(result.get("object_ref_range_shader_path", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH:
		push_error("  FAIL: %s should report the object-ref update shader path" % label)
		return false
	if not bool(result.get("object_ref_range_shader_ready", false)):
		push_error("  FAIL: %s should report object-ref shader readiness" % label)
		return false
	var refs_per_tile := int(result.get("refs_per_tile", -1))
	var tile_count := int(result.get("object_ref_tile_count", -1))
	var capacity := int(result.get("object_ref_capacity", -1))
	if refs_per_tile != 8 or tile_count <= 0 or capacity != tile_count * refs_per_tile:
		push_error("  FAIL: %s object-ref capacity contract mismatch: %s" % [label, str(result)])
		return false
	if bool(result.get("object_ref_rebuild_required", true)):
		push_error("  FAIL: %s should not require rebuild without overflow/mismatch" % label)
		return false
	if int(result.get("object_ref_overflow_count", -1)) != 0 or int(result.get("overflow_tile_count", -1)) != 0:
		push_error("  FAIL: %s should report zero object-ref overflow diagnostics" % label)
		return false
	if bool(result.get("object_ref_update_gpu_dispatched", false)) and int(result.get("object_ref_update_dispatch_count", -1)) <= 0:
		push_error("  FAIL: %s should report a positive dispatch count when object-ref shader dispatch is true" % label)
		return false
	if not bool(result.get("object_ref_update_gpu_dispatched", false)):
		if int(result.get("object_ref_non_numeric_count", -1)) != 0 \
		   or int(result.get("object_ref_duplicate_count", -1)) != 0 \
		   or int(result.get("object_ref_touched_count", -1)) != 0:
			push_error("  FAIL: %s should report zero object-ref shader stats before dispatch" % label)
			return false
	if str(result.get("gpu_autoobject_ref_key_schema", "")) != "u32_numeric_ref_key_v1":
		push_error("  FAIL: %s should report explicit numeric GPU AutoObject ref-key schema" % label)
		return false
	if not str(result.get("gpu_autoobject_ref_key_schema_note", "")).contains("u32 ref_key"):
		push_error("  FAIL: %s should include numeric u32 ref-key schema note" % label)
		return false
	return true


func _test_clear_sv_dirty() -> bool:
	print("[VoxelDirtyTile] test_clear_sv_dirty...")
	var committer := _make_committer_with_voxel()
	committer.invalidate_sv_tile(0, Vector2i(16, 16), "scene")
	if committer.get_sv_dirty_tiles().is_empty():
		push_error("  FAIL: expected dirty tile before clear")
		return false
	committer.clear_sv_dirty()
	if not committer.get_sv_dirty_tiles().is_empty():
		push_error("  FAIL: expected dirty tiles to clear")
		return false
	if not committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("  FAIL: expected named SceneVoxelTile dirty flags to clear")
		return false
	var sv := committer.get_sv()
	if int(sv.get("dirty_tile_count", -1)) != 0:
		push_error("  FAIL: expected SV dirty_tile_count=0 after clear")
		return false
	if int(sv.get("dirty_scene_voxel_tile_count", -1)) != 0:
		push_error("  FAIL: expected SV dirty_scene_voxel_tile_count=0 after clear")
		return false
	print("  OK: clear_sv_dirty reset pending dirty state")
	return true


func _make_committer_with_voxel() -> SceneVoxelCommitter:
	var committer := SVC.new(32, 32.0, false)

	committer.apply_voxel_write_spec(_make_voxel_record("dirty_sv_rock_0", Vector2i(16, 16)))
	_build_default_volume(committer)
	return committer


func _make_voxel_record(record_id: String, base_pixel: Vector2i) -> Dictionary:
	return {
		"id": record_id,
		"type": "rock",
		"source_voxel_type": "AutoSceneVoxel",
		"position": Vector3.ZERO,
		"base_pixel": base_pixel,
		"voxel_xz": base_pixel,
		"volume_xz_resolution": 32,
		"scale": Vector3.ONE,
		"color": Color(0.55, 0.50, 0.45, 1.0),
		"complexity": 1.0,
		"collision": [],
		"channel": 0,
		"radius": 2.0,
	}


func _make_gpu_blend_record(record_id: String, source_type: String, base_pixel: Vector2i, complexity: float, auto_mix: float) -> Dictionary:
	return {
		"id": record_id,
		"type": "brush" if source_type == "BrushSceneVoxel" else "rock",
		"source_voxel_type": source_type,
		"position": Vector3.ZERO,
		"base_pixel": base_pixel,
		"voxel_xz": base_pixel,
		"volume_xz_resolution": 8,
		"scale": Vector3.ONE,
		"color": Color(complexity, complexity, complexity, complexity),
		"complexity": complexity,
		"auto_mix": auto_mix,
		"channel": 0,
		"radius": 0.0,
	}


func _build_default_volume(committer: SceneVoxelCommitter) -> void:
	committer.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.55, 0.50, 0.45, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])


func _packed_float_max(values: PackedFloat32Array) -> float:
	var result := 0.0
	for value in values:
		result = maxf(result, value)
	return result


func _packed_float_nonzero_count(values: PackedFloat32Array) -> int:
	var count := 0
	for value in values:
		if value > 0.01:
			count += 1
	return count


func _object_ref_slots_contain(bytes: PackedByteArray, tile_index: int, refs_per_tile: int, ref_key: int) -> bool:
	if tile_index < 0 or refs_per_tile <= 0:
		return false
	var slot_base := tile_index * refs_per_tile
	for slot in range(refs_per_tile):
		var byte_offset := (slot_base + slot) * SVC.SCENE_VOXEL_TILE_REF_STRIDE_BYTES
		if byte_offset < 0 or byte_offset + SVC.SCENE_VOXEL_TILE_REF_STRIDE_BYTES > bytes.size():
			continue
		if int(bytes.decode_u32(byte_offset)) == ref_key:
			return true
	return false


func _make_object_ref_dirty_delta_bytes(
	object_id: int,
	old_min: Vector3i,
	old_max: Vector3i,
	new_min: Vector3i,
	new_max: Vector3i,
	removed: bool,
	alive_after: bool
) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(SVC.SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_DELTA_STRIDE_BYTES)
	bytes.encode_s32(0, object_id)
	bytes.encode_s32(4, 0)
	bytes.encode_s32(8, 0)
	bytes.encode_s32(12, 0)
	bytes.encode_s32(16, old_min.x)
	bytes.encode_s32(20, old_min.y)
	bytes.encode_s32(24, old_min.z)
	bytes.encode_s32(28, 1 if removed else 0)
	bytes.encode_s32(32, old_max.x)
	bytes.encode_s32(36, old_max.y)
	bytes.encode_s32(40, old_max.z)
	bytes.encode_s32(44, 1 if alive_after else 0)
	bytes.encode_s32(48, new_min.x)
	bytes.encode_s32(52, new_min.y)
	bytes.encode_s32(56, new_min.z)
	bytes.encode_s32(60, 0)
	bytes.encode_s32(64, new_max.x)
	bytes.encode_s32(68, new_max.y)
	bytes.encode_s32(72, new_max.z)
	bytes.encode_s32(76, 0)
	return bytes


func _scene_voxel_tile_grid_for(p_grid_size: Vector3i, tile_size: Vector3i) -> Vector3i:
	var safe_tile := Vector3i(maxi(tile_size.x, 1), maxi(tile_size.y, 1), maxi(tile_size.z, 1))
	return Vector3i(
		maxi(ceili(float(maxi(p_grid_size.x, 1)) / float(safe_tile.x)), 1),
		maxi(ceili(float(maxi(p_grid_size.y, 1)) / float(safe_tile.y)), 1),
		maxi(ceili(float(maxi(p_grid_size.z, 1)) / float(safe_tile.z)), 1)
	)


func _scene_voxel_tile_flattened_index(tile_coord: Vector3i, tile_grid: Vector3i) -> int:
	return tile_coord.x + tile_grid.x * (tile_coord.z + tile_grid.z * tile_coord.y)


func _full_dirty_coverage_matches(dirty_tiles: Dictionary, grid_size: Vector3i, tile_grid: Vector3i, label: String) -> bool:
	var origin_tile: Dictionary = dirty_tiles.get("0:0:0", {})
	var edge_id := "%d:%d:%d" % [tile_grid.x - 1, tile_grid.y - 1, tile_grid.z - 1]
	var edge_tile: Dictionary = dirty_tiles.get(edge_id, {})
	if origin_tile.get("voxel_min", Vector3i.ONE) != Vector3i.ZERO:
		push_error("  FAIL: %s dirty origin tile should start at grid origin" % label)
		return false
	if edge_tile.get("voxel_max", Vector3i.ZERO) != grid_size:
		push_error("  FAIL: %s dirty edge tile should clip to grid_size, got %s expected %s" % [
			label,
			str(edge_tile.get("voxel_max", Vector3i.ZERO)),
			str(grid_size),
		])
		return false
	for raw_tile in dirty_tiles.values():
		if not raw_tile is Dictionary:
			push_error("  FAIL: %s dirty snapshot contained a non-dictionary tile" % label)
			return false
		var tile: Dictionary = raw_tile
		var flags: Dictionary = tile.get("dirty_flags", {})
		if not bool(flags.get("scene", false)) or not bool(flags.get("collision", false)):
			push_error("  FAIL: %s full dirty tile should preserve scene/collision flags" % label)
			return false
	return true


func _restore_scene_voxel_tile_setting(setting: String, had_setting: bool, old_value) -> void:
	if had_setting:
		ProjectSettings.set_setting(setting, old_value)
	else:
		ProjectSettings.clear(setting)
