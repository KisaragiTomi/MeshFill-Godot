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
const RuntimeProfileContainerScript := preload("res://scripts/auto_voxel_runtime_profile_container.gd")
const VoxelPlacementGeneratorScript := preload("res://scripts/voxel_placement_generator.gd")

const TILE_SIZE := 8
const MAX_ASSETS := 256
const TOPK := 4
const ANCHOR_CAPACITY := 65536
const EMPTY_ASSET_ID := 0xffffffff
const CANDIDATE_ROUTE_SCHEMA_VERSION := 1
const CANDIDATE_ROUTE_RECORD_STRIDE_BYTES := 16
const CANDIDATE_ROUTE_RANGE_STRIDE_BYTES := 16
const CANDIDATE_ROUTE_CPU_PACK_SOURCE_LABEL := "gpu_vote_buffer_readback_cpu_pack"

var anchor_topk: int = 4                    # per-anchor asset top-K target
var max_scene_field: float = 0.15           # anchor allowed scene occupancy threshold
var max_collision_field: float = 0.05       # anchor allowed collision threshold
var min_support: float = 0.25               # required support below anchor
var min_target_interest: float = 0.01       # minimum TargetSV_B demand
var min_prefilter_score: float = 0.35       # minimum probe score accepted by shader
var interpolation_guard_voxels: int = 1     # route expansion guard, at least 1 voxel

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
	sv: Dictionary,
	autoobjects: Array,
	dirty_tile_ids: Array[int] = [],
	runtime_profile_container: Object = null,
	target_color_rgba8_bytes: PackedByteArray = PackedByteArray(),
	target_occupancy_bytes: PackedByteArray = PackedByteArray()
) -> Dictionary:
	if sv.is_empty():
		return _empty_result("empty_sv")
	var voxel_sparse_ids := dirty_tile_ids.duplicate()
	if voxel_sparse_ids.is_empty():
		voxel_sparse_ids = _dirty_tile_ids_from_sv(sv)
	if voxel_sparse_ids.is_empty():
		voxel_sparse_ids = _all_tile_ids(sv)
	if voxel_sparse_ids.is_empty():
		return _empty_result("no_voxel_regions")

	log_name = "AutoObjectProbePrefilterGPU"
	sync_global_device = true
	if runtime_profile_container != null:
		if not _attach_runtime_profile_container_device(runtime_profile_container):
			return _empty_result("auto_voxel_runtime_profile_container_not_ready")
	elif not ensure_device(true, true):
		return _empty_result("missing_rendering_device")

	_load_shaders()
	if not _pipeline_rids_ready():
		var pipeline_status := _pipeline_readiness()
		var blocked_result := _empty_result("prefilter_shader_pipeline_not_ready", {}, pipeline_status)
		_free_gpu()
		return blocked_result

	var result := _run_gpu_pipeline(sv, autoobjects, voxel_sparse_ids, runtime_profile_container, target_color_rgba8_bytes, target_occupancy_bytes)
	_free_gpu()
	return result


# ---------------------------------------------------------------------------
# GPU pipeline
# ---------------------------------------------------------------------------

func _run_gpu_pipeline(
	sv: Dictionary,
	autoobjects: Array,
	tile_ids: Array[int],
	runtime_profile_container: Object = null,
	target_color_rgba8_bytes: PackedByteArray = PackedByteArray(),
	target_occupancy_bytes: PackedByteArray = PackedByteArray()
) -> Dictionary:
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var voxel_size: Vector3 = sv.get("voxel_size", Vector3.ONE)
	var voxel_count: int = grid_size.x * grid_size.y * grid_size.z
	var tile_grid := Vector3i(
		ceili(float(grid_size.x) / float(TILE_SIZE)),
		ceili(float(grid_size.y) / float(TILE_SIZE)),
		ceili(float(grid_size.z) / float(TILE_SIZE))
	)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z

	# ---- Normalize GPU buffer inputs ----

	var scene_data := _ensure_float_array(sv.get("scene_field", PackedFloat32Array()), voxel_count)
	var collision_data := _ensure_float_array(sv.get("collision_field", PackedFloat32Array()), voxel_count)
	var target_occ_data := _target_occupancy_bytes(target_occupancy_bytes, voxel_count)
	var target_color_data := _target_color_rgba8_bytes(target_color_rgba8_bytes, voxel_count)

	var asset_count := mini(autoobjects.size(), MAX_ASSETS)
	var probe_pack := _pack_all_probes(autoobjects, asset_count, voxel_size, runtime_profile_container)
	if not bool(probe_pack.get("ready", true)):
		return _empty_result(str(probe_pack.get("reason", "profile_probe_pack_not_ready")), probe_pack)

	# ---- Create GPU buffers ----

	var scene_buf := storage_buffer_from_floats(scene_data)
	var collision_buf := storage_buffer_from_floats(collision_data)
	var target_occ_buf := storage_buffer_from_bytes(target_occ_data)
	var target_color_buf := storage_buffer_from_bytes(target_color_data)
	var dirty_tile_buf := storage_buffer_from_bytes(_pack_u32_array_from_int(tile_ids))
	var anchor_buf := storage_buffer_zero(ANCHOR_CAPACITY * 16)  # uvec4(x, y, z, reserved) per anchor
	var anchor_count_buf := storage_buffer_zero(4)

	var probe_data_buf: RID
	if bool(probe_pack.get("probe_data_borrowed", false)):
		probe_data_buf = probe_pack.get("probe_data_buffer", RID())
		track_borrowed_rid(probe_data_buf, KIND_BUFFER, SCOPE_FRAME, "auto_voxel_runtime_profile_container:probe_records")
	else:
		probe_data_buf = storage_buffer_from_bytes(probe_pack.probe_bytes)
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
	var actual_anchor_count := mini(_decode_u32_count(anchor_count_bytes), ANCHOR_CAPACITY)
	if actual_anchor_count == 0:
		var pipeline_status := _pipeline_readiness()
		_free_gpu()
		return _empty_result("no_anchors_collected", probe_pack, pipeline_status)

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
	var pipeline_status := _pipeline_readiness()

	_free_gpu()

	return _decode_results(
		anchors_bytes,
		votes_bytes,
		actual_anchor_count,
		asset_count,
		tile_count,
		sv,
		tile_grid,
		probe_pack.get("route_profiles", []),
		probe_pack,
		pipeline_status
	)


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
	if cl < 0:
		push_error("[AutoObjectProbePrefilterGPU] Collect anchors compute list begin failed")
		return
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
	if cl < 0:
		push_error("[AutoObjectProbePrefilterGPU] Score probes compute list begin failed")
		return
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
	if cl < 0:
		push_error("[AutoObjectProbePrefilterGPU] Top-K compute list begin failed")
		return
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
	if cl < 0:
		push_error("[AutoObjectProbePrefilterGPU] Reduce votes compute list begin failed")
		return
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_reduce)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	end_compute_list()


