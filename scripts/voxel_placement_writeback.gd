class_name VoxelPlacementWriteback

## 把已接受的 placement 结果回写到 SceneVoxelCommitter / GPU autoobject runtime 的子系统
## (从 VoxelPlacementGenerator 抽出)。committer/runtime 经参数传入；通过 _generator 反向引用
## 调用少量配置/校验 helper；借用生成器 RenderingDevice。
extends "res://scripts/godot_compute_shader_base.gd"

## 生成器反向引用(调 _object_bool/_object_summary/_validate_gpu_runtime_profile_contract 等)
var _generator: VoxelPlacementGenerator = null

const AutoObject := preload("res://scripts/auto_object.gd")
const VoxelPlacementOutputScript := preload("res://scripts/voxel_placement_output.gd")
const VoxelFootprintBakerScript := preload("res://scripts/voxel_footprint_baker.gd")

const TILE_SIZE := 8
const FOOTPRINT_CAPACITY := 128
const RECORD_STRIDE := 4
const DELTA_STRIDE := 2
const STAMP_BOUNDS_STRIDE := 2
const FLAG_SUPPORT := 1
const FLAG_CLEARANCE := 2
const NUM_DEBUG_CHANNELS := 8
const ACCEPTED_PLACEMENT_SOURCE_BUFFER_INCOMPLETE_REASON := "incomplete_source_candidate_handoff_missing_payload_and_group_index_buffers"
const SCORE_CONTRACT_DEBUG_WORDS := 48
const SCORE_CONTRACT_MAGIC := 0x4D465052 # MFPR: MeshFill placement runtime/profile.
const CANDIDATE_ROUTE_BINDING_DEBUG_WORDS := 16
const CANDIDATE_ROUTE_ADAPTER_COUNT_WORDS := 4
const CANDIDATE_ROUTE_INDIRECT_ARGS_BYTES := 12
const CANDIDATE_ROUTE_SPARSE_ADAPTER_LOCAL_SIZE := 64
const BOX_FOOTPRINT_BAKE_SHADER_PATH := "res://shaders/bake_box_footprint.glsl"
const BOX_FOOTPRINT_BAKE_LOCAL_SIZE := 64
const CYLINDER_FOOTPRINT_BAKE_SHADER_PATH := "res://shaders/bake_cylinder_footprint.glsl"
const CYLINDER_FOOTPRINT_BAKE_LOCAL_SIZE := 64
const ROTATE_FOOTPRINT_Y_SHADER_PATH := "res://shaders/rotate_footprint_y.glsl"
const ROTATE_FOOTPRINT_Y_LOCAL_SIZE := 64
const GPU_RUNTIME_PROVIDER_CONFIG_KEYS := [
	"gpu_autoobject_runtime",
	"autoobject_runtime",
	"runtime",
]
const GPU_PROFILE_CONTAINER_CONFIG_KEYS := [
	"auto_voxel_runtime_profile_container",
	"runtime_profile_container",
	"profile_container",
]
const SCENE_PLACEMENT_ACTOR_CONFIG_KEYS := [
	"scene_placement_actor",
	"placement_actor",
	"spa",
]
const CANDIDATE_REGION_BY_ASSET_CONFIG_KEYS := [
	"candidate_voxel_regions_by_asset",
	"candidate_voxel_sparses_by_asset",
]
const CANDIDATE_ROUTE_CONTRACT_SCHEMA_VERSION := 1
const CANDIDATE_ROUTE_RECORD_STRIDE_BYTES := 16
const CANDIDATE_ROUTE_RANGE_STRIDE_BYTES := 16
const ASSET_CANDIDATE_REGION_CONFIG_KEYS := [
	"candidate_voxel_regions",
	"candidate_voxel_sparses",
]
const REQUIRED_GPU_RUNTIME_BUFFERS := [
	"alive",
	"generation",
	"type",
	"profile",
	"bounds_min",
	"bounds_max",
	"previous_bounds_min",
	"previous_bounds_max",
	"transform",
]
const REQUIRED_GPU_PROFILE_BUFFERS := [
	"profile_table",
	"probe_records",
	"pivot_records",
]
const DEBUG_CHANNEL_NAMES: PackedStringArray = [
	"target_coverage",
	"target_complexity_fit",
	"target_color_fit",
	"target_density",
	"placement_score",
	"support_ratio",
	"solid_collision",
	"clearance_overlap",
]
const SCORE_CONTRACT_DEBUG_NAMES: PackedStringArray = [
	"magic",
	"contract_enabled",
	"runtime_object_capacity",
	"profile_count",
	"alive_object_reads",
	"profile_records_matched",
	"runtime_overlap_tests",
	"runtime_overlap_hits",
	"profile_table_reads",
	"asset_profile_id",
	"candidate_invocations",
	"profile_complexity_q1000",
	"runtime_profile_reads",
	"runtime_profile_matches",
	"probe_record_reads",
	"reserved_profile_side_read",
	"pivot_record_reads",
	"probe_weight_q1000",
	"reserved_profile_side_metric",
	"pivot_bias_q1000",
	"profile_probe_count",
	"reserved_profile_side_count",
	"profile_pivot_count",
	"debug_max_target_coverage_q1000",
	"debug_max_target_complexity_fit_q1000",
	"debug_max_target_color_fit_q1000",
	"debug_max_target_density_q1000",
	"debug_max_placement_score_q1000",
	"debug_max_support_ratio_q1000",
	"debug_max_solid_collision_q1000",
	"debug_max_clearance_overlap_q1000",
	"runtime_spacing_tests",
	"runtime_spacing_profile_matches",
	"runtime_spacing_rejections",
	"runtime_spacing_min_distance_q1000",
	"scene_voxel_tile_object_ref_enabled",
	"scene_voxel_tile_object_ref_tile_reads",
	"scene_voxel_tile_object_ref_slot_reads",
	"scene_voxel_tile_object_ref_object_reads",
	"scene_voxel_tile_object_ref_duplicate_reads",
	"reserved40",
	"reserved41",
	"reserved42",
	"reserved43",
	"reserved44",
	"reserved45",
	"reserved46",
	"reserved47",
]
const SCENE_VOXEL_COMMITTER_CONFIG_KEY := "scene_voxel_committer"
const SCENE_VOXEL_TILE_COMMITTER_CONFIG_KEYS := [
	SCENE_VOXEL_COMMITTER_CONFIG_KEY,
	"sv_committer",
	"scene_voxel_tile_committer",
]
const SCENE_VOXEL_TILE_OBJECT_REF_BUFFER_NAME := "scene_voxel_tile_object_refs"
const SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_NUMERIC := "u32_numeric_ref_key_v1"
const SCENE_VOXEL_TILE_OBJECT_REF_STRIDE_BYTES := 4
const SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT := 8
const PREVIOUS_SCENE_VOXEL_COMMITTER_CONFIG_KEY := "vegetation" + "_exclusion"
const STAGE_SCENE_VOXEL_SOURCE_CANDIDATES_CONFIG_KEY := "stage_scene_voxel_source_candidates_to_resident_buffers"
const VOXEL_WRITE_SPEC_CONFIG_KEYS := [
	"asset",
	"base_pixel",
	"capture_size",
	"create_voxel_write_spec",
	"defer_blend",
	"generation_tick",
	"grid_origin",
	"grid_size",
	"group",
	"groups",
	"material",
	"mesh",
	"name",
	"placement_mesh",
	"record_id",
	SCENE_VOXEL_COMMITTER_CONFIG_KEY,
	"texture_resolution",
	PREVIOUS_SCENE_VOXEL_COMMITTER_CONFIG_KEY,
	"voxel_size",
	"volume_xz_resolution",
	AutoObject.INSTANCE_STAMP_WRITE_SPEC_META_KEY,
	"voxel_write_spec",
	"world_capture_size",
]
const SCENE_VOXEL_SOURCE_WRITE_DIAGNOSTIC_KEYS := [
	"source_write_handoff_mode",
	"source_write_batch_api",
	"cpu_pending_source_candidate_bridge",
	"pending_source_candidate_flush_api",
	"source_candidate_resolve_api",
	"resident_source_write_buffer",
	"resident_source_write_buffer_owner",
	"resident_source_write_buffer_rid",
	"resident_source_write_buffer_lifetime",
	"resident_source_write_buffer_stride_bytes",
	"resident_source_write_buffer_range_count",
	"resident_source_candidate_buffer_rid",
	"resident_source_candidate_buffer_stride_bytes",
	"resident_source_candidate_buffer_capacity",
	"resident_source_candidate_buffer_count",
	"resident_source_range_buffer_rid",
	"resident_source_range_buffer_stride_bytes",
	"resident_source_range_buffer_capacity",
	"resident_source_range_buffer_count",
	"resident_source_candidate_staging_epoch",
	"runtime_read_source",
	"final_source_stream_resident",
	"final_source_stream_resident_source",
	"resident_gpu_allocator_writeback",
	"resident_gpu_allocator_writeback_mode",
]


