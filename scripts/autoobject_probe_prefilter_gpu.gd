class_name AutoObjectProbePrefilterGPU
extends "res://scripts/godot_compute_shader_base.gd"

## GPU-accelerated AutoObject probe prefilter.
## This is the only supported prefilter path. The CPU fallback was removed
## because anchor_count * asset_count * probe_count is too expensive for
## GDScript and can stall large scenes.
##
## Uses 4 compute-shader dispatches:
##   1. collect_sv_anchors        — find position-only anchor voxels
##   2. score_anchor_asset_probes — score each anchor×asset probe set (Pass A)
##   3. select_anchor_topk        — per-anchor top-K asset selection   (Pass B)
##   4. reduce_anchor_topk_to_voxel_regions — aggregate to per-asset voxel-region votes

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")

const TILE_SIZE := 8
const MAX_ASSETS := 256
const TOPK := 4
const ANCHOR_CAPACITY := 65536

var anchor_topk: int = 4
var max_scene_field: float = 0.15
var max_collision_field: float = 0.05
var min_support: float = 0.25
var min_target_interest: float = 0.01
var min_prefilter_score: float = 0.35

# Shaders & pipelines
var _shader_collect: RID
var _shader_score: RID
var _shader_topk: RID
var _shader_reduce: RID
var _pipeline_collect: RID
var _pipeline_score: RID
var _pipeline_topk: RID
var _pipeline_reduce: RID


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func run_probe_prefilter(
	scene_voxel_runtime: SceneVoxelLocal,
	target_occupancy: PackedFloat32Array,
	target_color: PackedColorArray,
	autoobjects: Array,
	dirty_tile_ids: Array[int] = []
) -> Dictionary:
	if scene_voxel_runtime == null:
		return _empty_result()
	var voxel_sparse_ids := dirty_tile_ids.duplicate()
	if voxel_sparse_ids.is_empty():
		voxel_sparse_ids = scene_voxel_runtime.get_dirty_voxel_sparse_ids() if scene_voxel_runtime.has_method("get_dirty_voxel_sparse_ids") else scene_voxel_runtime.get_dirty_tile_ids()
	if voxel_sparse_ids.is_empty():
		voxel_sparse_ids = _all_tile_ids(scene_voxel_runtime)
	if voxel_sparse_ids.is_empty():
		return _empty_result()

	log_name = "AutoObjectProbePrefilterGPU"
	sync_global_device = true
	if not ensure_device(true, true):
		return _empty_result()

	_load_shaders()
	if not _shader_collect.is_valid() or not _shader_score.is_valid() \
	   or not _shader_topk.is_valid() or not _shader_reduce.is_valid():
		_free_gpu()
		return _empty_result()

	var result := _run_gpu_pipeline(scene_voxel_runtime, target_occupancy, target_color, autoobjects, voxel_sparse_ids)
	_free_gpu()
	return result


# ---------------------------------------------------------------------------
# GPU pipeline
# ---------------------------------------------------------------------------

