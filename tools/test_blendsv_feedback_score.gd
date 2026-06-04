extends SceneTree

const SVC := preload("res://scripts/scene_voxel_committer.gd")


func _init() -> void:
	if not _has_rendering_device():
		print("[BlendSVFeedbackScore] SKIP: no RenderingDevice")
		quit(0)
		return

	var ok := true
	ok = _test_blendsv_feedback_scores_committed_result_against_target() and ok
	ok = _test_committed_payload_and_debug_query_boundaries() and ok
	ok = _test_cpu_runtime_managers_are_retired() and ok

	if ok:
		print("[BlendSVFeedbackScore] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[BlendSVFeedbackScore] SOME TESTS FAILED")
		quit(1)


func _test_blendsv_feedback_scores_committed_result_against_target() -> bool:
	print("[BlendSVFeedbackScore] test_blendsv_feedback_scores_committed_result_against_target...")
	var committer := SVC.new(32, 32.0)
	committer.configure_scene_voxel_grid(Vector3i(16, 1, 16), Vector3(1.0, 1.0, 1.0), Vector3.ZERO)
	committer.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.2, 0.8, 0.2, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var write_tick := committer.begin_generation_tick(committer.get_generation_tick())
	var record := {
		"id": "feedback_auto_0",
		"type": "autoobject",
		"source_voxel_type": "AutoSceneVoxel",
		"position": Vector3.ZERO,
		"base_pixel": Vector2i(16, 16),
		"voxel_xz": Vector2i(8, 8),
		"volume_xz_resolution": 16,
		"scale": Vector3.ONE,
		"color": Color(0.2, 0.8, 0.2, 1.0),
		"complexity": 1.0,
		"channel": 0,
		"radius": 1.0,
		"slice_indices": [0],
	}
	committer.apply_voxel_write_spec(record, true, write_tick)
	committer.blend_scene_voxels(write_tick)

	var voxel_count := 16 * 1 * 16
	var target := PackedFloat32Array()
	target.resize(voxel_count)
	for z in range(16):
		for x in range(16):
			var scene_voxel := committer.get_scene_voxel(0, Vector2i(x, z))
			var value := float(scene_voxel.get("complexity", scene_voxel.get("complexity", 0.0)))
			if value <= 0.01:
				continue
			var idx := x + 16 * (z + 16 * 0)
			target[idx] = value

	var matched := committer.score_blendsv_feedback_against_target(target, "TargetSV_B")
	if str(matched.get("score_source", "")) != "score_scene_voxel_feedback_compute":
		push_error("  FAIL: expected GPU feedback score source, got %s" % str(matched))
		return false
	if float(matched.get("score", 0.0)) < 0.95:
		push_error("  FAIL: expected high score for matching BlendSV/TargetSV_B, got %s" % str(matched))
		return false
	if int(matched.get("overlap_occupied_count", 0)) <= 0:
		push_error("  FAIL: expected matching occupancy overlap, got %s" % str(matched))
		return false

	for i in range(voxel_count):
		target[i] = 0.0
	target[1 + 16 * (1 + 16 * 0)] = 1.0
	var mismatched := committer.score_blendsv_feedback_against_target(target, "TargetSV_B")
	if float(mismatched.get("score", 1.0)) >= float(matched.get("score", 0.0)):
		push_error("  FAIL: mismatched target should score lower: matched=%s mismatched=%s" % [str(matched), str(mismatched)])
		return false
	if int(mismatched.get("overlap_occupied_count", -1)) != 0:
		push_error("  FAIL: expected no occupancy overlap for shifted target, got %s" % str(mismatched))
		return false

	print("  OK: BlendSV[tick] feedback compares committed result with TargetSV_B buffers")
	committer.dispose(true)
	return true


