extends SceneTree

const TargetColorRgba8PackGPUScript := preload("res://tools/target_color_rgba8_pack_gpu.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[test_target_color_rgba8_pack_gpu] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	if not _test_rgba32f_pack_and_clamp():
		quit(FAILED)
		return
	if not _test_edge_guard_and_size_reject():
		quit(FAILED)
		return

	print("[test_target_color_rgba8_pack_gpu] OK")
	quit(OK)


func _test_rgba32f_pack_and_clamp() -> bool:
	var colors := PackedFloat32Array([
		1.0, 0.5, 0.0, 0.25,
		-0.2, 1.2, 0.501, 1.0,
		0.0, 0.0, 0.0, 0.0,
	])
	var result := TargetColorRgba8PackGPUScript.pack_rgba32f_values_to_rgba8_gpu(colors)
	if not bool(result.get("ok", false)):
		push_error("[test_target_color_rgba8_pack_gpu] pack failed: %s" % str(result))
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("[test_target_color_rgba8_pack_gpu] GPU pack must not report CPU fallback")
		return false
	if str(result.get("stats_source", "")) != "target_color_rgba8_pack_compute":
		push_error("[test_target_color_rgba8_pack_gpu] expected compute stats source")
		return false
	if int(result.get("input_stride_bytes", 0)) != 16 or int(result.get("output_stride_bytes", 0)) != 4:
		push_error("[test_target_color_rgba8_pack_gpu] layout metadata mismatch: %s" % str(result))
		return false

	var bytes: PackedByteArray = result.get("target_color_rgba8_bytes", PackedByteArray())
	var expected: Array[int] = [
		_pack_rgba8(Color(1.0, 0.5, 0.0, 0.25)),
		_pack_rgba8(Color(-0.2, 1.2, 0.501, 1.0)),
		_pack_rgba8(Color(0.0, 0.0, 0.0, 0.0)),
	]
	if not _compare_words(bytes, expected, "pack"):
		return false
	if int(result.get("active_alpha_count", 0)) != 2:
		push_error("[test_target_color_rgba8_pack_gpu] active alpha count mismatch")
		return false
	if absf(float(result.get("max_alpha", 0.0)) - 1.0) > 0.0001:
		push_error("[test_target_color_rgba8_pack_gpu] max alpha mismatch")
		return false
	if int(result.get("component_clamp_count", 0)) != 2:
		push_error("[test_target_color_rgba8_pack_gpu] clamp count mismatch: %s" % str(result))
		return false
	return true


func _test_edge_guard_and_size_reject() -> bool:
	var voxel_count := 65
	var colors := PackedFloat32Array()
	colors.resize(voxel_count * 4)
	for i in range(voxel_count):
		colors[i * 4 + 0] = float(i % 17) / 16.0
		colors[i * 4 + 1] = float(i % 9) / 8.0
		colors[i * 4 + 2] = float(i % 5) / 4.0
		colors[i * 4 + 3] = float(i) / float(voxel_count - 1)

	var result := TargetColorRgba8PackGPUScript.pack_rgba32f_values_to_rgba8_gpu(colors)
	if not bool(result.get("ok", false)):
		push_error("[test_target_color_rgba8_pack_gpu] edge-guard pack failed: %s" % str(result))
		return false
	if (result.get("dispatch_groups", Vector3i.ZERO) as Vector3i).x != 2:
		push_error("[test_target_color_rgba8_pack_gpu] expected ceil(65 / 64) = 2 groups")
		return false

	var bytes: PackedByteArray = result.get("target_color_rgba8_bytes", PackedByteArray())
	if bytes.size() != voxel_count * 4:
		push_error("[test_target_color_rgba8_pack_gpu] output byte size mismatch")
		return false
	if int(bytes.decode_u32(0)) != _pack_rgba8(_color_at(colors, 0)):
		push_error("[test_target_color_rgba8_pack_gpu] first word mismatch")
		return false
	if int(bytes.decode_u32((voxel_count - 1) * 4)) != _pack_rgba8(_color_at(colors, voxel_count - 1)):
		push_error("[test_target_color_rgba8_pack_gpu] last word mismatch")
		return false

	var invalid := TargetColorRgba8PackGPUScript.pack_rgba32f_values_to_rgba8_gpu(colors, voxel_count + 1)
	if bool(invalid.get("ok", true)) or str(invalid.get("reason", "")) != "rgba32f_values_too_short":
		push_error("[test_target_color_rgba8_pack_gpu] invalid size should be rejected: %s" % str(invalid))
		return false
	if bool(invalid.get("cpu_fallback", true)):
		push_error("[test_target_color_rgba8_pack_gpu] invalid path must not report CPU fallback")
		return false
	return true


func _color_at(values: PackedFloat32Array, index: int) -> Color:
	var base := index * 4
	return Color(values[base + 0], values[base + 1], values[base + 2], values[base + 3])


func _pack_rgba8(c: Color) -> int:
	var r := clampi(int(roundf(c.r * 255.0)), 0, 255)
	var g := clampi(int(roundf(c.g * 255.0)), 0, 255)
	var b := clampi(int(roundf(c.b * 255.0)), 0, 255)
	var a := clampi(int(roundf(c.a * 255.0)), 0, 255)
	return (r << 24) | (g << 16) | (b << 8) | a


func _compare_words(actual_bytes: PackedByteArray, expected: Array[int], label: String) -> bool:
	if actual_bytes.size() != expected.size() * 4:
		push_error("[test_target_color_rgba8_pack_gpu] %s byte size mismatch" % label)
		return false
	for i in range(expected.size()):
		var actual := int(actual_bytes.decode_u32(i * 4))
		var expected_word := int(expected[i]) & 0xFFFFFFFF
		if actual != expected_word:
			push_error("[test_target_color_rgba8_pack_gpu] %s[%d] expected 0x%08x, got 0x%08x" % [
				label,
				i,
				expected_word,
				actual,
			])
			return false
	return true
