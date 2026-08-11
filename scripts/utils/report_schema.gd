@tool
class_name ReportSchema
extends RefCounted

## 管线输出字典的分级精简设施（《统一Debug承载与输出字典精简方案.md》方案二）。
##
## 管线的输出 dict 是隐式 API——没有 schema，生产端为了「不知道谁在消费」而防御性全量输出，
## 消费端不知道哪些键承重，于是键只增不减、恒定 provenance / 提升重复 / 可推导键 / schema 回显 /
## 空占位 / 输入 echo 六类冗余越长越多。本类给每个报告族一份 schema，把键分四级，由机器强制产出：
##
##   [b]core[/b]     —— 下游代码消费的结果与 ok/reason。            总是输出。
##   [b]contract[/b] —— 契约测试 / 桥客户端逐字断言的键（冻结名单）。总是输出（改名须同 commit 改测试）。
##   [b]diag[/b]     —— 人看的诊断（source 溯源、统计、快照）。      仅 include_diagnostics 请求时输出。
##   [b]derived[/b]  —— 可由其他键推导的键。                        从不输出（推导式写在 schema 注释）。
##
## [method build] 对 values 里[b]未声明[/b]的键 push_error——这是键膨胀的 authoring-time 刹车：
## 今后想加键必须先进某一 tier，一处可见。[method fail] 收编审计发现的重复失败 dict（SPA ×7、
## writeback 骨架 ×2、blocked/empty prefilter 等），产出规范 {ok:false, reason} + schema 的失败默认值。
##
## 与 [DebugBufferSet] 共享同一条原则——约定由机器强制，观测数据按需产出；schema 回显（布局元数据，
## 如 debug_channel_names）移到 [method metadata] 查询接口，不随每次结果发。

const TIER_CORE := "core"
const TIER_CONTRACT := "contract"
const TIER_DIAG := "diag"
const TIER_DERIVED := "derived"
const TIERS := [TIER_CORE, TIER_CONTRACT, TIER_DIAG, TIER_DERIVED]


## 按 schema 分级从 values 里挑键组装输出：
##   core + contract 总是发（若 values 里有）；diag 仅 include_diagnostics 时发；derived 从不发。
## values 里出现[b]任何未在四级中声明的键[/b]→ push_error（authoring-time 刹车）。
static func build(schema: Dictionary, values: Dictionary, include_diagnostics: bool = false) -> Dictionary:
	var declared := _declared_key_set(schema)
	for key in values:
		if not declared.has(key):
			push_error("ReportSchema.build[%s]: 未声明的键 '%s'——加键须先进某一 tier（core/contract/diag/derived）" % [_schema_name(schema), key])
			assert(false, "ReportSchema.build: undeclared key")
	var out := {}
	_emit_tier(out, schema, values, TIER_CORE)
	_emit_tier(out, schema, values, TIER_CONTRACT)
	if include_diagnostics:
		_emit_tier(out, schema, values, TIER_DIAG)
	# derived 从不输出。
	return out


## 规范失败 dict：{ok:false, reason} + schema.failure_defaults + 调用方传入的运行时 extra。
## reason 逐字透传（契约测试常逐字断言 reason 后缀）。收编同族重复失败 dict。
static func fail(schema: Dictionary, reason: String, extra: Dictionary = {}) -> Dictionary:
	var out := {"ok": false, "reason": reason}
	var defaults: Dictionary = schema.get("failure_defaults", {})
	for key in defaults:
		out[key] = defaults[key]
	for key in extra:
		out[key] = extra[key]
	return out