func _run_gpu_pipeline(
	scene_voxel_runtime: SceneVoxelLocal,
	target_occupancy: PackedFloat32Array,
	target_color: PackedColorArray,
	autoobjects: Array,
	tile_ids: Array[int]
) -> Dictionary:
	var grid_size := scene_voxel_runtime.grid_size
	var voxel_size := scene_voxel_runtime.voxel_size
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var tile_grid := Vector3i(
		ceili(float(grid_size.x) / float(TILE_SIZE)),
		ceili(float(grid_size.y) / float(TILE_SIZE)),
		ceili(float(grid_size.z) / float(TILE_SIZE))
	)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z

	# ---- Pack CPU data into byte arrays ----

	var scene_data := _ensure_float_array(scene_voxel_runtime.scene_field, voxel_count)
	var collision_data := _ensure_float_array(scene_voxel_runtime.collision_field, voxel_count)
	var target_occ_data := _ensure_float_array(target_occupancy, voxel_count)
	var target_color_data := _pack_color_array_rgba8(target_color, voxel_count)

	var asset_count := mini(autoobjects.size(), MAX_ASSETS)
	var probe_pack := _pack_all_probes(autoobjects, asset_count, voxel_size)

	# ---- Create GPU buffers ----

	var scene_buf := storage_buffer_from_floats(scene_data)
	var collision_buf := storage_buffer_from_floats(collision_data)
	var target_occ_buf := storage_buffer_from_floats(target_occ_data)
	var target_color_buf := storage_buffer_from_bytes(target_color_data)
	var dirty_tile_buf := storage_buffer_from_bytes(_pack_u32_array_from_int(tile_ids))
	var anchor_buf := storage_buffer_zero(ANCHOR_CAPACITY * 16)  # uvec4(x, y, z, reserved) per anchor
	var anchor_count_buf := storage_buffer_zero(4)

	var probe_data_buf := storage_buffer_from_bytes(probe_pack.probe_bytes)
	var probe_range_buf := storage_buffer_from_bytes(probe_pack.range_bytes)

	var score_buf_size := ANCHOR_CAPACITY * MAX_ASSETS * 4
	var asset_scores_buf := storage_buffer_zero(score_buf_size)
	var topk_buf := storage_buffer_zero(ANCHOR_CAPACITY * TOPK * 8)  # uvec2 per entry
	var voxel_sparse_votes_buf := storage_buffer_zero(asset_count * tile_count * 4)

	# ---- Dispatch 1: Collect anchors ----

	_dispatch_collect(
		scene_buf, collision_buf, target_occ_buf, dirty_tile_buf,
		anchor_buf, anchor_count_buf,
		grid_size, tile_grid, tile_ids.size()
	)
	submit_and_sync(true)

	# Read anchor count
	var anchor_count_bytes := _rd.buffer_get_data(anchor_count_buf, 0, 4)
	var actual_anchor_count := mini(int(anchor_count_bytes.decode_u32(0)), ANCHOR_CAPACITY)
	if actual_anchor_count == 0:
		_free_gpu()
		return _empty_result()

	# ---- Dispatch 2: Score probes (Pass A) ----

	var anchor_grid_x := ceili(sqrt(float(actual_anchor_count)))
	var anchor_grid_y := ceili(float(actual_anchor_count) / float(anchor_grid_x))
	var asset_blocks := ceili(float(asset_count) / 16.0)

	_dispatch_score(
		anchor_buf, probe_range_buf, probe_data_buf,
		scene_buf, collision_buf, target_occ_buf, target_color_buf,
		asset_scores_buf,
		grid_size, voxel_size, asset_count, actual_anchor_count,
		anchor_grid_x, anchor_grid_y, asset_blocks
	)
	submit_and_sync(true)

	# ---- Dispatch 3: Top-K selection (Pass B) ----

	_dispatch_topk(
		asset_scores_buf, topk_buf,
		actual_anchor_count, asset_count, anchor_grid_x, anchor_grid_y
	)
	submit_and_sync(true)

	# ---- Dispatch 4: Voxel-region reduction ----

	_dispatch_reduce(
		anchor_buf, topk_buf, voxel_sparse_votes_buf,
		tile_grid, tile_count, actual_anchor_count, asset_count
	)
	submit_and_sync(true)

	# ---- Read back results ----

	var anchors_bytes := _rd.buffer_get_data(anchor_buf, 0, actual_anchor_count * 16)
	var votes_bytes := _rd.buffer_get_data(voxel_sparse_votes_buf, 0, asset_count * tile_count * 4)

	_free_gpu()

	return _decode_results(anchors_bytes, votes_bytes, actual_anchor_count, asset_count, tile_count, scene_voxel_runtime)


# ---------------------------------------------------------------------------
# Dispatch helpers
# ---------------------------------------------------------------------------

