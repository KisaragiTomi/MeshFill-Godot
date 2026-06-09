extends SceneTree

const SVC := preload("res://scripts/scene_voxel_committer.gd")

var _gpu_skip_count := 0


func _init() -> void:
	var ok := true
	ok = _test_resident_source_candidate_buffer_or_skip() and ok

	if ok:
		if _gpu_skip_count > 0:
			print("[SceneVoxelResidentSourceCandidateBuffer] TESTS PASSED WITH %d GPU SKIPS" % _gpu_skip_count)
		else:
			print("[SceneVoxelResidentSourceCandidateBuffer] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[SceneVoxelResidentSourceCandidateBuffer] SOME TESTS FAILED")
		quit(1)


func _test_resident_source_candidate_buffer_or_skip() -> bool:
	print("[SceneVoxelResidentSourceCandidateBuffer] test_resident_source_candidate_buffer_or_skip...")
	if not _has_rendering_device():
		_gpu_skip_count += 1
		print("  SKIP: no RenderingDevice for resident source candidate buffer diagnostics")
		return true

	var committer := _make_committer()
	if not committer._gpu_ready:
		push_error("  FAIL: SceneVoxelCommitter GPU resources are not ready")
		committer.dispose(true)
		return false

	var report := committer.apply_voxel_write_specs(_make_overlapping_write_specs(), false)
	if not bool(report.get("ok", false)):
		push_error("  FAIL: write-spec batch should apply and blend: %s" % str(report))
		committer.dispose(true)
		return false

	if not _assert_resident_diagnostics(report, "write-spec batch report"):
		committer.dispose(true)
		return false

	var resolve_summary := committer.get_last_scene_voxel_source_resolve_summary()
	if not _assert_resolve_summary(resolve_summary):
		committer.dispose(true)
		return false

	var commit_summary := committer.get_last_blend_scene_voxel_commit_summary()
	if not bool(commit_summary.get("ok", false)) or bool(commit_summary.get("cpu_fallback", true)):
		push_error("  FAIL: public SceneVoxel commit should succeed without CPU fallback: %s" % str(commit_summary))
		committer.dispose(true)
		return false
	if str(commit_summary.get("payload_blend_mode", "")) != "merged_resolve_commit_gpu":
		push_error("  FAIL: accepted ComplexityVoxel fields should still materialize through compute blend: %s" % str(commit_summary))
		committer.dispose(true)
		return false
	if bool(commit_summary.get("source_candidate_cpu_apply_bridge", true)) or not bool(commit_summary.get("final_source_stream_resident", false)):
		push_error("  FAIL: blend summary should use resident final source streams without CPU apply bridge: %s" % str(commit_summary))
		committer.dispose(true)
		return false
	if str(commit_summary.get("source_candidate_winner_readback_source", "")) != "none" \
			or int(commit_summary.get("source_candidate_winner_readback_count", -1)) != 0 \
			or str(commit_summary.get("source_candidate_cpu_apply_bridge_target", "")) != "none":
		push_error("  FAIL: blend summary must not preserve winner readback or CPU bridge diagnostics: %s" % str(commit_summary))
		committer.dispose(true)
		return false
	if str(commit_summary.get("runtime_read_source", "")) != "resident_resolved_source_stream_buffers":
		push_error("  FAIL: blend summary should read resident resolved source streams: %s" % str(commit_summary))
		committer.dispose(true)
		return false

	if not _assert_public_scene_voxels(committer):
		committer.dispose(true)
		return false

	committer.dispose(true)
	print("  OK: resident source candidate/range staging diagnostics and public SceneVoxels are valid")
	return true


func _assert_resident_diagnostics(report: Dictionary, label: String) -> bool:
	if not bool(report.get("cpu_pending_source_candidate_bridge", false)):
		push_error("  FAIL: %s should keep the CPU pending-source candidate bridge: %s" % [label, str(report)])
		return false
	if bool(report.get("cpu_fallback", true)):
		push_error("  FAIL: %s must report cpu_fallback=false: %s" % [label, str(report)])
		return false
	if not bool(report.get("resident_source_write_buffer", false)):
		push_error("  FAIL: %s should report an active resident source write buffer: %s" % [label, str(report)])
		return false
	if str(report.get("resident_source_write_buffer_owner", "")) != "SceneVoxelCommitter":
		push_error("  FAIL: %s should report SceneVoxelCommitter as resident owner: %s" % [label, str(report)])
		return false
	if int(report.get("resident_source_write_buffer_stride_bytes", -1)) != 16:
		push_error("  FAIL: %s should expose candidate write stride 16 bytes: %s" % [label, str(report)])
		return false
	if int(report.get("resident_source_candidate_buffer_stride_bytes", -1)) != 16:
		push_error("  FAIL: %s should expose candidate buffer stride 16 bytes: %s" % [label, str(report)])
		return false
	if int(report.get("resident_source_range_buffer_stride_bytes", -1)) != 8:
		push_error("  FAIL: %s should expose range buffer stride 8 bytes: %s" % [label, str(report)])
		return false
	if int(report.get("resident_source_candidate_buffer_count", 0)) <= 0:
		push_error("  FAIL: %s should stage at least one source candidate: %s" % [label, str(report)])
		return false
	if int(report.get("resident_source_range_buffer_count", 0)) <= 0:
		push_error("  FAIL: %s should stage at least one candidate range: %s" % [label, str(report)])
		return false
	if int(report.get("resident_source_write_buffer_range_count", 0)) != int(report.get("resident_source_range_buffer_count", -1)):
		push_error("  FAIL: %s write-buffer range count should match range buffer count: %s" % [label, str(report)])
		return false
	return true


