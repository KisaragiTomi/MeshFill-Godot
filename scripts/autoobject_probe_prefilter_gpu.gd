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
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")
const TargetReadBufferBorrow := preload("res://scripts/utils/target_read_buffer_borrow.gd")

const TILE_SIZE := 8
const MAX_ASSETS := 256
## ⚠ 2026-08-10 用户裁决：4 → 16，配合**粗筛暂停淘汰**（见 `select_anchor_topk.glsl`
## 文件头的完整说明）。资产数 ≤ 16 时人人有槽，粗筛的排序挤不掉任何候选，
## 由细筛独自决定；coarse score 的重做另行安排。
## ⚠ 它是端到端的编译期契约：`_resident_topk_buf`（ANCHOR_CAPACITY × TOPK × 8 B）、
## VPG 的候选池（anchor_capacity × topk × 64 B）与细筛派发的 workgroup 数都按它线性放大。
## 当前配置下候选池 65536 × 16 × 64 B ≈ 67 MiB（TOPK=4 时约 17 MiB）。
## 恢复淘汰时把这里与 shader 的 `const uint TOPK` 一起调回。
const TOPK := 16
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
# profile_sample_record_capacity = profile_sample_records[] elements.
const SCORE_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["asset_count", "int"],
	["inv_voxel_x", "float"], ["inv_voxel_y", "float"], ["inv_voxel_z", "float"], ["asset_stride", "float"],
	["anchor_buf_capacity", "uint"], ["anchor_grid_x", "uint"],
	["probe_range_capacity", "uint"], ["profile_sample_record_capacity", "uint"],
]
## ⚠ `min_prefilter_score` 当前**被 shader 忽略**（粗筛暂停淘汰，2026-08-10 裁决）。
## 字段保留是为了不动已冻结的 push 布局；恢复淘汰时 shader 侧取回它即可，host 不用改。
const TOPK_PUSH := [
	["asset_stride", "uint"], ["asset_count", "uint"], ["anchor_grid_x", "uint"], ["min_prefilter_score", "float"],
]

# Per-anchor asset top-K is the compile-time TOPK contract (buffer strides, the
# select shader and the fine-score dispatch are sized by it end-to-end); the old
# public anchor_topk knob was inert and has been removed.
# Anchor gate: collect_sv_anchors emits an anchor at a cell inside the target volume
# (target_field.a > min_target_interest, matching Houdini's volumesample(targetVol,0,P) > 0)
# that is also the BOTTOMMOST in-target cell in its column — a lower in-target cell
# overrides (covers) higher ones, so at most one anchor per (x,z) column (the lowest)
# and no anchor stacks above another. The former scene-occupancy / collision / support
# caps are gone; their COLLECT_PUSH slots (reserved0/1/2) are now zero-filled for layout stability.
var min_target_interest: float = 0.01       # anchor gate: cell counts as "inside target" (bottommost-in-column) when target_field.a exceeds this
var min_prefilter_score: float = 0.35       # minimum probe score accepted by shader
## Opt-in only: CPU readback of the anchor position array into result["anchors"].
## The anchors array is purely for debug/visualization; resident buffers drive placement.
##
## ⚠ 不要为了"点选/显示要坐标"而把这个开关打开当生产路径用。它的语义是**每次
## prefilter 运行都顺带回读**（最多 65536 × 16 B ≈ 1 MB），默认 false = 不回读。
## 需要 CPU 锚点坐标的消费方走按需取数：借用 anchor_candidate_handoff 的只读
## anchor/count 缓冲，在真正要用的那一刻读一次并缓存——见
## VolumeScoreFineSelection.read_resident_anchors_packed / materialize_cpu_anchor_model。
## ⚠ 按需取数省下的是**不需要 CPU 锚点坐标的路径**（Place 批次、纯 GPU benchmark、
## 只吃 handoff 常驻 RID 的下游）。带可视化的 Score **没省**：显示构建仍会物化一次
## live_anchor_count × 16 B，与本开关打开时字节数相同，区别只在时机与缓存粒度
## （每模型一次，而非每次 prefilter 一次）。要真正省掉，前提是可视化改由 GPU 常驻
## 数据驱动；在那之前不要为了让"按需"这个说法成立而削弱显示。
var debug_read_anchors: bool = false
## Compatibility-only Dictionary materialization for debug consumers. Packed ivec4 data is
## always returned as anchors_packed when debug_read_anchors is enabled; high-volume Score
## consumers disable this and decode only the packed columns they actually use.
var decode_anchor_dictionaries: bool = true
## Opt-in benchmark mode. Each GPU stage is submitted and synchronized so the wall-clock
## phase timings include the work executed by that stage. Disabled by default: the normal
## resident pipeline keeps its original submission/synchronization behavior.
var profile_timing: bool = false
## Opt-in：把本类的三处 dispatch 从 [ComputePassChain]（位置数组绑定 + 相邻 pass 无条件切段）
## 换成 [RDGBuilder]（虚拟资源 + 访问语义，依赖/剔除/切段由图推导）。
##
## **默认 false = 走既有 ComputePassChain 路径**，所以本开关落地时是零行为变更。
## 两条路径共享同一套输入准备代码（缓冲数组、push 值、组数全都只算一遍），只在
## "怎么把这批 pass 送进 compute list"这一步分叉 —— 否则 A/B 比的就不是同一件事。
##
## 等价性由 scripts/checks/rdg_selftest.gd 的 T22 守（同输入两条路径各跑一遍，逐字节比对
## GPU 输出）。本类的四个绑定全是外部既有 RID，图不会剔除任何 pass、瞬态池也不参与分配，
## 所以这条路目前拿到的是"依赖/切段自动推导"，不是内存复用。
var use_rdg_dispatch: bool = false

# Compute kernels (shader + pipeline + push layout), all SCOPE_PERSISTENT: the
# pipeline set survives across runs and is only torn down by _free_gpu()/dispose().
var _kernel_collect: ComputeKernel = null
var _kernel_anchor_finalize: ComputeKernel = null
var _kernel_score: ComputeKernel = null
var _kernel_topk: ComputeKernel = null
## RDG 瞬态资源池（只在 use_rdg_dispatch 打开时懒建）。**池必须活得比单个 [RDGBuilder] 长** ——
## 它是跨图复用的载体，所以挂在实例上而不是每次 dispatch 新建。本类的绑定全是外部既有 RID
## （register_external_buffer），池实际上不会发生任何 acquire，但 RDGBuilder 要求池非空。
var _rdg_pool: RDGPool = null
var _resident_anchor_buf: RID
var _resident_anchor_count_buf: RID
var _resident_topk_buf: RID
var _resident_asset_scores_buf: RID
var _resident_asset_stride := 0
var _resident_collect_cache_key: Dictionary = {}
var _timing_phases: Array[Dictionary] = []
var _timing_last_usec := 0
var _timing_total_start_usec := 0
var _timing_anchor_count := 0
var _timing_asset_count := 0
var _timing_tile_count := 0
var _timing_collect_cache_hit := false


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## 执行 GPU 探针预过滤主入口，返回包含 resident anchor handoff（anchor/count/topk
## RID）的结果字典。目标场只接受 target_read_buffers 中的常驻 GPU 交接（无 CPU 字节上传）。
func run_probe_prefilter(
	sv: Dictionary,
	autoobjects: Array,
	dirty_handoff: Dictionary = {},
	runtime_profile_container: Object = null,
	target_read_buffers: Dictionary = {}
) -> Dictionary:
	_repair_soft_reloaded_members()
	_timing_begin()
	if sv.is_empty():
		return _empty_result("empty_sv")
	if not bool(dirty_handoff.get("ok", false)):
		return _empty_result(str(dirty_handoff.get("reason", "dirty_worklist_handoff_not_ready")))

	log_name = "AutoObjectProbePrefilterGPU"
	sync_global_device = true
	if runtime_profile_container != null:
		if not _attach_runtime_profile_container_device(runtime_profile_container):
			return _empty_result("auto_voxel_runtime_profile_container_not_ready")
	elif not ensure_device(true, true):
		return _empty_result("missing_rendering_device")
	if dirty_handoff.get("rendering_device") != _rd:
		return _empty_result("dirty_worklist_rendering_device_mismatch")
	_timing_mark("prepare")

	_load_shaders()
	_timing_mark("shader_setup")
	if not _pipeline_rids_ready():
		var pipeline_status := _pipeline_readiness()
		push_error("[AutoObjectProbePrefilterGPU] shader/pipeline 未就绪，四段管线状态 %s —— 不继续 dispatch。" % pipeline_status)
		assert(false, "AutoObjectProbePrefilterGPU: shader pipeline not ready")
		var blocked_result := _empty_result("prefilter_shader_pipeline_not_ready", {}, pipeline_status)
		_free_gpu()
		return blocked_result

	var result := _run_gpu_pipeline(sv, autoobjects, dirty_handoff, runtime_profile_container, target_read_buffers)
	if _result_has_resident_anchor_payload(result):
		gc_frame()
	else:
		_free_gpu()
	_timing_mark("gc")
	if profile_timing and bool(result.get("ok", false)):
		result["anchor_timing_profile"] = _timing_report()
	return result


# ---------------------------------------------------------------------------
# Opt-in timing profile
# ---------------------------------------------------------------------------

