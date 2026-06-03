extends SceneTree

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

const SHADER_PATH := "res://shaders/update_scene_voxel_tile_summary_ranges.glsl"
const LOCAL_SIZE_X := 64
const RECORD_STRIDE_WORDS := 32
const RECORD_STRIDE_BYTES := RECORD_STRIDE_WORDS * 4
const SUMMARY_STRIDE_WORDS := 8
const SUMMARY_STRIDE_BYTES := SUMMARY_STRIDE_WORDS * 4
const OCCUPIED_THRESHOLD := 0.01
const QUANT_SCALE := 1000000.0

const EMPTY_TILE_INDEX := 0
const INTERIOR_TILE_INDEX := 4
const EDGE_TILE_INDEX := 17


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[UpdateSceneVoxelTileSummaryRangesGPU] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	var ok := true
	ok = _test_summary_layout_worklist_and_edge_tile() and ok

	if ok:
		print("[UpdateSceneVoxelTileSummaryRangesGPU] ALL TESTS PASSED")
		quit(OK)
	else:
		push_error("[UpdateSceneVoxelTileSummaryRangesGPU] SOME TESTS FAILED")
		quit(FAILED)


func _test_summary_layout_worklist_and_edge_tile() -> bool:
	print("[UpdateSceneVoxelTileSummaryRangesGPU] test_summary_layout_worklist_and_edge_tile...")
	var grid_size := Vector3i(5, 3, 5)
	var tile_size := Vector3i(2, 2, 2)
	var tile_grid := Vector3i(3, 2, 3)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	var voxel_count := grid_size.x * grid_size.y * grid_size.z

	var scene_field := PackedFloat32Array()
	var collision_field := PackedFloat32Array()
	scene_field.resize(voxel_count)
	collision_field.resize(voxel_count)

	_set_field_value(scene_field, grid_size.x, 2, 0, 2, 0.25)
	_set_field_value(scene_field, grid_size.x, 3, 0, 2, 0.50)
	_set_field_value(scene_field, grid_size.x, 3, 1, 3, 0.75)
	_set_field_value(scene_field, grid_size.x, 2, 1, 2, OCCUPIED_THRESHOLD)
	_set_field_value(collision_field, grid_size.x, 2, 0, 3, 0.125)
	_set_field_value(collision_field, grid_size.x, 3, 1, 2, 0.625)

	_set_field_value(scene_field, grid_size.x, 4, 2, 4, 0.875)
	_set_field_value(collision_field, grid_size.x, 4, 2, 4, 0.375)

	_set_field_value(scene_field, grid_size.x, 4, 0, 0, 1.0)
	_set_field_value(collision_field, grid_size.x, 4, 1, 0, 1.0)

	var dirty_tile_indices := PackedInt32Array([EMPTY_TILE_INDEX, INTERIOR_TILE_INDEX, EDGE_TILE_INDEX])
	var result := _dispatch_summary_ranges(
		scene_field,
		collision_field,
		_make_summary_sentinel_bytes(tile_count),
		_pack_u32_words(dirty_tile_indices),
		_make_tile_record_bytes(grid_size, tile_size, tile_grid),
		grid_size,
		tile_size,
		tile_grid,
		tile_count,
		dirty_tile_indices.size()
	)
	if not bool(result.get("ok", false)):
		push_error("  FAIL: shader dispatch failed: %s" % str(result))
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: test must validate the GPU path without CPU fallback")
		return false

	var dispatch_groups: Vector3i = result.get("dispatch_groups", Vector3i.ZERO)
	if dispatch_groups != Vector3i(dirty_tile_indices.size(), 1, 1) or int(result.get("local_size_x", 0)) != LOCAL_SIZE_X:
		push_error("  FAIL: dispatch metadata mismatch: %s" % str(result))
		return false

	var summary_bytes: PackedByteArray = result.get("summary_bytes", PackedByteArray())
	if summary_bytes.size() != tile_count * SUMMARY_STRIDE_BYTES:
		push_error("  FAIL: summary byte count mismatch: got %d expected %d" % [summary_bytes.size(), tile_count * SUMMARY_STRIDE_BYTES])
		return false

	if not _expect_summary(summary_bytes, EMPTY_TILE_INDEX, 0.0, 0.0, 0.0, 0.0, 0, 0, 0, "empty dirty tile"):
		return false
	if not _expect_summary(summary_bytes, INTERIOR_TILE_INDEX, 0.25, 0.75, 0.125, 0.625, 3, 2, 1, "interior dirty tile"):
		return false
	if not _expect_summary(summary_bytes, EDGE_TILE_INDEX, 0.875, 0.875, 0.375, 0.375, 1, 1, 1, "edge dirty tile"):
		return false
	if not _expect_untouched_summaries(summary_bytes, tile_count, dirty_tile_indices):
		return false

	print("  OK: 32-byte summaries, dirty worklist filtering, threshold exclusion, and partial edge tile bounds")
	return true


