extends SceneTree

const SVC := preload("res://scripts/scene_voxel_committer.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[test_collision_max_compute] SKIP: no local RenderingDevice")
		quit(0)
		return
	probe_rd.free()

	var committer := SVC.new(8, 8.0, true)
	if not committer._gpu_ready:
		push_error("SceneVoxelCommitter GPU pipeline was not ready")
		quit(1)
		return

	var a := Image.create(8, 8, false, Image.FORMAT_RF)
	var b := Image.create(8, 8, false, Image.FORMAT_RF)
	a.fill(Color(0.0, 0.0, 0.0, 0.0))
	b.fill(Color(0.0, 0.0, 0.0, 0.0))
	a.set_pixelv(Vector2i(2, 3), Color(0.25, 0.0, 0.0, 0.0))
	b.set_pixelv(Vector2i(2, 3), Color(0.75, 0.0, 0.0, 0.0))
	a.set_pixelv(Vector2i(7, 1), Color(0.9, 0.0, 0.0, 0.0))
	b.set_pixelv(Vector2i(7, 1), Color(0.1, 0.0, 0.0, 0.0))

	var out: Image = committer._max_collision_images_gpu(a, b)
	var out_values := out.get_data().to_float32_array()
	var p0 := out_values[2 + 3 * out.get_width()]
	var p1 := out_values[7 + 1 * out.get_width()]
	if absf(p0 - 0.75) > 0.001:
		push_error("Expected max collision 0.75 at (2,3), got %.6f" % p0)
		quit(1)
		return
	if absf(p1 - 0.9) > 0.001:
		push_error("Expected max collision 0.9 at (7,1), got %.6f" % p1)
		quit(1)
		return

	var stamped_r32 := committer._stamp_scalar_image_disc(a, Vector2i(4, 4), 1, 0.6, 0)
	var stamped_r32_values := stamped_r32.get_data().to_float32_array()
	if absf(stamped_r32_values[4 + 4 * stamped_r32.get_width()] - 0.6) > 0.001:
		push_error("Expected GPU R32 disc stamp at center")
		quit(1)
		return
	if stamped_r32_values[6 + 4 * stamped_r32.get_width()] > 0.001:
		push_error("GPU R32 disc stamp leaked outside radius")
		quit(1)
		return
	var sampled_r32 := committer._sample_scalar_image_pixel_gpu(stamped_r32, Vector2i(4, 4))
	if not bool(sampled_r32.get("ok", false)) or absf(float(sampled_r32.get("value", 0.0)) - 0.6) > 0.001:
		push_error("Expected GPU R32 pixel sample at stamped center, got %s" % str(sampled_r32))
		quit(1)
		return

	var rgba := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	rgba.fill(Color(0.0, 0.0, 0.0, 0.0))
	var stamped_rgba := committer._stamp_scalar_image_disc(rgba, Vector2i(3, 3), 1, 0.7, 2)
	if absf(stamped_rgba.get_pixelv(Vector2i(3, 3)).b - 0.7) > 0.001:
		push_error("Expected GPU RGBA channel disc stamp at center")
		quit(1)
		return
	if stamped_rgba.get_pixelv(Vector2i(3, 3)).r > 0.001 or stamped_rgba.get_pixelv(Vector2i(3, 3)).g > 0.001:
		push_error("GPU RGBA channel disc stamp wrote the wrong channel")
		quit(1)
		return

	var collect_source := Image.create(8, 8, false, Image.FORMAT_RF)
	collect_source.fill(Color(0.0, 0.0, 0.0, 0.0))
	collect_source.set_pixelv(Vector2i(4, 4), Color(0.8, 0.0, 0.0, 0.0))
	var collected := committer._collect_disc_pixels_gpu(collect_source, Vector2i(4, 4), 1, 0.5, false, false)
	var collected_keys := {}
	for px in collected:
		collected_keys[str(px)] = true
	if collected_keys.size() != 4 or collected_keys.has(str(Vector2i(4, 4))):
		push_error("Expected GPU disc collector to skip pixels whose previous value is already higher, got %s" % str(collected))
		quit(1)
		return
	var forced_collected := committer._collect_disc_pixels_gpu(collect_source, Vector2i(4, 4), 1, 0.0, true, true)
	if forced_collected.size() != 5:
		push_error("Expected force-write GPU disc collector to return every radius-1 disc pixel, got %s" % str(forced_collected))
		quit(1)
		return

	var base_field := PackedFloat32Array()
	base_field.resize(8 * 8)
	base_field[1] = 0.2
	var collision_records := {
		"collision:2:2": {
			"voxel_xz": Vector2i(2, 2),
			"slice_index": 0,
			"collision_strength": 0.8,
		}
	}
	var merged := committer._merge_sv_collision_records_gpu(base_field, collision_records, 8, 1)
	var merge_idx := 2 + 8 * 2
	if merged.size() != base_field.size() or absf(merged[merge_idx] - 0.8) > 0.001 or absf(merged[1] - 0.2) > 0.001:
		push_error("Expected GPU SV collision record merge to preserve base and apply record")
		quit(1)
		return

	committer.dispose()
	print("[test_collision_max_compute] OK")
	quit(0)