# ⚠ 编辑器软重载（@tool 脚本重新解析）后的成员修复，别当成冗余判空删掉。
#
# 事实依据（gdscript.cpp GDScriptInstance::reload_members）：软重载只把**重载前已存在**
# 的成员按名字搬进新槽位（值原样保留，不回初始值）；本次重载**新增**的成员槽是默认构造
# 的 Variant = nil，声明里的初始化器**不会**重跑。带静态类型也拦不住——实例槽本身是
# Variant。重载后第一次 run_probe_prefilter() 会炸在 `_timing_phases.clear()`、
# `_resident_collect_cache_key.is_empty()`、`_resident_asset_scores_buf.is_valid()`
# 这些"在 Nil 上找方法"的位置。
#
# ⚠ 必须用 `is` 而不是 `== null`：对静态类型已知的操作数 GDScript 会挑验证求值器，而
# Variant 给 (RID, NIL)、(DICTIONARY, NIL) 这类组合注册的是 OperatorEvaluatorAlwaysFalse
# （variant_op.cpp），`x == null` 会被编成恒 false，判空形同虚设。
#
# 语义：全部回到声明初值。常驻 asset score 缓冲句柄归零 ⇒
# _ensure_resident_asset_scores_buffer 重新创建（不会 free 一个假句柄）；collect 缓存键
# 清空 ⇒ 本次必然重跑 collect（缓存只做"键相等才复用"的判定，清空只会多算一次，不会误命中）。
# _timing_* 的其余标量由 _timing_begin() 无条件赋值，无需在此修复。
func _repair_soft_reloaded_members() -> void:
	if not (min_target_interest is float): min_target_interest = 0.01
	if not (_resident_asset_scores_buf is RID): _resident_asset_scores_buf = RID()
	if not (_resident_asset_stride is int): _resident_asset_stride = 0
	if not (_resident_collect_cache_key is Dictionary): _resident_collect_cache_key = {}
	if not (_timing_phases is Array): _timing_phases = []
	# 本轮重载**新增**的成员槽是 Nil：调度开关必须回到声明初值（= 旧路径），否则
	# `if use_rdg_dispatch` 拿 Nil 求值，重载后第一次 run 的调度路径由运气决定。
	if not (use_rdg_dispatch is bool): use_rdg_dispatch = false
	# 池句柄归零 ⇒ _ensure_rdg_pool 重建。丢掉的旧池是空的（本类不向池 acquire），
	# 不存在"漏掉一批物理资源"的问题。
	if not (_rdg_pool is RDGPool): _rdg_pool = null


func _timing_begin() -> void:
	_timing_phases.clear()
	_timing_anchor_count = 0
	_timing_asset_count = 0
	_timing_tile_count = 0
	_timing_collect_cache_hit = false
	if not profile_timing:
		_timing_last_usec = 0
		_timing_total_start_usec = 0
		return
	_timing_total_start_usec = Time.get_ticks_usec()
	_timing_last_usec = _timing_total_start_usec


func _timing_mark(phase_name: String, sync_gpu := false) -> void:
	if not profile_timing:
		return
	if sync_gpu:
		submit_and_sync(sync_global_device)
	var now := Time.get_ticks_usec()
	_timing_phases.append({
		"name": phase_name,
		"usec": now - _timing_last_usec,
	})
	_timing_last_usec = now


func _timing_report() -> Dictionary:
	var total_usec := maxi(_timing_last_usec - _timing_total_start_usec, 0)
	var phases_by_name := {}
	for phase in _timing_phases:
		var phase_name := str(phase.get("name", "unknown"))
		phases_by_name[phase_name] = int(phases_by_name.get(phase_name, 0)) + int(phase.get("usec", 0))
	return {
		"total_usec": total_usec,
		"phases": _timing_phases.duplicate(true),
		"phases_by_name": phases_by_name,
		"anchor_count": _timing_anchor_count,
		"asset_count": _timing_asset_count,
		"tile_count": _timing_tile_count,
		"collect_cache_hit": _timing_collect_cache_hit,
		"debug_read_anchors": debug_read_anchors,
		"gpu_stage_sync": true,
		"measurement_note": "GPU stages include one submit+sync boundary in profile mode",
	}


# ---------------------------------------------------------------------------
# GPU pipeline
# ---------------------------------------------------------------------------