# ---------------------------------------------------------------------------
# Probe packing
# ---------------------------------------------------------------------------

func _pack_all_probes(
	autoobjects: Array,
	asset_count: int,
	voxel_size: Vector3,
	runtime_profile_container: Object = null
) -> Dictionary:
	if runtime_profile_container != null:
		return _pack_profile_container_probes(autoobjects, asset_count, voxel_size, runtime_profile_container)

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
		var rgba8 := _shader_rgba8_from_probe(p)
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
		"ok": true,
		"ready": true,
		"probe_bytes": probe_bytes,
		"range_bytes": range_bytes,
		"total_probes": all_probes.size(),
		"probe_data_borrowed": false,
		"probe_source": "transient_descriptor_probes",
		"contract_blocked": false,
		"route_profiles": _build_route_profiles(autoobjects, asset_count, voxel_size),
	}


func _pack_profile_container_probes(
	autoobjects: Array,
	asset_count: int,
	voxel_size: Vector3,
	runtime_profile_container: Object
) -> Dictionary:
	if not _profile_container_ready_to_borrow(runtime_profile_container):
		return _blocked_probe_pack("auto_voxel_runtime_profile_container_not_ready", autoobjects, asset_count, voxel_size)

	var raw_probe_buffer = runtime_profile_container.call("get_probe_buffer")
	var probe_buffer: RID = raw_probe_buffer if raw_probe_buffer is RID else RID()
	if not probe_buffer.is_valid():
		return _blocked_probe_pack("missing_probe_records_buffer", autoobjects, asset_count, voxel_size)

	var range_bytes := PackedByteArray()
	range_bytes.resize(maxi(asset_count, 1) * 8)
	var profile_ids: Array[int] = []
	for asset_id in range(asset_count):
		var autoobject := autoobjects[asset_id] as AutoObject
		if autoobject == null:
			profile_ids.append(-1)
			range_bytes.encode_u32(asset_id * 8 + 0, 0)
			range_bytes.encode_u32(asset_id * 8 + 4, 0)
			continue
		var profile_id := _profile_id_from_autoobject(autoobject, runtime_profile_container)
		if profile_id < 0:
			return _blocked_probe_pack("missing_profile_id_for_asset:%d" % asset_id, autoobjects, asset_count, voxel_size)
		var probe_range := _profile_container_probe_range(runtime_profile_container, profile_id)
		if probe_range.is_empty():
			return _blocked_probe_pack("missing_probe_range_for_profile:%d" % profile_id, autoobjects, asset_count, voxel_size)
		profile_ids.append(profile_id)
		range_bytes.encode_u32(asset_id * 8 + 0, int(probe_range.get("start", 0)))
		range_bytes.encode_u32(asset_id * 8 + 4, int(probe_range.get("count", 0)))

	return {
		"ok": true,
		"ready": true,
		"range_bytes": range_bytes,
		"total_probes": _profile_container_probe_record_count(runtime_profile_container),
		"probe_data_borrowed": true,
		"probe_data_buffer": probe_buffer,
		"probe_source": "auto_voxel_runtime_profile_container.probe_records",
		"profile_ids": profile_ids,
		"contract_blocked": false,
		"route_profiles": _build_route_profiles(autoobjects, asset_count, voxel_size),
	}


