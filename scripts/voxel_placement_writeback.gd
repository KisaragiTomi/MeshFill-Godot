class_name VoxelPlacementWriteback

## 把已接受的 placement 结果回写到 SceneVoxelCommitter / GPU autoobject runtime 的子系统
## (从 VoxelPlacementGenerator 抽出)。committer/runtime 经参数传入；通过 _generator 反向引用
## 调用少量配置/校验 helper；借用生成器 RenderingDevice。
extends "res://scripts/godot_compute_shader_base.gd"

## 生成器反向引用(调 _object_bool/_object_summary/_validate_gpu_runtime_profile_contract 等)
var _generator: VoxelPlacementGenerator = null

const AutoObject := preload("res://scripts/auto_object.gd")
const PlacementResultCodec := preload("res://scripts/utils/placement_result_codec.gd")
const ReportSchema := preload("res://scripts/utils/report_schema.gd")

## 共享派发骨架（PlacementResultCodec.dispatch_results_to_world）的 fail_step →
## 本文件既有 reason 诊断字符串（逐字保持）。
const WORLD_CONVERT_FAIL_REASONS := {
	"shader": "world_convert_shader_not_ready",
	"world_buffer": "world_convert_buffer_create_failed",
	"uniform_set": "world_convert_uniform_set_failed",
	"compute_list": "world_convert_compute_list_failed",
}


## --- 迁移自 generator 的 writeback 函数 ---
## 探测 runtime_provider 支持的写回 API：仅 GPU 常驻批量入口
## spawn_batch_from_accepted_placement_gpu_buffers；不支持则返回 "none"
## （CPU 字典逐条 spawn / 命令队列桥路径已删除）。
static func _runtime_writeback_spawn_api(runtime_provider: Object) -> String:
	if runtime_provider == null:
		return "none"
	if runtime_provider.has_method("spawn_batch_from_accepted_placement_gpu_buffers"):
		return "spawn_batch_from_accepted_placement_gpu_buffers"
	return "none"



## 根据 spawn_api 与是否启用，映射出对应的写回模式标签字符串。
static func _runtime_writeback_mode_from_api(spawn_api: String, enabled: bool) -> String:
	if not enabled:
		return "not_requested"
	if spawn_api == "spawn_batch_from_accepted_placement_gpu_buffers":
		return "gpu_resident_placement_buffer_writeback"
	return "none"



## 将 flush_result 中 GPU 常驻分配器写回相关的字段拷贝进 report，并在 shader 未消费记录时推导 blocked_reason。
static func _copy_gpu_autoobject_runtime_flush_contract(report: Dictionary, flush_result: Dictionary) -> void:
	if flush_result.is_empty():
		return
	var shader_consumed := bool(flush_result.get("accepted_placement_record_shader_consumed", false))
	for key in [
		"runtime_command_flush_mode",
		"accepted_placement_record_schema_version",
		"accepted_placement_record_stride_bytes",
		"accepted_placement_record_count",
		"accepted_placement_record_byte_count",
		"accepted_placement_record_debug_packed",
		"accepted_placement_record_shader_consumed",
		"accepted_placement_record_shader_name",
		"accepted_placement_record_shader_path",
		"accepted_placement_record_shader_dispatch_count",
		"accepted_placement_record_shader_local_size_x",
		"resident_gpu_allocator_writeback",
		"resident_gpu_allocator_writeback_mode",
	]:
		if flush_result.has(key):
			report[key] = flush_result[key]
	var shader_stats = flush_result.get("accepted_placement_record_shader_stats", {})
	report["accepted_placement_record_shader_stats"] = (shader_stats as Dictionary).duplicate(true) if shader_stats is Dictionary else {}
	var blocked_reason := str(flush_result.get(
		"resident_gpu_allocator_writeback_blocked_reason",
		"none" if shader_consumed else "no_resident_allocator_shader_dispatch"
	))
	if not shader_consumed and blocked_reason == "none":
		blocked_reason = str(flush_result.get("reason", "accepted_placement_record_shader_not_consumed"))
	report["resident_gpu_allocator_writeback_blocked_reason"] = blocked_reason
	if shader_consumed:
		report["runtime_command_flush_mode"] = str(flush_result.get("runtime_command_flush_mode", "resident_accepted_placement_record_shader_writeback"))
		report["accepted_placement_record_shader_consumed"] = true
		report["resident_gpu_allocator_writeback_mode"] = str(flush_result.get("resident_gpu_allocator_writeback_mode", "resident_object_buffer_writeback"))
		report["resident_gpu_allocator_record_stride_bytes"] = int(flush_result.get(
			"resident_gpu_allocator_record_stride_bytes",
			flush_result.get("accepted_placement_record_stride_bytes", report.get("accepted_placement_record_stride_bytes", 0))
		))
		report["resident_gpu_allocator_owner"] = str(flush_result.get("resident_gpu_allocator_owner", "GPUAutoObjectRuntime"))
	elif flush_result.has("resident_gpu_allocator_record_stride_bytes"):
		report["resident_gpu_allocator_record_stride_bytes"] = int(flush_result.get("resident_gpu_allocator_record_stride_bytes", 0))
	if not shader_consumed and flush_result.has("resident_gpu_allocator_owner"):
		report["resident_gpu_allocator_owner"] = str(flush_result.get("resident_gpu_allocator_owner", "none"))



