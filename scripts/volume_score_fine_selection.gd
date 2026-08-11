@tool
class_name VolumeScoreFineSelection
extends RefCounted

## placement-score-3d 细筛评分 runner + 结果模型（demo 场景真实链重设计 批 3b）。
##
## 编排一次 anchor-origin residual-gain 细筛（S7）：吃真实 S6 常驻 anchor handoff、
## S5 常驻 target 读缓冲、S4 committer 常驻场（经 SPA BlendSV 工作对副本——stamp 写
## 在副本上，逐次评分幂等，committed SV 不被观察运行污染），调 VPG.run_multi_asset
## 并把 debug_read_fine_candidates 回读整理成按体素排序的确定性结果模型。
## golden v2 文本格式器住这里（tools/golden_snapshot_check.js 消费，行格式逐字冻结）。

const VoxelPlacementGenerator := preload("res://scripts/voxel_placement_generator.gd")
const SceneVoxelTileStoreScript := preload("res://scripts/scene_voxel_tile_store.gd")
const ScoreTimingProfilerScript := preload("res://scripts/utils/score_timing_profiler.gd")

const ANCHOR_SOURCE_INDEX_BITS := 16
const ANCHOR_SOURCE_INDEX_MASK := (1 << ANCHOR_SOURCE_INDEX_BITS) - 1
const CANDIDATE_RECORD_BYTES := 64
const CANDIDATE_SCORE_OFFSET := 12
const CANDIDATE_ASSET_OFFSET := 20
const CANDIDATE_ROTATION_OFFSET := 24
const CANDIDATE_VALID_OFFSET := 52

## VPG 实例跨 run 缓存：shader/pipeline PERSISTENT 常驻（run 末尾只清 FRAME/PASS），
## 复用实例即免每 run ~18ms 的 8-shader 重编（沿袭 demo 优化 _cached_vpg 的意图）。
## 设备跟 profile 容器走（VPG attach 容器设备），生命周期必须 ≤ env 的 SPA/容器——
## demo 在 env 失效/PREDELETE 时先 dispose 本 runner 再 dispose env。
var _vpg = null   # VoxelPlacementGenerator


## 释放自建 VPG（借用的 SPA/committer/容器/handoff 概不释放）。
func dispose() -> void:
	if _vpg != null and _vpg.has_method("dispose"):
		_vpg.dispose()
	_vpg = null