func _dispatch_collect(
	scene_buf: RID, collision_buf: RID, target_occ_buf: RID,
	dirty_tile_buf: RID, anchor_buf: RID, anchor_count_buf: RID,
	grid_size: Vector3i, tile_grid: Vector3i, dirty_count: int
) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, scene_buf),
		make_storage_uniform(1, collision_buf),
		make_storage_uniform(2, target_occ_buf),
		make_storage_uniform(3, dirty_tile_buf),
		make_storage_uniform(4, anchor_buf),
		make_storage_uniform(5, anchor_count_buf),
	], _shader_collect, 0)

	var push := PackedByteArray()
	push.resize(48)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, grid_size.z)
	push.encode_s32(12, dirty_count)
	push.encode_s32(16, tile_grid.x)
	push.encode_s32(20, tile_grid.y)
	push.encode_s32(24, tile_grid.z)
	push.encode_s32(28, ANCHOR_CAPACITY)
	push.encode_float(32, max_scene_field)
	push.encode_float(36, max_collision_field)
	push.encode_float(40, min_support)
	push.encode_float(44, min_target_interest)

	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_collect)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, dirty_count, 1, 1)
	end_compute_list()


func _dispatch_score(
	anchor_buf: RID, probe_range_buf: RID,
	probe_data_buf: RID, scene_buf: RID, collision_buf: RID,
	target_occ_buf: RID, target_color_buf: RID, asset_scores_buf: RID,
	grid_size: Vector3i, voxel_size: Vector3, asset_count: int,
	anchor_count: int, anchor_grid_x: int, anchor_grid_y: int,
	asset_blocks: int
) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, anchor_buf),
		make_storage_uniform(1, probe_range_buf),
		make_storage_uniform(2, probe_data_buf),
		make_storage_uniform(3, scene_buf),
		make_storage_uniform(4, collision_buf),
		make_storage_uniform(5, target_occ_buf),
		make_storage_uniform(6, target_color_buf),
		make_storage_uniform(7, asset_scores_buf),
	], _shader_score, 0)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, grid_size.z)
	push.encode_s32(12, asset_count)
	push.encode_float(16, 1.0 / maxf(voxel_size.x, 0.0001))
	push.encode_float(20, 1.0 / maxf(voxel_size.y, 0.0001))
	push.encode_float(24, 1.0 / maxf(voxel_size.z, 0.0001))
	push.encode_float(28, 0.0)  # pad
	# Second 16 bytes
	push.resize(48)
	push.encode_u32(32, anchor_count)
	push.encode_u32(36, anchor_grid_x)
	push.encode_float(40, min_prefilter_score)
	push.encode_float(44, 0.0)  # pad

	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_score)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, anchor_grid_x, anchor_grid_y, asset_blocks)
	end_compute_list()


func _dispatch_topk(
	asset_scores_buf: RID, topk_buf: RID,
	anchor_count: int, asset_count: int,
	anchor_grid_x: int, anchor_grid_y: int
) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, asset_scores_buf),
		make_storage_uniform(1, topk_buf),
	], _shader_topk, 0)

	var push := PackedByteArray()
	push.resize(16)
	push.encode_u32(0, anchor_count)
	push.encode_u32(4, asset_count)
	push.encode_u32(8, anchor_grid_x)
	push.encode_float(12, min_prefilter_score)

	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_topk)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, anchor_grid_x, anchor_grid_y, 1)
	end_compute_list()


func _dispatch_reduce(
	anchor_buf: RID, topk_buf: RID, voxel_sparse_votes_buf: RID,
	tile_grid: Vector3i, tile_count: int,
	anchor_count: int, asset_count: int
) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, anchor_buf),
		make_storage_uniform(1, topk_buf),
		make_storage_uniform(2, voxel_sparse_votes_buf),
	], _shader_reduce, 0)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, tile_grid.x)
	push.encode_s32(4, tile_grid.y)
	push.encode_s32(8, tile_grid.z)
	push.encode_s32(12, tile_count)
	push.encode_u32(16, anchor_count)
	push.encode_u32(20, asset_count)
	push.encode_u32(24, TOPK)
	push.encode_u32(28, 0)

	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_reduce)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	end_compute_list()


# ---------------------------------------------------------------------------
# Probe packing
# ---------------------------------------------------------------------------