func _blocked_probe_pack(reason: String, autoobjects: Array, asset_count: int, voxel_size: Vector3) -> Dictionary:
	return {
		"ok": false,
		"ready": false,
		"reason": reason,
		"contract_blocked": true,
		"gpu_first": true,
		"cpu_fallback": false,
		"probe_data_borrowed": false,
		"probe_source": "none",
		"route_profiles": _build_route_profiles(autoobjects, asset_count, voxel_size),
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
	sv,
	tile_grid: Vector3i,
	route_profiles: Array,
	probe_pack: Dictionary = {},
	pipeline_status: Dictionary = {}
) -> Dictionary:
	# Decode anchors
	var anchors: Array[Dictionary] = []
	var anchor_stride_bytes := 16 # uvec4(x, y, z, reserved)
	var available_anchor_bytes := mini(anchors_bytes.size(), anchor_count * anchor_stride_bytes)
	available_anchor_bytes -= available_anchor_bytes % anchor_stride_bytes
	var available_anchor_count := mini(anchor_count, int(available_anchor_bytes / anchor_stride_bytes))
	for i in range(available_anchor_count):
		var base := i * anchor_stride_bytes
		var x := anchors_bytes.decode_s32(base + 0)
		var y := anchors_bytes.decode_s32(base + 4)
		var z := anchors_bytes.decode_s32(base + 8)
		anchors.append({
			"id": i,                         # debug anchor index
			"voxel_pos": Vector3i(x, y, z),  # position-only anchor voxel
		})

	# Decode voxel-region votes → per-asset sorted voxel-region lists
	var autoobject_candidate_voxel_sparses: Dictionary = {}
	var expected_vote_count := asset_count * tile_count
	var available_vote_bytes := mini(votes_bytes.size(), expected_vote_count * 4)
	available_vote_bytes -= available_vote_bytes % 4
	var available_vote_count := int(available_vote_bytes / 4)

	for asset_id in range(asset_count):
		var entries: Array[Dictionary] = []
		for tid in range(tile_count):
			var vote_index := asset_id * tile_count + tid
			var vote := votes_bytes.decode_float(vote_index * 4) if vote_index < available_vote_count else 0.0
			if vote > 0.0001:
				entries.append({"tile_id": tid, "score": vote}) # voted voxel region tile
		if entries.is_empty():
			continue
		entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.get("score", 0.0)) > float(b.get("score", 0.0)))
		var route_profile: Dictionary = route_profiles[asset_id] if asset_id < route_profiles.size() and route_profiles[asset_id] is Dictionary else {}
		var voxel_sparses := _expand_vote_entries_to_voxel_sparses(entries, route_profile, tile_grid)
		autoobject_candidate_voxel_sparses[asset_id] = voxel_sparses

	var route_debug := _route_profile_debug(route_profiles, asset_count)
	var readiness := pipeline_status.duplicate(true) if not pipeline_status.is_empty() else _pipeline_readiness()
	var route_contract := VoxelPlacementGeneratorScript._candidate_route_input_contract_from_settings({
		"candidate_voxel_regions_by_asset": autoobject_candidate_voxel_sparses,
		"candidate_route_readback_source": "gpu_vote_buffer_readback",
		"candidate_route_runtime_read_source": "cpu_debug_bridge",
	})
	var route_handoff_payload := build_candidate_route_handoff_payload(
		autoobject_candidate_voxel_sparses,
		asset_count,
		tile_grid,
		tile_count
	)
	return {
		"ok": true,
		"anchors": anchors,                                           # position-only anchor readback
		"anchor_autoobject_topk": {},                                  # GPU internal, not read back
		"autoobject_candidate_voxel_sparses": autoobject_candidate_voxel_sparses, # per-asset regions
		"candidate_voxel_regions_by_asset": autoobject_candidate_voxel_sparses,
		"candidate_voxel_sparses_by_asset": autoobject_candidate_voxel_sparses,
		"candidate_route_profiles": route_debug,                       # route expansion debug
		"candidate_route_readback_source": "gpu_vote_buffer_readback",
		"candidate_route_runtime_read_source": "cpu_debug_bridge",
		"candidate_route_input_contract": route_contract,
		"candidate_route_handoff_payload": route_handoff_payload,
		"anchor_count": anchors.size(),                                # collected anchor count
		"profile_probe_pack": _profile_probe_pack_summary(probe_pack),  # GPU-first probe pack contract/debug
		"prefilter_reason": "ok",
		"contract_blocked": false,
		"pipeline_readiness": readiness,
		"gpu_first": true,
		"cpu_fallback": false,
	}


static func build_candidate_route_handoff_payload(
	candidate_regions_by_asset: Dictionary,
	asset_count: int,
	tile_grid: Vector3i,
	tile_count: int = -1
) -> Dictionary:
	var safe_asset_count := maxi(asset_count, 0)
	var safe_tile_count := tile_count
	if safe_tile_count < 0:
		safe_tile_count = tile_grid.x * tile_grid.y * tile_grid.z
	var valid_tile_space := tile_grid.x > 0 and tile_grid.y > 0 and tile_grid.z > 0 and safe_tile_count > 0

	var per_asset_tile_ids: Array = []
	var per_asset_record_counts: Array[int] = []
	var record_count := 0
	var duplicate_tile_id_count := 0
	var invalid_tile_id_count := 0
	var empty_range_count := 0

	for asset_index in range(safe_asset_count):
		var ids := PackedInt32Array()
		var seen := {}
		var raw_regions = _candidate_regions_for_asset(candidate_regions_by_asset, asset_index)
		if valid_tile_space:
			if raw_regions is Array:
				for region in raw_regions:
					var tile_id := _candidate_route_region_to_tile_id(region, tile_grid)
					if tile_id < 0 or tile_id >= safe_tile_count:
						invalid_tile_id_count += 1
						continue
					if seen.has(tile_id):
						duplicate_tile_id_count += 1
						continue
					seen[tile_id] = true
					ids.append(tile_id)
			elif raw_regions is PackedInt32Array:
				for tile_id in raw_regions:
					var id := int(tile_id)
					if id < 0 or id >= safe_tile_count:
						invalid_tile_id_count += 1
						continue
					if seen.has(id):
						duplicate_tile_id_count += 1
						continue
					seen[id] = true
					ids.append(id)
			elif raw_regions != null:
				invalid_tile_id_count += 1
		else:
			invalid_tile_id_count += 1
		per_asset_tile_ids.append(ids)
		per_asset_record_counts.append(ids.size())
		record_count += ids.size()
		if ids.is_empty():
			empty_range_count += 1

	var record_bytes := PackedByteArray()
	record_bytes.resize(record_count * CANDIDATE_ROUTE_RECORD_STRIDE_BYTES)
	var range_bytes := PackedByteArray()
	range_bytes.resize(safe_asset_count * CANDIDATE_ROUTE_RANGE_STRIDE_BYTES)

	var record_cursor := 0
	for asset_index in range(safe_asset_count):
		var ids: PackedInt32Array = per_asset_tile_ids[asset_index]
		var range_offset := asset_index * CANDIDATE_ROUTE_RANGE_STRIDE_BYTES
		range_bytes.encode_u32(range_offset + 0, record_cursor)
		range_bytes.encode_u32(range_offset + 4, ids.size())
		range_bytes.encode_u32(range_offset + 8, asset_index)
		range_bytes.encode_u32(range_offset + 12, 0)
		for tile_id in ids:
			var record_offset := record_cursor * CANDIDATE_ROUTE_RECORD_STRIDE_BYTES
			record_bytes.encode_u32(record_offset + 0, int(tile_id))
			record_bytes.encode_u32(record_offset + 4, 0)
			record_bytes.encode_u32(record_offset + 8, 0)
			record_bytes.encode_u32(record_offset + 12, 0)
			record_cursor += 1

	var status := "readback_derived_cpu_pack"
	if not valid_tile_space:
		status = "blocked_invalid_tile_grid"
	elif safe_asset_count <= 0:
		status = "blocked_no_assets"
	elif record_count <= 0:
		status = "blocked_no_valid_route_records"

	return {
		"ok": valid_tile_space and safe_asset_count > 0,
		"schema_version": CANDIDATE_ROUTE_SCHEMA_VERSION,
		"resident_route_schema_version": CANDIDATE_ROUTE_SCHEMA_VERSION,
		"record_stride_bytes": CANDIDATE_ROUTE_RECORD_STRIDE_BYTES,
		"range_stride_bytes": CANDIDATE_ROUTE_RANGE_STRIDE_BYTES,
		"resident_route_record_stride_bytes": CANDIDATE_ROUTE_RECORD_STRIDE_BYTES,
		"resident_route_range_stride_bytes": CANDIDATE_ROUTE_RANGE_STRIDE_BYTES,
		"record_count": record_count,
		"range_count": safe_asset_count,
		"asset_count": safe_asset_count,
		"tile_count": safe_tile_count,
		"tile_grid": tile_grid,
		"record_bytes": record_bytes,
		"range_bytes": range_bytes,
		"source": CANDIDATE_ROUTE_CPU_PACK_SOURCE_LABEL,
		"source_label": CANDIDATE_ROUTE_CPU_PACK_SOURCE_LABEL,
		"producer": "AutoObjectProbePrefilterGPU",
		"has_records": record_count > 0,
		"blocked": not valid_tile_space or safe_asset_count <= 0,
		"reason": status,
		"readback_derived": true,
		"debug_readback_derived": true,
		"status": status,
		"debug_status": "readback_derived_not_resident_until_scene_placement_actor_upload",
		"duplicate_tile_id_count": duplicate_tile_id_count,
		"invalid_tile_id_count": invalid_tile_id_count,
		"empty_range_count": empty_range_count,
		"per_asset_record_counts": per_asset_record_counts,
	}