func _dispatch_summary_ranges(
	scene_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	initial_summary_bytes: PackedByteArray,
	dirty_index_bytes: PackedByteArray,
	tile_record_bytes: PackedByteArray,
	grid_size: Vector3i,
	tile_size: Vector3i,
	tile_grid: Vector3i,
	tile_count: int,
	dirty_count: int
) -> Dictionary:
	var compute := ComputeShaderBaseScript.new()
	compute.log_name = "UpdateSceneVoxelTileSummaryRangesGPU"
	if not compute.ensure_device(true, false):
		return {
			"ok": false,
			"reason": "no_rendering_device",
			"cpu_fallback": false,
		}

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader: RID = compute.load_compute_shader(SHADER_PATH, ComputeShaderBaseScript.SCOPE_FRAME, "summary_ranges_shader")
	var pipeline: RID = compute.create_compute_pipeline(shader, ComputeShaderBaseScript.SCOPE_FRAME, "summary_ranges_pipeline")
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {
			"ok": false,
			"reason": "shader_or_pipeline_create_failed",
			"cpu_fallback": false,
		}

	var scene_buf: RID = compute.storage_buffer_from_floats(scene_field, ComputeShaderBaseScript.SCOPE_FRAME, "scene_field")
	var collision_buf: RID = compute.storage_buffer_from_floats(collision_field, ComputeShaderBaseScript.SCOPE_FRAME, "collision_field")
	var summary_buf: RID = compute.storage_buffer_from_bytes(initial_summary_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "tile_summaries")
	var dirty_buf: RID = compute.storage_buffer_from_bytes(dirty_index_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "dirty_tile_indices")
	var record_buf: RID = compute.storage_buffer_from_bytes(tile_record_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "tile_records")
	if not scene_buf.is_valid() or not collision_buf.is_valid() or not summary_buf.is_valid() or not dirty_buf.is_valid() or not record_buf.is_valid():
		compute.dispose()
		return {
			"ok": false,
			"reason": "buffer_create_failed",
			"cpu_fallback": false,
		}

	var uniform_set: RID = compute.create_uniform_set([
		compute.make_storage_uniform(0, scene_buf),
		compute.make_storage_uniform(1, collision_buf),
		compute.make_storage_uniform(2, summary_buf),
		compute.make_storage_uniform(3, dirty_buf),
		compute.make_storage_uniform(4, record_buf),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "summary_ranges_set0")
	if not uniform_set.is_valid():
		compute.dispose()
		return {
			"ok": false,
			"reason": "uniform_set_create_failed",
			"cpu_fallback": false,
		}

	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var push := _pack_push_constants(grid_size, voxel_count, dirty_count, tile_size, tile_grid, tile_count)
	var dispatch_groups := Vector3i(dirty_count, 1, 1)
	var cl := compute.begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, dispatch_groups.x, dispatch_groups.y, dispatch_groups.z)
	compute.end_compute_list()
	compute.submit_and_sync()

	var summary_bytes := rd.buffer_get_data(summary_buf, 0, tile_count * SUMMARY_STRIDE_BYTES)
	compute.dispose()
	return {
		"ok": true,
		"cpu_fallback": false,
		"summary_bytes": summary_bytes,
		"dispatch_groups": dispatch_groups,
		"local_size_x": LOCAL_SIZE_X,
	}


func _pack_push_constants(
	grid_size: Vector3i,
	voxel_count: int,
	dirty_count: int,
	tile_size: Vector3i,
	tile_grid: Vector3i,
	tile_count: int
) -> PackedByteArray:
	var push := PackedByteArray()
	push.resize(64)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, voxel_count)
	push.encode_s32(12, dirty_count)
	push.encode_s32(16, tile_size.x)
	push.encode_s32(20, tile_size.y)
	push.encode_s32(24, tile_size.z)
	push.encode_s32(28, SUMMARY_STRIDE_WORDS)
	push.encode_s32(32, tile_grid.x)
	push.encode_s32(36, tile_grid.y)
	push.encode_s32(40, tile_grid.z)
	push.encode_s32(44, tile_count)
	push.encode_float(48, OCCUPIED_THRESHOLD)
	push.encode_float(52, QUANT_SCALE)
	push.encode_float(56, float(RECORD_STRIDE_WORDS))
	push.encode_float(60, 0.0)
	return push


