extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")
const GVF := preload("res://scripts/global_voxel_field.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_same_type_neighbor_skips_candidate_tile()
	ok = ok and _test_different_subtype_keeps_candidate_tile()
	ok = ok and _test_global_field_autoobject_metadata_gate()
	if ok:
		print("[VoxelSameTypeExclusion] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[VoxelSameTypeExclusion] SOME TESTS FAILED")
		quit(1)


func _test_same_type_neighbor_skips_candidate_tile() -> bool:
	print("[VoxelSameTypeExclusion] test_same_type_neighbor_skips_candidate_tile...")
	var manager := AutoObjectManager.new()
	manager.configure_spatial_index(4.0)
	var existing := _make_object("existing_bush", "vegetation", "bush", Vector3(2.0, 0.0, 2.0), 3.0)
	manager.register_object(existing, {
		"id": "existing_bush",
		"object_type": "vegetation",
		"object_subtype": "bush",
		"min_spacing": 3.0,
	})

	var result := _run_single_tile_placement(manager, "bush")
	var asset_results: Array = result.get("asset_results", [])
	var a0: Dictionary = asset_results[0]
	if not bool(a0.get("skipped_same_type_exclusion", false)):
		push_error("  FAIL: same-type bush candidate should be skipped before physical placement")
		existing.free()
		manager.free()
		return false
	var exclusion: Dictionary = a0.get("same_type_exclusion", {})
	if int(exclusion.get("blocked_tile_count", 0)) != 1:
		push_error("  FAIL: expected one blocked tile, got %s" % str(exclusion))
		existing.free()
		manager.free()
		return false

	print("  OK: skipped before physical placement, exclusion=%s" % str(exclusion.get("first_block", {})))
	existing.free()
	manager.free()
	return true


func _test_different_subtype_keeps_candidate_tile() -> bool:
	print("[VoxelSameTypeExclusion] test_different_subtype_keeps_candidate_tile...")
	var manager := AutoObjectManager.new()
	manager.configure_spatial_index(4.0)
	var existing := _make_object("existing_bush", "vegetation", "bush", Vector3(2.0, 0.0, 2.0), 3.0)
	manager.register_object(existing, {
		"id": "existing_bush",
		"object_type": "vegetation",
		"object_subtype": "bush",
		"min_spacing": 3.0,
	})

	var exclusion := _run_same_type_filter(manager, "grass")
	if not exclusion.is_empty():
		push_error("  FAIL: grass candidate should not have blocked tiles: %s" % str(exclusion))
		existing.free()
		manager.free()
		return false

	print("  OK: different subtype was not pruned by same-type gate")
	existing.free()
	manager.free()
	return true


func _test_global_field_autoobject_metadata_gate() -> bool:
	print("[VoxelSameTypeExclusion] test_global_field_autoobject_metadata_gate...")
	var manager := AutoObjectManager.new()
	manager.configure_spatial_index(4.0)
	var existing := _make_object("existing_bush", "vegetation", "bush", Vector3(2.0, 0.0, 2.0), 3.0)
	manager.register_object(existing, {
		"id": "existing_bush",
		"object_type": "vegetation",
		"object_subtype": "bush",
		"min_spacing": 3.0,
	})

	var field := GVF.new(Vector3i(16, 8, 16), Vector3(0.5, 0.5, 0.5), Vector3.ZERO)
	field.set_auto_object_manager(manager)

	var candidate_asset := _make_object("candidate_bush_asset", "vegetation", "bush", Vector3.ZERO, 2.0)
	var asset_defs: Array = [
		{
			"collision_voxels": [
				{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 1.0}
			],
			"candidate_tiles": [Vector3i(0, 0, 0)],
			"result_capacity": 1,
		},
	]
	var result := field.run_placement(
		VPG.new(),
		asset_defs,
		{
			"autoobjects": [candidate_asset],
			"top_k": 2,
			"collision_limit": 0.0,
			"min_support_ratio": 1.0,
			"clearance_limit": 0.0,
		}
	)
	var asset_results: Array = result.get("asset_results", [])
	var a0: Dictionary = asset_results[0]
	if not bool(a0.get("skipped_same_type_exclusion", false)):
		push_error("  FAIL: GlobalVoxelField should forward manager and AutoObject metadata")
		existing.free()
		candidate_asset.free()
		manager.free()
		return false

	print("  OK: GlobalVoxelField metadata path skipped same-type candidate")
	existing.free()
	candidate_asset.free()
	manager.free()
	return true


func _run_single_tile_placement(manager: AutoObjectManager, subtype: String) -> Dictionary:
	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var generator := VPG.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var asset_defs: Array = [
		{
			"object_type": "vegetation",
			"object_subtype": subtype,
			"min_spacing": 2.0,
			"collision_voxels": [
				{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 1.0}
			],
			"candidate_tiles": [Vector3i(0, 0, 0)],
			"result_capacity": 1,
			"min_distance_voxels": 0.0,
		},
	]
	var common_settings := {
		"top_k": 2,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
		"auto_object_manager": manager,
	}
	return generator.run_multi_asset(scene, collision, asset_defs, grid_size, voxel_size, Vector3.ZERO, common_settings)


func _run_same_type_filter(manager: AutoObjectManager, subtype: String) -> Dictionary:
	var grid_size := Vector3i(16, 8, 16)
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var asset_def := {
		"object_type": "vegetation",
		"object_subtype": subtype,
		"min_spacing": 2.0,
		"collision_voxels": [
			{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "value": 1.0}
		],
	}
	var settings := {
		"candidate_tiles": [Vector3i(0, 0, 0)],
		"auto_object_manager": manager,
	}
	return VPG._filter_candidate_tiles_by_same_type_exclusion(
		settings,
		asset_def,
		grid_size,
		voxel_size,
		Vector3.ZERO
	)


func _make_object(object_id: String, object_type: String, subtype: String, pos: Vector3, min_spacing: float) -> AutoObject:
	var obj := AutoObject.new()
	obj.name = object_id
	obj.auto_id = object_id
	obj.object_type = object_type
	obj.object_subtype = subtype
	obj.position = pos
	obj.min_spacing = min_spacing
	obj.min_spacing_auto = false
	return obj
