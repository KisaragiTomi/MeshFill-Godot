extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_priority_order()
	ok = ok and _test_weight_shuffle_seeded()
	ok = ok and _test_global_quota()
	ok = ok and _test_global_quota_caps_per_asset()
	ok = ok and _test_priority_with_gpu_pipeline()

	if ok:
		print("[VoxelAssetPriority] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[VoxelAssetPriority] SOME TESTS FAILED")
		quit(1)


# ---- CPU-only tests for sorting logic ----

func _test_priority_order() -> bool:
	print("[VoxelAssetPriority] test_priority_order...")
	var asset_defs: Array = [
		{"priority": 0, "collision_voxels": [{"shape": "cylinder", "radius": 0.2, "y_min": 0.0, "y_max": 1.0, "value": 1.0}]},
		{"priority": 10, "collision_voxels": [{"shape": "cylinder", "radius": 0.2, "y_min": 0.0, "y_max": 1.0, "value": 1.0}]},
		{"priority": 5, "collision_voxels": [{"shape": "cylinder", "radius": 0.2, "y_min": 0.0, "y_max": 1.0, "value": 1.0}]},
	]
	var order: Array[int] = VPG._sort_asset_defs_by_priority_weight(asset_defs, {})
	if order.size() != 3:
		push_error("  FAIL: expected 3 entries, got %d" % order.size())
		return false
	if order[0] != 1:
		push_error("  FAIL: highest priority (index 1, priority 10) should be first, got index %d" % order[0])
		return false
	if order[1] != 2:
		push_error("  FAIL: second should be index 2 (priority 5), got index %d" % order[1])
		return false
	if order[2] != 0:
		push_error("  FAIL: last should be index 0 (priority 0), got index %d" % order[2])
		return false
	print("  OK: order=%s" % [order])
	return true


func _test_weight_shuffle_seeded() -> bool:
	print("[VoxelAssetPriority] test_weight_shuffle_seeded...")
	var asset_defs: Array = [
		{"priority": 0, "weight": 1.0, "collision_voxels": [{"shape": "cylinder", "radius": 0.2, "y_min": 0.0, "y_max": 1.0, "value": 1.0}]},
		{"priority": 0, "weight": 100.0, "collision_voxels": [{"shape": "cylinder", "radius": 0.2, "y_min": 0.0, "y_max": 1.0, "value": 1.0}]},
		{"priority": 0, "weight": 1.0, "collision_voxels": [{"shape": "cylinder", "radius": 0.2, "y_min": 0.0, "y_max": 1.0, "value": 1.0}]},
	]

	var order_a: Array[int] = VPG._sort_asset_defs_by_priority_weight(asset_defs, {"seed": 42})
	var order_b: Array[int] = VPG._sort_asset_defs_by_priority_weight(asset_defs, {"seed": 42})
	if order_a != order_b:
		push_error("  FAIL: same seed should produce same order: %s vs %s" % [order_a, order_b])
		return false

	var first_counts := {0: 0, 1: 0, 2: 0}
	for seed_val in range(100):
		var o: Array[int] = VPG._sort_asset_defs_by_priority_weight(asset_defs, {"seed": seed_val})
		first_counts[o[0]] += 1

	var high_weight_first: int = first_counts[1]
	if high_weight_first < 50:
		push_error("  FAIL: weight=100 asset should be first most of the time, got %d/100" % high_weight_first)
		return false

	print("  OK: seeded=%s weight_100_first=%d/100" % [order_a, high_weight_first])
	return true


