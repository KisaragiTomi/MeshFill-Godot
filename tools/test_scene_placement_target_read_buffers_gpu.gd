extends SceneTree

const ScenePlacementActorScript := preload("res://scripts/scene_placement_actor.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[ScenePlacementTargetReadBuffersGPU] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	var ok := true
	ok = _test_gpu_prepare_trims_and_zero_fills() and ok
	ok = _test_gpu_prepare_edge_guard() and ok

	if ok:
		print("[ScenePlacementTargetReadBuffersGPU] ALL TESTS PASSED")
		quit(OK)
	else:
		push_error("[ScenePlacementTargetReadBuffersGPU] SOME TESTS FAILED")
		quit(FAILED)


func _test_gpu_prepare_trims_and_zero_fills() -> bool:
	print("[ScenePlacementTargetReadBuffersGPU] test_gpu_prepare_trims_and_zero_fills...")
	var grid_size := Vector3i(2, 1, 2)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var expected_bytes := voxel_count * 4
	var color_bytes := PackedByteArray()
	color_bytes.resize(expected_bytes + 8)
	var occupancy_values := PackedFloat32Array([0.15, 0.35, 0.55, 0.75])
	var occupancy_bytes := occupancy_values.to_byte_array()
	occupancy_bytes.resize(expected_bytes + 4)
	for i in range(voxel_count):
		color_bytes.encode_u32(i * 4, 0x10203040 + i)
	occupancy_bytes.encode_float(expected_bytes, 99.0)

	var actor := ScenePlacementActorScript.new()
	var result := actor.prepare_target_read_buffers_from_common_gpu({
		"target_color_rgba8_bytes": color_bytes,
		"target_occupancy_bytes": occupancy_bytes,
	}, {"grid_size": grid_size})
	actor.dispose(true)

	if not bool(result.get("ok", false)):
		push_error("  FAIL: GPU prepare failed: %s" % str(result))
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: GPU prepare must not report CPU fallback")
		return false
	if str(result.get("stats_source", "")) != "prepare_target_read_buffers_compute":
		push_error("  FAIL: wrong stats source: %s" % str(result))
		return false
	if int(result.get("expected_byte_count", 0)) != expected_bytes or int(result.get("voxel_count", 0)) != voxel_count:
		push_error("  FAIL: byte-count metadata mismatch: %s" % str(result))
		return false
	if int((result.get("dispatch_groups", Vector3i.ZERO) as Vector3i).x) != 1:
		push_error("  FAIL: expected one dispatch group for four voxels")
		return false

	var out_color: PackedByteArray = result.get("target_color_rgba8_bytes", PackedByteArray())
	var out_occupancy: PackedByteArray = result.get("target_occupancy_bytes", PackedByteArray())
	if out_color.size() != expected_bytes or out_occupancy.size() != expected_bytes:
		push_error("  FAIL: output byte size mismatch")
		return false
	for i in range(voxel_count):
		if int(out_color.decode_u32(i * 4)) != 0x10203040 + i:
			push_error("  FAIL: color word mismatch at %d" % i)
			return false
	var out_occupancy_values := out_occupancy.to_float32_array()
	for i in range(voxel_count):
		if absf(out_occupancy_values[i] - occupancy_values[i]) > 0.001:
			push_error("  FAIL: occupancy word mismatch at %d" % i)
			return false
	if str(result.get("target_color_source", "")) != "target_color_rgba8_bytes" \
			or str(result.get("target_occupancy_source", "")) != "target_occupancy_bytes":
		push_error("  FAIL: source metadata mismatch: %s" % str(result))
		return false

	var missing_actor := ScenePlacementActorScript.new()
	var missing := missing_actor.prepare_target_read_buffers_from_common_gpu({}, {"grid_size": grid_size})
	missing_actor.dispose(true)
	if not bool(missing.get("ok", false)):
		push_error("  FAIL: missing-input zero-fill path failed: %s" % str(missing))
		return false
	var missing_color: PackedByteArray = missing.get("target_color_rgba8_bytes", PackedByteArray())
	var missing_occupancy: PackedByteArray = missing.get("target_occupancy_bytes", PackedByteArray())
	for i in range(voxel_count):
		if int(missing_color.decode_u32(i * 4)) != 0 or absf(missing_occupancy.decode_float(i * 4)) > 0.001:
			push_error("  FAIL: missing inputs should produce zero-filled buffers")
			return false
	if str(missing.get("target_color_source", "")) != "zero_filled" \
			or str(missing.get("target_occupancy_source", "")) != "zero_filled":
		push_error("  FAIL: missing-input source metadata mismatch: %s" % str(missing))
		return false

	print("  OK: GPU prepared TargetSV read buffers preserve packed words and zero-fill missing inputs")
	return true


func _test_gpu_prepare_edge_guard() -> bool:
	print("[ScenePlacementTargetReadBuffersGPU] test_gpu_prepare_edge_guard...")
	var grid_size := Vector3i(5, 3, 5)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var expected_bytes := voxel_count * 4
	var color_bytes := PackedByteArray()
	var occupancy_bytes := PackedByteArray()
	color_bytes.resize(expected_bytes)
	occupancy_bytes.resize(expected_bytes)
	for i in range(voxel_count):
		color_bytes.encode_u32(i * 4, 0xA0000000 | i)
		occupancy_bytes.encode_float(i * 4, float(i) / 100.0)

	var actor := ScenePlacementActorScript.new()
	var result := actor.prepare_target_read_buffers_from_common_gpu({
		"target_color_rgba8_bytes": color_bytes,
		"target_occupancy_bytes": occupancy_bytes,
	}, {"grid_size": grid_size})
	actor.dispose(true)

	if not bool(result.get("ok", false)):
		push_error("  FAIL: edge-guard GPU prepare failed: %s" % str(result))
		return false
	if (result.get("dispatch_groups", Vector3i.ZERO) as Vector3i).x != 2:
		push_error("  FAIL: expected ceil(75 / 64) = 2 dispatch groups")
		return false
	var out_color: PackedByteArray = result.get("target_color_rgba8_bytes", PackedByteArray())
	var out_occupancy: PackedByteArray = result.get("target_occupancy_bytes", PackedByteArray())
	if out_color.size() != expected_bytes or out_occupancy.size() != expected_bytes:
		push_error("  FAIL: guarded output byte size mismatch")
		return false
	if int(out_color.decode_u32(0)) != 0xA0000000 or int(out_color.decode_u32((voxel_count - 1) * 4)) != (0xA0000000 | (voxel_count - 1)):
		push_error("  FAIL: guarded color output endpoints mismatch")
		return false
	if absf(out_occupancy.decode_float((voxel_count - 1) * 4) - float(voxel_count - 1) / 100.0) > 0.001:
		push_error("  FAIL: guarded occupancy output endpoint mismatch")
		return false

	print("  OK: non-multiple voxel count is edge-guarded")
	return true
