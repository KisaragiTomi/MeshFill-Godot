class_name HeightToSceneDepthGPU
extends SceneTree

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")
const TerrainGPUUtil := preload("res://tools/terrain/terrain_gpu_util.gd")

const SHADER_PATH := "res://shaders/height_to_scene_depth.glsl"
const DEFAULT_WIDTH := 256
const DEFAULT_HEIGHT := 256
const DEFAULT_MAX_HEIGHT := 120.0
const FLOATS_PER_R32F_HEIGHT_PIXEL := 1
const FLOATS_PER_RGBA32F_PIXEL := 4
const HEIGHT_CHANNEL_R := 0
const INPUT_STRIDE_R32F := 1
const INPUT_STRIDE_RGBA32F := 4
const LOCAL_SIZE := 256
const STATS_BUFFER_BYTES := 16
const STATS_MIN_DEPTH_KEY_OFFSET := 0
const STATS_MAX_DEPTH_KEY_OFFSET := 4
const STATS_MIN_HEIGHT_KEY_OFFSET := 8
const STATS_MAX_HEIGHT_KEY_OFFSET := 12
const POSITIVE_INF_ORDERED_KEY := 0xFF800000
const NEGATIVE_INF_ORDERED_KEY := 0x007FFFFF


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("Usage: godot --path . --rendering-driver vulkan --script tools/terrain/height_to_scene_depth_gpu.gd -- <height_rgba32f.raw> <scene_depth_rgba32f.raw> [width] [height] [max_height]")
		print("  GPU tool: --headless is prohibited; requires --rendering-driver vulkan.")
		quit(OK)
		return

	var src_path := str(args[0])
	var dst_path := str(args[1])
	var width := int(args[2]) if args.size() > 2 else DEFAULT_WIDTH
	var height := int(args[3]) if args.size() > 3 else DEFAULT_HEIGHT
	var max_height := float(args[4]) if args.size() > 4 else DEFAULT_MAX_HEIGHT
	var result := convert_height_raw_rgba_file_gpu(src_path, dst_path, width, height, max_height)
	if not bool(result.get("ok", false)):
		push_error("HeightToSceneDepthGPU: conversion failed: %s" % str(result))
		quit(FAILED)
		return
	print("HeightToSceneDepthGPU: wrote %s depth_range=%s height_range=%s" % [
		_resolve_path(dst_path),
		str(result.get("depth_range", Vector2.ZERO)),
		str(result.get("height_range", Vector2.ZERO)),
	])
	quit(OK)


static func convert_height_raw_rgba_file_gpu(
	src_path: String,
	dst_path: String,
	width: int = DEFAULT_WIDTH,
	height: int = DEFAULT_HEIGHT,
	max_height: float = DEFAULT_MAX_HEIGHT
) -> Dictionary:
	var resolved_src := _resolve_path(src_path)
	var file := FileAccess.open(src_path, FileAccess.READ) if TerrainGPUUtil.is_virtual_path(src_path) else FileAccess.open(resolved_src, FileAccess.READ)
	if file == null:
		return TerrainGPUUtil.gpu_blocked("source_open_failed", width, height)

	var expected_bytes := width * height * FLOATS_PER_RGBA32F_PIXEL * 4
	var read_size := file.get_length()
	if read_size <= 0:
		read_size = expected_bytes
	var bytes := file.get_buffer(read_size)
	file = null
	if bytes.size() != expected_bytes:
		var size_block := TerrainGPUUtil.gpu_blocked("source_size_mismatch", width, height)
		size_block["actual_bytes"] = bytes.size()
		size_block["expected_bytes"] = expected_bytes
		size_block["source_path"] = resolved_src
		return size_block

	var result := make_scene_depth_from_height_raw_rgba_gpu(bytes, width, height, max_height)
	if not bool(result.get("ok", false)):
		return result

	var resolved_dst := _resolve_path(dst_path)
	var out_file := FileAccess.open(dst_path, FileAccess.WRITE) if TerrainGPUUtil.is_virtual_path(dst_path) else FileAccess.open(resolved_dst, FileAccess.WRITE)
	if out_file == null:
		return TerrainGPUUtil.gpu_blocked("destination_open_failed", width, height)
	out_file.store_buffer(result.get("scene_depth_bytes", PackedByteArray()))
	out_file = null
	result["source_path"] = resolved_src
	result["destination_path"] = resolved_dst
	return result


static func make_scene_depth_from_heights_gpu(
	height_values: PackedFloat32Array,
	width: int,
	height: int,
	max_height: float = DEFAULT_MAX_HEIGHT
) -> Dictionary:
	var pixel_count := width * height
	if width <= 0 or height <= 0 or height_values.size() != pixel_count:
		return TerrainGPUUtil.gpu_blocked("invalid_height_data", width, height)
	return _make_scene_depth_from_height_bytes_gpu(
		height_values.to_byte_array(),
		width,
		height,
		max_height,
		INPUT_STRIDE_R32F,
		HEIGHT_CHANNEL_R,
		"r32f_storage_buffer"
	)


