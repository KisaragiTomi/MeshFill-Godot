extends SceneTree

const TargetSceneVoxelGeneratorScript := preload("res://scripts/target_scene_voxel_generator.gd")
const TargetSVLoader := preload("res://scripts/target_sv_loader.gd")

const SCENE_PATH := "res://demos/target-sv-point-cloud-conversion-c/target-sv-point-cloud-conversion.tscn"


func _init() -> void:
	TargetSVLoader.reload()
	var ok := true
	ok = _test_scene_loads() and ok
	ok = _test_fixture_buffers_decode() and ok
	if ok:
		print("[TargetSVPointCloudConversion] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[TargetSVPointCloudConversion] SOME TESTS FAILED")
		quit(1)


func _test_scene_loads() -> bool:
	print("[TargetSVPointCloudConversion] test_scene_loads...")
	var scene := load(SCENE_PATH)
	if scene == null:
		push_error("  FAIL: scene does not load: %s" % SCENE_PATH)
		return false
	var instance = scene.instantiate()
	if instance == null:
		push_error("  FAIL: scene does not instantiate")
		return false
	var visualization: Node = instance.get_node_or_null("TargetSVVisualization")
	if visualization == null:
		push_error("  FAIL: scene does not contain TargetSVVisualization")
		instance.free()
		return false
	var terrain := instance.find_child("Terrain", true, false) as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		push_error("  FAIL: scene does not use edit-time common Terrain")
		instance.free()
		return false
	var can_build_gpu_preview := RenderingServer.get_rendering_device() != null
	visualization.set("build_project_voxels_on_ready", can_build_gpu_preview)
	visualization.call("_rebuild_visualization")
	if can_build_gpu_preview:
		var project_boxes := visualization.get_node_or_null("ProjectVoxelBoxes") as MultiMeshInstance3D
		if project_boxes == null or project_boxes.multimesh == null or project_boxes.multimesh.instance_count <= 0:
			push_error("  FAIL: scene did not build project SceneVoxel box preview")
			instance.free()
			return false
		if not _assert_box_view_mode(visualization, "color"):
			instance.free()
			return false
		if not _assert_box_view_hotkey(visualization, KEY_T, "complexity"):
			instance.free()
			return false
		if not _assert_box_view_hotkey(visualization, KEY_Y, "collision"):
			instance.free()
			return false
		if not _assert_box_view_hotkey(visualization, KEY_R, "color"):
			instance.free()
			return false
	if not visualization.has_method("get_project_scene_voxel_snapshot"):
		push_error("  FAIL: TargetSVVisualization does not expose project SceneVoxel snapshot")
		instance.free()
		return false
	var project_sv: Dictionary = visualization.call("get_project_scene_voxel_snapshot")
	if not _assert_project_scene_voxel_snapshot(project_sv):
		instance.free()
		return false
	instance.free()
	print("  OK: scene resource loads and builds project SceneVoxel snapshot")
	return true



func _assert_box_view_hotkey(visualization: Node, keycode: Key, expected_mode: String) -> bool:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.shift_pressed = true
	visualization.call("_unhandled_input", event)
	return _assert_box_view_mode(visualization, expected_mode)


func _assert_box_view_mode(visualization: Node, expected_mode: String) -> bool:
	if not visualization.has_method("get_project_voxel_box_view"):
		push_error("  FAIL: TargetSVVisualization does not expose project voxel box view")
		return false
	var actual_mode := str(visualization.call("get_project_voxel_box_view"))
	if actual_mode != expected_mode:
		push_error("  FAIL: box view mode mismatch, expected %s got %s" % [expected_mode, actual_mode])
		return false
	var project_boxes := visualization.get_node_or_null("ProjectVoxelBoxes") as MultiMeshInstance3D
	if project_boxes == null or project_boxes.multimesh == null or project_boxes.multimesh.instance_count <= 0:
		push_error("  FAIL: project boxes missing after box view mode switch: %s" % expected_mode)
		return false
	return true


func _assert_project_scene_voxel_snapshot(project_sv: Dictionary) -> bool:
	var ok := true
	if project_sv.is_empty():
		push_error("  FAIL: project SceneVoxel snapshot is empty")
		return false
	if str(project_sv.get("type", "")) != "SV":
		push_error("  FAIL: project snapshot type must be SV")
		ok = false
	if str(project_sv.get("source_voxel_type", "")) != "TargetSceneVoxel":
		push_error("  FAIL: project snapshot source_voxel_type must be TargetSceneVoxel")
		ok = false
	if not bool(project_sv.get("target_guidance_only", false)):
		push_error("  FAIL: project snapshot must preserve target_guidance_only=true")
		ok = false
	if bool(project_sv.get("height_buffer_applied", true)) or bool(project_sv.get("collision_buffer_applied", true)):
		push_error("  FAIL: project snapshot must not mark source buffers as applied")
		ok = false

	var grid_size: Vector3i = project_sv.get("grid_size", Vector3i.ZERO)
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		push_error("  FAIL: project snapshot grid_size is invalid: %s" % str(grid_size))
		return false
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var complexity_field: PackedFloat32Array = project_sv.get("complexity_field", PackedFloat32Array())
	var collision_field: PackedFloat32Array = project_sv.get("collision_field", PackedFloat32Array())
	if complexity_field.size() != voxel_count:
		push_error("  FAIL: complexity_field size mismatch: %d / %d" % [complexity_field.size(), voxel_count])
		ok = false
	if collision_field.size() != voxel_count:
		push_error("  FAIL: collision_field size mismatch: %d / %d" % [collision_field.size(), voxel_count])
		ok = false

	var scene_voxels: Dictionary = project_sv.get("scene_voxels", {})
	var scene_voxel_tiles: Dictionary = project_sv.get("scene_voxel_tiles", {})
	if scene_voxels.is_empty() or int(project_sv.get("scene_voxel_count", 0)) != scene_voxels.size():
		push_error("  FAIL: scene_voxels are missing or count is inconsistent")
		ok = false
	if scene_voxel_tiles.is_empty() or int(project_sv.get("scene_voxel_tile_count", 0)) != scene_voxel_tiles.size():
		push_error("  FAIL: scene_voxel_tiles are missing or count is inconsistent")
		ok = false
	if int(project_sv.get("target_active_voxel_count", 0)) <= 0:
		push_error("  FAIL: target_active_voxel_count is empty")
		ok = false
	if int(project_sv.get("target_collision_voxel_count", 0)) <= 0:
		push_error("  FAIL: target_collision_voxel_count is empty")
		ok = false

	var record_bytes: PackedByteArray = project_sv.get("scene_voxel_tile_record_bytes", PackedByteArray())
	var summary_bytes: PackedByteArray = project_sv.get("scene_voxel_tile_summary_bytes", PackedByteArray())
	if record_bytes.is_empty() or summary_bytes.is_empty():
		push_error("  FAIL: project snapshot did not pack SceneVoxelTile bytes")
		ok = false
	var source_record: Dictionary = project_sv.get("target_scene_voxel_source_record", {})
	if source_record.is_empty() or str(source_record.get("source_voxel_type", "")) != "TargetSceneVoxel":
		push_error("  FAIL: project snapshot source record is missing TargetSceneVoxel semantics")
		ok = false
	return ok


func _test_fixture_buffers_decode() -> bool:
	print("[TargetSVPointCloudConversion] test_fixture_buffers_decode...")
	var metadata := TargetSVLoader.metadata()
	if metadata.is_empty():
		push_error("  FAIL: TargetSVLoader metadata is empty")
		return false
	var texture_size := int(metadata.get("texture_size", 0))
	var slice_count := int(metadata.get("slice_count", 0))
	var voxel_count := texture_size * texture_size * slice_count
	var visual_bytes := TargetSVLoader.visual_bytes()
	var collision_bytes := TargetSVLoader.collision_bytes()
	var ok := true
	if visual_bytes.size() != voxel_count * 16:
		push_error("  FAIL: visual buffer size mismatch: %d" % visual_bytes.size())
		ok = false
	if collision_bytes.size() != voxel_count * 4:
		push_error("  FAIL: collision buffer size mismatch: %d" % collision_bytes.size())
		ok = false

	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers(visual_bytes, collision_bytes, texture_size, slice_count)
	if not bool(decoded.get("valid", false)):
		push_error("  FAIL: decode_target_read_buffers rejected fixture: %s" % str(decoded))
		ok = false
	if float(decoded.get("max_completely", 0.0)) <= 0.0:
		push_error("  FAIL: decoded target occupancy is empty")
		ok = false
	if float(decoded.get("max_collision", 0.0)) <= 0.0:
		push_error("  FAIL: decoded target collision is empty")
		ok = false
	if not bool(metadata.get("target_guidance_only", false)):
		push_error("  FAIL: metadata must preserve target_guidance_only=true")
		ok = false
	if absf(float(metadata.get("max_height", 0.0)) - 120.0) > 0.001:
		push_error("  FAIL: metadata max_height must be 120m, got %.4f" % float(metadata.get("max_height", 0.0)))
		ok = false
	if bool(metadata.get("height_buffer_applied", true)) or bool(metadata.get("collision_buffer_applied", true)):
		push_error("  FAIL: TargetSV conversion must not mark source buffers as applied")
		ok = false
	if int(metadata.get("used_point_count", 0)) <= 0 or int(metadata.get("non_empty_voxel_count", 0)) <= 0:
		push_error("  FAIL: metadata point or voxel counts are empty")
		ok = false

	if ok:
		print("  OK: %d voxels decode with max occupancy %.3f and max collision %.3f" % [
			voxel_count,
			float(decoded.get("max_completely", 0.0)),
			float(decoded.get("max_collision", 0.0)),
		])
	return ok
