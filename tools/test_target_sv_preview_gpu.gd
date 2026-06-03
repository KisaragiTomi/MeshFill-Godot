extends SceneTree

const TargetSVPreviewGPUScript := preload("res://tools/target_sv_preview_gpu.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[test_target_sv_preview_gpu] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	if not _test_synthetic_volume_preview():
		quit(FAILED)
		return
	if not _test_edge_guard_dispatch():
		quit(FAILED)
		return

	print("[test_target_sv_preview_gpu] OK")
	quit(OK)


func _test_synthetic_volume_preview() -> bool:
	var width := 3
	var height := 2
	var slice_count := 3
	var visual := PackedFloat32Array()
	var collision := PackedFloat32Array()
	visual.resize(width * height * slice_count * 4)
	collision.resize(width * height * slice_count)

	_write_visual(visual, width, height, 0, 0, 0, Color(1.0, 0.0, 0.0, 0.5))
	_write_visual(visual, width, height, 1, 0, 0, Color(0.0, 0.0, 1.0, 0.25))
	_write_collision(collision, width, height, 1, 0, 0, 0.2)

	_write_collision(collision, width, height, 2, 1, 0, 0.8)

	_write_visual(visual, width, height, 0, 2, 1, Color(0.0, 1.0, 0.0, 0.1))
	_write_visual(visual, width, height, 2, 2, 1, Color(1.0, 1.0, 0.0, 0.6))
	_write_collision(collision, width, height, 2, 2, 1, 0.3)

	var result := TargetSVPreviewGPUScript.build_preview_gpu(
		visual.to_byte_array(),
		collision.to_byte_array(),
		width,
		height,
		slice_count
	)
	if not bool(result.get("ok", false)):
		push_error("[test_target_sv_preview_gpu] GPU preview failed: %s" % str(result))
		return false
	if str(result.get("stats_source", "")) != "target_sv_preview_compute":
		push_error("[test_target_sv_preview_gpu] expected compute stats source")
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("[test_target_sv_preview_gpu] GPU result must not report CPU fallback")
		return false

	var actual: PackedFloat32Array = result.get("preview_rgba32f", PackedFloat32Array())
	var expected := _make_cpu_reference_preview(visual, collision, width, height, slice_count)
	if actual.size() != expected.size():
		push_error("[test_target_sv_preview_gpu] preview size mismatch")
		return false
	for i in range(expected.size()):
		if absf(float(actual[i]) - float(expected[i])) > 0.001:
			push_error("[test_target_sv_preview_gpu] preview[%d] expected %.6f, got %.6f" % [
				i,
				float(expected[i]),
				float(actual[i]),
			])
			return false

	if int(result.get("active_pixel_count", 0)) != 3:
		push_error("[test_target_sv_preview_gpu] expected 3 active pixels, got %d" % int(result.get("active_pixel_count", 0)))
		return false

	return true


func _test_edge_guard_dispatch() -> bool:
	var width := 17
	var height := 9
	var slice_count := 2
	var visual := PackedFloat32Array()
	var collision := PackedFloat32Array()
	visual.resize(width * height * slice_count * 4)
	collision.resize(width * height * slice_count)
	for z in range(height):
		for x in range(width):
			_write_visual(visual, width, height, 0, x, z, Color(0.25, 0.5, 1.0, 0.4))

	var result := TargetSVPreviewGPUScript.build_preview_gpu(
		visual.to_byte_array(),
		collision.to_byte_array(),
		width,
		height,
		slice_count
	)
	if not bool(result.get("ok", false)):
		push_error("[test_target_sv_preview_gpu] edge guarded dispatch failed: %s" % str(result))
		return false
	if int(result.get("active_pixel_count", 0)) != width * height:
		push_error("[test_target_sv_preview_gpu] edge guarded active count mismatch")
		return false
	return true


func _make_cpu_reference_preview(
	visual: PackedFloat32Array,
	collision: PackedFloat32Array,
	width: int,
	height: int,
	slice_count: int
) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(width * height * 4)
	for z in range(height):
		for x in range(width):
			var peak_visual := 0.0
			var peak_collision := 0.0
			var preview_weight := 0.0
			var weighted_color := Vector3.ZERO
			for slice_index in range(slice_count):
				var voxel_index := _voxel_index(width, height, slice_index, x, z)
				var visual_base := voxel_index * 4
				var complexity := clampf(visual[visual_base + 3], 0.0, 1.0)
				var collision_value := clampf(collision[voxel_index], 0.0, 1.0)
				var voxel_weight := pow(maxf(complexity, collision_value), 2.0)
				peak_visual = maxf(peak_visual, complexity)
				peak_collision = maxf(peak_collision, collision_value)
				preview_weight += voxel_weight
				weighted_color += Vector3(
					clampf(visual[visual_base + 0], 0.0, 1.0),
					clampf(visual[visual_base + 1], 0.0, 1.0),
					clampf(visual[visual_base + 2], 0.0, 1.0)
				) * voxel_weight

			var color := Vector3.ZERO
			if preview_weight > 0.00001:
				color = weighted_color / preview_weight
			var tint := Vector3(0.72, 0.68, 0.60)
			color = color.lerp(tint, clampf(peak_collision * 0.35, 0.0, 1.0))

			var pixel_base := (z * width + x) * 4
			result[pixel_base + 0] = clampf(color.x, 0.0, 1.0)
			result[pixel_base + 1] = clampf(color.y, 0.0, 1.0)
			result[pixel_base + 2] = clampf(color.z, 0.0, 1.0)
			result[pixel_base + 3] = maxf(peak_visual, peak_collision)
	return result


func _write_visual(
	visual: PackedFloat32Array,
	width: int,
	height: int,
	slice_index: int,
	x: int,
	z: int,
	value: Color
) -> void:
	var base := _voxel_index(width, height, slice_index, x, z) * 4
	visual[base + 0] = value.r
	visual[base + 1] = value.g
	visual[base + 2] = value.b
	visual[base + 3] = value.a


func _write_collision(
	collision: PackedFloat32Array,
	width: int,
	height: int,
	slice_index: int,
	x: int,
	z: int,
	value: float
) -> void:
	collision[_voxel_index(width, height, slice_index, x, z)] = value


func _voxel_index(width: int, height: int, slice_index: int, x: int, z: int) -> int:
	return slice_index * width * height + z * width + x
