class_name TerrainRawPackGPU
extends RefCounted

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

const SHADER_PATH := "res://shaders/pack_rgba_raw_channels.glsl"
const LOCAL_SIZE := 256
const FLOATS_PER_RGBA32F_PIXEL := 4
const STATS_BUFFER_BYTES := 12
const STATS_MIN_R_KEY_OFFSET := 0
const STATS_MAX_R_KEY_OFFSET := 4
const STATS_VALID_PIXEL_COUNT_OFFSET := 8
const POSITIVE_INF_ORDERED_KEY := 0xFF800000
const NEGATIVE_INF_ORDERED_KEY := 0x007FFFFF


static func pack_scalar_channels_gpu(
	channel_r: PackedFloat32Array,
	width: int,
	height: int,
	channel_g: PackedFloat32Array = PackedFloat32Array(),
	channel_b: PackedFloat32Array = PackedFloat32Array(),
	channel_a: PackedFloat32Array = PackedFloat32Array()
) -> Dictionary:
	var pixel_count := width * height
	if width <= 0 or height <= 0 or channel_r.size() != pixel_count:
		return _blocked("invalid_r_channel", width, height)

	var g_valid := channel_g.size() == pixel_count
	var b_valid := channel_b.size() == pixel_count
	var a_valid := channel_a.size() == pixel_count
	if channel_g.size() > 0 and not g_valid:
		return _blocked("invalid_g_channel", width, height)
	if channel_b.size() > 0 and not b_valid:
		return _blocked("invalid_b_channel", width, height)
	if channel_a.size() > 0 and not a_valid:
		return _blocked("invalid_a_channel", width, height)

	var zero_channel := PackedFloat32Array()
	zero_channel.resize(pixel_count)

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "TerrainRawPackGPU"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return _blocked("missing_rendering_device", width, height)

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(SHADER_PATH)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return _blocked("shader_not_ready", width, height)

	var r_buf := compute.storage_buffer_from_floats(channel_r, ComputeShaderBaseScript.SCOPE_FRAME, "terrain_raw_pack_r32f_r")
	var g_buf := compute.storage_buffer_from_floats(channel_g if g_valid else zero_channel, ComputeShaderBaseScript.SCOPE_FRAME, "terrain_raw_pack_r32f_g")
	var b_buf := compute.storage_buffer_from_floats(channel_b if b_valid else zero_channel, ComputeShaderBaseScript.SCOPE_FRAME, "terrain_raw_pack_r32f_b")
	var a_buf := compute.storage_buffer_from_floats(channel_a if a_valid else zero_channel, ComputeShaderBaseScript.SCOPE_FRAME, "terrain_raw_pack_r32f_a")
	var out_buf := compute.storage_buffer_zero(pixel_count * FLOATS_PER_RGBA32F_PIXEL * 4, ComputeShaderBaseScript.SCOPE_FRAME, "terrain_raw_pack_rgba32f")
	var stats_init := PackedByteArray()
	stats_init.resize(STATS_BUFFER_BYTES)
	stats_init.encode_u32(STATS_MIN_R_KEY_OFFSET, POSITIVE_INF_ORDERED_KEY)
	stats_init.encode_u32(STATS_MAX_R_KEY_OFFSET, NEGATIVE_INF_ORDERED_KEY)
	stats_init.encode_u32(STATS_VALID_PIXEL_COUNT_OFFSET, 0)
	var stats_buf := compute.storage_buffer_from_bytes(stats_init, ComputeShaderBaseScript.SCOPE_FRAME, "terrain_raw_pack_stats_u32")
	if not r_buf.is_valid() or not g_buf.is_valid() or not b_buf.is_valid() or not a_buf.is_valid() or not out_buf.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return _blocked("resource_create_failed", width, height)

	var set0 := compute.create_uniform_set([
		compute.make_storage_uniform(0, r_buf),
		compute.make_storage_uniform(1, g_buf),
		compute.make_storage_uniform(2, b_buf),
		compute.make_storage_uniform(3, a_buf),
		compute.make_storage_uniform(4, out_buf),
		compute.make_storage_uniform(5, stats_buf),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "terrain_raw_pack_set0")
	if not set0.is_valid():
		compute.dispose()
		return _blocked("uniform_set_failed", width, height)

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, pixel_count)
	push.encode_s32(4, 1 if g_valid else 0)
	push.encode_s32(8, 1 if b_valid else 0)
	push.encode_s32(12, 1 if a_valid else 0)

	var groups := compute.dispatch_groups_1d(pixel_count, LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return _blocked("compute_list_begin_failed", width, height)
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	compute.end_compute_list()
	compute.submit_and_sync()

	var packed_bytes := rd.buffer_get_data(out_buf, 0, pixel_count * FLOATS_PER_RGBA32F_PIXEL * 4)
	var stats_bytes := rd.buffer_get_data(stats_buf, 0, STATS_BUFFER_BYTES)
	compute.dispose()
	if packed_bytes.size() != pixel_count * FLOATS_PER_RGBA32F_PIXEL * 4 or stats_bytes.size() < STATS_BUFFER_BYTES:
		return _blocked("readback_failed", width, height)

	var valid_pixel_count := int(stats_bytes.decode_u32(STATS_VALID_PIXEL_COUNT_OFFSET))
	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"stats_source": "pack_rgba_raw_channels_compute",
		"width": width,
		"height": height,
		"pixel_count": pixel_count,
		"input_format": "r32f_scalar_channels",
		"output_format": "rgba32f_storage_buffer",
		"output_layout": "pixel-major RGBA32F: [r, g_or_0, b_or_0, a_or_0]",
		"output_stride_bytes": FLOATS_PER_RGBA32F_PIXEL * 4,
		"valid_range": "caller-defined scalar terrain values; missing optional channels are zero-filled",
		"dispatch_local_size": LOCAL_SIZE,
		"dispatch_groups": groups,
		"packed_bytes": packed_bytes,
		"packed_values": packed_bytes.to_float32_array(),
		"valid_pixel_count": valid_pixel_count,
		"min_r": _ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MIN_R_KEY_OFFSET))) if valid_pixel_count > 0 else 0.0,
		"max_r": _ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MAX_R_KEY_OFFSET))) if valid_pixel_count > 0 else 0.0,
	}


static func _blocked(reason: String, width: int = 0, height: int = 0) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"width": width,
		"height": height,
	}


static func _ordered_uint_to_float(key: int) -> float:
	var bits := 0
	if (key & 0x80000000) != 0:
		bits = key ^ 0x80000000
	else:
		bits = (~key) & 0xFFFFFFFF
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, bits)
	return bytes.decode_float(0)
