extends SceneTree

const SVC := preload("res://scripts/scene_voxel_committer.gd")

var _gpu_skip_count := 0


func _init() -> void:
	var ok := true
	ok = _test_gpu_source_resolve_or_skip() and ok

	if ok:
		if _gpu_skip_count > 0:
			print("[SceneVoxelSourceResolve] TESTS PASSED WITH %d GPU SKIPS" % _gpu_skip_count)
		else:
			print("[SceneVoxelSourceResolve] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[SceneVoxelSourceResolve] SOME TESTS FAILED")
		quit(1)


func _test_gpu_source_resolve_or_skip() -> bool:
	print("[SceneVoxelSourceResolve] test_gpu_source_resolve_or_skip...")
	if not _has_rendering_device():
		_gpu_skip_count += 1
		print("  SKIP: no RenderingDevice for source candidate resolver")
		return true

	var committer := _make_committer()
	if not committer._gpu_ready:
		push_error("  FAIL: SceneVoxelCommitter GPU resources are not ready")
		return false
	if not committer._shader_resolve_scene_sources.is_valid() or not committer._pipeline_resolve_scene_sources.is_valid():
		push_error("  FAIL: source candidate resolver shader/pipeline RID is invalid")
		return false

	var tick := committer.begin_generation_tick(committer.get_generation_tick())
	_write_priority_candidates(committer, tick)
	committer.blend_scene_voxels(tick)

	var result := _check_priority_winner(committer, "resolve_resident_source_streams")
	committer.dispose(true)
	if not result:
		return false

	var next_tick := committer.begin_generation_tick(committer.get_generation_tick())
	committer._enqueue_scene_voxel_source_record(
		_make_source_voxel("next_tick_lower_priority", next_tick, 1.0, 0.1, Color(0.8, 0.8, 0.1, 0.1))
	)
	committer.blend_scene_voxels(next_tick)
	var next_voxel := committer.get_scene_voxel(0, Vector2i(4, 4))
	if absf(float(next_voxel.get("complexity", -1.0)) - 0.1) > 0.001:
		push_error("  FAIL: a new tick should replace the previous source stream winner")
		committer.dispose(true)
		return false

	committer.dispose(true)
	print("  OK: source candidate winners publish resident final source streams")
	return true


func _write_priority_candidates(committer: SceneVoxelCommitter, tick: int) -> void:
	committer._enqueue_scene_voxel_source_record(
		_make_source_voxel("high_complexity_low_priority", tick, 10.0, 0.9, Color(0.9, 0.1, 0.1, 0.9))
	)
	committer._enqueue_scene_voxel_source_record(
		_make_source_voxel("lower_complexity_high_priority", tick, 20.0, 0.4, Color(0.1, 0.9, 0.1, 0.4))
	)
	committer._enqueue_scene_voxel_source_record(
		_make_source_voxel("higher_complexity_high_priority", tick, 20.0, 0.6, Color(0.1, 0.1, 0.9, 0.6))
	)
	committer._enqueue_scene_voxel_source_record(
		_make_source_voxel("later_equal_score_wins", tick, 20.0, 0.6, Color(0.8, 0.2, 0.8, 0.6))
	)


func _check_priority_winner(committer: SceneVoxelCommitter, expected_mode: String) -> bool:
	var voxel := committer.get_scene_voxel(0, Vector2i(4, 4))
	if voxel.is_empty():
		push_error("  FAIL: expected committed center voxel")
		return false
	if absf(float(voxel.get("complexity", -1.0)) - 0.6) > 0.001:
		push_error("  FAIL: priority/complexity winner mismatch: %s" % str(voxel))
		return false
	var color: Color = voxel.get("color", Color.TRANSPARENT)
	if not color.is_equal_approx(Color(0.8, 0.2, 0.8, 0.6)):
		push_error("  FAIL: equal priority/complexity should keep the later source: %s" % str(voxel))
		return false

	var summary := committer.get_last_scene_voxel_source_resolve_summary()
	if str(summary.get("mode", "")) != expected_mode:
		push_error("  FAIL: expected source resolve mode %s, got %s" % [expected_mode, str(summary)])
		return false
	if int(summary.get("candidate_group_count", 0)) != 1 or int(summary.get("candidate_count", 0)) != 4:
		push_error("  FAIL: source resolve candidate summary mismatch: %s" % str(summary))
		return false
	if bool(summary.get("cpu_runtime_fallback", true)):
		push_error("  FAIL: source resolve must not advertise CPU runtime fallback")
		return false
	if str(summary.get("source_candidate_winner_readback_source", "")) != "none":
		push_error("  FAIL: source resolve must not read back winner indices: %s" % str(summary))
		return false
	if int(summary.get("source_candidate_winner_readback_count", -1)) != 0:
		push_error("  FAIL: winner readback count should stay zero: %s" % str(summary))
		return false
	if bool(summary.get("source_candidate_cpu_apply_bridge", true)):
		push_error("  FAIL: source resolve must not report CPU apply bridge success: %s" % str(summary))
		return false
	if str(summary.get("source_candidate_cpu_apply_bridge_target", "")) != "none":
		push_error("  FAIL: source resolve CPU apply bridge target should stay none: %s" % str(summary))
		return false
	if not bool(summary.get("final_source_stream_resident", false)):
		push_error("  FAIL: final source stream should be reported as GPU-resident: %s" % str(summary))
		return false
	if str(summary.get("final_source_stream_resident_source", "")) != "resolve_scene_voxel_sources.glsl":
		push_error("  FAIL: final source stream should come from resolve_scene_voxel_sources.glsl: %s" % str(summary))
		return false
	if int(summary.get("final_source_stream_resident_stride_bytes", -1)) != SVC.SCENE_VOXEL_SOURCE_PAYLOAD_STRIDE_BYTES:
		push_error("  FAIL: final source stream stride should match source payload stride: %s" % str(summary))
		return false
	if int(summary.get("final_source_stream_resident_count", 0)) <= 0:
		push_error("  FAIL: final source stream should retain a resident count: %s" % str(summary))
		return false
	return true


func _has_rendering_device() -> bool:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return false
	probe_rd.free()
	return true


func _make_committer() -> SceneVoxelCommitter:
	var committer := SVC.new(8, 8.0)
	committer.build_voxel_volume(8, [
		{"channel": 0, "color": Color.WHITE, "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])
	return committer


func _make_source_voxel(record_id: String, tick: int, priority: float, complexity: float, color: Color) -> Dictionary:
	return {
		"record_id": record_id,
		"source_id": record_id,
		"source_voxel_type": "AutoSceneVoxel",
		"slice_index": 0,
		"voxel_xz": Vector2i(4, 4),
		"base_pixel": Vector2i(4, 4),
		"write_tick": tick,
		"priority": priority,
		"complexity": complexity,
		"color": color,
	}
