extends SceneTree

const HeightToSceneDepthGPUScript := preload("res://tools/terrain/height_to_scene_depth_gpu.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[test_height_to_scene_depth_gpu] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	var width := 7
	var height := 3
	var max_height := 120.0
	var heights := PackedFloat32Array()
	heights.resize(width * height)
	for y in range(height):
		for x in range(width):
			var idx := y * width + x
			heights[idx] = float((x * 7 + y * 11) % 29) * 1.25
	heights[2] = 0.0
	heights[width * height - 1] = 119.5

	var result := HeightToSceneDepthGPUScript.make_scene_depth_from_heights_gpu(heights, width, height, max_height)
	if not bool(result.get("ok", false)):
		push_error("[test_height_to_scene_depth_gpu] GPU scene depth generation failed: %s" % str(result))
		quit(FAILED)
		return
	if str(result.get("stats_source", "")) != "height_to_scene_depth_compute":
		push_error("[test_height_to_scene_depth_gpu] expected compute stats source")
		quit(FAILED)
		return
	if bool(result.get("cpu_fallback", true)):
		push_error("[test_height_to_scene_depth_gpu] CPU fallback must not be used")
		quit(FAILED)
		return
	if int(result.get("height_input_stride", 0)) != 1 or str(result.get("height_format", "")) != "r32f_storage_buffer":
		push_error("[test_height_to_scene_depth_gpu] R32F path did not report expected input layout")
		quit(FAILED)
		return

	var expected := _make_cpu_reference_scene_depth(heights, max_height)
	var scene_depth_values: PackedFloat32Array = result.get("scene_depth_values", PackedFloat32Array())
	if not _compare_float_arrays(scene_depth_values, expected, "r32f"):
		quit(FAILED)
		return

	var depth_range: Vector2 = result.get("depth_range", Vector2.ZERO)
	var height_range: Vector2 = result.get("height_range", Vector2.ZERO)
	if absf(depth_range.x - 0.5) > 0.0001 or absf(depth_range.y - 120.0) > 0.0001:
		push_error("[test_height_to_scene_depth_gpu] depth range mismatch: %s" % str(depth_range))
		quit(FAILED)
		return
	if absf(height_range.x - 0.0) > 0.0001 or absf(height_range.y - 119.5) > 0.0001:
		push_error("[test_height_to_scene_depth_gpu] height range mismatch: %s" % str(height_range))
		quit(FAILED)
		return

	var raw_heights := PackedFloat32Array()
	raw_heights.resize(width * height * 4)
	for i in range(width * height):
		raw_heights[i * 4] = heights[i]
		raw_heights[i * 4 + 1] = -17.0
		raw_heights[i * 4 + 2] = -18.0
		raw_heights[i * 4 + 3] = -19.0
	var raw_result := HeightToSceneDepthGPUScript.make_scene_depth_from_height_raw_rgba_gpu(raw_heights.to_byte_array(), width, height, max_height)
	if not bool(raw_result.get("ok", false)):
		push_error("[test_height_to_scene_depth_gpu] RGBA32F raw path failed: %s" % str(raw_result))
		quit(FAILED)
		return
	if int(raw_result.get("height_input_stride", 0)) != 4 \
	   or int(raw_result.get("height_channel", -1)) != 0 \
	   or str(raw_result.get("height_format", "")) != "rgba32f_storage_buffer_r_channel":
		push_error("[test_height_to_scene_depth_gpu] RGBA32F path did not report R-channel sampling: %s" % str(raw_result))
		quit(FAILED)
		return
	var raw_values: PackedFloat32Array = raw_result.get("scene_depth_values", PackedFloat32Array())
	if not _compare_float_arrays(raw_values, expected, "rgba32f"):
		quit(FAILED)
		return

	var temp_src := "user://test_height_to_scene_depth_gpu_height.raw"
	var temp_dst := "user://test_height_to_scene_depth_gpu_scene_depth.raw"
	var src_file := FileAccess.open(ProjectSettings.globalize_path(temp_src), FileAccess.WRITE)
	if src_file == null:
		push_error("[test_height_to_scene_depth_gpu] failed to create temp height raw")
		quit(FAILED)
		return
	src_file.store_buffer(raw_heights.to_byte_array())
	src_file.flush()
	src_file = null

	var file_result := HeightToSceneDepthGPUScript.convert_height_raw_rgba_file_gpu(temp_src, temp_dst, width, height, max_height)
	if not bool(file_result.get("ok", false)):
		push_error("[test_height_to_scene_depth_gpu] file conversion failed: %s" % str(file_result))
		quit(FAILED)
		return
	var dst_file := FileAccess.open(ProjectSettings.globalize_path(temp_dst), FileAccess.READ)
	if dst_file == null:
		push_error("[test_height_to_scene_depth_gpu] failed to read temp scene depth raw")
		quit(FAILED)
		return
	var file_values := dst_file.get_buffer(dst_file.get_length()).to_float32_array()
	dst_file = null
	if not _compare_float_arrays(file_values, expected, "file"):
		quit(FAILED)
		return

	print("[test_height_to_scene_depth_gpu] OK")
	quit(OK)


func _make_cpu_reference_scene_depth(heights: PackedFloat32Array, max_height: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(heights.size() * 4)
	for i in range(heights.size()):
		var out_index := i * 4
		result[out_index + 0] = max_height - heights[i]
		result[out_index + 1] = 0.0
		result[out_index + 2] = 0.0
		result[out_index + 3] = 1.0
	return result


func _compare_float_arrays(actual: PackedFloat32Array, expected: PackedFloat32Array, label: String) -> bool:
	if actual.size() != expected.size():
		push_error("[test_height_to_scene_depth_gpu] %s size mismatch: got %d expected %d" % [label, actual.size(), expected.size()])
		return false
	for i in range(expected.size()):
		if absf(actual[i] - expected[i]) > 0.0001:
			push_error("[test_height_to_scene_depth_gpu] %s[%d] expected %.6f, got %.6f" % [
				label,
				i,
				expected[i],
				actual[i],
			])
			return false
	return true