## 合并两个 shader 统计字典：数值字段相加，非数值字段直接覆盖。
static func _merge_gpu_autoobject_runtime_shader_stats(target: Dictionary, source: Dictionary) -> Dictionary:
	var merged := {}
	for key in target.keys():
		merged[key] = target[key]
	for key in source.keys():
		var source_value = source[key]
		if source_value is int or source_value is float:
			merged[key] = int(merged.get(key, 0)) + int(source_value)
		else:
			merged[key] = source_value
	return merged



## 将多次(资产/批次)GPU flush 写回结果的契约字段累加/合并进 target：记录数与字节数累加，
## schema/stride/shader 名称等信息仅在首次写入，多种模式不一致时标记为 "mixed"。
static func _merge_gpu_autoobject_runtime_flush_contract(target: Dictionary, source: Dictionary) -> void:
	if source.is_empty():
		return
	var source_record_count := int(source.get("accepted_placement_record_count", 0))
	var target_record_count_before := int(target.get("accepted_placement_record_count", 0))
	var source_shader_consumed := bool(source.get("accepted_placement_record_shader_consumed", false))
	for key in [
		"accepted_placement_record_schema_version",
		"accepted_placement_record_stride_bytes",
		"accepted_placement_record_shader_local_size_x",
	]:
		if source.has(key) and int(target.get(key, 0)) == 0:
			target[key] = source[key]
	for key in [
		"accepted_placement_record_shader_name",
		"accepted_placement_record_shader_path",
	]:
		var source_text := str(source.get(key, "none"))
		if source.has(key) and source_text != "none" and str(target.get(key, "none")) == "none":
			target[key] = source[key]
	if source.has("runtime_command_flush_mode"):
		var source_mode := str(source.get("runtime_command_flush_mode", "none"))
		var target_mode := str(target.get("runtime_command_flush_mode", "none"))
		if target_record_count_before <= 0 or target_mode == "none":
			target["runtime_command_flush_mode"] = source_mode
		elif source_mode != "none" and target_mode != source_mode:
			target["runtime_command_flush_mode"] = "mixed"
	target["accepted_placement_record_count"] = target_record_count_before + source_record_count
	target["accepted_placement_record_byte_count"] = int(target.get("accepted_placement_record_byte_count", 0)) + int(source.get("accepted_placement_record_byte_count", 0))
	if source_record_count > 0:
		target["accepted_placement_record_debug_packed"] = bool(source.get("accepted_placement_record_debug_packed", false)) if target_record_count_before <= 0 else bool(target.get("accepted_placement_record_debug_packed", false)) and bool(source.get("accepted_placement_record_debug_packed", false))
		target["accepted_placement_record_shader_consumed"] = source_shader_consumed if target_record_count_before <= 0 else bool(target.get("accepted_placement_record_shader_consumed", false)) and source_shader_consumed
	elif source_shader_consumed:
		target["accepted_placement_record_shader_consumed"] = true
	target["accepted_placement_record_shader_dispatch_count"] = int(target.get("accepted_placement_record_shader_dispatch_count", 0)) + int(source.get("accepted_placement_record_shader_dispatch_count", 0))
	var target_stats = target.get("accepted_placement_record_shader_stats", {})
	var source_stats = source.get("accepted_placement_record_shader_stats", {})
	target["accepted_placement_record_shader_stats"] = _merge_gpu_autoobject_runtime_shader_stats(
		(target_stats as Dictionary) if target_stats is Dictionary else {},
		(source_stats as Dictionary) if source_stats is Dictionary else {}
	)
	if source.has("resident_gpu_allocator_writeback"):
		target["resident_gpu_allocator_writeback"] = bool(target.get("resident_gpu_allocator_writeback", false)) or bool(source.get("resident_gpu_allocator_writeback", false))
	if source.has("resident_gpu_allocator_writeback_mode"):
		var source_writeback_mode := str(source.get("resident_gpu_allocator_writeback_mode", "none"))
		var target_writeback_mode := str(target.get("resident_gpu_allocator_writeback_mode", "none"))
		if target_record_count_before <= 0 or target_writeback_mode == "none":
			target["resident_gpu_allocator_writeback_mode"] = source_writeback_mode
		elif source_record_count > 0 and target_writeback_mode != source_writeback_mode:
			target["resident_gpu_allocator_writeback_mode"] = "mixed"
	if source.has("resident_gpu_allocator_record_stride_bytes") and int(target.get("resident_gpu_allocator_record_stride_bytes", 0)) == 0:
		target["resident_gpu_allocator_record_stride_bytes"] = int(source.get("resident_gpu_allocator_record_stride_bytes", 0))
	if source.has("resident_gpu_allocator_owner") and str(target.get("resident_gpu_allocator_owner", "none")) == "none":
		target["resident_gpu_allocator_owner"] = str(source.get("resident_gpu_allocator_owner", "none"))
	var consumed_after := bool(target.get("accepted_placement_record_shader_consumed", false))
	var source_blocked_reason := str(source.get(
		"resident_gpu_allocator_writeback_blocked_reason",
		"none" if source_shader_consumed else "no_resident_allocator_shader_dispatch"
	))
	if consumed_after:
		target["resident_gpu_allocator_writeback_blocked_reason"] = "none"
	elif source_blocked_reason != "none":
		target["resident_gpu_allocator_writeback_blocked_reason"] = source_blocked_reason