## merge / 发射后突变的硬门（出口复验）：build() 的未声明键刹车只作用于组装时刻，
## 报告发射后若还被 merge 突变（如 writeback 总报告的逐资产累加），挂接前在此复验——
##   ① 出现未声明键；② 未请求 include_diagnostics 时含 diag 键（缺席的 diag 键不得被
##   merge 重新引入）；③ 出现 derived 键（永不输出）——均 push_error。
## 与 build 同款 authoring-time 语义：只刹车不修剪，原样返回 report 以便就地挂接。
static func validate_report(schema: Dictionary, report: Dictionary, include_diagnostics: bool = false) -> Dictionary:
	var declared := _declared_key_set(schema)
	var diag_keys := {}
	for key in schema.get(TIER_DIAG, []):
		diag_keys[str(key)] = true
	var derived_keys := {}
	for key in schema.get(TIER_DERIVED, []):
		derived_keys[str(key)] = true
	for key in report:
		if not declared.has(key):
			push_error("ReportSchema.validate_report[%s]: 发射后出现未声明键 '%s'——merge 突变须先把键登进某一 tier" % [_schema_name(schema), key])
			assert(false, "ReportSchema.validate_report: undeclared key")
		elif derived_keys.has(key):
			push_error("ReportSchema.validate_report[%s]: derived 键 '%s' 不得输出" % [_schema_name(schema), key])
			assert(false, "ReportSchema.validate_report: derived key emitted")
		elif not include_diagnostics and diag_keys.has(key):
			push_error("ReportSchema.validate_report[%s]: 未请求 include_diagnostics 时 merge 重新引入了 diag 键 '%s'" % [_schema_name(schema), key])
			assert(false, "ReportSchema.validate_report: diag key reintroduced")
	return report


## 布局元数据查询接口（schema 回显的去处）：channel 名表等「不是本次结果、是布局元数据」的键
## 从结果里挪来这里，消费者按需查询，不随每次输出发送。
static func metadata(schema: Dictionary) -> Dictionary:
	return schema.get("metadata", {}).duplicate(true)



static func _emit_tier(out: Dictionary, schema: Dictionary, values: Dictionary, tier: String) -> void:
	for key in schema.get(tier, []):
		if values.has(key):
			out[key] = values[key]


static func _declared_key_set(schema: Dictionary) -> Dictionary:
	var declared := {}
	for tier in TIERS:
		for key in schema.get(tier, []):
			declared[str(key)] = true
	return declared


static func _schema_name(schema: Dictionary) -> String:
	return str(schema.get("name", "report"))


# ── 报告族 schema（SSOT）──
#
# 每族一份。tier 判定规则：grep 全项目消费者（.gd + tools + 桥客户端），零读者的键进 derived 或删；
# 被 test_markdown_contracts / test_autoobject_probe_prefilter / spa_test 等逐字断言的进 contract。

## gpu_autoobject_runtime_writeback 报告（voxel_placement_writeback.gd 两个 builder 的共同 SSOT，
## 全部经 build() 发出）。migrate 轮（2026-07-12）已落：零消费者的溯源/摘要键降入 diag，
## 仅 placement settings 的 "include_diagnostics"（默认 false）请求时输出。
## 条件键（缺席时 build 跳过）：asset_index/profile_id/object_type（仅 per-asset 报告）、
## writeback_detail_reason（仅 runtime spawn 失败）、pending_dirty_delta_count（spawn 成功或 merge 后）、
## live_count/profile_summary（仅 merge 后的总报告）、runtime_summary（总报告恒有；per-asset 仅成功尾）。
## 冻结 contract 消费者（改名须同 commit 改读者）：
##   ~~spa_pipeline_checks.check_resident_placement_writeback~~（该套件 2026-08-07 已删）曾读 — ok/reason/writeback_detail_reason/spawned_count/
##     accepted_placement_spawn_api/accepted_placement_record_shader_consumed/
##     accepted_placement_record_shader_stats(applied,skipped)；
##   scene_placement_actor._accepted_placement_writeback_summary_from_placement — ok/reason/
##     runtime_command_flush_mode/accepted_placement_record_{schema_version,stride_bytes,shader_consumed,
##     shader_name,shader_path,shader_dispatch_count,shader_stats}/resident_gpu_allocator_writeback{,_mode,_blocked_reason}；
##   test_markdown_contracts._test_vpg_and_scene_tile_gpu_binding_contracts — 源码文本须含
##     "writeback_reason" 与 "cpu_fallback": false（writeback 骨架字面量，勿删——只降输出 tier，不删源码）。
const WRITEBACK_REPORT := {
	"name": "gpu_autoobject_runtime_writeback",
	"core": [
		"ok", "reason", "accepted_count", "spawned_count", "failed_count",
		"object_ids", "spawned_result_indices",
	],
	"contract": [
		"writeback_reason",
		"accepted_placement_writeback_mode", "accepted_placement_spawn_api",
		"runtime_command_flush_mode",
		"accepted_placement_record_schema_version", "accepted_placement_record_stride_bytes",
		"accepted_placement_record_count", "accepted_placement_record_byte_count",
		"accepted_placement_record_debug_packed", "accepted_placement_record_shader_consumed",
		"accepted_placement_record_shader_name", "accepted_placement_record_shader_path",
		"accepted_placement_record_shader_dispatch_count", "accepted_placement_record_shader_local_size_x",
		"accepted_placement_record_shader_stats",
		"resident_gpu_allocator_writeback", "resident_gpu_allocator_writeback_mode",
		"resident_gpu_allocator_record_stride_bytes", "resident_gpu_allocator_owner",
		"resident_gpu_allocator_writeback_blocked_reason",
		"asset_index", "profile_id", "object_type",
		"writeback_detail_reason", "pending_dirty_delta_count", "live_count",
	],
	"diag": [
		# migrate 轮全项目 grep 复核：零运行时读者（spa_test/scene_placement_actor 均不读；
		# test_markdown_contracts 对这些键只断言其他报告族/文档文本）。
		# 其中 gpu_first/cpu_fallback/*_source/cpu_batch_bridge 值恒定（恒定 provenance）——
		# 彻底删除是后续单独决策，本轮仅降级到 diag。
		"gpu_first", "cpu_fallback", "readback_source", "runtime_read_source",
		"accepted_placement_record_source", "accepted_placement_origin_record_source",
		"cpu_batch_bridge", "runtime_summary", "profile_summary",
	],
	# derived: —（本族无纯派生键）。
}