static func _candidate_regions_for_asset(candidate_regions_by_asset: Dictionary, asset_index: int) -> Variant:
	if candidate_regions_by_asset.has(asset_index):
		return candidate_regions_by_asset.get(asset_index)
	var asset_key := str(asset_index)
	if candidate_regions_by_asset.has(asset_key):
		return candidate_regions_by_asset.get(asset_key)
	return null


static func _candidate_route_region_to_tile_id(region: Variant, tile_grid: Vector3i) -> int:
	if tile_grid.x <= 0 or tile_grid.y <= 0 or tile_grid.z <= 0:
		return -1
	if region is Vector3i:
		var p := region as Vector3i
		if not _tile_pos_in_bounds(p, tile_grid):
			return -1
		return p.x + tile_grid.x * (p.y + tile_grid.y * p.z)
	if region is Vector3:
		var v := region as Vector3
		var p := Vector3i(int(v.x), int(v.y), int(v.z))
		if not _tile_pos_in_bounds(p, tile_grid):
			return -1
		return p.x + tile_grid.x * (p.y + tile_grid.y * p.z)
	if region is Dictionary:
		var record := region as Dictionary
		if record.has("tile_id"):
			return int(record.get("tile_id", -1))
		for key in ["voxel_sparse", "voxel_region", "region", "tile_pos"]:
			if record.has(key):
				return _candidate_route_region_to_tile_id(record.get(key), tile_grid)
	if typeof(region) == TYPE_INT:
		return int(region)
	if typeof(region) == TYPE_FLOAT:
		return int(region)
	return -1


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


func _pipeline_rids_ready() -> bool:
	return (
		_shader_collect.is_valid() and _pipeline_collect.is_valid()
		and _shader_score.is_valid() and _pipeline_score.is_valid()
		and _shader_topk.is_valid() and _pipeline_topk.is_valid()
		and _shader_reduce.is_valid() and _pipeline_reduce.is_valid()
	)


func _pipeline_readiness() -> Dictionary:
	var collect := _pipeline_pass_readiness(_shader_collect, _pipeline_collect)
	var score := _pipeline_pass_readiness(_shader_score, _pipeline_score)
	var topk := _pipeline_pass_readiness(_shader_topk, _pipeline_topk)
	var reduce := _pipeline_pass_readiness(_shader_reduce, _pipeline_reduce)
	return {
		"collect": collect,
		"score": score,
		"topk": topk,
		"reduce": reduce,
		"all_ready": bool(collect.get("ready", false))
			and bool(score.get("ready", false))
			and bool(topk.get("ready", false))
			and bool(reduce.get("ready", false)),
	}


func _pipeline_pass_readiness(shader: RID, pipeline: RID) -> Dictionary:
	var shader_valid := shader.is_valid()
	var pipeline_valid := pipeline.is_valid()
	return {
		"shader_rid_valid": shader_valid,
		"pipeline_rid_valid": pipeline_valid,
		"ready": shader_valid and pipeline_valid,
	}


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

func _empty_result(reason: String = "empty", probe_pack: Dictionary = {}, pipeline_status: Dictionary = {}) -> Dictionary:
	var probe_pack_ready := true
	if not probe_pack.is_empty():
		probe_pack_ready = bool(probe_pack.get("ready", false))
	var blocked := _is_contract_blocked_reason(reason) or not probe_pack_ready
	var readiness := pipeline_status.duplicate(true) if not pipeline_status.is_empty() else _pipeline_readiness_from_probe_pack(probe_pack)
	var profile_probe_pack := _profile_probe_pack_summary(probe_pack)
	var route_contract := VoxelPlacementGeneratorScript._candidate_route_input_contract_from_settings({})
	if blocked and probe_pack.is_empty() and not bool(profile_probe_pack.get("contract_blocked", false)):
		profile_probe_pack["ok"] = false
		profile_probe_pack["ready"] = false
		profile_probe_pack["reason"] = reason
		profile_probe_pack["contract_blocked"] = true
	return {
		"ok": not blocked,
		"anchors": [],                              # position-only anchor readback
		"anchor_autoobject_topk": {},               # GPU internal, not read back
		"autoobject_candidate_voxel_sparses": {},   # per-asset candidate regions
		"candidate_voxel_regions_by_asset": {},
		"candidate_voxel_sparses_by_asset": {},
		"candidate_route_profiles": [],             # route expansion debug
		"candidate_route_readback_source": "none",
		"candidate_route_runtime_read_source": "none",
		"candidate_route_input_contract": route_contract,
		"anchor_count": 0,                          # collected anchor count
		"profile_probe_pack": profile_probe_pack,
		"prefilter_reason": reason,
		"contract_blocked": blocked,
		"pipeline_readiness": readiness,
		"gpu_first": true,
		"cpu_fallback": false,
	}


