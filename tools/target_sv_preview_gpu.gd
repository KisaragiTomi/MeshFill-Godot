class_name TargetSVPreviewGPU
extends RefCounted

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

const SHADER_PATH := "res://shaders/target_sv_preview.glsl"
const LOCAL_SIZE := 16
const STATS_BUFFER_BYTES := 4


static func build_preview_gpu(
	visual_rgba32f_bytes: PackedByteArray,
	collision_r32f_bytes: PackedByteArray,
	width: int,
	height: int,
	slice_count: int,
	occupancy_epsilon: float = 0.00001,
	collision_tint: Color = Color(0.72, 0.68, 0.60, 1.0),
	collision_tint_strength: float = 0.35
) -> Dictionary:
	if width <= 0 or height <= 0 or slice_count <= 0:
		return _blocked("invalid_dimensions", width, height, slice_count)

	var voxel_count := width * height * slice_count
	var expected_visual_bytes := voxel_count * 16
	var expected_collision_bytes := voxel_count * 4
	if visual_rgba32f_bytes.size() < expected_visual_bytes:
		return _blocked("visual_rgba32f_bytes_too_short", width, height, slice_count)
	if collision_r32f_bytes.size() < expected_collision_bytes:
		return _blocked("collision_r32f_bytes_too_short", width, height, slice_count)

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "TargetSVPreviewGPU"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return _blocked("missing_rendering_device", width, height, slice_count)

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(SHADER_PATH)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return _blocked("shader_not_ready", width, height, slice_count)

	var visual_buf := compute.storage_buffer_from_bytes(
		visual_rgba32f_bytes.slice(0, expected_visual_bytes),
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_sv_preview_visual_rgba32f"
	)
	var collision_buf := compute.storage_buffer_from_bytes(
		collision_r32f_bytes.slice(0, expected_collision_bytes),
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_sv_preview_collision_r32f"
	)
	var preview_buf := compute.storage_buffer_zero(
		width * height * 16,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_sv_preview_rgba32f"
	)
	var stats_buf := compute.storage_buffer_zero(
		STATS_BUFFER_BYTES,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_sv_preview_stats_u32"
	)
	if not visual_buf.is_valid() or not collision_buf.is_valid() or not preview_buf.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return _blocked("resource_create_failed", width, height, slice_count)

	var set0 := compute.create_uniform_set([
		compute.make_storage_uniform(0, visual_buf),
		compute.make_storage_uniform(1, collision_buf),
		compute.make_storage_uniform(2, preview_buf),
		compute.make_storage_uniform(3, stats_buf),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "target_sv_preview_set0")
	if not set0.is_valid():
		compute.dispose()
		return _blocked("uniform_set_failed", width, height, slice_count)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_s32(8, slice_count)
	push.encode_float(12, occupancy_epsilon)
	push.encode_float(16, collision_tint_strength)
	push.encode_float(20, collision_tint.r)
	push.encode_float(24, collision_tint.g)
	push.encode_float(28, collision_tint.b)

	var groups := compute.dispatch_groups_2d(width, height, LOCAL_SIZE, LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return _blocked("compute_list_begin_failed", width, height, slice_count)
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var preview_bytes := rd.buffer_get_data(preview_buf, 0, width * height * 16)
	var stats_bytes := rd.buffer_get_data(stats_buf, 0, STATS_BUFFER_BYTES)
	compute.dispose()
	if preview_bytes.size() != width * height * 16 or stats_bytes.size() < STATS_BUFFER_BYTES:
		return _blocked("readback_failed", width, height, slice_count)

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"stats_source": "target_sv_preview_compute",
		"width": width,
		"height": height,
		"slice_count": slice_count,
		"voxel_count": voxel_count,
		"volume_layout": "slice_major_z_row_major_x",
		"visual_format": "rgba32f",
		"visual_stride_bytes": 16,
		"collision_format": "r32f",
		"collision_stride_bytes": 4,
		"preview_format": "rgba32f",
		"preview_stride_bytes": 16,
		"valid_range": "visual/collision clamped 0..1",
		"dispatch_local_size": Vector2i(LOCAL_SIZE, LOCAL_SIZE),
		"dispatch_groups": groups,
		"active_pixel_count": int(stats_bytes.decode_u32(0)),
		"preview_bytes": preview_bytes,
		"preview_rgba32f": preview_bytes.to_float32_array(),
	}


static func _blocked(reason: String, width: int = 0, height: int = 0, slice_count: int = 0) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"width": width,
		"height": height,
		"slice_count": slice_count,
	}