## 唯一发射口：writeback 报告一律经 ReportSchema.build 组装（values 里未声明的键
## authoring-time push_error）。build 按 values.has 跳过缺席键，条件键的在场性由收集处决定；
## diag tier 仅 include_diagnostics（placement settings 的 "include_diagnostics" 键）时输出。
static func _emit_writeback_report(values: Dictionary, include_diagnostics: bool = false) -> Dictionary:
	return ReportSchema.build(ReportSchema.WRITEBACK_REPORT, values, include_diagnostics)


## GPU AutoObject 运行时写回报告的共有骨架（两个 builder 逐字重复的 ~30 个置空/置零默认键）。
## 收敛为一处 SSOT（键清单/分级见 ReportSchema.WRITEBACK_REPORT）；spawn_api/enabled 参数化少数
## 随 enabled 变的键。各 builder 从骨架起手收集 values，最终经 _emit_writeback_report 发出。
func _new_gpu_autoobject_runtime_writeback_skeleton(spawn_api: String, enabled: bool) -> Dictionary:
	return {
		"gpu_first": true,
		"cpu_fallback": false,
		"accepted_placement_writeback_mode": _runtime_writeback_mode_from_api(spawn_api, enabled),
		"accepted_placement_record_source": "vpg_resident_placement_buffers" if enabled else "none",
		"accepted_placement_origin_record_source": "vpg_resident_placement_buffers" if enabled else "none",
		"accepted_placement_spawn_api": spawn_api,
		"cpu_batch_bridge": false,
		"runtime_command_flush_mode": "none",
		"accepted_placement_record_schema_version": 0,
		"accepted_placement_record_stride_bytes": 0,
		"accepted_placement_record_count": 0,
		"accepted_placement_record_byte_count": 0,
		"accepted_placement_record_debug_packed": false,
		"accepted_placement_record_shader_consumed": false,
		"accepted_placement_record_shader_name": "none",
		"accepted_placement_record_shader_path": "none",
		"accepted_placement_record_shader_dispatch_count": 0,
		"accepted_placement_record_shader_local_size_x": 0,
		"accepted_placement_record_shader_stats": {},
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"resident_gpu_allocator_record_stride_bytes": 0,
		"resident_gpu_allocator_owner": "none",
		"resident_gpu_allocator_writeback_blocked_reason": "none",
		"spawned_count": 0,
		"failed_count": 0,
		"object_ids": [],
		"spawned_result_indices": [],
	}