func _profile_probe_pack_summary(probe_pack: Dictionary) -> Dictionary:
	if probe_pack.is_empty():
		return {
			"ok": false,
			"ready": false,
			"reason": "none",
			"contract_blocked": false,
			"gpu_first": true,
			"cpu_fallback": false,
			"probe_data_borrowed": false,
			"probe_source": "none",
			"runtime_read_source": "none",
			"borrowed_buffers": [],
			"profile_ids": [],
			"total_probes": 0,
		}
	var borrowed := bool(probe_pack.get("probe_data_borrowed", false))
	var borrowed_buffers: Array[String] = []
	if borrowed:
		borrowed_buffers.append("probe_records")
	var ready := bool(probe_pack.get("ready", false))
	var reason := "ready" if ready else str(probe_pack.get("reason", "profile_probe_pack_not_ready"))
	var contract_blocked := (not ready) or _is_contract_blocked_reason(reason)
	var raw_profile_ids = probe_pack.get("profile_ids", [])
	var profile_ids: Array = raw_profile_ids.duplicate() if raw_profile_ids is Array else []
	return {
		"ok": ready,
		"ready": ready,
		"reason": reason,
		"contract_blocked": contract_blocked,
		"gpu_first": true,
		"cpu_fallback": false,
		"probe_data_borrowed": borrowed,
		"probe_source": str(probe_pack.get("probe_source", "none")),
		"runtime_read_source": "gpu_profile_buffers" if borrowed else ("transient_descriptor_probes" if ready else "none"),
		"borrowed_buffers": borrowed_buffers,
		"profile_ids": profile_ids,
		"total_probes": int(probe_pack.get("total_probes", 0)),
	}


func _is_contract_blocked_reason(reason: String) -> bool:
	if reason in [
		"missing_rendering_device",
		"auto_voxel_runtime_profile_container_not_ready",
		"prefilter_shader_pipeline_not_ready",
		"missing_probe_records_buffer",
		"profile_probe_pack_not_ready",
	]:
		return true
	return reason.begins_with("missing_profile_id_for_asset:") \
		or reason.begins_with("missing_probe_range_for_profile:")


func _pipeline_readiness_from_probe_pack(probe_pack: Dictionary) -> Dictionary:
	var raw_status = probe_pack.get("pipeline_readiness", {})
	if raw_status is Dictionary and not (raw_status as Dictionary).is_empty():
		return (raw_status as Dictionary).duplicate(true)
	return _pipeline_readiness()


func _dirty_tile_ids_from_sv(sv: Dictionary) -> Array[int]:
	var tile_grid: Vector3i = sv.get("tile_grid_size", Vector3i.ZERO)
	var result: Array[int] = []
	var dirty_tiles: Dictionary = sv.get("dirty_tiles", {})
	for raw_key in dirty_tiles.keys():
		var tile_id := _sv_tile_key_to_shader_tile_id(str(raw_key), tile_grid)
		if tile_id >= 0 and result.find(tile_id) < 0:
			result.append(tile_id)
	var dirty_scene_voxel_tiles: Dictionary = sv.get("dirty_scene_voxel_tiles", {})
	for raw_tile in dirty_scene_voxel_tiles.values():
		if not raw_tile is Dictionary:
			continue
		_append_shader_tile_ids_for_scene_voxel_tile(raw_tile as Dictionary, tile_grid, result)
	return result


func _sv_tile_key_to_shader_tile_id(tile_key: String, tile_grid: Vector3i) -> int:
	if tile_grid.x <= 0 or tile_grid.y <= 0 or tile_grid.z <= 0:
		return -1
	var parts := tile_key.split(":")
	var tile_x := -1
	var tile_y := -1
	var slice_index := 0
	if parts.size() == 3:
		slice_index = int(parts[0])
		tile_x = int(parts[1])
		tile_y = int(parts[2])
	elif parts.size() == 4 and parts[1] == "collision":
		slice_index = int(parts[0])
		tile_x = int(parts[2])
		tile_y = int(parts[3])
	else:
		return -1
	var tile_z := tile_y
	var tile_layer_y := clampi(int(slice_index / TILE_SIZE), 0, tile_grid.y - 1)
	var tile_pos := Vector3i(tile_x, tile_layer_y, tile_z)
	if not _tile_pos_in_bounds(tile_pos, tile_grid):
		return -1
	return _tile_pos_to_id(tile_pos, tile_grid)


func _append_shader_tile_ids_for_scene_voxel_tile(tile: Dictionary, tile_grid: Vector3i, result: Array[int]) -> void:
	if tile_grid.x <= 0 or tile_grid.y <= 0 or tile_grid.z <= 0:
		return
	var voxel_min := _vector3i_from_value(tile.get("voxel_min", tile.get("bounds_min", Vector3i.ZERO)), Vector3i.ZERO)
	var voxel_max := _vector3i_from_value(tile.get("voxel_max", tile.get("bounds_max", voxel_min + Vector3i.ONE)), voxel_min + Vector3i.ONE)
	voxel_max = Vector3i(
		maxi(voxel_max.x, voxel_min.x + 1),
		maxi(voxel_max.y, voxel_min.y + 1),
		maxi(voxel_max.z, voxel_min.z + 1)
	)
	var tile_min := Vector3i(
		clampi(int(voxel_min.x / TILE_SIZE), 0, tile_grid.x - 1),
		clampi(int(voxel_min.y / TILE_SIZE), 0, tile_grid.y - 1),
		clampi(int(voxel_min.z / TILE_SIZE), 0, tile_grid.z - 1)
	)
	var tile_max := Vector3i(
		clampi(int((voxel_max.x - 1) / TILE_SIZE), 0, tile_grid.x - 1),
		clampi(int((voxel_max.y - 1) / TILE_SIZE), 0, tile_grid.y - 1),
		clampi(int((voxel_max.z - 1) / TILE_SIZE), 0, tile_grid.z - 1)
	)
	for ty in range(tile_min.y, tile_max.y + 1):
		for tz in range(tile_min.z, tile_max.z + 1):
			for tx in range(tile_min.x, tile_max.x + 1):
				var tile_id := _tile_pos_to_id(Vector3i(tx, ty, tz), tile_grid)
				if tile_id >= 0 and result.find(tile_id) < 0:
					result.append(tile_id)


