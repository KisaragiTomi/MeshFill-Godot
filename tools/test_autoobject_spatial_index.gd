extends SceneTree


func _init() -> void:
	var ok := true
	ok = ok and _test_cell_registration_and_radius_query()
	ok = ok and _test_unregister_and_rebuild()
	if ok:
		print("[AutoObjectSpatialIndex] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[AutoObjectSpatialIndex] SOME TESTS FAILED")
		quit(1)


func _test_cell_registration_and_radius_query() -> bool:
	print("[AutoObjectSpatialIndex] test_cell_registration_and_radius_query...")
	var manager := AutoObjectManager.new()
	manager.configure_spatial_index(4.0)

	var tree := _make_object("tree_a", Vector3(1.0, 0.0, 1.0), 2.0)
	var bush := _make_object("bush_a", Vector3(7.5, 0.0, 1.0), 0.6)
	manager.register_object(tree, {"id": "tree_a", "min_spacing": 2.0})
	manager.register_object(bush, {"id": "bush_a", "min_spacing": 0.6})

	var origin_cell := manager.world_to_cell(Vector3(1.0, 0.0, 1.0))
	var cell_objects := manager.get_objects_in_cell(origin_cell)
	if cell_objects.find(tree) < 0:
		push_error("  FAIL: tree not indexed in origin cell")
		_free_objects([tree, bush, manager])
		return false

	var near_objects := manager.query_objects_in_radius(Vector3(3.2, 0.0, 1.0), 1.0)
	if near_objects.find(tree) < 0:
		push_error("  FAIL: query should include tree by object radius overlap")
		_free_objects([tree, bush, manager])
		return false
	if near_objects.find(bush) >= 0:
		push_error("  FAIL: query should not include distant bush")
		_free_objects([tree, bush, manager])
		return false

	var far_objects := manager.query_objects_in_radius(Vector3(7.0, 0.0, 1.0), 1.0)
	if far_objects.find(bush) < 0:
		push_error("  FAIL: query should include nearby bush")
		_free_objects([tree, bush, manager])
		return false

	var stats := manager.get_spatial_stats()
	if int(stats.get("object_count", 0)) != 2:
		push_error("  FAIL: expected 2 indexed objects")
		_free_objects([tree, bush, manager])
		return false

	print("  OK: cells=%d objects=%d" % [int(stats.cell_count), int(stats.object_count)])
	_free_objects([tree, bush, manager])
	return true


func _test_unregister_and_rebuild() -> bool:
	print("[AutoObjectSpatialIndex] test_unregister_and_rebuild...")
	var manager := AutoObjectManager.new()
	manager.configure_spatial_index(4.0)

	var tree := _make_object("tree_b", Vector3(-2.0, 0.0, -1.0), 1.5)
	var rock := _make_object("rock_b", Vector3(-6.0, 0.0, -1.0), 1.0)
	manager.register_object(tree, {"id": "tree_b", "min_spacing": 1.5})
	manager.register_object(rock, {"id": "rock_b", "min_spacing": 1.0})
	manager.unregister_object(tree)

	var after_unregister := manager.query_objects_in_radius(Vector3(-2.0, 0.0, -1.0), 2.0)
	if after_unregister.find(tree) >= 0:
		push_error("  FAIL: unregistered tree still appears in spatial query")
		_free_objects([tree, rock, manager])
		return false
	if after_unregister.find(rock) >= 0:
		push_error("  FAIL: rock should be outside query after tree unregister")
		_free_objects([tree, rock, manager])
		return false

	rock.position = Vector3(-1.0, 0.0, -1.0)
	manager.reindex_object(rock)
	manager.rebuild_spatial_index()
	var after_rebuild := manager.query_objects_in_radius(Vector3(-2.0, 0.0, -1.0), 2.0)
	if after_rebuild.find(rock) < 0:
		push_error("  FAIL: rebuilt index should include moved rock")
		_free_objects([tree, rock, manager])
		return false

	print("  OK: unregister/reindex/rebuild")
	_free_objects([tree, rock, manager])
	return true


func _make_object(object_id: String, pos: Vector3, min_spacing: float) -> AutoObject:
	var obj := AutoObject.new()
	obj.name = object_id
	obj.auto_id = object_id
	obj.position = pos
	obj.min_spacing = min_spacing
	obj.min_spacing_auto = false
	return obj


func _free_objects(nodes: Array) -> void:
	for node in nodes:
		if node is Object and is_instance_valid(node):
			(node as Object).free()