func _assert_resolve_summary(summary: Dictionary) -> bool:
	if str(summary.get("mode", "")) != "resolve_resident_source_streams":
		push_error("  FAIL: source candidate resolve should publish resident source streams: %s" % str(summary))
		return false
	if not bool(summary.get("gpu_dispatched", false)):
		push_error("  FAIL: source candidate resolve should dispatch on GPU: %s" % str(summary))
		return false
	if bool(summary.get("cpu_runtime_fallback", true)):
		push_error("  FAIL: source candidate resolve must not report CPU runtime fallback: %s" % str(summary))
		return false
	if not bool(summary.get("resident_source_write_buffer", false)):
		push_error("  FAIL: source resolve summary should keep resident source buffer diagnostics: %s" % str(summary))
		return false
	if int(summary.get("candidate_group_count", 0)) <= 0 or int(summary.get("candidate_count", 0)) <= 0:
		push_error("  FAIL: source resolve should process candidate groups and records: %s" % str(summary))
		return false
	if int(summary.get("resident_source_candidate_buffer_count", 0)) != int(summary.get("candidate_count", -1)):
		push_error("  FAIL: resident candidate count should match resolver candidate count: %s" % str(summary))
		return false
	if int(summary.get("resident_source_range_buffer_count", 0)) != int(summary.get("candidate_group_count", -1)):
		push_error("  FAIL: resident range count should match resolver group count: %s" % str(summary))
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
		push_error("  FAIL: final source streams should be reported as GPU-resident: %s" % str(summary))
		return false
	if str(summary.get("final_source_stream_resident_source", "")) != "resolve_scene_voxel_sources.glsl":
		push_error("  FAIL: final source streams should come from resolve_scene_voxel_sources.glsl: %s" % str(summary))
		return false
	if int(summary.get("final_source_stream_resident_stride_bytes", -1)) != SVC.SCENE_VOXEL_SOURCE_PAYLOAD_STRIDE_BYTES:
		push_error("  FAIL: final source stream stride should match source payload stride: %s" % str(summary))
		return false
	if int(summary.get("final_source_stream_resident_count", 0)) <= 0:
		push_error("  FAIL: final source streams should retain a resident count: %s" % str(summary))
		return false
	return _assert_resident_stride_summary(summary, "source resolve summary")


func _assert_resident_stride_summary(summary: Dictionary, label: String) -> bool:
	if str(summary.get("resident_source_write_buffer_owner", "")) != "SceneVoxelCommitter":
		push_error("  FAIL: %s should report SceneVoxelCommitter as resident owner: %s" % [label, str(summary)])
		return false
	if int(summary.get("resident_source_write_buffer_stride_bytes", -1)) != 16:
		push_error("  FAIL: %s should expose candidate write stride 16 bytes: %s" % [label, str(summary)])
		return false
	if int(summary.get("resident_source_candidate_buffer_stride_bytes", -1)) != 16:
		push_error("  FAIL: %s should expose candidate buffer stride 16 bytes: %s" % [label, str(summary)])
		return false
	if int(summary.get("resident_source_range_buffer_stride_bytes", -1)) != 8:
		push_error("  FAIL: %s should expose range buffer stride 8 bytes: %s" % [label, str(summary)])
		return false
	return true


func _assert_public_scene_voxels(committer: SceneVoxelCommitter) -> bool:
	var public_voxels := committer.get_scene_voxels()
	if public_voxels.is_empty():
		push_error("  FAIL: public SceneVoxel dictionary should materialize after source resolve")
		return false

	var center := committer.get_scene_voxel(0, Vector2i(4, 4))
	if center.is_empty():
		push_error("  FAIL: expected accepted ComplexityVoxel fields at center")
		return false

	var expected_complexity := 0.35
	if absf(float(center.get("complexity", -1.0)) - expected_complexity) > 0.001:
		push_error("  FAIL: public SceneVoxel center complexity mismatch: %s" % str(center))
		return false
	if absf(float(center.get("auto_mix", -1.0)) - 0.25) > 0.001:
		push_error("  FAIL: public SceneVoxel center should expose brush auto_mix 0.25: %s" % str(center))
		return false

	var color: Color = center.get("color", Color.TRANSPARENT)
	var expected_color := Color(0.50, 0.275, 0.20, expected_complexity)
	if not color.is_equal_approx(expected_color):
		push_error("  FAIL: public SceneVoxel center color mismatch, got %s expected %s" % [str(color), str(expected_color)])
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


func _make_overlapping_write_specs() -> Array[Dictionary]:
	return [
		_make_auto_spec("resident_source_auto_low", 0.4, 10.0, Color(0.8, 0.1, 0.1, 0.4)),
		_make_auto_spec("resident_source_auto_high", 0.8, 20.0, Color(0.2, 0.8, 0.2, 0.8)),
		{
			"id": "resident_source_brush_mix",
			"type": "brush",
			"source_voxel_type": "BrushSceneVoxel",
			"base_pixel": Vector2i(4, 4),
			"voxel_xz": Vector2i(4, 4),
			"volume_xz_resolution": 8,
			"color": Color(0.6, 0.1, 0.2, 0.2),
			"complexity": 0.2,
			"auto_mix": 0.25,
			"channel": 0,
			"radius_px": 1,
		},
	]


func _make_auto_spec(record_id: String, complexity: float, priority: float, color: Color) -> Dictionary:
	return {
		"id": record_id,
		"type": "rock",
		"source_voxel_type": "AutoSceneVoxel",
		"base_pixel": Vector2i(4, 4),
		"voxel_xz": Vector2i(4, 4),
		"volume_xz_resolution": 8,
		"color": color,
		"complexity": complexity,
		"priority": priority,
		"channel": 0,
		"radius_px": 1,
	}