func _all_tile_ids(sv: Dictionary) -> Array[int]:
	var total := int(sv.get("total_tiles", 0))
	var result: Array[int] = []
	for i in range(total):
		result.append(i)
	return result


func _attach_runtime_profile_container_device(runtime_profile_container: Object) -> bool:
	if not _profile_container_ready_to_borrow(runtime_profile_container):
		return false
	if not runtime_profile_container.has_method("get_rendering_device"):
		return false
	var raw_rd = runtime_profile_container.call("get_rendering_device")
	var profile_rd: RenderingDevice = raw_rd as RenderingDevice
	if profile_rd == null:
		return false
	return attach_rendering_device(profile_rd, false)


func _profile_container_ready_to_borrow(runtime_profile_container: Object) -> bool:
	if runtime_profile_container == null:
		return false
	if not runtime_profile_container.has_method("is_runtime_ready"):
		return false
	if not bool(runtime_profile_container.call("is_runtime_ready")):
		return false
	if not runtime_profile_container.has_method("get_probe_buffer"):
		return false
	var raw_probe_buffer = runtime_profile_container.call("get_probe_buffer")
	if not raw_probe_buffer is RID:
		return false
	var probe_buffer: RID = raw_probe_buffer
	return probe_buffer.is_valid()


func _profile_id_from_autoobject(autoobject: AutoObject, runtime_profile_container: Object) -> int:
	if autoobject == null:
		return -1
	for profile_key in ["profile_id", "auto_voxel_profile_id", "runtime_profile_id", "asset_profile_id"]:
		if autoobject.has_meta(profile_key):
			return int(autoobject.get_meta(profile_key))
		if _object_has_property(autoobject, profile_key):
			return int(autoobject.get(profile_key))
	var write_spec := {}
	if autoobject.has_method("get_voxel_write_spec"):
		var raw_spec = autoobject.call("get_voxel_write_spec")
		if raw_spec is Dictionary:
			write_spec = raw_spec as Dictionary
	for profile_key in ["profile_id", "auto_voxel_profile_id", "runtime_profile_id", "asset_profile_id"]:
		if write_spec.has(profile_key):
			return int(write_spec.get(profile_key, -1))
	if not runtime_profile_container.has_method("get_profile_id_for_descriptor"):
		return -1
	if not _object_has_property(autoobject, "voxel_descriptor"):
		return -1
	var descriptor = autoobject.get("voxel_descriptor")
	if not descriptor is Resource:
		return -1
	var density := float(autoobject.get("semantic_probe_density")) if _object_has_property(autoobject, "semantic_probe_density") else -1.0
	return int(runtime_profile_container.call(
		"get_profile_id_for_descriptor",
		descriptor,
		0.0,
		density,
		Vector3.ONE,
		autoobject.mesh
	))


func _profile_container_probe_range(runtime_profile_container: Object, profile_id: int) -> Dictionary:
	if runtime_profile_container == null or not runtime_profile_container.has_method("get_probe_range_for_profile_id"):
		return {}
	var raw_range = runtime_profile_container.call("get_probe_range_for_profile_id", profile_id)
	if raw_range is Dictionary:
		return (raw_range as Dictionary).duplicate(true)
	return {}


func _profile_container_probe_record_count(runtime_profile_container: Object) -> int:
	if runtime_profile_container == null or not runtime_profile_container.has_method("get_gpu_buffer_summary"):
		return 0
	var raw_summary = runtime_profile_container.call("get_gpu_buffer_summary")
	if not raw_summary is Dictionary:
		return 0
	var summary := raw_summary as Dictionary
	var buffers: Dictionary = summary.get("buffers", {})
	var probe_summary: Dictionary = buffers.get(RuntimeProfileContainerScript.PROBE_RECORD_BUFFER, {})
	return int(probe_summary.get("record_count", 0))


func _ensure_float_array(arr: PackedFloat32Array, expected: int) -> PackedFloat32Array:
	if arr.size() >= expected:
		return arr
	var result := arr.duplicate()
	result.resize(expected)
	return result


func _decode_u32_count(bytes: PackedByteArray) -> int:
	if bytes.size() < 4:
		return 0
	return int(bytes.decode_u32(0))


func _pack_u32_array_from_int(values: Array[int]) -> PackedByteArray:
	if values.is_empty():
		var bytes := PackedByteArray()
		bytes.resize(4)
		return bytes
	return PackedInt32Array(values).to_byte_array()


func _target_color_rgba8_bytes(prepacked: PackedByteArray, voxel_count: int) -> PackedByteArray:
	var expected_bytes := maxi(voxel_count, 1) * 4
	if prepacked.size() >= expected_bytes:
		if prepacked.size() == expected_bytes:
			return prepacked
		return prepacked.slice(0, expected_bytes)
	var bytes := PackedByteArray()
	bytes.resize(expected_bytes)
	return bytes


func _target_occupancy_bytes(prepacked: PackedByteArray, voxel_count: int) -> PackedByteArray:
	var expected_bytes := maxi(voxel_count, 1) * 4
	if prepacked.size() >= expected_bytes:
		if prepacked.size() == expected_bytes:
			return prepacked
		return prepacked.slice(0, expected_bytes)
	var bytes := PackedByteArray()
	bytes.resize(expected_bytes)
	return bytes


static func _pack_rgba8(c: Color) -> int:
	var r := clampi(int(roundf(c.r * 255.0)), 0, 255)
	var g := clampi(int(roundf(c.g * 255.0)), 0, 255)
	var b := clampi(int(roundf(c.b * 255.0)), 0, 255)
	var a := clampi(int(roundf(c.a * 255.0)), 0, 255)
	return (r << 24) | (g << 16) | (b << 8) | a