func _test_global_quota() -> bool:
	print("[VoxelAssetPriority] test_global_quota...")
	var grid_size := Vector3i(16, 8, 16)
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z

	var generator := VPG.new()
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var asset_defs: Array = [
		{
			"collision_voxels": [{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 1.0}],
			"result_capacity": 10,
			"min_distance_voxels": 2.0,
		},
		{
			"collision_voxels": [{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 0.8}],
			"result_capacity": 10,
			"min_distance_voxels": 2.0,
		},
	]

	var result := generator.run_multi_asset(
		scene, collision, asset_defs, grid_size, voxel_size, Vector3.ZERO,
		{"top_k": 4, "collision_limit": 0.0, "min_support_ratio": 1.0,
		 "clearance_limit": 0.0, "global_quota": 3})

	if result.is_empty():
		push_error("  FAIL: run_multi_asset returned empty")
		return false

	var total := int(result.get("total_placed", 0))
	if total > 3:
		push_error("  FAIL: global_quota=3 but total_placed=%d" % total)
		return false
	if total <= 0:
		push_error("  FAIL: expected at least 1 placement, got %d" % total)
		return false

	print("  OK: total_placed=%d (quota=3)" % total)
	return true


func _test_global_quota_caps_per_asset() -> bool:
	print("[VoxelAssetPriority] test_global_quota_caps_per_asset...")
	var grid_size := Vector3i(16, 8, 16)
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z

	var generator := VPG.new()
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var asset_defs: Array = [
		{
			"priority": 10,
			"collision_voxels": [{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 1.0}],
			"result_capacity": 10,
			"min_distance_voxels": 2.0,
		},
		{
			"priority": 0,
			"collision_voxels": [{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 0.8}],
			"result_capacity": 10,
			"min_distance_voxels": 2.0,
		},
	]

	var result := generator.run_multi_asset(
		scene, collision, asset_defs, grid_size, voxel_size, Vector3.ZERO,
		{"top_k": 4, "collision_limit": 0.0, "min_support_ratio": 1.0,
		 "clearance_limit": 0.0, "global_quota": 2})

	if result.is_empty():
		push_error("  FAIL: empty result")
		return false

	var total := int(result.get("total_placed", 0))
	var order: Array = result.get("processing_order", [])
	var a0_count := int(result.asset_results[0].get("result_count", 0))
	var a1_count := int(result.asset_results[1].get("result_count", 0))
	var a1_skipped := bool(result.asset_results[1].get("skipped_quota", false))

	if order.is_empty():
		push_error("  FAIL: no processing_order")
		return false
	if order[0] != 0:
		push_error("  FAIL: priority 10 asset (index 0) should be processed first, order=%s" % [order])
		return false
	if total > 2:
		push_error("  FAIL: quota=2 but total=%d" % total)
		return false

	print("  OK: order=%s a0=%d a1=%d total=%d skipped_a1=%s" % [
		order, a0_count, a1_count, total, a1_skipped])
	return true


func _test_priority_with_gpu_pipeline() -> bool:
	print("[VoxelAssetPriority] test_priority_with_gpu_pipeline...")
	var grid_size := Vector3i(16, 8, 16)
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z

	var generator := VPG.new()
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var asset_defs: Array = [
		{
			"priority": 0,
			"collision_voxels": [{"shape": "cylinder", "radius": 0.45, "y_min": 0.0, "y_max": 2.0, "value": 1.0}],
			"result_capacity": 3,
			"min_distance_voxels": 3.0,
		},
		{
			"priority": 5,
			"collision_voxels": [{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 0.8}],
			"result_capacity": 4,
			"min_distance_voxels": 2.0,
		},
	]

	var result := generator.run_multi_asset(
		scene, collision, asset_defs, grid_size, voxel_size, Vector3.ZERO,
		{"top_k": 4, "collision_limit": 0.0, "min_support_ratio": 1.0,
		 "clearance_limit": 0.0, "seed": 123})

	if result.is_empty():
		push_error("  FAIL: empty result")
		return false

	var order: Array = result.get("processing_order", [])
	if order.is_empty() or order[0] != 1:
		push_error("  FAIL: priority 5 (index 1) should be first, order=%s" % [order])
		return false

	var total := int(result.get("total_placed", 0))
	if total <= 0:
		push_error("  FAIL: no placements")
		return false

	var a0_count := int(result.asset_results[0].get("result_count", 0))
	var a1_count := int(result.asset_results[1].get("result_count", 0))

	print("  OK: order=%s total=%d a0=%d a1=%d" % [order, total, a0_count, a1_count])
	return true