## 创建一份初始的 GPU AutoObject 运行时写回报告(所有计数/数组字段先置空或置零)，
## 依据 runtime_provider/profile_container 摘要与 enabled 开关填充初始状态。
func _new_gpu_autoobject_runtime_writeback_report(
	runtime_provider: Object,
	profile_container: Object,
	gpu_contract: Dictionary,
	enabled: bool,
	include_diagnostics: bool = false
) -> Dictionary:
	var spawn_api := _runtime_writeback_spawn_api(runtime_provider) if enabled else "none"
	var ready := enabled and bool(gpu_contract.get("ok", false))
	var report := _new_gpu_autoobject_runtime_writeback_skeleton(spawn_api, enabled)
	report["ok"] = ready
	report["reason"] = str(gpu_contract.get("reason", "not_requested")) if enabled else "not_requested"
	report["writeback_reason"] = ""
	report["readback_source"] = "gpu_storage_buffers" if ready else "none"
	report["runtime_read_source"] = "gpu_storage_buffers" if ready else "none"
	report["accepted_count"] = 0
	report["runtime_summary"] = _generator._object_summary(runtime_provider)
	report["profile_summary"] = _generator._object_summary(profile_container)
	return _emit_writeback_report(report, include_diagnostics)



## 将单个资产的写回报告(source)累加合并进总报告(target)：合并成功标志/原因、各类计数、
## 对象 ID 与摘要数组、flush 契约字段，并据此更新 readback_source/runtime_read_source。
## diag 键（readback/runtime_read_source、runtime/profile_summary 等）按在场性合并——
## 报告未请求 include_diagnostics 时这些键缺席，merge 不得重新引入。
func _merge_gpu_autoobject_runtime_writeback_report(target: Dictionary, source: Dictionary) -> void:
	if target.is_empty() or source.is_empty():
		return
	target["ok"] = bool(target.get("ok", true)) and bool(source.get("ok", true))
	if not bool(source.get("ok", true)):
		var failure_reason := str(source.get("reason", "runtime_writeback_failed"))
		target["reason"] = failure_reason
		target["writeback_reason"] = failure_reason
		if target.has("readback_source"):
			target["readback_source"] = "none"
			target["runtime_read_source"] = "none"
	elif str(target.get("writeback_reason", "")).is_empty():
		target["writeback_reason"] = str(source.get("reason", "gpu_runtime_writeback_ready"))
	target["accepted_count"] = int(target.get("accepted_count", 0)) + int(source.get("accepted_count", 0))
	target["spawned_count"] = int(target.get("spawned_count", 0)) + int(source.get("spawned_count", 0))
	target["failed_count"] = int(target.get("failed_count", 0)) + int(source.get("failed_count", 0))
	var object_ids: Array = target.get("object_ids", [])
	object_ids.append_array(source.get("object_ids", []))
	target["object_ids"] = object_ids
	var spawned_result_indices: Array = target.get("spawned_result_indices", [])
	spawned_result_indices.append_array(source.get("spawned_result_indices", []))
	target["spawned_result_indices"] = spawned_result_indices
	if source.has("runtime_summary") or target.has("runtime_summary"):
		target["runtime_summary"] = source.get("runtime_summary", target.get("runtime_summary", {}))
	if source.has("profile_summary") or target.has("profile_summary"):
		target["profile_summary"] = source.get("profile_summary", target.get("profile_summary", {}))
	for key in [
		"accepted_placement_writeback_mode",
		"accepted_placement_record_source",
		"accepted_placement_origin_record_source",
		"accepted_placement_spawn_api",
		"cpu_batch_bridge",
		"accepted_placement_record_stride_bytes",
	]:
		if source.has(key):
			target[key] = source[key]
	_merge_gpu_autoobject_runtime_flush_contract(target, source)
	if target.has("readback_source"):
		if not bool(target.get("ok", false)):
			target["readback_source"] = "none"
			target["runtime_read_source"] = "none"
		elif object_ids.size() > 0:
			target["readback_source"] = "gpu_storage_buffers"
			target["runtime_read_source"] = "gpu_storage_buffers"
		else:
			target["readback_source"] = str(target.get("readback_source", "none"))
			target["runtime_read_source"] = str(target.get("runtime_read_source", "none"))
	target["live_count"] = int(source.get("live_count", target.get("live_count", 0)))
	target["pending_dirty_delta_count"] = int(source.get("pending_dirty_delta_count", target.get("pending_dirty_delta_count", 0)))


