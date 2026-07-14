class_name AutoObjectProbePrefilterGPU
extends "res://scripts/godot_compute_shader_base.gd"

## GPU-accelerated AutoObject probe prefilter.
## This is the only supported prefilter path. The CPU fallback was removed
## because anchor_count * asset_count * probe_count is too expensive for
## GDScript and can stall large scenes.
##
## Uses four compute-shader dispatches:
##   1. collect_sv_anchors        — find position-only anchor voxels
##   2. score_anchor_asset_probes — score each anchor×asset probe set (Pass A)
##   3. select_anchor_topk        — per-anchor top-K asset selection   (Pass B)
##   4. prefilter_anchor_dispatch_finalize — GPU indirect dispatch preparation
##
## Anchors and their top-K asset ids stay resident and are handed directly to fine
## scoring. Target read buffers must be a resident GPU handoff — when the
## resident buffer cannot be borrowed the prefilter raises an error (push_error)
## and returns a blocked result instead of uploading CPU bytes.

const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const RuntimeProfileContainerScript := preload("res://scripts/auto_voxel_runtime_profile_container.gd")
const SemanticProbeGeneratorScript := preload("res://scripts/semantic_probe_generator.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const TargetReadBufferBorrow := preload("res://scripts/utils/target_read_buffer_borrow.gd")

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

# ---------------------------------------------------------------------------
# Push-constant layout schemas (std430). Each field maps 1:1 to the original
# manual push.encode_* sequence, in order; trailing unused/zero slots are _pad.
# ---------------------------------------------------------------------------
const COLLECT_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["dirty_count", "int"],
	["tile_grid_x", "int"], ["tile_grid_y", "int"], ["tile_grid_z", "int"], ["anchor_capacity", "int"],
	["reserved0", "float"], ["reserved1", "float"], ["reserved2", "float"], ["min_target_interest", "float"],
	["collect_groups_x", "int"], ["collect_groups_y", "int"], ["_pad0", "int"], ["_pad1", "int"],
]
const ANCHOR_FINALIZE_PUSH := [
	["anchor_grid_x", "uint"], ["asset_blocks", "uint"], ["anchor_capacity", "uint"], ["_pad0", "uint"],
]
# Pass A writes raw signed probe sums unthresholded — min_prefilter_score only
# gates in Pass B (select_anchor_topk). The former pad/unused slots now carry
# host-passed buffer element capacities for the shader's capacity gates
# (replaces GLSL .length()/OpArrayLength, unsupported by Godot's SPIR-V path):
# anchor_buf_capacity = anchors[] elements (count still read from AnchorCountBuf),
# probe_range_capacity = asset_probe_range[] elements,
# probe_data_capacity_vec4 = probe_data[] vec4 elements (2 per probe).
const SCORE_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["asset_count", "int"],
	["inv_voxel_x", "float"], ["inv_voxel_y", "float"], ["inv_voxel_z", "float"], ["_pad0", "float"],
	["anchor_buf_capacity", "uint"], ["anchor_grid_x", "uint"],
	["probe_range_capacity", "uint"], ["probe_data_capacity_vec4", "uint"],
]
const TOPK_PUSH := [
	["_pad0", "uint"], ["asset_count", "uint"], ["anchor_grid_x", "uint"], ["min_prefilter_score", "float"],
]
const FIELD_PAIR_PUSH := [
	["voxel_count", "int"], ["_pad0", "int"], ["_pad1", "int"], ["_pad2", "int"],
]

