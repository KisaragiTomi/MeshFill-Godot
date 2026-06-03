extends SceneTree

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

const SHADER_PATH := "res://shaders/invert_height_raw.glsl"
const DEFAULT_WIDTH := 256
const DEFAULT_HEIGHT := 256
const FLOATS_PER_PIXEL := 4
const VALID_SENTINEL := -10000.0
const NEGATIVE_INF_ORDERED_KEY := 0x007FFFFF
const POSITIVE_INF_ORDERED_KEY := 0xFF800000
const STATS_BUFFER_BYTES := 16
const STATS_PEAK_KEY_OFFSET := 0
const STATS_VALID_COUNT_OFFSET := 4
const STATS_MIN_KEY_OFFSET := 8
const STATS_MAX_KEY_OFFSET := 12
const LOCAL_SIZE := 256


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		var geo := ProjectSettings.globalize_path("res://geo")
		for name in ["cliff_01_height.raw", "cliff_02_height.raw"]:
			var path := geo.path_join(name)
			if FileAccess.file_exists(path):
				print("Converting %s..." % name)
				var result := invert_file_gpu(path, DEFAULT_WIDTH, DEFAULT_HEIGHT)
				if result.is_empty():
					quit(FAILED)
					return
				_print_result(result)
			else:
				print("SKIP (not found): %s" % path)
		quit(OK)
		return

	var path := str(args[0])
	var width := int(args[1]) if args.size() > 1 else DEFAULT_WIDTH
	var height := int(args[2]) if args.size() > 2 else DEFAULT_HEIGHT
	var result := invert_file_gpu(path, width, height)
	if result.is_empty():
		quit(FAILED)
		return
	_print_result(result)
	quit(OK)


static func invert_file_gpu(path: String, width: int = DEFAULT_WIDTH, height: int = DEFAULT_HEIGHT, valid_sentinel: float = VALID_SENTINEL) -> Dictionary:
	var resolved_path := _resolve_path(path)
	var file := FileAccess.open(resolved_path, FileAccess.READ)
	if file == null:
		push_error("HeightRawInverterGPU: failed to open %s" % resolved_path)
		return {}

	var bytes := file.get_buffer(file.get_length())
	file = null
	var pixel_count := width * height
	var expected_size := pixel_count * FLOATS_PER_PIXEL * 4
	if width <= 0 or height <= 0 or bytes.size() != expected_size:
		push_error("HeightRawInverterGPU: raw size mismatch for %s: got %d, expected %d" % [resolved_path, bytes.size(), expected_size])
		return {}

	var result := invert_bytes_gpu(bytes, pixel_count, valid_sentinel)
	if result.is_empty():
		return {}

	var out_file := FileAccess.open(resolved_path, FileAccess.WRITE)
	if out_file == null:
		push_error("HeightRawInverterGPU: failed to write %s" % resolved_path)
		return {}
	out_file.store_buffer(result["bytes"])
	out_file = null
	result["path"] = resolved_path
	return result


static func invert_bytes_gpu(bytes: PackedByteArray, pixel_count: int, valid_sentinel: float = VALID_SENTINEL) -> Dictionary:
	if pixel_count <= 0 or bytes.size() != pixel_count * FLOATS_PER_PIXEL * 4:
		return {}

	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[HeightRawInverterGPU] SKIP: no RenderingDevice available for GPU-only raw height inversion")
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "HeightRawInverterGPU"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(SHADER_PATH)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var data_buf := compute.storage_buffer_from_bytes(bytes, ComputeShaderBaseScript.SCOPE_FRAME, "height_raw_rgba32f")
	var stats_bytes := PackedByteArray()
	stats_bytes.resize(STATS_BUFFER_BYTES)
	stats_bytes.encode_u32(STATS_PEAK_KEY_OFFSET, NEGATIVE_INF_ORDERED_KEY)
	stats_bytes.encode_u32(STATS_VALID_COUNT_OFFSET, 0)
	stats_bytes.encode_u32(STATS_MIN_KEY_OFFSET, POSITIVE_INF_ORDERED_KEY)
	stats_bytes.encode_u32(STATS_MAX_KEY_OFFSET, NEGATIVE_INF_ORDERED_KEY)
	var stats_buf := compute.storage_buffer_from_bytes(stats_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "height_raw_stats_u32")
	if not data_buf.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return {}

	var set0 := compute.create_uniform_set([
		compute.make_storage_uniform(0, data_buf),
		compute.make_storage_uniform(1, stats_buf),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "height_raw_invert_set0")
	if not set0.is_valid():
		compute.dispose()
		return {}

	var peak_push := _make_push(pixel_count, 0, valid_sentinel)
	var invert_push := _make_push(pixel_count, 1, valid_sentinel)
	var groups := compute.dispatch_groups_1d(pixel_count, LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, peak_push, peak_push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, invert_push, invert_push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	compute.end_compute_list()
	compute.submit_and_sync()

	var stats_data := rd.buffer_get_data(stats_buf, 0, STATS_BUFFER_BYTES)
	var out_bytes := rd.buffer_get_data(data_buf, 0, bytes.size())
	compute.dispose()
	if stats_data.size() < STATS_BUFFER_BYTES or out_bytes.size() != bytes.size():
		return {}

	var valid_count := int(stats_data.decode_u32(STATS_VALID_COUNT_OFFSET))
	if valid_count <= 0:
		push_error("HeightRawInverterGPU: no valid height pixels found")
		return {}

	var peak := _ordered_uint_to_float(int(stats_data.decode_u32(STATS_PEAK_KEY_OFFSET)))
	var min_value := _ordered_uint_to_float(int(stats_data.decode_u32(STATS_MIN_KEY_OFFSET)))
	var max_value := _ordered_uint_to_float(int(stats_data.decode_u32(STATS_MAX_KEY_OFFSET)))
	return {
		"bytes": out_bytes,
		"peak": peak,
		"valid_count": valid_count,
		"min": min_value,
		"max": max_value,
		"stats_source": "invert_height_raw_compute",
	}


static func _make_push(pixel_count: int, mode: int, valid_sentinel: float) -> PackedByteArray:
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, pixel_count)
	push.encode_s32(4, mode)
	push.encode_float(8, valid_sentinel)
	push.encode_float(12, 0.0)
	return push


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


static func _print_result(result: Dictionary) -> void:
	print("  Before: peak = %.4f" % float(result.get("peak", 0.0)))
	print("  After:  range [%.4f, %.4f]" % [float(result.get("min", 0.0)), float(result.get("max", 0.0))])
	if result.has("path"):
		print("  Written: %s" % str(result["path"]))
