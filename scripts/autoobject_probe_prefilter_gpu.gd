class_name AutoObjectProbePrefilterGPU
extends "res://scripts/godot_compute_shader_base.gd"

## GPU-accelerated AutoObject probe prefilter.
## This is the only supported prefilter path. The CPU fallback was removed
## because anchor_count * asset_count * probe_count is too expensive for
## GDScript and can stall large scenes.
##
## Uses 5 compute-shader dispatches by default:
##   1. collect_sv_anchors        — find position-only anchor voxels
##   2. score_anchor_asset_probes — score each anchor×asset probe set (Pass A)
##   3. select_anchor_topk        — per-anchor top-K asset selection   (Pass B)
##   4. reduce_anchor_topk_to_voxel_regions — aggregate to per-asset voxel-region votes
##   5. pack_candidate_route_records_from_votes — dense votes → schema-v1 record/range bytes (default enabled)
##
## CPU vote-decoding path is preserved as a debug-only fallback when GPU route
## pack is explicitly disabled via target_read_buffers options or fails to execute.

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
const CANDIDATE_ROUTE_GPU_PACK_SOURCE_LABEL := "gpu_vote_buffer_gpu_pack"
const CANDIDATE_ROUTE_GPU_PACK_PASS := "pack_candidate_route_records_from_votes"
const CANDIDATE_ROUTE_GPU_EXPAND_PASS := "expand_scene_voxel_tile_routes"
const SCENE_VOXEL_TILE_SUMMARY_STRIDE_UINTS := 8  ## 32 bytes per summary / 4 bytes per uint

var anchor_topk: int = 4                    # per-anchor asset top-K target
var max_complexity_field: float = 0.15           # anchor allowed scene occupancy threshold
var max_collision_field: float = 0.05       # anchor allowed collision threshold
var min_support: float = 0.25               # required support below anchor
var min_target_interest: float = 0.01       # minimum TargetSV_B demand
var min_prefilter_score: float = 0.35       # minimum probe score accepted by shader
var interpolation_guard_voxels: int = 1     # route expansion guard, at least 1 voxel
var use_gpu_candidate_route_pack: bool = true  ## P0 #4: GPU route pack enabled by default; CPU vote decoding preserved as debug-only fallback (set target_read_buffers.use_gpu_candidate_route_pack=false to opt-out)

# Shaders & pipelines
var _shader_collect: RID
var _shader_score: RID
var _shader_topk: RID
var _shader_reduce: RID
var _shader_route_pack: RID
var _shader_route_expand: RID
var _pipeline_collect: RID
var _pipeline_score: RID
var _pipeline_topk: RID
var _pipeline_reduce: RID
var _pipeline_route_pack: RID
var _pipeline_route_expand: RID
var _candidate_route_gpu_pack_record_buf: RID
var _candidate_route_gpu_pack_range_buf: RID


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func run_probe_prefilter(
	sv: Dictionary,
	autoobjects: Array,
	dirty_tile_ids: Array[int] = [],
	runtime_profile_container: Object = null,
	target_field_bytes: PackedFloat32Array = PackedFloat32Array(),
	target_read_buffers: Dictionary = {},
	tile_summaries_rid: RID = RID()
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

	var route_pack_requested := _candidate_route_gpu_pack_requested(target_read_buffers)
	var use_expand_shader := tile_summaries_rid.is_valid() and route_pack_requested
	_load_shaders(route_pack_requested, use_expand_shader)
	if not _pipeline_rids_ready(route_pack_requested, use_expand_shader):
		var pipeline_status := _pipeline_readiness(route_pack_requested, use_expand_shader)
		var blocked_result := _empty_result("prefilter_shader_pipeline_not_ready", {}, pipeline_status)
		_free_gpu()
		return blocked_result

	var result := _run_gpu_pipeline(sv, autoobjects, voxel_sparse_ids, runtime_profile_container, target_field_bytes, target_read_buffers, tile_summaries_rid)
	if _result_has_resident_candidate_route_payload(result):
		gc_frame()
	else:
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
	target_field_bytes: PackedFloat32Array = PackedFloat32Array(),
	target_read_buffers: Dictionary = {},
	tile_summaries_rid: RID = RID()
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

	var complexity_collision_bytes := _pack_complexity_collision_float_bytes(
		_ensure_float_array(sv.get(complexity_field, PackedFloat32Array()), voxel_count),
		_ensure_float_array(sv.get("collision_field", PackedFloat32Array()), voxel_count),
		voxel_count
	)
	var route_pack_requested := _candidate_route_gpu_pack_requested(target_read_buffers)
	var use_expand_shader := tile_summaries_rid.is_valid() and route_pack_requested
	var target_buffer_pack := _target_read_buffer_pack(target_read_buffers, target_field_bytes, voxel_count)
	if not bool(target_buffer_pack.get("ready", false)):
		var blocked_reason := str(target_buffer_pack.get("reason", "target_read_buffer_not_ready"))
		var blocked_result := _empty_result(blocked_reason, {}, _pipeline_readiness(route_pack_requested, use_expand_shader))
		blocked_result["target_read_buffer_source"] = str(target_buffer_pack.get("target_read_buffer_source", "none"))
		blocked_result["target_read_buffer_summary"] = _target_read_buffer_summary(target_buffer_pack)
		blocked_result["target_read_buffer_blocked_reason"] = blocked_reason
		_free_gpu()
		return blocked_result

	var asset_count := mini(autoobjects.size(), MAX_ASSETS)
	var probe_pack := _pack_all_probes(autoobjects, asset_count, voxel_size, runtime_profile_container)
	if not bool(probe_pack.get("ready", true)):
		return _empty_result(str(probe_pack.get("reason", "profile_probe_pack_not_ready")), probe_pack)

	# ---- Create GPU buffers ----

	var complexity_collision_buf := storage_buffer_from_bytes(complexity_collision_bytes, SCOPE_FRAME, "complexity_collision_merged")
	var target_field_buf: RID = target_buffer_pack.get("target_field_buffer", RID())
	if bool(target_buffer_pack.get("target_read_buffers_borrowed", false)):
		track_borrowed_rid(target_field_buf, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_field")
	else:
		var target_field_data: PackedFloat32Array = target_buffer_pack.get("target_field_bytes", PackedFloat32Array())
		target_field_buf = storage_buffer_from_floats(target_field_data, SCOPE_FRAME, "target_field_uploaded")
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
		complexity_collision_buf, target_field_buf, dirty_tile_buf,
		anchor_buf, anchor_count_buf,
		grid_size, tile_grid, tile_ids.size()
	)
	submit_and_sync(true)

	# Read anchor count
	var anchor_count_bytes := _rd.buffer_get_data(anchor_count_buf, 0, 4)
	var actual_anchor_count := mini(_decode_u32_count(anchor_count_bytes), ANCHOR_CAPACITY)
	if actual_anchor_count == 0:
		var pipeline_status := _pipeline_readiness(route_pack_requested, use_expand_shader)
		_free_gpu()
		return _empty_result("no_anchors_collected", probe_pack, pipeline_status)

	# ---- Dispatch 2-4: Score probes -> Top-K selection -> Voxel-region reduction ----

	if not _dispatch_score_topk_reduce(
		anchor_buf, probe_range_buf, probe_data_buf,
		complexity_collision_buf, target_field_buf,
		asset_scores_buf, topk_buf, voxel_sparse_votes_buf,
		grid_size, voxel_size,
		tile_grid, tile_count, actual_anchor_count, asset_count
	):
		var pipeline_status := _pipeline_readiness(route_pack_requested, use_expand_shader)
		_free_gpu()
		return _empty_result("score_topk_reduce_compute_list_begin_failed", probe_pack, pipeline_status)

	var gpu_route_pack_payload := {}
	if route_pack_requested:
		gpu_route_pack_payload = _run_candidate_route_gpu_pack_pass(
			voxel_sparse_votes_buf,
			probe_pack.get("route_profiles", []),
			tile_grid,
			tile_count,
			asset_count,
			_candidate_route_cpu_debug_readback_requested(target_read_buffers),
			tile_summaries_rid
		)
	if not bool(gpu_route_pack_payload.get("ok", false)):
		submit_and_sync(true)

	# ---- Read back results ----

	var anchors_bytes := _rd.buffer_get_data(anchor_buf, 0, actual_anchor_count * 16)
	var resident_route_payload_ready := _candidate_route_payload_has_resident_rids(gpu_route_pack_payload)
	var cpu_route_debug_readback_requested := _candidate_route_cpu_debug_readback_requested(target_read_buffers)
	var votes_bytes := PackedByteArray()
	if not resident_route_payload_ready or cpu_route_debug_readback_requested:
		votes_bytes = _rd.buffer_get_data(voxel_sparse_votes_buf, 0, asset_count * tile_count * 4)
	var pipeline_status := _pipeline_readiness(route_pack_requested, use_expand_shader)

	if resident_route_payload_ready:
		gc_frame()
	else:
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
		pipeline_status,
		_target_read_buffer_summary(target_buffer_pack),
		gpu_route_pack_payload,
		cpu_route_debug_readback_requested
	)


