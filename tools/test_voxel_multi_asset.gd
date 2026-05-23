extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_multi_asset_pipeline()
	ok = ok and _test_instantiate_placements()
	ok = ok and _test_instantiate_placement_asset_voxel_record_commit()
	ok = ok and _test_multi_asset_collision_avoidance()

	if ok:
		print("[VoxelMultiAsset] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[VoxelMultiAsset] SOME TESTS FAILED")
		quit(1)


func _test_multi_asset_pipeline() -> bool:
	print("[VoxelMultiAsset] test_multi_asset_pipeline...")
	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var grid_origin := Vector3(-4.0, 0.0, -4.0)

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
			"collision_voxels": [
				{"shape": "cylinder", "radius": 0.45, "y_min": 0.0, "y_max": 2.0, "value": 1.0}
			],
			"result_capacity": 3,
			"min_distance_voxels": 3.0,
		},
		{
			"collision_voxels": [
				{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 0.8}
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

	var result := generator.run_multi_asset(
		scene, collision, asset_defs, grid_size, voxel_size, grid_origin, common_settings)

	if result.is_empty():
		push_error("  FAIL: run_multi_asset returned empty")
		return false

	var asset_results: Array = result.get("asset_results", [])
	if asset_results.size() != 2:
		push_error("  FAIL: expected 2 asset results, got %d" % asset_results.size())
		return false

	var total := int(result.get("total_placed", 0))
	if total <= 0:
		push_error("  FAIL: no placements at all")
		return false

	var a0: Dictionary = asset_results[0]
	var a1: Dictionary = asset_results[1]
	var a0_count := int(a0.get("result_count", 0))
	var a1_count := int(a1.get("result_count", 0))

	if a0_count <= 0:
		push_error("  FAIL: asset 0 has no placements")
		return false
	if a1_count <= 0:
		push_error("  FAIL: asset 1 has no placements")
		return false

	var a0_world: Array = a0.get("world_results", [])
	var a1_world: Array = a1.get("world_results", [])
	if a0_world.is_empty() or a1_world.is_empty():
		push_error("  FAIL: world results missing")
		return false

	print("  OK: asset0=%d asset1=%d total=%d world0=%d world1=%d" % [
		a0_count, a1_count, total, a0_world.size(), a1_world.size()])
	return true


func _test_instantiate_placements() -> bool:
	print("[VoxelMultiAsset] test_instantiate_placements...")
	var tree_mesh := VegetationScatter.create_tree_mesh()
	var bush_mesh := VegetationScatter.create_bush_mesh()

	var tree_results: Array = [
		{
			"position": Vector3(1.0, 0.5, 2.0),
			"rotation_degrees": Vector3(0.0, 45.0, 0.0),
			"scale": Vector3.ONE,
			"asset_index": 0,
		},
		{
			"position": Vector3(5.0, 0.5, 3.0),
			"rotation_degrees": Vector3(0.0, 90.0, 0.0),
			"scale": Vector3.ONE,
			"asset_index": 0,
		},
	]

	var bush_results: Array = [
		{
			"position": Vector3(3.0, 0.3, 1.0),
			"rotation_degrees": Vector3(0.0, 15.0, 0.0),
			"scale": Vector3.ONE * 0.8,
			"asset_index": 1,
		},
	]

	var tree_config := {
		"color": Color(0.25, 0.50, 0.20, 0.8),
		"complexity": 0.8,
		"visual_layer": VegetationScatter.TREE_VISUAL_LAYER,
	}

	var tree_nodes := VPG.instantiate_placements(tree_results, "canopy_tree", tree_mesh, tree_config)
	var bush_nodes := VPG.instantiate_placements(bush_results, "bush", bush_mesh)

	if tree_nodes.size() != 2:
		push_error("  FAIL: expected 2 tree nodes, got %d" % tree_nodes.size())
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	if bush_nodes.size() != 1:
		push_error("  FAIL: expected 1 bush node, got %d" % bush_nodes.size())
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	var t0: AutoObject = tree_nodes[0]
	if not t0 is AutoCanopyTree:
		push_error("  FAIL: tree node is not AutoCanopyTree")
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	if t0.position.distance_to(Vector3(1.0, 0.5, 2.0)) > 0.01:
		push_error("  FAIL: tree position mismatch: %s" % str(t0.position))
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	if t0.mesh == null:
		push_error("  FAIL: tree has no mesh")
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	var b0: AutoObject = bush_nodes[0]
	if not b0 is AutoBush:
		push_error("  FAIL: bush node is not AutoBush")
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	if b0.object_subtype != "bush":
		push_error("  FAIL: bush subtype is '%s'" % b0.object_subtype)
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	print("  OK: trees=%d bushes=%d type=%s subtype=%s pos=%s" % [
		tree_nodes.size(), bush_nodes.size(),
		t0.get_class(), b0.object_subtype, str(t0.position)])
	_free_nodes(tree_nodes)
	_free_nodes(bush_nodes)
	return true


func _test_instantiate_placement_asset_voxel_record_commit() -> bool:
	print("[VoxelMultiAsset] test_instantiate_placement_asset_voxel_record_commit...")
	var mesh := VegetationScatter.create_bush_mesh()
	var veg := SceneVoxelCommitter.new(32, 32.0, false)

	var world_result := {
		"position": Vector3(0.0, 0.5, 0.0),
		"rotation_degrees": Vector3(0.0, 30.0, 0.0),
		"scale": Vector3.ONE,
		"asset_index": 2,
		"rotation_index": 2,
		"voxel_origin": Vector3i(8, 1, 8),
		"score": 7.5,
	}

	var node := VPG.instantiate_placement(world_result, "bush", mesh, {
		"name": "VoxelBushRecord_0",
		"record_id": "voxel_bush_record_0",
		"create_asset_voxel_record": true,
		"vegetation_exclusion": veg,
		"capture_size": 32.0,
		"volume_xz_resolution": 32,
	})

	if node == null:
		push_error("  FAIL: node was not created")
		return false
	if not node.has_meta("voxel_write_spec"):
		push_error("  FAIL: node has no voxel_write_spec metadata")
		node.free()
		return false

	var record: Dictionary = node.get_meta("voxel_write_spec")
	if str(record.get("id", "")) != "voxel_bush_record_0":
		push_error("  FAIL: wrong record id: %s" % str(record.get("id", "")))
		node.free()
		return false
	if str(record.get("producer_stage", "")) != "voxel_placement":
		push_error("  FAIL: producer_stage was not preserved")
		node.free()
		return false
	if record.get("base_pixel", Vector2i(-1, -1)) != Vector2i(16, 16):
		push_error("  FAIL: base_pixel mismatch: %s" % str(record.get("base_pixel", Vector2i(-1, -1))))
		node.free()
		return false

	veg.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.2, 0.8, 0.2, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 0.3, "subdivisions": 1},
		{"channel": 1, "color": Color(0.8, 0.6, 0.2, 0.8), "complexity": 0.8, "y_min": 0.3, "y_max": 2.0, "subdivisions": 1},
	])
	var scene_voxels := veg.get_scene_voxels()
	if scene_voxels.is_empty():
		push_error("  FAIL: expected committed SceneVoxel entries")
		node.free()
		return false
	var has_auto_scene_voxel := false
	for scene_voxel in scene_voxels.values():
		if scene_voxel is Dictionary and str((scene_voxel as Dictionary).get("source_type", "")) == "AutoSceneVoxel":
			has_auto_scene_voxel = true
			break
	if not has_auto_scene_voxel:
		push_error("  FAIL: expected AutoSceneVoxel committed SceneVoxel entries")
		node.free()
		return false

	print("  OK: record=%s scene_voxels=%d commit_tick=%d" % [
		str(record.id),
		scene_voxels.size(),
		veg.get_committed_tick(),
	])
	node.free()
	return true


