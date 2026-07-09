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
##   5. pack_candidate_route_records_from_votes — dense votes → schema-v1 record/range bytes (always enabled)
##
## The candidate route pack always runs on GPU; there is no CPU vote-decoding
## fallback. Target read buffers must be a resident GPU handoff — when the
## resident buffer cannot be borrowed the prefilter raises an error (push_error)
## and returns a blocked result instead of uploading CPU bytes.

const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const RuntimeProfileContainerScript := preload("res://scripts/auto_voxel_runtime_profile_container.gd")
const VoxelPlacementGeneratorScript := preload("res://scripts/voxel_placement_generator.gd")
const AssetDescriptorScript := preload("res://scripts/asset_descriptor.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")

const TILE_SIZE := 8
const MAX_ASSETS := 256
const TOPK := 4
const ANCHOR_CAPACITY := 65536
## Fixed anchor grid width for score/top-K dispatch. Kept constant (not derived from
## the anchor count) so the GPU finalize pass and the shaders agree on the anchor_id
## decode without a CPU/GPU formula. 256 * 256 == ANCHOR_CAPACITY, so it always covers
## the full capacity; only group_count_y scales with the actual anchor count.
const ANCHOR_GRID_X := 256
const SCORE_ASSET_LANES := 16
const PREFILTER_DISPATCH_AXIS_LIMIT := 65535
const EMPTY_ASSET_ID := 0xffffffff
const CandidateRouteSchemaScript := preload("res://scripts/candidate_route_schema.gd")
const CANDIDATE_ROUTE_SCHEMA_VERSION := CandidateRouteSchemaScript.SCHEMA_VERSION
const CANDIDATE_ROUTE_RECORD_STRIDE_BYTES := CandidateRouteSchemaScript.RECORD_STRIDE_BYTES
const CANDIDATE_ROUTE_RANGE_STRIDE_BYTES := CandidateRouteSchemaScript.RANGE_STRIDE_BYTES
const CANDIDATE_ROUTE_GPU_PACK_SOURCE_LABEL := "gpu_vote_buffer_gpu_pack"
const CANDIDATE_ROUTE_GPU_PACK_PASS := "pack_candidate_route_records_from_votes"
const CANDIDATE_ROUTE_GPU_EXPAND_PASS := "expand_scene_voxel_tile_routes"
const SCENE_VOXEL_TILE_SUMMARY_STRIDE_UINTS := 8  ## 32 bytes per summary / 4 bytes per uint

# ---------------------------------------------------------------------------
# Push-constant layout schemas (std430). Each field maps 1:1 to the original
# manual push.encode_* sequence, in order; trailing unused/zero slots are _pad.
# ---------------------------------------------------------------------------
const COLLECT_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["dirty_count", "int"],
	["tile_grid_x", "int"], ["tile_grid_y", "int"], ["tile_grid_z", "int"], ["anchor_capacity", "int"],
	["max_complexity", "float"], ["max_collision", "float"], ["min_support", "float"], ["min_target_interest", "float"],
	["collect_groups_x", "int"], ["collect_groups_y", "int"], ["_pad0", "int"], ["_pad1", "int"],
]
const ANCHOR_FINALIZE_PUSH := [
	["anchor_grid_x", "uint"], ["asset_blocks", "uint"], ["anchor_capacity", "uint"], ["_pad0", "uint"],
]
const SCORE_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["asset_count", "int"],
	["inv_voxel_x", "float"], ["inv_voxel_y", "float"], ["inv_voxel_z", "float"], ["_pad0", "float"],
	["_pad1", "uint"], ["anchor_grid_x", "uint"], ["min_prefilter_score", "float"], ["_pad2", "float"],
]
const TOPK_PUSH := [
	["_pad0", "uint"], ["asset_count", "uint"], ["anchor_grid_x", "uint"], ["min_prefilter_score", "float"],
]
const REDUCE_PUSH := [
	["tile_grid_x", "int"], ["tile_grid_y", "int"], ["tile_grid_z", "int"], ["tile_count", "int"],
	["_pad0", "uint"], ["asset_count", "uint"], ["topk", "uint"], ["_pad1", "uint"],
]
const ROUTE_EXPAND_PUSH := [
	["tile_grid_x", "int"], ["tile_grid_y", "int"], ["tile_grid_z", "int"], ["asset_count", "int"],
	["tile_count", "uint"], ["record_capacity", "uint"], ["summary_stride_uints", "uint"], ["epsilon", "float"],
	["_pad0", "uint"],
]
const ROUTE_PACK_PUSH := [
	["tile_grid_x", "int"], ["tile_grid_y", "int"], ["tile_grid_z", "int"], ["asset_count", "int"],
	["tile_count", "uint"], ["record_capacity", "uint"], ["epsilon", "float"], ["_pad0", "uint"],
]
const FIELD_PAIR_PUSH := [
	["voxel_count", "int"], ["_pad0", "int"], ["_pad1", "int"], ["_pad2", "int"],
]

var anchor_topk: int = 4                    # per-anchor asset top-K target
var max_complexity_field: float = 0.15           # anchor allowed scene occupancy threshold
var max_collision_field: float = 0.05       # anchor allowed collision threshold
var min_support: float = 0.25               # required support below anchor
var min_target_interest: float = 0.01       # minimum TargetSV_B demand
var min_prefilter_score: float = 0.35       # minimum probe score accepted by shader
var interpolation_guard_voxels: int = 1     # route expansion guard, at least 1 voxel
## Opt-in only: CPU readback of the anchor position array into result["anchors"].
## The anchors array is purely for debug/visualization (the resident GPU route buffers
## drive placement); off by default so the routing path stays GPU-first.
var debug_read_anchors: bool = false

# Shaders & pipelines
var _shader_collect: RID
var _shader_anchor_finalize: RID
var _shader_score: RID
var _shader_topk: RID
var _shader_reduce: RID
var _shader_route_pack: RID
var _shader_route_expand: RID
var _pipeline_collect: RID
var _pipeline_anchor_finalize: RID
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

## 执行 GPU 探针预过滤主入口，返回包含候选路由和锚点信息的结果字典。
## 目标场只接受 target_read_buffers 中的常驻 GPU 交接（无 CPU 字节上传）。
func run_probe_prefilter(
	sv: Dictionary,
	autoobjects: Array,
	dirty_tile_ids: Array[int] = [],
	runtime_profile_container: Object = null,
	target_read_buffers: Dictionary = {},
	tile_summaries_rid: RID = RID()
) -> Dictionary:
	if sv.is_empty():
		return _empty_result("empty_sv")
	var voxel_sparse_ids := dirty_tile_ids.duplicate()
	if voxel_sparse_ids.is_empty():
		voxel_sparse_ids = _dirty_tile_ids_from_sv(sv)
	if voxel_sparse_ids.is_empty():
		voxel_sparse_ids = all_tile_ids(sv)
	if voxel_sparse_ids.is_empty():
		return _empty_result("no_voxel_regions")

	log_name = "AutoObjectProbePrefilterGPU"
	sync_global_device = true
	if runtime_profile_container != null:
		if not _attach_runtime_profile_container_device(runtime_profile_container):
			return _empty_result("auto_voxel_runtime_profile_container_not_ready")
	elif not ensure_device(true, true):
		return _empty_result("missing_rendering_device")

	var use_expand_shader := tile_summaries_rid.is_valid()
	_load_shaders(use_expand_shader)
	if not _pipeline_rids_ready(use_expand_shader):
		var pipeline_status := _pipeline_readiness(use_expand_shader)
		var blocked_result := _empty_result("prefilter_shader_pipeline_not_ready", {}, pipeline_status)
		_free_gpu()
		return blocked_result

	var result := _run_gpu_pipeline(sv, autoobjects, voxel_sparse_ids, runtime_profile_container, target_read_buffers, tile_summaries_rid)
	if _result_has_resident_candidate_route_payload(result):
		gc_frame()
	else:
		_free_gpu()
	return result