# ---------------------------------------------------------------------------
# Dispatch helpers
# ---------------------------------------------------------------------------

func _dispatch_collect(
	complexity_collision_buf: RID, target_field_buf: RID,
	dirty_tile_buf: RID, anchor_buf: RID, anchor_count_buf: RID,
	grid_size: Vector3i, tile_grid: Vector3i, dirty_count: int
) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, complexity_collision_buf),
		make_storage_uniform(1, target_field_buf),
		make_storage_uniform(2, dirty_tile_buf),
		make_storage_uniform(3, anchor_buf),
		make_storage_uniform(4, anchor_count_buf),
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
	push.encode_float(32, max_complexity_field)
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


func _dispatch_score_topk_reduce(
	anchor_buf: RID, probe_range_buf: RID,
	probe_data_buf: RID, complexity_collision_buf: RID,
	target_field_buf: RID, asset_scores_buf: RID,
	topk_buf: RID, voxel_sparse_votes_buf: RID,
	grid_size: Vector3i, voxel_size: Vector3,
	tile_grid: Vector3i, tile_count: int,
	anchor_count: int, asset_count: int
) -> bool:
	var anchor_grid_x := ceili(sqrt(float(anchor_count)))
	var anchor_grid_y := ceili(float(anchor_count) / float(anchor_grid_x))
	var asset_blocks := ceili(float(asset_count) / 16.0)

	var score_set0 := create_uniform_set([
		make_storage_uniform(0, anchor_buf),
		make_storage_uniform(1, probe_range_buf),
		make_storage_uniform(2, probe_data_buf),
		make_storage_uniform(3, complexity_collision_buf),
		make_storage_uniform(4, target_field_buf),
		make_storage_uniform(5, asset_scores_buf),
	], _shader_score, 0)

	var topk_set0 := create_uniform_set([
		make_storage_uniform(0, asset_scores_buf),
		make_storage_uniform(1, topk_buf),
	], _shader_topk, 0)

	var reduce_set0 := create_uniform_set([
		make_storage_uniform(0, anchor_buf),
		make_storage_uniform(1, topk_buf),
		make_storage_uniform(2, voxel_sparse_votes_buf),
	], _shader_reduce, 0)

	var score_push := PackedByteArray()
	score_push.resize(48)
	score_push.encode_s32(0, grid_size.x)
	score_push.encode_s32(4, grid_size.y)
	score_push.encode_s32(8, grid_size.z)
	score_push.encode_s32(12, asset_count)
	score_push.encode_float(16, 1.0 / maxf(voxel_size.x, 0.0001))
	score_push.encode_float(20, 1.0 / maxf(voxel_size.y, 0.0001))
	score_push.encode_float(24, 1.0 / maxf(voxel_size.z, 0.0001))
	score_push.encode_float(28, 0.0)
	score_push.encode_u32(32, anchor_count)
	score_push.encode_u32(36, anchor_grid_x)
	score_push.encode_float(40, min_prefilter_score)
	score_push.encode_float(44, 0.0)

	var topk_push := PackedByteArray()
	topk_push.resize(16)
	topk_push.encode_u32(0, anchor_count)
	topk_push.encode_u32(4, asset_count)
	topk_push.encode_u32(8, anchor_grid_x)
	topk_push.encode_float(12, min_prefilter_score)

	var reduce_push := PackedByteArray()
	reduce_push.resize(32)
	reduce_push.encode_s32(0, tile_grid.x)
	reduce_push.encode_s32(4, tile_grid.y)
	reduce_push.encode_s32(8, tile_grid.z)
	reduce_push.encode_s32(12, tile_count)
	reduce_push.encode_u32(16, anchor_count)
	reduce_push.encode_u32(20, asset_count)
	reduce_push.encode_u32(24, TOPK)
	reduce_push.encode_u32(28, 0)

	var cl := begin_compute_list()
	if cl < 0:
		push_error("[AutoObjectProbePrefilterGPU] Score/Top-K/Reduce compute list begin failed")
		return false
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_score)
	_rd.compute_list_bind_uniform_set(cl, score_set0, 0)
	_rd.compute_list_set_push_constant(cl, score_push, score_push.size())
	_rd.compute_list_dispatch(cl, anchor_grid_x, anchor_grid_y, asset_blocks)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_topk)
	_rd.compute_list_bind_uniform_set(cl, topk_set0, 0)
	_rd.compute_list_set_push_constant(cl, topk_push, topk_push.size())
	_rd.compute_list_dispatch(cl, anchor_grid_x, anchor_grid_y, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_reduce)
	_rd.compute_list_bind_uniform_set(cl, reduce_set0, 0)
	_rd.compute_list_set_push_constant(cl, reduce_push, reduce_push.size())
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	_rd.compute_list_add_barrier(cl)
	end_compute_list()
	return true