## --- 复制自 generator 的辅助 ---


## 按已知 meta key 依次在配置字典中查找已有的 voxel write spec 记录，返回第一个非空记录的副本；找不到则返回空字典。
static func _get_config_voxel_write_spec(config: Dictionary) -> Dictionary:
	for key in AutoObject.voxel_write_spec_meta_keys():
		var raw_record = config.get(key, {})
		if raw_record is Dictionary:
			var record := raw_record as Dictionary
			if not record.is_empty():
				return record.duplicate(true)
	return {}



## --- 迁移自 generator 的 writeback 函数 ---
## 探测 runtime_provider 支持的写回 API：优先批处理命令队列，其次 spawn_from_bounds，再次 spawn，都不支持则返回 "none"。
static func _runtime_writeback_spawn_api(runtime_provider: Object) -> String:
	if runtime_provider == null:
		return "none"
	if runtime_provider.has_method("stage_command") and runtime_provider.has_method("flush_command_queue"):
		return "stage_command_flush_command_queue"
	if runtime_provider.has_method("spawn_from_bounds"):
		return "spawn_from_bounds"
	if runtime_provider.has_method("spawn"):
		return "spawn"
	return "none"



## 根据 spawn_api 与是否启用，映射出对应的写回模式标签字符串。
static func _runtime_writeback_mode_from_api(spawn_api: String, enabled: bool) -> String:
	if not enabled:
		return "not_requested"
	if spawn_api == "stage_command_flush_command_queue":
		return "cpu_dictionary_to_gpu_runtime_batched_command_queue"
	return "cpu_dictionary_to_gpu_runtime_spawn"



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



## 创建一份初始的 GPU AutoObject 运行时写回报告(所有计数/数组字段先置空或置零)，
## 依据 runtime_provider/profile_container 摘要与 enabled 开关填充初始状态。
func _new_gpu_autoobject_runtime_writeback_report(
	runtime_provider: Object,
	profile_container: Object,
	gpu_contract: Dictionary,
	enabled: bool
) -> Dictionary:
	var runtime_summary := _generator._object_summary(runtime_provider)
	var profile_summary := _generator._object_summary(profile_container)
	var spawn_api := _runtime_writeback_spawn_api(runtime_provider) if enabled else "none"
	var command_queue_bridge := spawn_api == "stage_command_flush_command_queue"
	return {
		"ok": enabled and bool(gpu_contract.get("ok", false)),
		"reason": str(gpu_contract.get("reason", "not_requested")) if enabled else "not_requested",
		"contract_reason": str(gpu_contract.get("reason", "not_requested")) if enabled else "not_requested",
		"writeback_reason": "",
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "gpu_storage_buffers" if enabled and bool(gpu_contract.get("ok", false)) else "none",
		"runtime_read_source": "gpu_storage_buffers" if enabled and bool(gpu_contract.get("ok", false)) else "none",
		"accepted_placement_writeback_mode": _runtime_writeback_mode_from_api(spawn_api, enabled),
		"accepted_placement_record_source": "cpu_spawn_command_dictionaries" if command_queue_bridge else ("cpu_world_result_and_raw_result_dictionaries" if enabled else "none"),
		"accepted_placement_origin_record_source": "cpu_world_result_and_raw_result_dictionaries" if enabled else "none",
		"accepted_placement_spawn_api": spawn_api,
		"cpu_batched_command_queue_bridge": command_queue_bridge,
		"cpu_batch_bridge": command_queue_bridge,
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
		"resident_gpu_allocator_writeback_blocked_reason": "no_resident_allocator_shader_dispatch" if command_queue_bridge else "none",
		"accepted_count": 0,
		"spawned_count": 0,
		"failed_count": 0,
		"object_ids": [],
		"object_summaries": [],
		"spawned_result_indices": [],
		"command_queue_stage_count": 0,
		"command_queue_flush_count": 0,
		"runtime_summary": runtime_summary,
		"profile_summary": profile_summary,
	}



## 将单个资产的写回报告(source)累加合并进总报告(target)：合并成功标志/原因、各类计数、
## 对象 ID 与摘要数组、flush 契约字段，并据此更新 readback_source/runtime_read_source。
func _merge_gpu_autoobject_runtime_writeback_report(target: Dictionary, source: Dictionary) -> void:
	if target.is_empty() or source.is_empty():
		return
	target["ok"] = bool(target.get("ok", true)) and bool(source.get("ok", true))
	if not bool(source.get("ok", true)):
		var failure_reason := str(source.get("reason", "runtime_writeback_failed"))
		target["reason"] = failure_reason
		target["writeback_reason"] = failure_reason
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
	var object_summaries: Array = target.get("object_summaries", [])
	object_summaries.append_array(source.get("object_summaries", []))
	target["object_summaries"] = object_summaries
	target["runtime_summary"] = source.get("runtime_summary", target.get("runtime_summary", {}))
	target["profile_summary"] = source.get("profile_summary", target.get("profile_summary", {}))
	for key in [
		"accepted_placement_writeback_mode",
		"accepted_placement_record_source",
		"accepted_placement_origin_record_source",
		"accepted_placement_spawn_api",
		"cpu_batched_command_queue_bridge",
		"cpu_batch_bridge",
		"accepted_placement_record_stride_bytes",
	]:
		if source.has(key):
			target[key] = source[key]
	_merge_gpu_autoobject_runtime_flush_contract(target, source)
	target["command_queue_stage_count"] = int(target.get("command_queue_stage_count", 0)) + int(source.get("command_queue_stage_count", 0))
	target["command_queue_flush_count"] = int(target.get("command_queue_flush_count", 0)) + int(source.get("command_queue_flush_count", 0))
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


## GPU-first: packs accepted placements into source-candidate records/ranges buffers,
## calls apply_accepted_placement_source_buffer() on the first available committer,
## and exposes the RIDs so the actor can hand them off without CPU readback.