static func _shader_rgba8_from_probe(probe: Dictionary) -> int:
	if probe.has("expected_color") or probe.has("color") or probe.has("expected_complexity") or probe.has("complexity"):
		var color := SemanticProbeProfileScript.color_from_value(
			probe.get("expected_color", probe.get("color", Color.WHITE)),
			Color.WHITE
		)
		color.a = clampf(float(probe.get("expected_complexity", probe.get("complexity", color.a))), 0.0, 1.0)
		return _pack_rgba8(color)
	return _semantic_rgba8_to_shader_rgba8(int(probe.get("expected_rgba8", 0)))


static func _semantic_rgba8_to_shader_rgba8(packed: int) -> int:
	var r := packed & 0xff
	var g := (packed >> 8) & 0xff
	var b := (packed >> 16) & 0xff
	var a := (packed >> 24) & 0xff
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


static func _build_route_profiles(autoobjects: Array, asset_count: int, voxel_size: Vector3) -> Array[Dictionary]:
	var profiles: Array[Dictionary] = []
	for obj_idx in range(asset_count):
		var autoobject := autoobjects[obj_idx] as AutoObject
		if autoobject == null:
			profiles.append(_empty_route_profile(obj_idx))
			continue
		var probes: Array = autoobject.get_semantic_probes(autoobject.semantic_probe_density)
		var collisions: Array = autoobject.get_collision() if autoobject.has_method("get_collision") else []
		var context_radius := _object_context_sensing_radius(autoobject)
		profiles.append(_build_route_profile_from_arrays(
			probes,
			collisions,
			voxel_size,
			context_radius,
			obj_idx
		))
	return profiles


static func _empty_route_profile(asset_index: int) -> Dictionary:
	return {
		"asset_index": asset_index,                 # asset index in current registry
		"probe_min": Vector3i.ZERO,                 # min probe offset in voxels
		"probe_max": Vector3i.ZERO,                 # max probe offset in voxels
		"footprint_min": Vector3i.ZERO,             # min footprint voxel
		"footprint_max": Vector3i.ZERO,             # max footprint voxel
		"context_radius_voxels": Vector3i.ZERO,     # context radius in voxels
		"interpolation_guard_voxels": 1,            # route expansion guard
		"tile_radius": Vector3i.ONE,                # tile expansion radius
	}


static func _build_route_profile_from_arrays(
	probes: Array,
	collision: Array,
	voxel_size: Vector3,
	context_sensing_radius: float,
	asset_index: int = 0
) -> Dictionary:
	var probe_bounds := _probe_offset_voxel_bounds(probes, voxel_size)
	var footprint_bounds := _footprint_voxel_bounds(collision, voxel_size)
	var context_radius_voxels := _radius_to_voxels(context_sensing_radius, voxel_size)
	var guard := maxi(1, 1)
	var min_pad := Vector3i(
		mini(int(probe_bounds.get("min", Vector3i.ZERO).x), int(footprint_bounds.get("min", Vector3i.ZERO).x)) - context_radius_voxels.x - guard,
		mini(int(probe_bounds.get("min", Vector3i.ZERO).y), int(footprint_bounds.get("min", Vector3i.ZERO).y)) - context_radius_voxels.y - guard,
		mini(int(probe_bounds.get("min", Vector3i.ZERO).z), int(footprint_bounds.get("min", Vector3i.ZERO).z)) - context_radius_voxels.z - guard
	)
	var max_pad := Vector3i(
		maxi(int(probe_bounds.get("max", Vector3i.ZERO).x), int(footprint_bounds.get("max", Vector3i.ZERO).x)) + context_radius_voxels.x + guard,
		maxi(int(probe_bounds.get("max", Vector3i.ZERO).y), int(footprint_bounds.get("max", Vector3i.ZERO).y)) + context_radius_voxels.y + guard,
		maxi(int(probe_bounds.get("max", Vector3i.ZERO).z), int(footprint_bounds.get("max", Vector3i.ZERO).z)) + context_radius_voxels.z + guard
	)
	return {
		"asset_index": asset_index,                                # asset index in current registry
		"probe_min": probe_bounds.get("min", Vector3i.ZERO),       # min probe offset in voxels
		"probe_max": probe_bounds.get("max", Vector3i.ZERO),       # max probe offset in voxels
		"footprint_min": footprint_bounds.get("min", Vector3i.ZERO), # min footprint voxel
		"footprint_max": footprint_bounds.get("max", Vector3i.ZERO), # max footprint voxel
		"context_radius_voxels": context_radius_voxels,            # context radius in voxels
		"interpolation_guard_voxels": guard,                       # route expansion guard
		"tile_radius": _padding_to_tile_radius(min_pad, max_pad),  # tile expansion radius
	}


static func _probe_offset_voxel_bounds(probes: Array, voxel_size: Vector3) -> Dictionary:
	var has_probe := false
	var min_v := Vector3i.ZERO
	var max_v := Vector3i.ZERO
	for raw_probe in probes:
		if not raw_probe is Dictionary:
			continue
		var probe := raw_probe as Dictionary
		var offset := SemanticProbeProfileScript.vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
		var ov := _world_offset_to_voxels(offset, voxel_size)
		if not has_probe:
			min_v = ov
			max_v = ov
			has_probe = true
		else:
			min_v = Vector3i(mini(min_v.x, ov.x), mini(min_v.y, ov.y), mini(min_v.z, ov.z))
			max_v = Vector3i(maxi(max_v.x, ov.x), maxi(max_v.y, ov.y), maxi(max_v.z, ov.z))
	return {"min": min_v, "max": max_v}