## 跑一轮细筛并返回结果模型。inputs（全部借用）：
##   spa:                ScenePlacementActor（env 持有；BlendSV 合成 + 容器来源）
##   committer:          SceneVoxelCommitter（常驻场所有者）
##   sv:                 committer.get_sv() 快照（grid_size/voxel_size/grid_origin/tile_grid_size）
##   target_read_buffers: S5 prepare_target_read_buffers_from_common_gpu 的完整返回 dict
##   prefilter_result:   S6 run_autoobject_prefilter 结果。GPU 细筛只吃
##                       anchor_candidate_handoff 的常驻 RID —— anchors_packed（CPU 锚点
##                       位置回读）是**可选**输入：prefilter 默认 debug_read_anchors=false
##                       时它为空，本 runner 照常发起 GPU 评分，CPU 模型改为按需物化
##                       （见 materialize_cpu_anchor_model —— 那不是"省掉一次回读"，
##                       只是把它挪到真正需要坐标的消费方那一刻）。调用方若确实开了
##                       回读，原有的 anchor_count / packed 一致性校验语义原样保留。
##   committed_resident_fields: 可选 {complexity:RID, collision:RID}；调用方若已在
##                       prefilter 阶段确保并验证常驻场，直接借用，避免重复 ensure
##   descriptors:        Array — 与 SPA 注册序一致的 AssetDescriptor
##   profile_ids:        Array[int] — env 注册时返回的 id，与 descriptors 同序
##   terrain_height:     PackedFloat32Array — S0 地形高度场（grid_size.x² 、z*w+x 索引）。
##                       TargetSV 烘焙 height_relative=true：体素 Y 是地形表面相对值，
##                       世界坐标必须加地形项（canonical=TargetSVSetup.voxel_to_world 同款），
##                       缺省空数组=平面网格退化（仅无地形环境合法）
##   settings:           {rotation_slots:int, profile_score_timing:bool}
## 返回 {ok, reason, ...结果模型（见 _build_model）}；失败 push_warning + ok:false，
## 不留任何半初始化 GPU 状态（blend 对总在返回前 release）。
func run(inputs: Dictionary) -> Dictionary:
	var spa = inputs.get("spa")
	var committer = inputs.get("committer")
	var sv: Dictionary = inputs.get("sv", {})
	var target_read_buffers: Dictionary = inputs.get("target_read_buffers", {})
	var prefilter_result: Dictionary = inputs.get("prefilter_result", {})
	var descriptors: Array = inputs.get("descriptors", [])
	var profile_ids: Array = inputs.get("profile_ids", [])
	var settings: Dictionary = inputs.get("settings", {})
	var profile_timing := bool(settings.get("profile_score_timing", false))
	var full_candidate_diagnostics := bool(settings.get("full_candidate_diagnostics", false))
	var outer_profiler := ScoreTimingProfilerScript.new(profile_timing, "volume_score_fine_selection_wall")
	outer_profiler.mark("run_start")
	if spa == null or committer == null or sv.is_empty():
		return _fail_hard("missing_stage_env_inputs", "spa=%s committer=%s sv_keys=%d —— 调用方没有传齐 stage env" % [
			str(spa), str(committer), sv.size()])
	if descriptors.is_empty() or descriptors.size() != profile_ids.size():
		return _fail_hard("descriptor_profile_id_mismatch", "descriptors=%d profile_ids=%d —— 两者必须同序等长，否则 asset_index 与 profile_id 全部错配" % [
			descriptors.size(), profile_ids.size()])
	var handoff: Dictionary = prefilter_result.get("anchor_candidate_handoff", {})
	if not bool(handoff.get("ok", false)):
		return _fail("anchor_candidate_handoff_not_ok:%s" % str(prefilter_result.get("prefilter_reason", "?")))
	var anchors_packed := _anchor_payload_as_packed(prefilter_result.get("anchors_packed", PackedInt32Array()))
	if anchors_packed.is_empty():
		anchors_packed = _anchor_payload_as_packed(prefilter_result.get("anchors", []))
	# CPU anchor 载荷是可选输入。生产 prefilter 默认 debug_read_anchors=false（不回读
	# 那 65536×16B 的位置数组），此时 anchors_packed 为空、prefilter 声明的 anchor_count
	# 也是 0 —— 这是正常的 GPU-only 形态，不是"prefilter 少给了锚点"，因此下面这两条
	# 校验只在**调用方确实拿到了回读载荷**时才成立（anchor_count_source=="debug_readback"
	# 是 prefilter 既有的自述字段；旧的 Array[Dictionary] 调试调用方则由非空 packed 认出）。
	var anchor_payload_readback := not anchors_packed.is_empty() \
		or str(prefilter_result.get("anchor_count_source", "")) == "debug_readback"
	var packed_anchor_count := int(anchors_packed.size() / 4)
	var reported_anchor_count := int(prefilter_result.get("anchor_count", packed_anchor_count))
	var anchor_count := reported_anchor_count
	if anchor_payload_readback:
		# 声明的锚点数超过实际 packed 载荷时不再静默截断：mini() 会让排序/建模只覆盖
		# 前一部分锚点，剩下的静默消失，看上去像"prefilter 少给了锚点"。
		if reported_anchor_count > packed_anchor_count:
			return _fail_hard("anchor_count_exceeds_packed_payload",
				"prefilter 声明 anchor_count=%d 但 anchors_packed 只有 %d 个（%d ivec4 words）" % [
					reported_anchor_count, packed_anchor_count, anchors_packed.size()])
		if anchor_count <= 0:
			return _fail("prefilter_returned_zero_anchors")
	if not bool(target_read_buffers.get("resident_target_read_buffer_handoff", false)):
		return _fail_hard("target_read_buffers_not_resident",
			"S5 必须以常驻 GPU 交接提供 target 读缓冲（resident_target_read_buffer_handoff=false）")

	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var voxel_size: Vector3 = sv.get("voxel_size", Vector3.ONE)
	var grid_origin: Vector3 = sv.get("grid_origin", Vector3.ZERO)
	var container = spa.get_runtime_profile_container()
	if container == null or not container.is_runtime_ready():
		return _fail("runtime_profile_container_not_ready")
	# ⚠ 零锚点必须在**进 VPG 之前**判掉，不能等 run_multi_asset 回来再判。
	# VPG 的 _finish_fine_candidates_only 会执行
	# buffer_get_data(winner_buffer, 0, live_anchor_count * STRIDE * 16)；live=0 时 size
	# 算出来是 0，而 RenderingDevice::buffer_get_data 把 size==0 解释为**读整个缓冲**
	# （rendering_device.cpp: `if (!p_size) { p_size = buffer->size; }`），于是返回
	# anchor_capacity*64 ≈ 4 MiB，撞上 VPG 的字节数校验 → push_error + assert（编辑器是
	# debug 构建，assert 会中断执行），本 runner 再补一条 fine_score_output_missing。
	# 于是"这块区域没有 TargetSV 内容"这种完全合法的输入被报成两次硬错误。
	# 判空只需要 anchor_count 缓冲的 4 字节（与被砍掉的 1 MB anchors_packed 回读不是一回事，
	# 代价可忽略），事实源与 VPG fine 段读的是同一个常驻缓冲，判定逐字等价。
	# handoff 就绪性：collect 段在上游 prefilter 里已经派发并结束 compute list（buffer_get_data
	# 自带 flush+stall），此处只借读，不持有也不释放任何 RID；blend 工作对尚未合成，
	# 因此零锚点提前返回时没有任何待释放的 GPU 状态（原来的返回时机也是如此）。
	if not anchor_payload_readback:
		var count_probe := read_resident_anchor_count(_container_rendering_device(container), handoff)
		if not bool(count_probe.get("ok", false)):
			return _fail_hard(
				str(count_probe.get("reason", "anchor_count_probe_failed")),
				str(count_probe.get("detail", "")))
		anchor_count = int(count_probe.get("count", 0))
		if anchor_count <= 0:
			return _fail("prefilter_returned_zero_anchors")
	outer_profiler.mark("inputs_contract")

	# Score is read-only. Without BrushSV content the committed resident pair is
	# already the exact CurrentSV input, so avoid allocating/composing an 8 MiB
	# BlendSV copy. Brush content keeps the existing compose-and-release path.
	var resident_field_mode := "caller_handoff"
	var committed_fields: Dictionary = inputs.get("committed_resident_fields", {})
	var committed_complexity: RID = committed_fields.get("complexity", RID())
	var committed_collision: RID = committed_fields.get("collision", RID())
	if not committed_complexity.is_valid() or not committed_collision.is_valid():
		resident_field_mode = "spa_tile_store_ensure"
		spa.ensure_svtile_gpu_ready(false)
		committed_complexity = spa.get_svtile_gpu_buffer(
			SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER)
		committed_collision = spa.get_svtile_gpu_buffer(
			SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)
	if not committed_complexity.is_valid() or not committed_collision.is_valid():
		return _fail_hard("committer_resident_fields_unavailable",
			"mode=%s complexity_valid=%s collision_valid=%s —— committer 常驻场是 CurrentSV 的唯一来源" % [
				resident_field_mode, committed_complexity.is_valid(), committed_collision.is_valid()])
	outer_profiler.mark("resident_fields")
	var score_complexity := committed_complexity
	var score_collision := committed_collision
	var blend_active: bool = spa.has_method("has_brush_sv_content") and bool(spa.call("has_brush_sv_content"))
	if blend_active:
		var blend: Dictionary = spa.compose_blend_sv_fields(committed_complexity, committed_collision)
		if blend.is_empty():
			return _fail_hard("blend_sv_compose_failed",
				"SPA 报告有 BrushSV 内容但 compose_blend_sv_fields 返回空 —— 不得退回 committed SV 打分（那会漏掉笔刷内容）")
		score_complexity = blend.get("complexity_field_buffer", RID())
		score_collision = blend.get("collision_field_buffer", RID())
		if not score_complexity.is_valid() or not score_collision.is_valid():
			spa.release_blend_sv_fields()
			return _fail_hard("blend_sv_field_rid_invalid",
				"compose_blend_sv_fields 返回的读对 RID 非法 complexity_valid=%s collision_valid=%s" % [
					score_complexity.is_valid(), score_collision.is_valid()])
	outer_profiler.mark("blend_or_direct_current")

	var asset_defs: Array = []
	for i in range(descriptors.size()):
		asset_defs.append({
			"descriptor": descriptors[i],
			"asset_index": i,
			"profile_id": int(profile_ids[i]),
		})

	var run_settings := {
		"rotation_slots": int(settings.get("rotation_slots", 12)),
		"target_read_buffers": target_read_buffers,
		"anchor_candidate_handoff": handoff,
		"auto_voxel_runtime_profile_container": container,
		"complexity_field_buffer_rid": score_complexity,
		"collision_field_buffer_rid": score_collision,
		"complexity_field_buffer_borrowed": true,
		"collision_field_buffer_borrowed": true,
		"complexity_field_buffer_owner": "ScenePlacementActor",
		"collision_field_buffer_owner": "ScenePlacementActor",
		"gpu_state_chain_source": "spa_blend_sv_composed_field_volume_score_observation" if blend_active else "scene_voxel_committer_resident_field_volume_score_observation",
		"execution_mode": "fine_candidates_only",
		"debug_read_fine_candidates": false,
		"read_fine_candidate_bytes": full_candidate_diagnostics,
		# VPG 默认只发布常驻 winner buffer 的借用 RID（fine_score_handoff），不回读。
		# 这里显式 opt-in 是因为下面的 _build_model 要构建 CPU 结果模型——目前 demo 的
		# 可视化/HUD/点选全部读它。统一 GPU 点选与 GPU 直提渲染落地后，这一行改成 false，
		# 消费方转而借 handoff 的 RID，Score 热路径的结果回读即归零。
		"read_fine_winner_bytes": true,
		"score_timing_profile": profile_timing,
		"score_timing_label": "volume_score",
	}
	# 物理可行性门透传（Place/Score 同门限契约；键缺省 = VPG 默认 -1 关门，旧调用方行为不变）
	for limit_key in ["collision_limit", "clearance_limit"]:
		if settings.has(limit_key):
			run_settings[limit_key] = settings[limit_key]
	if _vpg == null:
		_vpg = VoxelPlacementGenerator.new()
	if profile_timing:
		ScoreTimingProfilerScript.reset_aggregate()
	outer_profiler.mark("asset_setup")
	var t0_usec := Time.get_ticks_usec()
	var out: Dictionary = _vpg.run_multi_asset(
		PackedFloat32Array(), PackedFloat32Array(), asset_defs,
		grid_size, voxel_size, grid_origin, run_settings)
	var vpg_elapsed_ms := float(Time.get_ticks_usec() - t0_usec) / 1000.0
	outer_profiler.mark("vpg_fine_only")
	if blend_active:
		spa.release_blend_sv_fields()
	outer_profiler.mark("release_current_fields")
	if profile_timing:
		print(ScoreTimingProfilerScript.format_aggregate("volume-score fine-selection"))

	var contract: Dictionary = out.get("gpu_runtime_profile_contract", {})
	# 「有输出」现在包含常驻交接：零回读的 Score 只回 fine_score_handoff，三个 CPU 字节键
	# 都不存在也是合法结果，不能再当成 VPG 没产出。
	var fine_handoff: Dictionary = out.get("fine_score_handoff", {})
	var fine_handoff_ok := bool(fine_handoff.get("ok", false)) \
		and (fine_handoff.get("fine_winner_buffer_rid", RID()) as RID).is_valid()
	if not fine_handoff_ok \
			and out.get("fine_winner_bytes") == null \
			and out.get("fine_candidate_bytes") == null \
			and out.get("fine_candidates") == null:
		return _fail_hard("fine_score_output_missing",
			"VPG fine_candidates_only 既未返回常驻交接也未返回任何细筛输出 contract_reason=%s ok=%s" % [
				str(contract.get("reason", "?")), str(out.get("ok", "?"))])
	# 锚点数在 run 之前已由 anchor_count 缓冲判过（零锚点根本走不到这里）。这里取 VPG
	# 自述的 live_anchor_count 只是为了把 CPU 物化的条数与 VPG 实际解码的条数绑成同一个
	# 数；缺键（-1）时按需回读会自己重读 count 缓冲，语义不变。
	var terrain_height = inputs.get("terrain_height", PackedFloat32Array())
	var live_anchor_count := int(
		(out.get("anchor_fine_contract", {}) as Dictionary).get("live_anchor_count", -1))
	var model := _build_model(
		out, anchors_packed, anchor_count, int(handoff.get("topk", 4)),
		descriptors.size(), grid_size, voxel_size, grid_origin,
		vpg_elapsed_ms,
		terrain_height)
	# 常驻 Fine 交接原样透传给调用方（SPA 据此发布只读 handoff 与 score_revision）。
	# 借用语义随之传递：拿到 RID 的人不得 free，释放归 VPG。
	if fine_handoff_ok:
		model["fine_score_handoff"] = fine_handoff
	if not anchor_payload_readback:
		_attach_cpu_anchor_source(model, handoff, live_anchor_count, container, terrain_height)
	outer_profiler.mark("build_model")
	if profile_timing:
		var wall_report: Dictionary = outer_profiler.build_report(false)
		wall_report["current_field_mode"] = "blend_sv" if blend_active else "committed_sv_direct"
		wall_report["resident_field_mode"] = resident_field_mode
		wall_report["vpg"] = out.get("score_timing_profile", {})
		model["score_timing_profile"] = wall_report
		print(outer_profiler.format_report())
	return model


