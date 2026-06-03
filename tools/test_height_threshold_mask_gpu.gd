extends SceneTree

const HeightThresholdMaskGPUScript := preload("res://tools/terrain/height_threshold_mask_gpu.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[test_height_threshold_mask_gpu] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	var img := Image.create(5, 3, false, Image.FORMAT_RGBAF)
	img.fill(Color(-12000.0, 0.0, 0.0, 1.0))
	var heights := {
		Vector2i(0, 0): 1.0,
		Vector2i(1, 0): 2.5,
		Vector2i(2, 0): 4.0,
		Vector2i(3, 1): 6.5,
		Vector2i(4, 2): 8.0,
		Vector2i(2, 2): -2.0,
	}
	for p in heights.keys():
		img.set_pixelv(p, Color(float(heights[p]), 0.0, 0.0, 1.0))

	var min_height := 2.0
	var max_height := 7.0
	var result := HeightThresholdMaskGPUScript.make_mask_from_height_image_gpu(img, min_height, max_height)
	if not bool(result.get("ok", false)):
		push_error("[test_height_threshold_mask_gpu] GPU mask failed: %s" % str(result))
		quit(FAILED)
		return
	if str(result.get("stats_source", "")) != "height_threshold_mask_compute":
		push_error("[test_height_threshold_mask_gpu] expected compute stats source")
		quit(FAILED)
		return

	var expected := _make_cpu_reference_mask(img, min_height, max_height, -10000.0)
	var mask_words: PackedInt32Array = result.get("mask_words", PackedInt32Array())
	if mask_words.size() != expected.size():
		push_error("[test_height_threshold_mask_gpu] mask size mismatch")
		quit(FAILED)
		return
	for i in range(expected.size()):
		if int(mask_words[i]) != int(expected[i]):
			push_error("[test_height_threshold_mask_gpu] mask[%d] expected %d, got %d" % [
				i,
				int(expected[i]),
				int(mask_words[i]),
			])
			quit(FAILED)
			return

	if int(result.get("active_count", 0)) != 3:
		push_error("[test_height_threshold_mask_gpu] expected 3 active pixels, got %d" % int(result.get("active_count", 0)))
		quit(FAILED)
		return
	if absf(float(result.get("min_active_height", 0.0)) - 2.5) > 0.001:
		push_error("[test_height_threshold_mask_gpu] expected min active height 2.5, got %.6f" % float(result.get("min_active_height", 0.0)))
		quit(FAILED)
		return
	if absf(float(result.get("max_active_height", 0.0)) - 6.5) > 0.001:
		push_error("[test_height_threshold_mask_gpu] expected max active height 6.5, got %.6f" % float(result.get("max_active_height", 0.0)))
		quit(FAILED)
		return

	var edge_img := Image.create(33, 17, false, Image.FORMAT_RGBAF)
	edge_img.fill(Color(3.0, 0.0, 0.0, 1.0))
	var edge_result := HeightThresholdMaskGPUScript.make_mask_from_height_image_gpu(edge_img, 2.0, 4.0)
	if not bool(edge_result.get("ok", false)) or int(edge_result.get("active_count", 0)) != 33 * 17:
		push_error("[test_height_threshold_mask_gpu] edge guarded dispatch failed: %s" % str(edge_result))
		quit(FAILED)
		return

	print("[test_height_threshold_mask_gpu] OK")
	quit(OK)


func _make_cpu_reference_mask(img: Image, min_height: float, max_height: float, sentinel: float) -> PackedInt32Array:
	var result := PackedInt32Array()
	result.resize(img.get_width() * img.get_height())
	var values := img.get_data().to_float32_array()
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var idx := y * img.get_width() + x
			var value_index := idx * 4
			var value := values[value_index] if value_index < values.size() else sentinel
			result[idx] = 1 if value > sentinel and value >= min_height and value <= max_height else 0
	return result