func _test_multi_asset_collision_avoidance() -> bool:
	print("[VoxelMultiAsset] test_multi_asset_collision_avoidance...")
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

	var large_cylinder := {
		"collision_voxels": [
			{"shape": "cylinder", "radius": 1.5, "y_min": 0.0, "y_max": 3.0, "value": 1.0}
		],
		"result_capacity": 2,
		"min_distance_voxels": 4.0,
	}
	var small_cylinder := {
		"collision_voxels": [
			{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 1.0}
		],
		"result_capacity": 4,
		"min_distance_voxels": 2.0,
	}

	var common_settings := {
		"top_k": 4,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
	}

	var result := generator.run_multi_asset(
		scene, collision, [large_cylinder, small_cylinder],
		grid_size, voxel_size, Vector3.ZERO, common_settings)

	var asset_results: Array = result.get("asset_results", [])
	var large_results: Array = asset_results[0].get("world_results", [])
	var small_results: Array = asset_results[1].get("world_results", [])

	for large_wr in large_results:
		var large_pos: Vector3 = large_wr.position
		for small_wr in small_results:
			var small_pos: Vector3 = small_wr.position
			var dist := large_pos.distance_to(small_pos)
			if dist < 0.5:
				push_error("  FAIL: small object placed on top of large at distance %.2f" % dist)
				return false

	print("  OK: large=%d small=%d (no collision overlap)" % [
		large_results.size(), small_results.size()])
	return true


func _free_nodes(nodes: Array) -> void:
	for node in nodes:
		if node is Node and is_instance_valid(node):
			node.free()