## 软失败：本轮没有可打分的输入（合法空结果，例如 prefilter 一个锚点都没给出，
## 或上游 handoff 自己已经报过错）。只提示，不中断。
func _fail(reason: String) -> Dictionary:
	push_warning("[VolumeScoreFineSelection] %s —— 不打分" % reason)
	return {"ok": false, "reason": reason}


## 硬失败：契约破裂（调用方少传输入、descriptor 与 profile_id 不同步、常驻交接
## 不合规、VPG 该给的输出没给）。这些在正确装配下不可能发生，必须在第一现场炸掉，
## 而不是降级成一个 ok=false 的空模型被 demo 当"这轮没分"处理掉。
func _fail_hard(reason: String, detail: String) -> Dictionary:
	_report_hard(reason, detail)
	return {"ok": false, "reason": reason}


## _fail_hard 的报错半边，供静态取数路径（没有 ok/reason 返回值可用）复用同一文案口径。
static func _report_hard(reason: String, detail: String) -> void:
	push_error("[VolumeScoreFineSelection] %s —— %s" % [reason, detail])
	assert(false, "VolumeScoreFineSelection: %s" % reason)


## anchors-only 模型（demo generate_anchors 门面消费）：真实 S6 锚点、无细筛分数。
## 排序与 run() 同口径；ok=false（有锚点无分数，demo 的 _scored() 判定沿用）。
static func anchors_only_model(
	anchors, topk: int, asset_count: int,
	grid_size: Vector3i, voxel_size: Vector3, grid_origin: Vector3,
	terrain_height := PackedFloat32Array()
) -> Dictionary:
	var anchors_packed := _anchor_payload_as_packed(anchors)
	var model := _build_model(
		{"fine_candidates": []}, anchors_packed, int(anchors_packed.size() / 4), topk, asset_count,
		grid_size, voxel_size, grid_origin, 0.0, terrain_height)
	model["ok"] = false
	model["reason"] = "anchors_only"
	return model


# ---- 按需 CPU 锚点物化 -------------------------------------------------------
#
# ⚠ 诚实说明这条路省下的到底是什么，别把它当成"Score 变快了"：
#   省下的是**不需要 CPU 锚点坐标的消费方**——Place 批次（全程 GPU：begin_place_session /
#   run_place_session_batch，从不物化）、纯 GPU benchmark、以及任何只吃 handoff 常驻 RID
#   的下游。这些路径以前只要跑一次 prefilter 就得白读一遍位置数组，现在一个字节都不读。
#   **带可视化的 Score 并没有省**：_build_visualization 要画锚点小球、要按锚点世界坐标
#   摆胜出 mesh，必须要 CPU 坐标，于是每轮 Score 仍然发生一次 live_anchor_count×16 字节
#   回读（golden 的 45,598 锚点 ≈ 730 KB），与改动前的字节数一致，只是时机从"prefilter
#   内部顺带读"挪成"显示构建时读一次并随模型缓存"。
#   真要在 Score 上省掉它，前提是可视化本身改由 GPU 常驻数据驱动（MultiMesh 缓冲直接由
#   GPU 写），那是另一件事；在那之前不得为了让注释成立而削弱显示功能。

## 把 run() 的 GPU-only 结果模型标成"CPU 锚点待物化"，并挂上物化所需的一切来源。
## 只挂**借用**句柄（handoff 的只读 RID 与容器设备），本 runner 不持有也不释放它们。
static func _attach_cpu_anchor_source(
	model: Dictionary, handoff: Dictionary, live_anchor_count: int,
	container, terrain_height
) -> void:
	var rendering_device = _container_rendering_device(container)
	model["cpu_anchor_model_pending"] = true
	model["cpu_anchor_source"] = {
		"anchor_buffer_rid": handoff.get("anchor_buffer_rid", RID()),
		"anchor_count_buffer_rid": handoff.get("anchor_count_buffer_rid", RID()),
		"anchor_capacity": int(handoff.get("anchor_capacity", 0)),
		"anchor_stride_bytes": int(handoff.get("anchor_stride_bytes", 16)),
		"live_anchor_count": live_anchor_count,
		"rendering_device": rendering_device,
		"terrain_height": terrain_height,
	}


## 容器（runtime profile container）持有的 RenderingDevice——按需取数只借这个设备读
## 常驻缓冲。⚠ 判空用 is_instance_valid 而不是 `== null`（后者对静态类型已知的操作数
## 会被编成恒 false）。
static func _container_rendering_device(container):
	if is_instance_valid(container) and container.has_method("get_rendering_device"):
		return container.call("get_rendering_device")
	return null


## 越容量不变量。collect shader 的 `atomicAdd(anchor_count, 1u)` 是**无条件**自增（只有
## 写入受 `idx < cap` 保护），所以计数确实能超过 anchor_capacity；此时 mini() 静默截断会
## 让超出的锚点无声消失（UI 与 golden 都看不出来），因此一律 fail-loud，沿用 prefilter
## 的 anchor_count_invariant_violated 口径。capacity<=0 = 交接没声明容量，无从校验。
static func _anchor_count_within_capacity(live_count: int, capacity: int) -> bool:
	return capacity <= 0 or live_count <= capacity


