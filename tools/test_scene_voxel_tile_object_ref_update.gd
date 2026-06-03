extends SceneTree

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

const SHADER_PATH := "res://shaders/scene_voxel_tile_object_ref_update.glsl"
const LOCAL_SIZE_X := 64
const DIRTY_DELTA_STRIDE_WORDS := 20
const DIRTY_DELTA_STRIDE_BYTES := DIRTY_DELTA_STRIDE_WORDS * 4
const STATS_CAPACITY := 8

const STAT_OVERFLOW := 0
const STAT_NON_NUMERIC := 1
const STAT_DUPLICATE := 2
const STAT_TOUCHED := 3
const STAT_REMOVED_SLOTS := 4
const STAT_INSERTED_SLOTS := 5
const STAT_INVALID_BOUNDS := 6
const STAT_SKIPPED := 7


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[SceneVoxelTileObjectRefUpdateGPU] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	var ok := true
	ok = _test_object_ref_layout_and_delta_stats() and ok

	if ok:
		print("[SceneVoxelTileObjectRefUpdateGPU] ALL TESTS PASSED")
		quit(OK)
	else:
		push_error("[SceneVoxelTileObjectRefUpdateGPU] SOME TESTS FAILED")
		quit(FAILED)


func _test_object_ref_layout_and_delta_stats() -> bool:
	print("[SceneVoxelTileObjectRefUpdateGPU] test_object_ref_layout_and_delta_stats...")
	var grid_size := Vector3i(4, 4, 4)
	var tile_size := Vector3i(2, 2, 2)
	var tile_grid := Vector3i(2, 2, 2)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	var refs_per_tile := 2
	var object_ref_capacity := tile_count * refs_per_tile

	var initial_refs := PackedInt32Array()
	initial_refs.resize(object_ref_capacity)
	_set_ref(initial_refs, 0, 0, refs_per_tile, 3)   # object_id 2, old tile
	_set_ref(initial_refs, 4, 1, refs_per_tile, 5)   # object_id 4, removed object
	_set_ref(initial_refs, 6, 0, refs_per_tile, 7)   # object_id 6, alive_after false
	_set_ref(initial_refs, 5, 0, refs_per_tile, 20)  # fill tile 5 to force overflow
	_set_ref(initial_refs, 5, 1, refs_per_tile, 21)

	var dirty_delta_bytes := PackedByteArray()
	_append_dirty_delta(
		dirty_delta_bytes,
		2,
		Vector3i(0, 0, 0),
		Vector3i(2, 2, 2),
		Vector3i(2, 0, 0),
		Vector3i(4, 2, 4),
		false,
		true
	)
	_append_dirty_delta(
		dirty_delta_bytes,
		4,
		Vector3i(0, 2, 0),
		Vector3i(2, 4, 2),
		Vector3i(2, 2, 2),
		Vector3i(4, 4, 4),
		true,
		false
	)
	_append_dirty_delta(
		dirty_delta_bytes,
		6,
		Vector3i(0, 2, 2),
		Vector3i(2, 4, 4),
		Vector3i(2, 2, 2),
		Vector3i(4, 4, 4),
		false,
		false
	)
	_append_dirty_delta(
		dirty_delta_bytes,
		8,
		Vector3i(2, 2, 0),
		Vector3i(4, 4, 2),
		Vector3i(2, 2, 0),
		Vector3i(4, 4, 2),
		false,
		true
	)

	var result := _dispatch_object_ref_update(
		dirty_delta_bytes,
		4,
		initial_refs,
		grid_size,
		tile_size,
		tile_grid,
		refs_per_tile,
		object_ref_capacity
	)
	if not bool(result.get("ok", false)):
		push_error("  FAIL: shader dispatch failed: %s" % str(result))
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: test must validate the GPU path without CPU fallback")
		return false

	var expected_refs := PackedInt32Array([
		0, 0,
		3, 0,
		0, 0,
		3, 0,
		0, 0,
		20, 21,
		0, 0,
		0, 0,
	])
	var refs: PackedInt32Array = result.get("object_refs", PackedInt32Array())
	if not _expect_words(refs, expected_refs, "object_refs"):
		return false

	var stats: PackedInt32Array = result.get("stats", PackedInt32Array())
	if not _expect_stat(stats, STAT_OVERFLOW, 1, "overflow"):
		return false
	if not _expect_stat(stats, STAT_NON_NUMERIC, 0, "non_numeric"):
		return false
	if not _expect_stat(stats, STAT_DUPLICATE, 0, "duplicate"):
		return false
	if not _expect_stat(stats, STAT_TOUCHED, 5, "touched"):
		return false
	if not _expect_stat(stats, STAT_REMOVED_SLOTS, 3, "removed_slots"):
		return false
	if not _expect_stat(stats, STAT_INSERTED_SLOTS, 2, "inserted_slots"):
		return false
	if not _expect_stat(stats, STAT_INVALID_BOUNDS, 0, "invalid_bounds"):
		return false
	if not _expect_stat(stats, STAT_SKIPPED, 0, "skipped"):
		return false

	var groups: Vector3i = result.get("dispatch_groups", Vector3i.ZERO)
	if groups != Vector3i(1, 1, 1) or int(result.get("local_size_x", 0)) != LOCAL_SIZE_X:
		push_error("  FAIL: dispatch metadata mismatch: %s" % str(result))
		return false

	print("  OK: object refs use tile-major slots, object_id+1 refs, removals, alive skips, and overflow stats")
	return true