## VoxelPlacementGenerator run_multi_asset 顶层输出族（成功 / contract-blocked / 空帧三变体
## 的共同 SSOT，全部经 build() 发出）。anchor-fine 单管线（2026-07-13）：旧 run_minimal 族
## 已删除，其顶层承载键（placement_result_buffers/stamp_*/debug_voxel 等）并入本族 core。
## 条件键（缺席时 build 跳过，在场性由收集处决定）：
##   仅 blocked 变体：ok/contract_blocked/skipped_gpu_runtime_profile_contract/gpu_first/
##     runtime_read_source/readback_source（成功变体故意不发 ok——SPA 的 ok 门现状即靠缺席
##     走 false 分支，勿补发）；
##   成功变体门控键：gpu_state_chain（GPU 状态链激活，diag）、cpu_state_chain（compact 链）、
##     gpu_autoobject_runtime_writeback（write_accepted_placements_to_gpu_runtime）、
##     instance_stamp_writeback（gpu 链 stamp 提交）、placement_result_buffers/
##     placement_score_sum/placement_valid_count（retain_placement_result_buffers）、
##     stamp_delta_count（read_stamp_deltas/compact 链）、fine_winner_bytes（read_fine_winner_bytes
##     显式 opt-in；默认零回读，结果改经 fine_score_handoff 常驻交出）、debug_voxel
##     （debug_read_voxel_channels）、score_timing_profile（score_timing_profile 自带门）、
##     cpu_fallback（contract.reason != "not_requested"）；anchor_fine_contract 恒有。
## 冻结 contract 消费者（改名须同 commit 改读者）：
##   spa_pipeline_checks.check_resident_placement_writeback（spa_test 门面委托） — gpu_runtime_profile_contract/total_placed/
##     gpu_autoobject_runtime_writeback/asset_results；
##   scene_placement_actor.run_placement_pipeline — ok/total_placed/instance_stamp_writeback/
##     gpu_autoobject_runtime_writeback/cpu_state_chain/target_read_buffer_summary；
##   test_markdown_contracts._test_vpg_and_scene_tile_gpu_binding_contracts — VPG 源码文本须含
##     "contract_blocked" 与 "cpu_fallback": false（blocked builder 字面量，勿删源码，只动输出 tier）。
## 发射后突变：无——writeback merge（live_count/pending_dirty_delta_count 追加）发生在嵌套的
## WRITEBACK_REPORT 族报告内、且在 output 组装前，顶层键集不受影响。
const VPG_MULTI_ASSET_REPORT := {
	"name": "vpg_run_multi_asset",
	"core": [
		"ok", "asset_results", "total_placed",
		"complexity_field_out", "collision_field_out",
		# anchor-fine 单管线的顶层承载（旧 run_minimal 族的对应键上移至此）：
		"placement_result_buffers", "placement_score_sum", "placement_valid_count",
		"stamp_delta_count", "stamp_bounds",
		"debug_voxel", "fine_winner_bytes", "fine_candidates", "fine_candidate_bytes",
		"score_timing_profile",
	],
	"contract": [
		"contract_blocked", "cpu_fallback",
		"gpu_runtime_profile_contract",
		"anchor_fine_contract",
		# Score（fine_candidates_only）的常驻候选/胜出交接：借用 RID + stride + live count
		# 来源。必须恒发（contract tier），因为零回读的 Score 只靠它把结果交出去。
		"fine_score_handoff",
		"cpu_state_chain",
		"instance_stamp_writeback",
		"gpu_autoobject_runtime_writeback",
		"target_read_buffer_summary",
	],
	"diag": [
		# 零运行时读者的 provenance/诊断键（SPA 链只读 contract tier；processing_order
		# 仅文档提及；gpu_state_chain 仅诊断观测）。
		"processing_order", "gpu_state_chain",
		"skipped_gpu_runtime_profile_contract", "gpu_first",
		"runtime_read_source", "readback_source",
	],
	# derived: —（本族无纯派生键）。
}

## run_multi_asset 的 per-asset asset_result 族（成功 / 空占位 / blocked per-asset 变体的
## 共同 SSOT，全部经 build() 发出）。anchor-fine 单管线（2026-07-13）：per-asset 结果由
## 公共候选池按 record 的 asset_index 分组产生——不再有逐资产 GPU run，旧的配额跳过
## （skipped_quota）与 per-asset state-chain/route 键随之退役（quota 现为 reduce 的
## per-asset 上限，见 asset_lookup）。
## 条件键（缺席时 build 跳过）：
##   仅 blocked 变体：ok/contract_blocked/gpu_first/runtime_read_source/readback_source；
##   成功变体门控键：cpu_fallback（contract.reason != "not_requested" 时置 false）。
## 冻结 contract 消费者（改名须同 commit 改读者）：
##   spa_pipeline_checks.check_resident_placement_writeback（asset_results[0]，spa_test 门面委托）— world_results/results/
##     result_count。
const VPG_MULTI_ASSET_RESULT := {
	"name": "vpg_run_multi_asset_result",
	"core": [
		"ok", "asset_index", "results", "world_results", "result_count",
		"rotation_slots_used",
	],
	"contract": [
		"contract_blocked", "cpu_fallback",
		"gpu_runtime_profile_contract",
	],
	"diag": [
		"placement_output_gpu", "placement_output_readback_source",
		"gpu_first", "runtime_read_source", "readback_source",
	],
	# derived: —（本族无纯派生键）。
}

## SPA prepare_target_read_buffers_from_common_gpu 的失败 dict（同族 ×7-8）。
## reason 逐字断言（test_autoobject_probe_prefilter），故走 fail() 透传；运行时值经 extra 传入。
const TARGET_READ_BUFFER_FAILURE := {
	"name": "prepare_target_read_buffers",
	"failure_defaults": {
		"gpu_first": true,
		"cpu_fallback": false,
	},
}