## GPU 常驻 anchor_count 缓冲的 4 字节读数 + 容量不变量校验。
## GPU-only 形态下"这一轮有多少锚点"的唯一事实源（VPG fine 段读的是同一个缓冲）。
## 返回 {ok:bool, count:int, reason:String, detail:String, hard:bool}——本函数只取数不报错，
## 由调用方按各自语境决定硬失败（run 的契约门）还是软降级（显示侧取数）。
static func read_resident_anchor_count(rendering_device, handoff: Dictionary) -> Dictionary:
	# ⚠ 判空用 `is`：对静态类型已知的操作数 `== null` 会被编成恒 false。
	if not (rendering_device is RenderingDevice) or not is_instance_valid(rendering_device):
		return {"ok": false, "count": -1, "hard": false,
			"reason": "anchor_count_rendering_device_unavailable",
			"detail": "anchor_count 取数没有可用 RenderingDevice"}
	var count_buffer: RID = handoff.get("anchor_count_buffer_rid", RID())
	if not count_buffer.is_valid():
		return {"ok": false, "count": -1, "hard": false,
			"reason": "anchor_count_buffer_rid_invalid",
			"detail": "anchor handoff 的 anchor_count_buffer_rid 非法"}
	var rd: RenderingDevice = rendering_device
	var count_bytes := rd.buffer_get_data(count_buffer, 0, 4)
	if count_bytes.size() < 4:
		return {"ok": false, "count": -1, "hard": false,
			"reason": "anchor_count_readback_short",
			"detail": "anchor_count 回读字节不足（%d < 4）" % count_bytes.size()}
	var live_count := int(count_bytes.decode_u32(0))
	var capacity := int(handoff.get("anchor_capacity", 0))
	if not _anchor_count_within_capacity(live_count, capacity):
		return {"ok": false, "count": live_count, "hard": true,
			"reason": "anchor_count_invariant_violated",
			"detail": "anchor invariant violated: raw_count=%d capacity=%d" % [live_count, capacity]}
	return {"ok": true, "count": live_count, "hard": false, "reason": "ok", "detail": ""}


## GPU 常驻 anchor 位置的**按需**回读（借用只读缓冲；本函数不持有/不释放任何 RID）。
## 与 prefilter 的 debug_read_anchors 是两条不同的路：那个开关是"每次 prefilter 都顺带
## 回读"的调试模式（默认关闭，语义不变，不是生产路径）；这里是"某个 CPU 消费方现在
## 真的需要坐标了"的一次性取数，由消费方显式触发。
## handoff 需含 anchor_buffer_rid / anchor_count_buffer_rid / anchor_capacity /
## anchor_stride_bytes；anchor_count < 0 时先读 4 字节 count 缓冲。
## 取不到时 push_warning 并返回空数组（这是显示/点选侧的降级，不构成 run() 的失败原因）；
## **越容量除外**——那是不变量破裂，push_error + assert，不静默截断（见
## _anchor_count_within_capacity）。
static func read_resident_anchors_packed(
	rendering_device, handoff: Dictionary, anchor_count: int = -1
) -> PackedInt32Array:
	# ⚠ 判空用 `is`：对静态类型已知的操作数 `== null` 会被编成恒 false。
	if not (rendering_device is RenderingDevice) or not is_instance_valid(rendering_device):
		push_warning("[VolumeScoreFineSelection] anchor 按需回读没有可用 RenderingDevice —— 空锚点载荷")
		return PackedInt32Array()
	var rd: RenderingDevice = rendering_device
	var anchor_buffer: RID = handoff.get("anchor_buffer_rid", RID())
	if not anchor_buffer.is_valid():
		push_warning("[VolumeScoreFineSelection] anchor handoff 的 anchor_buffer_rid 非法 —— 空锚点载荷")
		return PackedInt32Array()
	var live_count := anchor_count
	if live_count < 0:
		var count_probe := read_resident_anchor_count(rendering_device, handoff)
		if not bool(count_probe.get("ok", false)):
			if bool(count_probe.get("hard", false)):
				_report_hard(str(count_probe.get("reason", "?")), str(count_probe.get("detail", "")))
			else:
				push_warning("[VolumeScoreFineSelection] %s —— 空锚点载荷" % str(count_probe.get("detail", "?")))
			return PackedInt32Array()
		live_count = int(count_probe.get("count", 0))
	elif not _anchor_count_within_capacity(live_count, int(handoff.get("anchor_capacity", 0))):
		# 调用方给的计数同样受不变量约束（它同样源自 GPU 的 atomicAdd 计数）。
		_report_hard("anchor_count_invariant_violated",
			"anchor invariant violated: raw_count=%d capacity=%d" % [
				live_count, int(handoff.get("anchor_capacity", 0))])
		return PackedInt32Array()
	if live_count <= 0:
		return PackedInt32Array()
	var stride := maxi(int(handoff.get("anchor_stride_bytes", 16)), 4)
	var expected_bytes := live_count * stride
	var anchor_bytes := rd.buffer_get_data(anchor_buffer, 0, expected_bytes)
	if anchor_bytes.size() < expected_bytes:
		push_warning("[VolumeScoreFineSelection] anchor 位置回读字节不足 期望 %d 实际 %d —— 空锚点载荷" % [
			expected_bytes, anchor_bytes.size()])
		return PackedInt32Array()
	return anchor_bytes.to_int32_array()


## 惰性 CPU 锚点模型入口。run() 在 GPU-only 形态下返回的模型只带 GPU 侧记录
## （fine_winner_bytes / fine_candidate_bytes）与几何参数，anchor_voxels /
## anchor_world_positions / winner_* 全为空，并挂 cpu_anchor_model_pending=true。
## 第一个真正需要 CPU 锚点的消费方（点选、显示、golden、HUD）调用本函数把模型补全；
## 补全后的模型与"prefilter 开了回读"时 run() 直接返回的模型逐字段等价。
##
## 缓存与失效（不新造平行状态）：缓存就是补全后的模型字典本身——pending 标记被清成
## false，同一批 GPU 结果内的后续调用是 O(1) 判断，不会重复回读。失效条件只有一条：
## **模型字典换代**。每次新的 Score / Anchors / Place 都整份替换调用方持有的模型，新
## 模型自带 pending=true，旧"缓存"随旧字典一起作废，因此不存在与 GPU 结果脱节的副本。
##
## ⚠ 物化必须发生在同一批 GPU 结果仍然常驻期间（demo 在 _build_visualization 立即触发）：
## anchor 缓冲归 prefilter 的 collect 段所有，下一次 collect 换代后其内容随之换代。
static func materialize_cpu_anchor_model(model: Dictionary) -> Dictionary:
	if not bool(model.get("cpu_anchor_model_pending", false)):
		return model
	var source: Dictionary = model.get("cpu_anchor_source", {})
	var anchors_packed := read_resident_anchors_packed(
		source.get("rendering_device"), source, int(source.get("live_anchor_count", -1)))
	# model 自身即 _build_model 的 out：fine_candidates / fine_candidate_bytes /
	# fine_winner_bytes 三个键在结果模型里同名同义，重建走的是同一条解码路径。
	var rebuilt := _build_model(
		model, anchors_packed, int(anchors_packed.size() / 4),
		int(model.get("topk", 4)), int(model.get("asset_count", 0)),
		model.get("grid", Vector3i.ZERO), model.get("voxel_size", Vector3.ONE),
		model.get("grid_origin", Vector3.ZERO), float(model.get("elapsed_ms", 0.0)),
		source.get("terrain_height", PackedFloat32Array()))
	# duplicate + merge：保留 run() 在 _build_model 之后追加的键（score_timing_profile 等），
	# 锚点相关键一律以重建结果为准。
	var materialized := model.duplicate()
	materialized.merge(rebuilt, true)
	materialized["cpu_anchor_model_pending"] = false
	return materialized


