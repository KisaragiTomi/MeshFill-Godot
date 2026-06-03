extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")
const SVC := preload("res://scripts/scene_voxel_committer.gd")


func _init() -> void:
	var mesh := VegetationScatter.create_bush_mesh()
	var committer := SVC.new(32, 32.0, false)
	committer.configure_scene_voxel_grid(Vector3i(32, 4, 32), Vector3(0.5, 0.5, 0.5), Vector3(-8.0, 0.0, -8.0))

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
		"create_voxel_write_spec": true,
		"scene_voxel_committer": committer,
		"capture_size": 32.0,
		"volume_xz_resolution": 32,
	})

	if node == null:
		push_error("Expected instantiated node")
		quit(1)
		return
	if not node.has_meta(AutoObject.INSTANCE_STAMP_WRITE_SPEC_META_KEY):
		push_error("Expected node instance_stamp_write_spec metadata")
		node.free()
		quit(1)
		return
	if not node.has_meta(AutoObject.VOXEL_WRITE_SPEC_META_KEY):
		push_error("Expected node legacy voxel_write_spec metadata")
		node.free()
		quit(1)
		return

	var record: Dictionary = node.get_instance_stamp_write_spec()
	if str(record.get("id", "")) != "voxel_bush_record_0":
		push_error("Expected voxel_bush_record_0 record id, got %s" % str(record.get("id", "")))
		node.free()
		quit(1)
		return
	if record.get("base_pixel", Vector2i(-1, -1)) != Vector2i(16, 16):
		push_error("Expected base_pixel=(16,16), got %s" % str(record.get("base_pixel", Vector2i(-1, -1))))
		node.free()
		quit(1)
		return
	var committed_record := committer.get_instance_stamp_write_spec("voxel_bush_record_0")
	if str(committed_record.get("id", "")) != "voxel_bush_record_0":
		push_error("Expected committer ISWS record readback")
		node.free()
		quit(1)
		return

	var volume: Dictionary = committer.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.2, 0.8, 0.2, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 0.3, "subdivisions": 1},
		{"channel": 1, "color": Color(0.8, 0.6, 0.2, 0.8), "complexity": 0.8, "y_min": 0.3, "y_max": 2.0, "subdivisions": 1},
	])
	var scene_voxels := committer.get_scene_voxels()
	var sv := committer.get_sv()
	var expected_origin := Vector3(-8.0, 0.0, -8.0)
	var expected_volume_voxel_size := Vector3(1.0, 1.0, 1.0)

	if volume.get("grid_origin", Vector3.ZERO) != expected_origin:
		push_error("Expected volume grid_origin=%s, got %s" % [str(expected_origin), str(volume.get("grid_origin", Vector3.ZERO))])
		node.free()
		quit(1)
		return
	if (volume.get("voxel_size", Vector3.ZERO) as Vector3).distance_to(expected_volume_voxel_size) > 0.001:
		push_error("Expected volume voxel_size=%s, got %s" % [str(expected_volume_voxel_size), str(volume.get("voxel_size", Vector3.ZERO))])
		node.free()
		quit(1)
		return
	if sv.get("grid_origin", Vector3.ZERO) != expected_origin:
		push_error("Expected SV grid_origin=%s, got %s" % [str(expected_origin), str(sv.get("grid_origin", Vector3.ZERO))])
		node.free()
		quit(1)
		return
	var committed_voxel := committer.world_to_voxel(Vector3(0.0, 0.5, 0.0), int(volume.get("xz_res", 16)))
	if committed_voxel != Vector3i(8, 0, 8):
		push_error("Expected committed world center voxel=(8,0,8), got %s" % str(committed_voxel))
		node.free()
		quit(1)
		return
	var scene_field: PackedFloat32Array = sv.get("scene_field", PackedFloat32Array())
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var found_committed_scene := false
	for y in range(grid_size.y):
		var committed_index := committed_voxel.x + grid_size.x * (committed_voxel.z + grid_size.z * y)
		if committed_index >= 0 and committed_index < scene_field.size() and scene_field[committed_index] > 0.01:
			found_committed_scene = true
			break
	if not found_committed_scene:
		push_error("Expected SV scene_field to preserve committed world center voxel")
		node.free()
		quit(1)
		return

	if scene_voxels.is_empty():
		push_error("Expected committed SceneVoxel entries")
		node.free()
		quit(1)
		return
	var has_committed_payload := false
	for scene_voxel in scene_voxels.values():
		if scene_voxel is Dictionary and float((scene_voxel as Dictionary).get("complexity", 0.0)) > 0.01:
			has_committed_payload = true
			break
	if not has_committed_payload:
		push_error("Expected committed SceneVoxel payload entries")
		node.free()
		quit(1)
		return
	if int(sv.get("tile_count", 0)) <= 0:
		push_error("Expected SV tiles")
		node.free()
		quit(1)
		return

	print("[test_voxel_placement_record_commit] record=%s scene_voxels=%d tiles=%d commit_tick=%d" % [
		str(record.id),
		scene_voxels.size(),
		int(sv.get("tile_count", 0)),
		committer.get_committed_tick(),
	])
	node.free()
	quit(0)
