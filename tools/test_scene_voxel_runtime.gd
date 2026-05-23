extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")
const SVR := preload("res://scripts/scene_voxel_runtime.gd")
const CHANNEL_ENTRIES_KEY := "channel_entries"


func _init() -> void:
	var ok := true
	ok = ok and _test_basic_field()
	ok = ok and _test_collision_import()
	ok = ok and _test_gpu_pipeline_integration()
	ok = ok and _test_asset_voxel_record_creation()
	ok = ok and _test_full_end_to_end()

	if ok:
		print("[SceneVoxelLocal] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[SceneVoxelLocal] SOME TESTS FAILED")
		quit(1)


func _test_basic_field() -> bool:
	print("[SceneVoxelLocal] test_basic_field...")
	var field := SVR.new(
		Vector3i(32, 8, 32),
		Vector3(0.5, 0.5, 0.5),
		Vector3(-8.0, 0.0, -8.0)
	)

	if field.grid_size != Vector3i(32, 8, 32):
		push_error("  FAIL: grid_size mismatch")
		return false

	field.fill_ground_plane(0, 1.0)

	var occupied := 0
	for z in range(32):
		for x in range(32):
			if field.get_scene(Vector3i(x, 0, z)) > 0.5:
				occupied += 1
	if occupied != 32 * 32:
		push_error("  FAIL: ground plane not filled (%d/1024)" % occupied)
		return false

	var world_pos := Vector3(-6.0, 1.5, -4.0)
	var voxel_pos := field.world_to_voxel(world_pos)
	var expected := Vector3i(
		floori((-6.0 - (-8.0)) / 0.5),
		floori(1.5 / 0.5),
		floori((-4.0 - (-8.0)) / 0.5)
	)
	if voxel_pos != expected:
		push_error("  FAIL: world_to_voxel %s != %s" % [str(voxel_pos), str(expected)])
		return false

	var back := field.voxel_to_world(voxel_pos)
	if back.distance_to(Vector3(-6.0, 1.5, -4.0)) > 0.5:
		push_error("  FAIL: voxel_to_world round-trip too far: %s" % str(back))
		return false

	var stats := field.get_stats()
	if int(stats.scene_occupied) != 32 * 32:
		push_error("  FAIL: stats scene_occupied=%d" % int(stats.scene_occupied))
		return false

	print("  OK: grid=%s ground=%d tiles=%d" % [
		str(field.grid_size), occupied, int(stats.total_tiles)])
	return true


func _test_collision_import() -> bool:
	print("[SceneVoxelLocal] test_collision_import...")
	var field := SVR.new(
		Vector3i(16, 8, 16),
		Vector3(0.5, 0.5, 0.5),
		Vector3(0.0, 0.0, 0.0)
	)

	field.set_collision(Vector3i(4, 1, 4), 0.8)
	field.set_collision(Vector3i(4, 2, 4), 0.8)
	field.set_collision(Vector3i(5, 1, 4), 0.6)

	if absf(field.get_collision(Vector3i(4, 1, 4)) - 0.8) > 0.01:
		push_error("  FAIL: collision read mismatch")
		return false

	var dirty_count := field.get_dirty_tile_count()
	if dirty_count <= 0:
		push_error("  FAIL: no dirty tiles after writes")
		return false

	field.clear_dirty()
	if field.get_dirty_tile_count() != 0:
		push_error("  FAIL: dirty tiles not cleared")
		return false

	print("  OK: collision written, dirty_tiles=%d (cleared)" % dirty_count)
	return true


