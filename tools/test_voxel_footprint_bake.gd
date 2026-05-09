extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")
const FLAG_SUPPORT := 1
const FLAG_CLEARANCE := 2


func _init() -> void:
	var ok := true
	ok = ok and _test_bake_cylinder()
	ok = ok and _test_bake_rotation()
	ok = ok and _test_bake_rotated_set()
	ok = ok and _test_full_pipeline()
	ok = ok and _test_results_to_world()

	if ok:
		print("[VoxelFootprintBake] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[VoxelFootprintBake] SOME TESTS FAILED")
		quit(1)


func _test_bake_cylinder() -> bool:
	print("[VoxelFootprintBake] test_bake_cylinder...")
	var collision_voxels: Array = [
		{
			"shape": "cylinder",
			"radius": 0.5,
			"y_min": 0.0,
			"y_max": 2.0,
			"value": 1.0,
		}
	]
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var footprint := VPG.bake_footprint_from_collision_voxels(
		collision_voxels, voxel_size, true, 1)

	if footprint.is_empty():
		push_error("  FAIL: footprint is empty")
		return false

	var has_support := false
	var has_clearance := false
	var has_solid := false
	for entry in footprint:
		var flags := int(entry.flags)
		var degree := int(entry.collision_degree)
		if flags & FLAG_SUPPORT:
			has_support = true
		if flags & FLAG_CLEARANCE:
			has_clearance = true
		if degree >= 192:
			has_solid = true

	if not has_support:
		push_error("  FAIL: no support voxels found")
		return false
	if not has_clearance:
		push_error("  FAIL: no clearance voxels found")
		return false
	if not has_solid:
		push_error("  FAIL: no solid collision voxels found")
		return false

	print("  OK: %d voxels (support=%s clearance=%s solid=%s)" % [
		footprint.size(), has_support, has_clearance, has_solid])
	return true


func _test_bake_rotation() -> bool:
	print("[VoxelFootprintBake] test_bake_rotation...")
	var footprint: Array[Dictionary] = [
		{"local_pos": Vector3i(2, 0, 0), "collision_degree": 255, "flags": FLAG_SUPPORT, "weight": 1.0},
		{"local_pos": Vector3i(2, 1, 0), "collision_degree": 255, "flags": 0, "weight": 1.0},
	]

	var rotated_90 := VPG.rotate_footprint_y(footprint, 90.0)
	if rotated_90.is_empty():
		push_error("  FAIL: rotated footprint is empty")
		return false

	var found_rotated := false
	for entry in rotated_90:
		var pos: Vector3i = entry.local_pos
		if pos.x == 0 and pos.z == 2 and pos.y == 0:
			found_rotated = true
			break
		if pos.x == 0 and pos.z == -2 and pos.y == 0:
			found_rotated = true
			break

	if not found_rotated:
		var positions := []
		for entry in rotated_90:
			positions.append(entry.local_pos)
		push_error("  FAIL: expected (2,0,0) rotated 90° around Y, got %s" % str(positions))
		return false

	var identity := VPG.rotate_footprint_y(footprint, 0.0)
	if identity.size() != footprint.size():
		push_error("  FAIL: identity rotation changed count")
		return false

	print("  OK: 90° rotation correct, identity preserved")
	return true


func _test_bake_rotated_set() -> bool:
	print("[VoxelFootprintBake] test_bake_rotated_set...")
	var collision_voxels: Array = [
		{"shape": "cylinder", "radius": 0.3, "y_min": 0.0, "y_max": 1.0, "value": 1.0}
	]
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var rotations := VPG.bake_rotated_footprints(collision_voxels, voxel_size, 24, true, 1)

	if rotations.size() != 24:
		push_error("  FAIL: expected 24 rotations, got %d" % rotations.size())
		return false

	for i in range(24):
		var fp: Array = rotations[i]
		if fp.is_empty():
			push_error("  FAIL: rotation %d produced empty footprint" % i)
			return false

	print("  OK: 24 rotations, each non-empty")
	return true