## 执行完整的 GPU 计算管线（收集锚点→dispatch finalize→评分→Top-K），返回解码后的结果字典。
func _run_gpu_pipeline(
	sv: Dictionary,
	autoobjects: Array,
	dirty_handoff: Dictionary,
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
	var dirty_capacity := int(dirty_handoff.get("dirty_tile_capacity", 0))
	var dirty_worklist_buf: RID = dirty_handoff.get("dirty_tile_worklist_buffer", RID())
	var dirty_count_buf: RID = dirty_handoff.get("dirty_tile_count_buffer", RID())
	if dirty_capacity != tile_count or not dirty_worklist_buf.is_valid() or not dirty_count_buf.is_valid():
		push_error("[AutoObjectProbePrefilterGPU] dirty worklist 交接契约不符（dirty_capacity=%d，本地 tile_count=%d，worklist_rid_valid=%s，count_rid_valid=%s）。" % [
			dirty_capacity, tile_count, dirty_worklist_buf.is_valid(), dirty_count_buf.is_valid()])
		assert(false, "AutoObjectProbePrefilterGPU: dirty worklist handoff contract mismatch")
		return _empty_result("dirty_worklist_handoff_contract_mismatch", {}, _pipeline_readiness())
	_timing_asset_count = mini(autoobjects.size(), MAX_ASSETS)
	_timing_tile_count = dirty_capacity

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
	var scene_field_pack := _scene_field_buffer_pack(sv, voxel_count)
	if not bool(scene_field_pack.get("ready", false)):
		var field_pipeline_status := _pipeline_readiness()
		_free_gpu()
		return _empty_result(
			str(scene_field_pack.get("reason", "scene_field_buffers_not_ready")),
			{},
			field_pipeline_status
		)

	if autoobjects.size() > MAX_ASSETS:
		# 旧行为静默截到前 MAX_ASSETS 个，超出的资产永远不参与评分/放置。
		push_error("[AutoObjectProbePrefilterGPU] 资产数超出管线容量（%d > MAX_ASSETS=%d）—— 不静默截断资产表。" % [
			autoobjects.size(), MAX_ASSETS])
		assert(false, "AutoObjectProbePrefilterGPU: asset count exceeds MAX_ASSETS")
		_free_gpu()
		return _empty_result("asset_count_exceeds_capacity", {}, _pipeline_readiness())
	var asset_count := autoobjects.size()
	var asset_stride := maxi(asset_count, 1)
	var sample_pack := _pack_all_profile_samples(autoobjects, asset_count, voxel_size, runtime_profile_container)
	if not bool(sample_pack.get("ready", true)):
		return _empty_result(str(sample_pack.get("reason", "profile_sample_pack_not_ready")), sample_pack)
	_timing_mark("input_pack")

	# ---- Create or reuse GPU buffers ----

	var target_field_buf: RID = target_buffer_pack.get("target_field_buffer", RID())
	var target_collision_buf: RID = target_buffer_pack.get("target_collision_buffer", RID())
	track_borrowed_rid(target_field_buf, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_field")
	track_borrowed_rid(target_collision_buf, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_collision")
	var scene_complexity_buf: RID = scene_field_pack.get("complexity_buffer", RID())
	var scene_collision_buf: RID = scene_field_pack.get("collision_buffer", RID())

	var collect_cache_key := _make_collect_cache_key(
		grid_size,
		tile_grid,
		int(dirty_handoff.get("dirty_epoch", -1)),
		target_buffer_pack
	)
	var collect_cache_hit := _resident_collect_cache_ready(collect_cache_key)
	_timing_collect_cache_hit = collect_cache_hit
	if not collect_cache_hit:
		_release_resident_collect_cache()
		_resident_anchor_buf = storage_buffer_uninitialized(
			ANCHOR_CAPACITY * 16, SCOPE_PERSISTENT, "prefilter_anchor_records")
		_resident_anchor_count_buf = storage_buffer_zero(
			4, SCOPE_PERSISTENT, "prefilter_anchor_count")
	var anchor_buf := _resident_anchor_buf
	var anchor_count_buf := _resident_anchor_count_buf
	track_borrowed_rid(dirty_worklist_buf, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:dirty_tile_worklist")
	track_borrowed_rid(dirty_count_buf, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:dirty_tile_count")

	# coarse 粗筛的采样只有一个来源：容器常驻的固定槽位 Profile Arena。CPU 兜底布局已随
	# Arena 化退役（见 _pack_all_profile_samples），走到这里必然是借来的 Arena RID。
	var profile_arena_buf: RID = sample_pack.get("profile_sample_records_buffer", RID())
	if not bool(sample_pack.get("profile_sample_records_borrowed", false)) or not profile_arena_buf.is_valid():
		push_error("[AutoObjectProbePrefilterGPU] 采样包没有携带常驻 Profile Arena RID —— 不继续 dispatch。")
		assert(false, "AutoObjectProbePrefilterGPU: missing resident profile arena RID")
		_free_gpu()
		return _empty_result("missing_profile_arena_buffer", sample_pack, _pipeline_readiness())
	track_borrowed_rid(profile_arena_buf, KIND_BUFFER, SCOPE_FRAME, "auto_voxel_runtime_profile_container:profile_arena")
	var probe_range_buf := storage_buffer_from_bytes(sample_pack.range_bytes)
	var asset_scores_buf := _ensure_resident_asset_scores_buffer(asset_stride)
	var topk_buf := _ensure_resident_topk_buffer()
	if not anchor_buf.is_valid() or not anchor_count_buf.is_valid() \
			or not asset_scores_buf.is_valid() or not topk_buf.is_valid():
		push_error("[AutoObjectProbePrefilterGPU] 工作缓冲分配失败（anchor=%s, anchor_count=%s, asset_scores=%s, topk=%s）—— 不继续 dispatch。" % [
			anchor_buf.is_valid(), anchor_count_buf.is_valid(), asset_scores_buf.is_valid(), topk_buf.is_valid()])
		assert(false, "AutoObjectProbePrefilterGPU: work buffer allocation failed")
		_free_gpu()
		return _empty_result("prefilter_work_buffer_allocation_failed", sample_pack, _pipeline_readiness())
	_timing_mark("buffer_setup")

	# ---- Dispatch 1: Collect anchors, unless the target-derived set is resident ----

	if not collect_cache_hit:
		if not _dispatch_collect(
			target_field_buf, target_collision_buf, dirty_worklist_buf, dirty_count_buf,
			anchor_buf, anchor_count_buf,
			grid_size, tile_grid, dirty_capacity
		):
			var pipeline_status := _pipeline_readiness()
			assert(false, "AutoObjectProbePrefilterGPU: collect anchor dispatch failed")
			_free_gpu()
			return _empty_result("collect_anchor_dispatch_bounds_exceeded", sample_pack, pipeline_status)
		_resident_collect_cache_key = collect_cache_key.duplicate(true)
	_timing_mark("collect", not collect_cache_hit)

	# ---- Dispatch 2-3: Score probes -> Top-K selection ----

	if not _dispatch_score_topk(
		anchor_buf, anchor_count_buf, probe_range_buf, profile_arena_buf,
		scene_complexity_buf, scene_collision_buf, target_field_buf, target_collision_buf,
		asset_scores_buf, topk_buf,
		grid_size, voxel_size,
		asset_count, asset_stride,
		int(sample_pack.get("probe_range_capacity", 0)),
		int(sample_pack.get("profile_sample_record_capacity", 0))
	):
		var pipeline_status := _pipeline_readiness()
		assert(false, "AutoObjectProbePrefilterGPU: score/top-K dispatch failed")
		_free_gpu()
		return _empty_result("score_topk_compute_list_begin_failed", sample_pack, pipeline_status)
	_timing_mark("score_topk", true)

	# ---- Read back results ----

	var raw_anchor_count := 0
	var actual_anchor_count := 0
	var anchors_bytes := PackedByteArray()
	if debug_read_anchors or profile_timing:
		var anchor_count_bytes := _rd.buffer_get_data(anchor_count_buf, 0, 4)
		raw_anchor_count = BufferUtils.decode_u32_count(anchor_count_bytes)
		if not raw_anchor_count_within_capacity(raw_anchor_count):
			push_error("[AutoObjectProbePrefilterGPU] anchor invariant violated: raw_count=%d capacity=%d" % [
				raw_anchor_count, ANCHOR_CAPACITY])
			assert(false, "AutoObjectProbePrefilterGPU: anchor count invariant violated")
			_resident_collect_cache_key = {}
			return _empty_result("anchor_count_invariant_violated", sample_pack, _pipeline_readiness())
		actual_anchor_count = raw_anchor_count
		_timing_anchor_count = actual_anchor_count
	if debug_read_anchors:
		anchors_bytes = _rd.buffer_get_data(anchor_buf, 0, actual_anchor_count * 16)
	_timing_mark("readback")
	var pipeline_status := _pipeline_readiness()

	var decoded := _decode_results(
		anchors_bytes,
		actual_anchor_count,
		asset_count,
		tile_count,
		sv,
		tile_grid,
		sample_pack,
		pipeline_status,
		_target_read_buffer_summary(target_buffer_pack),
		anchor_buf,
		anchor_count_buf,
		topk_buf,
		raw_anchor_count,
		collect_cache_hit,
		asset_stride
	)
	_timing_mark("decode")
	return decoded


# ---------------------------------------------------------------------------
# Dispatch helpers
# ---------------------------------------------------------------------------

## 调度 Pass 1：在脏 Tile 内收集落在目标体积内（target_field.a > min_target_interest）
## 且为所在竖直列最低一个的锚点体素，写入 anchor_buf。门控 = Houdini
## `volumesample(targetVol,0,P) > 0` 的 GPU 实现 + bottommost-in-column（较低的 in-target
## 覆盖较高的：下方存在 in-target 体素则不发锚，每列至多一个锚且取最低）；场景占用/碰撞/支撑门控已交后续评分。
func _dispatch_collect(
	target_field_buf: RID,
	target_collision_buf: RID,
	dirty_tile_buf: RID,
	dirty_count_buf: RID,
	anchor_buf: RID,
	anchor_count_buf: RID,
	grid_size: Vector3i,
	tile_grid: Vector3i,
	dirty_capacity: int
) -> bool:
	var collect_groups := _linear_dispatch_groups(dirty_capacity)
	if collect_groups == Vector3i.ZERO:
		push_error("[AutoObjectProbePrefilterGPU] Collect anchors dispatch count is out of bounds (dirty_capacity=%d, axis_limit=%d)" % [
			dirty_capacity, PREFILTER_DISPATCH_AXIS_LIMIT])
		assert(false, "AutoObjectProbePrefilterGPU._dispatch_collect: dispatch count out of bounds")
		return false
	# ---- 输入准备：两条调度路径共用。位置即 set 0 的 binding 序号 ----
	var collect_buffers := [
		target_field_buf,      # b0 TargetField      readonly
		target_collision_buf,  # b1 TargetCollision  readonly
		dirty_tile_buf,        # b2 DirtyTiles       readonly
		anchor_buf,            # b3 AnchorOut        无限定符：按 atomicAdd 返回的 idx 散射写
		anchor_count_buf,      # b4 AnchorCount      无限定符：atomicAdd 的目标
		dirty_count_buf,       # b5 DirtyTileCount   readonly
	]
	var collect_push := {
		grid_x = grid_size.x,
		grid_y = grid_size.y,
		grid_z = grid_size.z,
		dirty_count = dirty_capacity,
		tile_grid_x = tile_grid.x,
		tile_grid_y = tile_grid.y,
		tile_grid_z = tile_grid.z,
		anchor_capacity = ANCHOR_CAPACITY,
		min_target_interest = min_target_interest,
		collect_groups_x = collect_groups.x,
		collect_groups_y = collect_groups.y,
	}

	# ---- 调度分叉：两条路径表达的是同一批 pass，差别只在如何送进 compute list ----
	# sync=false：本段不提交，提交/同步仍只由 profile 模式的 _timing_mark 触发。
	var dispatched := false
	if use_rdg_dispatch:
		dispatched = _rdg_dispatch_collect(collect_buffers, collect_push, collect_groups)
	else:
		var collect_pass := _kernel_collect.make_pass(collect_buffers, collect_push, collect_groups)
		dispatched = ComputePassChain.run(self, [collect_pass], false)
	if not dispatched:
		push_error("[AutoObjectProbePrefilterGPU] Collect anchors compute list begin failed（dispatch_path=%s）" % _dispatch_path_name())
		assert(false, "AutoObjectProbePrefilterGPU._dispatch_collect: compute list begin failed")
		return false
	return true


## GPU-first：先用 finalize pass 把 GPU 端 anchor_count 转成 score/top-K 的间接 dispatch
## 参数（anchor_count 全程不回读 CPU），再以间接 dispatch 连续调度评分→Top-K。
## anchor_count==0 时 finalize 写出 0 组 → score/top-K 天然空跑，无需 CPU early-out。
func _dispatch_score_topk(
	anchor_buf: RID, anchor_count_buf: RID, probe_range_buf: RID,
	profile_arena_buf: RID, scene_complexity_buf: RID, scene_collision_buf: RID,
	target_field_buf: RID, target_collision_buf: RID, asset_scores_buf: RID,
	topk_buf: RID,
	grid_size: Vector3i, voxel_size: Vector3,
	asset_count: int, asset_stride: int,
	probe_range_capacity: int, profile_sample_record_capacity: int
) -> bool:
	var safe_asset_count := clampi(asset_count, 0, MAX_ASSETS)
	var safe_asset_stride := clampi(asset_stride, maxi(safe_asset_count, 1), MAX_ASSETS)
	var asset_blocks := _score_asset_block_dispatch_groups(safe_asset_count)
	if asset_blocks <= 0:
		push_error("[AutoObjectProbePrefilterGPU] Score/Top-K asset block dispatch count is out of bounds (asset_count=%d, lanes=%d)" % [
			safe_asset_count, SCORE_ASSET_LANES])
		assert(false, "AutoObjectProbePrefilterGPU._dispatch_score_topk: asset block dispatch count out of bounds")
		return false
	if not _rd.has_method("compute_list_dispatch_indirect"):
		push_error("[AutoObjectProbePrefilterGPU] RenderingDevice lacks compute_list_dispatch_indirect")
		assert(false, "AutoObjectProbePrefilterGPU._dispatch_score_topk: no indirect dispatch support")
		return false
	var anchor_grid_x := ANCHOR_GRID_X

	# ---- GPU finalize: anchor_count -> indirect dispatch args (no CPU readback) ----
	var score_indirect_args_buf := dispatch_indirect_args_buffer_zero(SCOPE_FRAME, "prefilter_score_indirect_args")
	var topk_indirect_args_buf := dispatch_indirect_args_buffer_zero(SCOPE_FRAME, "prefilter_topk_indirect_args")
	if not score_indirect_args_buf.is_valid() or not topk_indirect_args_buf.is_valid():
		push_error("[AutoObjectProbePrefilterGPU] Failed to allocate anchor indirect args buffers (score=%s, topk=%s)" % [
			score_indirect_args_buf.is_valid(), topk_indirect_args_buf.is_valid()])
		assert(false, "AutoObjectProbePrefilterGPU._dispatch_score_topk: indirect args buffer allocation failed")
		return false
	# ---- 输入准备：两条调度路径共用。每个数组的位置即 set 0 的 binding 序号 ----
	var finalize_buffers := [
		anchor_count_buf,         # b0 AnchorCount        readonly
		score_indirect_args_buf,  # b1 ScoreIndirectArgs  writeonly
		topk_indirect_args_buf,   # b2 TopkIndirectArgs   writeonly
	]
	var finalize_push := {
		anchor_grid_x = anchor_grid_x,
		asset_blocks = asset_blocks,
		anchor_capacity = ANCHOR_CAPACITY,
	}
	# anchor_count is read from anchor_count_buf inside the shaders;
	# anchor_grid_x stays fixed (ANCHOR_GRID_X). The capacity slots feed the
	# score shader's buffer-range gates (host-passed element counts).
	var score_buffers := [
		anchor_buf,            # b0 AnchorBuf         readonly
		probe_range_buf,       # b1 ProbeRange        readonly
		profile_arena_buf,     # b2 ProfileArena      readonly
		scene_complexity_buf,  # b3 SceneComplexity   readonly
		scene_collision_buf,   # b4 SceneCollision    readonly
		target_field_buf,      # b5 TargetField       readonly
		target_collision_buf,  # b6 TargetCollision   readonly
		asset_scores_buf,      # b7 ScoresOut         writeonly
		anchor_count_buf,      # b8 AnchorCountBuf    readonly
	]
	var score_push := {
		grid_x = grid_size.x,
		grid_y = grid_size.y,
		grid_z = grid_size.z,
		asset_count = safe_asset_count,
		inv_voxel_x = 1.0 / maxf(voxel_size.x, 0.0001),
		inv_voxel_y = 1.0 / maxf(voxel_size.y, 0.0001),
		inv_voxel_z = 1.0 / maxf(voxel_size.z, 0.0001),
		asset_stride = float(safe_asset_stride),
		anchor_buf_capacity = ANCHOR_CAPACITY,
		anchor_grid_x = anchor_grid_x,
		probe_range_capacity = maxi(probe_range_capacity, 0),
		profile_sample_record_capacity = maxi(profile_sample_record_capacity, 0),
	}
	var topk_buffers := [
		asset_scores_buf,  # b0 ScoresIn        readonly（= score 的输出）
		topk_buf,          # b1 TopKOut         writeonly
		anchor_count_buf,  # b2 AnchorCountBuf  readonly
	]
	var topk_push := {
		asset_stride = safe_asset_stride,
		asset_count = safe_asset_count,
		anchor_grid_x = anchor_grid_x,
		min_prefilter_score = min_prefilter_score,
	}

	# ---- 调度分叉 ----
	# finalize 单独成段：score/top-K 的间接参数必须在其自身 compute list 结束后才被读取。
	var finalize_dispatched := false
	if use_rdg_dispatch:
		finalize_dispatched = _rdg_dispatch_finalize(finalize_buffers, finalize_push)
	else:
		var finalize_set0 := _kernel_anchor_finalize.bind_storage(finalize_buffers)
		if not finalize_set0.is_valid():
			push_error("[AutoObjectProbePrefilterGPU] Anchor finalize uniform set create failed")
			assert(false, "AutoObjectProbePrefilterGPU._dispatch_score_topk: finalize uniform set create failed")
			return false
		var finalize_pass := _kernel_anchor_finalize.make_pass_sets(
			[finalize_set0], finalize_push, Vector3i(1, 1, 1))
		finalize_dispatched = ComputePassChain.run(self, [finalize_pass], false)
	if not finalize_dispatched:
		push_error("[AutoObjectProbePrefilterGPU] Anchor finalize compute list begin failed（dispatch_path=%s）" % _dispatch_path_name())
		assert(false, "AutoObjectProbePrefilterGPU._dispatch_score_topk: finalize compute list begin failed")
		return false

	# ---- Score -> Top-K (indirect dispatch) ----
	# asset_scores_buf 是 score 写、top-K 读的唯一通道，两段之间的 barrier 不可省。
	var score_topk_dispatched := false
	if use_rdg_dispatch:
		score_topk_dispatched = _rdg_dispatch_score_topk(
			score_buffers, score_push, score_indirect_args_buf,
			topk_buffers, topk_push, topk_indirect_args_buf)
	else:
		var score_pass := _kernel_score.make_pass_indirect(
			score_buffers, score_push, score_indirect_args_buf)
		var topk_pass := _kernel_topk.make_pass_indirect(
			topk_buffers, topk_push, topk_indirect_args_buf)
		score_topk_dispatched = ComputePassChain.run(self, [score_pass, topk_pass], false, true)
	if not score_topk_dispatched:
		push_error("[AutoObjectProbePrefilterGPU] Score/Top-K compute list begin failed（dispatch_path=%s）" % _dispatch_path_name())
		assert(false, "AutoObjectProbePrefilterGPU._dispatch_score_topk: score/top-K compute list begin failed")
		return false
	return true


# ---------------------------------------------------------------------------
# RDG dispatch path (opt-in via use_rdg_dispatch)
# ---------------------------------------------------------------------------
#
# 三个 _rdg_dispatch_* 与上面 else 分支里的 ComputePassChain 段一一对应，表达同一批 pass、
# 同样的绑定顺序、同样的 push 值、同样的组数，只是把"谁依赖谁、在哪里切段"交给图去推。
#
# 访问语义逐条对着 shader 源码定，规则只有两条：
#   * 带 readonly / writeonly 限定符的绑定 -> [method RDG.read] / [method RDG.write]
#   * 不带限定符的绑定（本家族只有 collect_sv_anchors 的 b3/b4）-> [method RDG.read_write]
# 后者是**部分写 / 原子累加**：b3 按 atomicAdd 返回的 idx 散射写、b4 就是 atomicAdd 的目标。
# 误声明成 write，图会认定它整块覆盖并剔掉上游初始化 pass —— GPU 不报错，只出错数。
# [member ComputeKernel.uses_atomics] 的机械检查专门逮这种漏声明（collect 的 kernel 会命中它）。
#
# 本类的绑定**全部**是外部既有 RID：写 external 是图外可观测的副作用，所以剔除在这条路上
# 永远是空操作，瞬态池也不会发生任何 acquire。这条路目前买到的是依赖/切段的自动推导。


## 当前调度路径的名字，只用于错误文案 —— "哪条路失败了"是排查时的第一个问题。
func _dispatch_path_name() -> String:
	return "RDGBuilder" if use_rdg_dispatch else "ComputePassChain"


## 懒建 RDG 瞬态池。池与 owner 同寿（跨图复用的载体），失效或未建时重建。
func _ensure_rdg_pool() -> RDGPool:
	if _rdg_pool != null and _rdg_pool.is_valid():
		return _rdg_pool
	if _rd == null:
		push_error("[AutoObjectProbePrefilterGPU] RDG 池需要 RenderingDevice —— 不继续 dispatch。")
		assert(false, "AutoObjectProbePrefilterGPU._ensure_rdg_pool: no RenderingDevice")
		return null
	_rdg_pool = RDGPool.new(self)
	return _rdg_pool


## 把一条既有 RID 注册成图的 external 资源，并按 RID 去重。
##
## **去重不可省**：同一条 RID 注册两次会变成两个互不相干的虚拟资源，图看不出它们其实是同一块
## 内存，于是 score 写、top-K 读的那条 RAW 边根本不存在 —— 本该切的那一刀没了，静默数据竞争。
## asset_scores_buf 与 anchor_count_buf 正是跨 pass 复用的两条。
##
## size_bytes 传 0：[member RDGResource.logical_size] 只在**通过图回读** extracted 资源时才有
## 意义（池按 2 的幂分桶，回读要按逻辑尺寸截断）。external 资源不入池，本路径的回读也全部走
## 既有的 `_rd.buffer_get_data(原 RID, ...)`，不经过图。
func _rdg_external(builder: RDGBuilder, seen: Dictionary, name: String, rid: RID) -> RDGResource:
	var key := rid.get_id()
	var cached = seen.get(key)
	if cached != null:
		return cached
	var res := builder.register_external_buffer(name, rid, 0)
	seen[key] = res
	return res


## RDG 变体 — Pass 1 collect_sv_anchors（单 pass，零切段）。
func _rdg_dispatch_collect(buffers: Array, push_values: Dictionary, groups: Vector3i) -> bool:
	var pool := _ensure_rdg_pool()
	if pool == null:
		return false
	var g := RDGBuilder.new(self, pool)
	_rdg_build_collect(g, buffers, push_values, groups)
	var ok := g.execute({"sync": false})
	g.dispose()
	return ok


## 只声明、不执行。拆出来是为了让等价性用例（T22）能在**不真跑 GPU** 的前提下核对
## 「两条路径绑的是不是同一批 buffer、同样的 access」—— 绑定错位是本次转换最大的风险，
## 而它恰好完全可以静态查出来。
##
## ⚠ 别改成"顺便也 A/B 一下输出 buffer"：collect 用 `atomicAdd` 分配输出下标，
## 同输入重跑槽位顺序就会变，逐字节比对天然 flaky。
func _rdg_build_collect(g: RDGBuilder, buffers: Array, push_values: Dictionary, groups: Vector3i) -> void:
	var seen := {}
	g.add_pass("collect_sv_anchors", _kernel_collect, [
		RDG.read(_rdg_external(g, seen, "target_field", buffers[0])),
		RDG.read(_rdg_external(g, seen, "target_collision", buffers[1])),
		RDG.read(_rdg_external(g, seen, "dirty_tiles", buffers[2])),
		# b3/b4 无限定符：散射部分写 + atomicAdd 目标，必须 read_write（见本节顶部注释）。
		RDG.read_write(_rdg_external(g, seen, "anchor_out", buffers[3])),
		RDG.read_write(_rdg_external(g, seen, "anchor_count", buffers[4])),
		RDG.read(_rdg_external(g, seen, "dirty_tile_count", buffers[5])),
	], push_values, groups)


## RDG 变体 — prefilter_anchor_dispatch_finalize（单 pass，独立成图 = 独立成段）。
func _rdg_dispatch_finalize(buffers: Array, push_values: Dictionary) -> bool:
	var pool := _ensure_rdg_pool()
	if pool == null:
		return false
	var g := RDGBuilder.new(self, pool)
	_rdg_build_finalize(g, buffers, push_values)
	var ok := g.execute({"sync": false})
	g.dispose()
	return ok


## 只声明、不执行 —— 同 [method _rdg_build_collect] 的理由。
func _rdg_build_finalize(g: RDGBuilder, buffers: Array, push_values: Dictionary) -> void:
	var seen := {}
	g.add_pass("prefilter_anchor_dispatch_finalize", _kernel_anchor_finalize, [
		RDG.read(_rdg_external(g, seen, "anchor_count", buffers[0])),
		RDG.write(_rdg_external(g, seen, "score_indirect_args", buffers[1])),
		RDG.write(_rdg_external(g, seen, "topk_indirect_args", buffers[2])),
	], push_values, Vector3i(1, 1, 1))


## RDG 变体 — score -> top-K（两个间接 dispatch pass 同图）。
##
## 切段由图自己推出来：top-K 读的 asset_scores 正是 score 写的那一块（同一个 external 句柄），
## 这条 RAW 边让 top-K 前面切一刀 —— 与旧路径的 `barrier_between = true` 落在同一个位置。
## 两个 indirect args 缓冲由上一张图（finalize）写，跨图的顺序由"上一张图已经 end 了 compute
## list"保证，与旧路径完全一致。
func _rdg_dispatch_score_topk(
	score_buffers: Array, score_push: Dictionary, score_indirect_args_buf: RID,
	topk_buffers: Array, topk_push: Dictionary, topk_indirect_args_buf: RID
) -> bool:
	var pool := _ensure_rdg_pool()
	if pool == null:
		return false
	var g := RDGBuilder.new(self, pool)
	_rdg_build_score_topk(g, score_buffers, score_push, score_indirect_args_buf,
			topk_buffers, topk_push, topk_indirect_args_buf)
	var ok := g.execute({"sync": false})
	g.dispose()
	return ok


## 只声明、不执行 —— 同 [method _rdg_build_collect] 的理由。
## 这张图里 `asset_scores` 被 score 写、被 top-K 读，经 `_rdg_external` 的按 RID 去重后
## 是**同一个 [RDGResource] 实例** —— 那正是 RAW 边的来源，也是 top-K 前面那一刀的依据。
func _rdg_build_score_topk(
	g: RDGBuilder,
	score_buffers: Array, score_push: Dictionary, score_indirect_args_buf: RID,
	topk_buffers: Array, topk_push: Dictionary, topk_indirect_args_buf: RID
) -> void:
	var seen := {}
	g.add_pass_indirect("score_anchor_asset_probes", _kernel_score, [
		RDG.read(_rdg_external(g, seen, "anchors", score_buffers[0])),
		RDG.read(_rdg_external(g, seen, "probe_range", score_buffers[1])),
		RDG.read(_rdg_external(g, seen, "profile_arena", score_buffers[2])),
		RDG.read(_rdg_external(g, seen, "scene_complexity", score_buffers[3])),
		RDG.read(_rdg_external(g, seen, "scene_collision", score_buffers[4])),
		RDG.read(_rdg_external(g, seen, "target_field", score_buffers[5])),
		RDG.read(_rdg_external(g, seen, "target_collision", score_buffers[6])),
		RDG.write(_rdg_external(g, seen, "asset_scores", score_buffers[7])),
		RDG.read(_rdg_external(g, seen, "anchor_count", score_buffers[8])),
	], score_push, _rdg_external(g, seen, "score_indirect_args", score_indirect_args_buf))
	g.add_pass_indirect("select_anchor_topk", _kernel_topk, [
		RDG.read(_rdg_external(g, seen, "asset_scores", topk_buffers[0])),
		RDG.write(_rdg_external(g, seen, "anchor_topk", topk_buffers[1])),
		RDG.read(_rdg_external(g, seen, "anchor_count", topk_buffers[2])),
	], topk_push, _rdg_external(g, seen, "topk_indirect_args", topk_indirect_args_buf))


## collect 只依赖 target、grid、tile 集和 min_target_interest。target_revision 可用时
## 跨目标缓冲重建复用；缺失时退回 RID 身份，保证不会把未知新目标误判成缓存命中。
func _make_collect_cache_key(
	grid_size: Vector3i,
	tile_grid: Vector3i,
	dirty_epoch: int,
	target_buffer_pack: Dictionary
) -> Dictionary:
	var target_revision := int(target_buffer_pack.get("target_revision", -1))
	var key := {
		"grid_size": grid_size,
		"tile_grid": tile_grid,
		"dirty_epoch": dirty_epoch,
		"min_target_interest": min_target_interest,
		"target_revision": target_revision,
	}
	if target_revision < 0:
		key["target_field_buffer"] = target_buffer_pack.get("target_field_buffer", RID())
		key["target_collision_buffer"] = target_buffer_pack.get("target_collision_buffer", RID())
	return key


func _resident_collect_cache_ready(cache_key: Dictionary) -> bool:
	return not _resident_collect_cache_key.is_empty() \
		and _resident_collect_cache_key == cache_key \
		and _resident_anchor_buf.is_valid() \
		and _resident_anchor_count_buf.is_valid()


func _ensure_resident_asset_scores_buffer(asset_stride: int) -> RID:
	var safe_stride := clampi(asset_stride, 1, MAX_ASSETS)
	if _resident_asset_scores_buf.is_valid() and _resident_asset_stride == safe_stride:
		return _resident_asset_scores_buf
	if _resident_asset_scores_buf.is_valid():
		release_rid(_resident_asset_scores_buf)
	_resident_asset_scores_buf = storage_buffer_uninitialized(
		asset_scores_buffer_byte_count(safe_stride),
		SCOPE_PERSISTENT,
		"prefilter_asset_scores_stride_%d" % safe_stride
	)
	_resident_asset_stride = safe_stride if _resident_asset_scores_buf.is_valid() else 0
	return _resident_asset_scores_buf


func _ensure_resident_topk_buffer() -> RID:
	if not _resident_topk_buf.is_valid():
		_resident_topk_buf = storage_buffer_uninitialized(
			ANCHOR_CAPACITY * TOPK * 8,
			SCOPE_PERSISTENT,
			"prefilter_anchor_topk"
		)
	return _resident_topk_buf


# ---------------------------------------------------------------------------
# Probe packing
# ---------------------------------------------------------------------------

## Packs each asset's coarse ProfileSample range, borrowing the resident sample buffer when available.
func _pack_all_profile_samples(
	autoobjects: Array,
	asset_count: int,
	voxel_size: Vector3,
	runtime_profile_container: Object = null
) -> Dictionary:
	if runtime_profile_container != null:
		return _pack_profile_container_samples(autoobjects, asset_count, voxel_size, runtime_profile_container)

	# 固定槽位 Arena 化之后，这里原本的 CPU 兜底路径已经不可能正确：它把各资产的 coarse
	# 采样打成一条**扁平**记录流并按全局累计起点建 range，而 score_anchor_asset_probes.glsl
	# 现在按 (slot_index, 槽内局部下标) 从定长 Arena 里取样，两种布局无法互换——照旧上传
	# 只会让 shader 按 Arena 偏移去读一段完全不同的字节。故改为明确阻断，与容器未就绪时
	# 的既有 contract_blocked 语义一致（GPU-first：不降级到 CPU 副本）。
	push_error("[AutoObjectProbePrefilterGPU] 未提供 runtime profile container —— coarse 粗筛的采样只能来自常驻 Profile Arena，不存在 CPU 兜底布局。")
	assert(false, "AutoObjectProbePrefilterGPU._pack_all_profile_samples: profile arena required")
	return _blocked_profile_sample_pack(
		"profile_arena_required", autoobjects, asset_count, voxel_size)


## Borrows the resident ProfileSample buffer and builds the per-asset coarse ranges.
func _pack_profile_container_samples(
	autoobjects: Array,
	asset_count: int,
	voxel_size: Vector3,
	runtime_profile_container: Object
) -> Dictionary:
	if not _profile_container_ready_to_borrow(runtime_profile_container):
		return _blocked_profile_sample_pack("auto_voxel_runtime_profile_container_not_ready", autoobjects, asset_count, voxel_size)

	var raw_sample_buffer = runtime_profile_container.call("get_profile_arena_buffer")
	var sample_buffer: RID = raw_sample_buffer if raw_sample_buffer is RID else RID()
	if not sample_buffer.is_valid():
		push_error("[AutoObjectProbePrefilterGPU] runtime profile container 自称就绪，但 profile_arena buffer RID 无效 —— 不上传 CPU 副本顶替。")
		assert(false, "AutoObjectProbePrefilterGPU._pack_profile_container_samples: invalid resident arena buffer RID")
		return _blocked_profile_sample_pack("missing_profile_arena_buffer", autoobjects, asset_count, voxel_size)

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
			push_error("[AutoObjectProbePrefilterGPU] 资产 %d (%s) 未解析出 profile_id —— 不用空 range 顶替。" % [asset_index, autoobject])
			assert(false, "AutoObjectProbePrefilterGPU._pack_profile_container_samples: missing profile_id for asset")
			return _blocked_profile_sample_pack("missing_profile_id_for_asset:%d" % asset_index, autoobjects, asset_count, voxel_size)
		var probe_range := _profile_container_coarse_sample_range(runtime_profile_container, profile_id)
		if probe_range.is_empty():
			push_error("[AutoObjectProbePrefilterGPU] profile_id=%d（资产 %d）在 runtime profile container 中查不到 coarse sample range。" % [
				profile_id, asset_index])
			assert(false, "AutoObjectProbePrefilterGPU._pack_profile_container_samples: missing coarse sample range")
			return _blocked_profile_sample_pack("missing_coarse_sample_range_for_profile:%d" % profile_id, autoobjects, asset_count, voxel_size)
		# ⚠ range.x 存的是 **Arena slot 索引**（= profile_index），不是采样起点：coarse 段
		# 在每个定长 slot 内恒从局部下标 0 起算，全局累计起点随扁平 buffer 一并退役。
		var slot_index := int(runtime_profile_container.call("get_profile_index_for_profile_id", profile_id))
		if slot_index < 0:
			push_error("[AutoObjectProbePrefilterGPU] profile_id=%d（资产 %d）查不到 Arena slot 索引。" % [
				profile_id, asset_index])
			assert(false, "AutoObjectProbePrefilterGPU._pack_profile_container_samples: missing arena slot index")
			return _blocked_profile_sample_pack("missing_arena_slot_for_profile:%d" % profile_id, autoobjects, asset_count, voxel_size)
		profile_ids.append(profile_id)
		range_bytes.encode_u32(asset_index * 8 + 0, slot_index)
		range_bytes.encode_u32(asset_index * 8 + 4, int(probe_range.get("count", 0)))

	var sample_record_count := _profile_container_sample_record_count(runtime_profile_container)
	return {
		"ok": true,
		"ready": true,
		"range_bytes": range_bytes,
		"total_profile_samples": sample_record_count,
		"profile_sample_records_borrowed": true,
		"profile_sample_records_buffer": sample_buffer,
		"profile_sample_source": "auto_voxel_runtime_profile_container.profile_arena",
		"profile_ids": profile_ids,
		"contract_blocked": false,
		"probe_range_capacity": range_bytes.size() / 8,
		"profile_sample_record_capacity": sample_record_count,
	}


## Builds a contract-blocked result for ProfileSample input failures.
func _blocked_profile_sample_pack(reason: String, autoobjects: Array, asset_count: int, voxel_size: Vector3) -> Dictionary:
	return {
		"ok": false,
		"ready": false,
		"reason": reason,
		"contract_blocked": true,
		"gpu_first": true,
		"cpu_fallback": false,
		"profile_sample_records_borrowed": false,
		"profile_sample_source": "none",
	}


# ---------------------------------------------------------------------------
# Result decoding
# ---------------------------------------------------------------------------

## 将 GPU 回读的锚点字节保留为 packed ivec4，并交接 GPU 驻留路由载荷。
## Dictionary 解码仅为旧调试消费者显式保留，生产 Score 路径关闭。
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
	topk_buf: RID = RID(),
	raw_anchor_count: int = -1,
	collect_cache_hit: bool = false,
	asset_stride: int = 0
) -> Dictionary:
	var anchor_stride_bytes := BufferUtils.IVEC4_BYTES # uvec4(x, y, z, reserved)
	var available_anchor_bytes := mini(anchors_bytes.size(), anchor_count * anchor_stride_bytes)
	available_anchor_bytes -= available_anchor_bytes % anchor_stride_bytes
	var available_anchor_count := mini(anchor_count, int(available_anchor_bytes / anchor_stride_bytes))
	var anchors_packed := anchors_bytes.slice(0, available_anchor_bytes).to_int32_array()
	var anchors: Array[Dictionary] = []
	if decode_anchor_dictionaries:
		anchors = anchor_dictionaries_from_packed(anchors_packed, available_anchor_count)

	var readiness := pipeline_status.duplicate(true) if not pipeline_status.is_empty() else _pipeline_readiness()
	var handoff := {
		"ok": anchor_buf.is_valid() and anchor_count_buf.is_valid() and topk_buf.is_valid(),
		"anchor_buffer_rid": anchor_buf,
		"anchor_count_buffer_rid": anchor_count_buf,
		"topk_buffer_rid": topk_buf,
		"anchor_capacity": ANCHOR_CAPACITY,
		"topk": TOPK,
		"asset_count": asset_count,
		"asset_stride": maxi(maxi(asset_stride, asset_count), 1),
		"anchor_stride_bytes": 16,
		"topk_stride_bytes": 8,
		"origin_contract": "one_origin_per_anchor",
		"producer": "AutoObjectProbePrefilterGPU",
		"owner": "AutoObjectProbePrefilterGPU",
		"gpu_first": true,
	}
	return {
		"ok": true,
		"anchors": anchors,                                           # compatibility-only Dictionary view
		"anchors_packed": anchors_packed,                              # canonical packed ivec4 debug payload
		"anchor_autoobject_topk": {},                                 # GPU internal, not read back
		"anchor_candidate_handoff": handoff,
		"anchor_count": available_anchor_count,                        # collected debug-readback count
		"raw_anchor_count": anchor_count if raw_anchor_count < 0 else raw_anchor_count,
		"anchor_count_source": "debug_readback" if debug_read_anchors else "gpu_buffer",
		"anchor_decode": "dictionary_compat" if decode_anchor_dictionaries else "packed_only",
		"collect_cache_hit": collect_cache_hit,
		"profile_probe_pack": _profile_probe_pack_summary(probe_pack),  # GPU-first probe pack contract/debug
		"target_read_buffer_source": str(target_read_buffer_summary.get("target_read_buffer_source", "none")),
		"target_read_buffer_summary": target_read_buffer_summary.duplicate(true),
		"prefilter_reason": "ok",
		"contract_blocked": false,
		"pipeline_readiness": readiness,
		"gpu_first": true,
		"cpu_fallback": false,
	}


## 显式兼容转换：将 packed ivec4 锚点物化为旧的 position-only Dictionary 数组。
## 大规模 Score 路径不调用；core anchor 调试 demo 可继续使用 result["anchors"]。
static func anchor_dictionaries_from_packed(
	anchors_packed: PackedInt32Array,
	anchor_count: int = -1
) -> Array[Dictionary]:
	var available := int(anchors_packed.size() / 4)
	var safe_count := available if anchor_count < 0 else mini(maxi(anchor_count, 0), available)
	var anchors: Array[Dictionary] = []
	anchors.resize(safe_count)
	for i in range(safe_count):
		var base := i * 4
		anchors[i] = {
			"id": i,
			"voxel_pos": Vector3i(
				anchors_packed[base],
				anchors_packed[base + 1],
				anchors_packed[base + 2]
			),
		}
	return anchors


static func raw_anchor_count_within_capacity(raw_anchor_count: int) -> bool:
	return raw_anchor_count >= 0 and raw_anchor_count <= ANCHOR_CAPACITY


static func asset_scores_buffer_byte_count(asset_stride: int) -> int:
	return ANCHOR_CAPACITY * clampi(asset_stride, 1, MAX_ASSETS) * 4


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


## 在不派发任何 prefilter 工作的前提下编译完整 shader 家族。与 VoxelPlacementGenerator 的
## prepare_placement_pipeline() 对称：_load_shaders() 本身在 run_probe_prefilter() 里，
## 虽有 kernel 复用守卫，但"编译那一次"落在用户的第一次交互上。场景 bootstrap 调本方法把它前移。
## runtime_profile_container 传法与 run_probe_prefilter 一致（同一 RenderingDevice）。
func prepare_prefilter_pipeline(runtime_profile_container: Object = null) -> Dictionary:
	_repair_soft_reloaded_members()
	log_name = "AutoObjectProbePrefilterGPU"
	if runtime_profile_container != null:
		if not _attach_runtime_profile_container_device(runtime_profile_container):
			return {"ok": false, "reason": "auto_voxel_runtime_profile_container_not_ready"}
	elif not ensure_device(true, true):
		return {"ok": false, "reason": "missing_rendering_device"}
	_load_shaders()
	var ready := _pipeline_rids_ready()
	return {
		"ok": ready,
		"reason": "ok" if ready else "prefilter_shader_pipeline_not_ready",
		"pipeline_readiness": _pipeline_readiness(),
	}


## 加载并编译所有计算着色器，同时创建对应管线 RID。
func _load_shaders() -> void:
	_kernel_collect = _ensure_kernel(
		_kernel_collect, "res://shaders/collect_sv_anchors.glsl", COLLECT_PUSH, "collect_sv_anchors")
	_kernel_anchor_finalize = _ensure_kernel(
		_kernel_anchor_finalize, "res://shaders/prefilter_anchor_dispatch_finalize.glsl",
		ANCHOR_FINALIZE_PUSH, "prefilter_anchor_dispatch_finalize")
	_kernel_score = _ensure_kernel(
		_kernel_score, "res://shaders/score_anchor_asset_probes.glsl", SCORE_PUSH, "score_anchor_asset_probes")
	_kernel_topk = _ensure_kernel(
		_kernel_topk, "res://shaders/select_anchor_topk.glsl", TOPK_PUSH, "select_anchor_topk")


## 复用已编译的 kernel；缺失或编译失败时重建（失败的 kernel 由随后的 _free_gpu 整体清理）。
func _ensure_kernel(kernel: ComputeKernel, shader_path: String, push_schema: Array, label: String) -> ComputeKernel:
	if kernel != null and kernel.is_valid():
		return kernel
	return ComputeKernel.create(self, shader_path, push_schema, label)


## 检查核心管线（collect/finalize/score/topk）的 RID 是否全部有效。
func _pipeline_rids_ready() -> bool:
	var core_ready := (
		ComputeKernel.ready(_kernel_collect)
		and ComputeKernel.ready(_kernel_anchor_finalize)
		and ComputeKernel.ready(_kernel_score)
		and ComputeKernel.ready(_kernel_topk)
	)
	return core_ready


## 返回每个 Pass 的 shader/pipeline 有效性状态字典，用于调试和错误报告。
func _pipeline_readiness() -> Dictionary:
	var collect := _pipeline_pass_readiness(_kernel_collect)
	var anchor_finalize := _pipeline_pass_readiness(_kernel_anchor_finalize)
	var score := _pipeline_pass_readiness(_kernel_score)
	var topk := _pipeline_pass_readiness(_kernel_topk)
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
func _pipeline_pass_readiness(kernel: ComputeKernel) -> Dictionary:
	var shader_valid := kernel != null and kernel.shader.is_valid()
	var pipeline_valid := kernel != null and kernel.pipeline.is_valid()
	return {
		"shader_rid_valid": shader_valid,
		"pipeline_rid_valid": pipeline_valid,
		"ready": shader_valid and pipeline_valid,
	}


## 释放所有 GPU 资源并丢弃 kernel（其 shader/pipeline RID 已随 dispose 回收）。
func _free_gpu() -> void:
	dispose()
	_kernel_collect = null
	_kernel_anchor_finalize = null
	_kernel_score = null
	_kernel_topk = null


## dispose 完成后清空驻留 anchor handoff 的 RID 引用。
func _on_after_dispose() -> void:
	# 池内物理资源登记在 owner 的 RDGPool.POOL_SCOPE 下，刚才的 gc_all() 已经把它们释放了 ——
	# 这里只能**丢引用**，不能再调 _rdg_pool.dispose()（那会对已失效的 RID 再 release 一次；
	# RID.is_valid() 只看 id 非零，查不出来）。本类不向池 acquire，丢掉的池本就是空的。
	_rdg_pool = null
	_resident_anchor_buf = RID()
	_resident_anchor_count_buf = RID()
	_resident_topk_buf = RID()
	_resident_asset_scores_buf = RID()
	_resident_asset_stride = 0
	_resident_collect_cache_key = {}


func _release_resident_collect_cache() -> void:
	for rid in [_resident_anchor_buf, _resident_anchor_count_buf]:
		if rid.is_valid():
			release_rid(rid)
	_resident_anchor_buf = RID()
	_resident_anchor_count_buf = RID()
	_resident_collect_cache_key = {}


# ⚠ 这里曾有 `_release_resident_anchor_handoff()`：把四条常驻缓冲当作一组释放。
# 它**全仓零调用点**，是一条从未被执行过、因而也从未被验证过的释放路径，已删除
# （《AutoVolume 公用体积基类计划》V4）。
#
# 别照着它重建「统一释放四条」的入口——四条的生命周期本来就**不同步**：
#   * `_resident_anchor_buf` / `_resident_anchor_count_buf` 由 **collect 缓存键**驱动
#     （grid / tile_grid / dirty_epoch / min_target_interest / target_revision），
#     缓存未命中时经 `_release_resident_collect_cache()` 重建；
#   * `_resident_asset_scores_buf` / `_resident_topk_buf` 只在 dispose 时释放。
# 把四条当一组释放会在缓存命中的正常路径上白扔掉后两条，下一次 run 重新分配。


## 逐 (anchor, asset) 探针分的调试回读——**粗筛门 `min_prefilter_score` 的输入**。
##
## 为什么需要它：粗筛不通过的锚点在细筛侧只留下 `-INF` 占位（「该资产不在 top-K 槽」），
## 从那里分不出「探针分确实低」与「门限设高了」。分数本身一直常驻在
## `_resident_asset_scores_buf`（score pass 写 b7 / top-K pass 读 b0，`SCOPE_PERSISTENT`，
## 只在 dispose 释放），此前只是没有取用口。
##
## ⚠ 入参是 **source anchor index**（collect 的 atomicAdd 追加序），不是评分模型里的锚点序。
## 模型那一侧按线性体素索引重排过，两者经 `model.source_anchor_indices[model_index]` 换算——
## 直接拿模型序来读会读到另一个锚点的分数，且看不出错。
##
## 只读该锚点那一条（stride × 4 字节），不整块回读。
func debug_read_asset_scores(source_anchor_index: int) -> Dictionary:
	_repair_soft_reloaded_members()
	if _rd == null or not _resident_asset_scores_buf.is_valid():
		return {"ok": false, "reason": "asset_scores_buffer_unavailable"}
	var stride := _resident_asset_stride
	if stride <= 0:
		return {"ok": false, "reason": "asset_stride_unknown"}
	if source_anchor_index < 0 or source_anchor_index >= ANCHOR_CAPACITY:
		return {"ok": false, "reason": "source_anchor_index_out_of_range",
			"source_anchor_index": source_anchor_index, "anchor_capacity": ANCHOR_CAPACITY}
	var byte_offset := source_anchor_index * stride * 4
	var bytes := _rd.buffer_get_data(_resident_asset_scores_buf, byte_offset, stride * 4)
	if bytes.size() < stride * 4:
		return {"ok": false, "reason": "asset_scores_readback_short",
			"expected_bytes": stride * 4, "actual_bytes": bytes.size()}
	return {
		"ok": true,
		"source_anchor_index": source_anchor_index,
		"asset_stride": stride,
		"scores": bytes.to_float32_array(),
		"min_prefilter_score": min_prefilter_score,
		"topk": TOPK,
	}


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
			"profile_sample_records_borrowed": false,
			"profile_sample_source": "none",
			"runtime_read_source": "none",
			"borrowed_buffers": [],
			"profile_ids": [],
			"total_profile_samples": 0,
		}
	var borrowed := bool(probe_pack.get("profile_sample_records_borrowed", false))
	var borrowed_buffers: Array[String] = []
	if borrowed:
		borrowed_buffers.append("profile_arena")
	var ready := bool(probe_pack.get("ready", false))
	var reason := "ready" if ready else str(probe_pack.get("reason", "profile_sample_pack_not_ready"))
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
		"profile_sample_records_borrowed": borrowed,
		"profile_sample_source": str(probe_pack.get("profile_sample_source", "none")),
		"runtime_read_source": "gpu_profile_buffers" if borrowed else ("transient_descriptor_profile_samples" if ready else "none"),
		"borrowed_buffers": borrowed_buffers,
		"profile_ids": profile_ids,
		"total_profile_samples": int(probe_pack.get("total_profile_samples", 0)),
	}


## 判断给定原因字符串是否属于合约阻塞级别的错误。
func _is_contract_blocked_reason(reason: String) -> bool:
	if reason in [
		"missing_rendering_device",
		"auto_voxel_runtime_profile_container_not_ready",
		"prefilter_shader_pipeline_not_ready",
		"missing_profile_sample_records_buffer",
		"profile_sample_pack_not_ready",
		# GPU 侧的硬失败：以前这些 reason 不在阻塞名单里，_empty_result 会以 ok=true
		# 返回一份空锚点结果，调用方把"dispatch 失败"当成"这一轮没有锚点"继续跑。
		"profile_sample_pack_failed",
		"asset_count_exceeds_capacity",
		"dirty_worklist_handoff_contract_mismatch",
		"dirty_worklist_rendering_device_mismatch",
		"prefilter_work_buffer_allocation_failed",
		"collect_anchor_dispatch_bounds_exceeded",
		"score_topk_compute_list_begin_failed",
		"anchor_count_invariant_violated",
		"resident_scene_field_pair_incomplete",
		"scene_field_cpu_source_size_mismatch",
		"scene_field_cpu_upload_failed",
		"scene_field_buffers_not_ready",
	]:
		return true
	return reason.begins_with("missing_profile_id_for_asset:") \
		or reason.begins_with("missing_probe_range_for_profile:") \
		or reason.begins_with("missing_coarse_sample_range_for_profile:") \
		or reason.begins_with("missing_profile_samples_for_asset:") \
		or reason.begins_with("resident_target_read_buffer_") \
		or reason.begins_with("target_read_buffer_")


## 从探针打包字典中提取管线可用性状态，若无则重新查询。
func _pipeline_readiness_from_probe_pack(probe_pack: Dictionary) -> Dictionary:
	var raw_status = probe_pack.get("pipeline_readiness", {})
	if raw_status is Dictionary and not (raw_status as Dictionary).is_empty():
		return (raw_status as Dictionary).duplicate(true)
	return _pipeline_readiness()


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


## 从 runtime_profile_container 获取 RenderingDevice 并附加到本类。
func _attach_runtime_profile_container_device(runtime_profile_container: Object) -> bool:
	if not _profile_container_ready_to_borrow(runtime_profile_container):
		return false
	var profile_rd := rendering_device_of(runtime_profile_container)
	if profile_rd == null:
		return false
	return attach_rendering_device(profile_rd, false)


## Checks that the runtime container owns a valid resident ProfileSample buffer.
func _profile_container_ready_to_borrow(runtime_profile_container: Object) -> bool:
	if runtime_profile_container == null:
		return false
	if not runtime_profile_container.has_method("is_runtime_ready"):
		return false
	if not bool(runtime_profile_container.call("is_runtime_ready")):
		return false
	if not runtime_profile_container.has_method("get_profile_arena_buffer"):
		return false
	if not runtime_profile_container.has_method("get_profile_index_for_profile_id"):
		return false
	var raw_arena_buffer = runtime_profile_container.call("get_profile_arena_buffer")
	if not raw_arena_buffer is RID:
		return false
	var arena_buffer: RID = raw_arena_buffer
	return arena_buffer.is_valid()


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


## Returns the coarse ProfileSample range for a registered profile.
func _profile_container_coarse_sample_range(runtime_profile_container: Object, profile_id: int) -> Dictionary:
	if runtime_profile_container == null or not runtime_profile_container.has_method("get_coarse_sample_range_for_profile_id"):
		return {}
	var raw_range = runtime_profile_container.call("get_coarse_sample_range_for_profile_id", profile_id)
	if raw_range is Dictionary:
		return (raw_range as Dictionary).duplicate(true)
	return {}


## 常驻采样的有效条数。扁平 profile_sample_records 退役后不再有"整表记录数"这种东西，
## 改报 Arena 的有效采样总量（各 slot coarse+fine 之和），仍是同一语义的可观测数字。
func _profile_container_sample_record_count(runtime_profile_container: Object) -> int:
	if runtime_profile_container == null or not runtime_profile_container.has_method("get_profile_arena_summary"):
		return 0
	var raw_summary = runtime_profile_container.call("get_profile_arena_summary")
	if not raw_summary is Dictionary:
		return 0
	return int((raw_summary as Dictionary).get("valid_sample_count", 0))


## 确保 float 数组长度不低于 expected，不足时用零补齐后返回副本。


## 将 CPU float fallback 量化为与 resident scene field 相同的 low-byte u32 口径。
func _pack_unorm8_u32_bytes(values: PackedFloat32Array, voxel_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(voxel_count, 0) * 4)
	for i in range(voxel_count):
		var value := values[i] if i < values.size() else 0.0
		bytes.encode_u32(i * 4, BufferUtils.quantize_unorm8(value))
	return bytes


## score shader 直接读取常驻量化 scene complexity/collision，避免每 run 编译 pack shader、
## 创建 voxel_count*8 的 merged buffer 并同步。无 resident 场的窄测试路径保留 CPU 量化上传。
func _scene_field_buffer_pack(sv: Dictionary, voxel_count: int) -> Dictionary:
	var raw_complexity_rid = sv.get("resident_complexity_field_read_rid", RID())
	var raw_collision_rid = sv.get("resident_collision_field_read_rid", RID())
	var resident_complexity: RID = raw_complexity_rid if raw_complexity_rid is RID else RID()
	var resident_collision: RID = raw_collision_rid if raw_collision_rid is RID else RID()
	if resident_complexity.is_valid() and resident_collision.is_valid():
		track_borrowed_rid(resident_complexity, KIND_BUFFER, SCOPE_FRAME, "scene_field:complexity")
		track_borrowed_rid(resident_collision, KIND_BUFFER, SCOPE_FRAME, "scene_field:collision")
		return {
			"ready": true,
			"source": "resident_quantized_fields",
			"complexity_buffer": resident_complexity,
			"collision_buffer": resident_collision,
		}
	if resident_complexity.is_valid() != resident_collision.is_valid():
		push_error("[AutoObjectProbePrefilterGPU] resident scene field pair is incomplete (complexity=%s, collision=%s)" % [
			resident_complexity.is_valid(), resident_collision.is_valid()])
		assert(false, "AutoObjectProbePrefilterGPU._scene_field_buffer_pack: resident scene field pair incomplete")
		return {"ready": false, "reason": "resident_scene_field_pair_incomplete"}

	# CPU 量化上传（无 resident 场的窄测试路径）：字段长度必须与 voxel_count 对齐。
	# 空数组 = 该场整体为 0，是合法输入；非空但长度不符说明来自另一套网格，
	# 旧行为由 pad_float_array 悄悄补零，会让评分读到错位的场。
	var raw_complexity = sv.get("complexity_field", PackedFloat32Array())
	var raw_collision = sv.get("collision_field", PackedFloat32Array())
	var complexity_size: int = raw_complexity.size() if raw_complexity is PackedFloat32Array else -1
	var collision_size: int = raw_collision.size() if raw_collision is PackedFloat32Array else -1
	if complexity_size < 0 or collision_size < 0 \
			or (complexity_size > 0 and complexity_size != voxel_count) \
			or (collision_size > 0 and collision_size != voxel_count):
		push_error("[AutoObjectProbePrefilterGPU] CPU scene field 长度与网格不符（voxel_count=%d，complexity=%d，collision=%d）—— 不补零对齐。" % [
			voxel_count, complexity_size, collision_size])
		assert(false, "AutoObjectProbePrefilterGPU._scene_field_buffer_pack: cpu scene field size mismatch")
		return {"ready": false, "reason": "scene_field_cpu_source_size_mismatch"}

	var complexity_values := VoxelGeneral.pad_float_array(raw_complexity, voxel_count)
	var collision_values := VoxelGeneral.pad_float_array(raw_collision, voxel_count)
	var complexity_buffer := storage_buffer_from_bytes(
		_pack_unorm8_u32_bytes(complexity_values, voxel_count),
		SCOPE_FRAME,
		"scene_complexity_unorm8_u32"
	)
	var collision_buffer := storage_buffer_from_bytes(
		_pack_unorm8_u32_bytes(collision_values, voxel_count),
		SCOPE_FRAME,
		"scene_collision_unorm8_u32"
	)
	if not complexity_buffer.is_valid() or not collision_buffer.is_valid():
		push_error("[AutoObjectProbePrefilterGPU] CPU scene field 上传失败（complexity=%s, collision=%s）。" % [
			complexity_buffer.is_valid(), collision_buffer.is_valid()])
		assert(false, "AutoObjectProbePrefilterGPU._scene_field_buffer_pack: cpu scene field upload failed")
	return {
		"ready": complexity_buffer.is_valid() and collision_buffer.is_valid(),
		"reason": "ok" if complexity_buffer.is_valid() and collision_buffer.is_valid() else "scene_field_cpu_upload_failed",
		"source": "cpu_float_fallback",
		"complexity_buffer": complexity_buffer,
		"collision_buffer": collision_buffer,
	}


## 组装目标评分的 GPU 读取缓冲区数据包：仅接受常驻 GPU 交接（借用外部持有的
## target_field 缓冲）；借用失败即阻断——无 CPU 字节上传回退。
func _target_read_buffer_pack(target_read_buffers: Dictionary, voxel_count: int) -> Dictionary:
	# 常驻 target 场已与其余三层同格式：packed rgba8，每体素 1 个 u32（4 B）。
	# ⚠ 旧签名传的是 expected_floats（= voxel_count * 4，vec4 展开的 float 数），下游同时用它
	# 推场字节（*4）和碰撞字节（/4 还原体素数）。把它单纯改小会让碰撞期望变成 1/4 而借用失败，
	# 所以这里改传 voxel_count，两个期望在下游各自显式导出。
	var safe_voxel_count := maxi(voxel_count, 1)
	var borrowed := _borrowed_target_read_buffer_pack(target_read_buffers, safe_voxel_count)
	if bool(borrowed.get("ready", false)):
		return borrowed
	return _blocked_target_read_buffer_pack(
		str(borrowed.get("reason", "resident_handoff_absent")),
		safe_voxel_count
	)


## 尝试从 target_read_buffers 字典借用已驻留的目标场缓冲区 RID（解析/校验核心
## 共享自 TargetReadBufferBorrow；成功字典键集留在本文件，契约测试逐字断言）。
func _borrowed_target_read_buffer_pack(target_read_buffers: Dictionary, voxel_count: int) -> Dictionary:
	var handoff_summary: Dictionary = target_read_buffers.get("resident_target_read_buffer_handoff_summary", {})
	var resolved := TargetReadBufferBorrow.resolve(
		target_read_buffers,
		voxel_count * 4,   # packed rgba8：每体素 1 个 u32
		_rd,
		["target_field_buffer", "resident_target_field_buffer"],
		SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count),
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
		"target_revision": int(target_read_buffers.get("target_revision", handoff_summary.get("target_revision", -1))),
		"target_field_buffer": resolved.get("field_buffer", RID()),
		"target_collision_buffer": resolved.get("collision_buffer", RID()),
		"target_field_bytes": PackedFloat32Array(),
		"target_field_byte_count": int(resolved.get("field_byte_count", 0)),
		"expected_byte_count": voxel_count * 4,
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
	voxel_count: int
) -> Dictionary:
	var reason := "%s_gpu_resident_required" % borrow_reason
	push_error("[AutoObjectProbePrefilterGPU] target read buffers require a resident GPU handoff: %s" % reason)
	assert(false, "AutoObjectProbePrefilterGPU._blocked_target_read_buffer_pack: resident target handoff unavailable")
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
		"expected_byte_count": voxel_count * 4,
		"target_field_format": "rgba8_unorm",
		"target_field_stride_bytes": 4,
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
		"target_revision": int(pack.get("target_revision", -1)),
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


## 从 autoobject 中读取 semantic_probe_density，默认返回 1.0。
static func _semantic_probe_density(autoobject: Object) -> float:
	if autoobject != null and VariantUtils.has_property(autoobject, "semantic_probe_density"):
		return float(autoobject.get("semantic_probe_density"))
	return 1.0