## 多区域兼容模型合并：区域 tile 集互不相交、每个子模型
## 已按线性体素索引排序——合并后全局重排，与单区域 run 同口径（确定性保持）。
## elapsed_ms 累加、fine_candidates 连接（诊断留存）、winner 按合并后记录重算。
## ok/reason 取首个子模型（scored 全 ok=true；anchors_only 全 ok=false 语义沿用）。
static func merge_models(models: Array) -> Dictionary:
	var base: Dictionary = {}
	var entries: Array = []
	var elapsed := 0.0
	var candidates_all: Array = []
	for raw_model in models:
		if not (raw_model is Dictionary):
			continue
		# 合并需要每个子模型的 CPU 锚点数组，因此在这里按需物化（单区域路径不经过
		# merge_models，惰性语义完整保留；多区域下与改动前一样在评分后立即取数）。
		var m := materialize_cpu_anchor_model(raw_model as Dictionary)
		if m.get("anchor_voxels") == null:
			continue
		if base.is_empty():
			base = m
		elapsed += float(m.get("elapsed_ms", 0.0))
		var voxels: Array = m.get("anchor_voxels", [])
		var worlds: PackedVector3Array = m.get("anchor_world_positions", PackedVector3Array())
		var recs: Array = m.get("records_by_anchor", [])
		var model_winners: PackedInt32Array = m.get("winner_per_anchor", PackedInt32Array())
		var model_scores: PackedFloat32Array = m.get("winner_scores", PackedFloat32Array())
		var model_rotations: PackedInt32Array = m.get("winner_rotation_indices", PackedInt32Array())
		for i in range(voxels.size()):
			entries.append({
				"voxel": voxels[i],
				"world": worlds[i] if i < worlds.size() else Vector3.ZERO,
				"records": recs[i] if i < recs.size() else _records_for_anchor(m, i),
				"winner": model_winners[i] if i < model_winners.size() else -1,
				"score": model_scores[i] if i < model_scores.size() else -INF,
				"rotation": model_rotations[i] if i < model_rotations.size() else 0,
			})
		candidates_all.append_array(m.get("fine_candidates", []))
	if base.is_empty():
		return {"ok": false, "reason": "merge_no_models"}
	var grid: Vector3i = base.get("grid", Vector3i.ZERO)
	entries.sort_custom(func(a, b) -> bool:
		return VoxelGeneral.voxel_index(a["voxel"], grid) < VoxelGeneral.voxel_index(b["voxel"], grid))
	var anchor_voxels: Array[Vector3i] = []
	var world_positions := PackedVector3Array()
	var records_by_anchor: Array = []
	var winners := PackedInt32Array()
	var winner_scores := PackedFloat32Array()
	var winner_rotations := PackedInt32Array()
	winners.resize(entries.size())
	winner_scores.resize(entries.size())
	winner_rotations.resize(entries.size())
	for entry in entries:
		var output_index := anchor_voxels.size()
		anchor_voxels.append(entry["voxel"])
		world_positions.append(entry["world"])
		records_by_anchor.append(entry["records"])
		winners[output_index] = int(entry["winner"])
		winner_scores[output_index] = float(entry["score"])
		winner_rotations[output_index] = int(entry["rotation"])
	return {
		"ok": bool(base.get("ok", false)), "reason": str(base.get("reason", "ok")),
		"grid": grid, "voxel_size": base.get("voxel_size", Vector3.ONE),
		"grid_origin": base.get("grid_origin", Vector3.ZERO),
		"topk": base.get("topk", 4), "asset_count": base.get("asset_count", 0),
		"elapsed_ms": elapsed,
		"anchor_count": anchor_voxels.size(),
		"anchor_voxels": anchor_voxels,
		"anchor_world_positions": world_positions,
		"records_by_anchor": records_by_anchor,
		"winner_per_anchor": winners,
		"winner_scores": winner_scores,
		"winner_rotation_indices": winner_rotations,
		"fine_candidates": candidates_all,
	}


static func _records_for_anchor(model: Dictionary, anchor_index: int) -> Array:
	var records: Array = []
	var asset_count := int(model.get("asset_count", 0))
	for asset_index in range(asset_count):
		var record := anchor_asset_record(model, anchor_index, asset_index)
		if float(record.get("score", -INF)) > -INF:
			records.append(record)
	return records