func _test_committed_payload_and_debug_query_boundaries() -> bool:
	print("[BlendSVFeedbackScore] test_committed_payload_and_debug_query_boundaries...")
	var committer := SVC.new(32, 32.0)
	committer.configure_scene_voxel_grid(Vector3i(8, 1, 8), Vector3(1.0, 1.0, 1.0), Vector3.ZERO)
	committer.build_voxel_volume(8, [
		{"channel": 0, "color": Color(0.1, 0.3, 0.9, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var write_tick := committer.begin_generation_tick(committer.get_generation_tick())
	var record := {
		"id": "payload_boundary_auto_0",
		"type": "autoobject",
		"source_type": "BrushSceneVoxel",
		"source_voxel_type": "AutoSceneVoxel",
		"commit_tick": 999,
		"debug": {"authoritative": true},
		"value": 0.99,
		"position": Vector3.ZERO,
		"base_pixel": Vector2i(16, 16),
		"voxel_xz": Vector2i(4, 4),
		"volume_xz_resolution": 8,
		"scale": Vector3.ONE,
		"color": Color(0.7, 0.2, 0.1, 0.99),
		"complexity": 0.42,
		"channel": 0,
		"radius": 1.0,
		"slice_indices": [0],
	}
	committer.apply_voxel_write_spec(record, true, write_tick)
	var public_map := committer.blend_scene_voxels(write_tick)
	var scene_voxel := committer.get_scene_voxel(0, Vector2i(4, 4))
	if scene_voxel.is_empty():
		push_error("  FAIL: expected committed SceneVoxel at center")
		return false
	if not _check_public_scene_voxel_payload(scene_voxel):
		return false
	for key in public_map.keys():
		var public_scene_voxel = public_map[key]
		if public_scene_voxel is Dictionary and not _check_public_scene_voxel_payload(public_scene_voxel as Dictionary):
			return false

	var color: Color = scene_voxel.get("color", Color.BLACK)
	if not _approx(float(scene_voxel.get("complexity", -1.0)), 0.42, 0.001) or not _approx(color.a, 0.42, 0.001):
		push_error("  FAIL: committed complexity/color.a should mirror source complexity, got %s" % str(scene_voxel))
		return false

	if committer.has_method("get_scene_voxel_local") or committer.has_method("get_scene_voxel_sidecar"):
		push_error("  FAIL: old CPU SceneVoxel sidecar/local query path must stay removed")
		return false
	print("  OK: committed payload is minimal; debug metadata stays out of CPU query sidecars")
	committer.dispose(true)
	return true


func _test_cpu_runtime_managers_are_retired() -> bool:
	print("[BlendSVFeedbackScore] test_cpu_runtime_managers_are_retired...")
	if FileAccess.file_exists("res://scripts/scene_voxel_runtime.gd") or ResourceLoader.exists("res://scripts/scene_voxel_runtime.gd"):
		push_error("  FAIL: scripts/scene_voxel_runtime.gd must stay retired")
		return false
	if FileAccess.file_exists("res://tools/test_scene_voxel_runtime.gd") or ResourceLoader.exists("res://tools/test_scene_voxel_runtime.gd"):
		push_error("  FAIL: old CPU SceneVoxelRuntime tests must stay retired")
		return false
	if FileAccess.file_exists("res://scripts/auto_object_manager.gd") or ResourceLoader.exists("res://scripts/auto_object_manager.gd"):
		push_error("  FAIL: scripts/auto_object_manager.gd must stay retired")
		return false
	if FileAccess.file_exists("res://tools/test_autoobject_spatial_index.gd") or ResourceLoader.exists("res://tools/test_autoobject_spatial_index.gd"):
		push_error("  FAIL: old CPU AutoObjectManager spatial-index tests must stay retired")
		return false
	print("  OK: CPU SceneVoxelRuntime and AutoObjectManager file/tests are absent")
	return true


func _check_public_scene_voxel_payload(scene_voxel: Dictionary) -> bool:
	for key in [
		"value",
		"occupied",
		"type",
		"source_type",
		"source_voxel_type",
		"commit_tick",
		"write_tick",
		"read_tick",
		"generation_tick",
		"debug",
		"record_id",
		"auto_id",
		"object_type",
		"channel",
	]:
		if scene_voxel.has(key):
			push_error("  FAIL: committed public SceneVoxel payload must not expose %s: %s" % [key, str(scene_voxel)])
			return false
	if not scene_voxel.has("complexity") or not scene_voxel.has("color"):
		push_error("  FAIL: committed public SceneVoxel must expose complexity and color")
		return false
	return true


func _has_rendering_device() -> bool:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return false
	probe_rd.free()
	return true


func _approx(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps
