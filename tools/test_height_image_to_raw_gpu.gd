extends SceneTree

const HeightImageToRawGPUScript := preload("res://tools/terrain/height_image_to_raw_gpu.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[test_height_image_to_raw_gpu] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	if not _test_l8_image_to_height_raw():
		quit(FAILED)
		return
	if not _test_rgba8_channel_selection_and_file_write():
		quit(FAILED)
		return

	print("[test_height_image_to_raw_gpu] OK")
	quit(OK)


func _test_l8_image_to_height_raw() -> bool:
	var width := 17
	var height := 9
	var height_scale := 120.0
	var luma := PackedByteArray()
	luma.resize(width * height)
	for i in range(luma.size()):
		luma[i] = (i * 37 + 11) % 256
	luma[0] = 0
	luma[luma.size() - 1] = 255
	var img := Image.create_from_data(width, height, false, Image.FORMAT_L8, luma)

	var result := HeightImageToRawGPUScript.make_height_raw_from_image_gpu(img, height_scale)
	if not bool(result.get("ok", false)):
		push_error("[test_height_image_to_raw_gpu] L8 conversion failed: %s" % str(result))
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("[test_height_image_to_raw_gpu] GPU conversion must not report CPU fallback")
		return false
	if str(result.get("stats_source", "")) != "height_image_to_raw_compute":
		push_error("[test_height_image_to_raw_gpu] expected compute stats source")
		return false
	if int(result.get("output_stride_bytes", 0)) != 16 or str(result.get("output_format", "")) != "rgba32f_storage_buffer":
		push_error("[test_height_image_to_raw_gpu] output layout metadata mismatch: %s" % str(result))
		return false
	if int(result.get("valid_pixel_count", 0)) != width * height:
		push_error("[test_height_image_to_raw_gpu] valid pixel count mismatch")
		return false
	var groups: Vector3i = result.get("dispatch_groups", Vector3i.ZERO)
	if groups != Vector3i(1, 1, 1):
		push_error("[test_height_image_to_raw_gpu] expected edge-guard dispatch groups (1,1,1), got %s" % str(groups))
		return false

	var actual: PackedFloat32Array = result.get("raw_values", PackedFloat32Array())
	var expected := _make_luma_reference(luma, height_scale)
	if not _compare_float_arrays(actual, expected, "l8"):
		return false

	var height_range: Vector2 = result.get("height_range", Vector2.ZERO)
	if absf(height_range.x - 0.0) > 0.0001 or absf(height_range.y - height_scale) > 0.0001:
		push_error("[test_height_image_to_raw_gpu] height range mismatch: %s" % str(height_range))
		return false
	return true


func _test_rgba8_channel_selection_and_file_write() -> bool:
	var width := 5
	var height := 4
	var height_scale := 50.0
	var img := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var expected_g := PackedByteArray()
	expected_g.resize(width * height)
	for y in range(height):
		for x in range(width):
			var idx := y * width + x
			var g := (idx * 13 + 5) % 256
			expected_g[idx] = g
			img.set_pixel(x, y, Color8(250 - g, g, idx % 256, 255))

	var result := HeightImageToRawGPUScript.make_height_raw_from_image_gpu(img, height_scale, 1)
	if not bool(result.get("ok", false)):
		push_error("[test_height_image_to_raw_gpu] RGBA8 channel conversion failed: %s" % str(result))
		return false
	if int(result.get("source_channel", -1)) != 1:
		push_error("[test_height_image_to_raw_gpu] source channel metadata mismatch")
		return false
	var expected := _make_luma_reference(expected_g, height_scale)
	var actual: PackedFloat32Array = result.get("raw_values", PackedFloat32Array())
	if not _compare_float_arrays(actual, expected, "rgba8_g"):
		return false

	var temp_src := "user://test_height_image_to_raw_gpu.png"
	var temp_dst := "user://test_height_image_to_raw_gpu.raw"
	var save_err := img.save_png(temp_src)
	if save_err != OK:
		push_error("[test_height_image_to_raw_gpu] failed to save temp PNG: %d" % save_err)
		return false
	var file_result := HeightImageToRawGPUScript.convert_height_image_file_gpu(temp_src, temp_dst, height_scale, 1)
	if not bool(file_result.get("ok", false)):
		push_error("[test_height_image_to_raw_gpu] file conversion failed: %s" % str(file_result))
		return false
	var dst_file := FileAccess.open(ProjectSettings.globalize_path(temp_dst), FileAccess.READ)
	if dst_file == null:
		push_error("[test_height_image_to_raw_gpu] failed to read temp raw")
		return false
	var file_values := dst_file.get_buffer(dst_file.get_length()).to_float32_array()
	dst_file = null
	return _compare_float_arrays(file_values, expected, "file")


func _make_luma_reference(luma: PackedByteArray, height_scale: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(luma.size() * 4)
	for i in range(luma.size()):
		result[i * 4 + 0] = float(luma[i]) / 255.0 * height_scale
		result[i * 4 + 1] = 0.0
		result[i * 4 + 2] = 0.0
		result[i * 4 + 3] = 0.0
	return result


func _compare_float_arrays(actual: PackedFloat32Array, expected: PackedFloat32Array, label: String) -> bool:
	if actual.size() != expected.size():
		push_error("[test_height_image_to_raw_gpu] %s size mismatch: got %d expected %d" % [label, actual.size(), expected.size()])
		return false
	for i in range(expected.size()):
		if absf(actual[i] - expected[i]) > 0.0001:
			push_error("[test_height_image_to_raw_gpu] %s[%d] expected %.6f, got %.6f" % [
				label,
				i,
				expected[i],
				actual[i],
			])
			return false
	return true