## 把原始候选池整理为确定性结果模型：锚点按线性体素索引升序（批3b规格 F2——
## collect_sv_anchors 的 atomicAdd 追加序跨 run 不确定，集合确定但顺序随机），
## 每锚点归组其 topk 槽记录（record.asset_index 键控，F4——真实 prefilter 的
## topk 槽 ≠ asset_index，空槽 asset id=0xFFFFFFFF）。
## 返回键（消费方：demo 可视化/HUD/选中、golden 格式器、debug_anchor_breakdown）：
##   ok, reason:"ok", grid, voxel_size, grid_origin, topk, asset_count, elapsed_ms,
##   anchor_count            — 排序后锚点数
##   anchor_voxels: Array[Vector3i]           — 排序序
##   anchor_world_positions: PackedVector3Array — 体素中心世界坐标（terrain_height 非空时
##                             = 地形相对：Y 加该 XZ 列地形高度，height_relative 烘焙口径；
##                             3D 锚点仍可悬空于地表上方，F10 预期）
##   records_by_anchor: Array[Array]          — 每锚点该锚的 fine-candidate 记录（原始 dict，
##                                              含 score/valid/rotation_index/asset_index/
##                                              loss_before/loss_after/solid_collision/clearance_overlap）
##   winner_per_anchor: PackedInt32Array      — 每锚点最佳有效资产 index（-1 = 无）
##   fine_candidates: Array                   — 原始候选池（诊断留存，槽序未重排）
## GPU-only 形态（prefilter 未回读 anchor 位置）下 run() 会在上述键之外追加
## cpu_anchor_model_pending / cpu_anchor_source：此时锚点相关键全为空，需由消费方调
## materialize_cpu_anchor_model 补全（见该函数的缓存与失效说明）。
static func _build_model(
	out: Dictionary, anchors_packed: PackedInt32Array, anchor_count: int,
	topk: int, asset_count: int,
	grid_size: Vector3i, voxel_size: Vector3, grid_origin: Vector3,
	elapsed_ms: float,
	terrain_height := PackedFloat32Array()
) -> Dictionary:
	var candidates: Array = out.get("fine_candidates", [])
	var candidate_bytes: PackedByteArray = out.get("fine_candidate_bytes", PackedByteArray())
	var winner_bytes: PackedByteArray = out.get("fine_winner_bytes", PackedByteArray())
	var packed_candidates := not candidate_bytes.is_empty()
	var packed_winners := not winner_bytes.is_empty()
	var packed_output := packed_candidates or packed_winners
	var safe_anchor_count := mini(maxi(anchor_count, 0), int(anchors_packed.size() / 4))
	# 线性体素索引放高位、原始 anchor id 放低 16 位；PackedInt64Array 原地排序
	# 避免 45k 次 Dictionary 物化和 lambda 比较器内反复计算 voxel_index。
	var order_keys := PackedInt64Array()
	order_keys.resize(safe_anchor_count)
	for source_index in range(safe_anchor_count):
		var voxel := _packed_anchor_voxel_at(anchors_packed, source_index)
		var linear_index := VoxelGeneral.voxel_index(voxel, grid_size)
		order_keys[source_index] = (linear_index << ANCHOR_SOURCE_INDEX_BITS) | source_index
	order_keys.sort()
	var anchor_voxels: Array[Vector3i] = []
	var world_positions := PackedVector3Array()
	var records_by_anchor: Array = []
	var source_anchor_indices := PackedInt32Array()
	var winners := PackedInt32Array()
	var winner_scores := PackedFloat32Array()
	var winner_rotation_indices := PackedInt32Array()
	if packed_output:
		source_anchor_indices.resize(safe_anchor_count)
		winners.resize(safe_anchor_count)
		winners.fill(-1)
		winner_scores.resize(safe_anchor_count)
		winner_scores.fill(-INF)
		winner_rotation_indices.resize(safe_anchor_count)
	for order_key in order_keys:
		var source_index := int(order_key & ANCHOR_SOURCE_INDEX_MASK)
		var sorted_index := anchor_voxels.size()
		var voxel := _packed_anchor_voxel_at(anchors_packed, source_index)
		anchor_voxels.append(voxel)
		world_positions.append(VoxelGeneral.terrain_relative_voxel_center_to_world(
			voxel, grid_size, grid_origin, voxel_size, terrain_height))
		if packed_output:
			source_anchor_indices[sorted_index] = source_index
			var best_asset := -1
			var best_score := -INF
			var best_rotation := 0
			if packed_winners:
				var winner_base := source_index * CANDIDATE_RECORD_BYTES
				if winner_base >= 0 and winner_base + CANDIDATE_RECORD_BYTES <= winner_bytes.size():
					var winner_asset := int(roundf(winner_bytes.decode_float(
						winner_base + CANDIDATE_ASSET_OFFSET)))
					var winner_valid := winner_bytes.decode_float(
						winner_base + CANDIDATE_VALID_OFFSET) > 0.5
					if winner_valid and winner_asset >= 0 and winner_asset < asset_count:
						best_asset = winner_asset
						best_score = winner_bytes.decode_float(winner_base + CANDIDATE_SCORE_OFFSET)
						best_rotation = int(roundf(winner_bytes.decode_float(
							winner_base + CANDIDATE_ROTATION_OFFSET)))
			else:
				for k in range(topk):
					var record_index := source_index * topk + k
					var byte_base := record_index * CANDIDATE_RECORD_BYTES
					if byte_base < 0 or byte_base + CANDIDATE_RECORD_BYTES > candidate_bytes.size():
						continue
					var asset_index := int(roundf(candidate_bytes.decode_float(byte_base + CANDIDATE_ASSET_OFFSET)))
					if asset_index < 0 or asset_index >= asset_count:
						continue
					var score := candidate_bytes.decode_float(byte_base + CANDIDATE_SCORE_OFFSET)
					var valid := candidate_bytes.decode_float(byte_base + CANDIDATE_VALID_OFFSET) > 0.5
					if valid and score > best_score:
						best_asset = asset_index
						best_score = score
						best_rotation = int(roundf(candidate_bytes.decode_float(byte_base + CANDIDATE_ROTATION_OFFSET)))
			winners[sorted_index] = best_asset
			winner_scores[sorted_index] = best_score
			winner_rotation_indices[sorted_index] = best_rotation
			continue
		var records: Array = []
		for k in range(topk):
			var slot := source_index * topk + k
			if slot >= 0 and slot < candidates.size():
				var record: Dictionary = candidates[slot]
				# 空槽哨兵（0xFFFFFFFF）经 float 解码溢出为超大正整数——按 asset_count 上界过滤。
				var asset_index := int(record.get("asset_index", -1))
				if asset_index >= 0 and asset_index < asset_count:
					records.append(record)
		records_by_anchor.append(records)
	var model := {
		"ok": true, "reason": "ok",
		"grid": grid_size, "voxel_size": voxel_size, "grid_origin": grid_origin,
		"topk": topk, "asset_count": asset_count, "elapsed_ms": elapsed_ms,
		"anchor_count": anchor_voxels.size(),
		"anchor_voxels": anchor_voxels,
		"anchor_world_positions": world_positions,
		"records_by_anchor": records_by_anchor,
		"winner_per_anchor": winners if packed_output else winners_from_results(records_by_anchor, asset_count),
		"fine_candidates": candidates,
	}
	if packed_output:
		model["source_anchor_indices"] = source_anchor_indices
		model["winner_scores"] = winner_scores
		model["winner_rotation_indices"] = winner_rotation_indices
	if packed_winners:
		model["fine_winner_bytes"] = winner_bytes
		model["fine_winner_record_count"] = int(winner_bytes.size() / CANDIDATE_RECORD_BYTES)
	if packed_candidates:
		model["fine_candidate_bytes"] = candidate_bytes
		model["fine_candidate_record_count"] = int(candidate_bytes.size() / CANDIDATE_RECORD_BYTES)
	return model


static func _packed_anchor_voxel_at(anchors_packed: PackedInt32Array, anchor_index: int) -> Vector3i:
	var base := anchor_index * 4
	if base < 0 or base + 2 >= anchors_packed.size():
		return Vector3i(-1, -1, -1)
	return Vector3i(anchors_packed[base], anchors_packed[base + 1], anchors_packed[base + 2])


## 兼容旧测试/调试调用：Array[Dictionary] 仅在这里一次性转成 packed ivec4。
## 生产 prefilter 直接提供 PackedInt32Array，不进入此分支。
static func _anchor_payload_as_packed(anchors) -> PackedInt32Array:
	if anchors is PackedInt32Array:
		return anchors
	var dictionaries: Array = anchors if anchors is Array else []
	var packed := PackedInt32Array()
	packed.resize(dictionaries.size() * 4)
	for i in range(dictionaries.size()):
		var voxel := Vector3i(-1, -1, -1)
		if dictionaries[i] is Dictionary:
			voxel = (dictionaries[i] as Dictionary).get("voxel_pos", voxel)
		var base := i * 4
		packed[base] = voxel.x
		packed[base + 1] = voxel.y
		packed[base + 2] = voxel.z
		packed[base + 3] = 0
	return packed


## 每锚点最佳有效资产（valid 且分数最高；无 → -1）。
static func winners_from_results(records_by_anchor: Array, asset_count: int) -> PackedInt32Array:
	var winners := PackedInt32Array()
	winners.resize(records_by_anchor.size())
	for i in range(records_by_anchor.size()):
		var best_asset := -1
		var best_score := -INF
		for record in (records_by_anchor[i] as Array):
			var rec: Dictionary = record
			var asset_index := int(rec.get("asset_index", -1))
			if asset_index < 0 or asset_index >= asset_count:
				continue
			if bool(rec.get("valid", false)) and float(rec.get("score", -INF)) > best_score:
				best_score = float(rec.get("score", -INF))
				best_asset = asset_index
		winners[i] = best_asset
	return winners


## 某锚点 (anchor, asset) 记录；该资产不在其 topk 槽时返回 -INF 占位（F4，golden 沿用
## 现格式器 clamp 数学 → gain_q1000=-1000000 确定哨兵）。
static func anchor_asset_record(model: Dictionary, anchor_index: int, asset_index: int) -> Dictionary:
	var candidate_bytes: PackedByteArray = model.get("fine_candidate_bytes", PackedByteArray())
	var source_anchor_indices: PackedInt32Array = model.get("source_anchor_indices", PackedInt32Array())
	if not candidate_bytes.is_empty() and anchor_index >= 0 and anchor_index < source_anchor_indices.size():
		var source_index := source_anchor_indices[anchor_index]
		var topk := int(model.get("topk", 4))
		for k in range(topk):
			var record_index := source_index * topk + k
			var byte_base := record_index * CANDIDATE_RECORD_BYTES
			if byte_base < 0 or byte_base + CANDIDATE_RECORD_BYTES > candidate_bytes.size():
				continue
			var record_asset := int(roundf(candidate_bytes.decode_float(byte_base + CANDIDATE_ASSET_OFFSET)))
			if record_asset == asset_index:
				return _decode_candidate_record(candidate_bytes, byte_base)
	var winner_bytes: PackedByteArray = model.get("fine_winner_bytes", PackedByteArray())
	if not winner_bytes.is_empty() and anchor_index >= 0 and anchor_index < source_anchor_indices.size():
		var winner_base := source_anchor_indices[anchor_index] * CANDIDATE_RECORD_BYTES
		if winner_base >= 0 and winner_base + CANDIDATE_RECORD_BYTES <= winner_bytes.size():
			var winner_asset := int(roundf(winner_bytes.decode_float(
				winner_base + CANDIDATE_ASSET_OFFSET)))
			if winner_asset == asset_index:
				return _decode_candidate_record(winner_bytes, winner_base)
	var records_by_anchor: Array = model.get("records_by_anchor", [])
	if anchor_index >= 0 and anchor_index < records_by_anchor.size():
		for record in (records_by_anchor[anchor_index] as Array):
			if int((record as Dictionary).get("asset_index", -2)) == asset_index:
				return record
	return {"score": -INF, "valid": false, "rotation_index": 0, "asset_index": asset_index}