## 遍历所有资产的放置结果，收集"源候选"记录(优先级/复杂度/来源类型等)并按资产分段打包为交错浮点数组，
## 找到第一个支持 apply_accepted_placement_source_buffer 的场景体素委交器(committer)目标，
## 将候选记录/区间上传为 GPU 常驻存储缓冲区并整体交接给该 committer(全程无需 CPU 回读)；
## 若交接不完整则返回被阻塞的报告并释放已分配的缓冲区，交接失败时同样不做 CPU 回退。
func _write_accepted_placements_to_scene_voxel_committer(
	asset_defs: Array,
	result_by_index: Dictionary,
	asset_results: Array[Dictionary],
	common_settings: Dictionary,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3
) -> Dictionary:
	# ---- 1.  gather source-candidate records from every asset ----------------
	var candidate_priorities := PackedFloat32Array()
	var candidate_complexities := PackedFloat32Array()
	var candidate_source_types := PackedFloat32Array()
	var candidate_has_priority_flags := PackedFloat32Array()
	var ranges := PackedInt32Array()
	var target: Object = null
	var generated_tick := int(common_settings.get("generation_tick", -1))
	var has_candidates := false

	for orig_idx in range(asset_defs.size()):
		var asset_def: Dictionary = asset_defs[orig_idx]
		var asset_result: Dictionary = result_by_index.get(orig_idx, {})
		if asset_result.is_empty() or int(asset_result.get("result_count", 0)) <= 0:
			ranges.append(candidate_priorities.size())
			ranges.append(0)
			continue
		var cfg := _runtime_voxel_write_spec_config(asset_def, common_settings, orig_idx, grid_size, voxel_size, grid_origin)
		if target == null:
			target = cfg.get(SCENE_VOXEL_COMMITTER_CONFIG_KEY, cfg.get(PREVIOUS_SCENE_VOXEL_COMMITTER_CONFIG_KEY, null))
		var provided_record := _get_config_voxel_write_spec(cfg)
		var should_create := bool(cfg.get("create_voxel_write_spec", false)) or not provided_record.is_empty()
		if target == null or not should_create:
			ranges.append(candidate_priorities.size())
			ranges.append(0)
			continue
		generated_tick = maxi(generated_tick, int(cfg.get("generation_tick", -1)))
		var world_results: Array = asset_result.get("world_results", [])
		var result_indices := _scene_voxel_source_write_result_indices(asset_result, world_results.size())
		var range_start := candidate_priorities.size()
		var valid_count := 0
		for raw_i in result_indices:
			var i := int(raw_i)
			if i < 0 or i >= world_results.size():
				continue
			var world_result: Dictionary = world_results[i]
			candidate_priorities.append(float(world_result.get("score", 0.0)))
			var complexity := float(asset_def.get("voxel_complexity", asset_def.get("complexity", 0.5)))
			if world_result.has("complexity"):
				complexity = float(world_result.get("complexity", complexity))
			candidate_complexities.append(clampf(complexity, 0.0, 1.0))
			# VPG placements are always AutoSceneVoxel (source_type_code = 1)
			candidate_source_types.append(1.0)
			candidate_has_priority_flags.append(1.0)
			valid_count += 1
			has_candidates = true
		ranges.append(range_start)
		ranges.append(valid_count)

	if not has_candidates:
		return {}

	# ---- 2.  GPU path: pack buffers and handoff to committer -----------------
	var gpu_ok := false
	var gpu_reason := "gpu_path_not_attempted"
	var source_records_rid := RID()
	var source_ranges_rid := RID()

	if target != null and target.has_method("apply_accepted_placement_source_buffer"):
		var _committer_rd := rendering_device_of(target)
		if _rd == null and _committer_rd != null:
			attach_rendering_device(_committer_rd, false)
		if _rd != null:
			var candidate_count := candidate_priorities.size()
			var range_count := int(ranges.size() / 2)
			# interleave 4 fields: [priority, complexity, source_type, has_flag]
			var candidate_floats := PackedFloat32Array()
			candidate_floats.resize(candidate_count * 4)
			for ri in range(candidate_count):
				candidate_floats[ri * 4 + 0] = candidate_priorities[ri]
				candidate_floats[ri * 4 + 1] = candidate_complexities[ri]
				candidate_floats[ri * 4 + 2] = candidate_source_types[ri]
				candidate_floats[ri * 4 + 3] = candidate_has_priority_flags[ri]
			var candidate_bytes := pack_float_array(candidate_floats)
			var range_bytes := pack_u32_array(ranges)

			source_records_rid = storage_buffer_from_bytes(
				candidate_bytes,
				SCOPE_PERSISTENT,
				"vpg_accepted_source_candidate_records"
			)
			source_ranges_rid = storage_buffer_from_bytes(
				range_bytes,
				SCOPE_PERSISTENT,
				"vpg_accepted_source_candidate_ranges"
			)

			if source_records_rid.is_valid() and source_ranges_rid.is_valid():
				var handoff_result: Dictionary = target.call(
					"apply_accepted_placement_source_buffer",
					source_records_rid,
					source_ranges_rid,
					candidate_count,
					range_count,
					generated_tick
				)
				gpu_ok = bool(handoff_result.get("ok", false))
				gpu_reason = str(handoff_result.get("reason", "gpu_handoff_returned_false"))

	# ---- 3.  GPU path succeeded — emit RID-rich report -----------------------
	if gpu_ok:
		var report := {
			"ok": true,
			"reason": "gpu_resident_source_buffer_handoff_ok",
			"gpu_first": true,
			"cpu_fallback": false,
			"accepted_placement_writeback_mode": "gpu_resident_source_write_buffer",
			"accepted_placement_record_source": "gpu_resident_source_candidate_buffer",
			"source_write_handoff_mode": "gpu_resident_source_write_buffer",
			"source_write_batch_api": "apply_accepted_placement_source_buffer",
			"cpu_pending_source_candidate_bridge": false,
			"pending_source_candidate_flush_api": "none",
			"source_candidate_resolve_api": "resolve_scene_voxel_sources.glsl",
			"resident_source_write_buffer": true,
			"resident_source_write_buffer_owner": "vpg_accepted_placement_buffer",
			"resident_source_write_buffer_rid": str(source_records_rid),
			"resident_source_write_buffer_lifetime": "vpg_pass_owned_handoff",
			"resident_source_write_buffer_stride_bytes": 16,
			"resident_source_write_buffer_range_count": int(ranges.size() / 2),
			"resident_source_candidate_buffer_rid": str(source_records_rid),
			"resident_source_candidate_buffer_stride_bytes": 16,
			"resident_source_candidate_buffer_capacity": candidate_priorities.size(),
			"resident_source_candidate_buffer_count": candidate_priorities.size(),
			"resident_source_range_buffer_rid": str(source_ranges_rid),
			"resident_source_range_buffer_stride_bytes": 8,
			"resident_source_range_buffer_capacity": int(ranges.size() / 2),
			"resident_source_range_buffer_count": int(ranges.size() / 2),
			"resident_source_candidate_staging_epoch": 0,
			"runtime_read_source": "resident_gpu_source_candidate_buffer",
			"final_source_stream_resident": false,
			"final_source_stream_resident_source": "none",
			"resident_gpu_allocator_writeback": false,
			"resident_gpu_allocator_writeback_mode": "none",
			"source_record_count": candidate_priorities.size(),
			"applied_count": candidate_priorities.size(),
			"failed_count": 0,
			"asset_reports": [],
			# P0 #3: RIDs for SPA to consume without CPU readback
			"accepted_placement_source_records_rid": source_records_rid,
			"accepted_placement_source_ranges_rid": source_ranges_rid,
			"accepted_placement_source_record_count": candidate_priorities.size(),
			"accepted_placement_source_range_count": int(ranges.size() / 2),
		}
		return report

	# ---- 4.  GPU path failed — release buffers and fall through to CPU --------
	if source_records_rid.is_valid():
		release_rid(source_records_rid, false)
		source_records_rid = RID()
	if source_ranges_rid.is_valid():
		release_rid(source_ranges_rid, false)
		source_ranges_rid = RID()

	if gpu_reason == ACCEPTED_PLACEMENT_SOURCE_BUFFER_INCOMPLETE_REASON:
		return {
			"ok": false,
			"reason": gpu_reason,
			"gpu_first": true,
			"cpu_fallback": false,
			"accepted_placement_writeback_mode": "blocked_gpu_resident_source_write_buffer",
			"accepted_placement_record_source": "incomplete_gpu_resident_source_candidate_buffer",
			"source_write_handoff_mode": "blocked_incomplete_gpu_resident_source_write_buffer",
			"source_write_batch_api": "apply_accepted_placement_source_buffer",
			"cpu_pending_source_candidate_bridge": false,
			"pending_source_candidate_flush_api": "none",
			"source_candidate_resolve_api": "resolve_scene_voxel_sources.glsl",
			"resident_source_write_buffer": false,
			"resident_source_write_buffer_owner": "none",
			"resident_source_write_buffer_rid": "none",
			"resident_source_write_buffer_lifetime": "none",
			"resident_source_write_buffer_stride_bytes": 0,
			"resident_source_write_buffer_range_count": 0,
			"resident_source_candidate_buffer_rid": "none",
			"resident_source_candidate_buffer_stride_bytes": 0,
			"resident_source_candidate_buffer_capacity": 0,
			"resident_source_candidate_buffer_count": 0,
			"resident_source_range_buffer_rid": "none",
			"resident_source_range_buffer_stride_bytes": 0,
			"resident_source_range_buffer_capacity": 0,
			"resident_source_range_buffer_count": 0,
			"resident_source_candidate_payload_buffer": false,
			"resident_source_candidate_payload_buffer_rid": "none",
			"resident_source_candidate_payload_buffer_stride_bytes": 0,
			"resident_source_candidate_payload_buffer_capacity": 0,
			"resident_source_candidate_payload_buffer_count": 0,
			"resident_source_candidate_group_index_buffer": false,
			"resident_source_candidate_group_index_buffer_rid": "none",
			"resident_source_candidate_group_index_buffer_stride_bytes": 0,
			"resident_source_candidate_group_index_buffer_capacity": 0,
			"resident_source_candidate_group_index_buffer_count": 0,
			"resident_source_candidate_staging_epoch": 0,
			"runtime_read_source": "none",
			"final_source_stream_resident": false,
			"final_source_stream_resident_source": "none",
			"resident_gpu_allocator_writeback": false,
			"resident_gpu_allocator_writeback_mode": "none",
			"source_record_count": candidate_priorities.size(),
			"applied_count": 0,
			"failed_count": candidate_priorities.size(),
			"asset_reports": [],
			"accepted_placement_source_record_count": candidate_priorities.size(),
			"accepted_placement_source_range_count": int(ranges.size() / 2),
			"source_candidate_required_buffers": [
				"candidate_records",
				"candidate_ranges",
				"candidate_payloads",
				"group_source_key_indices",
			],
			"source_candidate_missing_buffers": [
				"candidate_payloads",
				"group_source_key_indices",
			],
		}

	# ---- 5.  GPU handoff complete — no CPU fallback
	return {
		"ok": false,
		"reason": gpu_reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"source_record_count": 0,
		"applied_count": 0,
		"failed_count": 0,
		"asset_reports": [],
	}