func _dispatch_object_ref_update(
	dirty_delta_bytes: PackedByteArray,
	dirty_delta_count: int,
	initial_refs: PackedInt32Array,
	grid_size: Vector3i,
	tile_size: Vector3i,
	tile_grid: Vector3i,
	refs_per_tile: int,
	object_ref_capacity: int
) -> Dictionary:
	var compute := ComputeShaderBaseScript.new()
	compute.log_name = "SceneVoxelTileObjectRefUpdateGPU"
	if not compute.ensure_device(true, false):
		return {
			"ok": false,
			"reason": "no_rendering_device",
			"cpu_fallback": false,
		}

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader: RID = compute.load_compute_shader(SHADER_PATH, ComputeShaderBaseScript.SCOPE_FRAME, "object_ref_update_shader")
	var pipeline: RID = compute.create_compute_pipeline(shader, ComputeShaderBaseScript.SCOPE_FRAME, "object_ref_update_pipeline")
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {
			"ok": false,
			"reason": "shader_or_pipeline_create_failed",
			"cpu_fallback": false,
		}

	var dirty_delta_buf: RID = compute.storage_buffer_from_bytes(
		dirty_delta_bytes,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"dirty_delta_words"
	)
	var object_ref_buf: RID = compute.storage_buffer_from_bytes(
		_pack_u32_words(initial_refs),
		ComputeShaderBaseScript.SCOPE_FRAME,
		"object_refs"
	)
	var stats_buf: RID = compute.storage_buffer_from_bytes(
		_zero_bytes(STATS_CAPACITY * 4),
		ComputeShaderBaseScript.SCOPE_FRAME,
		"stats"
	)
	if not dirty_delta_buf.is_valid() or not object_ref_buf.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return {
			"ok": false,
			"reason": "buffer_create_failed",
			"cpu_fallback": false,
		}

	var uniform_set: RID = compute.create_uniform_set([
		compute.make_storage_uniform(0, dirty_delta_buf),
		compute.make_storage_uniform(1, object_ref_buf),
		compute.make_storage_uniform(2, stats_buf),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "object_ref_update_set0")
	if not uniform_set.is_valid():
		compute.dispose()
		return {
			"ok": false,
			"reason": "uniform_set_create_failed",
			"cpu_fallback": false,
		}

	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	var push := _pack_push_constants(
		grid_size,
		dirty_delta_count,
		tile_size,
		refs_per_tile,
		tile_grid,
		tile_count,
		dirty_delta_count,
		object_ref_capacity,
		32,
		STATS_CAPACITY,
		0
	)
	var dispatch_groups := Vector3i(1, 1, 1)
	var cl := compute.begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, dispatch_groups.x, dispatch_groups.y, dispatch_groups.z)
	compute.end_compute_list()
	compute.submit_and_sync()

	var object_ref_bytes := rd.buffer_get_data(object_ref_buf, 0, object_ref_capacity * 4)
	var stats_bytes := rd.buffer_get_data(stats_buf, 0, STATS_CAPACITY * 4)
	compute.dispose()
	return {
		"ok": true,
		"cpu_fallback": false,
		"object_refs": object_ref_bytes.to_int32_array(),
		"stats": stats_bytes.to_int32_array(),
		"dispatch_groups": dispatch_groups,
		"local_size_x": LOCAL_SIZE_X,
	}