func _dispatch_score(
	anchor_buf: RID, probe_range_buf: RID,
	probe_data_buf: RID, complexity_collision_buf: RID,
	target_field_buf: RID, asset_scores_buf: RID,
	grid_size: Vector3i, voxel_size: Vector3, asset_count: int,
	anchor_count: int, anchor_grid_x: int, anchor_grid_y: int,
	asset_blocks: int
) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, anchor_buf),
		make_storage_uniform(1, probe_range_buf),
		make_storage_uniform(2, probe_data_buf),
		make_storage_uniform(3, complexity_collision_buf),
		make_storage_uniform(4, target_field_buf),
		make_storage_uniform(5, asset_scores_buf),
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


func _run_candidate_route_gpu_pack_pass(
	voxel_sparse_votes_buf: RID,
	route_profiles: Array,
	tile_grid: Vector3i,
	tile_count: int,
	asset_count: int,
	debug_readback_bytes: bool = false,
	tile_summaries_rid: RID = RID()
) -> Dictionary:
	var use_expand := tile_summaries_rid.is_valid()
	var shader_rid := _shader_route_expand if use_expand else _shader_route_pack
	var pipeline_rid := _pipeline_route_expand if use_expand else _pipeline_route_pack
	var pack_pass_label := CANDIDATE_ROUTE_GPU_EXPAND_PASS if use_expand else CANDIDATE_ROUTE_GPU_PACK_PASS

	if not shader_rid.is_valid() or not pipeline_rid.is_valid():
		return _candidate_route_gpu_pack_blocked(
			"candidate_route_gpu_%s_shader_not_ready" % ("expand" if use_expand else "pack"),
			asset_count, tile_grid, tile_count
		)
	if not voxel_sparse_votes_buf.is_valid():
		return _candidate_route_gpu_pack_blocked("missing_voxel_sparse_votes_buffer", asset_count, tile_grid, tile_count)
	if asset_count <= 0 or tile_count <= 0 or tile_grid.x <= 0 or tile_grid.y <= 0 or tile_grid.z <= 0:
		return _candidate_route_gpu_pack_blocked("invalid_route_pack_dimensions", asset_count, tile_grid, tile_count)

	_release_candidate_route_gpu_pack_payload_buffers()
	var record_capacity := maxi(asset_count * tile_count, 0)
	var route_radius_buf := storage_buffer_from_bytes(_pack_route_profile_radius_bytes(route_profiles, asset_count), SCOPE_FRAME, "candidate_route_profile_radii")
	var route_mark_buf := storage_buffer_zero(record_capacity * 4, SCOPE_FRAME, "candidate_route_tile_marks")
	var record_buf := storage_buffer_zero(record_capacity * CANDIDATE_ROUTE_RECORD_STRIDE_BYTES, SCOPE_PERSISTENT, "candidate_route_records_gpu_%s" % ("expand" if use_expand else "pack"))
	var range_buf := storage_buffer_zero(asset_count * CANDIDATE_ROUTE_RANGE_STRIDE_BYTES, SCOPE_PERSISTENT, "candidate_route_ranges_gpu_%s" % ("expand" if use_expand else "pack"))
	var debug_buf := storage_buffer_zero(64, SCOPE_FRAME, "candidate_route_gpu_%s_debug" % ("expand" if use_expand else "pack"))
	if (
		not route_radius_buf.is_valid()
		or not route_mark_buf.is_valid()
		or not record_buf.is_valid()
		or not range_buf.is_valid()
		or not debug_buf.is_valid()
	):
		return _candidate_route_gpu_pack_blocked("candidate_route_gpu_%s_storage_buffer_failed" % ("expand" if use_expand else "pack"), asset_count, tile_grid, tile_count)

	var bindings := []
	if use_expand:
		bindings = [
			make_storage_uniform(0, tile_summaries_rid),
			make_storage_uniform(1, voxel_sparse_votes_buf),
			make_storage_uniform(2, route_radius_buf),
			make_storage_uniform(3, route_mark_buf),
			make_storage_uniform(4, record_buf),
			make_storage_uniform(5, range_buf),
			make_storage_uniform(6, debug_buf),
		]
	else:
		bindings = [
			make_storage_uniform(0, voxel_sparse_votes_buf),
			make_storage_uniform(1, route_radius_buf),
			make_storage_uniform(2, route_mark_buf),
			make_storage_uniform(3, record_buf),
			make_storage_uniform(4, range_buf),
			make_storage_uniform(5, debug_buf),
		]
	var set0 := create_uniform_set(bindings, shader_rid, 0, SCOPE_PASS, "candidate_route_gpu_%s" % ("expand" if use_expand else "pack"))
	if not set0.is_valid():
		return _candidate_route_gpu_pack_blocked("candidate_route_gpu_%s_uniform_set_failed" % ("expand" if use_expand else "pack"), asset_count, tile_grid, tile_count)

	var push := PackedByteArray()
	if use_expand:
		# Expand shader uses more push constants
		push.resize(48)
		push.encode_s32(0, tile_grid.x)
		push.encode_s32(4, tile_grid.y)
		push.encode_s32(8, tile_grid.z)
		push.encode_s32(12, asset_count)
		push.encode_u32(16, tile_count)
		push.encode_u32(20, record_capacity)
		push.encode_u32(24, SCENE_VOXEL_TILE_SUMMARY_STRIDE_UINTS)
		push.encode_float(28, 0.0001)
		push.encode_u32(32, 0)
	else:
		# Pack shader uses exactly 32 bytes
		push.resize(32)
		push.encode_s32(0, tile_grid.x)
		push.encode_s32(4, tile_grid.y)
		push.encode_s32(8, tile_grid.z)
		push.encode_s32(12, asset_count)
		push.encode_u32(16, tile_count)
		push.encode_u32(20, record_capacity)
		push.encode_float(24, 0.0001)
		push.encode_u32(28, 0)

	var cl := begin_compute_list()
	if cl < 0:
		return _candidate_route_gpu_pack_blocked("candidate_route_gpu_%s_compute_list_begin_failed" % ("expand" if use_expand else "pack"), asset_count, tile_grid, tile_count)
	_rd.compute_list_bind_compute_pipeline(cl, pipeline_rid)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	end_compute_list()
	submit_and_sync(true)

	# ═══════════════════════════════════════════════════════════════════
	# GPU-First path (expand shader with tile_summaries_rid):
	#   Count buffer is NOT read back on CPU. Resident record/range
	#   buffers are handed directly to the VPG adapter chain.
	#   CPU debug readback is only performed when explicitly requested.
	# ═══════════════════════════════════════════════════════════════════
	var record_count := 0
	var positive_vote_count := 0
	var duplicate_tile_id_count := 0
	var overflow_count := 0
	var skipped_empty_tiles := 0
	var record_bytes := PackedByteArray()
	var range_bytes := PackedByteArray()
	var per_asset_record_counts: Array[int] = []
	var empty_range_count := -1
	var readback_derived := false

	if debug_readback_bytes:
		var count_bytes := _rd.buffer_get_data(debug_buf, 0, 16)
		if count_bytes.size() >= 16:
			record_count = clampi(int(count_bytes.decode_u32(0)), 0, record_capacity)
			positive_vote_count = int(count_bytes.decode_u32(4))
			duplicate_tile_id_count = int(count_bytes.decode_u32(8))
			overflow_count = int(count_bytes.decode_u32(12))
		if use_expand and debug_readback_bytes:
			var debug_count_bytes := _rd.buffer_get_data(debug_buf, 0, 64)
			if debug_count_bytes.size() >= 40:
				skipped_empty_tiles = int(debug_count_bytes.decode_u32(36))
		if debug_readback_bytes and record_count > 0:
			record_bytes = _rd.buffer_get_data(record_buf, 0, record_count * CANDIDATE_ROUTE_RECORD_STRIDE_BYTES)
		if debug_readback_bytes:
			range_bytes = _rd.buffer_get_data(range_buf, 0, asset_count * CANDIDATE_ROUTE_RANGE_STRIDE_BYTES)
			if range_bytes.size() >= asset_count * CANDIDATE_ROUTE_RANGE_STRIDE_BYTES:
				empty_range_count = 0
				for asset_index in range(asset_count):
					var range_offset := asset_index * CANDIDATE_ROUTE_RANGE_STRIDE_BYTES
					var rc := int(range_bytes.decode_u32(range_offset + 4))
					per_asset_record_counts.append(rc)
					if rc <= 0:
						empty_range_count += 1
		readback_derived = true
	else:
		# GPU-First: no CPU count readback (unless expand)
		if use_expand:
			# Expand shader doesn't need readback either if no debug requested
			readback_derived = false
		else:
			# Pack shader: still read count for safety, but don't mark readback_derived
			var count_bytes := _rd.buffer_get_data(debug_buf, 0, 16)
			if count_bytes.size() >= 16:
				record_count = clampi(int(count_bytes.decode_u32(0)), 0, record_capacity)
				positive_vote_count = int(count_bytes.decode_u32(4))
				duplicate_tile_id_count = int(count_bytes.decode_u32(8))
				overflow_count = int(count_bytes.decode_u32(12))
			readback_derived = false

	_candidate_route_gpu_pack_record_buf = record_buf
	_candidate_route_gpu_pack_range_buf = range_buf

	var source_label := CANDIDATE_ROUTE_GPU_PACK_SOURCE_LABEL
	var producer_pack_pass := CANDIDATE_ROUTE_GPU_PACK_PASS
	if use_expand:
		source_label = "gpu_vote_buffer_gpu_expand"
		producer_pack_pass = CANDIDATE_ROUTE_GPU_EXPAND_PASS

	return {
		"ok": true,
		"reason": "ok",
		"source": source_label,
		"source_label": source_label,
		"pack_input_source": "gpu_dense_vote_buffer",
		"producer_pack_pass": producer_pack_pass,
		"producer": "AutoObjectProbePrefilterGPU",
		"record_layout": "uvec4(tile_id, 0, 0, 0)",
		"range_layout": "uvec4(record_start, record_count, 0, 0)",
		"record_order": "asset_range_tile_id_ascending",
		"score_order_preserved": false,
		"ordering_contract": "candidate_set_equivalent_not_score_sorted",
		"schema_version": CANDIDATE_ROUTE_SCHEMA_VERSION,
		"resident_route_schema_version": CANDIDATE_ROUTE_SCHEMA_VERSION,
		"record_stride_bytes": CANDIDATE_ROUTE_RECORD_STRIDE_BYTES,
		"range_stride_bytes": CANDIDATE_ROUTE_RANGE_STRIDE_BYTES,
		"resident_route_record_stride_bytes": CANDIDATE_ROUTE_RECORD_STRIDE_BYTES,
		"resident_route_range_stride_bytes": CANDIDATE_ROUTE_RANGE_STRIDE_BYTES,
		"resident_route_record_rid": record_buf,
		"resident_route_range_rid": range_buf,
		"resident_route_record_rid_valid": record_buf.is_valid(),
		"resident_route_range_rid_valid": range_buf.is_valid(),
		"resident_route_record_capacity": record_capacity,
		"resident_route_record_count": record_count,
		"resident_route_range_count": asset_count,
		"resident_route_buffer_owner": "AutoObjectProbePrefilterGPU",
		"resident_route_owner": "AutoObjectProbePrefilterGPU",
		"resident_route_producer": "AutoObjectProbePrefilterGPU",
		"resident_route_source_label": source_label,
		"resident_route_buffer_lifetime": "AutoObjectProbePrefilterGPU owned until next route pack, dispose, or explicit release",
		"same_rendering_device_as_vpg": true,
		"rendering_device_matches_vpg": true,
		"record_count": record_count,
		"range_count": asset_count,
		"asset_count": asset_count,
		"tile_count": tile_count,
		"tile_grid": tile_grid,
		"record_bytes": record_bytes,
		"range_bytes": range_bytes,
		"has_records": record_count > 0 or not readback_derived,
		"blocked": false,
		"status": "gpu_%s_resident" % ("expand" if use_expand else "pack"),
		"debug_status": "gpu_route_%s_debug_bytes_read_back" % ("expand" if use_expand else "pack") if debug_readback_bytes else "gpu_route_%s_resident_no_record_range_readback" % ("expand" if use_expand else "pack"),
		"readback_derived": readback_derived,
		"debug_readback_derived": debug_readback_bytes,
		"resident_route_input_ready": true,
		"resident_candidate_route_handoff": true,
		"gpu_route_pack": true,
		"gpu_route_expand": use_expand,
		"gpu_route_pack_requested": true,
		"gpu_route_pack_used": true,
		"gpu_candidate_route_pack": true,
		"cpu_expanded_route_input": false,
		"positive_vote_count": positive_vote_count,
		"duplicate_tile_id_count": duplicate_tile_id_count,
		"invalid_tile_id_count": 0,
		"empty_range_count": empty_range_count,
		"overflow_count": overflow_count,
		"skipped_empty_tiles": skipped_empty_tiles,
		"per_asset_record_counts": per_asset_record_counts,
		"record_capacity": record_capacity,
	}