# Per-anchor asset top-K is the compile-time TOPK contract (buffer strides, the
# select shader and the fine-score dispatch are sized by it end-to-end); the old
# public anchor_topk knob was inert and has been removed.
# Anchor gate retired (2026-07-09): collect_sv_anchors emits an anchor wherever the cell is
# inside the target volume (target_field.a > min_target_interest), matching Houdini's
# volumesample(targetVol,0,P) > 0. The former scene-occupancy / collision / support caps are
# gone; their COLLECT_PUSH slots (reserved0/1/2) are now zero-filled for layout stability.
var min_target_interest: float = 0.01       # anchor gate: cell counts as "inside target" when target_field.a exceeds this
var min_prefilter_score: float = 0.35       # minimum probe score accepted by shader
## Opt-in only: CPU readback of the anchor position array into result["anchors"].
## The anchors array is purely for debug/visualization; resident buffers drive placement.
var debug_read_anchors: bool = false

# Shaders & pipelines
var _shader_collect: RID
var _shader_anchor_finalize: RID
var _shader_score: RID
var _shader_topk: RID
var _pipeline_collect: RID
var _pipeline_anchor_finalize: RID
var _pipeline_score: RID
var _pipeline_topk: RID
var _resident_anchor_buf: RID
var _resident_anchor_count_buf: RID
var _resident_topk_buf: RID


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## 执行 GPU 探针预过滤主入口，返回包含 resident anchor handoff（anchor/count/topk
## RID）的结果字典。目标场只接受 target_read_buffers 中的常驻 GPU 交接（无 CPU 字节上传）。
func run_probe_prefilter(
	sv: Dictionary,
	autoobjects: Array,
	dirty_tile_ids: Array[int] = [],
	runtime_profile_container: Object = null,
	target_read_buffers: Dictionary = {}
) -> Dictionary:
	if sv.is_empty():
		return _empty_result("empty_sv")
	var candidate_tile_ids := dirty_tile_ids.duplicate()
	if candidate_tile_ids.is_empty():
		candidate_tile_ids = _dirty_tile_ids_from_sv(sv)
	if candidate_tile_ids.is_empty():
		candidate_tile_ids = all_tile_ids(sv)
	if candidate_tile_ids.is_empty():
		return _empty_result("no_candidate_tiles")

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

	_release_resident_anchor_handoff()
	var result := _run_gpu_pipeline(sv, autoobjects, candidate_tile_ids, runtime_profile_container, target_read_buffers)
	if _result_has_resident_anchor_payload(result):
		gc_frame()
	else:
		_free_gpu()
	return result


# ---------------------------------------------------------------------------
# GPU pipeline
# ---------------------------------------------------------------------------

