extends SceneTree

const HeightNormalFromHeightGPUScript := preload("res://tools/terrain/height_normal_from_height_gpu.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[test_height_normal_from_height_gpu] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	var width := 5
	var height := 4
	var cell_size := 0.5
	var heights := PackedFloat32Array()
	heights.resize(width * height)
	for y in range(height):
		for x in range(width):
			var idx := y * width + x
			heights[idx] = float(x * x) * 0.25 + float(y) * 0.75 + float((x + y) % 3) * 0.1

	var result := HeightNormalFromHeightGPUScript.make_normals_from_heights_gpu(heights, width, height, cell_size)
	if not bool(result.get("ok", false)):
		push_error("[test_height_normal_from_height_gpu] GPU normal generation failed: %s" % str(result))
		quit(FAILED)
		return
	if str(result.get("stats_source", "")) != "height_normal_from_height_compute":
		push_error("[test_height_normal_from_height_gpu] expected compute stats source")
		quit(FAILED)
		return

	var expected := _make_cpu_reference_normals(heights, width, height, cell_size)
	var normal_values: PackedFloat32Array = result.get("normal_values", PackedFloat32Array())
	if normal_values.size() != expected.size():
		push_error("[test_height_normal_from_height_gpu] normal size mismatch")
		quit(FAILED)
		return
	for i in range(expected.size()):
		if absf(normal_values[i] - expected[i]) > 0.0001:
			push_error("[test_height_normal_from_height_gpu] normal[%d] expected %.6f, got %.6f" % [
				i,
				expected[i],
				normal_values[i],
			])
			quit(FAILED)
			return

	var expected_steep := 0
	var min_nz := 1.0
	var max_nz := -1.0
	for i in range(width * height):
		var nz := expected[i * 4 + 2]
		if nz < 0.75:
			expected_steep += 1
		min_nz = minf(min_nz, nz)
		max_nz = maxf(max_nz, nz)
	if int(result.get("steep_count", 0)) != expected_steep:
		push_error("[test_height_normal_from_height_gpu] expected steep_count %d, got %d" % [expected_steep, int(result.get("steep_count", 0))])
		quit(FAILED)
		return
	if absf(float(result.get("min_nz", 0.0)) - min_nz) > 0.0001 or absf(float(result.get("max_nz", 0.0)) - max_nz) > 0.0001:
		push_error("[test_height_normal_from_height_gpu] nz stats mismatch")
		quit(FAILED)
		return

	var raw_heights := PackedFloat32Array()
	raw_heights.resize(width * height * 4)
	for i in range(width * height):
		raw_heights[i * 4] = heights[i]
		raw_heights[i * 4 + 1] = -999.0
		raw_heights[i * 4 + 2] = -999.0
		raw_heights[i * 4 + 3] = -999.0
	var raw_result := HeightNormalFromHeightGPUScript.make_normals_from_height_raw_rgba_gpu(raw_heights.to_byte_array(), width, height, cell_size)
	var raw_normal_values: PackedFloat32Array = raw_result.get("normal_values", PackedFloat32Array())
	if not bool(raw_result.get("ok", false)) or raw_normal_values.size() != expected.size():
		push_error("[test_height_normal_from_height_gpu] raw RGBA input path failed: %s" % str(raw_result))
		quit(FAILED)
		return
	if str(raw_result.get("height_format", "")) != "rgba32f_storage_buffer_r_channel" \
	   or int(raw_result.get("height_input_stride", 0)) != 4 \
	   or int(raw_result.get("height_channel", -1)) != 0:
		push_error("[test_height_normal_from_height_gpu] raw RGBA path did not report GPU-side R-channel sampling: %s" % str(raw_result))
		quit(FAILED)
		return
	for i in range(expected.size()):
		if absf(raw_normal_values[i] - expected[i]) > 0.0001:
			push_error("[test_height_normal_from_height_gpu] raw normal[%d] expected %.6f, got %.6f" % [
				i,
				expected[i],
				raw_normal_values[i],
			])
			quit(FAILED)
			return

	var temp_src := "user://test_height_normal_from_height_gpu_height.raw"
	var temp_dst := "user://test_height_normal_from_height_gpu_normal.raw"
	var src_file := FileAccess.open(ProjectSettings.globalize_path(temp_src), FileAccess.WRITE)
	if src_file == null:
		push_error("[test_height_normal_from_height_gpu] failed to create temp height raw")
		quit(FAILED)
		return
	src_file.store_buffer(raw_heights.to_byte_array())
	src_file.flush()
	src_file = null
	var file_result := HeightNormalFromHeightGPUScript.convert_height_raw_file_gpu(temp_src, temp_dst, width, height, cell_size)
	if not bool(file_result.get("ok", false)):
		push_error("[test_height_normal_from_height_gpu] file conversion failed: %s" % str(file_result))
		quit(FAILED)
		return
	var dst_file := FileAccess.open(ProjectSettings.globalize_path(temp_dst), FileAccess.READ)
	if dst_file == null:
		push_error("[test_height_normal_from_height_gpu] failed to read temp normal raw")
		quit(FAILED)
		return
	var file_values := dst_file.get_buffer(dst_file.get_length()).to_float32_array()
	dst_file = null
	for i in range(expected.size()):
		if absf(file_values[i] - expected[i]) > 0.0001:
			push_error("[test_height_normal_from_height_gpu] file normal[%d] expected %.6f, got %.6f" % [
				i,
				expected[i],
				file_values[i],
			])
			quit(FAILED)
			return

	var single := HeightNormalFromHeightGPUScript.make_normals_from_heights_gpu(PackedFloat32Array([42.0]), 1, 1, cell_size)
	var single_values: PackedFloat32Array = single.get("normal_values", PackedFloat32Array())
	if not bool(single.get("ok", false)) or single_values.size() != 4 or absf(single_values[2] - 1.0) > 0.0001:
		push_error("[test_height_normal_from_height_gpu] single-pixel guard failed: %s" % str(single))
		quit(FAILED)
		return

	print("[test_height_normal_from_height_gpu] OK")
	quit(OK)


func _make_cpu_reference_normals(heights: PackedFloat32Array, width: int, height: int, cell_size: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(width * height * 4)
	for y in range(height):
		for x in range(width):
			var dx := 0.0
			if width <= 1:
				dx = 0.0
			elif x == 0:
				dx = (_height_at(heights, width, height, 1, y) - _height_at(heights, width, height, 0, y)) / cell_size
			elif x == width - 1:
				dx = (_height_at(heights, width, height, x, y) - _height_at(heights, width, height, x - 1, y)) / cell_size
			else:
				dx = (_height_at(heights, width, height, x + 1, y) - _height_at(heights, width, height, x - 1, y)) / (2.0 * cell_size)

			var dy := 0.0
			if height <= 1:
				dy = 0.0
			elif y == 0:
				dy = (_height_at(heights, width, height, x, 1) - _height_at(heights, width, height, x, 0)) / cell_size
			elif y == height - 1:
				dy = (_height_at(heights, width, height, x, y) - _height_at(heights, width, height, x, y - 1)) / cell_size
			else:
				dy = (_height_at(heights, width, height, x, y + 1) - _height_at(heights, width, height, x, y - 1)) / (2.0 * cell_size)

			var normal := Vector3(-dx, -dy, 1.0).normalized()
			var out_index := (y * width + x) * 4
			result[out_index + 0] = normal.x
			result[out_index + 1] = normal.y
			result[out_index + 2] = normal.z
			result[out_index + 3] = 0.0
	return result


func _height_at(heights: PackedFloat32Array, width: int, height: int, x: int, y: int) -> float:
	x = clampi(x, 0, width - 1)
	y = clampi(y, 0, height - 1)
	return heights[y * width + x]