func _release_candidate_route_gpu_pack_payload_buffers() -> void:
	gc_scope(SCOPE_PASS)
	if _candidate_route_gpu_pack_record_buf.is_valid():
		release_rid(_candidate_route_gpu_pack_record_buf)
	if _candidate_route_gpu_pack_range_buf.is_valid():
		release_rid(_candidate_route_gpu_pack_range_buf)
	_candidate_route_gpu_pack_record_buf = RID()
	_candidate_route_gpu_pack_range_buf = RID()


func _candidate_route_gpu_pack_blocked(
	reason: String,
	asset_count: int,
	tile_grid: Vector3i,
	tile_count: int
) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"source": "none",
		"source_label": "none",
		"pack_input_source": "gpu_dense_vote_buffer",
		"producer_pack_pass": CANDIDATE_ROUTE_GPU_PACK_PASS,
		"record_order": "none",
		"score_order_preserved": false,
		"ordering_contract": "blocked",
		"schema_version": CANDIDATE_ROUTE_SCHEMA_VERSION,
		"record_stride_bytes": CANDIDATE_ROUTE_RECORD_STRIDE_BYTES,
		"range_stride_bytes": CANDIDATE_ROUTE_RANGE_STRIDE_BYTES,
		"record_count": 0,
		"range_count": maxi(asset_count, 0),
		"asset_count": maxi(asset_count, 0),
		"tile_count": maxi(tile_count, 0),
		"tile_grid": tile_grid,
		"record_bytes": PackedByteArray(),
		"range_bytes": PackedByteArray(),
		"has_records": false,
		"readback_derived": false,
		"debug_readback_derived": false,
		"gpu_route_pack": false,
		"gpu_candidate_route_pack": true,
		"blocked": true,
	}


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
	pipeline_status: Dictionary = {},
	target_read_buffer_summary: Dictionary = {},
	gpu_route_pack_payload: Dictionary = {},
	cpu_route_debug_readback_requested: bool = false
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

	# Decode voxel-region votes - DEPRECATED CPU PATH (P0 #4): GPU route pack is now default.
	# This O(asset×tile) CPU path is preserved as a debug-only fallback. It runs when:
	#   1. GPU route pack failed (resident_route_payload_ready is false), or
	#   2. CPU debug readback is explicitly requested via target_read_buffers options.
	# To opt-out of GPU route pack per-call: set target_read_buffers.use_gpu_candidate_route_pack=false
	var autoobject_candidate_voxel_sparses: Dictionary = {}
	var candidate_route_vote_entries_by_asset: Dictionary = {}
	var resident_route_payload_ready := _candidate_route_payload_has_resident_rids(gpu_route_pack_payload)
	var decode_cpu_route_debug := not resident_route_payload_ready or cpu_route_debug_readback_requested
	var expected_vote_count := asset_count * tile_count
	var available_vote_bytes := mini(votes_bytes.size(), expected_vote_count * 4)
	available_vote_bytes -= available_vote_bytes % 4
	var available_vote_count := int(available_vote_bytes / 4)

	# --- DEPRECATED CPU vote-decode path (P0 #4: GPU route pack is default) ---
	# Only reached when GPU route pack failed or debug readback was explicitly requested.
	# O(asset_count × tile_count) CPU iteration; preserved as debug-only fallback.
	if decode_cpu_route_debug:
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
			candidate_route_vote_entries_by_asset[asset_id] = entries
			autoobject_candidate_voxel_sparses[asset_id] = voxel_sparses

	var route_debug := _route_profile_debug(route_profiles, asset_count)
	var readiness := pipeline_status.duplicate(true) if not pipeline_status.is_empty() else _pipeline_readiness()
	var cpu_route_handoff_payload := {}
	if decode_cpu_route_debug:
		cpu_route_handoff_payload = build_candidate_route_handoff_payload_from_vote_entries(
			candidate_route_vote_entries_by_asset,
			route_profiles,
			asset_count,
			tile_grid,
			tile_count
		)
	var route_handoff_payload := _select_candidate_route_handoff_payload(
		gpu_route_pack_payload,
		cpu_route_handoff_payload
	)
	var route_has_resident_rids := _candidate_route_payload_has_resident_rids(route_handoff_payload)
	var route_contract := VoxelPlacementGeneratorScript._candidate_route_input_contract_from_settings({
		"candidate_route_input_contract": route_handoff_payload,
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "resident",
	} if route_has_resident_rids else {
		"candidate_voxel_regions_by_asset": autoobject_candidate_voxel_sparses,
		"candidate_route_readback_source": "gpu_vote_buffer_readback",
		"candidate_route_runtime_read_source": "cpu_debug_bridge",
	})
	return {
		"ok": true,
		"anchors": anchors,                                           # position-only anchor readback
		"anchor_autoobject_topk": {},                                  # GPU internal, not read back
		"autoobject_candidate_voxel_sparses": autoobject_candidate_voxel_sparses, # per-asset regions
		"candidate_voxel_regions_by_asset": autoobject_candidate_voxel_sparses,
		"candidate_voxel_sparses_by_asset": autoobject_candidate_voxel_sparses,
		"candidate_route_profiles": route_debug,                       # route expansion debug
		"candidate_route_readback_source": "resident_route_snapshot" if route_has_resident_rids else "gpu_vote_buffer_readback",
		"candidate_route_runtime_read_source": "resident" if route_has_resident_rids else "cpu_debug_bridge",
		"candidate_route_input_contract": route_contract,
		"candidate_route_handoff_payload": route_handoff_payload,
		"candidate_route_cpu_handoff_payload": cpu_route_handoff_payload,
		"candidate_route_cpu_debug_readback_requested": cpu_route_debug_readback_requested,
		"candidate_route_cpu_debug_readback_performed": decode_cpu_route_debug and not votes_bytes.is_empty(),
		"candidate_route_cpu_debug_source": "gpu_vote_buffer_readback" if decode_cpu_route_debug and not votes_bytes.is_empty() else "disabled",
		"candidate_route_gpu_pack_payload": gpu_route_pack_payload,
		"candidate_route_payload_source_label": str(route_handoff_payload.get("source_label", "none")),
		"candidate_route_payload_ordering_contract": str(route_handoff_payload.get("ordering_contract", "score_sorted_cpu_expansion")),
		"anchor_count": anchors.size(),                                # collected anchor count
		"profile_probe_pack": _profile_probe_pack_summary(probe_pack),  # GPU-first probe pack contract/debug
		"target_read_buffer_source": str(target_read_buffer_summary.get("target_read_buffer_source", "none")),
		"target_read_buffer_summary": target_read_buffer_summary.duplicate(true),
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
	var duplicate_tile_id_count := 0
	var invalid_tile_id_count := 0

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
	return _build_candidate_route_handoff_payload_from_tile_ids(
		per_asset_tile_ids,
		safe_asset_count,
		tile_grid,
		safe_tile_count,
		duplicate_tile_id_count,
		invalid_tile_id_count,
		"candidate_voxel_regions_by_asset_debug"
	)


static func build_candidate_route_handoff_payload_from_vote_entries(
	candidate_vote_entries_by_asset: Dictionary,
	route_profiles: Array,
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
	var duplicate_tile_id_count := 0
	var invalid_tile_id_count := 0

	for asset_index in range(safe_asset_count):
		var ids := PackedInt32Array()
		var raw_entries = _candidate_regions_for_asset(candidate_vote_entries_by_asset, asset_index)
		if valid_tile_space:
			if raw_entries is Array:
				var route_profile: Dictionary = route_profiles[asset_index] if asset_index < route_profiles.size() and route_profiles[asset_index] is Dictionary else _empty_route_profile(asset_index)
				var expanded := _expand_vote_entries_to_route_tile_ids(raw_entries as Array, route_profile, tile_grid, safe_tile_count)
				ids = expanded.get("tile_ids", PackedInt32Array())
				duplicate_tile_id_count += int(expanded.get("duplicate_tile_id_count", 0))
				invalid_tile_id_count += int(expanded.get("invalid_tile_id_count", 0))
			elif raw_entries != null:
				invalid_tile_id_count += 1
		else:
			invalid_tile_id_count += 1
		per_asset_tile_ids.append(ids)

	return _build_candidate_route_handoff_payload_from_tile_ids(
		per_asset_tile_ids,
		safe_asset_count,
		tile_grid,
		safe_tile_count,
		duplicate_tile_id_count,
		invalid_tile_id_count,
		"gpu_vote_buffer_readback_vote_entries"
	)


## Selects GPU route pack payload when available (default), falls back to CPU-packed payload.
## GPU route pack produces schema-v1 record/range buffers with resident RID handoff.
static func _select_candidate_route_handoff_payload(
	gpu_route_pack_payload: Dictionary,
	cpu_route_handoff_payload: Dictionary
) -> Dictionary:
	if bool(gpu_route_pack_payload.get("ok", false)):
		return gpu_route_pack_payload.duplicate(true)
	var payload := cpu_route_handoff_payload.duplicate(true)
	if not gpu_route_pack_payload.is_empty():
		payload["gpu_route_pack_requested"] = true
		payload["gpu_route_pack_used"] = false
		payload["gpu_route_pack_blocked_reason"] = str(gpu_route_pack_payload.get("reason", "gpu_route_pack_not_ready"))
	else:
		payload["gpu_route_pack_requested"] = false
		payload["gpu_route_pack_used"] = false
		payload["gpu_route_pack_blocked_reason"] = "not_requested"
	return payload


static func _candidate_route_payload_has_resident_rids(payload: Dictionary) -> bool:
	var raw_record = payload.get("resident_route_record_rid", RID())
	var raw_range = payload.get("resident_route_range_rid", RID())
	var record_rid: RID = raw_record if raw_record is RID else RID()
	var range_rid: RID = raw_range if raw_range is RID else RID()
	return bool(payload.get("ok", false)) and record_rid.is_valid() and range_rid.is_valid()


static func _result_has_resident_candidate_route_payload(result: Dictionary) -> bool:
	var raw_payload = result.get("candidate_route_handoff_payload", {})
	return raw_payload is Dictionary and _candidate_route_payload_has_resident_rids(raw_payload as Dictionary)


static func _build_candidate_route_handoff_payload_from_tile_ids(
	per_asset_tile_ids: Array,
	asset_count: int,
	tile_grid: Vector3i,
	tile_count: int,
	duplicate_tile_id_count: int,
	invalid_tile_id_count: int,
	pack_input_source: String
) -> Dictionary:
	var safe_asset_count := maxi(asset_count, 0)
	var safe_tile_count := tile_count
	if safe_tile_count < 0:
		safe_tile_count = tile_grid.x * tile_grid.y * tile_grid.z
	var valid_tile_space := tile_grid.x > 0 and tile_grid.y > 0 and tile_grid.z > 0 and safe_tile_count > 0

	var per_asset_record_counts: Array[int] = []
	var record_count := 0
	var empty_range_count := 0
	for asset_index in range(safe_asset_count):
		var ids := PackedInt32Array()
		if asset_index < per_asset_tile_ids.size() and per_asset_tile_ids[asset_index] is PackedInt32Array:
			ids = per_asset_tile_ids[asset_index]
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
		range_bytes.encode_u32(range_offset + 8, 0)
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
		"pack_input_source": pack_input_source,
		"record_layout": "uvec4(tile_id, 0, 0, 0)",
		"range_layout": "uvec4(record_start, record_count, 0, 0)",
		"producer_pack_pass": "cpu_vote_entry_route_pack",
		"record_order": "asset_range_score_desc_tile_id_ascending",
		"score_order_preserved": true,
		"ordering_contract": "score_sorted_cpu_expansion",
		"gpu_route_pack": false,
		"gpu_route_pack_requested": false,
		"gpu_route_pack_used": false,
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
		return _tile_pos_to_id(p, tile_grid)
	if region is Vector3:
		var v := region as Vector3
		var p := Vector3i(int(v.x), int(v.y), int(v.z))
		if not _tile_pos_in_bounds(p, tile_grid):
			return -1
		return _tile_pos_to_id(p, tile_grid)
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


func _load_shaders(load_route_pack: bool = false, load_route_expand: bool = false) -> void:
	_shader_collect = load_compute_shader("res://shaders/collect_sv_anchors.glsl")
	_shader_score = load_compute_shader("res://shaders/score_anchor_asset_probes.glsl")
	_shader_topk = load_compute_shader("res://shaders/select_anchor_topk.glsl")
	_shader_reduce = load_compute_shader("res://shaders/reduce_anchor_topk_to_voxel_regions.glsl")
	if load_route_pack:
		_shader_route_pack = load_compute_shader("res://shaders/pack_candidate_route_records_from_votes.glsl")
	if load_route_expand:
		_shader_route_expand = load_compute_shader("res://shaders/expand_scene_voxel_tile_routes.glsl")
	if _shader_collect.is_valid():
		_pipeline_collect = create_compute_pipeline(_shader_collect)
	if _shader_score.is_valid():
		_pipeline_score = create_compute_pipeline(_shader_score)
	if _shader_topk.is_valid():
		_pipeline_topk = create_compute_pipeline(_shader_topk)
	if _shader_reduce.is_valid():
		_pipeline_reduce = create_compute_pipeline(_shader_reduce)
	if _shader_route_pack.is_valid():
		_pipeline_route_pack = create_compute_pipeline(_shader_route_pack)
	if _shader_route_expand.is_valid():
		_pipeline_route_expand = create_compute_pipeline(_shader_route_expand)


func _pipeline_rids_ready(require_route_pack: bool = false, require_route_expand: bool = false) -> bool:
	var core_ready := (
		_shader_collect.is_valid() and _pipeline_collect.is_valid()
		and _shader_score.is_valid() and _pipeline_score.is_valid()
		and _shader_topk.is_valid() and _pipeline_topk.is_valid()
		and _shader_reduce.is_valid() and _pipeline_reduce.is_valid()
	)
	if not core_ready:
		return false
	if require_route_expand:
		return _shader_route_expand.is_valid() and _pipeline_route_expand.is_valid()
	if require_route_pack:
		return _shader_route_pack.is_valid() and _pipeline_route_pack.is_valid()
	return true


func _pipeline_readiness(route_pack_requested: bool = false, route_expand_requested: bool = false) -> Dictionary:
	var collect := _pipeline_pass_readiness(_shader_collect, _pipeline_collect)
	var score := _pipeline_pass_readiness(_shader_score, _pipeline_score)
	var topk := _pipeline_pass_readiness(_shader_topk, _pipeline_topk)
	var reduce := _pipeline_pass_readiness(_shader_reduce, _pipeline_reduce)
	var route_pack := _pipeline_pass_readiness(_shader_route_pack, _pipeline_route_pack)
	route_pack["requested"] = route_pack_requested
	var route_expand := _pipeline_pass_readiness(_shader_route_expand, _pipeline_route_expand)
	route_expand["requested"] = route_expand_requested
	var all_ready := bool(collect.get("ready", false)) \
		and bool(score.get("ready", false)) \
		and bool(topk.get("ready", false)) \
		and bool(reduce.get("ready", false))
	if route_expand_requested:
		all_ready = all_ready and bool(route_expand.get("ready", false))
	elif route_pack_requested:
		all_ready = all_ready and bool(route_pack.get("ready", false))
	return {
		"collect": collect,
		"score": score,
		"topk": topk,
		"reduce": reduce,
		"route_pack": route_pack,
		"route_expand": route_expand,
		"all_ready": all_ready,
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
	_pipeline_route_pack = RID()
	_pipeline_route_expand = RID()
	_shader_collect = RID()
	_shader_score = RID()
	_shader_topk = RID()
	_shader_reduce = RID()
	_shader_route_pack = RID()
	_shader_route_expand = RID()


func _on_after_dispose() -> void:
	_candidate_route_gpu_pack_record_buf = RID()
	_candidate_route_gpu_pack_range_buf = RID()


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
		"target_read_buffer_source": "none",
		"target_read_buffer_summary": _target_read_buffer_summary({}),
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
		or reason.begins_with("missing_probe_range_for_profile:") \
		or reason.begins_with("resident_target_read_buffer_") \
		or reason.begins_with("target_read_buffer_")


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


func _pack_complexity_collision_float_bytes(scene_data: PackedFloat32Array, collision_data: PackedFloat32Array, voxel_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(voxel_count * 8)
	for i in range(voxel_count):
		var sv := scene_data[i] if i < scene_data.size() else 0.0
		var cv := collision_data[i] if i < collision_data.size() else 0.0
		bytes.encode_float(i * 8, sv)
		bytes.encode_float(i * 8 + 4, cv)
	return bytes


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


## Returns true when GPU route pack is requested (default enabled per P0 #4).
## Per-call override: set target_read_buffers.use_gpu_candidate_route_pack=false to opt-out.
func _candidate_route_gpu_pack_requested(options: Dictionary = {}) -> bool:
	for key in [
		"use_gpu_candidate_route_pack",
		"use_producer_gpu_candidate_route_pack",
		"use_gpu_candidate_route_payload_pack",
		"gpu_candidate_route_pack",
	]:
		if options.has(key):
			return bool(options.get(key, false))
	return use_gpu_candidate_route_pack


## CPU debug readback of vote buffer bytes — only needed when GPU route pack is
## explicitly disabled or debug inspection of raw vote bytes is requested.
func _candidate_route_cpu_debug_readback_requested(options: Dictionary = {}) -> bool:
	for key in [
		"debug_read_candidate_route_cpu_handoff_payload",
		"debug_read_candidate_route_cpu_expansion",
		"read_candidate_route_cpu_debug",
		"read_candidate_route_vote_buffer_debug",
		"read_candidate_route_debug_bytes",
		"debug_readback_bytes",
	]:
		if options.has(key):
			return bool(options.get(key, false))
	return false


func _pack_route_profile_radius_bytes(route_profiles: Array, asset_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(asset_count, 1) * 16)
	for asset_index in range(maxi(asset_count, 0)):
		var route_profile: Dictionary = route_profiles[asset_index] if asset_index < route_profiles.size() and route_profiles[asset_index] is Dictionary else _empty_route_profile(asset_index)
		var radius := _vector3i_from_value(route_profile.get("tile_radius", Vector3i.ONE), Vector3i.ONE)
		radius = Vector3i(maxi(radius.x, 0), maxi(radius.y, 0), maxi(radius.z, 0))
		var base := asset_index * 16
		bytes.encode_u32(base + 0, radius.x)
		bytes.encode_u32(base + 4, radius.y)
		bytes.encode_u32(base + 8, radius.z)
		bytes.encode_u32(base + 12, 0)
	return bytes


func _target_read_buffer_pack(
	target_read_buffers: Dictionary,
	target_field_bytes: PackedFloat32Array,
	voxel_count: int
) -> Dictionary:
	var expected_floats := maxi(voxel_count, 1) * 4
	var borrowed := _borrowed_target_read_buffer_pack(target_read_buffers, expected_floats)
	if bool(borrowed.get("ready", false)):
		return borrowed

	var field_input: PackedFloat32Array = target_field_bytes
	var raw_field_from_pack = target_read_buffers.get("target_field_bytes", PackedFloat32Array())
	if field_input.is_empty() and raw_field_from_pack is PackedFloat32Array:
		field_input = raw_field_from_pack
	var upload_reason := str(borrowed.get("reason", "resident_handoff_absent"))
	if _target_read_buffers_claim_resident(target_read_buffers) and field_input.size() < expected_floats:
		return _blocked_target_read_buffer_pack(upload_reason, expected_floats, field_input.size())

	var field_data := _target_field_data(field_input, voxel_count)
	return {
		"ready": true,
		"target_read_buffer_source": "uploaded_target_bytes",
		"target_read_buffer_ownership": "prefilter_uploaded_owned",
		"target_read_buffer_lifetime": "AutoObjectProbePrefilterGPU frame scope",
		"target_read_buffers_borrowed": false,
		"target_read_buffers_uploaded": true,
		"target_field_buffer": RID(),
		"target_field_bytes": field_data,
		"target_field_byte_count": field_data.size() * 4,
		"expected_byte_count": expected_floats * 4,
		"target_field_format": "vec4",
		"target_field_stride_bytes": 16,
		"owner": "AutoObjectProbePrefilterGPU",
		"producer": "AutoObjectProbePrefilterGPU",
		"borrowed_from": "none",
		"source_reason": upload_reason,
		"rendering_device_match": false,
		"rid_valid": false,
		"gpu_first": true,
		"cpu_fallback": false,
	}


func _borrowed_target_read_buffer_pack(target_read_buffers: Dictionary, expected_floats: int) -> Dictionary:
	if target_read_buffers.is_empty():
		return {"ready": false, "reason": "resident_handoff_absent"}

	var summary: Dictionary = target_read_buffers.get("resident_target_read_buffer_handoff_summary", {})
	var raw_field = target_read_buffers.get(
		"target_field_buffer",
		target_read_buffers.get("resident_target_field_buffer", summary.get("target_field_buffer", RID()))
	)
	var field_buffer: RID = raw_field if raw_field is RID else RID()
	if not field_buffer.is_valid():
		return {"ready": false, "reason": "resident_target_read_buffer_rid_invalid"}

	var raw_source_rd = target_read_buffers.get("rendering_device", summary.get("rendering_device", null))
	var source_rd: RenderingDevice = raw_source_rd as RenderingDevice
	if source_rd == null or _rd == null or source_rd != _rd:
		return {"ready": false, "reason": "resident_target_read_buffer_rendering_device_mismatch"}

	var field_byte_count := int(target_read_buffers.get("expected_byte_count", summary.get("expected_byte_count", 0)))
	if field_byte_count != expected_floats * 4:
		return {"ready": false, "reason": "resident_target_read_buffer_byte_count_mismatch"}

	return {
		"ready": true,
		"target_read_buffer_source": "borrowed_scene_placement_actor_resident",
		"target_read_buffer_ownership": "borrowed_external",
		"target_read_buffer_lifetime": str(target_read_buffers.get("resident_target_read_buffer_lifetime", summary.get("target_read_buffer_lifetime", "ScenePlacementActor owned"))),
		"target_read_buffers_borrowed": true,
		"target_read_buffers_uploaded": false,
		"target_field_buffer": field_buffer,
		"target_field_bytes": PackedFloat32Array(),
		"target_field_byte_count": field_byte_count,
		"expected_byte_count": expected_floats * 4,
		"target_field_format": str(target_read_buffers.get("target_field_format", summary.get("target_field_format", "vec4"))),
		"target_field_stride_bytes": int(target_read_buffers.get("target_field_stride_bytes", summary.get("target_field_stride_bytes", 16))),
		"owner": str(target_read_buffers.get("resident_target_read_buffer_owner", summary.get("owner", "ScenePlacementActor"))),
		"producer": str(summary.get("producer", "ScenePlacementActorTargetReadBuffers")),
		"borrowed_from": "ScenePlacementActor",
		"source_reason": str(summary.get("reason", "ok")),
		"rendering_device_match": true,
		"rid_valid": true,
		"gpu_first": true,
		"cpu_fallback": false,
	}


func _target_read_buffers_claim_resident(target_read_buffers: Dictionary) -> bool:
	if target_read_buffers.is_empty():
		return false
	var summary: Dictionary = target_read_buffers.get("resident_target_read_buffer_handoff_summary", {})
	return bool(target_read_buffers.get(
		"resident_target_read_buffer_handoff",
		summary.get("resident_target_read_buffer_handoff", false)
	))


func _blocked_target_read_buffer_pack(
	borrow_reason: String,
	expected_floats: int,
	actual_floats: int
) -> Dictionary:
	var reason := "%s_no_debug_or_legacy_bytes" % borrow_reason
	return {
		"ready": false,
		"reason": reason,
		"target_read_buffer_source": "none",
		"target_read_buffer_ownership": "none",
		"target_read_buffer_lifetime": "none",
		"target_read_buffers_borrowed": false,
		"target_read_buffers_uploaded": false,
		"target_field_buffer": RID(),
		"target_field_bytes": PackedFloat32Array(),
		"target_field_byte_count": actual_floats * 4,
		"expected_byte_count": expected_floats * 4,
		"target_field_format": "vec4",
		"target_field_stride_bytes": 16,
		"owner": "none",
		"producer": "ScenePlacementActorTargetReadBuffers",
		"borrowed_from": "ScenePlacementActor",
		"source_reason": borrow_reason,
		"rendering_device_match": borrow_reason != "resident_target_read_buffer_rendering_device_mismatch",
		"rid_valid": false,
		"contract_blocked": true,
		"gpu_first": true,
		"cpu_fallback": false,
	}


func _target_read_buffer_summary(pack: Dictionary) -> Dictionary:
	var raw_field = pack.get("target_field_buffer", RID())
	var field_buffer: RID = raw_field if raw_field is RID else RID()
	return {
		"ready": bool(pack.get("ready", false)),
		"target_read_buffer_source": str(pack.get("target_read_buffer_source", "none")),
		"target_read_buffer_ownership": str(pack.get("target_read_buffer_ownership", "none")),
		"target_read_buffer_lifetime": str(pack.get("target_read_buffer_lifetime", "none")),
		"target_read_buffers_borrowed": bool(pack.get("target_read_buffers_borrowed", false)),
		"target_read_buffers_uploaded": bool(pack.get("target_read_buffers_uploaded", false)),
		"target_field_buffer_rid": "valid" if field_buffer.is_valid() else "none",
		"target_field_buffer_rid_valid": field_buffer.is_valid(),
		"target_field_byte_count": int(pack.get("target_field_byte_count", 0)),
		"expected_byte_count": int(pack.get("expected_byte_count", 0)),
		"target_field_format": str(pack.get("target_field_format", "none")),
		"target_field_stride_bytes": int(pack.get("target_field_stride_bytes", 0)),
		"owner": str(pack.get("owner", "none")),
		"producer": str(pack.get("producer", "none")),
		"borrowed_from": str(pack.get("borrowed_from", "none")),
		"source_reason": str(pack.get("source_reason", "none")),
		"rendering_device_match": bool(pack.get("rendering_device_match", false)),
		"contract_blocked": bool(pack.get("contract_blocked", false)),
		"gpu_first": true,
		"cpu_fallback": false,
	}


func _target_field_data(prepacked: PackedFloat32Array, voxel_count: int) -> PackedFloat32Array:
	var expected_floats := maxi(voxel_count, 1) * 4
	if prepacked.size() >= expected_floats:
		if prepacked.size() == expected_floats:
			return prepacked
		return prepacked.slice(0, expected_floats)
	var result := PackedFloat32Array()
	result.resize(expected_floats)
	return result


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
	var expanded := _expand_vote_entries_to_route_tile_ids(entries, route_profile, tile_grid)
	var tile_ids: PackedInt32Array = expanded.get("tile_ids", PackedInt32Array())
	var voxel_sparses: Array[Vector3i] = []
	for tile_id in tile_ids:
		voxel_sparses.append(_tile_id_to_pos(int(tile_id), tile_grid))
	return voxel_sparses


static func _expand_vote_entries_to_route_tile_ids(
	entries: Array,
	route_profile: Dictionary,
	tile_grid: Vector3i,
	tile_count: int = -1
) -> Dictionary:
	var tile_ids := PackedInt32Array()
	var safe_tile_count := tile_count
	if safe_tile_count < 0:
		safe_tile_count = tile_grid.x * tile_grid.y * tile_grid.z
	if tile_grid.x <= 0 or tile_grid.y <= 0 or tile_grid.z <= 0 or safe_tile_count <= 0:
		return {
			"tile_ids": tile_ids,
			"duplicate_tile_id_count": 0,
			"invalid_tile_id_count": entries.size(),
		}

	var radius := _vector3i_from_value(route_profile.get("tile_radius", Vector3i.ONE), Vector3i.ONE)
	radius = Vector3i(maxi(radius.x, 0), maxi(radius.y, 0), maxi(radius.z, 0))
	var scored_by_tile := {}
	var duplicate_tile_id_count := 0
	var invalid_tile_id_count := 0
	for raw_entry in entries:
		if not raw_entry is Dictionary:
			invalid_tile_id_count += 1
			continue
		var entry := raw_entry as Dictionary
		var center_id := _candidate_route_region_to_tile_id(entry, tile_grid)
		if center_id < 0 or center_id >= safe_tile_count:
			invalid_tile_id_count += 1
			continue
		var center := _tile_id_to_pos(center_id, tile_grid)
		if not _tile_pos_in_bounds(center, tile_grid):
			invalid_tile_id_count += 1
			continue
		var score := float(entry.get("score", 0.0))
		for dz in range(-radius.z, radius.z + 1):
			for dy in range(-radius.y, radius.y + 1):
				for dx in range(-radius.x, radius.x + 1):
					var p := Vector3i(center.x + dx, center.y + dy, center.z + dz)
					if not _tile_pos_in_bounds(p, tile_grid):
						continue
					var tid := _tile_pos_to_id(p, tile_grid)
					if tid < 0 or tid >= safe_tile_count:
						invalid_tile_id_count += 1
						continue
					if scored_by_tile.has(tid):
						duplicate_tile_id_count += 1
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
	for entry in expanded_entries:
		tile_ids.append(int(entry.get("tile_id", 0)))
	return {
		"tile_ids": tile_ids,
		"duplicate_tile_id_count": duplicate_tile_id_count,
		"invalid_tile_id_count": invalid_tile_id_count,
	}


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
