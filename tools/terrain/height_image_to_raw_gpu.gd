class_name HeightImageToRawGPU
extends SceneTree

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")
const TerrainGPUUtil := preload("res://tools/terrain/terrain_gpu_util.gd")

const SHADER_PATH := "res://shaders/height_image_to_raw.glsl"
const DEFAULT_HEIGHT_SCALE := 120.0
const FLOATS_PER_RGBA32F_PIXEL := 4
const LOCAL_SIZE := 32
const STATS_BUFFER_BYTES := 12
const STATS_MIN_HEIGHT_KEY_OFFSET := 0
const STATS_MAX_HEIGHT_KEY_OFFSET := 4
const STATS_VALID_PIXEL_COUNT_OFFSET := 8
const POSITIVE_INF_ORDERED_KEY := 0xFF800000
const NEGATIVE_INF_ORDERED_KEY := 0x007FFFFF


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("Usage: godot --path . --rendering-driver vulkan --script tools/terrain/height_image_to_raw_gpu.gd -- <height_image.png> <height_rgba32f.raw> [height_scale] [source_channel]")
		print("  GPU tool: --headless is prohibited; requires --rendering-driver vulkan.")
		quit(OK)
		return

	var src_path := str(args[0])
	var dst_path := str(args[1])
	var height_scale := float(args[2]) if args.size() > 2 else DEFAULT_HEIGHT_SCALE
	var source_channel := int(args[3]) if args.size() > 3 else 0
	var result := convert_height_image_file_gpu(src_path, dst_path, height_scale, source_channel)
	if not bool(result.get("ok", false)):
		push_error("HeightImageToRawGPU: conversion failed: %s" % str(result))
		quit(FAILED)
		return
	print("HeightImageToRawGPU: wrote %s height_range=%s" % [
		_resolve_path(dst_path),
		str(result.get("height_range", Vector2.ZERO)),
	])
	quit(OK)


static func convert_height_image_file_gpu(
	src_path: String,
	dst_path: String,
	height_scale: float = DEFAULT_HEIGHT_SCALE,
	source_channel: int = 0
) -> Dictionary:
	var resolved_src := _resolve_path(src_path)
	var img := Image.new()
	var err := img.load(src_path if TerrainGPUUtil.is_virtual_path(src_path) else resolved_src)
	if err != OK:
		return TerrainGPUUtil.gpu_blocked("source_image_load_failed")

	var result := make_height_raw_from_image_gpu(img, height_scale, source_channel)
	if not bool(result.get("ok", false)):
		return result

	var resolved_dst := _resolve_path(dst_path)
	var out_file := FileAccess.open(dst_path, FileAccess.WRITE) if TerrainGPUUtil.is_virtual_path(dst_path) else FileAccess.open(resolved_dst, FileAccess.WRITE)
	if out_file == null:
		return TerrainGPUUtil.gpu_blocked("destination_open_failed", int(result.get("width", 0)), int(result.get("height", 0)))
	out_file.store_buffer(result.get("raw_bytes", PackedByteArray()))
	out_file = null
	result["source_path"] = resolved_src
	result["destination_path"] = resolved_dst
	return result


static func make_height_raw_from_image_gpu(
	img: Image,
	height_scale: float = DEFAULT_HEIGHT_SCALE,
	source_channel: int = 0
) -> Dictionary:
	if img == null or img.is_empty():
		return TerrainGPUUtil.gpu_blocked("missing_height_image")

	var width := img.get_width()
	var height := img.get_height()
	if width <= 0 or height <= 0:
		return TerrainGPUUtil.gpu_blocked("invalid_dimensions")

	var source_img := img
	if source_img.get_format() != Image.FORMAT_RGBA8:
		source_img = img.duplicate()
		source_img.convert(Image.FORMAT_RGBA8)

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "HeightImageToRawGPU"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("missing_rendering_device", width, height)

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(SHADER_PATH)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("shader_not_ready", width, height)

	var height_tex := compute.upload_texture_2d(
		source_img,
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,
		Image.FORMAT_RGBA8,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"height_image_rgba8_unorm"
	)
	var pixel_count := width * height
	var raw_buf := compute.storage_buffer_zero(pixel_count * FLOATS_PER_RGBA32F_PIXEL * 4, ComputeShaderBaseScript.SCOPE_FRAME, "height_image_to_raw_rgba32f")
	var stats_init := PackedByteArray()
	stats_init.resize(STATS_BUFFER_BYTES)
	stats_init.encode_u32(STATS_MIN_HEIGHT_KEY_OFFSET, POSITIVE_INF_ORDERED_KEY)
	stats_init.encode_u32(STATS_MAX_HEIGHT_KEY_OFFSET, NEGATIVE_INF_ORDERED_KEY)
	stats_init.encode_u32(STATS_VALID_PIXEL_COUNT_OFFSET, 0)
	var stats_buf := compute.storage_buffer_from_bytes(stats_init, ComputeShaderBaseScript.SCOPE_FRAME, "height_image_to_raw_stats_u32")
	if not height_tex.is_valid() or not raw_buf.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("resource_create_failed", width, height)

	var sampler := compute.create_linear_sampler(ComputeShaderBaseScript.SCOPE_FRAME, "height_image_to_raw_sampler")
	if not sampler.is_valid():
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("sampler_create_failed", width, height)

	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, height_tex),
		compute.make_storage_uniform(1, raw_buf),
		compute.make_storage_uniform(2, stats_buf),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "height_image_to_raw_set0")
	if not set0.is_valid():
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("uniform_set_failed", width, height)

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_float(8, height_scale)
	push.encode_s32(12, clampi(source_channel, 0, 3))

	var groups := compute.dispatch_groups_2d(width, height, LOCAL_SIZE, LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("compute_list_begin_failed", width, height)
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var raw_bytes := rd.buffer_get_data(raw_buf, 0, pixel_count * FLOATS_PER_RGBA32F_PIXEL * 4)
	var stats_bytes := rd.buffer_get_data(stats_buf, 0, STATS_BUFFER_BYTES)
	compute.dispose()
	if raw_bytes.size() != pixel_count * FLOATS_PER_RGBA32F_PIXEL * 4 or stats_bytes.size() < STATS_BUFFER_BYTES:
		return TerrainGPUUtil.gpu_blocked("readback_failed", width, height)

	var valid_pixel_count := int(stats_bytes.decode_u32(STATS_VALID_PIXEL_COUNT_OFFSET))
	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"stats_source": "height_image_to_raw_compute",
		"width": width,
		"height": height,
		"pixel_count": pixel_count,
		"source_format": "rgba8_unorm_texture",
		"source_channel": clampi(source_channel, 0, 3),
		"source_valid_range": "normalized channel [0, 1] from 8-bit image data",
		"output_format": "rgba32f_storage_buffer",
		"output_layout": "pixel-major RGBA32F: R=source_channel*height_scale, G=0, B=0, A=0",
		"output_stride_bytes": FLOATS_PER_RGBA32F_PIXEL * 4,
		"output_valid_range": Vector2(0.0, height_scale),
		"dispatch_local_size": Vector2i(LOCAL_SIZE, LOCAL_SIZE),
		"dispatch_groups": groups,
		"raw_bytes": raw_bytes,
		"raw_values": raw_bytes.to_float32_array(),
		"valid_pixel_count": valid_pixel_count,
		"height_range": Vector2(
			_ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MIN_HEIGHT_KEY_OFFSET))) if valid_pixel_count > 0 else 0.0,
			_ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MAX_HEIGHT_KEY_OFFSET))) if valid_pixel_count > 0 else 0.0
		),
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


static func _resolve_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path

