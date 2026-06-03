extends SceneTree

const HeightRawInverterGPU := preload("res://tools/terrain/invert_height_raw_gpu.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[test_invert_height_raw_gpu] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	var values := PackedFloat32Array([
		2.0, 10.0, 20.0, 30.0,
		5.0, 11.0, 21.0, 31.0,
		-12000.0, 12.0, 22.0, 32.0,
		-1.0, 13.0, 23.0, 33.0,
	])
	var result := HeightRawInverterGPU.invert_bytes_gpu(values.to_byte_array(), 4)
	if result.is_empty():
		push_error("[test_invert_height_raw_gpu] GPU inversion returned no result")
		quit(FAILED)
		return

	if int(result.get("valid_count", 0)) != 3:
		push_error("[test_invert_height_raw_gpu] expected 3 valid pixels, got %d" % int(result.get("valid_count", 0)))
		quit(FAILED)
		return
	if absf(float(result.get("peak", 0.0)) - 5.0) > 0.0001:
		push_error("[test_invert_height_raw_gpu] expected peak 5.0, got %.6f" % float(result.get("peak", 0.0)))
		quit(FAILED)
		return
	if str(result.get("stats_source", "")) != "invert_height_raw_compute":
		push_error("[test_invert_height_raw_gpu] expected compute stats source, got %s" % str(result.get("stats_source", "")))
		quit(FAILED)
		return
	if absf(float(result.get("min", 0.0)) - -6.0) > 0.0001 or absf(float(result.get("max", 0.0)) - 0.0) > 0.0001:
		push_error("[test_invert_height_raw_gpu] expected GPU min/max -6.0/0.0, got %.6f/%.6f" % [
			float(result.get("min", 0.0)),
			float(result.get("max", 0.0)),
		])
		quit(FAILED)
		return

	var out_values: PackedFloat32Array = (result["bytes"] as PackedByteArray).to_float32_array()
	var expected := PackedFloat32Array([
		-3.0, 10.0, 20.0, 30.0,
		0.0, 11.0, 21.0, 31.0,
		-12000.0, 12.0, 22.0, 32.0,
		-6.0, 13.0, 23.0, 33.0,
	])
	for i in range(expected.size()):
		if absf(out_values[i] - expected[i]) > 0.0001:
			push_error("[test_invert_height_raw_gpu] value[%d] expected %.6f, got %.6f" % [i, expected[i], out_values[i]])
			quit(FAILED)
			return

	var temp_path := "user://test_invert_height_raw_gpu.raw"
	var global_temp_path := ProjectSettings.globalize_path(temp_path)
	var file := FileAccess.open(global_temp_path, FileAccess.WRITE)
	if file == null:
		push_error("[test_invert_height_raw_gpu] failed to create temp raw file")
		quit(FAILED)
		return
	file.store_buffer(values.to_byte_array())
	file = null

	var file_result := HeightRawInverterGPU.invert_file_gpu(temp_path, 2, 2)
	if file_result.is_empty():
		push_error("[test_invert_height_raw_gpu] file inversion returned no result")
		quit(FAILED)
		return
	if str(file_result.get("stats_source", "")) != "invert_height_raw_compute":
		push_error("[test_invert_height_raw_gpu] file inversion expected compute stats source")
		quit(FAILED)
		return
	var read_file := FileAccess.open(global_temp_path, FileAccess.READ)
	var file_values := read_file.get_buffer(read_file.get_length()).to_float32_array()
	read_file = null
	for i in range(expected.size()):
		if absf(file_values[i] - expected[i]) > 0.0001:
			push_error("[test_invert_height_raw_gpu] file value[%d] expected %.6f, got %.6f" % [i, expected[i], file_values[i]])
			quit(FAILED)
			return

	print("[test_invert_height_raw_gpu] OK")
	quit(OK)