func _pack_all_probes(autoobjects: Array, asset_count: int, voxel_size: Vector3) -> Dictionary:
	# Build flat probe buffer and per-asset probe ranges.
	# probe_range[asset_id] = (start_index, probe_count).
	# Anchor meaning is represented by the anchor voxel position, not by an
	# explicit anchor_kind in the GPU record.

	var all_probes: Array[Dictionary] = []
	var range_entries: Array = []  # array of uvec2 as [start, count]

	# Pre-allocate range_entries: one slot per asset.
	range_entries.resize(asset_count)
	for i in range(range_entries.size()):
		range_entries[i] = Vector2i(0, 0)

	for obj_idx in range(asset_count):
		var autoobject := autoobjects[obj_idx] as AutoObject
		if autoobject == null:
			continue

		var probes: Array = autoobject.get_semantic_probes(autoobject.semantic_probe_density)
		var start := all_probes.size()
		for probe in probes:
			if probe is Dictionary:
				all_probes.append(probe)
		range_entries[obj_idx] = Vector2i(start, all_probes.size() - start)

	# Pack probe data: 2 vec4 per probe = 32 bytes
	var probe_bytes := PackedByteArray()
	probe_bytes.resize(maxi(all_probes.size(), 1) * 32)
	for i in range(all_probes.size()):
		var p: Dictionary = all_probes[i]
		var offset := _vec3_from(p.get("offset", Vector3.ZERO))
		var weight := maxf(float(p.get("weight", 1.0)), 0.0)
		var rgba8 := int(p.get("expected_rgba8", 0))
		var e_coll := clampf(float(p.get("expected_collision", 0.0)), 0.0, 1.0)
		var flags := int(p.get("flags", SemanticProbeProfileScript.FLAG_COLOR | SemanticProbeProfileScript.FLAG_COMPLEXITY))
		var kind := _kind_to_uint(str(p.get("kind", "positive")))

		var base := i * 32
		probe_bytes.encode_float(base + 0, offset.x)
		probe_bytes.encode_float(base + 4, offset.y)
		probe_bytes.encode_float(base + 8, offset.z)
		probe_bytes.encode_float(base + 12, weight)
		# Second vec4: pack as float-bits
		probe_bytes.encode_u32(base + 16, rgba8)       # floatBitsToUint on GPU side
		probe_bytes.encode_float(base + 20, e_coll)
		probe_bytes.encode_u32(base + 24, flags)
		probe_bytes.encode_u32(base + 28, kind)

	# Pack range: uvec2 per entry = 8 bytes
	var range_bytes := PackedByteArray()
	range_bytes.resize(maxi(range_entries.size(), 1) * 8)
	for i in range(range_entries.size()):
		var entry: Vector2i = range_entries[i]
		range_bytes.encode_u32(i * 8 + 0, entry.x)
		range_bytes.encode_u32(i * 8 + 4, entry.y)

	return {
		"probe_bytes": probe_bytes,
		"range_bytes": range_bytes,
		"total_probes": all_probes.size(),
	}


# ---------------------------------------------------------------------------
# Result decoding
# ---------------------------------------------------------------------------

func _decode_results(
	anchors_bytes: PackedByteArray,
	votes_bytes: PackedByteArray,
	anchor_count: int,
	asset_count: int,
	tile_count: int,
	scene_voxel_runtime: SceneVoxelLocal
) -> Dictionary:
	# Decode anchors
	var anchors: Array[Dictionary] = []
	for i in range(anchor_count):
		var base := i * 16
		var x := int(anchors_bytes.decode_u32(base + 0))
		var y := int(anchors_bytes.decode_u32(base + 4))
		var z := int(anchors_bytes.decode_u32(base + 8))
		anchors.append({
			"id": i,
			"voxel_pos": Vector3i(x, y, z),
		})

	# Decode voxel-region votes → per-asset sorted voxel-region lists
	var autoobject_candidate_voxel_sparses: Dictionary = {}

	for asset_id in range(asset_count):
		var entries: Array[Dictionary] = []
		for tid in range(tile_count):
			var vote := votes_bytes.decode_float((asset_id * tile_count + tid) * 4)
			if vote > 0.0001:
				entries.append({"tile_id": tid, "score": vote})
		if entries.is_empty():
			continue
		entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.get("score", 0.0)) > float(b.get("score", 0.0)))
		var voxel_sparses: Array[Vector3i] = []
		for entry in entries:
			voxel_sparses.append(scene_voxel_runtime.tile_id_to_pos(int(entry.get("tile_id", 0))))
		autoobject_candidate_voxel_sparses[asset_id] = voxel_sparses

	return {
		"anchors": anchors,
		"anchor_autoobject_topk": {},  # Not read back (GPU internal)
		"autoobject_candidate_voxel_sparses": autoobject_candidate_voxel_sparses,
		"anchor_count": anchors.size(),
	}