func _test_full_pipeline() -> bool:
	print("[VoxelFootprintBake] test_full_pipeline...")
	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var voxel_size := Vector3(0.5, 0.5, 0.5)

	var generator := VPG.new()
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var collision_voxels: Array = [
		{"shape": "cylinder", "radius": 0.45, "y_min": 0.0, "y_max": 2.0, "value": 1.0}
	]
	var footprint := VPG.bake_footprint_from_collision_voxels(
		collision_voxels, voxel_size, true, 1)

	if footprint.is_empty():
		push_error("  FAIL: baked footprint is empty")
		return false

	var settings := {
		"top_k": 4,
		"result_capacity": 4,
		"min_distance_voxels": 3.0,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
	}

	var result := generator.run_minimal(scene, collision, footprint, grid_size, settings)
	if result.is_empty():
		push_error("  FAIL: run_minimal returned empty")
		return false

	var count := int(result.get("result_count", 0))
	if count <= 0:
		push_error("  FAIL: no placements found")
		return false

	var results: Array = result.get("results", [])
	var first: Dictionary = results[0]
	if not bool(first.get("valid", false)):
		push_error("  FAIL: first placement not valid")
		return false

	var stamped_collision: PackedFloat32Array = result.get("collision_occupancy_out", PackedFloat32Array())
	var first_origin: Vector3i = first.voxel_origin
	var any_collision_written := false
	for entry in footprint:
		var degree := int(entry.collision_degree)
		if degree < 192:
			continue
		var pos: Vector3i = entry.local_pos
		var world_pos := first_origin + pos
		if world_pos.x < 0 or world_pos.x >= grid_size.x:
			continue
		if world_pos.y < 0 or world_pos.y >= grid_size.y:
			continue
		if world_pos.z < 0 or world_pos.z >= grid_size.z:
			continue
		var idx := generator.voxel_index(world_pos, grid_size)
		if stamped_collision[idx] > 0.01:
			any_collision_written = true
			break

	if not any_collision_written:
		push_error("  FAIL: stamp did not write collision for baked footprint")
		return false

	var second := generator.run_minimal(
		result.get("scene_occupancy_out", PackedFloat32Array()),
		result.get("collision_occupancy_out", PackedFloat32Array()),
		footprint, grid_size, settings)
	var second_count := int(second.get("result_count", 0))
	if second_count <= 0:
		push_error("  FAIL: second round found no placements")
		return false

	var second_origin: Vector3i = (second.get("results", []) as Array)[0].get("voxel_origin", Vector3i.ZERO)
	if second_origin == first_origin:
		push_error("  FAIL: second round placed at same origin as first")
		return false

	print("  OK: footprint=%d first=%s second=%s rounds=2" % [
		footprint.size(), str(first_origin), str(second_origin)])
	return true


func _test_results_to_world() -> bool:
	print("[VoxelFootprintBake] test_results_to_world...")
	var voxel_size := Vector3(0.5, 1.0, 0.5)
	var grid_origin := Vector3(-10.0, 0.0, -10.0)

	var mock_results: Array[Dictionary] = [
		{
			"voxel_origin": Vector3i(4, 2, 6),
			"score": 8.5,
			"valid": true,
			"rotation_index": 6,
			"scale_index": 0,
			"asset_index": 0,
			"support_ratio": 1.0,
			"solid_collision": 0.0,
			"scene_overlap": 0.0,
			"clearance_overlap": 0.0,
			"ignored_sample": 0.0,
		},
		{
			"voxel_origin": Vector3i(10, 1, 3),
			"score": -1.0,
			"valid": false,
			"rotation_index": 0,
			"scale_index": 0,
			"asset_index": 0,
			"support_ratio": 0.0,
			"solid_collision": 5.0,
			"scene_overlap": 0.0,
			"clearance_overlap": 0.0,
			"ignored_sample": 0.0,
		},
	]

	var world := VPG.results_to_world(mock_results, voxel_size, grid_origin, 24)

	if world.size() != 1:
		push_error("  FAIL: expected 1 valid result, got %d" % world.size())
		return false

	var w: Dictionary = world[0]
	var expected_pos := grid_origin + Vector3(4.0 * 0.5, 2.0 * 1.0, 6.0 * 0.5)
	var pos: Vector3 = w.position
	if pos.distance_to(expected_pos) > 0.01:
		push_error("  FAIL: position %s != expected %s" % [str(pos), str(expected_pos)])
		return false

	var expected_yaw := 6.0 * 360.0 / 24.0
	var yaw := float(w.rotation_y)
	if absf(yaw - expected_yaw) > 0.1:
		push_error("  FAIL: yaw %.1f != expected %.1f" % [yaw, expected_yaw])
		return false

	print("  OK: position=%s yaw=%.1f (filtered invalid)" % [str(pos), yaw])
	return true