func _make_tile_record_bytes(grid_size: Vector3i, tile_size: Vector3i, tile_grid: Vector3i) -> PackedByteArray:
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	var bytes := PackedByteArray()
	bytes.resize(tile_count * RECORD_STRIDE_BYTES)

	for y in range(tile_grid.y):
		for z in range(tile_grid.z):
			for x in range(tile_grid.x):
				var tile_index := _tile_index_from_coord(Vector3i(x, y, z), tile_grid)
				var base := tile_index * RECORD_STRIDE_BYTES
				var voxel_min := Vector3i(x * tile_size.x, y * tile_size.y, z * tile_size.z)
				var voxel_max := Vector3i(
					mini(voxel_min.x + tile_size.x, grid_size.x),
					mini(voxel_min.y + tile_size.y, grid_size.y),
					mini(voxel_min.z + tile_size.z, grid_size.z)
				)
				bytes.encode_s32(base + 0, x)
				bytes.encode_s32(base + 4, y)
				bytes.encode_s32(base + 8, z)
				bytes.encode_s32(base + 16, tile_size.x)
				bytes.encode_s32(base + 20, tile_size.y)
				bytes.encode_s32(base + 24, tile_size.z)
				bytes.encode_s32(base + 32, voxel_min.x)
				bytes.encode_s32(base + 36, voxel_min.y)
				bytes.encode_s32(base + 40, voxel_min.z)
				bytes.encode_s32(base + 48, voxel_max.x)
				bytes.encode_s32(base + 52, voxel_max.y)
				bytes.encode_s32(base + 56, voxel_max.z)

	return bytes


func _make_summary_sentinel_bytes(tile_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(tile_count * SUMMARY_STRIDE_BYTES)
	for tile_index in range(tile_count):
		for word_index in range(SUMMARY_STRIDE_WORDS):
			bytes.encode_u32((tile_index * SUMMARY_STRIDE_WORDS + word_index) * 4, _summary_sentinel(tile_index, word_index))
	return bytes


func _pack_u32_words(words: PackedInt32Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(words.size() * 4)
	for i in range(words.size()):
		bytes.encode_u32(i * 4, words[i])
	return bytes


func _set_field_value(values: PackedFloat32Array, xz_res: int, x: int, y: int, z: int, value: float) -> void:
	values[x + xz_res * (z + xz_res * y)] = value


func _tile_index_from_coord(tile_coord: Vector3i, tile_grid: Vector3i) -> int:
	return tile_coord.x + tile_grid.x * (tile_coord.z + tile_grid.z * tile_coord.y)


func _expect_summary(
	bytes: PackedByteArray,
	tile_index: int,
	scene_min: float,
	scene_max: float,
	collision_min: float,
	collision_max: float,
	scene_count: int,
	collision_count: int,
	non_empty: int,
	label: String
) -> bool:
	var base := tile_index * SUMMARY_STRIDE_BYTES
	if not _expect_float_word(bytes, base + 0, scene_min, "%s scene_min" % label):
		return false
	if not _expect_float_word(bytes, base + 4, scene_max, "%s scene_max" % label):
		return false
	if not _expect_float_word(bytes, base + 8, collision_min, "%s collision_min" % label):
		return false
	if not _expect_float_word(bytes, base + 12, collision_max, "%s collision_max" % label):
		return false
	if not _expect_u32(bytes, base + 16, scene_count, "%s scene_count" % label):
		return false
	if not _expect_u32(bytes, base + 20, collision_count, "%s collision_count" % label):
		return false
	if not _expect_u32(bytes, base + 24, non_empty, "%s non_empty" % label):
		return false
	if not _expect_u32(bytes, base + 28, 0, "%s pad" % label):
		return false
	return true


func _expect_untouched_summaries(bytes: PackedByteArray, tile_count: int, dirty_tile_indices: PackedInt32Array) -> bool:
	var dirty_lookup := {}
	for tile_index in dirty_tile_indices:
		dirty_lookup[int(tile_index)] = true

	for tile_index in range(tile_count):
		if dirty_lookup.has(tile_index):
			continue
		for word_index in range(SUMMARY_STRIDE_WORDS):
			var byte_offset := (tile_index * SUMMARY_STRIDE_WORDS + word_index) * 4
			var expected := _summary_sentinel(tile_index, word_index)
			var actual := int(bytes.decode_u32(byte_offset))
			if actual != expected:
				push_error("  FAIL: untouched tile %d word %d expected sentinel 0x%08x, got 0x%08x" % [tile_index, word_index, expected, actual])
				return false
	return true


func _expect_float_word(bytes: PackedByteArray, byte_offset: int, expected: float, label: String) -> bool:
	var actual_value := bytes.decode_float(byte_offset)
	var actual_bits := int(bytes.decode_u32(byte_offset))
	var expected_bits := _float_bits(expected)
	if actual_bits != expected_bits or absf(actual_value - expected) > 0.000001:
		push_error("  FAIL: %s expected %s bits 0x%08x, got %s bits 0x%08x" % [label, str(expected), expected_bits, str(actual_value), actual_bits])
		return false
	return true


func _expect_u32(bytes: PackedByteArray, byte_offset: int, expected: int, label: String) -> bool:
	var actual := int(bytes.decode_u32(byte_offset))
	if actual != expected:
		push_error("  FAIL: %s expected %d, got %d" % [label, expected, actual])
		return false
	return true


func _float_bits(value: float) -> int:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	return int(bytes.decode_u32(0))


func _summary_sentinel(tile_index: int, word_index: int) -> int:
	return 0x5A5A0000 + tile_index * SUMMARY_STRIDE_WORDS + word_index