## 执行完整的 GPU 计算管线（收集锚点→dispatch finalize→评分→Top-K），返回解码后的结果字典。
func _run_gpu_pipeline(
	sv: Dictionary,
	autoobjects: Array,
	tile_ids: Array[int],
	runtime_profile_container: Object = null,
	target_read_buffers: Dictionary = {}
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
		var pipeline_status := _pipeline_readiness()
		return _empty_result("no_valid_candidate_tiles", {}, pipeline_status)

	# ---- Normalize GPU buffer inputs ----

	var target_buffer_pack := _target_read_buffer_pack(target_read_buffers, voxel_count)
	if not bool(target_buffer_pack.get("ready", false)):
		var blocked_reason := str(target_buffer_pack.get("reason", "target_read_buffer_not_ready"))
		var blocked_result := _empty_result(blocked_reason, {}, _pipeline_readiness())
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
		var field_pipeline_status := _pipeline_readiness()
		_free_gpu()
		return _empty_result("complexity_collision_field_buffer_not_ready", probe_pack, field_pipeline_status)
	# Target read buffers must be a resident GPU handoff (borrowed); the CPU
	# upload fallback was removed, so _target_read_buffer_pack only reaches here
	# with a valid borrowed RID.
	var target_field_buf: RID = target_buffer_pack.get("target_field_buffer", RID())
	var target_collision_buf: RID = target_buffer_pack.get("target_collision_buffer", RID())
	track_borrowed_rid(target_field_buf, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_field")
	track_borrowed_rid(target_collision_buf, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_collision")
	var dirty_tile_buf := storage_buffer_from_bytes(_pack_u32_array_from_int(safe_tile_ids))
	var anchor_buf := storage_buffer_zero(ANCHOR_CAPACITY * 16, SCOPE_PERSISTENT, "prefilter_anchor_records")
	var anchor_count_buf := storage_buffer_zero(4, SCOPE_PERSISTENT, "prefilter_anchor_count")

	var probe_data_buf: RID
	if bool(probe_pack.get("probe_data_borrowed", false)):
		probe_data_buf = probe_pack.get("probe_data_buffer", RID())
		track_borrowed_rid(probe_data_buf, KIND_BUFFER, SCOPE_FRAME, "auto_voxel_runtime_profile_container:probe_records")
	else:
		probe_data_buf = storage_buffer_from_bytes(probe_pack.probe_bytes)
	var probe_range_buf := storage_buffer_from_bytes(probe_pack.range_bytes)

	var score_buf_size := ANCHOR_CAPACITY * MAX_ASSETS * 4
	var asset_scores_buf := storage_buffer_zero(score_buf_size)
	var topk_buf := storage_buffer_zero(ANCHOR_CAPACITY * TOPK * 8, SCOPE_PERSISTENT, "prefilter_anchor_topk")

	# ---- Dispatch 1: Collect anchors ----

	if not _dispatch_collect(
		target_field_buf, target_collision_buf, dirty_tile_buf,
		anchor_buf, anchor_count_buf,
		grid_size, tile_grid, safe_tile_ids.size()
	):
		var pipeline_status := _pipeline_readiness()
		_free_gpu()
		return _empty_result("collect_anchor_dispatch_bounds_exceeded", probe_pack, pipeline_status)

	# GPU-first: anchor_count stays on the GPU. The finalize pass inside
	# _dispatch_score_topk turns it into indirect dispatch args, so the host
	# never reads it back. Zero anchors -> zero score/top-K groups
	# flow through the rest of the pipeline naturally (no CPU early-out / sync here).

	# ---- Dispatch 2-3: Score probes -> Top-K selection ----

	if not _dispatch_score_topk(
		anchor_buf, anchor_count_buf, probe_range_buf, probe_data_buf,
		complexity_collision_buf, target_field_buf, target_collision_buf,
		asset_scores_buf, topk_buf,
		grid_size, voxel_size,
		asset_count,
		int(probe_pack.get("probe_range_capacity", 0)),
		int(probe_pack.get("probe_data_capacity_vec4", 0))
	):
		var pipeline_status := _pipeline_readiness()
		_free_gpu()
		return _empty_result("score_topk_compute_list_begin_failed", probe_pack, pipeline_status)

	_resident_anchor_buf = anchor_buf
	_resident_anchor_count_buf = anchor_count_buf
	_resident_topk_buf = topk_buf

	# ---- Read back results ----

	# Anchor position array + count readback is debug-only (result["anchors"]
	# visualization). Off by default so the routing path stays fully GPU-first; the
	# fine scoring consumes the resident buffers directly.
	var actual_anchor_count := 0
	var anchors_bytes := PackedByteArray()
	if debug_read_anchors:
		var anchor_count_bytes := _rd.buffer_get_data(anchor_count_buf, 0, 4)
		actual_anchor_count = mini(BufferUtils.decode_u32_count(anchor_count_bytes), ANCHOR_CAPACITY)
		anchors_bytes = _rd.buffer_get_data(anchor_buf, 0, actual_anchor_count * 16)
	var pipeline_status := _pipeline_readiness()

	return _decode_results(
		anchors_bytes,
		actual_anchor_count,
		asset_count,
		tile_count,
		sv,
		tile_grid,
		probe_pack,
		pipeline_status,
		_target_read_buffer_summary(target_buffer_pack),
		anchor_buf,
		anchor_count_buf,
		topk_buf
	)


# ---------------------------------------------------------------------------
# Dispatch helpers
# ---------------------------------------------------------------------------

## 调度 Pass 1：在脏 Tile 内收集落在目标体积内（target_field.a > min_target_interest）的锚点
## 体素，写入 anchor_buf。这是 Houdini `volumesample(targetVol,0,P) > 0` 门控的 GPU 对应实现：
## 只判定"是否在目标区域内"，场景占用/碰撞/支撑门控已交由后续评分阶段处理。
func _dispatch_collect(
	target_field_buf: RID,
	target_collision_buf: RID,
	dirty_tile_buf: RID, anchor_buf: RID, anchor_count_buf: RID,
	grid_size: Vector3i, tile_grid: Vector3i, dirty_count: int
) -> bool:
	var collect_groups := _linear_dispatch_groups(dirty_count)
	if collect_groups == Vector3i.ZERO:
		push_error("[AutoObjectProbePrefilterGPU] Collect anchors dispatch count is out of bounds")
		return false
	var set0 := create_uniform_set([
		make_storage_uniform(0, target_field_buf),
		make_storage_uniform(1, target_collision_buf),
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
## 参数（anchor_count 全程不回读 CPU），再以间接 dispatch 连续调度评分→Top-K。
## anchor_count==0 时 finalize 写出 0 组 → score/top-K 天然空跑，无需 CPU early-out。
func _dispatch_score_topk(
	anchor_buf: RID, anchor_count_buf: RID, probe_range_buf: RID,
	probe_data_buf: RID, complexity_collision_buf: RID,
	target_field_buf: RID, target_collision_buf: RID, asset_scores_buf: RID,
	topk_buf: RID,
	grid_size: Vector3i, voxel_size: Vector3,
	asset_count: int,
	probe_range_capacity: int, probe_data_capacity_vec4: int
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

	# ---- Score -> Top-K (indirect dispatch) ----
	var score_set0 := create_uniform_set([
		make_storage_uniform(0, anchor_buf),
		make_storage_uniform(1, probe_range_buf),
		make_storage_uniform(2, probe_data_buf),
		make_storage_uniform(3, complexity_collision_buf),
		make_storage_uniform(4, target_field_buf),
		make_storage_uniform(5, target_collision_buf),
		make_storage_uniform(6, asset_scores_buf),
		make_storage_uniform(7, anchor_count_buf),
	], _shader_score, 0)

	var topk_set0 := create_uniform_set([
		make_storage_uniform(0, asset_scores_buf),
		make_storage_uniform(1, topk_buf),
		make_storage_uniform(2, anchor_count_buf),
	], _shader_topk, 0)

	# anchor_count is read from anchor_count_buf inside the shaders;
	# anchor_grid_x stays fixed (ANCHOR_GRID_X). The capacity slots feed the
	# score shader's buffer-range gates (host-passed element counts).
	var score_push := PushConstantLayout.new(SCORE_PUSH).pack({
		grid_x = grid_size.x,
		grid_y = grid_size.y,
		grid_z = grid_size.z,
		asset_count = safe_asset_count,
		inv_voxel_x = 1.0 / maxf(voxel_size.x, 0.0001),
		inv_voxel_y = 1.0 / maxf(voxel_size.y, 0.0001),
		inv_voxel_z = 1.0 / maxf(voxel_size.z, 0.0001),
		anchor_buf_capacity = ANCHOR_CAPACITY,
		anchor_grid_x = anchor_grid_x,
		probe_range_capacity = maxi(probe_range_capacity, 0),
		probe_data_capacity_vec4 = maxi(probe_data_capacity_vec4, 0),
	})

	var topk_push := PushConstantLayout.new(TOPK_PUSH).pack({
		asset_count = safe_asset_count,
		anchor_grid_x = anchor_grid_x,
		min_prefilter_score = min_prefilter_score,
	})

	var cl := begin_compute_list()
	if cl < 0:
		push_error("[AutoObjectProbePrefilterGPU] Score/Top-K compute list begin failed")
		return false
	_gpu_dispatch_pipeline_sets_indirect(cl, _pipeline_score, [score_set0], score_push, score_indirect_args_buf)
	_rd.compute_list_add_barrier(cl)
	_gpu_dispatch_pipeline_sets_indirect(cl, _pipeline_topk, [topk_set0], topk_push, topk_indirect_args_buf)
	_rd.compute_list_add_barrier(cl)
	end_compute_list()
	return true


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
	# probe_range[asset_index] = (start_index, probe_count).
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
		# Element capacities of the buffers built from these bytes — explicit
		# capacity values for the score shader's gates.
		"probe_range_capacity": range_bytes.size() / 8,
		"probe_data_capacity_vec4": probe_bytes.size() / 16,
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
	for asset_index in range(asset_count):
		var autoobject := autoobjects[asset_index] as Object
		if autoobject == null:
			profile_ids.append(-1)
			range_bytes.encode_u32(asset_index * 8 + 0, 0)
			range_bytes.encode_u32(asset_index * 8 + 4, 0)
			continue
		var profile_id := _profile_id_from_autoobject(autoobject, runtime_profile_container)
		if profile_id < 0:
			return _blocked_probe_pack("missing_profile_id_for_asset:%d" % asset_index, autoobjects, asset_count, voxel_size)
		var probe_range := _profile_container_probe_range(runtime_profile_container, profile_id)
		if probe_range.is_empty():
			return _blocked_probe_pack("missing_probe_range_for_profile:%d" % profile_id, autoobjects, asset_count, voxel_size)
		profile_ids.append(profile_id)
		range_bytes.encode_u32(asset_index * 8 + 0, int(probe_range.get("start", 0)))
		range_bytes.encode_u32(asset_index * 8 + 4, int(probe_range.get("count", 0)))

	var probe_record_count := _profile_container_probe_record_count(runtime_profile_container)
	return {
		"ok": true,
		"ready": true,
		"range_bytes": range_bytes,
		"total_probes": probe_record_count,
		"probe_data_borrowed": true,
		"probe_data_buffer": probe_buffer,
		"probe_source": "auto_voxel_runtime_profile_container.probe_records",
		"profile_ids": profile_ids,
		"contract_blocked": false,
		# Element capacities for the score shader's gates: the borrowed probe
		# buffer holds 32 B records = 2 vec4 each; the range table is built above.
		"probe_range_capacity": range_bytes.size() / 8,
		"probe_data_capacity_vec4": probe_record_count * 2,
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
	probe_pack: Dictionary = {},
	pipeline_status: Dictionary = {},
	target_read_buffer_summary: Dictionary = {},
	anchor_buf: RID = RID(),
	anchor_count_buf: RID = RID(),
	topk_buf: RID = RID()
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

	var readiness := pipeline_status.duplicate(true) if not pipeline_status.is_empty() else _pipeline_readiness()
	var handoff := {
		"ok": anchor_buf.is_valid() and anchor_count_buf.is_valid() and topk_buf.is_valid(),
		"anchor_buffer_rid": anchor_buf,
		"anchor_count_buffer_rid": anchor_count_buf,
		"topk_buffer_rid": topk_buf,
		"anchor_capacity": ANCHOR_CAPACITY,
		"topk": TOPK,
		"asset_count": asset_count,
		"anchor_stride_bytes": 16,
		"topk_stride_bytes": 8,
		"origin_contract": "one_origin_per_anchor",
		"producer": "AutoObjectProbePrefilterGPU",
		"owner": "AutoObjectProbePrefilterGPU",
		"gpu_first": true,
	}
	return {
		"ok": true,
		"anchors": anchors,                                           # position-only anchor readback
		"anchor_autoobject_topk": {},                                 # GPU internal, not read back
		"anchor_candidate_handoff": handoff,
		"anchor_count": anchors.size(),                                # collected anchor count
		"anchor_count_source": "debug_readback" if debug_read_anchors else "gpu_buffer",
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
static func _result_has_resident_anchor_payload(result: Dictionary) -> bool:
	var raw_payload = result.get("anchor_candidate_handoff", {})
	if not raw_payload is Dictionary:
		return false
	var payload := raw_payload as Dictionary
	var anchor_rid: RID = payload.get("anchor_buffer_rid", RID())
	var count_rid: RID = payload.get("anchor_count_buffer_rid", RID())
	var topk_rid: RID = payload.get("topk_buffer_rid", RID())
	return bool(payload.get("ok", false)) and anchor_rid.is_valid() and count_rid.is_valid() and topk_rid.is_valid()


## 加载并编译所有计算着色器，同时创建对应管线 RID。
func _load_shaders() -> void:
	_shader_collect = load_compute_shader("res://shaders/collect_sv_anchors.glsl")
	_shader_anchor_finalize = load_compute_shader("res://shaders/prefilter_anchor_dispatch_finalize.glsl")
	_shader_score = load_compute_shader("res://shaders/score_anchor_asset_probes.glsl")
	_shader_topk = load_compute_shader("res://shaders/select_anchor_topk.glsl")
	if _shader_collect.is_valid():
		_pipeline_collect = create_compute_pipeline(_shader_collect)
	if _shader_anchor_finalize.is_valid():
		_pipeline_anchor_finalize = create_compute_pipeline(_shader_anchor_finalize)
	if _shader_score.is_valid():
		_pipeline_score = create_compute_pipeline(_shader_score)
	if _shader_topk.is_valid():
		_pipeline_topk = create_compute_pipeline(_shader_topk)


## 检查核心管线（collect/finalize/score/topk）的 RID 是否全部有效。
func _pipeline_rids_ready() -> bool:
	var core_ready := (
		_shader_collect.is_valid() and _pipeline_collect.is_valid()
		and _shader_anchor_finalize.is_valid() and _pipeline_anchor_finalize.is_valid()
		and _shader_score.is_valid() and _pipeline_score.is_valid()
		and _shader_topk.is_valid() and _pipeline_topk.is_valid()
	)
	return core_ready


## 返回每个 Pass 的 shader/pipeline 有效性状态字典，用于调试和错误报告。
func _pipeline_readiness() -> Dictionary:
	var collect := _pipeline_pass_readiness(_shader_collect, _pipeline_collect)
	var anchor_finalize := _pipeline_pass_readiness(_shader_anchor_finalize, _pipeline_anchor_finalize)
	var score := _pipeline_pass_readiness(_shader_score, _pipeline_score)
	var topk := _pipeline_pass_readiness(_shader_topk, _pipeline_topk)
	var all_ready := bool(collect.get("ready", false)) \
		and bool(anchor_finalize.get("ready", false)) \
		and bool(score.get("ready", false)) \
		and bool(topk.get("ready", false))
	return {
		"collect": collect,
		"anchor_finalize": anchor_finalize,
		"score": score,
		"topk": topk,
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
	_shader_collect = RID()
	_shader_anchor_finalize = RID()
	_shader_score = RID()
	_shader_topk = RID()


## dispose 完成后清空驻留 anchor handoff 的 RID 引用。
func _on_after_dispose() -> void:
	_resident_anchor_buf = RID()
	_resident_anchor_count_buf = RID()
	_resident_topk_buf = RID()


func _release_resident_anchor_handoff() -> void:
	for rid in [_resident_anchor_buf, _resident_anchor_count_buf, _resident_topk_buf]:
		if rid.is_valid():
			release_rid(rid)
	_resident_anchor_buf = RID()
	_resident_anchor_count_buf = RID()
	_resident_topk_buf = RID()


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
	if blocked and probe_pack.is_empty() and not bool(profile_probe_pack.get("contract_blocked", false)):
		profile_probe_pack["ok"] = false
		profile_probe_pack["ready"] = false
		profile_probe_pack["reason"] = reason
		profile_probe_pack["contract_blocked"] = true
	return {
		"ok": not blocked,
		"anchors": [],                              # position-only anchor readback
		"anchor_autoobject_topk": {},               # GPU internal, not read back
		"anchor_candidate_handoff": {"ok": false, "reason": reason},
		"anchor_count": 0,                          # collected anchor count
		"anchor_count_source": "none",
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
				var tile_index := _tile_pos_to_id(Vector3i(tx, ty, tz), tile_grid)
				if tile_index >= 0 and result.find(tile_index) < 0:
					result.append(tile_index)


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


## 过滤并去重 tile_index 列表，只保留 [0, tile_count) 范围内的有效 ID。
static func _sanitize_prefilter_tile_ids(values: Array[int], tile_count: int) -> Array[int]:
	var result: Array[int] = []
	if tile_count <= 0:
		return result
	var seen := {}
	for raw_id in values:
		var tile_index := int(raw_id)
		if tile_index < 0 or tile_index >= tile_count:
			continue
		if seen.has(tile_index):
			continue
		seen[tile_index] = true
		result.append(tile_index)
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


## 从 autoobject 的元数据、属性或 asset_descriptor 中解析 profile_id。
func _profile_id_from_autoobject(autoobject: Object, runtime_profile_container: Object) -> int:
	if autoobject == null:
		return -1
	for profile_key in ["profile_id", "auto_voxel_profile_id", "runtime_profile_id", "asset_profile_id"]:
		if autoobject.has_meta(profile_key):
			return int(autoobject.get_meta(profile_key))
		if VariantUtils.has_property(autoobject, profile_key):
			return int(autoobject.get(profile_key))
	var write_spec := {}
	if autoobject.has_method("get_instance_stamp_write_spec"):
		var raw_spec = autoobject.call("get_instance_stamp_write_spec")
		if raw_spec is Dictionary:
			write_spec = raw_spec as Dictionary
	for profile_key in ["profile_id", "auto_voxel_profile_id", "runtime_profile_id", "asset_profile_id"]:
		if write_spec.has(profile_key):
			return int(write_spec.get(profile_key, -1))
	if not runtime_profile_container.has_method("get_profile_id_for_descriptor"):
		return -1
	if not VariantUtils.has_property(autoobject, "asset_descriptor"):
		return -1
	var descriptor = autoobject.get("asset_descriptor")
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
		# resident RIDs were authoritative but the GPU convert failed. Do NOT fall through to the
		# CPU pack below: under a committer, sv carries no CPU fields → pad_float_array returns
		# an all-zero field that scores as real and slips past the caller's is_valid() block-guard.
		# Fail loud so run_probe_prefilter returns complexity_collision_field_buffer_not_ready.
		push_error("[AutoObjectProbePrefilterGPU] resident field pair convert failed; blocking (no CPU zero-fill fallback)")
		return RID()
	var complexity_collision_bytes := _pack_complexity_collision_float_bytes(
		VoxelGeneral.pad_float_array(sv.get("complexity_field", PackedFloat32Array()), voxel_count),
		VoxelGeneral.pad_float_array(sv.get("collision_field", PackedFloat32Array()), voxel_count),
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


## 尝试从 target_read_buffers 字典借用已驻留的目标场缓冲区 RID（解析/校验核心
## 共享自 TargetReadBufferBorrow；成功字典键集留在本文件，契约测试逐字断言）。
func _borrowed_target_read_buffer_pack(target_read_buffers: Dictionary, expected_floats: int) -> Dictionary:
	var resolved := TargetReadBufferBorrow.resolve(
		target_read_buffers,
		expected_floats * 4,
		_rd,
		["target_field_buffer", "resident_target_field_buffer"],
		SceneVoxelTileCodecScript.u32_field_byte_count(int(expected_floats / 4)),
		["target_collision_buffer", "resident_target_collision_buffer"]
	)
	if not bool(resolved.get("ok", false)):
		return {"ready": false, "reason": str(resolved.get("reason", "resident_handoff_absent"))}

	return {
		"ready": true,
		"target_read_buffer_source": "borrowed_scene_placement_actor_resident",
		"target_read_buffer_ownership": "borrowed_external",
		"target_read_buffer_lifetime": str(resolved.get("lifetime", "ScenePlacementActor owned")),
		"target_read_buffers_borrowed": true,
		"target_read_buffers_uploaded": false,
		"target_field_buffer": resolved.get("field_buffer", RID()),
		"target_collision_buffer": resolved.get("collision_buffer", RID()),
		"target_field_bytes": PackedFloat32Array(),
		"target_field_byte_count": int(resolved.get("field_byte_count", 0)),
		"expected_byte_count": expected_floats * 4,
		"target_field_format": str(resolved.get("field_format", "vec4")),
		"target_field_stride_bytes": int(resolved.get("field_stride_bytes", 16)),
		"target_collision_byte_count": int(resolved.get("collision_byte_count", 0)),
		"target_collision_format": str(resolved.get("collision_format", "unorm8_u32")),
		"owner": str(resolved.get("owner", "ScenePlacementActor")),
		"producer": str(resolved.get("producer", "ScenePlacementActorTargetReadBuffers")),
		"borrowed_from": "ScenePlacementActor",
		"source_reason": str(resolved.get("source_reason", "ok")),
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
		"target_collision_buffer": RID(),
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
	var raw_collision = pack.get("target_collision_buffer", RID())
	var collision_buffer: RID = raw_collision if raw_collision is RID else RID()
	return {
		"ready": bool(pack.get("ready", false)),
		"target_read_buffer_source": str(pack.get("target_read_buffer_source", "none")),
		"target_read_buffer_ownership": str(pack.get("target_read_buffer_ownership", "none")),
		"target_read_buffer_lifetime": str(pack.get("target_read_buffer_lifetime", "none")),
		"target_read_buffers_borrowed": bool(pack.get("target_read_buffers_borrowed", false)),
		"target_read_buffers_uploaded": bool(pack.get("target_read_buffers_uploaded", false)),
		"target_field_buffer_rid": "valid" if field_buffer.is_valid() else "none",
		"target_field_buffer_rid_valid": field_buffer.is_valid(),
		"target_collision_buffer_rid": "valid" if collision_buffer.is_valid() else "none",
		"target_collision_buffer_rid_valid": collision_buffer.is_valid(),
		"target_collision_byte_count": int(pack.get("target_collision_byte_count", 0)),
		"target_collision_format": str(pack.get("target_collision_format", "none")),
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


## 委托到探针 schema 属主 SemanticProbeGenerator.shader_rgba8_from_probe（单一权威）。
## 冻结符号：tools/test_autoobject_probe_prefilter.gd 按 Prefilter._shader_rgba8_from_probe
## 引用此静态，勿改名——如需改动语义请改共享属主并同步该测试。
static func _shader_rgba8_from_probe(probe: Dictionary) -> int:
	return SemanticProbeGeneratorScript.shader_rgba8_from_probe(probe)


## 将 Variant 安全转换为 Vector3，类型不匹配返回 Vector3.ZERO。
func _vec3_from(value) -> Vector3:
	if value is Vector3:
		return value as Vector3
	return Vector3.ZERO


## 委托到 SemanticProbeGenerator.probe_metric_weights（单一权威）。
static func _probe_metric_weights(p: Dictionary) -> Vector3:
	return SemanticProbeGeneratorScript.probe_metric_weights(p)


## 将 Tile 三维坐标转换为线性 tile_index（X-major，Z 次之，Y 最高）。
static func _tile_pos_to_id(p: Vector3i, tile_grid: Vector3i) -> int:
	return p.x + tile_grid.x * (p.z + tile_grid.z * p.y)


## 从 autoobject 中读取 semantic_probe_density，默认返回 1.0。
static func _semantic_probe_density(autoobject: Object) -> float:
	if autoobject != null and VariantUtils.has_property(autoobject, "semantic_probe_density"):
		return float(autoobject.get("semantic_probe_density"))
	return 1.0