func _test_gpu_pipeline_integration() -> bool:
	print("[SceneVoxelLocal] test_gpu_pipeline_integration...")
	var field := SVR.new(
		Vector3i(16, 8, 16),
		Vector3(0.5, 0.5, 0.5),
		Vector3(-4.0, 0.0, -4.0)
	)
	field.fill_ground_plane(0, 1.0)

	var generator := VPG.new()
	var asset_defs: Array = [
		{
			"collision_voxels": [
				{"shape": "cylinder", "radius": 0.45, "y_min": 0.0, "y_max": 2.0, "value": 1.0}
			],
			"result_capacity": 3,
			"min_distance_voxels": 3.0,
		},
	]
	var common_settings := {
		"top_k": 4,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
	}

	var result := field.run_placement(generator, asset_defs, common_settings)
	if result.is_empty():
		push_error("  FAIL: run_placement returned empty")
		return false

	var total := int(result.get("total_placed", 0))
	if total <= 0:
		push_error("  FAIL: no placements")
		return false

	field.apply_multi_asset_output(result)

	var stats := field.get_stats()
	if int(stats.collision_occupied) <= 0:
		push_error("  FAIL: collision not updated after apply")
		return false

	var asset_results: Array = result.get("asset_results", [])
	var world_results: Array = asset_results[0].get("world_results", [])
	if world_results.is_empty():
		push_error("  FAIL: no world results")
		return false

	var first_pos: Vector3 = world_results[0].position
	if not field.is_in_bounds(field.world_to_voxel(first_pos)):
		push_error("  FAIL: first placement out of bounds: %s" % str(first_pos))
		return false

	print("  OK: placed=%d collision_occupied=%d first_pos=%s" % [
		total, int(stats.collision_occupied), str(first_pos)])
	return true


func _test_asset_voxel_record_creation() -> bool:
	print("[SceneVoxelLocal] test_asset_voxel_record_creation...")
	var tree_mesh := VegetationScatter.create_tree_mesh()

	var world_results: Array = [
		{
			"position": Vector3(1.0, 0.5, 2.0),
			"rotation_degrees": Vector3(0.0, 45.0, 0.0),
			"rotation_y": 45.0,
			"scale": Vector3.ONE,
			"score": 7.5,
			"voxel_origin": Vector3i(10, 1, 12),
			"rotation_index": 3,
			"asset_index": 0,
		},
		{
			"position": Vector3(5.0, 0.5, 3.0),
			"rotation_degrees": Vector3(0.0, 90.0, 0.0),
			"rotation_y": 90.0,
			"scale": Vector3.ONE,
			"score": 6.2,
			"voxel_origin": Vector3i(18, 1, 14),
			"rotation_index": 6,
			"asset_index": 0,
		},
	]

	var nodes := VPG.instantiate_placements(world_results, "canopy_tree", tree_mesh, {
		"color": Color(0.3, 0.5, 0.2, 0.8),
		"complexity": 0.8,
	})

	var records := VPG.make_asset_voxel_records(world_results, nodes, {
		"id_prefix": "gpu_tree",
		"color": Color(0.3, 0.5, 0.2, 0.8),
		"complexity": 0.8,
	})

	if records.size() != 2:
		push_error("  FAIL: expected 2 records, got %d" % records.size())
		_free_nodes(nodes)
		return false

	var r0 := records[0]
	if str(r0.id) != "gpu_tree_0":
		push_error("  FAIL: record id='%s' expected 'gpu_tree_0'" % str(r0.id))
		_free_nodes(nodes)
		return false
	if str(r0.auto_source) != "voxel_placement":
		push_error("  FAIL: auto_source='%s'" % str(r0.auto_source))
		_free_nodes(nodes)
		return false
	if str(r0.source_voxel_type) != "AutoSceneVoxel":
		push_error("  FAIL: source_voxel_type='%s'" % str(r0.source_voxel_type))
		_free_nodes(nodes)
		return false
	if str(r0.producer_stage) != "voxel_placement":
		push_error("  FAIL: producer_stage='%s'" % str(r0.producer_stage))
		_free_nodes(nodes)
		return false

	var pos: Vector3 = r0.position
	if pos.distance_to(Vector3(1.0, 0.5, 2.0)) > 0.01:
		push_error("  FAIL: position mismatch %s" % str(pos))
		_free_nodes(nodes)
		return false

	if absf(float(r0.score) - 7.5) > 0.01:
		push_error("  FAIL: score=%.2f expected 7.5" % float(r0.score))
		_free_nodes(nodes)
		return false

	if not r0.has(CHANNEL_ENTRIES_KEY):
		push_error("  FAIL: missing channel_entries key")
		_free_nodes(nodes)
		return false

	print("  OK: records=%d id='%s' source='%s' score=%.1f" % [
		records.size(), r0.id, r0.auto_source, float(r0.score)])
	_free_nodes(nodes)
	return true


