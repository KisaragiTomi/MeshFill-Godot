extends SceneTree

const TargetSceneVoxelGeneratorScript := preload("res://scripts/target_scene_voxel_generator.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[TargetSVPartialDecodeGPU] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	var ok := true
	ok = _test_visual_only_partial_decode() and ok
	ok = _test_collision_only_partial_decode() and ok

	if ok:
		print("[TargetSVPartialDecodeGPU] ALL TESTS PASSED")
		quit(OK)
	else:
		push_error("[TargetSVPartialDecodeGPU] SOME TESTS FAILED")
		quit(FAILED)


func _test_visual_only_partial_decode() -> bool:
	print("[TargetSVPartialDecodeGPU] test_visual_only_partial_decode...")
	var tex_size := 3
	var slice_count := 2
	var voxel_count := tex_size * tex_size * slice_count
	var visual := PackedByteArray()
	visual.resize(voxel_count * 16)
	_write_visual(visual, 5, Color(0.25, 0.5, 0.75, 0.35))
	_write_visual(visual, voxel_count - 1, Color(2.0, -1.0, 0.1, 0.6))

	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers_gpu(
		visual,
		PackedByteArray(),
		tex_size,
		slice_count,
		true
	)
	if not _assert_partial_gpu_contract(decoded, voxel_count, "visual_bytes", "zero_filled"):
		return false
	var occupancy: PackedFloat32Array = decoded.get("target_field", PackedFloat32Array())
	var colors: PackedColorArray = decoded.get("target_color", PackedColorArray())
	if absf(occupancy[5] - 0.35) > 0.001 or absf(occupancy[voxel_count - 1] - 0.6) > 0.001:
		push_error("  FAIL: visual-only occupancy should come from visual complexity")
		return false
	var color := colors[voxel_count - 1]
	if absf(color.r - 1.0) > 0.001 or absf(color.g) > 0.001 or absf(color.b - 0.1) > 0.001 or absf(color.a - 0.6) > 0.001:
		push_error("  FAIL: visual-only color should be GPU-clamped RGBA32F, got %s" % str(color))
		return false
	if absf(float(decoded.get("max_collision", -1.0))) > 0.001 or int(decoded.get("collision_voxel_count", -1)) != 0:
		push_error("  FAIL: missing collision buffer should stay zero-filled")
		return false
	print("  OK: visual-only TargetSV decode uses GPU zero-filled collision input")
	return true


func _test_collision_only_partial_decode() -> bool:
	print("[TargetSVPartialDecodeGPU] test_collision_only_partial_decode...")
	var tex_size := 5
	var slice_count := 3
	var voxel_count := tex_size * tex_size * slice_count
	var collision := PackedByteArray()
	collision.resize(voxel_count * 4)
	collision.encode_float(0, 0.2)
	collision.encode_float(17 * 4, 1.25)
	collision.encode_float((voxel_count - 1) * 4, 0.45)

	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers_gpu(
		PackedByteArray(),
		collision,
		tex_size,
		slice_count,
		true
	)
	if not _assert_partial_gpu_contract(decoded, voxel_count, "zero_filled", "collision_bytes"):
		return false
	var occupancy: PackedFloat32Array = decoded.get("target_field", PackedFloat32Array())
	var colors: PackedColorArray = decoded.get("target_color", PackedColorArray())
	if absf(occupancy[0] - 0.2) > 0.001 \
			or absf(occupancy[17] - 1.0) > 0.001 \
			or absf(occupancy[voxel_count - 1] - 0.45) > 0.001:
		push_error("  FAIL: collision-only occupancy should come from clamped collision values")
		return false
	if colors[17] != Color(0.0, 0.0, 0.0, 0.0):
		push_error("  FAIL: missing visual buffer should decode as zero color")
		return false
	if absf(float(decoded.get("max_collision", 0.0)) - 1.0) > 0.001 \
			or int(decoded.get("collision_voxel_count", -1)) != 3:
		push_error("  FAIL: collision-only stats mismatch: %s" % str(decoded))
		return false
	var groups: Vector3i = decoded.get("dispatch_groups", Vector3i.ZERO)
	if groups != Vector3i(2, 1, 1) or int(decoded.get("dispatch_local_size", 0)) != 64:
		push_error("  FAIL: expected ceil(75 / 64) dispatch metadata, got %s" % str(decoded))
		return false
	print("  OK: collision-only TargetSV decode uses GPU zero-filled visual input and edge guard")
	return true


func _assert_partial_gpu_contract(decoded: Dictionary, voxel_count: int, visual_source: String, collision_source: String) -> bool:
	if not bool(decoded.get("ok", false)) or bool(decoded.get("cpu_fallback", true)):
		push_error("  FAIL: partial GPU decode must succeed without CPU fallback: %s" % str(decoded))
		return false
	if bool(decoded.get("valid", true)) or not bool(decoded.get("partial", false)):
		push_error("  FAIL: partial decode should be marked partial and invalid for full-buffer consumers: %s" % str(decoded))
		return false
	if str(decoded.get("reason", "")) != "target_buffer_partial":
		push_error("  FAIL: expected target_buffer_partial reason")
		return false
	if str(decoded.get("decode_source", "")) != "target_sv_pack_read_buffers_compute":
		push_error("  FAIL: wrong decode source")
		return false
	if str(decoded.get("visual_buffer_source", "")) != visual_source \
			or str(decoded.get("collision_buffer_source", "")) != collision_source:
		push_error("  FAIL: partial buffer source metadata mismatch: %s" % str(decoded))
		return false
	if int(decoded.get("target_color_stride_bytes", 0)) != 16 \
			or int(decoded.get("target_field_stride_bytes", 0)) != 4:
		push_error("  FAIL: partial decode stride metadata mismatch")
		return false
	var occupancy: PackedFloat32Array = decoded.get("target_field", PackedFloat32Array())
	var colors: PackedColorArray = decoded.get("target_color", PackedColorArray())
	if occupancy.size() != voxel_count or colors.size() != voxel_count:
		push_error("  FAIL: partial decode array sizes mismatch")
		return false
	return true


func _write_visual(bytes: PackedByteArray, voxel_index: int, color: Color) -> void:
	var base := voxel_index * 16
	bytes.encode_float(base + 0, color.r)
	bytes.encode_float(base + 4, color.g)
	bytes.encode_float(base + 8, color.b)
	bytes.encode_float(base + 12, color.a)