## 确定某资产应写入源候选缓冲区的 world_result 索引：若无 GPU AutoObject 写回报告则写入全部索引，
## 否则仅取该报告中实际生成对象的 spawned_result_indices(缺失时退化为前 spawned_count 个)。
static func _scene_voxel_source_write_result_indices(asset_result: Dictionary, world_result_count: int) -> Array[int]:
	var indices: Array[int] = []
	var writeback: Dictionary = asset_result.get("gpu_autoobject_runtime_writeback", {})
	if writeback.is_empty():
		for i in range(world_result_count):
			indices.append(i)
		return indices
	var spawned_indices: Array = writeback.get("spawned_result_indices", [])
	if not spawned_indices.is_empty():
		for raw_i in spawned_indices:
			var i := int(raw_i)
			if i >= 0 and i < world_result_count:
				indices.append(i)
		return indices
	var spawned_count := clampi(int(writeback.get("spawned_count", 0)), 0, world_result_count)
	for i in range(spawned_count):
		indices.append(i)
	return indices



## 合并 common_settings 与 asset_def(含其 settings 覆盖项)为单个资产级配置字典，
## 并填充网格/体素尺寸、资产索引及默认的分辨率/捕获尺寸/id 前缀。
static func _runtime_voxel_write_spec_config(
	asset_def: Dictionary,
	common_settings: Dictionary,
	asset_index: int,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3
) -> Dictionary:
	var cfg := common_settings.duplicate(true)
	for key in asset_def.keys():
		if key == "settings":
			continue
		cfg[key] = asset_def[key]
	var overrides: Dictionary = asset_def.get("settings", {})
	for key in overrides:
		cfg[key] = overrides[key]
	cfg["asset_index"] = asset_index
	cfg["grid_size"] = grid_size
	cfg["voxel_size"] = voxel_size
	cfg["grid_origin"] = grid_origin
	if not cfg.has("volume_xz_resolution"):
		cfg["volume_xz_resolution"] = grid_size.x
	if not cfg.has("capture_size"):
		cfg["capture_size"] = maxf(float(grid_size.x) * maxf(voxel_size.x, 0.0001), 0.0001)
	if not cfg.has("id_prefix"):
		cfg["id_prefix"] = "voxel_placement_asset_%d" % asset_index
	return cfg



## 为单条放置结果构造(或复用已提供的)voxel write spec 记录：调用 make_voxel_write_spec 生成基础记录后，
## 补充 id/资产索引/来源类型/位置缩放旋转/分数/基准像素/碰撞层等字段。
static func _runtime_placement_voxel_write_spec(
	world_result: Dictionary,
	asset_def: Dictionary,
	cfg: Dictionary,
	asset_index: int,
	result_index: int,
	provided_record: Dictionary = {}
) -> Dictionary:
	var record_cfg := cfg.duplicate(true)
	record_cfg["asset_index"] = asset_index
	if not record_cfg.has("id"):
		record_cfg["id"] = "%s_%d" % [str(record_cfg.get("id_prefix", "voxel_placement")), result_index]
	var resolution := maxi(int(record_cfg.get("volume_xz_resolution", record_cfg.get("texture_resolution", 0))), 1)
	var capture_size := float(record_cfg.get("capture_size", record_cfg.get("world_capture_size", float(resolution))))
	if capture_size <= 0.0:
		capture_size = float(resolution)
	var record := provided_record.duplicate(true) if not provided_record.is_empty() else VoxelPlacementOutputScript.make_voxel_write_spec(world_result, null, record_cfg)
	if record.is_empty():
		return {}
	record["id"] = str(record_cfg.get("id", record.get("id", "voxel_placement_%d" % result_index)))
	record["asset_index"] = asset_index
	record["source_voxel_type"] = str(record.get("source_voxel_type", "AutoSceneVoxel"))
	record["auto_source"] = str(record.get("auto_source", "voxel_placement"))
	record["position"] = world_result.get("position", record.get("position", Vector3.ZERO))
	record["scale"] = world_result.get("scale", record.get("scale", Vector3.ONE))
	record["voxel_origin"] = world_result.get("voxel_origin", record.get("voxel_origin", Vector3i.ZERO))
	record["rotation_index"] = int(world_result.get("rotation_index", record.get("rotation_index", 0)))
	record["rotation_degrees"] = world_result.get("rotation_degrees", record.get("rotation_degrees", Vector3.ZERO))
	record["score"] = float(world_result.get("score", record.get("score", 0.0)))
	var base_px := VoxelPlacementOutputScript._placement_base_pixel(world_result, record_cfg, capture_size, resolution)
	record["base_pixel"] = base_px
	record["voxel_xz"] = base_px
	record["volume_xz_resolution"] = resolution
	if not record.has("collision") and asset_def.has("collision"):
		record["collision"] = asset_def.get("collision", [])
	return record



