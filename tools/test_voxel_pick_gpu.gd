extends "res://scripts/utils/scene_tree_test.gd"

const VoxelPickGPUScript := preload("res://scripts/voxel_pick_gpu.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")


func _init() -> void:
	print("[VoxelPickGPU] === GPU pick shader smoke ===")
	var rd_available := RenderingServer.get_rendering_device() != null
	print("[VoxelPickGPU] RenderingDevice available: %s" % str(rd_available))
	if not rd_available:
		push_error("[VoxelPickGPU] RenderingDevice unavailable; run with --rendering-driver vulkan.")
		quit(1)
		return

	run_suite("VoxelPickGPU", [
		_test_scene_voxel_pick,
		_test_targetsv_pick,
		_test_targetsv_same_size_content_update,
	])


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
	visual.encode_u32(hit_idx * 4, BufferUtils.pack_shader_rgba8_word(Color(0.25, 0.50, 0.75, 1.0)))
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


# 同尺寸两次写入：同一 picker 实例（持久化 GPU 缓冲复用），内容 A 选中断言值 A，
# 同尺寸换内容 B 后再选中必须断言到值 B——陈旧缓存会错误返回 A。
func _test_targetsv_same_size_content_update() -> bool:
	print("[VoxelPickGPU] test_targetsv_same_size_content_update...")
	var texture_size := 4
	var slice_count := 2
	var voxel_count := texture_size * texture_size * slice_count
	var hit_x := 2
	var hit_z := 2
	var hit_slice := 0
	var hit_idx := (hit_slice * texture_size + hit_z) * texture_size + hit_x

	var terrain := PackedFloat32Array()
	terrain.resize(texture_size * texture_size)
	var capture_size := 10.0
	var vertical_span := 4.0
	var display_scale := 1.0
	var denom := float(texture_size - 1)
	var ray_origin := Vector3(
		(float(hit_x) / denom - 0.5) * capture_size * display_scale,
		(float(hit_slice) + 0.5) / float(slice_count) * vertical_span + 10.0,
		(float(hit_z) / denom - 0.5) * capture_size * display_scale
	)

	# 内容 A: complexity(视觉 alpha)=1.0, collision=51/255=0.2；
	# 内容 B（同尺寸）: complexity=0.6, collision=204/255=0.8。
	var visual_a := PackedByteArray()
	visual_a.resize(voxel_count * 4)
	visual_a.encode_u32(hit_idx * 4, BufferUtils.pack_shader_rgba8_word(Color(0.25, 0.50, 0.75, 1.0)))
	var collision_a := PackedByteArray()
	collision_a.resize(voxel_count)
	collision_a[hit_idx] = 51

	var visual_b := PackedByteArray()
	visual_b.resize(voxel_count * 4)
	visual_b.encode_u32(hit_idx * 4, BufferUtils.pack_shader_rgba8_word(Color(0.25, 0.50, 0.75, 0.6)))
	var collision_b := PackedByteArray()
	collision_b.resize(voxel_count)
	collision_b[hit_idx] = 204

	var picker = VoxelPickGPUScript.new()
	var ok := true
	ok = _assert_targetsv_channels(
		picker, ray_origin, hit_x, hit_z, hit_slice, hit_idx,
		visual_a, collision_a, texture_size, slice_count,
		capture_size, vertical_span, display_scale, terrain,
		1.0, 51.0 / 255.0, "content A"
	)
	if ok:
		ok = _assert_targetsv_channels(
			picker, ray_origin, hit_x, hit_z, hit_slice, hit_idx,
			visual_b, collision_b, texture_size, slice_count,
			capture_size, vertical_span, display_scale, terrain,
			153.0 / 255.0, 204.0 / 255.0, "content B (same-size rewrite)"
		)
	picker.dispose(true)
	if ok:
		print("[VoxelPickGPU] PASS TargetSV same-size content update")
	return ok


# 执行一次 TargetSV 拾取并断言命中坐标与 complexity/collision 通道值。
func _assert_targetsv_channels(
	picker, ray_origin: Vector3, hit_x: int, hit_z: int, hit_slice: int, hit_idx: int,
	visual: PackedByteArray, collision: PackedByteArray, texture_size: int, slice_count: int,
	capture_size: float, vertical_span: float, display_scale: float, terrain: PackedFloat32Array,
	expected_complexity: float, expected_collision: float, label: String
) -> bool:
	var result: Dictionary = picker.pick_targetsv(
		ray_origin,
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
	if not bool(result.get("ok", false)):
		push_error("[VoxelPickGPU] TargetSV %s pick failed: %s" % [label, str(result)])
		return false
	var coord: Vector3i = result.get("voxel_coord", Vector3i.ZERO)
	var buffer_index := int(result.get("buffer_index", -1))
	if coord != Vector3i(hit_x, hit_slice, hit_z) or buffer_index != hit_idx:
		push_error("[VoxelPickGPU] TargetSV %s coord mismatch: coord=%s buffer=%d result=%s" % [
			label, str(coord), buffer_index, str(result)
		])
		return false
	var complexity := float(result.get("complexity", -1.0))
	var collision_value := float(result.get("collision", -1.0))
	if absf(complexity - expected_complexity) > 0.01 or absf(collision_value - expected_collision) > 0.01:
		push_error("[VoxelPickGPU] TargetSV %s stale channel values: complexity=%f (expected %f) collision=%f (expected %f)" % [
			label, complexity, expected_complexity, collision_value, expected_collision
		])
		return false
	return true