## 将整个公共候选池的已接受放置结果以 GPU 常驻缓冲区形式一次写回
## GPU AutoObject 运行时（mixed-asset）：在 VPG 常驻 result 记录缓冲区上调度
## placement_results_to_world pass（pivot per-record 查 pivot_records），再调用
## runtime.spawn_batch_from_accepted_placement_gpu_buffers 单次 dispatch 写入
## 全部对象状态；apply shader 按 record 的 asset_index 查 asset_lookup 取得
## profile_id/object_type（不再逐资产 dispatch）。全程无 CPU 回读。
func _write_mixed_accepted_placements_to_gpu_runtime(
	runtime_provider: Object,
	placement_handoff: Dictionary,
	asset_lookup_rid: RID,
	profile_arena_rid: RID,
	rotation_slots: int,
	common_settings: Dictionary,
	world_convert_params: Dictionary
) -> Dictionary:
	var spawn_api := _runtime_writeback_spawn_api(runtime_provider)
	var include_diagnostics := bool(common_settings.get("include_diagnostics", false))
	var record_count := int(placement_handoff.get("result_count", 0))
	# 共有骨架（~30 键）来自 SSOT；此路径 always-enabled，故 skeleton(spawn_api, true) + 差异键覆盖。
	var report := _new_gpu_autoobject_runtime_writeback_skeleton(spawn_api, true)
	report["ok"] = true
	report["reason"] = "gpu_runtime_writeback_ready"
	report["readback_source"] = "gpu_storage_buffers"
	report["runtime_read_source"] = "gpu_storage_buffers"
	report["accepted_count"] = record_count
	if runtime_provider == null or spawn_api == "none":
		report["ok"] = false
		report["reason"] = "missing_gpu_autoobject_runtime_writeback_target"
		report["readback_source"] = "none"
		report["runtime_read_source"] = "none"
		return _emit_writeback_report(report, include_diagnostics)
	if not _generator._object_bool(runtime_provider, "is_gpu_ready", "is_ready"):
		report["ok"] = false
		report["reason"] = "gpu_autoobject_runtime_not_ready"
		report["readback_source"] = "none"
		report["runtime_read_source"] = "none"
		return _emit_writeback_report(report, include_diagnostics)
	if record_count <= 0:
		report["reason"] = "no_accepted_placements"
		return _emit_writeback_report(report, include_diagnostics)
	var placement_results_rid: RID = placement_handoff.get("placement_results_rid", RID())
	var stamp_bounds_rid: RID = placement_handoff.get("stamp_bounds_rid", RID())
	if not placement_results_rid.is_valid() or not stamp_bounds_rid.is_valid() or not asset_lookup_rid.is_valid():
		report["ok"] = false
		report["reason"] = "missing_resident_placement_buffers"
		report["readback_source"] = "none"
		report["runtime_read_source"] = "none"
		return _emit_writeback_report(report, include_diagnostics)

	# Same-device contract: the GPU runtime-profile contract already pinned the
	# VPG placement buffers to the runtime's device; borrow it here.
	var runtime_rd := rendering_device_of(runtime_provider)
	if runtime_rd == null:
		report["ok"] = false
		report["reason"] = "runtime_rendering_device_missing_for_resident_writeback"
		report["readback_source"] = "none"
		report["runtime_read_source"] = "none"
		return _emit_writeback_report(report, include_diagnostics)
	if _rd != runtime_rd:
		attach_rendering_device(runtime_rd, false)

	var world_convert := _dispatch_world_results_resident(
		placement_results_rid,
		record_count,
		maxi(rotation_slots, 1),
		Vector3.ZERO,
		world_convert_params,
		profile_arena_rid
	)
	if not bool(world_convert.get("ok", false)):
		report["ok"] = false
		report["reason"] = str(world_convert.get("reason", "world_convert_dispatch_failed"))
		report["readback_source"] = "none"
		report["runtime_read_source"] = "none"
		return _emit_writeback_report(report, include_diagnostics)

	var asset_params := {
		"profile_id": -1,
		"object_type": 0,
		"object_flags": 0,
		"dirty_flags": _runtime_writeback_dirty_flags({}, {}, common_settings),
		"asset_index": -1,
		"grid_size": world_convert_params.get("grid_size", Vector3i.ZERO),
	}
	var runtime_report_raw = runtime_provider.call(
		"spawn_batch_from_accepted_placement_gpu_buffers",
		{
			"placement_results_rid": placement_results_rid,
			"world_results_rid": world_convert.get("world_results_rid", RID()),
			"stamp_bounds_rid": stamp_bounds_rid,
			"asset_lookup_rid": asset_lookup_rid,
			# Element capacity of asset_lookup_rid (from its allocation point) —
			# the apply shader's mixed-asset capacity gate reads it from push.
			"asset_lookup_capacity": int(placement_handoff.get("asset_lookup_capacity", 0)),
		},
		record_count,
		asset_params,
		common_settings.get("runtime_writeback_options", {})
	)
	# The runtime dispatch has submitted+synced; the transient world buffer can go.
	gc_frame()
	if not (runtime_report_raw is Dictionary):
		report["ok"] = false
		report["reason"] = "runtime_spawn_failed"
		report["writeback_detail_reason"] = "resident_spawn_result_invalid"
		report["failed_count"] = record_count
		report["readback_source"] = "none"
		report["runtime_read_source"] = "none"
		return _emit_writeback_report(report, include_diagnostics)
	var runtime_report := (runtime_report_raw as Dictionary).duplicate(true)
	_copy_gpu_autoobject_runtime_flush_contract(report, runtime_report)
	if not bool(runtime_report.get("ok", false)):
		report["ok"] = false
		report["reason"] = "runtime_spawn_failed"
		report["writeback_detail_reason"] = str(runtime_report.get("reason", "resident_batch_spawn_failed"))
		report["failed_count"] = record_count
		report["readback_source"] = "none"
		report["runtime_read_source"] = "none"
		return _emit_writeback_report(report, include_diagnostics)

	report["spawned_count"] = int(runtime_report.get("spawned_count", 0))
	report["object_ids"] = runtime_report.get("object_ids", [])
	var spawned_result_indices: Array = []
	for i in range(record_count):
		spawned_result_indices.append(i)
	report["spawned_result_indices"] = spawned_result_indices
	report["pending_dirty_delta_count"] = int(runtime_report.get("pending_dirty_delta_count", 0))
	# Production path: no live-count/alive-buffer readback verification; the
	# resident shader stats (debug opt-in) cover apply-count validation.
	report["runtime_summary"] = _generator._object_summary(runtime_provider)
	return _emit_writeback_report(report, include_diagnostics)


