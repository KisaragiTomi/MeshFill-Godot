extends SceneTree

const TerrainRawPackGPUScript := preload("res://tools/terrain/terrain_raw_pack_gpu.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[test_terrain_raw_pack_gpu] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	if not _test_all_channels_pack():
		quit(FAILED)
		return
	if not _test_missing_optional_channels_zero_fill_and_edge_guard():
		quit(FAILED)
		return

	print("[test_terrain_raw_pack_gpu] OK")
	quit(OK)


func _test_all_channels_pack() -> bool:
	var width := 5
	var height := 3
	var pixel_count := width * height
	var r := PackedFloat32Array()
	var g := PackedFloat32Array()
	var b := PackedFloat32Array()
	var a := PackedFloat32Array()
	r.resize(pixel_count)
	g.resize(pixel_count)
	b.resize(pixel_count)
	a.resize(pixel_count)
	for i in range(pixel_count):
		r[i] = float(i) * 1.25 - 3.0
		g[i] = float(i) + 10.0
		b[i] = float(i) * -0.5
		a[i] = 1.0

	var result := TerrainRawPackGPUScript.pack_scalar_channels_gpu(r, width, height, g, b, a)
	if not bool(result.get("ok", false)):
		push_error("[test_terrain_raw_pack_gpu] all-channel pack failed: %s" % str(result))
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("[test_terrain_raw_pack_gpu] GPU pack must not report CPU fallback")
		return false
	if str(result.get("stats_source", "")) != "pack_rgba_raw_channels_compute":
		push_error("[test_terrain_raw_pack_gpu] expected compute stats source")
		return false
	if int(result.get("output_stride_bytes", 0)) != 16 or str(result.get("output_format", "")) != "rgba32f_storage_buffer":
		push_error("[test_terrain_raw_pack_gpu] output layout metadata mismatch: %s" % str(result))
		return false
	if int(result.get("valid_pixel_count", 0)) != pixel_count:
		push_error("[test_terrain_raw_pack_gpu] valid pixel count mismatch")
		return false
	if absf(float(result.get("min_r", 0.0)) - r[0]) > 0.0001 or absf(float(result.get("max_r", 0.0)) - r[pixel_count - 1]) > 0.0001:
		push_error("[test_terrain_raw_pack_gpu] R min/max stats mismatch")
		return false

	var actual: PackedFloat32Array = result.get("packed_values", PackedFloat32Array())
	var expected := _make_cpu_reference(r, width, height, g, b, a)
	return _compare_float_arrays(actual, expected, "all_channels")


func _test_missing_optional_channels_zero_fill_and_edge_guard() -> bool:
	var width := 17
	var height := 9
	var pixel_count := width * height
	var r := PackedFloat32Array()
	var g := PackedFloat32Array()
	r.resize(pixel_count)
	g.resize(pixel_count)
	for i in range(pixel_count):
		r[i] = 120.0 - float(i) * 0.25
		g[i] = float(i % 7) / 7.0

	var result := TerrainRawPackGPUScript.pack_scalar_channels_gpu(r, width, height, g)
	if not bool(result.get("ok", false)):
		push_error("[test_terrain_raw_pack_gpu] edge-guard pack failed: %s" % str(result))
		return false
	var groups: Vector3i = result.get("dispatch_groups", Vector3i.ZERO)
	if groups.x != 1:
		push_error("[test_terrain_raw_pack_gpu] expected ceil(153 / 256) = 1 dispatch group, got %s" % str(groups))
		return false

	var actual: PackedFloat32Array = result.get("packed_values", PackedFloat32Array())
	var expected := _make_cpu_reference(r, width, height, g)
	if not _compare_float_arrays(actual, expected, "zero_fill"):
		return false

	var invalid_b := PackedFloat32Array([1.0, 2.0])
	var invalid := TerrainRawPackGPUScript.pack_scalar_channels_gpu(r, width, height, g, invalid_b)
	if bool(invalid.get("ok", true)) or str(invalid.get("reason", "")) != "invalid_b_channel":
		push_error("[test_terrain_raw_pack_gpu] invalid channel length should be rejected explicitly: %s" % str(invalid))
		return false
	if bool(invalid.get("cpu_fallback", true)):
		push_error("[test_terrain_raw_pack_gpu] invalid input path must not report CPU fallback")
		return false

	return true


func _make_cpu_reference(
	r: PackedFloat32Array,
	width: int,
	height: int,
	g: PackedFloat32Array = PackedFloat32Array(),
	b: PackedFloat32Array = PackedFloat32Array(),
	a: PackedFloat32Array = PackedFloat32Array()
) -> PackedFloat32Array:
	var pixel_count := width * height
	var result := PackedFloat32Array()
	result.resize(pixel_count * 4)
	for i in range(pixel_count):
		result[i * 4 + 0] = r[i]
		result[i * 4 + 1] = g[i] if g.size() == pixel_count else 0.0
		result[i * 4 + 2] = b[i] if b.size() == pixel_count else 0.0
		result[i * 4 + 3] = a[i] if a.size() == pixel_count else 0.0
	return result


func _compare_float_arrays(actual: PackedFloat32Array, expected: PackedFloat32Array, label: String) -> bool:
	if actual.size() != expected.size():
		push_error("[test_terrain_raw_pack_gpu] %s size mismatch: got %d expected %d" % [label, actual.size(), expected.size()])
		return false
	for i in range(expected.size()):
		if absf(actual[i] - expected[i]) > 0.0001:
			push_error("[test_terrain_raw_pack_gpu] %s[%d] expected %.6f, got %.6f" % [
				label,
				i,
				expected[i],
				actual[i],
			])
			return false
	return true
