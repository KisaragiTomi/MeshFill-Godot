class_name TargetColorRgba8PackGPU
extends RefCounted

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

const SHADER_PATH := "res://shaders/target_color_rgba8_pack.glsl"
const LOCAL_SIZE := 64
const FLOATS_PER_RGBA32F_VOXEL := 4
const RGBA32F_STRIDE_BYTES := 16
const RGBA8_WORD_STRIDE_BYTES := 4
const STATS_BUFFER_BYTES := 16
const STATS_ACTIVE_ALPHA_COUNT_OFFSET := 0
const STATS_MAX_ALPHA_Q_OFFSET := 4
const STATS_COMPONENT_CLAMP_COUNT_OFFSET := 8


static func pack_rgba32f_values_to_rgba8_gpu(
	rgba32f_values: PackedFloat32Array,
	voxel_count: int = -1,
	active_epsilon: float = 0.001
) -> Dictionary:
	var resolved_voxel_count := voxel_count
	if resolved_voxel_count < 0:
		if rgba32f_values.size() % FLOATS_PER_RGBA32F_VOXEL != 0:
			return _blocked("rgba32f_value_count_not_aligned", 0)
		resolved_voxel_count = int(rgba32f_values.size() / FLOATS_PER_RGBA32F_VOXEL)
	if rgba32f_values.size() < resolved_voxel_count * FLOATS_PER_RGBA32F_VOXEL:
		return _blocked("rgba32f_values_too_short", resolved_voxel_count)
	return pack_rgba32f_bytes_to_rgba8_gpu(
		rgba32f_values.to_byte_array(),
		resolved_voxel_count,
		active_epsilon
	)


static func pack_rgba32f_bytes_to_rgba8_gpu(
	rgba32f_bytes: PackedByteArray,
	voxel_count: int,
	active_epsilon: float = 0.001
) -> Dictionary:
	if voxel_count <= 0:
		return _blocked("invalid_voxel_count", voxel_count)

	var expected_input_bytes := voxel_count * RGBA32F_STRIDE_BYTES
	var expected_output_bytes := voxel_count * RGBA8_WORD_STRIDE_BYTES
	if rgba32f_bytes.size() < expected_input_bytes:
		var size_block := _blocked("rgba32f_bytes_too_short", voxel_count)
		size_block["expected_input_bytes"] = expected_input_bytes
		size_block["actual_input_bytes"] = rgba32f_bytes.size()
		return size_block

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "TargetColorRgba8PackGPU"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return _blocked("missing_rendering_device", voxel_count)

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(SHADER_PATH)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return _blocked("shader_not_ready", voxel_count)

	var color_in_buffer := compute.storage_buffer_from_bytes(
		rgba32f_bytes.slice(0, expected_input_bytes),
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_color_pack_rgba32f_in"
	)
	var color_out_buffer := compute.storage_buffer_zero(
		expected_output_bytes,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_color_pack_rgba8_out"
	)
	var stats_buffer := compute.storage_buffer_zero(
		STATS_BUFFER_BYTES,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_color_pack_stats_u32"
	)
	if not color_in_buffer.is_valid() or not color_out_buffer.is_valid() or not stats_buffer.is_valid():
		compute.dispose()
		return _blocked("resource_create_failed", voxel_count)

	var set0 := compute.create_uniform_set([
		compute.make_storage_uniform(0, color_in_buffer),
		compute.make_storage_uniform(1, color_out_buffer),
		compute.make_storage_uniform(2, stats_buffer),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "target_color_rgba8_pack_set0")
	if not set0.is_valid():
		compute.dispose()
		return _blocked("uniform_set_failed", voxel_count)

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, voxel_count)
	push.encode_float(4, active_epsilon)
	push.encode_s32(8, 0)
	push.encode_s32(12, 0)

	var groups := compute.dispatch_groups_1d(voxel_count, LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return _blocked("compute_list_begin_failed", voxel_count)
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	compute.end_compute_list()
	compute.submit_and_sync()

	var rgba8_bytes := rd.buffer_get_data(color_out_buffer, 0, expected_output_bytes)
	var stats_bytes := rd.buffer_get_data(stats_buffer, 0, STATS_BUFFER_BYTES)
	compute.dispose()
	if rgba8_bytes.size() != expected_output_bytes or stats_bytes.size() < STATS_BUFFER_BYTES:
		return _blocked("readback_failed", voxel_count)

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"stats_source": "target_color_rgba8_pack_compute",
		"voxel_count": voxel_count,
		"input_format": "rgba32f_storage_buffer",
		"input_layout": "voxel-major RGBA32F: color.rgb, complexity/alpha",
		"input_stride_bytes": RGBA32F_STRIDE_BYTES,
		"output_format": "rgba8_u32_storage_buffer",
		"output_layout": "one u32 per voxel: (r << 24) | (g << 16) | (b << 8) | a",
		"output_stride_bytes": RGBA8_WORD_STRIDE_BYTES,
		"valid_range": "input components clamped to [0, 1] before pack",
		"dispatch_local_size": LOCAL_SIZE,
		"dispatch_groups": groups,
		"target_color_rgba8_bytes": rgba8_bytes,
		"target_color_rgba8_words": rgba8_bytes.to_int32_array(),
		"active_alpha_count": int(stats_bytes.decode_u32(STATS_ACTIVE_ALPHA_COUNT_OFFSET)),
		"max_alpha": float(stats_bytes.decode_u32(STATS_MAX_ALPHA_Q_OFFSET)) / 1000000.0,
		"component_clamp_count": int(stats_bytes.decode_u32(STATS_COMPONENT_CLAMP_COUNT_OFFSET)),
	}


static func _blocked(reason: String, voxel_count: int = 0) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"voxel_count": maxi(voxel_count, 0),
	}