## 将一批已接受的放置结果写回 GPU AutoObject 运行时：探测可用的 spawn API(若命令队列已有待处理
## 命令则放弃批处理队列)，计算每条结果的体素包围盒/脏标记/变换后，优先走批处理命令队列(可选对象
## ID 预留/终结/回滚)或 GPU 批量生成方法，都不可用时退回逐条调用 spawn_from_bounds/spawn；
## 最终核对 live_count 与 spawned_count 是否一致，并据此更新写回报告的成功状态与 readback_source。
func _write_accepted_placements_to_gpu_runtime(
	runtime_provider: Object,
	asset_index: int,
	asset_def: Dictionary,
	per_asset_settings: Dictionary,
	world_results: Array,
	raw_results: Array,
	stamp_deltas: Array,
	stamp_bounds: Array,
	common_settings: Dictionary
) -> Dictionary:
	var spawn_api := _runtime_writeback_spawn_api(runtime_provider)
	var command_queue_bridge := spawn_api == "stage_command_flush_command_queue"
	var pending_command_count_before := 0
	if command_queue_bridge and runtime_provider != null and runtime_provider.has_method("get_pending_command_count"):
		pending_command_count_before = int(runtime_provider.call("get_pending_command_count"))
		if pending_command_count_before > 0:
			if runtime_provider.has_method("spawn_from_bounds"):
				spawn_api = "spawn_from_bounds"
			elif runtime_provider.has_method("spawn"):
				spawn_api = "spawn"
			command_queue_bridge = false
	var report := {
		"ok": true,
		"reason": "gpu_runtime_writeback_ready",
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "gpu_storage_buffers",
		"runtime_read_source": "gpu_storage_buffers",
		"accepted_placement_writeback_mode": _runtime_writeback_mode_from_api(spawn_api, true),
		"accepted_placement_record_source": "cpu_spawn_command_dictionaries" if command_queue_bridge else "cpu_world_result_and_raw_result_dictionaries",
		"accepted_placement_origin_record_source": "cpu_world_result_and_raw_result_dictionaries",
		"accepted_placement_spawn_api": spawn_api,
		"cpu_batched_command_queue_bridge": command_queue_bridge,
		"cpu_batch_bridge": command_queue_bridge,
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
		"resident_gpu_allocator_writeback_blocked_reason": "no_resident_allocator_shader_dispatch" if command_queue_bridge else "none",
		"accepted_count": min(world_results.size(), raw_results.size()),
		"spawned_count": 0,
		"failed_count": 0,
		"object_ids": [],
		"object_summaries": [],
		"spawned_result_indices": [],
		"pending_command_count_before": pending_command_count_before,
		"command_queue_bridge_blocked": pending_command_count_before > 0 and spawn_api != "stage_command_flush_command_queue",
		"command_queue_bridge_blocked_reason": "pending_runtime_commands" if pending_command_count_before > 0 and spawn_api != "stage_command_flush_command_queue" else "",
		"command_queue_stage_count": 0,
		"command_queue_flush_count": 0,
		"runtime_command_queue_stage_results": [],
		"asset_index": asset_index,
		"profile_id": int(per_asset_settings.get("profile_id", -1)),
		"object_type": _runtime_writeback_object_type(asset_def, per_asset_settings, common_settings),
	}
	if runtime_provider == null or spawn_api == "none":
		report["ok"] = false
		report["reason"] = "missing_gpu_autoobject_runtime_writeback_target"
		report["readback_source"] = "none"
		report["runtime_read_source"] = "none"
		return report
	if not _generator._object_bool(runtime_provider, "is_gpu_ready", "is_ready"):
		report["ok"] = false
		report["reason"] = "gpu_autoobject_runtime_not_ready"
		report["readback_source"] = "none"
		report["runtime_read_source"] = "none"
		return report

	var bounds_by_result := _runtime_writeback_bounds_by_result(stamp_deltas, stamp_bounds)
	var dirty_flags := _runtime_writeback_dirty_flags(asset_def, per_asset_settings, common_settings)
	var spawn_records: Array[Dictionary] = []
	for i in range(mini(world_results.size(), raw_results.size())):
		var world_result: Dictionary = world_results[i]
		var raw_result: Dictionary = raw_results[i]
		var bounds := _runtime_writeback_bounds_for_result(i, raw_result, world_result, bounds_by_result)
		var transform := _runtime_writeback_transform(world_result)
		var spawn_params := {
			"profile_id": report["profile_id"],
			"object_type": report["object_type"],
			"voxel_min": bounds.get("voxel_min", Vector3i.ZERO),
			"voxel_max": bounds.get("voxel_max", Vector3i.ONE),
			"transform": transform,
			"dirty_flags": dirty_flags,
		}
		spawn_params["asset_index"] = asset_index
		spawn_params["result_index"] = i
		spawn_records.append(spawn_params)

	if command_queue_bridge:
		var staged_records: Array[Dictionary] = []
		var stage_reports: Array = []
		var reserved_object_ids: Array = []
		var staged_reserved_object_ids: Array = []
		var finalized_reserved_object_ids: Array = []
		var use_object_id_reservation := runtime_provider.has_method("reserve_accepted_placement_object_ids") \
			and runtime_provider.has_method("rollback_accepted_placement_object_ids") \
			and runtime_provider.has_method("finalize_accepted_placement_object_id_reservation")
		if use_object_id_reservation:
			var raw_reservation = runtime_provider.call("reserve_accepted_placement_object_ids", spawn_records.size())
			if raw_reservation is Dictionary:
				var reservation := (raw_reservation as Dictionary).duplicate(true)
				report["accepted_placement_object_id_reservation"] = reservation
				if bool(reservation.get("ok", false)):
					reserved_object_ids = reservation.get("object_ids", [])
					if reserved_object_ids.size() != spawn_records.size():
						report["ok"] = false
						report["reason"] = "runtime_spawn_failed"
						report["writeback_detail_reason"] = "object_id_reservation_count_mismatch"
						report["failed_count"] = int(report.get("failed_count", 0)) + spawn_records.size()
				else:
					report["ok"] = false
					report["reason"] = "runtime_spawn_failed"
					report["writeback_detail_reason"] = str(reservation.get("reason", "object_id_reservation_failed"))
					report["failed_count"] = int(report.get("failed_count", 0)) + spawn_records.size()
			else:
				report["ok"] = false
				report["reason"] = "runtime_spawn_failed"
				report["writeback_detail_reason"] = "object_id_reservation_result_invalid"
				report["failed_count"] = int(report.get("failed_count", 0)) + spawn_records.size()

		for i in range(spawn_records.size()):
			if use_object_id_reservation and not bool(report.get("ok", false)):
				break
			var command := spawn_records[i].duplicate(true)
			command["command"] = "spawn"
			if use_object_id_reservation:
				command["object_id"] = int(reserved_object_ids[i])
				command["accepted_placement_object_id_reserved"] = true
			var raw_stage_result = runtime_provider.call("stage_command", command)
			if raw_stage_result is Dictionary:
				var stage_result := (raw_stage_result as Dictionary).duplicate(true)
				stage_reports.append(stage_result)
				if bool(stage_result.get("ok", false)):
					staged_records.append(command)
					if use_object_id_reservation:
						staged_reserved_object_ids.append(int(command.get("object_id", -1)))
				else:
					report["ok"] = false
					report["failed_count"] = int(report.get("failed_count", 0)) + 1
					report["reason"] = "runtime_spawn_failed"
					if not report.has("writeback_detail_reason"):
						report["writeback_detail_reason"] = str(stage_result.get("reason", "stage_command_failed"))
			else:
				report["ok"] = false
				report["failed_count"] = int(report.get("failed_count", 0)) + 1
				report["reason"] = "runtime_spawn_failed"
				if not report.has("writeback_detail_reason"):
					report["writeback_detail_reason"] = "stage_command_result_invalid"
		report["runtime_command_queue_stage_results"] = stage_reports
		report["command_queue_stage_count"] = staged_records.size()

		# P0 #5: Always enable GPU-resident accepted placement shader for
		# batched writeback. This eliminates the CPU bulk-spawn code path
		# and lets the shader write alive/type/profile/bounds/transform/dirty
		# atomically in a single dispatch.
		if not staged_records.is_empty():
			var raw_flush_result = runtime_provider.call(
				"flush_command_queue",
				{"use_accepted_placement_record_shader": true}
			)
			if raw_flush_result is Dictionary:
				var flush_result := (raw_flush_result as Dictionary).duplicate(true)
				report["runtime_command_queue_flush_report"] = flush_result
				report["command_queue_flush_count"] = 1
				_copy_gpu_autoobject_runtime_flush_contract(report, flush_result)
				if not bool(flush_result.get("ok", false)):
					report["ok"] = false
					report["reason"] = "runtime_spawn_failed"
					if not report.has("writeback_detail_reason"):
						report["writeback_detail_reason"] = str(flush_result.get("reason", "flush_command_queue_failed"))
				elif use_object_id_reservation and bool(flush_result.get("accepted_placement_record_shader_consumed", false)):
					var raw_finalize = runtime_provider.call(
						"finalize_accepted_placement_object_id_reservation",
						staged_reserved_object_ids,
						flush_result
					)
					if raw_finalize is Dictionary:
						var finalize_result := (raw_finalize as Dictionary).duplicate(true)
						report["accepted_placement_object_id_reservation_finalize"] = finalize_result
						if bool(finalize_result.get("ok", false)):
							finalized_reserved_object_ids = finalize_result.get("finalized_object_ids", [])
						else:
							report["ok"] = false
							report["reason"] = "runtime_spawn_failed"
							if not report.has("writeback_detail_reason"):
								report["writeback_detail_reason"] = str(finalize_result.get("reason", "object_id_reservation_finalize_failed"))
					else:
						report["ok"] = false
						report["reason"] = "runtime_spawn_failed"
						if not report.has("writeback_detail_reason"):
							report["writeback_detail_reason"] = "object_id_reservation_finalize_result_invalid"
				elif use_object_id_reservation:
					report["ok"] = false
					report["reason"] = "runtime_spawn_failed"
					if not report.has("writeback_detail_reason"):
						report["writeback_detail_reason"] = "accepted_record_shader_not_consumed"
				var queue_results: Array = flush_result.get("results", [])
				for i in range(staged_records.size()):
					var spawn_params: Dictionary = staged_records[i]
					var queue_result: Dictionary = {}
					if i < queue_results.size() and queue_results[i] is Dictionary:
						queue_result = queue_results[i]
					if queue_result.is_empty():
						report["ok"] = false
						report["failed_count"] = int(report.get("failed_count", 0)) + 1
						report["reason"] = "runtime_spawn_failed"
						if not report.has("writeback_detail_reason"):
							report["writeback_detail_reason"] = "flush_result_missing"
						continue
					var object_id := int(queue_result.get("object_id", -1))
					if not bool(queue_result.get("ok", false)) or object_id < 0:
						report["ok"] = false
						report["failed_count"] = int(report.get("failed_count", 0)) + 1
						report["reason"] = "runtime_spawn_failed"
						if not report.has("writeback_detail_reason"):
							report["writeback_detail_reason"] = str(queue_result.get("reason", "queued_spawn_failed"))
						continue
					report["spawned_count"] = int(report.get("spawned_count", 0)) + 1
					report["object_ids"].append(object_id)
					report["spawned_result_indices"].append(int(spawn_params.get("result_index", i)))
					if runtime_provider.has_method("get_object_summary"):
						var object_summary = runtime_provider.call("get_object_summary", object_id)
						if object_summary is Dictionary:
							report["object_summaries"].append((object_summary as Dictionary).duplicate(true))
			else:
				report["ok"] = false
				report["reason"] = "runtime_spawn_failed"
				report["writeback_detail_reason"] = "flush_command_queue_result_invalid"
				report["failed_count"] = int(report.get("failed_count", 0)) + staged_records.size()
		if use_object_id_reservation:
			var rollback_ids: Array = []
			for raw_id in reserved_object_ids:
				var object_id := int(raw_id)
				if finalized_reserved_object_ids.find(object_id) < 0:
					rollback_ids.append(object_id)
			if not rollback_ids.is_empty():
				var raw_rollback = runtime_provider.call("rollback_accepted_placement_object_ids", rollback_ids)
				if raw_rollback is Dictionary:
					report["accepted_placement_object_id_reservation_rollback"] = (raw_rollback as Dictionary).duplicate(true)
	# P0 #5: GPU batched allocator replaces the old CPU for-loop that
	# called spawn()/spawn_from_bounds() for each record individually.
	# spawn_batch_from_accepted_placement_records allocates all IDs,
	# packs the AcceptedPlacementRecord buffer, and dispatches
	# autoobject_apply_accepted_placements.glsl in a single GPU pass.
	else:
		if runtime_provider.has_method("spawn_batch_from_accepted_placement_records"):
			var batch_options := {"use_accepted_placement_record_shader": true}
			var batch_result = runtime_provider.call("spawn_batch_from_accepted_placement_records", spawn_records, batch_options)
			if batch_result is Dictionary:
				_copy_gpu_autoobject_runtime_flush_contract(report, batch_result)
				var batch_object_ids: Array = batch_result.get("object_ids", [])
				if bool(batch_result.get("ok", false)):
					report["spawned_count"] = int(batch_result.get("spawned_count", 0))
					report["object_ids"] = batch_object_ids.duplicate(true)
					for i in range(batch_object_ids.size()):
						report["spawned_result_indices"].append(int(spawn_records[i].get("result_index", i)))
						if runtime_provider.has_method("get_object_summary"):
							var s = runtime_provider.call("get_object_summary", int(batch_object_ids[i]))
							if s is Dictionary:
								report["object_summaries"].append((s as Dictionary).duplicate(true))
				else:
					report["ok"] = false
					report["failed_count"] = int(report.get("failed_count", 0)) + spawn_records.size()
					report["reason"] = "runtime_spawn_failed"
					if not report.has("writeback_detail_reason"):
						report["writeback_detail_reason"] = str(batch_result.get("reason", "batch_spawn_failed"))
					report["resident_gpu_allocator_writeback_blocked_reason"] = str(batch_result.get("resident_gpu_allocator_writeback_blocked_reason", "none"))
			else:
				report["ok"] = false
				report["reason"] = "runtime_spawn_failed"
				report["writeback_detail_reason"] = "batch_spawn_result_invalid"
				report["failed_count"] = int(report.get("failed_count", 0)) + spawn_records.size()
		else:
			# Backward-compatible fallback for runtimes without batch method.
			for i in range(spawn_records.size()):
				var spawn_params: Dictionary = spawn_records[i]
				var transform: Transform3D = spawn_params.get("transform", Transform3D.IDENTITY)
				var object_id := -1
				if runtime_provider.has_method("spawn_from_bounds"):
					object_id = int(runtime_provider.call("spawn_from_bounds", spawn_params))
				elif runtime_provider.has_method("spawn"):
					object_id = int(runtime_provider.call(
						"spawn",
						report["profile_id"],
						report["object_type"],
						spawn_params["voxel_min"],
						spawn_params["voxel_max"],
						transform,
						dirty_flags
					))
				if object_id < 0:
					report["ok"] = false
					report["failed_count"] = int(report.get("failed_count", 0)) + 1
					if str(report.get("reason", "gpu_runtime_writeback_ready")) == "gpu_runtime_writeback_ready":
						report["reason"] = "runtime_spawn_failed"
					continue
				report["spawned_count"] = int(report.get("spawned_count", 0)) + 1
				report["object_ids"].append(object_id)
				report["spawned_result_indices"].append(int(spawn_params.get("result_index", i)))
				if runtime_provider.has_method("get_object_summary"):
					var object_summary = runtime_provider.call("get_object_summary", object_id)
					if object_summary is Dictionary:
						report["object_summaries"].append((object_summary as Dictionary).duplicate(true))

	var runtime_summary := _generator._object_summary(runtime_provider)
	report["runtime_summary"] = runtime_summary
	var live_count := int(runtime_summary.get("live_count", -1))
	if live_count < 0 and runtime_provider.has_method("get_live_count"):
		live_count = int(runtime_provider.call("get_live_count"))
	if live_count < 0:
		live_count = int(runtime_summary.get("objects", []).size())
	report["live_count"] = live_count
	report["pending_dirty_delta_count"] = int(runtime_provider.call("get_pending_dirty_delta_count")) if runtime_provider.has_method("get_pending_dirty_delta_count") else 0
	if report["spawned_count"] > 0 and int(report["live_count"]) < int(report["spawned_count"]):
		report["ok"] = false
		if str(report.get("reason", "")) == "gpu_runtime_writeback_ready":
			report["reason"] = "runtime_live_count_mismatch"
	if report["spawned_count"] <= 0 and report["accepted_count"] > 0:
		report["ok"] = false
		if str(report.get("reason", "")) == "gpu_runtime_writeback_ready":
			report["reason"] = "runtime_spawned_none"
	if not bool(report.get("ok", false)):
		report["readback_source"] = "none"
		report["runtime_read_source"] = "none"
	return report



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



