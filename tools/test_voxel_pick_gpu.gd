extends SceneTree

const VoxelPickGPUScript := preload("res://scripts/voxel_pick_gpu.gd")


func _pack_rgba8_for_test(color: Color) -> int:
	var r := int(round(clampf(color.r, 0.0, 1.0) * 255.0))
	var g := int(round(clampf(color.g, 0.0, 1.0) * 255.0))
	var b := int(round(clampf(color.b, 0.0, 1.0) * 255.0))
	var a := int(round(clampf(color.a, 0.0, 1.0) * 255.0))
	return ((r & 0xFF) << 24) | ((g & 0xFF) << 16) | ((b & 0xFF) << 8) | (a & 0xFF)


func _init() -> void:
	print("[VoxelPickGPU] === GPU pick shader smoke ===")
	var rd_available := RenderingServer.get_rendering_device() != null
	print("[VoxelPickGPU] RenderingDevice available: %s" % str(rd_available))
	if not rd_available:
		push_error("[VoxelPickGPU] RenderingDevice unavailable; run with --rendering-driver vulkan.")
		quit(1)
		return

	var ok := true
	ok = _test_scene_voxel_pick() and ok
	ok = _test_targetsv_pick() and ok

	if ok:
		print("[VoxelPickGPU] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[VoxelPickGPU] SOME TESTS FAILED")
		quit(1)


func _test_scene_voxel_pick() -> bool:
	print("[VoxelPickGPU] test_scene_voxel_pick...")
	var picker = VoxelPickGPUScript.new()
	var heights := PackedFloat32Array()
	heights.resize(16)
	var result: Dictionary = picker.pick_scene_voxel(
		Vector3(0.0, 10.0, 0.0),
		Vector3(0.0, -1.0, 0.0),
		heights,
		4,
		Vector3(-5.0, -1.0, -5.0),
		Vector3i(10, 4, 10),
		Vector3.ONE,
		10.0,
		20.0,
		0.0
	)
	picker.dispose(true)
	if not bool(result.get("ok", false)):
		push_error("[VoxelPickGPU] scene voxel pick failed: %s" % str(result))
		return false
	var coord: Vector3i = result.get("voxel_coord", Vector3i.ZERO)
	if coord != Vector3i(5, 1, 5):
		push_error("[VoxelPickGPU] scene voxel coord mismatch: %s result=%s" % [str(coord), str(result)])
		return false
	print("[VoxelPickGPU] PASS scene voxel pick -> %s" % str(coord))
	return true


func _test_targetsv_pick() -> bool:
	print("[VoxelPickGPU] test_targetsv_pick...")
	var texture_size := 4
	var slice_count := 2
	var voxel_count := texture_size * texture_size * slice_count
	var visual := PackedByteArray()
	visual.resize(voxel_count * 4)
	var collision := PackedByteArray()
	collision.resize(voxel_count)
	var hit_x := 2
	var hit_z := 2
	var hit_slice := 0
	var hit_idx := (hit_slice * texture_size + hit_z) * texture_size + hit_x
	visual.encode_u32(hit_idx * 4, _pack_rgba8_for_test(Color(0.25, 0.50, 0.75, 1.0)))
	collision[hit_idx] = 0

	var terrain := PackedFloat32Array()
	terrain.resize(texture_size * texture_size)
	var capture_size := 10.0
	var vertical_span := 4.0
	var display_scale := 1.0
	var denom := float(texture_size - 1)
	var target_x := (float(hit_x) / denom - 0.5) * capture_size * display_scale
	var target_z := (float(hit_z) / denom - 0.5) * capture_size * display_scale
	var target_y := (float(hit_slice) + 0.5) / float(slice_count) * vertical_span

	var picker = VoxelPickGPUScript.new()
	var result: Dictionary = picker.pick_targetsv(
		Vector3(target_x, target_y + 10.0, target_z),
		Vector3(0.0, -1.0, 0.0),
		hit_x,
		hit_z,
		visual,
		collision,
		texture_size,
		slice_count,
		capture_size,
		vertical_span,
		display_scale,
		Vector3.ZERO,
		terrain,
		texture_size,
		1,
		0.001
	)
	picker.dispose(true)
	if not bool(result.get("ok", false)):
		push_error("[VoxelPickGPU] TargetSV pick failed: %s" % str(result))
		return false
	var coord: Vector3i = result.get("voxel_coord", Vector3i.ZERO)
	var buffer_index := int(result.get("buffer_index", -1))
	if coord != Vector3i(hit_x, hit_slice, hit_z) or buffer_index != hit_idx:
		push_error("[VoxelPickGPU] TargetSV mismatch: coord=%s buffer=%d result=%s" % [
			str(coord), buffer_index, str(result)
		])
		return false
	print("[VoxelPickGPU] PASS TargetSV pick -> %s buffer=%d" % [str(coord), buffer_index])
	return true