static func _decode_candidate_record(bytes: PackedByteArray, byte_base: int) -> Dictionary:
	return {
		"voxel_origin": Vector3i(
			int(roundf(bytes.decode_float(byte_base + 0))),
			int(roundf(bytes.decode_float(byte_base + 4))),
			int(roundf(bytes.decode_float(byte_base + 8)))),
		"score": bytes.decode_float(byte_base + 12),
		"anchor_id": int(roundf(bytes.decode_float(byte_base + 16))),
		"asset_index": int(roundf(bytes.decode_float(byte_base + 20))),
		"rotation_index": int(roundf(bytes.decode_float(byte_base + 24))),
		"global_pivot_index": int(roundf(bytes.decode_float(byte_base + 28))),
		"solid_collision": bytes.decode_float(byte_base + 32),
		"loss_before": bytes.decode_float(byte_base + 36),
		"loss_after": bytes.decode_float(byte_base + 40),
		"clearance_overlap": bytes.decode_float(byte_base + 44),
		"profile_index": int(roundf(bytes.decode_float(byte_base + 48))),
		"valid": bytes.decode_float(byte_base + 52) > 0.5,
		"coarse_score": bytes.decode_float(byte_base + 56),
	}


## 某锚点按 (valid 优先, 分数降序) 的 Top-K 展示条目（demo 选中面板/HUD 消费）。
## 条目键与旧 demo `_anchor_topk_entries` 逐字一致：asset_index/asset_name/score/valid/
## rotation_slot/yaw/rank（asset_names 由调用方传，保证名字来源单一）。
static func topk_entries(
	model: Dictionary, anchor_index: int, limit: int,
	asset_names: Array, rotation_slots: int
) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var asset_count := int(model.get("asset_count", 0))
	# 名字来源单一（调用方传入）：短了不再拿 "AssetN" 顶上，那会让面板显示出
	# 一批与真实资产对不上的假名字，且看不出是名单没对齐。
	if asset_names.size() < asset_count:
		push_error("[VolumeScoreFineSelection] topk_entries 的 asset_names 短于模型资产数 期望 %d 实际 %d —— 名单与模型不同源" % [
			asset_count, asset_names.size()])
		assert(false, "VolumeScoreFineSelection: asset_names shorter than model asset_count")
		return entries
	for asset_index in range(asset_count):
		var record := anchor_asset_record(model, anchor_index, asset_index)
		var slot := int(record.get("rotation_index", 0))
		entries.append({
			"asset_index": asset_index,
			"asset_name": str(asset_names[asset_index]),
			"score": float(record.get("score", -INF)),
			"valid": bool(record.get("valid", false)),
			"rotation_slot": slot,
			"yaw": float(slot) * (360.0 / float(maxi(rotation_slots, 1))),
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.valid) != bool(b.valid):
			return bool(a.valid)
		return float(a.score) > float(b.score))
	var out: Array[Dictionary] = []
	for i in range(mini(limit, entries.size())):
		var e := entries[i].duplicate()
		e["rank"] = i + 1
		out.append(e)
	return out


## 全场每个锚点的**第 rank 名**候选（rank 从 0 起）。返回两个与 `winner_per_anchor`
## 等长、逐项并行的表：`{assets: PackedInt32Array, rotations: PackedInt32Array}`，
## 该锚点没有第 rank 名（有效候选不足）时资产填 -1。
##
## 排序规则与 `topk_entries()` 同源：**只取 valid**、分数降序。因此 `rank == 0` 的结果
## 与 `winner_per_anchor` 逐项一致（后者就是"有效候选里分最高的那个"，见本文件的
## winner 计算）——winner 档从"切资产"改成"切排名"后，rank 0 的观感与旧 winner 档相同。
##
## ⚠ 不走 `anchor_asset_record()`：那条每锚点每资产建一个 Dictionary，全场 4.5 万锚点 ×
## 资产数会在一次按键里产生二十几万次分配。这里直接读候选字节（与 winner 计算同一条路），
## 每锚点只用两个定长小数组。`fine_candidate_bytes` 缺席（非 packed 模型）时回退
## `records_by_anchor`，形状由 `_records_for_anchor()` 保证。
static func rank_pick_per_anchor(model: Dictionary, rank: int) -> Dictionary:
	var anchor_count := int(model.get("anchor_count", 0))
	var assets := PackedInt32Array()
	var rotations := PackedInt32Array()
	assets.resize(anchor_count)
	rotations.resize(anchor_count)
	assets.fill(-1)
	rotations.fill(0)
	if rank < 0 or anchor_count <= 0:
		return {"assets": assets, "rotations": rotations}
	var asset_count := int(model.get("asset_count", 0))
	var topk := int(model.get("topk", 4))
	var candidate_bytes: PackedByteArray = model.get("fine_candidate_bytes", PackedByteArray())
	var source_anchor_indices: PackedInt32Array = model.get("source_anchor_indices", PackedInt32Array())
	var records_by_anchor: Array = model.get("records_by_anchor", [])
	# ⚠ 交互 Score **没有**逐锚点 top-K：`read_fine_candidate_bytes` 挂在
	# `full_candidate_diagnostics` 上（只有 golden / 诊断路开），常规那趟只回读 winner 一份。
	# 此时唯一存在的名次就是第 1 名 —— 直接用 `winner_per_anchor`（与本函数的排序规则同源），
	# rank > 0 如实返回全 -1（"这一档没有数据"），而不是让 winner 档变成空场。
	if candidate_bytes.is_empty() and records_by_anchor.is_empty():
		if rank > 0:
			return {"assets": assets, "rotations": rotations}
		var winners: PackedInt32Array = model.get("winner_per_anchor", PackedInt32Array())
		var winner_rotations: PackedInt32Array = model.get("winner_rotation_indices", PackedInt32Array())
		for anchor_index in range(mini(anchor_count, winners.size())):
			assets[anchor_index] = winners[anchor_index]
			if anchor_index < winner_rotations.size():
				rotations[anchor_index] = winner_rotations[anchor_index]
		return {"assets": assets, "rotations": rotations}
	# 每锚点的有效候选（按分数降序插入，长度 ≤ topk）。循环外建一次，循环内 clear。
	var scores := PackedFloat32Array()
	var picked := PackedInt32Array()
	var picked_rot := PackedInt32Array()
	for anchor_index in range(anchor_count):
		scores.clear()
		picked.clear()
		picked_rot.clear()
		if not candidate_bytes.is_empty() and anchor_index < source_anchor_indices.size():
			var source_index := source_anchor_indices[anchor_index]
			for k in range(topk):
				var byte_base := (source_index * topk + k) * CANDIDATE_RECORD_BYTES
				if byte_base < 0 or byte_base + CANDIDATE_RECORD_BYTES > candidate_bytes.size():
					continue
				if candidate_bytes.decode_float(byte_base + CANDIDATE_VALID_OFFSET) <= 0.5:
					continue
				var asset_index := int(roundf(candidate_bytes.decode_float(byte_base + CANDIDATE_ASSET_OFFSET)))
				if asset_index < 0 or (asset_count > 0 and asset_index >= asset_count):
					continue
				_insert_ranked(
					scores, picked, picked_rot,
					candidate_bytes.decode_float(byte_base + CANDIDATE_SCORE_OFFSET),
					asset_index,
					int(roundf(candidate_bytes.decode_float(byte_base + CANDIDATE_ROTATION_OFFSET))))
		elif anchor_index < records_by_anchor.size():
			var records = records_by_anchor[anchor_index]
			if records is Array:
				for raw_record in records as Array:
					if not (raw_record is Dictionary):
						continue
					var record := raw_record as Dictionary
					if not bool(record.get("valid", false)):
						continue
					var record_asset := int(record.get("asset_index", -1))
					if record_asset < 0 or (asset_count > 0 and record_asset >= asset_count):
						continue
					_insert_ranked(
						scores, picked, picked_rot,
						float(record.get("score", -INF)),
						record_asset,
						int(record.get("rotation_index", 0)))
		if rank < picked.size():
			assets[anchor_index] = picked[rank]
			rotations[anchor_index] = picked_rot[rank]
	return {"assets": assets, "rotations": rotations}