func _append_dirty_delta(
	bytes: PackedByteArray,
	object_id: int,
	old_min: Vector3i,
	old_max: Vector3i,
	new_min: Vector3i,
	new_max: Vector3i,
	removed: bool,
	alive_after: bool
) -> void:
	var base := bytes.size()
	bytes.resize(base + DIRTY_DELTA_STRIDE_BYTES)
	bytes.encode_s32(base + 0, object_id)
	bytes.encode_s32(base + 4, 0)
	bytes.encode_s32(base + 8, 0)
	bytes.encode_s32(base + 12, 0)
	bytes.encode_s32(base + 16, old_min.x)
	bytes.encode_s32(base + 20, old_min.y)
	bytes.encode_s32(base + 24, old_min.z)
	bytes.encode_s32(base + 28, 1 if removed else 0)
	bytes.encode_s32(base + 32, old_max.x)
	bytes.encode_s32(base + 36, old_max.y)
	bytes.encode_s32(base + 40, old_max.z)
	bytes.encode_s32(base + 44, 1 if alive_after else 0)
	bytes.encode_s32(base + 48, new_min.x)
	bytes.encode_s32(base + 52, new_min.y)
	bytes.encode_s32(base + 56, new_min.z)
	bytes.encode_s32(base + 60, 0)
	bytes.encode_s32(base + 64, new_max.x)
	bytes.encode_s32(base + 68, new_max.y)
	bytes.encode_s32(base + 72, new_max.z)
	bytes.encode_s32(base + 76, 0)


func _pack_push_constants(
	grid_size: Vector3i,
	dirty_delta_count: int,
	tile_size: Vector3i,
	refs_per_tile: int,
	tile_grid: Vector3i,
	tile_count: int,
	dirty_delta_capacity: int,
	object_ref_capacity: int,
	max_object_id_count: int,
	stats_capacity: int,
	options_x: int
) -> PackedByteArray:
	var push := PackedByteArray()
	push.resize(80)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, grid_size.z)
	push.encode_s32(12, dirty_delta_count)
	push.encode_s32(16, tile_size.x)
	push.encode_s32(20, tile_size.y)
	push.encode_s32(24, tile_size.z)
	push.encode_s32(28, refs_per_tile)
	push.encode_s32(32, tile_grid.x)
	push.encode_s32(36, tile_grid.y)
	push.encode_s32(40, tile_grid.z)
	push.encode_s32(44, tile_count)
	push.encode_s32(48, dirty_delta_capacity)
	push.encode_s32(52, object_ref_capacity)
	push.encode_s32(56, max_object_id_count)
	push.encode_s32(60, stats_capacity)
	push.encode_s32(64, options_x)
	push.encode_s32(68, 0)
	push.encode_s32(72, 0)
	push.encode_s32(76, 0)
	return push


func _pack_u32_words(words: PackedInt32Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(words.size() * 4)
	for i in range(words.size()):
		bytes.encode_u32(i * 4, words[i])
	return bytes


func _zero_bytes(byte_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(byte_count)
	return bytes


func _set_ref(refs: PackedInt32Array, tile_index: int, slot: int, refs_per_tile: int, value: int) -> void:
	refs[tile_index * refs_per_tile + slot] = value


func _expect_words(actual: PackedInt32Array, expected: PackedInt32Array, label: String) -> bool:
	if actual.size() != expected.size():
		push_error("  FAIL: %s size mismatch: got %d expected %d" % [label, actual.size(), expected.size()])
		return false
	for i in range(expected.size()):
		if actual[i] != expected[i]:
			push_error("  FAIL: %s[%d] expected %d, got %d" % [label, i, expected[i], actual[i]])
			return false
	return true


func _expect_stat(stats: PackedInt32Array, stat_index: int, expected: int, label: String) -> bool:
	if stat_index >= stats.size():
		push_error("  FAIL: missing stat %s at index %d" % [label, stat_index])
		return false
	if stats[stat_index] != expected:
		push_error("  FAIL: stat %s expected %d, got %d (stats=%s)" % [label, expected, stats[stat_index], str(stats)])
		return false
	return true