static func _footprint_voxel_bounds(collision: Array, voxel_size: Vector3) -> Dictionary:
	var footprint: Array = VoxelPlacementGeneratorScript.bake_footprint_from_collision(
		collision,
		voxel_size,
		true,
		1
	)
	if footprint.is_empty():
		return {"min": Vector3i.ZERO, "max": Vector3i.ZERO}
	var min_v := Vector3i(2147483647, 2147483647, 2147483647)
	var max_v := Vector3i(-2147483648, -2147483648, -2147483648)
	for raw_entry in footprint:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		var p := _vector3i_from_value(entry.get("local_pos", Vector3i.ZERO), Vector3i.ZERO)
		min_v = Vector3i(mini(min_v.x, p.x), mini(min_v.y, p.y), mini(min_v.z, p.z))
		max_v = Vector3i(maxi(max_v.x, p.x), maxi(max_v.y, p.y), maxi(max_v.z, p.z))
	return {"min": min_v, "max": max_v}


static func _radius_to_voxels(radius: float, voxel_size: Vector3) -> Vector3i:
	var r := maxf(radius, 0.0)
	if r <= 0.0:
		return Vector3i.ZERO
	return Vector3i(
		ceili(r / maxf(voxel_size.x, 0.0001)),
		ceili(r / maxf(voxel_size.y, 0.0001)),
		ceili(r / maxf(voxel_size.z, 0.0001))
	)


static func _padding_to_tile_radius(min_pad: Vector3i, max_pad: Vector3i) -> Vector3i:
	return Vector3i(
		ceili(float(maxi(abs(min_pad.x), abs(max_pad.x))) / float(TILE_SIZE)),
		ceili(float(maxi(abs(min_pad.y), abs(max_pad.y))) / float(TILE_SIZE)),
		ceili(float(maxi(abs(min_pad.z), abs(max_pad.z))) / float(TILE_SIZE))
	)


static func _expand_vote_entries_to_voxel_sparses(
	entries: Array,
	route_profile: Dictionary,
	tile_grid: Vector3i
) -> Array[Vector3i]:
	var radius := _vector3i_from_value(route_profile.get("tile_radius", Vector3i.ONE), Vector3i.ONE)
	radius = Vector3i(maxi(radius.x, 0), maxi(radius.y, 0), maxi(radius.z, 0))
	var scored_by_tile := {}
	for raw_entry in entries:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		var center_id := int(entry.get("tile_id", -1))
		if center_id < 0:
			continue
		var center := _tile_id_to_pos(center_id, tile_grid)
		var score := float(entry.get("score", 0.0))
		for dz in range(-radius.z, radius.z + 1):
			for dy in range(-radius.y, radius.y + 1):
				for dx in range(-radius.x, radius.x + 1):
					var p := Vector3i(center.x + dx, center.y + dy, center.z + dz)
					if not _tile_pos_in_bounds(p, tile_grid):
						continue
					var tid := _tile_pos_to_id(p, tile_grid)
					scored_by_tile[tid] = maxf(float(scored_by_tile.get(tid, -INF)), score)
	var expanded_entries: Array[Dictionary] = []
	for tid in scored_by_tile:
		expanded_entries.append({"tile_id": int(tid), "score": float(scored_by_tile[tid])})
	expanded_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var score_a := float(a.get("score", 0.0))
		var score_b := float(b.get("score", 0.0))
		if not is_equal_approx(score_a, score_b):
			return score_a > score_b
		return int(a.get("tile_id", 0)) < int(b.get("tile_id", 0))
	)
	var voxel_sparses: Array[Vector3i] = []
	for entry in expanded_entries:
		voxel_sparses.append(_tile_id_to_pos(int(entry.get("tile_id", 0)), tile_grid))
	return voxel_sparses


static func _tile_pos_in_bounds(p: Vector3i, tile_grid: Vector3i) -> bool:
	return (
		p.x >= 0 and p.x < tile_grid.x
		and p.y >= 0 and p.y < tile_grid.y
		and p.z >= 0 and p.z < tile_grid.z
	)


static func _tile_pos_to_id(p: Vector3i, tile_grid: Vector3i) -> int:
	return p.x + tile_grid.x * (p.z + tile_grid.z * p.y)


static func _tile_id_to_pos(tile_id: int, tile_grid: Vector3i) -> Vector3i:
	var tx := tile_id % tile_grid.x
	var tz := (tile_id / tile_grid.x) % tile_grid.z
	var ty := tile_id / (tile_grid.x * tile_grid.z)
	return Vector3i(tx, ty, tz)


static func _world_offset_to_voxels(offset: Vector3, voxel_size: Vector3) -> Vector3i:
	return Vector3i(
		roundi(offset.x / maxf(voxel_size.x, 0.0001)),
		roundi(offset.y / maxf(voxel_size.y, 0.0001)),
		roundi(offset.z / maxf(voxel_size.z, 0.0001))
	)


static func _vector3i_from_value(value, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	if value is Vector3i:
		return value as Vector3i
	if value is Vector3:
		var v := value as Vector3
		return Vector3i(roundi(v.x), roundi(v.y), roundi(v.z))
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))
	if value is Dictionary:
		var d := value as Dictionary
		return Vector3i(int(d.get("x", fallback.x)), int(d.get("y", fallback.y)), int(d.get("z", fallback.z)))
	return fallback


static func _object_context_sensing_radius(autoobject: AutoObject) -> float:
	if autoobject == null:
		return 0.0
	var descriptor = autoobject.get("voxel_descriptor") if _object_has_property(autoobject, "voxel_descriptor") else null
	if descriptor is Resource and _object_has_property(descriptor, "context_sensing_radius"):
		return maxf(float(descriptor.get("context_sensing_radius")), 0.0)
	if _object_has_property(autoobject, "context_sensing_radius"):
		return maxf(float(autoobject.get("context_sensing_radius")), 0.0)
	return 0.0


static func _object_has_property(object: Object, property_name: String) -> bool:
	if object == null:
		return false
	for property in object.get_property_list():
		if str((property as Dictionary).get("name", "")) == property_name:
			return true
	return false


static func _route_profile_debug(route_profiles: Array, asset_count: int) -> Array[Dictionary]:
	var debug: Array[Dictionary] = []
	for asset_id in range(asset_count):
		if asset_id < route_profiles.size() and route_profiles[asset_id] is Dictionary:
			debug.append((route_profiles[asset_id] as Dictionary).duplicate(true))
		else:
			debug.append(_empty_route_profile(asset_id))
	return debug
