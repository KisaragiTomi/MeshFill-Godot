extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")
const SVR := preload("res://scripts/scene_voxel_runtime.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_tile_id_roundtrip()
	ok = ok and _test_dirty_tile_tracking()
	ok = ok and _test_apply_stamp_deltas()
	ok = ok and _test_run_placement_dirty()
	ok = ok and _test_dirty_cleared_after_placement()
	ok = ok and _test_no_dirty_returns_empty()

	if ok:
		print("[VoxelDirtyTile] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[VoxelDirtyTile] SOME TESTS FAILED")
		quit(1)


func _test_tile_id_roundtrip() -> bool:
	print("[VoxelDirtyTile] test_tile_id_roundtrip...")
	var field := SVR.new(Vector3i(32, 16, 32), Vector3(0.5, 0.5, 0.5))
	var tile_grid := Vector3i(
		ceili(32.0 / 8.0),
		ceili(16.0 / 8.0),
		ceili(32.0 / 8.0),
	)
	var total := tile_grid.x * tile_grid.y * tile_grid.z
	for i in range(total):
		var pos := field.tile_id_to_pos(i)
		var back := field.tile_pos_to_id(pos)
		if back != i:
			push_error("  FAIL: tile_id %d -> pos %s -> id %d" % [i, pos, back])
			return false
	print("  OK: %d tile IDs roundtrip correctly" % total)
	return true


func _test_dirty_tile_tracking() -> bool:
	print("[VoxelDirtyTile] test_dirty_tile_tracking...")
	var field := SVR.new(Vector3i(16, 8, 16), Vector3(0.5, 0.5, 0.5))

	if field.get_dirty_tile_count() != 0:
		push_error("  FAIL: expected 0 dirty tiles initially")
		return false

	field.set_scene(Vector3i(0, 0, 0), 1.0)
	field.set_scene(Vector3i(1, 0, 1), 1.0)
	if field.get_dirty_tile_count() != 1:
		push_error("  FAIL: expected 1 dirty tile after writing same tile")
		return false

	field.set_scene(Vector3i(9, 0, 0), 1.0)
	if field.get_dirty_tile_count() != 2:
		push_error("  FAIL: expected 2 dirty tiles after writing different tile")
		return false

	var positions := field.get_dirty_tile_positions()
	if positions.size() != 2:
		push_error("  FAIL: expected 2 dirty tile positions, got %d" % positions.size())
		return false

	field.clear_dirty()
	if field.get_dirty_tile_count() != 0:
		push_error("  FAIL: expected 0 dirty tiles after clear")
		return false

	print("  OK: dirty tile tracking works")
	return true


func _test_apply_stamp_deltas() -> bool:
	print("[VoxelDirtyTile] test_apply_stamp_deltas...")
	var field := SVR.new(Vector3i(16, 8, 16), Vector3(0.5, 0.5, 0.5))

	var deltas: Array = [
		{"voxel": Vector3i(2, 1, 3), "scene_value": 0.5, "collision_value": 0.8},
		{"voxel": Vector3i(5, 0, 7), "scene_value": 0.0, "collision_value": 1.0},
		{"voxel": Vector3i(-1, 0, 0), "scene_value": 1.0, "collision_value": 1.0},
	]

	var count := field.apply_stamp_deltas(deltas)
	if count != 2:
		push_error("  FAIL: expected 2 applied deltas, got %d" % count)
		return false

	var s1 := field.get_scene(Vector3i(2, 1, 3))
	var c1 := field.get_collision(Vector3i(2, 1, 3))
	if absf(s1 - 0.5) > 0.01 or absf(c1 - 0.8) > 0.01:
		push_error("  FAIL: voxel (2,1,3) scene=%.2f collision=%.2f" % [s1, c1])
		return false

	var c2 := field.get_collision(Vector3i(5, 0, 7))
	if absf(c2 - 1.0) > 0.01:
		push_error("  FAIL: voxel (5,0,7) collision=%.2f expected 1.0" % c2)
		return false

	var s2 := field.get_scene(Vector3i(5, 0, 7))
	if s2 > 0.01:
		push_error("  FAIL: voxel (5,0,7) scene=%.2f should be 0" % s2)
		return false

	if field.get_dirty_tile_count() < 1:
		push_error("  FAIL: expected dirty tiles after applying deltas")
		return false

	print("  OK: stamp deltas applied correctly")
	return true


func _test_run_placement_dirty() -> bool:
	print("[VoxelDirtyTile] test_run_placement_dirty...")
	var grid_size := Vector3i(16, 8, 16)
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var field := SVR.new(grid_size, voxel_size)

	for z in range(grid_size.z):
		for x in range(grid_size.x):
			field.set_scene(Vector3i(x, 0, z), 1.0)

	var dirty_before := field.get_dirty_tile_count()
	if dirty_before <= 0:
		push_error("  FAIL: expected dirty tiles after filling ground")
		return false

	var asset_defs: Array = [
		{
			"collision_voxels": [
				{"shape": "cylinder", "radius": 0.45, "y_min": 0.0, "y_max": 2.0, "value": 1.0}
			],
			"result_capacity": 2,
			"min_distance_voxels": 3.0,
		},
	]

	var common_settings := {
		"top_k": 4,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
	}

	var generator := VPG.new()
	var result := field.run_placement_dirty(
		generator, asset_defs, common_settings, true, true)

	if result.is_empty():
		push_error("  FAIL: run_placement_dirty returned empty")
		return false

	var total := int(result.get("total_placed", 0))
	if total <= 0:
		push_error("  FAIL: no placements from dirty tiles")
		return false

	var dirty_count := int(result.get("dirty_tile_count", 0))
	if dirty_count <= 0:
		push_error("  FAIL: dirty_tile_count should be > 0 in result")
		return false

	var asset_results: Array = result.get("asset_results", [])
	if asset_results.is_empty():
		push_error("  FAIL: no asset_results")
		return false

	var a0: Dictionary = asset_results[0]
	var stamp_deltas: Array = a0.get("stamp_deltas", [])
	if stamp_deltas.is_empty():
		push_error("  FAIL: no stamp deltas from dirty tile placement")
		return false

	print("  OK: dirty_tiles=%d placed=%d deltas=%d" % [
		dirty_count, total, stamp_deltas.size()])
	return true


func _test_dirty_cleared_after_placement() -> bool:
	print("[VoxelDirtyTile] test_dirty_cleared_after_placement...")
	var grid_size := Vector3i(16, 8, 16)
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var field := SVR.new(grid_size, voxel_size)

	field.set_scene(Vector3i(0, 0, 0), 1.0)
	field.set_scene(Vector3i(1, 0, 1), 1.0)
	var dirty_before := field.get_dirty_tile_count()

	var asset_defs: Array = [
		{
			"collision_voxels": [
				{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 0.8}
			],
			"result_capacity": 1,
			"min_distance_voxels": 2.0,
		},
	]

	var generator := VPG.new()
	var result := field.run_placement_dirty(
		generator, asset_defs,
		{"top_k": 2, "collision_limit": 0.0, "min_support_ratio": 1.0, "clearance_limit": 100.0},
		false, true)

	if result.is_empty():
		push_error("  FAIL: run_placement_dirty returned empty")
		return false

	var dirty_after := field.get_dirty_tile_count()
	if dirty_after >= dirty_before:
		push_error("  FAIL: dirty tiles not cleared (before=%d after=%d)" % [dirty_before, dirty_after])
		return false

	print("  OK: dirty_before=%d dirty_after=%d" % [dirty_before, dirty_after])
	return true


func _test_no_dirty_returns_empty() -> bool:
	print("[VoxelDirtyTile] test_no_dirty_returns_empty...")
	var field := SVR.new(Vector3i(16, 8, 16), Vector3(0.5, 0.5, 0.5))

	var generator := VPG.new()
	var result := field.run_placement_dirty(generator, [], {})

	if result.is_empty():
		push_error("  FAIL: expected non-empty result with zero placements")
		return false

	var total := int(result.get("total_placed", 0))
	if total != 0:
		push_error("  FAIL: expected 0 placements when no dirty tiles")
		return false

	print("  OK: no dirty tiles returns empty placement set")
	return true