## 在 VPG 常驻 result 记录缓冲区上调度 placement_results_to_world pass，
## 输出常驻 world 缓冲区（SCOPE_FRAME，由 runtime 消费后经 gc_frame 释放）。
## profile_arena_rid 有效时走 per-record pivot（record 的槽内局部 pivot 下标 + profile_index）。
func _dispatch_world_results_resident(
	placement_results_rid: RID,
	record_count: int,
	rotation_count: int,
	pivot_offset: Vector3,
	world_convert_params: Dictionary,
	profile_arena_rid: RID = RID()
) -> Dictionary:
	if _rd == null:
		return {"ok": false, "reason": "missing_rendering_device"}
	# voxel_size / grid_origin 缺失或类型不符时不再兜底成 ONE / ZERO：那是
	# "单位体素、原点在世界零点"的假设，会把整批对象按错误的比例和偏移放进世界，
	# 而且全程没有任何报错。
	var voxel_size_value = world_convert_params.get("voxel_size", null)
	var grid_origin_value = world_convert_params.get("grid_origin", null)
	if not (voxel_size_value is Vector3) or not (grid_origin_value is Vector3):
		push_error("[VoxelPlacementWriteback] world_convert_params 缺少合法的 voxel_size/grid_origin voxel_size=%s grid_origin=%s —— 拒绝用单位体素/零原点换算世界坐标" % [
			str(voxel_size_value), str(grid_origin_value)])
		assert(false, "VoxelPlacementWriteback: world_convert_params voxel_size/grid_origin invalid")
		return {"ok": false, "reason": "world_convert_params_invalid"}
	var voxel_size: Vector3 = voxel_size_value
	var grid_origin: Vector3 = grid_origin_value
	if profile_arena_rid.is_valid():
		track_borrowed_rid(profile_arena_rid, KIND_BUFFER, SCOPE_FRAME, "auto_voxel_runtime_profile_container:profile_arena")
	var dispatched := PlacementResultCodec.dispatch_results_to_world(
		self, placement_results_rid, record_count, rotation_count,
		grid_origin, voxel_size, pivot_offset,
		"vpg_resident_world_results", "vpg_resident_world_results_set0",
		profile_arena_rid
	)
	if not bool(dispatched.get("ok", false)):
		# fail_step 未登记时不再兜底成 "world_convert_shader_not_ready"：未知失败被
		# 贴上已知标签，报告里看到的原因是假的。
		var fail_step := str(dispatched.get("fail_step", ""))
		if not WORLD_CONVERT_FAIL_REASONS.has(fail_step):
			push_error("[VoxelPlacementWriteback] dispatch_results_to_world 返回未登记的 fail_step='%s'（已知：%s）record_count=%d" % [
				fail_step, str(WORLD_CONVERT_FAIL_REASONS.keys()), record_count])
			assert(false, "VoxelPlacementWriteback: unmapped world convert fail_step")
			return {"ok": false, "reason": "world_convert_unknown_fail_step:%s" % fail_step}
		return {"ok": false, "reason": str(WORLD_CONVERT_FAIL_REASONS[fail_step])}
	return {"ok": true, "reason": "ok", "world_results_rid": dispatched.get("world_results_rid", RID())}