## 若 source 是字典，则将其每个键值转换为 bool 后合并进 target。
static func _runtime_writeback_merge_flags(target: Dictionary, source) -> void:
	if not (source is Dictionary):
		return
	for key in (source as Dictionary).keys():
		target[key] = bool((source as Dictionary)[key])



## 按 result_index 构建体素包围盒映射：优先使用 stamp_bounds 中的显式记录，
## 若为空则退化为逐个累加 stamp_deltas 的体素坐标得到每个结果的最小/最大包围盒。
static func _runtime_writeback_bounds_by_result(stamp_deltas: Array, stamp_bounds: Array = []) -> Dictionary:
	var bounds_by_result: Dictionary = {}
	for raw_bounds in stamp_bounds:
		if not raw_bounds is Dictionary:
			continue
		var bounds: Dictionary = raw_bounds
		var result_index := int(bounds.get("result_index", -1))
		var written_count := int(bounds.get("written_count", 0))
		if result_index < 0 or written_count <= 0:
			continue
		bounds_by_result[result_index] = {
			"voxel_min": bounds.get("voxel_min", Vector3i.ZERO),
			"voxel_max": bounds.get("voxel_max", Vector3i.ONE),
			"written_count": written_count,
			"source": str(bounds.get("source", "stamp_shader_storage_buffer")),
		}
	if not bounds_by_result.is_empty():
		return bounds_by_result
	for raw_delta in stamp_deltas:
		if not raw_delta is Dictionary:
			continue
		var delta: Dictionary = raw_delta
		var result_index := int(delta.get("result_index", -1))
		if result_index < 0:
			continue
		var voxel: Vector3i = delta.get("voxel", Vector3i.ZERO)
		var entry: Dictionary = bounds_by_result.get(result_index, {})
		if entry.is_empty():
			bounds_by_result[result_index] = {
				"voxel_min": voxel,
				"voxel_max": voxel + Vector3i.ONE,
			}
			continue
		var voxel_min: Vector3i = entry.get("voxel_min", voxel)
		var voxel_max: Vector3i = entry.get("voxel_max", voxel + Vector3i.ONE)
		voxel_min = Vector3i(
			mini(voxel_min.x, voxel.x),
			mini(voxel_min.y, voxel.y),
			mini(voxel_min.z, voxel.z)
		)
		voxel_max = Vector3i(
			maxi(voxel_max.x, voxel.x + 1),
			maxi(voxel_max.y, voxel.y + 1),
			maxi(voxel_max.z, voxel.z + 1)
		)
		entry["voxel_min"] = voxel_min
		entry["voxel_max"] = voxel_max
		bounds_by_result[result_index] = entry
	return bounds_by_result



