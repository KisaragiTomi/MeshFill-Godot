class_name HeightNormalFromHeightGPU
extends SceneTree

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")
const TerrainGPUUtil := preload("res://tools/terrain/terrain_gpu_util.gd")

const SHADER_PATH := "res://shaders/height_normal_from_height.glsl"
const DEFAULT_WIDTH := 256
const DEFAULT_HEIGHT := 256
const DEFAULT_CELL_SIZE := 120.0 / 256.0
const FLOATS_PER_HEIGHT_RAW_PIXEL := 4
const FLOATS_PER_NORMAL_PIXEL := 4
const LOCAL_SIZE := 16
const STATS_BUFFER_BYTES := 12
const STATS_STEEP_COUNT_OFFSET := 0
const STATS_MIN_NZ_KEY_OFFSET := 4
const STATS_MAX_NZ_KEY_OFFSET := 8
const POSITIVE_INF_ORDERED_KEY := 0xFF800000
const NEGATIVE_INF_ORDERED_KEY := 0x007FFFFF
const INPUT_STRIDE_R32F := 1
const INPUT_STRIDE_RGBA32F := 4
const HEIGHT_CHANNEL_R := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("Usage: godot --path . --rendering-driver vulkan --script tools/terrain/height_normal_from_height_gpu.gd -- <height_rgba32f.raw> <normal_rgba32f.raw> [width] [height] [cell_size]")
		print("  GPU tool: --headless is prohibited; requires --rendering-driver vulkan.")
		quit(OK)
		return

	var src_path := str(args[0])
	var dst_path := str(args[1])
	var width := int(args[2]) if args.size() > 2 else DEFAULT_WIDTH
	var height := int(args[3]) if args.size() > 3 else DEFAULT_HEIGHT
	var cell_size := float(args[4]) if args.size() > 4 else DEFAULT_CELL_SIZE
	var result := convert_height_raw_file_gpu(src_path, dst_path, width, height, cell_size)
	if not bool(result.get("ok", false)):
		push_error("HeightNormalFromHeightGPU: conversion failed: %s" % str(result))
		quit(FAILED)
		return
	print("HeightNormalFromHeightGPU: wrote %s steep=%d min_nz=%.4f max_nz=%.4f" % [
		_resolve_path(dst_path),
		int(result.get("steep_count", 0)),
		float(result.get("min_nz", 0.0)),
		float(result.get("max_nz", 0.0)),
	])
	quit(OK)


static func convert_height_raw_file_gpu(
	src_path: String,
	dst_path: String,
	width: int = DEFAULT_WIDTH,
	height: int = DEFAULT_HEIGHT,
	cell_size: float = DEFAULT_CELL_SIZE,
	steep_nz_threshold: float = 0.75
) -> Dictionary:
	var resolved_src := _resolve_path(src_path)
	var file := FileAccess.open(src_path, FileAccess.READ) if TerrainGPUUtil.is_virtual_path(src_path) else FileAccess.open(resolved_src, FileAccess.READ)
	if file == null:
		return TerrainGPUUtil.gpu_blocked("source_open_failed", width, height)
	var expected_bytes := width * height * FLOATS_PER_HEIGHT_RAW_PIXEL * 4
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

	var result := make_normals_from_height_raw_rgba_gpu(bytes, width, height, cell_size, steep_nz_threshold)
	if not bool(result.get("ok", false)):
		return result

	var resolved_dst := _resolve_path(dst_path)
	var out_file := FileAccess.open(dst_path, FileAccess.WRITE) if TerrainGPUUtil.is_virtual_path(dst_path) else FileAccess.open(resolved_dst, FileAccess.WRITE)
	if out_file == null:
		return TerrainGPUUtil.gpu_blocked("destination_open_failed", width, height)
	out_file.store_buffer(result.get("normal_bytes", PackedByteArray()))
	out_file = null
	result["source_path"] = resolved_src
	result["destination_path"] = resolved_dst
	return result


static func make_normals_from_height_raw_rgba_gpu(
	height_raw_rgba32f_bytes: PackedByteArray,
	width: int,
	height: int,
	cell_size: float,
	steep_nz_threshold: float = 0.75
) -> Dictionary:
	var pixel_count := width * height
	if width <= 0 or height <= 0 or height_raw_rgba32f_bytes.size() != pixel_count * FLOATS_PER_HEIGHT_RAW_PIXEL * 4:
		return TerrainGPUUtil.gpu_blocked("invalid_height_raw_data", width, height)

	return _make_normals_from_height_bytes_gpu(
		height_raw_rgba32f_bytes,
		width,
		height,
		cell_size,
		INPUT_STRIDE_RGBA32F,
		HEIGHT_CHANNEL_R,
		"rgba32f_storage_buffer_r_channel",
		steep_nz_threshold
	)