## 按分数降序把一条候选插入三张并行小表（长度恒 ≤ topk，插入排序足够）。
static func _insert_ranked(
	scores: PackedFloat32Array, assets: PackedInt32Array, rotations: PackedInt32Array,
	score: float, asset_index: int, rotation_index: int
) -> void:
	var at := scores.size()
	for i in range(scores.size()):
		if score > scores[i]:
			at = i
			break
	scores.insert(at, score)
	assets.insert(at, asset_index)
	rotations.insert(at, rotation_index)


## 某锚点胜出资产的放置信息（渲染 / 红框 bound / 点选三处共用同一变换）。
## 数学逐字迁自 demo `_winner_placement`：真实 1:1 FBX 缩放（不再按 collision 采样
## 包围盒归一化——那会把小资产放大得比大资产更多，丢失资产间真实相对比例）、
## 垂直对齐 mesh 原生 FBX 轴心（local y=0）而非 AABB 底面（cliff 半埋、植物立于
## 基线，与 asset-overview 摆放一致）、水平取 AABB 中心居中于锚点体素。
## 锚点世界位置 = 体素中心（F10：3D 锚点可悬空，预期行为，不做 surface 精化）。
## assets[i] 需含 {mesh, aabb}；无有效胜者返回空字典。
static func winner_placement_transform(
	model: Dictionary, anchor_index: int, assets: Array, rotation_slots: int
) -> Dictionary:
	var winners: PackedInt32Array = model.get("winner_per_anchor", PackedInt32Array())
	var winner := winners[anchor_index] if anchor_index >= 0 and anchor_index < winners.size() else -1
	if winner < 0 or winner >= assets.size():
		return {}
	var winner_rotations: PackedInt32Array = model.get("winner_rotation_indices", PackedInt32Array())
	var rotation_index := 0
	if anchor_index < winner_rotations.size():
		rotation_index = winner_rotations[anchor_index]
	else:
		var record := anchor_asset_record(model, anchor_index, winner)
		if not bool(record.get("valid", false)):
			return {}
		rotation_index = int(record.get("rotation_index", 0))
	var asset: Dictionary = assets[winner]
	var mesh: Mesh = asset.get("mesh", null)
	if mesh == null:
		return {}
	var aabb: AABB = asset.get("aabb", mesh.get_aabb())
	var fit_scale := 1.0
	var pivot_local := Vector3(aabb.position.x + aabb.size.x * 0.5, 0.0, aabb.position.z + aabb.size.z * 0.5)
	var yaw := deg_to_rad(float(rotation_index) * (360.0 / float(maxi(rotation_slots, 1))))
	var basis := Basis(Vector3.UP, yaw) * Basis.IDENTITY.scaled(Vector3(fit_scale, fit_scale, fit_scale))
	var world_positions: PackedVector3Array = model.get("anchor_world_positions", PackedVector3Array())
	if anchor_index >= world_positions.size():
		return {}
	var origin := world_positions[anchor_index] - basis * pivot_local
	return {
		"ok": true, "winner": winner, "mesh": mesh, "yaw": yaw,
		"transform": Transform3D(basis, origin), "aabb": aabb, "fit_scale": fit_scale,
	}


## 胜者显示排序（可视化/点选用）：全部 valid 胜者的锚点下标，按分数降序。
## 排序仍有意义：点选面按此序命中，高分锚点优先。确定性 tie-break = 锚点下标升序。
static func ranked_winner_anchor_indices(model: Dictionary) -> PackedInt32Array:
	var winners: PackedInt32Array = model.get("winner_per_anchor", PackedInt32Array())
	var winner_scores: PackedFloat32Array = model.get("winner_scores", PackedFloat32Array())
	var scored: Array[int] = []
	for i in range(winners.size()):
		if winners[i] < 0:
			continue
		scored.append(i)
	scored.sort_custom(func(a: int, b: int) -> bool:
		var a_score := winner_scores[a] if a < winner_scores.size() else float(anchor_asset_record(model, a, winners[a]).get("score", -INF))
		var b_score := winner_scores[b] if b < winner_scores.size() else float(anchor_asset_record(model, b, winners[b]).get("score", -INF))
		if a_score != b_score:
			return a_score > b_score
		return a < b)
	var out := PackedInt32Array()
	for anchor_index in scored:
		out.append(anchor_index)
	return out


# ---- Golden v2 格式器（tools/golden_snapshot_check.js 消费；行格式逐字冻结 F6）----

## 完整快照文本。头行/段行/锚点行格式与量化数学逐字沿用旧 demo（run_golden_snapshot +
## _golden_sections_from_results）；meta 行 anchor_spacing 载体退役（拍板项 2 CPU 网格
## 锚点退役），换新链确定性配置七元组。golden_anchor_limit>0 时锚点段按排序序截前 N
## （观察侧截断，防 js LCS diff 爆内存；值写进 meta，截断可审计）。
static func golden_snapshot_text(model: Dictionary, asset_names: Array, config: Dictionary) -> String:
	if not bool(model.get("ok", false)):
		return "ERROR model_not_ok %s" % str(model.get("reason", "?"))
	var grid: Vector3i = model.get("grid", Vector3i.ZERO)
	var anchor_limit := int(config.get("golden_anchor_limit", 0))
	var anchor_count := int(model.get("anchor_count", 0))
	var emit_count := anchor_count if anchor_limit <= 0 else mini(anchor_limit, anchor_count)
	var tile_rect: Rect2i = config.get("prefilter_tile_rect", Rect2i())
	var lines: Array[String] = [
		"golden volume_score v2",
		"meta asset_count=%d anchor_count=%d grid=%dx%dx%d rotation_slots=%d min_target_interest=%.3f min_prefilter_score=%.3f tile_rect=%d,%d,%dx%d golden_anchor_limit=%d" % [
			asset_names.size(), anchor_count, grid.x, grid.y, grid.z,
			int(config.get("rotation_slots", 12)),
			float(config.get("min_target_interest", 0.01)),
			float(config.get("min_prefilter_score", 0.35)),
			tile_rect.position.x, tile_rect.position.y, tile_rect.size.x, tile_rect.size.y,
			anchor_limit,
		],
	]
	var anchor_voxels: Array = model.get("anchor_voxels", [])
	for a in range(asset_names.size()):
		lines.append("asset %d name=%s" % [a, str(asset_names[a])])
		for ai in range(emit_count):
			var record := anchor_asset_record(model, ai, a)
			lines.append("anchor %d voxel=%s valid=%d yaw=%d gain_q1000=%d" % [
				ai,
				str(anchor_voxels[ai]),
				1 if bool(record.get("valid", false)) else 0,
				int(record.get("rotation_index", 0)),
				int(round(clampf(float(record.get("score", 0.0)), -1000.0, 1000.0) * 1000.0)),
			])
	return "\n".join(lines)