## 取出指定 result_index 的体素包围盒；缺失或非法时退化为以 voxel_origin 为中心的单体素包围盒。
static func _runtime_writeback_bounds_for_result(result_index: int, raw_result: Dictionary, world_result: Dictionary, bounds_by_result: Dictionary) -> Dictionary:
	var entry: Dictionary = bounds_by_result.get(result_index, {})
	var voxel_min: Vector3i = entry.get("voxel_min", raw_result.get("voxel_origin", world_result.get("voxel_origin", Vector3i.ZERO)))
	var voxel_max: Vector3i = entry.get("voxel_max", voxel_min + Vector3i.ONE)
	if voxel_max.x <= voxel_min.x or voxel_max.y <= voxel_min.y or voxel_max.z <= voxel_min.z:
		voxel_min = raw_result.get("voxel_origin", world_result.get("voxel_origin", Vector3i.ZERO))
		voxel_max = voxel_min + Vector3i.ONE
	return {
		"voxel_min": voxel_min,
		"voxel_max": voxel_max,
	}



## 根据 world_result 的 position 与 rotation_degrees(仅偏航角)构造 Transform3D。
static func _runtime_writeback_transform(world_result: Dictionary) -> Transform3D:
	var position: Vector3 = world_result.get("position", Vector3.ZERO)
	var rotation_degrees: Vector3 = world_result.get("rotation_degrees", Vector3.ZERO)
	var yaw := deg_to_rad(float(rotation_degrees.y))
	return Transform3D(Basis.from_euler(Vector3(0.0, yaw, 0.0)), position)



## 委托调用 _generator._validate_gpu_runtime_profile_contract 校验 GPU 运行时 profile 契约。
func validate_gpu_runtime_profile_contract(settings: Dictionary) -> Dictionary:
	return _generator._validate_gpu_runtime_profile_contract(settings)