func _test_full_end_to_end() -> bool:
	print("[SceneVoxelLocal] test_full_end_to_end...")
	var grid_size := Vector3i(24, 8, 24)
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var grid_origin := Vector3(-6.0, 0.0, -6.0)

	var field := SVR.new(grid_size, voxel_size, grid_origin)
	field.fill_ground_plane(0, 1.0)

	var generator := VPG.new()
	var asset_defs: Array = [
		{
			"collision_voxels": [
				{"shape": "cylinder", "radius": 0.6, "y_min": 0.0, "y_max": 2.5, "value": 1.0}
			],
			"result_capacity": 2,
			"min_distance_voxels": 4.0,
		},
		{
			"collision_voxels": [
				{"shape": "cylinder", "radius": 0.3, "y_min": 0.0, "y_max": 1.0, "value": 0.8}
			],
			"result_capacity": 4,
			"min_distance_voxels": 2.0,
		},
	]
	var common_settings := {
		"top_k": 4,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
	}

	var result := field.run_placement(generator, asset_defs, common_settings)
	field.apply_multi_asset_output(result)

	var total := int(result.get("total_placed", 0))
	if total <= 0:
		push_error("  FAIL: no placements")
		return false

	var asset_results: Array = result.get("asset_results", [])
	var tree_world: Array = asset_results[0].get("world_results", [])
	var bush_world: Array = asset_results[1].get("world_results", [])

	var tree_mesh := VegetationScatter.create_tree_mesh()
	var bush_mesh := VegetationScatter.create_bush_mesh()
	var tree_nodes := VPG.instantiate_placements(tree_world, "canopy_tree", tree_mesh, {
		"color": Color(0.3, 0.5, 0.2, 0.8), "complexity": 0.8,
	})
	var bush_nodes := VPG.instantiate_placements(bush_world, "bush", bush_mesh, {
		"color": Color(0.4, 0.6, 0.1, 0.6), "complexity": 0.6,
	})

	var tree_records := VPG.make_asset_voxel_records(tree_world, tree_nodes, {
		"id_prefix": "gpu_canopy", "type": "canopy_tree",
		"color": Color(0.3, 0.5, 0.2, 0.8), "complexity": 0.8,
	})
	var bush_records := VPG.make_asset_voxel_records(bush_world, bush_nodes, {
		"id_prefix": "gpu_bush", "type": "bush",
		"color": Color(0.4, 0.6, 0.1, 0.6), "complexity": 0.6,
	})

	var all_nodes_count := tree_nodes.size() + bush_nodes.size()
	var all_records_count := tree_records.size() + bush_records.size()

	if all_nodes_count != total:
		push_error("  FAIL: nodes=%d != total_placed=%d" % [all_nodes_count, total])
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	if all_records_count != total:
		push_error("  FAIL: records=%d != total_placed=%d" % [all_records_count, total])
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	for record in tree_records:
		if str(record.producer_stage) != "voxel_placement":
			push_error("  FAIL: record producer_stage != voxel_placement")
			_free_nodes(tree_nodes)
			_free_nodes(bush_nodes)
			return false

	var stats := field.get_stats()
	print("  OK: total=%d trees=%d bushes=%d records=%d collision_occ=%s" % [
		total, tree_nodes.size(), bush_nodes.size(),
		all_records_count, str(stats.collision_pct)])
	_free_nodes(tree_nodes)
	_free_nodes(bush_nodes)
	return true


func _free_nodes(nodes: Array) -> void:
	for node in nodes:
		if node is Node and is_instance_valid(node):
			node.free()
