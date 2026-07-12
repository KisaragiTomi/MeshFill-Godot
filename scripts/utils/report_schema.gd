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


## 布局元数据查询接口（schema 回显的去处）：channel 名表等「不是本次结果、是布局元数据」的键
## 从结果里挪来这里，消费者按需查询，不随每次输出发送。
static func metadata(schema: Dictionary) -> Dictionary:
	return schema.get("metadata", {}).duplicate(true)


## schema 声明的全部键（四级并集），用于消费者自检 / 测试。
static func declared_keys(schema: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for tier in TIERS:
		for key in schema.get(tier, []):
			out.append(str(key))
	return out


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
##   spa_test.check_resident_placement_writeback — ok/reason/writeback_detail_reason/spawned_count/
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

## SPA prepare_target_read_buffers_from_common_gpu 的失败 dict（同族 ×7-8）。
## reason 逐字断言（test_autoobject_probe_prefilter），故走 fail() 透传；运行时值经 extra 传入。
const TARGET_READ_BUFFER_FAILURE := {
	"name": "prepare_target_read_buffers",
	"failure_defaults": {
		"gpu_first": true,
		"cpu_fallback": false,
	},
}