# ---------------------------------------------------------------------------
# GPU pipeline
# ---------------------------------------------------------------------------

## 执行完整的 GPU 计算管线（收集锚点→评分→Top-K→聚合→路由打包），返回解码后的结果字典。
func _run_gpu_pipeline(
	sv: Dictionary,
	autoobjects: Array,
	tile_ids: Array[int],
	runtime_profile_container: Object = null,
	target_read_buffers: Dictionary = {},
	tile_summaries_rid: RID = RID()
) -> Dictionary:
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var voxel_size: Vector3 = sv.get("voxel_size", Vector3.ONE)
	var voxel_count: int = VoxelGeneral.voxel_count(grid_size)
	var tile_grid := Vector3i(
		_ceil_div_positive(grid_size.x, TILE_SIZE),
		_ceil_div_positive(grid_size.y, TILE_SIZE),
		_ceil_div_positive(grid_size.z, TILE_SIZE)
	)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	var safe_tile_ids := _sanitize_prefilter_tile_ids(tile_ids, tile_count)
	if safe_tile_ids.is_empty():
		var pipeline_status := _pipeline_readiness(tile_summaries_rid.is_valid())
		return _empty_result("no_valid_voxel_regions", {}, pipeline_status)

	# ---- Normalize GPU buffer inputs ----

	var use_expand_shader := tile_summaries_rid.is_valid()
	var target_buffer_pack := _target_read_buffer_pack(target_read_buffers, voxel_count)
	if not bool(target_buffer_pack.get("ready", false)):
		var blocked_reason := str(target_buffer_pack.get("reason", "target_read_buffer_not_ready"))
		var blocked_result := _empty_result(blocked_reason, {}, _pipeline_readiness(use_expand_shader))
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

	var complexity_collision_buf := _make_complexity_collision_buffer(sv, voxel_count)
	if not complexity_collision_buf.is_valid():
		var field_pipeline_status := _pipeline_readiness(use_expand_shader)
		_free_gpu()
		return _empty_result("complexity_collision_field_buffer_not_ready", probe_pack, field_pipeline_status)
	# Target read buffers must be a resident GPU handoff (borrowed); the CPU
	# upload fallback was removed, so _target_read_buffer_pack only reaches here
	# with a valid borrowed RID.
	var target_field_buf: RID = target_buffer_pack.get("target_field_buffer", RID())
	track_borrowed_rid(target_field_buf, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_field")
	var dirty_tile_buf := storage_buffer_from_bytes(_pack_u32_array_from_int(safe_tile_ids))
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

	if not _dispatch_collect(
		complexity_collision_buf, target_field_buf, dirty_tile_buf,
		anchor_buf, anchor_count_buf,
		grid_size, tile_grid, safe_tile_ids.size()
	):
		var pipeline_status := _pipeline_readiness(use_expand_shader)
		_free_gpu()
		return _empty_result("collect_anchor_dispatch_bounds_exceeded", probe_pack, pipeline_status)

	# GPU-first: anchor_count stays on the GPU. The finalize pass inside
	# _dispatch_score_topk_reduce turns it into indirect dispatch args, so the host
	# never reads it back. Zero anchors -> zero score/top-K groups -> empty routes
	# flow through the rest of the pipeline naturally (no CPU early-out / sync here).

	# ---- Dispatch 2-4: Score probes -> Top-K selection -> Voxel-region reduction ----

	if not _dispatch_score_topk_reduce(
		anchor_buf, anchor_count_buf, probe_range_buf, probe_data_buf,
		complexity_collision_buf, target_field_buf,
		asset_scores_buf, topk_buf, voxel_sparse_votes_buf,
		grid_size, voxel_size,
		tile_grid, tile_count, asset_count
	):
		var pipeline_status := _pipeline_readiness(use_expand_shader)
		_free_gpu()
		return _empty_result("score_topk_reduce_compute_list_begin_failed", probe_pack, pipeline_status)

	var gpu_route_pack_payload := _run_candidate_route_gpu_pack_pass(
		voxel_sparse_votes_buf,
		probe_pack.get("route_profiles", []),
		tile_grid,
		tile_count,
		asset_count,
		tile_summaries_rid
	)
	if not bool(gpu_route_pack_payload.get("ok", false)):
		submit_and_sync(true)

	# ---- Read back results ----

	# Anchor position array + count readback is debug-only (result["anchors"]
	# visualization). Off by default so the routing path stays fully GPU-first; the
	# route pack pass has already submit_and_sync'd by the time we get here.
	var actual_anchor_count := 0
	var anchors_bytes := PackedByteArray()
	if debug_read_anchors:
		var anchor_count_bytes := _rd.buffer_get_data(anchor_count_buf, 0, 4)
		actual_anchor_count = mini(BufferUtils.decode_u32_count(anchor_count_bytes), ANCHOR_CAPACITY)
		anchors_bytes = _rd.buffer_get_data(anchor_buf, 0, actual_anchor_count * 16)
	var resident_route_payload_ready := _candidate_route_payload_has_resident_rids(gpu_route_pack_payload)
	var pipeline_status := _pipeline_readiness(use_expand_shader)

	if resident_route_payload_ready:
		gc_frame()
	else:
		_free_gpu()

	return _decode_results(
		anchors_bytes,
		actual_anchor_count,
		asset_count,
		tile_count,
		sv,
		tile_grid,
		probe_pack.get("route_profiles", []),
		probe_pack,
		pipeline_status,
		_target_read_buffer_summary(target_buffer_pack),
		gpu_route_pack_payload
	)


# ---------------------------------------------------------------------------
# Dispatch helpers
# ---------------------------------------------------------------------------

## 调度 Pass 1：在脏 Tile 内收集满足阈值的 SV 锚点体素，写入 anchor_buf。
func _dispatch_collect(
	complexity_collision_buf: RID, target_field_buf: RID,
	dirty_tile_buf: RID, anchor_buf: RID, anchor_count_buf: RID,
	grid_size: Vector3i, tile_grid: Vector3i, dirty_count: int
) -> bool:
	var collect_groups := _linear_dispatch_groups(dirty_count)
	if collect_groups == Vector3i.ZERO:
		push_error("[AutoObjectProbePrefilterGPU] Collect anchors dispatch count is out of bounds")
		return false
	var set0 := create_uniform_set([
		make_storage_uniform(0, complexity_collision_buf),
		make_storage_uniform(1, target_field_buf),
		make_storage_uniform(2, dirty_tile_buf),
		make_storage_uniform(3, anchor_buf),
		make_storage_uniform(4, anchor_count_buf),
	], _shader_collect, 0)

	var push := PushConstantLayout.new(COLLECT_PUSH).pack({
		grid_x = grid_size.x,
		grid_y = grid_size.y,
		grid_z = grid_size.z,
		dirty_count = dirty_count,
		tile_grid_x = tile_grid.x,
		tile_grid_y = tile_grid.y,
		tile_grid_z = tile_grid.z,
		anchor_capacity = ANCHOR_CAPACITY,
		max_complexity = max_complexity_field,
		max_collision = max_collision_field,
		min_support = min_support,
		min_target_interest = min_target_interest,
		collect_groups_x = collect_groups.x,
		collect_groups_y = collect_groups.y,
	})

	var cl := begin_compute_list()
	if cl < 0:
		push_error("[AutoObjectProbePrefilterGPU] Collect anchors compute list begin failed")
		return false
	_gpu_dispatch_pipeline_sets(cl, _pipeline_collect, [set0], push, collect_groups)
	end_compute_list()
	return true


## GPU-first：先用 finalize pass 把 GPU 端 anchor_count 转成 score/top-K 的间接 dispatch
## 参数（anchor_count 全程不回读 CPU），再以间接 dispatch 连续调度评分→Top-K→聚合。
## anchor_count==0 时 finalize 写出 0 组 → score/top-K 天然空跑，无需 CPU early-out。
func _dispatch_score_topk_reduce(
	anchor_buf: RID, anchor_count_buf: RID, probe_range_buf: RID,
	probe_data_buf: RID, complexity_collision_buf: RID,
	target_field_buf: RID, asset_scores_buf: RID,
	topk_buf: RID, voxel_sparse_votes_buf: RID,
	grid_size: Vector3i, voxel_size: Vector3,
	tile_grid: Vector3i, tile_count: int,
	asset_count: int
) -> bool:
	var safe_asset_count := clampi(asset_count, 0, MAX_ASSETS)
	var asset_blocks := _score_asset_block_dispatch_groups(safe_asset_count)
	if asset_blocks <= 0:
		push_error("[AutoObjectProbePrefilterGPU] Score/Top-K asset block dispatch count is out of bounds")
		return false
	if not _rd.has_method("compute_list_dispatch_indirect"):
		push_error("[AutoObjectProbePrefilterGPU] RenderingDevice lacks compute_list_dispatch_indirect")
		return false
	var anchor_grid_x := ANCHOR_GRID_X

	# ---- GPU finalize: anchor_count -> indirect dispatch args (no CPU readback) ----
	var score_indirect_args_buf := dispatch_indirect_args_buffer_zero(SCOPE_FRAME, "prefilter_score_indirect_args")
	var topk_indirect_args_buf := dispatch_indirect_args_buffer_zero(SCOPE_FRAME, "prefilter_topk_indirect_args")
	if not score_indirect_args_buf.is_valid() or not topk_indirect_args_buf.is_valid():
		push_error("[AutoObjectProbePrefilterGPU] Failed to allocate anchor indirect args buffers")
		return false
	var finalize_set0 := create_uniform_set([
		make_storage_uniform(0, anchor_count_buf),
		make_storage_uniform(1, score_indirect_args_buf),
		make_storage_uniform(2, topk_indirect_args_buf),
	], _shader_anchor_finalize, 0, SCOPE_PASS, "prefilter_anchor_dispatch_finalize")
	if not finalize_set0.is_valid():
		push_error("[AutoObjectProbePrefilterGPU] Anchor finalize uniform set create failed")
		return false
	var finalize_push := PushConstantLayout.new(ANCHOR_FINALIZE_PUSH).pack({
		anchor_grid_x = anchor_grid_x,
		asset_blocks = asset_blocks,
		anchor_capacity = ANCHOR_CAPACITY,
	})
	var fcl := begin_compute_list()
	if fcl < 0:
		push_error("[AutoObjectProbePrefilterGPU] Anchor finalize compute list begin failed")
		return false
	_gpu_dispatch_pipeline_sets(fcl, _pipeline_anchor_finalize, [finalize_set0], finalize_push, Vector3i(1, 1, 1))
	end_compute_list()

	# ---- Score -> Top-K -> Reduce (score/top-K via indirect dispatch) ----
	var score_set0 := create_uniform_set([
		make_storage_uniform(0, anchor_buf),
		make_storage_uniform(1, probe_range_buf),
		make_storage_uniform(2, probe_data_buf),
		make_storage_uniform(3, complexity_collision_buf),
		make_storage_uniform(4, target_field_buf),
		make_storage_uniform(5, asset_scores_buf),
		make_storage_uniform(6, anchor_count_buf),
	], _shader_score, 0)

	var topk_set0 := create_uniform_set([
		make_storage_uniform(0, asset_scores_buf),
		make_storage_uniform(1, topk_buf),
		make_storage_uniform(2, anchor_count_buf),
	], _shader_topk, 0)

	var reduce_set0 := create_uniform_set([
		make_storage_uniform(0, anchor_buf),
		make_storage_uniform(1, topk_buf),
		make_storage_uniform(2, voxel_sparse_votes_buf),
		make_storage_uniform(3, anchor_count_buf),
	], _shader_reduce, 0)

	# anchor_count is read from anchor_count_buf inside the shaders; the former
	# push-constant slots are left zeroed. anchor_grid_x stays fixed (ANCHOR_GRID_X).
	var score_push := PushConstantLayout.new(SCORE_PUSH).pack({
		grid_x = grid_size.x,
		grid_y = grid_size.y,
		grid_z = grid_size.z,
		asset_count = safe_asset_count,
		inv_voxel_x = 1.0 / maxf(voxel_size.x, 0.0001),
		inv_voxel_y = 1.0 / maxf(voxel_size.y, 0.0001),
		inv_voxel_z = 1.0 / maxf(voxel_size.z, 0.0001),
		anchor_grid_x = anchor_grid_x,
		min_prefilter_score = min_prefilter_score,
	})

	var topk_push := PushConstantLayout.new(TOPK_PUSH).pack({
		asset_count = safe_asset_count,
		anchor_grid_x = anchor_grid_x,
		min_prefilter_score = min_prefilter_score,
	})

	var reduce_push := PushConstantLayout.new(REDUCE_PUSH).pack({
		tile_grid_x = tile_grid.x,
		tile_grid_y = tile_grid.y,
		tile_grid_z = tile_grid.z,
		tile_count = tile_count,
		asset_count = safe_asset_count,
		topk = TOPK,
	})

	var cl := begin_compute_list()
	if cl < 0:
		push_error("[AutoObjectProbePrefilterGPU] Score/Top-K/Reduce compute list begin failed")
		return false
	_gpu_dispatch_pipeline_sets_indirect(cl, _pipeline_score, [score_set0], score_push, score_indirect_args_buf)
	_rd.compute_list_add_barrier(cl)
	_gpu_dispatch_pipeline_sets_indirect(cl, _pipeline_topk, [topk_set0], topk_push, topk_indirect_args_buf)
	_rd.compute_list_add_barrier(cl)
	_gpu_dispatch_pipeline_sets(cl, _pipeline_reduce, [reduce_set0], reduce_push, Vector3i(1, 1, 1))
	_rd.compute_list_add_barrier(cl)
	end_compute_list()
	return true


## 执行 GPU 路由打包 Pass（pack 或 expand），将稀疏投票缓冲区转换为 schema-v1 记录/范围 RID，返回驻留载荷字典。
func _run_candidate_route_gpu_pack_pass(
	voxel_sparse_votes_buf: RID,
	route_profiles: Array,
	tile_grid: Vector3i,
	tile_count: int,
	asset_count: int,
	tile_summaries_rid: RID = RID()
) -> Dictionary:
	var use_expand := tile_summaries_rid.is_valid()
	var shader_rid := _shader_route_expand if use_expand else _shader_route_pack
	var pipeline_rid := _pipeline_route_expand if use_expand else _pipeline_route_pack

	if not shader_rid.is_valid() or not pipeline_rid.is_valid():
		return _candidate_route_gpu_pack_blocked(
			"candidate_route_gpu_%s_shader_not_ready" % ("expand" if use_expand else "pack")
		)
	if not voxel_sparse_votes_buf.is_valid():
		return _candidate_route_gpu_pack_blocked("missing_voxel_sparse_votes_buffer")
	if asset_count <= 0 or tile_count <= 0 or tile_grid.x <= 0 or tile_grid.y <= 0 or tile_grid.z <= 0:
		return _candidate_route_gpu_pack_blocked("invalid_route_pack_dimensions")

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
		return _candidate_route_gpu_pack_blocked("candidate_route_gpu_%s_storage_buffer_failed" % ("expand" if use_expand else "pack"))

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
		return _candidate_route_gpu_pack_blocked("candidate_route_gpu_%s_uniform_set_failed" % ("expand" if use_expand else "pack"))

	var push := PackedByteArray()
	if use_expand:
		# Expand shader uses more push constants
		push = PushConstantLayout.new(ROUTE_EXPAND_PUSH).pack({
			tile_grid_x = tile_grid.x,
			tile_grid_y = tile_grid.y,
			tile_grid_z = tile_grid.z,
			asset_count = asset_count,
			tile_count = tile_count,
			record_capacity = record_capacity,
			summary_stride_uints = SCENE_VOXEL_TILE_SUMMARY_STRIDE_UINTS,
			epsilon = 0.0001,
		})
	else:
		# Pack shader uses exactly 32 bytes
		push = PushConstantLayout.new(ROUTE_PACK_PUSH).pack({
			tile_grid_x = tile_grid.x,
			tile_grid_y = tile_grid.y,
			tile_grid_z = tile_grid.z,
			asset_count = asset_count,
			tile_count = tile_count,
			record_capacity = record_capacity,
			epsilon = 0.0001,
		})

	var cl := begin_compute_list()
	if cl < 0:
		return _candidate_route_gpu_pack_blocked("candidate_route_gpu_%s_compute_list_begin_failed" % ("expand" if use_expand else "pack"))
	_gpu_dispatch_pipeline_sets(cl, pipeline_rid, [set0], push, Vector3i(1, 1, 1))
	end_compute_list()
	submit_and_sync(true)

	# ═══════════════════════════════════════════════════════════════════
	# GPU-First path:
	#   Count buffer is NOT read back on CPU. The resident record/range
	#   buffers are handed directly to the VPG adapter chain. The debug_buf
	#   is still written by the shader but never read back here.
	# ═══════════════════════════════════════════════════════════════════
	_candidate_route_gpu_pack_record_buf = record_buf
	_candidate_route_gpu_pack_range_buf = range_buf

	var source_label := CANDIDATE_ROUTE_GPU_PACK_SOURCE_LABEL
	if use_expand:
		source_label = "gpu_vote_buffer_gpu_expand"

	return {
		# 状态 / 来源标签（被 SPA 的 contract/summary 与 _decode_results 透出）
		"ok": true,
		"reason": "ok",
		"source_label": source_label,
		"resident_route_source_label": source_label,
		"ordering_contract": "candidate_set_equivalent_not_score_sorted",
		"producer": "AutoObjectProbePrefilterGPU",
		"resident_route_producer": "AutoObjectProbePrefilterGPU",
		"resident_route_owner": "AutoObjectProbePrefilterGPU",
		"resident_route_buffer_owner": "AutoObjectProbePrefilterGPU",
		"resident_route_buffer_lifetime": "AutoObjectProbePrefilterGPU owned until next route pack, dispose, or explicit release",
		"status": "gpu_%s_resident" % ("expand" if use_expand else "pack"),
		"debug_status": "gpu_route_%s_resident_no_record_range_readback" % ("expand" if use_expand else "pack"),
		"readback_derived": false,
		# Schema / stride（VPG 合同与 SPA 借用门控会校验）
		"schema_version": CANDIDATE_ROUTE_SCHEMA_VERSION,
		"record_stride_bytes": CANDIDATE_ROUTE_RECORD_STRIDE_BYTES,
		"range_stride_bytes": CANDIDATE_ROUTE_RANGE_STRIDE_BYTES,
		"resident_route_record_stride": CANDIDATE_ROUTE_RECORD_STRIDE_BYTES,
		"resident_route_range_stride": CANDIDATE_ROUTE_RANGE_STRIDE_BYTES,
		# 交给 VPG 适配链的驻留 GPU 缓冲区
		"resident_route_record_rid": record_buf,
		"resident_route_range_rid": range_buf,
		"resident_route_record_rid_valid": record_buf.is_valid(),
		"resident_route_range_rid_valid": range_buf.is_valid(),
		"resident_route_record_capacity": record_capacity,
		"resident_route_range_count": asset_count,
		"same_rendering_device_as_vpg": true,
		# 计数 / CPU 上传回退入参（GPU-first 不回读计数，record_bytes 留空）
		"record_count": 0,
		"range_count": asset_count,
		"asset_count": asset_count,
		"has_records": true,
		"cpu_expanded_route_input": false,
		"record_bytes": PackedByteArray(),
		"range_bytes": PackedByteArray(),
	}


## 释放上一帧 GPU 路由打包产生的驻留 record/range 缓冲区 RID，并清空 SCOPE_PASS 资源。
func _release_candidate_route_gpu_pack_payload_buffers() -> void:
	gc_scope(SCOPE_PASS)
	if _candidate_route_gpu_pack_record_buf.is_valid():
		release_rid(_candidate_route_gpu_pack_record_buf)
	if _candidate_route_gpu_pack_range_buf.is_valid():
		release_rid(_candidate_route_gpu_pack_range_buf)
	_candidate_route_gpu_pack_record_buf = RID()
	_candidate_route_gpu_pack_range_buf = RID()


## 构造 GPU 路由打包被阻塞时的默认失败结果字典。
func _candidate_route_gpu_pack_blocked(reason: String) -> Dictionary:
	# ok=false 即可让所有消费方（_candidate_route_payload_has_resident_rids /
	# SPA handoff / VPG 合同）走拒绝分支；其余键它们都有默认值兜底。
	return {
		"ok": false,
		"reason": reason,
		"ordering_contract": "blocked",
	}


# ---------------------------------------------------------------------------
# Probe packing
# ---------------------------------------------------------------------------

## 将所有 autoobject 的语义探针打包为 GPU 所需的字节缓冲区和范围表，优先使用 runtime_profile_container 借用路径。
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
		var autoobject := autoobjects[obj_idx] as Object
		if autoobject == null or not autoobject.has_method("get_semantic_probes"):
			continue

		var probes: Array = autoobject.call("get_semantic_probes", _semantic_probe_density(autoobject))
		var start := all_probes.size()
		for probe in probes:
			if probe is Dictionary:
				all_probes.append(probe)
		range_entries[obj_idx] = Vector2i(start, all_probes.size() - start)

	# Pack probe data: 2 vec4 per probe = 32 bytes
	# d0 = (offset.xyz, w_collision)
	# d1 = (rgba8_bits, expected_collision, w_color, w_complexity)
	var probe_bytes := PackedByteArray()
	probe_bytes.resize(maxi(all_probes.size(), 1) * 32)
	for i in range(all_probes.size()):
		var p: Dictionary = all_probes[i]
		var offset := _vec3_from(p.get("offset", Vector3.ZERO))
		var rgba8 := _shader_rgba8_from_probe(p)
		var e_coll := clampf(float(p.get("expected_collision", 0.0)), 0.0, 1.0)
		var wc := _probe_metric_weights(p)

		var base := i * 32
		BufferUtils.encode_vec4(probe_bytes, base + 0, offset, wc.z) # w_collision
		probe_bytes.encode_u32(base + 16, rgba8)        # floatBitsToUint on GPU side
		probe_bytes.encode_float(base + 20, e_coll)
		probe_bytes.encode_float(base + 24, wc.x)      # w_color
		probe_bytes.encode_float(base + 28, wc.y)      # w_complexity

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


## 从 runtime_profile_container 借用已驻留的探针缓冲区和范围数据，构造 GPU 探针打包结果。
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
		var autoobject := autoobjects[asset_id] as Object
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


## 构造探针打包失败时的阻塞结果字典。
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

## 将 GPU 回读的锚点字节解码为结构化结果字典，并交接 GPU 驻留路由载荷。
func _decode_results(
	anchors_bytes: PackedByteArray,
	anchor_count: int,
	asset_count: int,
	tile_count: int,
	sv,
	tile_grid: Vector3i,
	route_profiles: Array,
	probe_pack: Dictionary = {},
	pipeline_status: Dictionary = {},
	target_read_buffer_summary: Dictionary = {},
	gpu_route_pack_payload: Dictionary = {}
) -> Dictionary:
	# Decode anchors
	var anchors: Array[Dictionary] = []
	var anchor_stride_bytes := BufferUtils.IVEC4_BYTES # uvec4(x, y, z, reserved)
	var available_anchor_bytes := mini(anchors_bytes.size(), anchor_count * anchor_stride_bytes)
	available_anchor_bytes -= available_anchor_bytes % anchor_stride_bytes
	var available_anchor_count := mini(anchor_count, int(available_anchor_bytes / anchor_stride_bytes))
	for i in range(available_anchor_count):
		var base := i * anchor_stride_bytes
		var voxel_pos := BufferUtils.decode_vec3i4(anchors_bytes, base)
		anchors.append({
			"id": i,                         # debug anchor index
			"voxel_pos": voxel_pos,          # position-only anchor voxel
		})

	var route_debug := _route_profile_debug(route_profiles, asset_count)
	var readiness := pipeline_status.duplicate(true) if not pipeline_status.is_empty() else _pipeline_readiness()
	var route_handoff_payload := gpu_route_pack_payload.duplicate(true)

	var route_contract := VoxelPlacementGeneratorScript._candidate_route_input_contract_from_settings({
		"candidate_route_input_contract": route_handoff_payload,
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "resident",
	})
	return {
		"ok": true,
		"anchors": anchors,                                           # position-only anchor readback
		"anchor_autoobject_topk": {},                                 # GPU internal, not read back
		"autoobject_candidate_voxel_sparses": {},                     # per-asset regions live in resident GPU route buffers
		"candidate_voxel_regions_by_asset": {},
		"candidate_voxel_sparses_by_asset": {},
		"candidate_route_profiles": route_debug,                       # route expansion debug
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "resident",
		"candidate_route_input_contract": route_contract,
		"candidate_route_handoff_payload": route_handoff_payload,
		"candidate_route_gpu_pack_payload": gpu_route_pack_payload,
		"candidate_route_payload_source_label": str(route_handoff_payload.get("source_label", "none")),
		"candidate_route_payload_ordering_contract": str(route_handoff_payload.get("ordering_contract", "candidate_set_equivalent_not_score_sorted")),
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


## 检查路由交接载荷是否持有有效的驻留 record/range RID。
static func _candidate_route_payload_has_resident_rids(payload: Dictionary) -> bool:
	var raw_record = payload.get("resident_route_record_rid", RID())
	var raw_range = payload.get("resident_route_range_rid", RID())
	var record_rid: RID = raw_record if raw_record is RID else RID()
	var range_rid: RID = raw_range if raw_range is RID else RID()
	return bool(payload.get("ok", false)) and record_rid.is_valid() and range_rid.is_valid()


## 检查预过滤结果字典中的候选路由载荷是否持有驻留 RID。
static func _result_has_resident_candidate_route_payload(result: Dictionary) -> bool:
	var raw_payload = result.get("candidate_route_handoff_payload", {})
	return raw_payload is Dictionary and _candidate_route_payload_has_resident_rids(raw_payload as Dictionary)


## 加载并编译所有计算着色器，按需加载路由打包/展开 Shader，同时创建对应管线 RID。
func _load_shaders(load_route_expand: bool = false) -> void:
	_shader_collect = load_compute_shader("res://shaders/collect_sv_anchors.glsl")
	_shader_anchor_finalize = load_compute_shader("res://shaders/prefilter_anchor_dispatch_finalize.glsl")
	_shader_score = load_compute_shader("res://shaders/score_anchor_asset_probes.glsl")
	_shader_topk = load_compute_shader("res://shaders/select_anchor_topk.glsl")
	_shader_reduce = load_compute_shader("res://shaders/reduce_anchor_topk_to_voxel_regions.glsl")
	_shader_route_pack = load_compute_shader("res://shaders/pack_candidate_route_records_from_votes.glsl")
	if load_route_expand:
		_shader_route_expand = load_compute_shader("res://shaders/expand_scene_voxel_tile_routes.glsl")
	if _shader_collect.is_valid():
		_pipeline_collect = create_compute_pipeline(_shader_collect)
	if _shader_anchor_finalize.is_valid():
		_pipeline_anchor_finalize = create_compute_pipeline(_shader_anchor_finalize)
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


## 检查核心四个管线 RID 是否全部有效，可选验证路由打包或展开管线。
func _pipeline_rids_ready(require_route_expand: bool = false) -> bool:
	var core_ready := (
		_shader_collect.is_valid() and _pipeline_collect.is_valid()
		and _shader_anchor_finalize.is_valid() and _pipeline_anchor_finalize.is_valid()
		and _shader_score.is_valid() and _pipeline_score.is_valid()
		and _shader_topk.is_valid() and _pipeline_topk.is_valid()
		and _shader_reduce.is_valid() and _pipeline_reduce.is_valid()
	)
	if not core_ready:
		return false
	if require_route_expand:
		return _shader_route_expand.is_valid() and _pipeline_route_expand.is_valid()
	return _shader_route_pack.is_valid() and _pipeline_route_pack.is_valid()


## 返回每个 Pass 的 shader/pipeline 有效性状态字典，用于调试和错误报告。
func _pipeline_readiness(route_expand_requested: bool = false) -> Dictionary:
	var collect := _pipeline_pass_readiness(_shader_collect, _pipeline_collect)
	var anchor_finalize := _pipeline_pass_readiness(_shader_anchor_finalize, _pipeline_anchor_finalize)
	var score := _pipeline_pass_readiness(_shader_score, _pipeline_score)
	var topk := _pipeline_pass_readiness(_shader_topk, _pipeline_topk)
	var reduce := _pipeline_pass_readiness(_shader_reduce, _pipeline_reduce)
	var route_pack := _pipeline_pass_readiness(_shader_route_pack, _pipeline_route_pack)
	route_pack["requested"] = true
	var route_expand := _pipeline_pass_readiness(_shader_route_expand, _pipeline_route_expand)
	route_expand["requested"] = route_expand_requested
	var all_ready := bool(collect.get("ready", false)) \
		and bool(anchor_finalize.get("ready", false)) \
		and bool(score.get("ready", false)) \
		and bool(topk.get("ready", false)) \
		and bool(reduce.get("ready", false))
	if route_expand_requested:
		all_ready = all_ready and bool(route_expand.get("ready", false))
	else:
		all_ready = all_ready and bool(route_pack.get("ready", false))
	return {
		"collect": collect,
		"anchor_finalize": anchor_finalize,
		"score": score,
		"topk": topk,
		"reduce": reduce,
		"route_pack": route_pack,
		"route_expand": route_expand,
		"all_ready": all_ready,
	}


## 检查单个 Pass 的 shader 和 pipeline RID 是否均有效。
func _pipeline_pass_readiness(shader: RID, pipeline: RID) -> Dictionary:
	var shader_valid := shader.is_valid()
	var pipeline_valid := pipeline.is_valid()
	return {
		"shader_rid_valid": shader_valid,
		"pipeline_rid_valid": pipeline_valid,
		"ready": shader_valid and pipeline_valid,
	}


## 释放所有 GPU 资源并将管线/着色器 RID 清零。
func _free_gpu() -> void:
	dispose()
	_pipeline_collect = RID()
	_pipeline_anchor_finalize = RID()
	_pipeline_score = RID()
	_pipeline_topk = RID()
	_pipeline_reduce = RID()
	_pipeline_route_pack = RID()
	_pipeline_route_expand = RID()
	_shader_collect = RID()
	_shader_anchor_finalize = RID()
	_shader_score = RID()
	_shader_topk = RID()
	_shader_reduce = RID()
	_shader_route_pack = RID()
	_shader_route_expand = RID()


## dispose 完成后清空驻留路由缓冲区的 RID 引用。
func _on_after_dispose() -> void:
	_candidate_route_gpu_pack_record_buf = RID()
	_candidate_route_gpu_pack_range_buf = RID()


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

## 构造预过滤失败或无结果时的空结果字典。
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


## 从探针打包结果中提取摘要信息，供结果字典的 profile_probe_pack 字段使用。
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


## 判断给定原因字符串是否属于合约阻塞级别的错误。
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


## 从探针打包字典中提取管线可用性状态，若无则重新查询。
func _pipeline_readiness_from_probe_pack(probe_pack: Dictionary) -> Dictionary:
	var raw_status = probe_pack.get("pipeline_readiness", {})
	if raw_status is Dictionary and not (raw_status as Dictionary).is_empty():
		return (raw_status as Dictionary).duplicate(true)
	return _pipeline_readiness()


## 从 sv 字典的 dirty_scene_voxel_tiles(B)提取脏 Tile ID 列表。
## 旧式 dirty_tiles(A) 在标记时与 B 双向同步、覆盖一致，经 TILE_SIZE 映射后产出的线性 ID 是 B 的子集，故不再单独读取。
func _dirty_tile_ids_from_sv(sv: Dictionary) -> Array[int]:
	var tile_grid: Vector3i = sv.get("tile_grid_size", Vector3i.ZERO)
	var result: Array[int] = []
	var dirty_scene_voxel_tiles: Dictionary = sv.get("dirty_scene_voxel_tiles", {})
	for raw_tile in dirty_scene_voxel_tiles.values():
		if not raw_tile is Dictionary:
			continue
		_append_shader_tile_ids_for_scene_voxel_tile(raw_tile as Dictionary, tile_grid, result)
	return result


## 将 scene_voxel_tile 的体素范围映射为 Tile 坐标区间，追加到 result 列表。
func _append_shader_tile_ids_for_scene_voxel_tile(tile: Dictionary, tile_grid: Vector3i, result: Array[int]) -> void:
	if tile_grid.x <= 0 or tile_grid.y <= 0 or tile_grid.z <= 0:
		return
	var voxel_min := VoxelGeneral.vector3i_from_value(tile.get("voxel_min", tile.get("bounds_min", Vector3i.ZERO)), Vector3i.ZERO)
	var voxel_max := VoxelGeneral.vector3i_from_value(tile.get("voxel_max", tile.get("bounds_max", voxel_min + Vector3i.ONE)), voxel_min + Vector3i.ONE)
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


## 返回 sv 中所有 Tile 的线性 ID 列表（全量扫描模式）。
static func all_tile_ids(sv: Dictionary) -> Array[int]:
	var total := int(sv.get("total_tiles", 0))
	var result: Array[int] = []
	for i in range(total):
		result.append(i)
	return result


## 对正整数执行向上取整除法，非正数返回 0。
static func _ceil_div_positive(value: int, divisor: int) -> int:
	if value <= 0 or divisor <= 0:
		return 0
	return int((value + divisor - 1) / divisor)


## 将线性工作量映射为不超过轴限制的 2D dispatch 组数 (x, y, 1)。
static func _linear_dispatch_groups(work_count: int) -> Vector3i:
	if work_count <= 0:
		return Vector3i.ZERO
	var groups_x := mini(work_count, PREFILTER_DISPATCH_AXIS_LIMIT)
	var groups_y := _ceil_div_positive(work_count, groups_x)
	if groups_y <= 0 or groups_y > PREFILTER_DISPATCH_AXIS_LIMIT:
		return Vector3i.ZERO
	return Vector3i(groups_x, groups_y, 1)


## 计算评分 Pass 的 Z 轴 dispatch 组数（每 SCORE_ASSET_LANES 个资源一组）。
static func _score_asset_block_dispatch_groups(asset_count: int) -> int:
	var safe_asset_count := clampi(asset_count, 0, MAX_ASSETS)
	var groups_z := _ceil_div_positive(safe_asset_count, SCORE_ASSET_LANES)
	if groups_z <= 0 or groups_z > PREFILTER_DISPATCH_AXIS_LIMIT:
		return 0
	return groups_z


## 过滤并去重 tile_id 列表，只保留 [0, tile_count) 范围内的有效 ID。
static func _sanitize_prefilter_tile_ids(values: Array[int], tile_count: int) -> Array[int]:
	var result: Array[int] = []
	if tile_count <= 0:
		return result
	var seen := {}
	for raw_id in values:
		var tile_id := int(raw_id)
		if tile_id < 0 or tile_id >= tile_count:
			continue
		if seen.has(tile_id):
			continue
		seen[tile_id] = true
		result.append(tile_id)
	return result


## 从 runtime_profile_container 获取 RenderingDevice 并附加到本类。
func _attach_runtime_profile_container_device(runtime_profile_container: Object) -> bool:
	if not _profile_container_ready_to_borrow(runtime_profile_container):
		return false
	var profile_rd := rendering_device_of(runtime_profile_container)
	if profile_rd == null:
		return false
	return attach_rendering_device(profile_rd, false)


## 检查 runtime_profile_container 是否已就绪且持有有效的探针缓冲区 RID。
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


## 从 autoobject 的元数据、属性或 voxel_descriptor 中解析 profile_id。
func _profile_id_from_autoobject(autoobject: Object, runtime_profile_container: Object) -> int:
	if autoobject == null:
		return -1
	for profile_key in ["profile_id", "auto_voxel_profile_id", "runtime_profile_id", "asset_profile_id"]:
		if autoobject.has_meta(profile_key):
			return int(autoobject.get_meta(profile_key))
		if VariantUtils.has_property(autoobject, profile_key):
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
	if not VariantUtils.has_property(autoobject, "voxel_descriptor"):
		return -1
	var descriptor = autoobject.get("voxel_descriptor")
	if not descriptor is Resource:
		return -1
	var density := _semantic_probe_density(autoobject) if VariantUtils.has_property(autoobject, "semantic_probe_density") else -1.0
	var mesh_ref = autoobject.get("mesh") if VariantUtils.has_property(autoobject, "mesh") else null
	return int(runtime_profile_container.call(
		"get_profile_id_for_descriptor",
		descriptor,
		0.0,
		density,
		Vector3.ONE,
		mesh_ref
	))


## 从 runtime_profile_container 获取指定 profile_id 的探针起始/数量范围。
func _profile_container_probe_range(runtime_profile_container: Object, profile_id: int) -> Dictionary:
	if runtime_profile_container == null or not runtime_profile_container.has_method("get_probe_range_for_profile_id"):
		return {}
	var raw_range = runtime_profile_container.call("get_probe_range_for_profile_id", profile_id)
	if raw_range is Dictionary:
		return (raw_range as Dictionary).duplicate(true)
	return {}


## 从 runtime_profile_container 的 GPU 缓冲区摘要中获取探针记录总数。
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


## 确保 float 数组长度不低于 expected，不足时用零补齐后返回副本。
func _ensure_float_array(arr: PackedFloat32Array, expected: int) -> PackedFloat32Array:
	if arr.size() >= expected:
		return arr
	var result := arr.duplicate()
	result.resize(expected)
	return result


## 将 complexity 和 collision 字段逐体素交错打包为 GPU 字节流（每体素 8 字节）。
func _pack_complexity_collision_float_bytes(scene_data: PackedFloat32Array, collision_data: PackedFloat32Array, voxel_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(voxel_count * 8)
	for i in range(voxel_count):
		var sv := scene_data[i] if i < scene_data.size() else 0.0
		var cv := collision_data[i] if i < collision_data.size() else 0.0
		bytes.encode_float(i * 8, sv)
		bytes.encode_float(i * 8 + 4, cv)
	return bytes


## 构建合并 complexity/collision 输入缓冲：优先从 sv 携带的常驻 8-bit field RID
## 做 GPU 转换（含 BlendSV 读取对，无 CPU 打包）；无常驻 RID 时回退 CPU float 打包。
func _make_complexity_collision_buffer(sv: Dictionary, voxel_count: int) -> RID:
	var raw_complexity_rid = sv.get("resident_complexity_field_read_rid", RID())
	var raw_collision_rid = sv.get("resident_collision_field_read_rid", RID())
	var resident_complexity: RID = raw_complexity_rid if raw_complexity_rid is RID else RID()
	var resident_collision: RID = raw_collision_rid if raw_collision_rid is RID else RID()
	if resident_complexity.is_valid() and resident_collision.is_valid():
		var shader := load_compute_shader("res://shaders/pack_prefilter_field_pair.glsl", SCOPE_FRAME, "pack_prefilter_field_pair")
		var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "pack_prefilter_field_pair")
		if shader.is_valid() and pipeline.is_valid():
			var merged_buf := storage_buffer_zero(voxel_count * 8, SCOPE_FRAME, "complexity_collision_merged")
			var set0 := create_uniform_set([
				make_storage_uniform(0, resident_complexity),
				make_storage_uniform(1, resident_collision),
				make_storage_uniform(2, merged_buf),
			], shader, 0, SCOPE_PASS, "pack_prefilter_field_pair")
			if merged_buf.is_valid() and set0.is_valid():
				var push := PushConstantLayout.new(FIELD_PAIR_PUSH).pack({
					voxel_count = voxel_count,
				})
				if _gpu_dispatch_and_sync(pipeline, [set0], push, dispatch_groups_1d(voxel_count, 64)):
					return merged_buf
		push_error("[AutoObjectProbePrefilterGPU] resident field pair convert dispatch failed; falling back to CPU pack")
	var complexity_collision_bytes := _pack_complexity_collision_float_bytes(
		_ensure_float_array(sv.get("complexity_field", PackedFloat32Array()), voxel_count),
		_ensure_float_array(sv.get("collision_field", PackedFloat32Array()), voxel_count),
		voxel_count
	)
	return storage_buffer_from_bytes(complexity_collision_bytes, SCOPE_FRAME, "complexity_collision_merged")


## 将 int 数组打包为 PackedByteArray（u32 格式），空数组返回 4 字节零。
func _pack_u32_array_from_int(values: Array[int]) -> PackedByteArray:
	if values.is_empty():
		var bytes := PackedByteArray()
		bytes.resize(4)
		return bytes
	return PackedInt32Array(values).to_byte_array()


## 将每个资源的路由半径（tile_radius）打包为 GPU 所需的字节缓冲区（每资源 16 字节）。
func _pack_route_profile_radius_bytes(route_profiles: Array, asset_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(asset_count, 1) * 16)
	for asset_index in range(maxi(asset_count, 0)):
		var route_profile: Dictionary = route_profiles[asset_index] if asset_index < route_profiles.size() and route_profiles[asset_index] is Dictionary else _empty_route_profile(asset_index)
		var radius := VoxelGeneral.vector3i_from_value(route_profile.get("tile_radius", Vector3i.ONE), Vector3i.ONE)
		radius = Vector3i(maxi(radius.x, 0), maxi(radius.y, 0), maxi(radius.z, 0))
		var base := asset_index * 16
		bytes.encode_u32(base + 0, radius.x)
		bytes.encode_u32(base + 4, radius.y)
		bytes.encode_u32(base + 8, radius.z)
		bytes.encode_u32(base + 12, 0)
	return bytes


## 组装目标评分的 GPU 读取缓冲区数据包：仅接受常驻 GPU 交接（借用外部持有的
## target_field 缓冲）；借用失败即阻断——无 CPU 字节上传回退。
func _target_read_buffer_pack(target_read_buffers: Dictionary, voxel_count: int) -> Dictionary:
	var expected_floats := maxi(voxel_count, 1) * 4
	var borrowed := _borrowed_target_read_buffer_pack(target_read_buffers, expected_floats)
	if bool(borrowed.get("ready", false)):
		return borrowed
	return _blocked_target_read_buffer_pack(
		str(borrowed.get("reason", "resident_handoff_absent")),
		expected_floats
	)


## 尝试从 target_read_buffers 字典借用已驻留的目标场缓冲区 RID，校验设备和字节数。
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

	var field_byte_count := int(target_read_buffers.get(
		"target_field_byte_count",
		summary.get(
			"target_field_byte_count",
			target_read_buffers.get("expected_byte_count", summary.get("expected_byte_count", 0))
		)
	))
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


## 构造目标场缓冲区不可用时的阻塞结果字典（常驻 GPU 交接缺失或不合规，无 CPU 上传回退）。
func _blocked_target_read_buffer_pack(
	borrow_reason: String,
	expected_floats: int
) -> Dictionary:
	var reason := "%s_gpu_resident_required" % borrow_reason
	push_error("[AutoObjectProbePrefilterGPU] target read buffers require a resident GPU handoff: %s" % reason)
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
		"target_field_byte_count": 0,
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


## 从 target_buffer_pack 中提取摘要信息，供结果字典的 target_read_buffer_summary 字段使用。
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


## 从探针字典中提取颜色和复杂度，转换为 GPU 所需的 RGBA8 uint32。
static func _shader_rgba8_from_probe(probe: Dictionary) -> int:
	if probe.has("expected_color") or probe.has("color") or probe.has("expected_complexity") or probe.has("complexity"):
		var color := VariantUtils.color_from_value(
			probe.get("expected_color", probe.get("color", Color.WHITE)),
			Color.WHITE
		)
		color.a = clampf(float(probe.get("expected_complexity", probe.get("complexity", color.a))), 0.0, 1.0)
		return BufferUtils.pack_shader_rgba8_word(color)
	return BufferUtils.semantic_to_shader_rgba8_word(int(probe.get("expected_rgba8", 0)))


## 将 Variant 安全转换为 Vector3，类型不匹配返回 Vector3.ZERO。
func _vec3_from(value) -> Vector3:
	if value is Vector3:
		return value as Vector3
	return Vector3.ZERO


## 从探针字典中读取颜色、复杂度、碰撞三个权重，返回 Vector3。
static func _probe_metric_weights(p: Dictionary) -> Vector3:
	return Vector3(
		float(p.get("w_color", 1.0)),
		float(p.get("w_complexity", 1.0)),
		float(p.get("w_collision", 1.0)),
	)


## 为所有 autoobject 构建路由 Profile 数组（probe/footprint/tile_radius）。
static func _build_route_profiles(autoobjects: Array, asset_count: int, voxel_size: Vector3) -> Array[Dictionary]:
	var profiles: Array[Dictionary] = []
	for obj_idx in range(asset_count):
		var autoobject := autoobjects[obj_idx] as Object
		if autoobject == null:
			profiles.append(_empty_route_profile(obj_idx))
			continue
		var probes: Array = autoobject.call("get_semantic_probes", _semantic_probe_density(autoobject)) if autoobject.has_method("get_semantic_probes") else []
		var collisions: Array = autoobject.call("get_collision") if autoobject.has_method("get_collision") else []
		var context_radius := _object_context_sensing_radius(autoobject)
		profiles.append(_build_route_profile_from_arrays(
			probes,
			collisions,
			voxel_size,
			context_radius,
			obj_idx
		))
	return profiles


## 返回指定 asset_index 的空路由 Profile 默认值字典。
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


## 根据探针偏移、碰撞脚印和上下文感知半径计算路由 Profile（tile_radius 等）。
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


## 计算探针偏移列表在体素坐标系下的 AABB（min/max）。
static func _probe_offset_voxel_bounds(probes: Array, voxel_size: Vector3) -> Dictionary:
	var has_probe := false
	var min_v := Vector3i.ZERO
	var max_v := Vector3i.ZERO
	for raw_probe in probes:
		if not raw_probe is Dictionary:
			continue
		var probe := raw_probe as Dictionary
		var offset := VariantUtils.vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
		var ov := VoxelGeneral.world_offset_to_voxels(offset, voxel_size)
		if not has_probe:
			min_v = ov
			max_v = ov
			has_probe = true
		else:
			min_v = Vector3i(mini(min_v.x, ov.x), mini(min_v.y, ov.y), mini(min_v.z, ov.z))
			max_v = Vector3i(maxi(max_v.x, ov.x), maxi(max_v.y, ov.y), maxi(max_v.z, ov.z))
	return {"min": min_v, "max": max_v}


## 计算碰撞脚印在体素坐标系下的 AABB（min/max）。
static func _footprint_voxel_bounds(collision: Array, _voxel_size: Vector3) -> Dictionary:
	var footprint: Array = AssetDescriptorScript.bake_footprint(collision, true, 1)
	if footprint.is_empty():
		return {"min": Vector3i.ZERO, "max": Vector3i.ZERO}
	var min_v := Vector3i(2147483647, 2147483647, 2147483647)
	var max_v := Vector3i(-2147483648, -2147483648, -2147483648)
	for raw_entry in footprint:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		var p := VoxelGeneral.vector3i_from_value(entry.get("local_pos", Vector3i.ZERO), Vector3i.ZERO)
		min_v = Vector3i(mini(min_v.x, p.x), mini(min_v.y, p.y), mini(min_v.z, p.z))
		max_v = Vector3i(maxi(max_v.x, p.x), maxi(max_v.y, p.y), maxi(max_v.z, p.z))
	return {"min": min_v, "max": max_v}


## 将世界空间半径转换为体素空间半径 Vector3i（委托给 VoxelGeneral）。
static func _radius_to_voxels(radius: float, voxel_size: Vector3) -> Vector3i:
	return VoxelGeneral.radius_to_voxels(radius, voxel_size)


## 将体素填充量转换为 Tile 半径（向上取整到 TILE_SIZE）。
static func _padding_to_tile_radius(min_pad: Vector3i, max_pad: Vector3i) -> Vector3i:
	return Vector3i(
		_ceil_div_positive(maxi(abs(min_pad.x), abs(max_pad.x)), TILE_SIZE),
		_ceil_div_positive(maxi(abs(min_pad.y), abs(max_pad.y)), TILE_SIZE),
		_ceil_div_positive(maxi(abs(min_pad.z), abs(max_pad.z)), TILE_SIZE)
	)


## 检查 Tile 坐标 p 是否在 tile_grid 范围内。
static func _tile_pos_in_bounds(p: Vector3i, tile_grid: Vector3i) -> bool:
	return (
		p.x >= 0 and p.x < tile_grid.x
		and p.y >= 0 and p.y < tile_grid.y
		and p.z >= 0 and p.z < tile_grid.z
	)


## 将 Tile 三维坐标转换为线性 tile_id（X-major，Z 次之，Y 最高）。
static func _tile_pos_to_id(p: Vector3i, tile_grid: Vector3i) -> int:
	return p.x + tile_grid.x * (p.z + tile_grid.z * p.y)


## 将线性 tile_id 还原为三维 Tile 坐标 Vector3i。
static func _tile_id_to_pos(tile_id: int, tile_grid: Vector3i) -> Vector3i:
	var tx := tile_id % tile_grid.x
	var tz := (tile_id / tile_grid.x) % tile_grid.z
	var ty := tile_id / (tile_grid.x * tile_grid.z)
	return Vector3i(tx, ty, tz)


## 从 autoobject 或其 voxel_descriptor 中读取 context_sensing_radius。
static func _object_context_sensing_radius(autoobject: Object) -> float:
	if autoobject == null:
		return 0.0
	var descriptor = autoobject.get("voxel_descriptor") if VariantUtils.has_property(autoobject, "voxel_descriptor") else null
	if descriptor is Resource and VariantUtils.has_property(descriptor, "context_sensing_radius"):
		return maxf(float(descriptor.get("context_sensing_radius")), 0.0)
	if VariantUtils.has_property(autoobject, "context_sensing_radius"):
		return maxf(float(autoobject.get("context_sensing_radius")), 0.0)
	return 0.0


## 从 autoobject 中读取 semantic_probe_density，默认返回 1.0。
static func _semantic_probe_density(autoobject: Object) -> float:
	if autoobject != null and VariantUtils.has_property(autoobject, "semantic_probe_density"):
		return float(autoobject.get("semantic_probe_density"))
	return 1.0


## 构造路由 Profile 的调试副本数组，缺失条目用空 Profile 填充。
static func _route_profile_debug(route_profiles: Array, asset_count: int) -> Array[Dictionary]:
	var debug: Array[Dictionary] = []
	for asset_id in range(asset_count):
		if asset_id < route_profiles.size() and route_profiles[asset_id] is Dictionary:
			debug.append((route_profiles[asset_id] as Dictionary).duplicate(true))
		else:
			debug.append(_empty_route_profile(asset_id))
	return debug