func _load_shaders() -> void:
	_shader_collect = load_compute_shader("res://shaders/collect_sv_anchors.glsl")
	_shader_score = load_compute_shader("res://shaders/score_anchor_asset_probes.glsl")
	_shader_topk = load_compute_shader("res://shaders/select_anchor_topk.glsl")
	_shader_reduce = load_compute_shader("res://shaders/reduce_anchor_topk_to_voxel_regions.glsl")
	if _shader_collect.is_valid():
		_pipeline_collect = create_compute_pipeline(_shader_collect)
	if _shader_score.is_valid():
		_pipeline_score = create_compute_pipeline(_shader_score)
	if _shader_topk.is_valid():
		_pipeline_topk = create_compute_pipeline(_shader_topk)
	if _shader_reduce.is_valid():
		_pipeline_reduce = create_compute_pipeline(_shader_reduce)


func _free_gpu() -> void:
	dispose()
	_pipeline_collect = RID()
	_pipeline_score = RID()
	_pipeline_topk = RID()
	_pipeline_reduce = RID()
	_shader_collect = RID()
	_shader_score = RID()
	_shader_topk = RID()
	_shader_reduce = RID()


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

func _empty_result() -> Dictionary:
	return {
		"anchors": [],
		"anchor_autoobject_topk": {},
		"autoobject_candidate_voxel_sparses": {},
		"anchor_count": 0,
	}


func _all_tile_ids(scene_voxel_runtime: SceneVoxelLocal) -> Array[int]:
	var total := int(scene_voxel_runtime.get_stats().get("total_tiles", 0))
	var result: Array[int] = []
	for i in range(total):
		result.append(i)
	return result


func _ensure_float_array(arr: PackedFloat32Array, expected: int) -> PackedFloat32Array:
	if arr.size() >= expected:
		return arr
	var result := PackedFloat32Array()
	result.resize(expected)
	var n := mini(arr.size(), expected)
	for i in range(n):
		result[i] = arr[i]
	return result


func _pack_u32_array_from_int(values: Array[int]) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(values.size(), 1) * 4)
	for i in range(values.size()):
		bytes.encode_u32(i * 4, values[i])
	return bytes


func _pack_color_array_rgba8(colors: PackedColorArray, voxel_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(voxel_count, 1) * 4)
	var n := mini(colors.size(), voxel_count)
	for i in range(n):
		var c: Color = colors[i]
		bytes.encode_u32(i * 4, _pack_rgba8(c))
	return bytes


static func _pack_rgba8(c: Color) -> int:
	var r := clampi(int(roundf(c.r * 255.0)), 0, 255)
	var g := clampi(int(roundf(c.g * 255.0)), 0, 255)
	var b := clampi(int(roundf(c.b * 255.0)), 0, 255)
	var a := clampi(int(roundf(c.a * 255.0)), 0, 255)
	return (r << 24) | (g << 16) | (b << 8) | a


func _vec3_from(value) -> Vector3:
	if value is Vector3:
		return value as Vector3
	return Vector3.ZERO


func _kind_to_uint(kind: String) -> int:
	match kind:
		"negative": return 1
		"support":  return 2
		_:          return 0  # positive