## 按优先级(common_settings → asset_def → per_asset_settings)解析写回用的数值 object_type，都未设置则返回 0。
static func _runtime_writeback_object_type(asset_def: Dictionary, per_asset_settings: Dictionary, common_settings: Dictionary) -> int:
	if common_settings.has("runtime_writeback_object_type"):
		return int(common_settings.get("runtime_writeback_object_type", 0))
	if asset_def.has("runtime_writeback_object_type"):
		return int(asset_def.get("runtime_writeback_object_type", 0))
	if asset_def.has("object_type"):
		return int(asset_def.get("object_type", 0))
	if per_asset_settings.has("object_type"):
		return int(per_asset_settings.get("object_type", 0))
	return 0



## 构造脏标记(dirty_flags)字典，默认 auto/object_refs 均为 true，并依次合并 common/asset/per-asset 三层覆盖。
static func _runtime_writeback_dirty_flags(asset_def: Dictionary, per_asset_settings: Dictionary, common_settings: Dictionary) -> Dictionary:
	var flags := {"auto": true, "object_refs": true}
	_runtime_writeback_merge_flags(flags, common_settings.get("runtime_writeback_dirty_flags", {}))
	_runtime_writeback_merge_flags(flags, asset_def.get("runtime_writeback_dirty_flags", {}))
	_runtime_writeback_merge_flags(flags, per_asset_settings.get("runtime_writeback_dirty_flags", {}))
	return flags



## 将 source（必须是字典）的每个键值转换为 bool 后合并进 target。
## 三处调用点都以 `.get("runtime_writeback_dirty_flags", {})` 取值，缺席时拿到的
## 就是 {}；走到非 Dictionary 分支只可能是调用方把该键配成了别的类型——不再静默
## 忽略（那会让配置的脏标记整层丢失，对象生成后不触发刷新且毫无提示）。
static func _runtime_writeback_merge_flags(target: Dictionary, source) -> void:
	if not (source is Dictionary):
		push_error("[VoxelPlacementWriteback] runtime_writeback_dirty_flags 类型非法 期望 Dictionary 实际 %s —— 该层脏标记覆盖会整层丢失" % type_string(typeof(source)))
		assert(false, "VoxelPlacementWriteback: runtime_writeback_dirty_flags type invalid")
		return
	for key in (source as Dictionary).keys():
		target[key] = bool((source as Dictionary)[key])