static func make_scene_depth_from_height_raw_rgba_gpu(
	height_raw_rgba32f_bytes: PackedByteArray,
	width: int,
	height: int,
	max_height: float = DEFAULT_MAX_HEIGHT
) -> Dictionary:
	var pixel_count := width * height
	if width <= 0 or height <= 0 or height_raw_rgba32f_bytes.size() != pixel_count * FLOATS_PER_RGBA32F_PIXEL * 4:
		return TerrainGPUUtil.gpu_blocked("invalid_height_raw_data", width, height)
	return _make_scene_depth_from_height_bytes_gpu(
		height_raw_rgba32f_bytes,
		width,
		height,
		max_height,
		INPUT_STRIDE_RGBA32F,
		HEIGHT_CHANNEL_R,
		"rgba32f_storage_buffer_r_channel"
	)


static func _make_scene_depth_from_height_bytes_gpu(
	height_bytes: PackedByteArray,
	width: int,
	height: int,
	max_height: float,
	input_stride: int,
	height_channel: int,
	height_format: String
) -> Dictionary:
	var pixel_count := width * height
	if width <= 0 or height <= 0 or input_stride <= 0 or height_channel < 0 or height_channel >= input_stride:
		return TerrainGPUUtil.gpu_blocked("invalid_height_data", width, height)
	if height_bytes.size() != pixel_count * input_stride * 4:
		return TerrainGPUUtil.gpu_blocked("invalid_height_data", width, height)

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "HeightToSceneDepthGPU"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("missing_rendering_device", width, height)

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(SHADER_PATH)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("shader_not_ready", width, height)

	var height_buf := compute.storage_buffer_from_bytes(height_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "height_to_scene_depth_input_%s" % height_format)
	var scene_depth_buf := compute.storage_buffer_zero(pixel_count * FLOATS_PER_RGBA32F_PIXEL * 4, ComputeShaderBaseScript.SCOPE_FRAME, "scene_depth_rgba32f")
	var stats_init := PackedByteArray()
	stats_init.resize(STATS_BUFFER_BYTES)
	stats_init.encode_u32(STATS_MIN_DEPTH_KEY_OFFSET, POSITIVE_INF_ORDERED_KEY)
	stats_init.encode_u32(STATS_MAX_DEPTH_KEY_OFFSET, NEGATIVE_INF_ORDERED_KEY)
	stats_init.encode_u32(STATS_MIN_HEIGHT_KEY_OFFSET, POSITIVE_INF_ORDERED_KEY)
	stats_init.encode_u32(STATS_MAX_HEIGHT_KEY_OFFSET, NEGATIVE_INF_ORDERED_KEY)
	var stats_buf := compute.storage_buffer_from_bytes(stats_init, ComputeShaderBaseScript.SCOPE_FRAME, "height_to_scene_depth_stats_u32")
	if not height_buf.is_valid() or not scene_depth_buf.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("resource_create_failed", width, height)

	var set0 := compute.create_uniform_set([
		compute.make_storage_uniform(0, height_buf),
		compute.make_storage_uniform(1, scene_depth_buf),
		compute.make_storage_uniform(2, stats_buf),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "height_to_scene_depth_set0")
	if not set0.is_valid():
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("uniform_set_failed", width, height)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, pixel_count)
	push.encode_s32(4, input_stride)
	push.encode_s32(8, height_channel)
	push.encode_s32(12, 0)
	push.encode_float(16, max_height)
	push.encode_float(20, 0.0)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var groups := compute.dispatch_groups_1d(pixel_count, LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("compute_list_begin_failed", width, height)
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	compute.end_compute_list()
	compute.submit_and_sync()

	var scene_depth_bytes := rd.buffer_get_data(scene_depth_buf, 0, pixel_count * FLOATS_PER_RGBA32F_PIXEL * 4)
	var stats_bytes := rd.buffer_get_data(stats_buf, 0, STATS_BUFFER_BYTES)
	compute.dispose()
	if scene_depth_bytes.size() != pixel_count * FLOATS_PER_RGBA32F_PIXEL * 4 or stats_bytes.size() < STATS_BUFFER_BYTES:
		return TerrainGPUUtil.gpu_blocked("readback_failed", width, height)

	var min_depth := _ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MIN_DEPTH_KEY_OFFSET)))
	var max_depth := _ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MAX_DEPTH_KEY_OFFSET)))
	var min_height := _ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MIN_HEIGHT_KEY_OFFSET)))
	var max_input_height := _ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MAX_HEIGHT_KEY_OFFSET)))
	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"width": width,
		"height": height,
		"pixel_count": pixel_count,
		"height_format": height_format,
		"height_input_stride": input_stride,
		"height_channel": height_channel,
		"scene_depth_format": "rgba32f_storage_buffer",
		"scene_depth_layout": "pixel-major RGBA32F: R=max_height-height, G=0, B=0, A=1",
		"dispatch_groups": groups,
		"local_size": LOCAL_SIZE,
		"scene_depth_bytes": scene_depth_bytes,
		"scene_depth_values": scene_depth_bytes.to_float32_array(),
		"depth_range": Vector2(min_depth, max_depth),
		"height_range": Vector2(min_height, max_input_height),
		"stats_source": "height_to_scene_depth_compute",
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

