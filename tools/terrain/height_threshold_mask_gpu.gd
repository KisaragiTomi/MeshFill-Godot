class_name HeightThresholdMaskGPU
extends RefCounted

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

const SHADER_PATH := "res://shaders/height_threshold_mask.glsl"
const STATS_BUFFER_BYTES := 12
const STATS_ACTIVE_COUNT_OFFSET := 0
const STATS_MIN_KEY_OFFSET := 4
const STATS_MAX_KEY_OFFSET := 8
const LOCAL_SIZE := 32
const MIN_KEY_INIT := 0xFFFFFFFF
const MAX_KEY_INIT := 0


static func make_mask_from_height_image_gpu(
	img: Image,
	min_height: float,
	max_height: float,
	sentinel: float = -10000.0
) -> Dictionary:
	if img == null or img.is_empty():
		return _blocked("missing_height_image")

	var width := img.get_width()
	var height := img.get_height()
	if width <= 0 or height <= 0:
		return _blocked("invalid_dimensions")

	var source_img := img
	if source_img.get_format() != Image.FORMAT_RGBAF:
		source_img = img.duplicate()
		source_img.convert(Image.FORMAT_RGBAF)

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "HeightThresholdMaskGPU"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return _blocked("missing_rendering_device", width, height)

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(SHADER_PATH)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return _blocked("shader_not_ready", width, height)

	var height_tex := compute.upload_texture_2d(
		source_img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"height_threshold_mask_rgba32f"
	)
	var mask_buf := compute.storage_buffer_zero(width * height * 4, ComputeShaderBaseScript.SCOPE_FRAME, "height_threshold_mask_u32")
	var stats_init := PackedByteArray()
	stats_init.resize(STATS_BUFFER_BYTES)
	stats_init.encode_u32(STATS_ACTIVE_COUNT_OFFSET, 0)
	stats_init.encode_u32(STATS_MIN_KEY_OFFSET, MIN_KEY_INIT)
	stats_init.encode_u32(STATS_MAX_KEY_OFFSET, MAX_KEY_INIT)
	var stats_buf := compute.storage_buffer_from_bytes(stats_init, ComputeShaderBaseScript.SCOPE_FRAME, "height_threshold_stats_u32")
	if not height_tex.is_valid() or not mask_buf.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return _blocked("resource_create_failed", width, height)

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return _blocked("sampler_create_failed", width, height)

	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, height_tex),
		compute.make_storage_uniform(1, mask_buf),
		compute.make_storage_uniform(2, stats_buf),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "height_threshold_mask_set0")
	if not set0.is_valid():
		compute.dispose()
		return _blocked("uniform_set_failed", width, height)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_float(8, min_height)
	push.encode_float(12, max_height)
	push.encode_float(16, sentinel)

	var groups := compute.dispatch_groups_2d(width, height, LOCAL_SIZE, LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return _blocked("compute_list_begin_failed", width, height)
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var mask_bytes := rd.buffer_get_data(mask_buf, 0, width * height * 4)
	var stats_bytes := rd.buffer_get_data(stats_buf, 0, STATS_BUFFER_BYTES)
	compute.dispose()
	if mask_bytes.size() != width * height * 4 or stats_bytes.size() < STATS_BUFFER_BYTES:
		return _blocked("readback_failed", width, height)

	var active_count := int(stats_bytes.decode_u32(STATS_ACTIVE_COUNT_OFFSET))
	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"width": width,
		"height": height,
		"pixel_count": width * height,
		"mask_format": "u32",
		"height_format": "rgba32f_r_channel",
		"dispatch_groups": groups,
		"active_count": active_count,
		"min_active_height": _ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MIN_KEY_OFFSET))) if active_count > 0 else 0.0,
		"max_active_height": _ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MAX_KEY_OFFSET))) if active_count > 0 else 0.0,
		"mask_words": mask_bytes.to_int32_array(),
		"mask_bytes": mask_bytes,
		"stats_source": "height_threshold_mask_compute",
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