static func make_normals_from_heights_gpu(
	height_values: PackedFloat32Array,
	width: int,
	height: int,
	cell_size: float,
	steep_nz_threshold: float = 0.75
) -> Dictionary:
	var pixel_count := width * height
	if width <= 0 or height <= 0 or height_values.size() != pixel_count:
		return TerrainGPUUtil.gpu_blocked("invalid_height_data", width, height)

	return _make_normals_from_height_bytes_gpu(
		height_values.to_byte_array(),
		width,
		height,
		cell_size,
		INPUT_STRIDE_R32F,
		HEIGHT_CHANNEL_R,
		"r32f_storage_buffer",
		steep_nz_threshold
	)


static func _make_normals_from_height_bytes_gpu(
	height_bytes: PackedByteArray,
	width: int,
	height: int,
	cell_size: float,
	input_stride: int,
	height_channel: int,
	height_format: String,
	steep_nz_threshold: float = 0.75
) -> Dictionary:
	var pixel_count := width * height
	if width <= 0 or height <= 0 or input_stride <= 0 or height_channel < 0 or height_channel >= input_stride:
		return TerrainGPUUtil.gpu_blocked("invalid_height_data", width, height)
	if height_bytes.size() != pixel_count * input_stride * 4:
		return TerrainGPUUtil.gpu_blocked("invalid_height_data", width, height)

	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[HeightNormalFromHeightGPU] SKIP: no RenderingDevice available for GPU-only normal generation")
		return TerrainGPUUtil.gpu_blocked("missing_rendering_device", width, height)
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "HeightNormalFromHeightGPU"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("missing_rendering_device", width, height)

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(SHADER_PATH)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("shader_not_ready", width, height)

	var height_buf := compute.storage_buffer_from_bytes(height_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "height_normal_input_%s" % height_format)
	var normal_buf := compute.storage_buffer_zero(pixel_count * FLOATS_PER_NORMAL_PIXEL * 4, ComputeShaderBaseScript.SCOPE_FRAME, "height_normal_output_rgba32f")
	var stats_init := PackedByteArray()
	stats_init.resize(STATS_BUFFER_BYTES)
	stats_init.encode_u32(STATS_STEEP_COUNT_OFFSET, 0)
	stats_init.encode_u32(STATS_MIN_NZ_KEY_OFFSET, POSITIVE_INF_ORDERED_KEY)
	stats_init.encode_u32(STATS_MAX_NZ_KEY_OFFSET, NEGATIVE_INF_ORDERED_KEY)
	var stats_buf := compute.storage_buffer_from_bytes(stats_init, ComputeShaderBaseScript.SCOPE_FRAME, "height_normal_stats_u32")
	if not height_buf.is_valid() or not normal_buf.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("resource_create_failed", width, height)

	var set0 := compute.create_uniform_set([
		compute.make_storage_uniform(0, height_buf),
		compute.make_storage_uniform(1, normal_buf),
		compute.make_storage_uniform(2, stats_buf),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "height_normal_set0")
	if not set0.is_valid():
		compute.dispose()
		return TerrainGPUUtil.gpu_blocked("uniform_set_failed", width, height)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_float(8, maxf(cell_size, 0.000001))
	push.encode_float(12, steep_nz_threshold)
	push.encode_s32(16, input_stride)
	push.encode_s32(20, height_channel)

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

	var normal_bytes := rd.buffer_get_data(normal_buf, 0, pixel_count * FLOATS_PER_NORMAL_PIXEL * 4)
	var stats_bytes := rd.buffer_get_data(stats_buf, 0, STATS_BUFFER_BYTES)
	compute.dispose()
	if normal_bytes.size() != pixel_count * FLOATS_PER_NORMAL_PIXEL * 4 or stats_bytes.size() < STATS_BUFFER_BYTES:
		return TerrainGPUUtil.gpu_blocked("readback_failed", width, height)

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
		"normal_format": "rgba32f_storage_buffer",
		"dispatch_groups": groups,
		"normal_bytes": normal_bytes,
		"normal_values": normal_bytes.to_float32_array(),
		"steep_count": int(stats_bytes.decode_u32(STATS_STEEP_COUNT_OFFSET)),
		"min_nz": _ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MIN_NZ_KEY_OFFSET))),
		"max_nz": _ordered_uint_to_float(int(stats_bytes.decode_u32(STATS_MAX_NZ_KEY_OFFSET))),
		"stats_source": "height_normal_from_height_compute",
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

