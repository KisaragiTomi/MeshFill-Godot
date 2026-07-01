class_name VoxelPlacementGenerator


extends "res://scripts/godot_compute_shader_base.gd"
## Minimal GPU prototype for 3D voxel-space object placement.
##
## This is intentionally independent from the heightfield fitting path:
## callers provide compact scene/collision field buffers and a simplified
## asset footprint, then receive compact placement records and stamped occupancy.

const AutoObject := preload("res://scripts/auto_object.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const VoxelPlacementWritebackScript := preload("res://scripts/voxel_placement_writeback.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
var _placement_writeback = null

## Lazily creates the delegated placement writeback helper.
## 惰性创建（按需初始化）委托的放置写回（writeback）辅助对象。
func _ensure_placement_writeback():
	if _placement_writeback == null:
		_placement_writeback = VoxelPlacementWritebackScript.new()
		_placement_writeback._generator = self
	if not _placement_writeback._rd and _rd:
		_placement_writeback.attach_rendering_device(_rd, false)
	return _placement_writeback

const VoxelPlacementOutputScript := preload("res://scripts/voxel_placement_output.gd")
const VoxelFootprintBakerScript := preload("res://scripts/voxel_footprint_baker.gd")

const TILE_SIZE := 8
const FOOTPRINT_CAPACITY := 128
const RECORD_STRIDE := 4
const DELTA_STRIDE := 2
const STAMP_BOUNDS_STRIDE := 2
const NUM_DEBUG_CHANNELS := 8
const SCORE_CONTRACT_DEBUG_WORDS := 48
const SCORE_CONTRACT_MAGIC := 0x4D465052 # MFPR: MeshFill placement runtime/profile.
const CANDIDATE_ROUTE_BINDING_DEBUG_WORDS := 16
const CANDIDATE_ROUTE_ADAPTER_COUNT_WORDS := 4
const CANDIDATE_ROUTE_INDIRECT_ARGS_BYTES := 12
const CANDIDATE_ROUTE_SPARSE_ADAPTER_LOCAL_SIZE := 64
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

var top_k: int = 4
var result_capacity: int = 8
var solid_threshold: float = 192.0 / 255.0
var collision_limit: float = 0.0
var min_support_ratio: float = 1.0
var clearance_limit: float = 0.0
var support_weight: float = 10.0
var collision_penalty: float = 100.0
var overlap_penalty: float = 1.0
var clearance_penalty: float = 10.0
var min_distance_voxels: float = 2.0
var scene_write_scale: float = 1.0
var collision_write_scale: float = 1.0
var asset_index: int = 0
var rotation_index: int = 0
var scale_index: int = 0
var asset_color: Color = Color.WHITE

var _shader_score: RID
var _shader_reduce: RID
var _shader_init_stamp_bounds: RID
var _shader_stamp: RID
var _shader_pack_target_field: RID
var _shader_candidate_route_sparse_adapter: RID
var _shader_candidate_route_sparse_adapter_finalize: RID
var _pipeline_score: RID
var _pipeline_reduce: RID
var _pipeline_init_stamp_bounds: RID
var _pipeline_stamp: RID
var _pipeline_pack_target_field: RID
var _pipeline_candidate_route_sparse_adapter: RID
var _pipeline_candidate_route_sparse_adapter_finalize: RID


## 检查 settings 中是否包含“按资产分类”的候选体素区域配置（Dictionary 形式）。
static func _has_candidate_regions_by_asset(settings: Dictionary) -> bool:
	for key in CANDIDATE_REGION_BY_ASSET_CONFIG_KEYS:
		if settings.get(key, null) is Dictionary:
			return true
	return false


## 从 settings 中提取“按资产分类”的候选体素区域字典（不存在则返回空字典）。
static func _candidate_regions_by_asset_from_settings(settings: Dictionary) -> Dictionary:
	for key in CANDIDATE_REGION_BY_ASSET_CONFIG_KEYS:
		var value = settings.get(key, {})
		if value is Dictionary:
			return (value as Dictionary).duplicate(true)
	return {}


## 根据 settings 推断候选路由（candidate route）的 GPU 回读来源标签。
static func _candidate_route_readback_source_from_settings(settings: Dictionary) -> String:
	if _has_candidate_regions_by_asset(settings):
		return "gpu_vote_buffer_readback"
	if bool(_candidate_route_input_contract_from_settings(settings).get("resident_route_input_ready", false)):
		return "resident_route_snapshot"
	return "none"


## 根据 settings 推断候选路由在运行时的读取来源标签。
static func _candidate_route_runtime_read_source_from_settings(settings: Dictionary) -> String:
	if _has_candidate_regions_by_asset(settings):
		return "cpu_debug_bridge"
	if bool(_candidate_route_input_contract_from_settings(settings).get("resident_route_input_ready", false)):
		return "resident"
	return "none"


## 根据 settings 归纳候选路由（candidate route）输入契约（contract）：判断当前应使用
## CPU 候选区域字典、GPU 常驻（resident）路由缓冲，还是两者都不可用（none），并对常驻
## 路由所需的各项条件（RID 有效性、stride、schema 版本、稀疏适配器状态等）逐一核实，
## 最终返回包含就绪状态、拒绝原因及大量调试/统计字段的字典。
static func _candidate_route_input_contract_from_settings(settings: Dictionary) -> Dictionary:
	var has_cpu_route := _has_candidate_regions_by_asset(settings)
	var requested_readback := str(settings.get("candidate_route_readback_source", "none"))
	var requested_runtime := str(settings.get("candidate_route_runtime_read_source", "none"))
	var requested_resident_label := requested_readback != "none" or requested_runtime != "none"
	var raw_contract = settings.get("candidate_route_input_contract", {})
	var resident_contract := (raw_contract as Dictionary).duplicate(true) if raw_contract is Dictionary else {}
	if settings.get("resident_candidate_route_contract", null) is Dictionary:
		resident_contract = (settings.get("resident_candidate_route_contract") as Dictionary).duplicate(true)

	var record_rid: RID = _rid_from_contract(resident_contract, "resident_route_record_rid", "resident_route_record_buffer_rid")
	var range_rid: RID = _rid_from_contract(resident_contract, "resident_route_range_rid", "resident_route_range_buffer_rid")
	var record_stride := int(resident_contract.get("resident_route_record_stride", resident_contract.get("resident_route_record_stride_bytes", 0)))
	var range_stride := int(resident_contract.get("resident_route_range_stride", resident_contract.get("resident_route_range_stride_bytes", 0)))
	var range_count := int(resident_contract.get("resident_route_range_count", 0))
	var record_capacity := int(resident_contract.get("resident_route_record_capacity", resident_contract.get("resident_route_record_count", 0)))
	var schema_version := int(resident_contract.get("schema_version", resident_contract.get("resident_route_schema_version", 0)))
	var vpg_binds_route_buffers := bool(resident_contract.get("vpg_binds_route_buffers", false))
	var cpu_expanded := bool(resident_contract.get("cpu_expanded_route_input", false))
	var direct_all_tiles := bool(resident_contract.get("direct_all_tiles", false))
	var route_sparse_adapter := bool(resident_contract.get("resident_route_sparse_adapter", false))
	var rd_matches_vpg := bool(resident_contract.get("same_rendering_device_as_vpg", false))
	if resident_contract.get("rendering_device_matches_vpg", null) is bool:
		rd_matches_vpg = bool(resident_contract.get("rendering_device_matches_vpg"))
	var debug_api := str(resident_contract.get("debug_snapshot_api", "none"))
	var debug_status := str(resident_contract.get("debug_snapshot_status", "none" if debug_api == "none" else "available"))

	var record_rid_valid := record_rid.is_valid()
	var range_rid_valid := range_rid.is_valid()
	var rejection_reason := "none"
	if has_cpu_route:
		rejection_reason = "cpu_debug_bridge_route_dictionary"
	elif requested_resident_label and resident_contract.is_empty():
		rejection_reason = "metadata_only_route_labels"
	elif requested_resident_label and not record_rid_valid:
		rejection_reason = "missing_or_invalid_route_record_rid"
	elif requested_resident_label and not range_rid_valid:
		rejection_reason = "missing_or_invalid_route_range_rid"
	elif requested_resident_label and not rd_matches_vpg:
		rejection_reason = "rendering_device_mismatch_or_unverified"
	elif requested_resident_label and record_stride != CANDIDATE_ROUTE_RECORD_STRIDE_BYTES:
		rejection_reason = "route_record_stride_mismatch"
	elif requested_resident_label and range_stride != CANDIDATE_ROUTE_RANGE_STRIDE_BYTES:
		rejection_reason = "route_range_stride_mismatch"
	elif requested_resident_label and range_count <= 0:
		rejection_reason = "route_range_count_not_positive"
	elif requested_resident_label and schema_version != CANDIDATE_ROUTE_CONTRACT_SCHEMA_VERSION:
		rejection_reason = "route_schema_version_mismatch"
	elif requested_resident_label and not vpg_binds_route_buffers:
		rejection_reason = "vpg_route_buffer_binding_not_implemented"
	elif requested_resident_label and record_capacity <= 0:
		rejection_reason = "resident_route_record_capacity_missing"
	elif requested_resident_label and (cpu_expanded or direct_all_tiles or not route_sparse_adapter):
		rejection_reason = "route_dispatch_not_resident_sparse"

	var resident_ready := not has_cpu_route \
		and requested_resident_label \
		and record_rid_valid \
		and range_rid_valid \
		and rd_matches_vpg \
		and record_stride == CANDIDATE_ROUTE_RECORD_STRIDE_BYTES \
		and range_stride == CANDIDATE_ROUTE_RANGE_STRIDE_BYTES \
		and range_count > 0 \
		and schema_version == CANDIDATE_ROUTE_CONTRACT_SCHEMA_VERSION \
		and vpg_binds_route_buffers \
		and record_capacity > 0 \
		and not cpu_expanded \
		and not direct_all_tiles \
		and route_sparse_adapter
	var normalized_readback := "gpu_vote_buffer_readback" if has_cpu_route else ("resident_route_snapshot" if resident_ready else "none")
	var normalized_runtime := "cpu_debug_bridge" if has_cpu_route else ("resident" if resident_ready else "none")
	var route_input := "common_cpu_dictionary" if has_cpu_route else ("resident_contract" if requested_resident_label and not resident_contract.is_empty() else "none")
	return {
		"route_input": route_input,
		"resident_route_input_ready": resident_ready,
		"resident_route_owner": str(resident_contract.get("owner", resident_contract.get("resident_route_owner", "none"))),
		"resident_route_buffer_rid": "valid" if record_rid_valid else "none",
		"resident_route_record_rid": "valid" if record_rid_valid else "none",
		"resident_route_range_rid": "valid" if range_rid_valid else "none",
		"resident_route_record_rid_valid": record_rid_valid,
		"resident_route_range_rid_valid": range_rid_valid,
		"resident_route_buffer_lifetime": str(resident_contract.get("resident_route_buffer_lifetime", "none")),
		"resident_route_record_stride": record_stride if record_rid_valid or requested_resident_label else 0,
		"resident_route_record_capacity": record_capacity if record_rid_valid or requested_resident_label else 0,
		"resident_route_range_stride": range_stride if range_rid_valid or requested_resident_label else 0,
		"resident_route_range_count": range_count if range_rid_valid or requested_resident_label else 0,
		"resident_route_schema_version": schema_version if requested_resident_label else 0,
		"same_rendering_device_as_vpg": rd_matches_vpg,
		"vpg_binds_route_buffers": vpg_binds_route_buffers,
		"cpu_expanded_route_input": cpu_expanded,
		"direct_all_tiles": direct_all_tiles,
		"asset_count": int(resident_contract.get("asset_count", 0)),
		"profile_count": int(resident_contract.get("profile_count", 0)),
		"debug_snapshot_api": debug_api,
		"debug_snapshot_status": debug_status,
		"vpg_route_buffer_binding_source": str(resident_contract.get("vpg_route_buffer_binding_source", "none")),
		"vpg_route_buffer_binding_debug_source": str(resident_contract.get("vpg_route_buffer_binding_debug_source", "none")),
		"vpg_route_buffer_binding_block_reason": str(resident_contract.get("vpg_route_buffer_binding_block_reason", "none")),
		"vpg_route_buffer_binding_debug_enabled": bool(resident_contract.get("vpg_route_buffer_binding_debug_enabled", false)),
		"vpg_route_buffer_binding_range_reads": int(resident_contract.get("vpg_route_buffer_binding_range_reads", 0)),
		"vpg_route_buffer_binding_record_reads": int(resident_contract.get("vpg_route_buffer_binding_record_reads", 0)),
		"resident_route_sparse_adapter": route_sparse_adapter,
		"resident_route_sparse_adapter_source": str(resident_contract.get("resident_route_sparse_adapter_source", "none")),
		"resident_route_sparse_adapter_mode": str(resident_contract.get("resident_route_sparse_adapter_mode", "none")),
		"resident_route_sparse_adapter_record_reads": int(resident_contract.get("resident_route_sparse_adapter_record_reads", 0)),
		"resident_route_sparse_adapter_candidate_count": int(resident_contract.get("resident_route_sparse_adapter_candidate_count", 0)),
		"resident_route_sparse_adapter_candidate_count_source": str(resident_contract.get("resident_route_sparse_adapter_candidate_count_source", "none")),
		"resident_route_sparse_adapter_candidate_count_semantics": str(resident_contract.get("resident_route_sparse_adapter_candidate_count_semantics", "none")),
		"resident_route_sparse_adapter_candidate_count_cpu_readback_required": bool(resident_contract.get("resident_route_sparse_adapter_candidate_count_cpu_readback_required", false)),
		"resident_route_sparse_adapter_output_capacity": int(resident_contract.get("resident_route_sparse_adapter_output_capacity", 0)),
		"resident_route_sparse_adapter_count_record_reads": int(resident_contract.get("resident_route_sparse_adapter_count_record_reads", 0)),
		"resident_route_sparse_adapter_count_truncation_or_overflow": int(resident_contract.get("resident_route_sparse_adapter_count_truncation_or_overflow", 0)),
		"resident_route_sparse_adapter_indirect_args_ready": bool(resident_contract.get("resident_route_sparse_adapter_indirect_args_ready", false)),
		"resident_route_sparse_adapter_indirect_args_layout": str(resident_contract.get("resident_route_sparse_adapter_indirect_args_layout", "none")),
		"resident_route_sparse_adapter_indirect_args_words": resident_contract.get("resident_route_sparse_adapter_indirect_args_words", PackedInt32Array()),
		"resident_route_sparse_adapter_indirect_args_source": str(resident_contract.get("resident_route_sparse_adapter_indirect_args_source", "none")),
		"resident_route_sparse_adapter_debug_snapshot_enabled": bool(resident_contract.get("resident_route_sparse_adapter_debug_snapshot_enabled", false)),
		"resident_route_sparse_adapter_debug_snapshot_status": str(resident_contract.get("resident_route_sparse_adapter_debug_snapshot_status", "disabled")),
		"resident_route_sparse_adapter_debug_count_snapshot": int(resident_contract.get("resident_route_sparse_adapter_debug_count_snapshot", -1)),
		"resident_route_sparse_adapter_debug_count_snapshot_source": str(resident_contract.get("resident_route_sparse_adapter_debug_count_snapshot_source", "disabled")),
		"resident_route_sparse_adapter_debug_sparse_ids_snapshot": resident_contract.get("resident_route_sparse_adapter_debug_sparse_ids_snapshot", PackedInt32Array()),
		"resident_route_sparse_adapter_debug_sparse_ids_snapshot_source": str(resident_contract.get("resident_route_sparse_adapter_debug_sparse_ids_snapshot_source", "disabled")),
		"resident_route_sparse_adapter_debug_indirect_args_snapshot_source": str(resident_contract.get("resident_route_sparse_adapter_debug_indirect_args_snapshot_source", "disabled")),
		"resident_route_sparse_adapter_score_dispatch_indirect": bool(resident_contract.get("resident_route_sparse_adapter_score_dispatch_indirect", false)),
		"resident_route_sparse_adapter_score_dispatch_indirect_block_reason": str(resident_contract.get("resident_route_sparse_adapter_score_dispatch_indirect_block_reason", "none")),
		"resident_route_sparse_adapter_score_dispatch_indirect_api_supported": bool(resident_contract.get("resident_route_sparse_adapter_score_dispatch_indirect_api_supported", false)),
		"rejection_reason": "none" if resident_ready else rejection_reason,
		"requested_readback_source": requested_readback,
		"requested_runtime_read_source": requested_runtime,
		"requested_source_labels_normalized": requested_resident_label,
		"normalized_readback_source": normalized_readback,
		"normalized_runtime_read_source": normalized_runtime,
	}


## 从契约（contract）字典中按 key_a、key_b 依次尝试取出 RID，取不到或类型不符时返回空 RID。
static func _rid_from_contract(contract: Dictionary, key_a: String, key_b: String) -> RID:
	var raw = contract.get(key_a, contract.get(key_b, RID()))
	if raw is RID:
		return raw as RID
	return RID()


## 若传入值本身就是 RID 类型则原样返回，否则返回空 RID。
static func _rid_from_value(value) -> RID:
	if value is RID:
		return value as RID
	return RID()


## Legacy debug-only: full-field CPU readback contract.
## Only used when `read_full_field_outputs` is explicitly set to `true`.
## 旧版调试专用：完整体素场（full-field）CPU 回读契约，仅当显式设置
## `read_full_field_outputs` 为 true 时才会使用。
static func _full_field_readback_contract(voxel_count: int, output_source: String, is_gpu_readback: bool) -> Dictionary:
	var complexity_byte_count := SceneVoxelTileCodecScript.rgba8_byte_count(voxel_count)
	var collision_byte_count := SceneVoxelTileCodecScript.r8_word_byte_count(voxel_count)
	return {
		"complexity_field_out_source": output_source,
		"collision_field_out_source": output_source,
		"complexity_field_out_is_full_field": true,
		"collision_field_out_is_full_field": true,
		"complexity_field_out_byte_count": complexity_byte_count,
		"collision_field_out_byte_count": collision_byte_count,
		"complexity_field_out_format": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_FORMAT_RGBA8,
		"collision_field_out_format": SceneVoxelTileCodecScript.COLLISION_FIELD_FORMAT_R8,
		"complexity_field_out_stride_bytes": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_STRIDE_BYTES,
		"collision_field_out_stride_bytes": SceneVoxelTileCodecScript.COLLISION_FIELD_STRIDE_BYTES,
		"collision_field_out_upload_stride_bytes": 4,
		"complexity_field_out_gpu_storage_buffer_readback": is_gpu_readback,
		"collision_field_out_gpu_storage_buffer_readback": is_gpu_readback,
		"cpu_state_chaining": true,
		"cpu_state_chain_mode": "full_field_readback",
		"cpu_state_chain_source": output_source,
		"stamp_delta_cpu_state_chaining": false,
		"full_field_readback_required": true,
	}


## Legacy/debug: compact stamp-delta state chain contract.
## Kept for backward compatibility with tests and debug paths.
## 旧版/调试用：紧凑戳记增量（compact stamp-delta）状态链契约，
## 仅为测试与调试路径保留，以维持向后兼容。
static func _compact_delta_state_chain_contract(
	voxel_count: int,
	stamp_delta_count: int,
	decoded_delta_count: int
) -> Dictionary:
	return {
		"complexity_field_out_source": "cpu_state_chain_compact_stamp_deltas",
		"collision_field_out_source": "cpu_state_chain_compact_stamp_deltas",
		"complexity_field_out_is_full_field": false,
		"collision_field_out_is_full_field": false,
		"complexity_field_out_byte_count": 0,
		"collision_field_out_byte_count": 0,
		"complexity_field_out_format": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_FORMAT_RGBA8,
		"collision_field_out_format": SceneVoxelTileCodecScript.COLLISION_FIELD_FORMAT_R8,
		"complexity_field_out_stride_bytes": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_STRIDE_BYTES,
		"collision_field_out_stride_bytes": SceneVoxelTileCodecScript.COLLISION_FIELD_STRIDE_BYTES,
		"collision_field_out_upload_stride_bytes": 4,
		"complexity_field_out_gpu_storage_buffer_readback": false,
		"collision_field_out_gpu_storage_buffer_readback": false,
		"cpu_state_chaining": true,
		"cpu_state_chain_mode": "compact_stamp_deltas",
		"cpu_state_chain_source": "stamp_shader_storage_buffer",
		"stamp_delta_cpu_state_chaining": true,
		"stamp_delta_gpu_storage_buffer_readback": true,
		"stamp_delta_count": stamp_delta_count,
		"stamp_delta_decoded_count": decoded_delta_count,
		"voxel_count": maxi(voxel_count, 0),
		"full_field_readback_required": false,
	}


## GPU-resident state chain: scene/collision buffers live on GPU as borrowed RIDs.
## No full-field readback, no CPU array pass-through. This is the production default.
## GPU 常驻状态链：场景/碰撞缓冲以借用的 RID 形式常驻显存，无需完整场回读，
## 也无需 CPU 数组传递，是生产环境的默认路径。
static func _gpu_resident_state_chain_contract(
	voxel_count: int,
	gpu_resident: bool,
	scene_rid: RID,
	collision_rid: RID,
	source_label: String = "caller_provided_rid",
	owner: String = "external",
	borrowed_external: bool = true,
	blocked_reason: String = "none"
) -> Dictionary:
	return {
		"complexity_field_out_source": "gpu_resident_buffer" if gpu_resident else "gpu_resident_unavailable",
		"collision_field_out_source": "gpu_resident_buffer" if gpu_resident else "gpu_resident_unavailable",
		"complexity_field_out_is_full_field": false,
		"collision_field_out_is_full_field": false,
		"complexity_field_out_byte_count": 0,
		"collision_field_out_byte_count": 0,
		"complexity_field_out_format": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_FORMAT_RGBA8,
		"collision_field_out_format": SceneVoxelTileCodecScript.COLLISION_FIELD_FORMAT_R8,
		"complexity_field_out_stride_bytes": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_STRIDE_BYTES,
		"collision_field_out_stride_bytes": SceneVoxelTileCodecScript.COLLISION_FIELD_STRIDE_BYTES,
		"collision_field_out_upload_stride_bytes": 4,
		"complexity_field_out_gpu_storage_buffer_readback": false,
		"collision_field_out_gpu_storage_buffer_readback": false,
		"gpu_state_chaining": gpu_resident,
		"gpu_state_chain_mode": "resident_buffer_borrow",
		"gpu_state_chain_source": source_label if gpu_resident else "none",
		"gpu_state_chain_owner": owner if gpu_resident else "none",
		"gpu_state_chain_borrowed_external": gpu_resident and borrowed_external,
		"gpu_state_chain_blocked_reason": "none" if gpu_resident else blocked_reason,
		"cpu_state_chaining": false,
		"cpu_state_chain_mode": "none",
		"stamp_delta_cpu_state_chaining": false,
		"stamp_delta_gpu_storage_buffer_readback": false,
		"stamp_delta_count": 0,
		"stamp_delta_decoded_count": 0,
		"voxel_count": maxi(voxel_count, 0),
		"full_field_readback_required": false,
		"complexity_field_buffer_rid": scene_rid if gpu_resident else RID(),
		"collision_field_buffer_rid": collision_rid if gpu_resident else RID(),
	}


## Legacy: compact stamp-delta state chaining check.
## GPU-resident state chain is now the primary path. This function is kept
## for backward compatibility with tests and debug paths.
## 旧版：判断是否请求了紧凑戳记增量状态链。GPU 常驻状态链现为主路径，
## 此函数仅为测试与调试路径保留兼容性。
static func _compact_delta_state_chain_requested(settings: Dictionary) -> bool:
	# Explicit opt-out flags — pass force_full_field_readback=true to fall back to
	# the legacy full-voxel-field readback path (e.g. for debugging / compatibility).
	if bool(settings.get("force_full_field_readback", false)):
		return false
	if bool(settings.get("disable_compact_state_chain", false)):
		return false
	if bool(settings.get("use_full_field_readback", false)):
		return false
	var mode := str(settings.get("cpu_state_chain_mode", settings.get("cpu_state_chaining_mode", "")))
	if mode == "full_field_readback" or mode == "full_field":
		return false
	# Legacy opt-in flags (preserved for backward compatibility but now no-ops).
	if bool(settings.get("use_compact_state_chain", false)):
		return true
	if bool(settings.get("use_vpg_compact_state_chain", false)):
		return true
	if bool(settings.get("use_stamp_delta_state_chain", false)):
		return true
	if mode == "compact_stamp_deltas" or mode == "compact_deltas" or mode == "stamp_deltas":
		return true
	# DEFAULT: compact stamp-delta state chaining is enabled.
	# Reduces PCIe bandwidth by 90%+ (256³=67MB → stamp deltas only).
	return true


## GPU-resident state chain: scene/collision buffers live entirely on GPU.
## This is the production default path. No CPU arrays for state transfer.
## Disable via `force_cpu_state_chain=true` or `disable_gpu_state_chain=true`.
## 判断是否启用 GPU 常驻状态链（生产环境默认路径），可通过
## `force_cpu_state_chain` 或 `disable_gpu_state_chain` 关闭。
static func _gpu_state_chain_enabled(settings: Dictionary) -> bool:
	if bool(settings.get("force_cpu_state_chain", false)):
		return false
	if bool(settings.get("disable_gpu_state_chain", false)):
		return false
	if bool(settings.get("use_cpu_state_chain", false)):
		return false
	if bool(settings.get("force_full_field_readback", false)):
		return false
	return true


## 将戳记增量（stamp deltas）应用到 CPU 端的复杂度/碰撞场数组，
## 并返回已应用、跳过的增量数量等统计信息。
static func _apply_stamp_deltas_to_cpu_state(
	current_complexity: PackedFloat32Array,
	current_collision: PackedFloat32Array,
	stamp_deltas: Array,
	grid_size: Vector3i
) -> Dictionary:
	var expected_voxel_count := VoxelGeneral.voxel_count(grid_size)
	var applied_count := 0
	var complexity_write_count := 0
	var collision_write_count := 0
	var skipped_count := 0
	for raw_delta in stamp_deltas:
		if not raw_delta is Dictionary:
			skipped_count += 1
			continue
		var delta: Dictionary = raw_delta
		var voxel := VoxelGeneral.vector3i_from_value(delta.get("voxel", Vector3i.ZERO), Vector3i.ZERO)
		if voxel.x < 0 or voxel.y < 0 or voxel.z < 0 \
				or voxel.x >= grid_size.x or voxel.y >= grid_size.y or voxel.z >= grid_size.z:
			skipped_count += 1
			continue
		var index := VoxelGeneral.voxel_index(voxel, grid_size)
		if index < 0 or index >= current_complexity.size() or index >= current_collision.size():
			skipped_count += 1
			continue
		var scene_value := clampf(float(delta.get("scene_complexity", 0.0)), 0.0, 1.0)
		var collision_value := clampf(float(delta.get("collision_strength", 0.0)), 0.0, 1.0)
		if scene_value > current_complexity[index]:
			current_complexity[index] = scene_value
			complexity_write_count += 1
		if collision_value > current_collision[index]:
			current_collision[index] = collision_value
			collision_write_count += 1
		applied_count += 1
	return {
		"mode": "compact_stamp_deltas",
		"source": "stamp_shader_storage_buffer",
		"cpu_state_chaining": true,
		"full_field_readback_required": false,
		"stamp_delta_cpu_state_chaining": true,
		"stamp_delta_count": stamp_deltas.size(),
		"applied_delta_count": applied_count,
		"complexity_write_count": complexity_write_count,
		"collision_write_count": collision_write_count,
		"skipped_delta_count": skipped_count,
		"voxel_count": expected_voxel_count,
	}


## 检查单个资产定义（asset_def）中是否包含候选体素区域配置。
static func _has_asset_candidate_regions(asset_def: Dictionary) -> bool:
	for key in ASSET_CANDIDATE_REGION_CONFIG_KEYS:
		if asset_def.has(key):
			return true
	return false


## 从资产定义（asset_def）中提取候选体素区域数组（不存在则返回空数组）。
static func _asset_candidate_regions(asset_def: Dictionary) -> Array:
	for key in ASSET_CANDIDATE_REGION_CONFIG_KEYS:
		var value = asset_def.get(key, [])
		if value is Array:
			return (value as Array).duplicate(true)
	return []


# ---------------------------------------------------------------------------
# Multi-asset sequential pipeline
# ---------------------------------------------------------------------------
# Each asset_def: {collision, result_capacity, min_distance_voxels,
#                  settings, priority, weight}
#   priority (int, default 0): higher = processed first
#   weight (float, default 1.0): weighted random shuffle within same priority
# common_settings may contain:
#   global_quota (int, default -1 = unlimited): max total placements
#   seed (int, default -1 = nondeterministic): RNG seed for weight shuffle
# Returns: {asset_results: [{asset_index, results, world_results, result_count}],
#           complexity_field_out, collision_field_out, total_placed,
#           processing_order: [original indices in execution order],
#           gpu_autoobject_runtime_writeback: optional runtime writeback report}
## 多资产序列化放置流水线的顶层入口：先按 priority/weight 对 asset_defs 排序，再逐个资产
## 调用 run_minimal，对 pivot_variants（锚点变体）逐一尝试放置并保留评分最高者；根据配置
## 在 GPU 常驻、CPU 直接回写、紧凑 stamp-delta 三种状态链模式间传递更新后的
## complexity/collision 场，并追踪全局配额 global_quota；最终可选择将已接受的放置结果写回
## GPU AutoObject 运行时和/或场景体素瓦片提交器（scene voxel tile committer）。
func run_multi_asset(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3 = Vector3.ZERO,
	common_settings: Dictionary = {}
) -> Dictionary:
	var runtime_provider := _first_config_object(common_settings, GPU_RUNTIME_PROVIDER_CONFIG_KEYS)
	var profile_container := _first_config_object(common_settings, GPU_PROFILE_CONTAINER_CONFIG_KEYS)
	var write_accepted_placements_to_gpu_runtime := bool(common_settings.get("write_accepted_placements_to_gpu_runtime", false))
	var gpu_contract_settings := common_settings.duplicate(true)
	if write_accepted_placements_to_gpu_runtime:
		gpu_contract_settings["require_gpu_runtime_profile_contract"] = true
	var gpu_contract := _validate_gpu_runtime_profile_contract(gpu_contract_settings)
	if not bool(gpu_contract.get("ok", true)):
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field,
			collision_field,
			asset_defs,
			gpu_contract,
			common_settings
		)

	var current_complexity := complexity_field.duplicate()
	var current_collision := collision_field.duplicate()
	var total_placed := 0
	var global_quota := int(common_settings.get("global_quota", -1))
	var candidate_route_output_settings := common_settings.duplicate(true)
	var target_read_buffer_output_summary := {}
	var compact_state_chain := _compact_delta_state_chain_requested(common_settings)
	var compact_state_chain_reports: Array[Dictionary] = []
	var compact_state_chain_applied_count := 0

	var _voxel_count := VoxelGeneral.voxel_count(grid_size)
	var _gpu_complexity_buffer: RID = _rid_from_value(common_settings.get("complexity_field_buffer_rid", RID()))
	var _gpu_collision_buffer: RID = _rid_from_value(common_settings.get("collision_field_buffer_rid", RID()))
	var _gpu_state_chain_requested := _gpu_state_chain_enabled(common_settings)
	var _gpu_state_chain_external := _gpu_complexity_buffer.is_valid() and _gpu_collision_buffer.is_valid()
	var _gpu_state_chain_active := _gpu_state_chain_requested and _gpu_state_chain_external
	var _gpu_state_chain_blocked_reason := "none" if _gpu_state_chain_active else "external_complexity_collision_field_buffers_missing" if _gpu_state_chain_requested else "disabled"
	var _gpu_state_chain_source := str(common_settings.get("gpu_state_chain_source", "caller_provided_complexity_collision_field_rids"))
	var _gpu_state_chain_owner := str(common_settings.get("complexity_field_buffer_owner", common_settings.get("resident_complexity_field_owner", "external")))
	var _gpu_state_chain_rd: RenderingDevice = get_rendering_device()
	var raw_chain_rd = common_settings.get("resident_complexity_field_rendering_device", common_settings.get("rendering_device", null))
	if _gpu_state_chain_rd == null and raw_chain_rd is RenderingDevice:
		_gpu_state_chain_rd = raw_chain_rd as RenderingDevice

	var order := _sort_asset_defs_by_priority_weight(asset_defs, common_settings)
	var result_by_index: Dictionary = {}

	for slot in order:
		var orig_idx: int = slot
		var asset_def: Dictionary = asset_defs[orig_idx]

		if global_quota >= 0 and total_placed >= global_quota:
			result_by_index[orig_idx] = {
				"asset_index": orig_idx, "results": [], "world_results": [],
				"result_count": 0, "stamp_deltas": [], "skipped_quota": true,
			}
			continue

		var cv: Array = asset_def.get("collision", [])
		if cv.is_empty():
			result_by_index[orig_idx] = {
				"asset_index": orig_idx, "results": [], "world_results": [], "result_count": 0,
			}
			continue

		var base_footprint := bake_footprint_from_collision(
			cv, voxel_size,
			bool(asset_def.get("add_support", true)),
			int(asset_def.get("clearance_slices", 1)))
		if base_footprint.is_empty():
			result_by_index[orig_idx] = {
				"asset_index": orig_idx, "results": [], "world_results": [], "result_count": 0,
			}
			continue

		var per_asset_settings := common_settings.duplicate(true)
		var overrides: Dictionary = asset_def.get("settings", {})
		for key in overrides:
			per_asset_settings[key] = overrides[key]
		if _gpu_state_chain_active:
			if _gpu_state_chain_rd != null and get_rendering_device() != _gpu_state_chain_rd:
				attach_rendering_device(_gpu_state_chain_rd, false)
			per_asset_settings["complexity_field_buffer_rid"] = _gpu_complexity_buffer
			per_asset_settings["collision_field_buffer_rid"] = _gpu_collision_buffer
			per_asset_settings["complexity_field_buffer_borrowed"] = true
			per_asset_settings["collision_field_buffer_borrowed"] = true
			per_asset_settings["complexity_field_buffer_owner"] = _gpu_state_chain_owner
			per_asset_settings["collision_field_buffer_owner"] = str(common_settings.get("collision_field_buffer_owner", _gpu_state_chain_owner))
			per_asset_settings["gpu_state_chain_source"] = _gpu_state_chain_source
			per_asset_settings["read_full_field_outputs"] = false
		var routed_regions_by_asset := _candidate_regions_by_asset_from_settings(common_settings)
		if _has_asset_candidate_regions(asset_def):
			var asset_regions: Array = _asset_candidate_regions(asset_def)
			if asset_regions.is_empty():
				result_by_index[orig_idx] = {
					"asset_index": orig_idx, "results": [], "world_results": [], "result_count": 0,
					"stamp_deltas": [], "skipped_prefilter": true,
				}
				continue
			per_asset_settings["candidate_voxel_sparses"] = asset_regions
		elif _has_candidate_regions_by_asset(common_settings):
			var route_key = orig_idx if routed_regions_by_asset.has(orig_idx) else str(orig_idx)
			var routed_regions = routed_regions_by_asset.get(route_key, [])
			if routed_regions.is_empty():
				result_by_index[orig_idx] = {
					"asset_index": orig_idx, "results": [], "world_results": [], "result_count": 0,
					"stamp_deltas": [],
					"skipped_prefilter": true,
				}
				continue
			per_asset_settings["candidate_voxel_sparses"] = routed_regions
		if asset_def.has("result_capacity"):
			per_asset_settings["result_capacity"] = int(asset_def.result_capacity)
		if asset_def.has("min_distance_voxels"):
			per_asset_settings["min_distance_voxels"] = float(asset_def.min_distance_voxels)
		for profile_key in ["profile_id", "auto_voxel_profile_id", "runtime_profile_id", "asset_profile_id"]:
			if asset_def.has(profile_key):
				per_asset_settings["profile_id"] = int(asset_def[profile_key])
				break
		per_asset_settings["asset_index"] = orig_idx
		if compact_state_chain and not _gpu_state_chain_active:
			per_asset_settings["read_stamp_deltas"] = true
			per_asset_settings["read_full_field_outputs"] = false
			per_asset_settings["cpu_state_chain_mode"] = "compact_stamp_deltas"

		if global_quota >= 0:
			var remaining := global_quota - total_placed
			var cap := int(per_asset_settings.get("result_capacity", result_capacity))
			per_asset_settings["result_capacity"] = mini(cap, remaining)

		var pivot_variants = load("res://scripts/auto_voxel_descriptor.gd").normalize_pivot_variants(asset_def.get("pivot_variants", [{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}]))
		var best_gpu_out: Dictionary = {}
		var best_pivot: Dictionary = {}
		var best_pivot_score := -INF
		for pivot in pivot_variants:
			var pivot_offset := _vector3_from_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)
			var pivot_voxels := _world_offset_to_voxels(pivot_offset, voxel_size)
			var footprint := apply_pivot_to_footprint(base_footprint, pivot_voxels)
			if _gpu_state_chain_active and _gpu_state_chain_rd != null and get_rendering_device() != _gpu_state_chain_rd:
				attach_rendering_device(_gpu_state_chain_rd, false)
			var gpu_out := run_minimal(current_complexity, current_collision, footprint, grid_size, per_asset_settings)
			if bool(gpu_out.get("contract_blocked", false)):
				return _gpu_contract_blocked_multi_asset_output(
					complexity_field,
					collision_field,
					asset_defs,
					gpu_out.get("gpu_runtime_profile_contract", gpu_contract),
					common_settings
				)
			if gpu_out.has("candidate_route_input_contract"):
				candidate_route_output_settings["candidate_route_input_contract"] = gpu_out.get("candidate_route_input_contract", {})
			var pivot_score := _placement_output_score(gpu_out) + float(pivot.get("score_bias", 0.0))
			if not gpu_out.is_empty() and (best_gpu_out.is_empty() or pivot_score > best_pivot_score):
				best_gpu_out = gpu_out
				best_pivot = pivot
				best_pivot_score = pivot_score

		if best_gpu_out.is_empty():
			result_by_index[orig_idx] = {
				"asset_index": orig_idx, "results": [], "world_results": [], "result_count": 0,
			}
			continue
		if best_gpu_out.has("candidate_route_input_contract"):
			candidate_route_output_settings["candidate_route_input_contract"] = best_gpu_out.get("candidate_route_input_contract", {})
			candidate_route_output_settings["candidate_route_readback_source"] = str(best_gpu_out.get("candidate_route_readback_source", "none"))
			candidate_route_output_settings["candidate_route_runtime_read_source"] = str(best_gpu_out.get("candidate_route_runtime_read_source", "none"))
		if best_gpu_out.has("target_read_buffer_summary"):
			target_read_buffer_output_summary = best_gpu_out.get("target_read_buffer_summary", {})

		var count := int(best_gpu_out.get("result_count", 0))
		var raw_results: Array = best_gpu_out.get("results", [])
		var world := VoxelPlacementOutputScript.results_to_world(raw_results, voxel_size, grid_origin, 24, best_pivot)

		var compact_state_chain_report := {}
		if compact_state_chain and not _gpu_state_chain_active:
			compact_state_chain_report = _apply_stamp_deltas_to_cpu_state(
				current_complexity,
				current_collision,
				best_gpu_out.get("stamp_deltas", []),
				grid_size
			)
			compact_state_chain_report["asset_index"] = orig_idx
			compact_state_chain_report["result_count"] = count
			compact_state_chain_reports.append(compact_state_chain_report)
			compact_state_chain_applied_count += int(compact_state_chain_report.get("applied_delta_count", 0))
		elif not _gpu_state_chain_active:
			current_complexity = best_gpu_out.get("complexity_field_out", current_complexity)
			current_collision = best_gpu_out.get("collision_field_out", current_collision)
		total_placed += count

		var asset_result := {
			"asset_index": orig_idx,
			"results": raw_results,
			"world_results": world,
			"result_count": count,
			"stamp_deltas": best_gpu_out.get("stamp_deltas", []),
			"stamp_delta_count": best_gpu_out.get("stamp_delta_count", 0),
			"stamp_delta_readback_source": best_gpu_out.get("stamp_delta_readback_source", ""),
			"stamp_bounds": best_gpu_out.get("stamp_bounds", []),
			"stamp_bounds_source": best_gpu_out.get("stamp_bounds_source", ""),
			"pivot_variant": best_pivot,
			"pivot_variant_count": pivot_variants.size(),
		}
		if best_gpu_out.has("full_field_readback"):
			asset_result["full_field_readback"] = best_gpu_out.get("full_field_readback", {})
		if best_gpu_out.has("cpu_state_chain"):
			asset_result["cpu_state_chain"] = best_gpu_out.get("cpu_state_chain", {})
		if compact_state_chain:
			asset_result["compact_state_chain"] = compact_state_chain_report
		if best_gpu_out.has("gpu_runtime_profile_contract"):
			asset_result["gpu_runtime_profile_contract"] = best_gpu_out.get("gpu_runtime_profile_contract", {})
		if best_gpu_out.has("candidate_route_input_contract"):
			asset_result["candidate_route_readback_source"] = str(best_gpu_out.get("candidate_route_readback_source", "none"))
			asset_result["candidate_route_runtime_read_source"] = str(best_gpu_out.get("candidate_route_runtime_read_source", "none"))
			asset_result["candidate_route_input_contract"] = best_gpu_out.get("candidate_route_input_contract", {})
			asset_result["candidate_route_binding_debug"] = best_gpu_out.get("candidate_route_binding_debug", {})
		if best_gpu_out.has("target_read_buffer_summary"):
			asset_result["target_read_buffer_summary"] = best_gpu_out.get("target_read_buffer_summary", {})
		if bool(best_gpu_out.get("contract_blocked", false)):
			asset_result["contract_blocked"] = true
		if best_gpu_out.has("cpu_fallback"):
			asset_result["cpu_fallback"] = false
		result_by_index[orig_idx] = asset_result

	var asset_results: Array[Dictionary] = []
	var runtime_writeback_report := _new_gpu_autoobject_runtime_writeback_report(
		runtime_provider,
		profile_container,
		gpu_contract,
		write_accepted_placements_to_gpu_runtime
	)
	for i in range(asset_defs.size()):
		asset_results.append(result_by_index.get(i, {
			"asset_index": i, "results": [], "world_results": [], "result_count": 0,
		}))

	if write_accepted_placements_to_gpu_runtime:
		for orig_idx in range(asset_defs.size()):
			var asset_result: Dictionary = result_by_index.get(orig_idx, {})
			if asset_result.is_empty():
				continue
			var result_count := int(asset_result.get("result_count", 0))
			if result_count <= 0:
				continue
			var asset_def: Dictionary = asset_defs[orig_idx]
			var per_asset_settings := common_settings.duplicate(true)
			var overrides: Dictionary = asset_def.get("settings", {})
			for key in overrides:
				per_asset_settings[key] = overrides[key]
			for profile_key in ["profile_id", "auto_voxel_profile_id", "runtime_profile_id", "asset_profile_id"]:
				if asset_def.has(profile_key):
					per_asset_settings["profile_id"] = int(asset_def[profile_key])
					break
			per_asset_settings["asset_index"] = orig_idx
			var asset_writeback := _write_accepted_placements_to_gpu_runtime(
				runtime_provider,
				orig_idx,
				asset_def,
				per_asset_settings,
				asset_result.get("world_results", []),
				asset_result.get("results", []),
				asset_result.get("stamp_deltas", []),
				asset_result.get("stamp_bounds", []),
				common_settings
			)
			_merge_gpu_autoobject_runtime_writeback_report(runtime_writeback_report, asset_writeback)
			asset_result["gpu_autoobject_runtime_writeback"] = asset_writeback
			result_by_index[orig_idx] = asset_result
			asset_results[orig_idx] = asset_result

	var instance_stamp_writeback := _write_accepted_placements_to_scene_voxel_committer(
		asset_defs,
		result_by_index,
		asset_results,
		common_settings,
		grid_size,
		voxel_size,
		grid_origin
	)

	var output := {
		"asset_results": asset_results,
		"complexity_field_out": current_complexity if not _gpu_state_chain_active else PackedFloat32Array(),
		"collision_field_out": current_collision if not _gpu_state_chain_active else PackedFloat32Array(),
		"total_placed": total_placed,
		"processing_order": order,
		"gpu_runtime_profile_contract": gpu_contract,
	}
	if _gpu_state_chain_active:
		output["gpu_state_chain"] = {
			"mode": "gpu_resident",
			"source": _gpu_state_chain_source,
			"gpu_state_chaining": true,
			"cpu_state_chaining": false,
			"full_field_readback_required": false,
			"stamp_delta_cpu_state_chaining": false,
			"read_full_field_outputs": false,
			"complexity_field_buffer_rid": _gpu_complexity_buffer,
			"collision_field_buffer_rid": _gpu_collision_buffer,
			"complexity_field_buffer_borrowed": true,
			"collision_field_buffer_borrowed": true,
			"owner": _gpu_state_chain_owner,
			"borrowed_from": _gpu_state_chain_owner,
			"blocked_reason": "none",
		}
		if bool(common_settings.get("read_full_field_outputs", false)):
			if _gpu_state_chain_rd != null and get_rendering_device() != _gpu_state_chain_rd:
				attach_rendering_device(_gpu_state_chain_rd, false)
			# Debug/readback: read final GPU state back to CPU
			submit_and_sync(true)
			if _rd != null:
				var _scene_out := _rd.buffer_get_data(_gpu_complexity_buffer)
				var _collision_out := _rd.buffer_get_data(_gpu_collision_buffer)
				output["complexity_field_out"] = SceneVoxelTileCodecScript.decode_complexity_field_rgba8_alpha_bytes(_scene_out, _voxel_count)
				output["collision_field_out"] = SceneVoxelTileCodecScript.decode_collision_field_r8_word_bytes(_collision_out, _voxel_count)
				output["gpu_state_chain"]["read_full_field_outputs"] = true
				output["gpu_state_chain"]["complexity_field_out_source"] = "gpu_storage_buffer_full_field_readback_debug"
				output["gpu_state_chain"]["collision_field_out_source"] = "gpu_storage_buffer_full_field_readback_debug"
			else:
				output["gpu_state_chain"]["read_full_field_outputs"] = false
				output["gpu_state_chain"]["readback_blocked_reason"] = "rendering_device_unavailable_for_debug_readback"
		else:
			output["gpu_state_chain"]["complexity_field_out_source"] = "gpu_resident_skipped"
			output["gpu_state_chain"]["collision_field_out_source"] = "gpu_resident_skipped"
	elif compact_state_chain:
		if _gpu_state_chain_requested:
			output["gpu_state_chain"] = {
				"mode": "inactive",
				"source": "none",
				"gpu_state_chaining": false,
				"cpu_state_chaining": true,
				"full_field_readback_required": false,
				"complexity_field_buffer_rid": RID(),
				"collision_field_buffer_rid": RID(),
				"complexity_field_buffer_borrowed": false,
				"collision_field_buffer_borrowed": false,
				"owner": "none",
				"borrowed_from": "none",
				"blocked_reason": _gpu_state_chain_blocked_reason,
				"gpu_first": true,
				"cpu_fallback": false,
			}
		output["cpu_state_chain"] = {
			"mode": "compact_stamp_deltas",
			"source": "stamp_shader_storage_buffer",
			"cpu_state_chaining": true,
			"full_field_readback_required": false,
			"stamp_delta_cpu_state_chaining": true,
			"read_stamp_deltas": true,
			"asset_reports": compact_state_chain_reports,
			"applied_delta_count": compact_state_chain_applied_count,
		}
	var candidate_route_output_contract: Dictionary = candidate_route_output_settings.get("candidate_route_input_contract", {})
	if candidate_route_output_contract.has("normalized_readback_source"):
		output["candidate_route_readback_source"] = str(candidate_route_output_contract.get("normalized_readback_source", "none"))
		output["candidate_route_runtime_read_source"] = str(candidate_route_output_contract.get("normalized_runtime_read_source", "none"))
		output["candidate_route_input_contract"] = candidate_route_output_contract
	else:
		output["candidate_route_readback_source"] = _candidate_route_readback_source_from_settings(candidate_route_output_settings)
		output["candidate_route_runtime_read_source"] = _candidate_route_runtime_read_source_from_settings(candidate_route_output_settings)
		output["candidate_route_input_contract"] = _candidate_route_input_contract_from_settings(candidate_route_output_settings)
	if write_accepted_placements_to_gpu_runtime:
		output["gpu_autoobject_runtime_writeback"] = runtime_writeback_report
	if not target_read_buffer_output_summary.is_empty():
		output["target_read_buffer_summary"] = target_read_buffer_output_summary
	if not instance_stamp_writeback.is_empty():
		output["instance_stamp_writeback"] = instance_stamp_writeback
		# P0 #3: propagate accepted placement RIDs to top-level for SPA handoff
		var _records_rid = instance_stamp_writeback.get("accepted_placement_source_records_rid", RID())
		if _records_rid is RID and (_records_rid as RID).is_valid():
			output["accepted_placement_source_records_rid"] = _records_rid
		var _ranges_rid = instance_stamp_writeback.get("accepted_placement_source_ranges_rid", RID())
		if _ranges_rid is RID and (_ranges_rid as RID).is_valid():
			output["accepted_placement_source_ranges_rid"] = _ranges_rid
		output["accepted_placement_source_record_count"] = instance_stamp_writeback.get("accepted_placement_source_record_count", 0)
		output["accepted_placement_source_range_count"] = instance_stamp_writeback.get("accepted_placement_source_range_count", 0)
	if str(gpu_contract.get("reason", "")) != "not_requested":
		output["cpu_fallback"] = false
	return output


## 按 priority（降序）对 asset_defs 分组排序；同一 priority 分组内使用带种子的随机数
## 生成器做加权乱序（见 _weighted_shuffle），返回原始索引组成的执行顺序数组。
static func _sort_asset_defs_by_priority_weight(
	asset_defs: Array, common_settings: Dictionary
) -> Array[int]:
	if asset_defs.is_empty():
		return []

	var entries: Array[Dictionary] = []
	for i in range(asset_defs.size()):
		var d: Dictionary = asset_defs[i]
		entries.append({
			"index": i,
			"priority": int(d.get("priority", 0)),
			"weight": maxf(float(d.get("weight", 1.0)), 0.0001),
		})

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.priority) > int(b.priority))

	var rng := RandomNumberGenerator.new()
	var rng_seed := int(common_settings.get("seed", -1))
	if rng_seed >= 0:
		rng.seed = rng_seed
	else:
		rng.randomize()

	var result: Array[int] = []
	var group_start := 0
	while group_start < entries.size():
		var group_priority := int(entries[group_start].priority)
		var group_end := group_start + 1
		while group_end < entries.size() and int(entries[group_end].priority) == group_priority:
			group_end += 1

		if group_end - group_start <= 1:
			result.append(int(entries[group_start].index))
		else:
			var group: Array[Dictionary] = []
			for gi in range(group_start, group_end):
				group.append(entries[gi])
			var shuffled := _weighted_shuffle(group, rng)
			for s in shuffled:
				result.append(int(s.index))

		group_start = group_end
	return result


## 对一组带权重的字典做加权随机乱序（不放回抽样）：每一步按剩余元素的权重比例抽取下一个，
## 权重越高的元素越可能排在前面。
static func _weighted_shuffle(
	group: Array[Dictionary], rng: RandomNumberGenerator
) -> Array[Dictionary]:
	var remaining := group.duplicate()
	var result: Array[Dictionary] = []
	while remaining.size() > 1:
		var total_weight := 0.0
		for e in remaining:
			total_weight += float(e.weight)
		var pick := rng.randf() * total_weight
		var cumulative := 0.0
		var chosen_idx := 0
		for j in range(remaining.size()):
			cumulative += float(remaining[j].weight)
			if cumulative >= pick:
				chosen_idx = j
				break
		result.append(remaining[chosen_idx])
		remaining.remove_at(chosen_idx)
	if not remaining.is_empty():
		result.append(remaining[0])
	return result


## 将 footprint 中每个体素条目的 local_pos 按 pivot_voxels 整体平移，用于应用不同的锚点
## （pivot）变体；偏移量为零时仅做深拷贝，不做位移。
static func apply_pivot_to_footprint(footprint: Array, pivot_voxels: Vector3i) -> Array[Dictionary]:
	if pivot_voxels == Vector3i.ZERO:
		var copied: Array[Dictionary] = []
		for e in footprint:
			if e is Dictionary:
				copied.append((e as Dictionary).duplicate(true))
		return copied
	var shifted: Array[Dictionary] = []
	for e in footprint:
		if not e is Dictionary:
			continue
		var entry := (e as Dictionary).duplicate(true)
		entry["local_pos"] = VoxelGeneral.vector3i_from_value(entry.get("local_pos", Vector3i.ZERO), Vector3i.ZERO) - pivot_voxels
		shifted.append(entry)
	return shifted


## 将世界坐标系下的偏移量按 voxel_size 转换为体素坐标系下的整数偏移（委托给 VoxelGeneral）。
static func _world_offset_to_voxels(offset: Vector3, voxel_size: Vector3) -> Vector3i:
	return VoxelGeneral.world_offset_to_voxels(offset, voxel_size)


## 汇总 run_minimal 的 GPU 输出中所有有效（valid）放置结果的 score，用于比较不同 pivot
## 变体的优劣；输出为空或结果数为 0 时返回 -INF。
static func _placement_output_score(gpu_out: Dictionary) -> float:
	if gpu_out.is_empty():
		return -INF
	var count := int(gpu_out.get("result_count", 0))
	if count <= 0:
		return -INF
	var score := 0.0
	var results: Array = gpu_out.get("results", [])
	for raw in results:
		if raw is Dictionary and bool((raw as Dictionary).get("valid", false)):
			score += float((raw as Dictionary).get("score", 0.0))
	return score


## 将 Vector3 / 至少含 3 个元素的 Array / 含 x、y、z 键的 Dictionary 等多种形式的值统一
## 转换为 Vector3；无法识别时返回 fallback。
static func _vector3_from_value(value, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var d := value as Dictionary
		return Vector3(float(d.get("x", fallback.x)), float(d.get("y", fallback.y)), float(d.get("z", fallback.z)))
	return fallback


## 单资产单 footprint 的 GPU 放置调度入口，由 run_multi_asset 针对每个 pivot 变体调用一次。
## 校验 grid_size/footprint 等输入合法性，通过预筛选与候选路线绑定解析待测试的候选 tile 列表，
## 确保 GPU 设备、着色器与管线就绪，并在需要时准备同类型物体间距排斥所需的 object ref 缓冲区。
## 依次派发 score/reduce/stamp 计算着色器完成打分、归约与写回，
## 最终解码并返回放置结果记录，以及 stamp 增量数据与包围盒等回读信息。
func run_minimal(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	footprint: Array,
	grid_size: Vector3i,
	settings: Dictionary = {}
) -> Dictionary:
	_apply_settings(settings)
	var voxel_count := VoxelGeneral.voxel_count(grid_size)
	if voxel_count <= 0:
		push_error("VoxelPlacementGenerator: grid_size must be positive")
		return {}
	if footprint.is_empty():
		push_error("VoxelPlacementGenerator: footprint must not be empty")
		return {}
	if footprint.size() > FOOTPRINT_CAPACITY:
		push_error("VoxelPlacementGenerator: footprint is limited to %d voxels" % FOOTPRINT_CAPACITY)
		return {}

	var complexity_data := _normalize_float_array(complexity_field, voxel_count)
	var collision_data := _normalize_float_array(collision_field, voxel_count)
	var _complexity_field_gpu_rid: RID = _rid_from_value(settings.get("complexity_field_buffer_rid", RID()))
	var _collision_field_gpu_rid: RID = _rid_from_value(settings.get("collision_field_buffer_rid", RID()))
	var _complexity_field_gpu_resident: bool = _complexity_field_gpu_rid.is_valid() and _collision_field_gpu_rid.is_valid()
	var _complexity_field_gpu_borrowed_external := _complexity_field_gpu_resident \
		and bool(settings.get("complexity_field_buffer_borrowed", settings.get("complexity_field_buffer_external", true))) \
		and bool(settings.get("collision_field_buffer_borrowed", settings.get("collision_field_buffer_external", true)))
	var _complexity_field_gpu_source := str(settings.get("gpu_state_chain_source", settings.get("complexity_field_read_source", "caller_provided_complexity_collision_field_rids")))
	var _complexity_field_gpu_owner := str(settings.get("complexity_field_buffer_owner", settings.get("resident_complexity_field_owner", "external")))
	var footprint_buffers := _pack_footprint(footprint)
	var tile_counts := Vector3i(
		ceili(float(grid_size.x) / float(TILE_SIZE)),
		ceili(float(grid_size.y) / float(TILE_SIZE)),
		ceili(float(grid_size.z) / float(TILE_SIZE))
	)
	var tile_count := tile_counts.x * tile_counts.y * tile_counts.z
	var candidate_voxel_sparse_ids := _build_candidate_voxel_sparse_ids(settings, tile_counts, tile_count)
	var direct_all_tiles := _uses_direct_all_tile_candidates(settings)
	var candidate_voxel_sparse_count := tile_count if direct_all_tiles else candidate_voxel_sparse_ids.size()
	var gpu_contract := _validate_gpu_runtime_profile_contract(settings)
	if not bool(gpu_contract.get("ok", true)):
		return _gpu_contract_blocked_minimal_output(
			complexity_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids,
			gpu_contract
		)
	if candidate_voxel_sparse_count <= 0:
		return _empty_prefilter_output(
			complexity_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids
		)

	log_name = "VoxelPlacementGenerator"
	sync_global_device = true
	if not ensure_device():
		return _gpu_contract_blocked_minimal_output(
			complexity_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids,
			_gpu_contract_result(false, "missing_rendering_device")
		)

	_load_shaders()
	if not _placement_pipeline_ready():
		_free_gpu()
		return _gpu_contract_blocked_minimal_output(
			complexity_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids,
			_gpu_contract_result(false, "placement_shader_pipeline_not_ready")
		)

	var object_ref_contract := _prepare_scene_voxel_tile_object_ref_exclusion(gpu_contract, settings, tile_counts)
	gpu_contract = _merge_scene_voxel_tile_object_ref_contract(gpu_contract, object_ref_contract)
	if bool(gpu_contract.get("contract_blocked", false)):
		_free_gpu()
		return _gpu_contract_blocked_minimal_output(
			complexity_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids,
			gpu_contract
		)

	var route_binding := _prepare_candidate_route_binding(settings, direct_all_tiles)
	var route_settings: Dictionary = route_binding.get("settings", settings)
	var resident_route_sparse := _prepare_candidate_sparse_ids_from_resident_route_gpu(route_binding, tile_count)
	var resident_route_sparse_gpu := bool(resident_route_sparse.get("ok", false))
	if resident_route_sparse_gpu:
		candidate_voxel_sparse_ids = resident_route_sparse.get("candidate_voxel_sparse_ids", PackedInt32Array())
		direct_all_tiles = false
		candidate_voxel_sparse_count = candidate_voxel_sparse_ids.size()
		_mark_candidate_route_sparse_adapter_ready(route_settings, resident_route_sparse)
		route_binding["settings"] = route_settings
	elif bool(route_binding.get("bindable", false)):
		_mark_candidate_route_sparse_adapter_blocked(route_settings, str(resident_route_sparse.get("reason", "resident_route_gpu_sparse_adapter_blocked")))
		route_binding["settings"] = route_settings
		candidate_voxel_sparse_ids = PackedInt32Array()
		direct_all_tiles = false
		candidate_voxel_sparse_count = 0
	if candidate_voxel_sparse_count <= 0:
		_free_gpu()
		var empty_output := _empty_prefilter_output(
			complexity_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids
		)
		empty_output["candidate_route_readback_source"] = _candidate_route_readback_source_from_settings(route_settings)
		empty_output["candidate_route_runtime_read_source"] = _candidate_route_runtime_read_source_from_settings(route_settings)
		empty_output["candidate_route_input_contract"] = _candidate_route_input_contract_from_settings(route_settings)
		return empty_output

	var candidate_count := candidate_voxel_sparse_count * top_k
	var stamp_capacity := result_capacity * footprint.size()

	if _complexity_field_gpu_borrowed_external:
		track_borrowed_rid(_complexity_field_gpu_rid, KIND_BUFFER, SCOPE_FRAME, "%s:complexity_field" % _complexity_field_gpu_owner)
		track_borrowed_rid(_collision_field_gpu_rid, KIND_BUFFER, SCOPE_FRAME, "%s:collision_field" % _complexity_field_gpu_owner)
	var complexity_buffer: RID = _complexity_field_gpu_rid if _complexity_field_gpu_resident else storage_buffer_from_bytes(
		SceneVoxelTileCodecScript.pack_complexity_field_rgba8_bytes(complexity_data, voxel_count),
		SCOPE_FRAME,
		"placement_complexity_field_rgba8"
	)
	var collision_buffer: RID = _collision_field_gpu_rid if _complexity_field_gpu_resident else storage_buffer_from_bytes(
		SceneVoxelTileCodecScript.pack_collision_field_r8_word_bytes(collision_data, voxel_count),
		SCOPE_FRAME,
		"placement_collision_field_r8_words"
	)
	var footprint_pos_buffer := storage_buffer_from_bytes(footprint_buffers.pos_bytes)
	var footprint_weight_buffer := storage_buffer_from_bytes(footprint_buffers.weight_bytes)
	var candidate_voxel_sparse_buffer := storage_buffer_from_bytes(
		PackedByteArray() if direct_all_tiles else pack_u32_array(candidate_voxel_sparse_ids)
	)
	var tile_topk_buffer := storage_buffer_zero(candidate_count * RECORD_STRIDE * 16)
	var result_buffer := storage_buffer_zero(result_capacity * RECORD_STRIDE * 16)
	var result_count_buffer := storage_buffer_zero(4)
	var stamp_delta_buffer := storage_buffer_zero(maxi(stamp_capacity, 1) * DELTA_STRIDE * 16)
	var stamp_delta_count_buffer := storage_buffer_zero(4)
	var stamp_bounds_buffer := storage_buffer_zero(maxi(result_capacity, 1) * STAMP_BOUNDS_STRIDE * 16)

	var target_buffer_pack := _target_read_buffer_pack(settings, voxel_count)
	if not bool(target_buffer_pack.get("ready", false)):
		var blocked_reason := str(target_buffer_pack.get("reason", "target_read_buffer_not_ready"))
		var blocked_output := _gpu_contract_blocked_minimal_output(
			complexity_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids,
			_gpu_contract_result(false, blocked_reason)
		)
		blocked_output["target_read_buffer_summary"] = _target_read_buffer_summary(target_buffer_pack)
		blocked_output["target_read_buffer_source"] = str(target_buffer_pack.get("target_read_buffer_source", "none"))
		blocked_output["target_read_buffer_blocked_reason"] = blocked_reason
		_free_gpu()
		return blocked_output
	var has_target := 1 if bool(target_buffer_pack.get("has_target", false)) else 0
	var target_field_buffer: RID = target_buffer_pack.get("target_field_buffer", RID())
	if bool(target_buffer_pack.get("target_read_buffers_borrowed", false)):
		track_borrowed_rid(target_field_buffer, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_field")
	elif bool(target_buffer_pack.get("target_field_bytes_uploaded", false)):
		var target_field_data: PackedFloat32Array = target_buffer_pack.get("target_field_bytes", PackedFloat32Array())
		target_field_buffer = storage_buffer_from_floats(
			target_field_data,
			SCOPE_FRAME,
			"target_field_uploaded"
		)
	else:
		var target_color_buffer := storage_buffer_from_bytes(
			target_buffer_pack.get("target_color_rgba8_bytes", PackedByteArray()),
			SCOPE_FRAME,
			"target_color_rgba8_uploaded"
		)
		target_field_buffer = _ensure_combined_target_field_buffer(complexity_buffer, collision_buffer, target_color_buffer, voxel_count)
	if not target_field_buffer.is_valid():
		var blocked_output := _gpu_contract_blocked_minimal_output(
			complexity_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids,
			_gpu_contract_result(false, "target_field_buffer_not_ready")
		)
		blocked_output["target_read_buffer_summary"] = _target_read_buffer_summary(target_buffer_pack)
		blocked_output["target_read_buffer_source"] = str(target_buffer_pack.get("target_read_buffer_source", "none"))
		blocked_output["target_read_buffer_blocked_reason"] = "target_field_buffer_not_ready"
		_free_gpu()
		return blocked_output

	var debug_voxel_buffer := storage_buffer_zero(voxel_count * NUM_DEBUG_CHANNELS * 4)
	var score_contract_debug_buffer := storage_buffer_from_bytes(_pack_score_contract_debug_reset())
	var candidate_route_adapter_count_buffer := RID()
	var candidate_route_indirect_args_buffer := RID()

	if resident_route_sparse_gpu:
		candidate_route_adapter_count_buffer = storage_buffer_zero(
			CANDIDATE_ROUTE_ADAPTER_COUNT_WORDS * 4,
			SCOPE_FRAME,
			"candidate_route_adapter_count_u32x4"
		)
		candidate_route_indirect_args_buffer = dispatch_indirect_args_buffer_zero(
			SCOPE_FRAME,
			"candidate_route_score_indirect_args_u32x3"
		)
		_dispatch_candidate_route_sparse_adapter(
			route_binding,
			candidate_voxel_sparse_buffer,
			candidate_route_adapter_count_buffer,
			candidate_route_indirect_args_buffer,
			tile_count,
			candidate_voxel_sparse_count
		)
	var score_dispatch := _dispatch_score(
		complexity_buffer,
		collision_buffer,
		footprint_pos_buffer,
		footprint_weight_buffer,
		candidate_voxel_sparse_buffer,
		tile_topk_buffer,
		target_field_buffer,
		debug_voxel_buffer,
		score_contract_debug_buffer,
		route_binding,
		candidate_route_indirect_args_buffer,
		grid_size,
		tile_counts,
		tile_count,
		candidate_voxel_sparse_count,
		direct_all_tiles,
		footprint.size(),
		has_target,
		gpu_contract,
		route_settings
	)
	if resident_route_sparse_gpu:
		resident_route_sparse["score_dispatch_indirect"] = bool(score_dispatch.get("score_dispatch_indirect", false))
		resident_route_sparse["score_dispatch_indirect_block_reason"] = str(score_dispatch.get("score_dispatch_indirect_block_reason", "none"))
	_dispatch_reduce(tile_topk_buffer, result_buffer, result_count_buffer, candidate_count)
	_dispatch_stamp(
		complexity_buffer,
		collision_buffer,
		result_buffer,
		result_count_buffer,
		footprint_pos_buffer,
		footprint_weight_buffer,
		stamp_delta_buffer,
		stamp_delta_count_buffer,
		stamp_bounds_buffer,
		grid_size,
		footprint.size(),
		settings
	)

	submit_and_sync(true)

	var result_count_data := _rd.buffer_get_data(result_count_buffer)
	var result_count := _decode_u32_count(result_count_data)
	result_count = clampi(result_count, 0, result_capacity)
	var result_readback_bytes := result_count * RECORD_STRIDE * 16
	var result_data := _rd.buffer_get_data(result_buffer, 0, result_readback_bytes)
	var read_tile_topk := bool(settings.get("read_tile_topk", false))
	var tile_topk_data := _rd.buffer_get_data(tile_topk_buffer) if read_tile_topk else PackedByteArray()
	var compact_state_chain := _compact_delta_state_chain_requested(settings)
	var _gpu_resident_field_input: bool = _complexity_field_gpu_resident
	var read_full_field_outputs := bool(settings.get("read_full_field_outputs", false))
	if _gpu_resident_field_input and not read_full_field_outputs:
		pass  # GPU-resident: skip full-field readback, borrowed buffers stay on GPU
	var scene_out_data := _rd.buffer_get_data(complexity_buffer) if read_full_field_outputs else PackedByteArray()
	var collision_out_data := _rd.buffer_get_data(collision_buffer) if read_full_field_outputs else PackedByteArray()
	var stamp_delta_count_data := _rd.buffer_get_data(stamp_delta_count_buffer)
	var stamp_delta_count := clampi(_decode_u32_count(stamp_delta_count_data), 0, stamp_capacity)
	var read_stamp_deltas := bool(settings.get("read_stamp_deltas", false))
	var stamp_delta_data := _rd.buffer_get_data(stamp_delta_buffer, 0, stamp_delta_count * DELTA_STRIDE * 16) if read_stamp_deltas else PackedByteArray()
	var decoded_stamp_deltas: Array[Dictionary] = []
	if read_stamp_deltas:
		decoded_stamp_deltas = _decode_stamp_deltas(stamp_delta_data, stamp_delta_count)
	var stamp_bounds_data := _rd.buffer_get_data(stamp_bounds_buffer, 0, result_count * STAMP_BOUNDS_STRIDE * 16)
	var read_debug_voxel := bool(settings.get("read_debug_voxel", false))
	var debug_voxel_data := _rd.buffer_get_data(debug_voxel_buffer) if read_debug_voxel else PackedByteArray()
	var score_contract_debug_data := _rd.buffer_get_data(score_contract_debug_buffer)
	var score_contract_debug := _decode_score_contract_debug(score_contract_debug_data)
	var read_route_adapter_debug := bool(route_settings.get(
		"read_candidate_route_sparse_adapter_debug",
		route_settings.get("read_resident_route_sparse_adapter_debug", false)
	))
	var read_route_binding_debug := bool(route_settings.get(
		"read_candidate_route_binding_debug",
		read_route_adapter_debug
	))
	var route_binding_debug := _read_candidate_route_binding_debug(route_binding, read_route_binding_debug)
	if resident_route_sparse_gpu:
		resident_route_sparse = _read_candidate_route_sparse_adapter_result(
			candidate_voxel_sparse_buffer,
			candidate_route_adapter_count_buffer,
			candidate_route_indirect_args_buffer,
			route_binding_debug,
			tile_count,
			candidate_voxel_sparse_count,
			score_dispatch,
			read_route_adapter_debug
		)
		candidate_voxel_sparse_ids = resident_route_sparse.get("candidate_voxel_sparse_ids", PackedInt32Array())
		candidate_voxel_sparse_count = int(resident_route_sparse.get("candidate_count", candidate_voxel_sparse_ids.size()))
		_mark_candidate_route_sparse_adapter_ready(route_settings, resident_route_sparse)
	if read_route_binding_debug:
		_merge_candidate_route_binding_debug_into_settings(route_settings, route_binding_debug)
	gpu_contract = _annotate_score_contract_debug(gpu_contract, score_contract_debug)
	if not bool(gpu_contract.get("ok", true)):
		var blocked_output := _gpu_contract_blocked_minimal_output(
			complexity_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids,
			gpu_contract
		)
		blocked_output["gpu_runtime_profile_binding_debug"] = score_contract_debug
		_free_gpu()
		return blocked_output

	var _state_chain_contract := {}
	if read_full_field_outputs:
		_state_chain_contract = _full_field_readback_contract(voxel_count, "complexity_collision_storage_buffer_full_field_readback", true)
	elif _gpu_resident_field_input:
		_state_chain_contract = _gpu_resident_state_chain_contract(
			voxel_count,
			true,
			_complexity_field_gpu_rid,
			_collision_field_gpu_rid,
			_complexity_field_gpu_source,
			_complexity_field_gpu_owner,
			_complexity_field_gpu_borrowed_external
		)
	elif compact_state_chain:
		_state_chain_contract = _compact_delta_state_chain_contract(voxel_count, stamp_delta_count, decoded_stamp_deltas.size())
	else:
		_state_chain_contract = _full_field_readback_contract(voxel_count, "complexity_collision_storage_buffer_full_field_readback_disabled", false)
	var output := {
		"result_count": result_count,
		"result_readback_bytes": result_readback_bytes,
		"result_readback_count_source": "reduce_shader_result_count_buffer",
		"results": _decode_records(result_data, result_count),
		"tile_topk": _decode_records(tile_topk_data, candidate_count) if read_tile_topk else [],
		"tile_topk_readback_source": "score_shader_tile_topk_buffer" if read_tile_topk else "disabled",
		"complexity_field_out": SceneVoxelTileCodecScript.decode_complexity_field_rgba8_alpha_bytes(scene_out_data, voxel_count) if read_full_field_outputs else PackedFloat32Array(),
		"collision_field_out": SceneVoxelTileCodecScript.decode_collision_field_r8_word_bytes(collision_out_data, voxel_count) if read_full_field_outputs else PackedFloat32Array(),
		"complexity_field_out_source": _state_chain_contract.get("complexity_field_out_source", ""),
		"collision_field_out_source": _state_chain_contract.get("collision_field_out_source", ""),
		"complexity_field_out_byte_count": _state_chain_contract.get("complexity_field_out_byte_count", 0),
		"collision_field_out_byte_count": _state_chain_contract.get("collision_field_out_byte_count", 0),
		"full_field_readback": _state_chain_contract,
		"stamp_deltas": decoded_stamp_deltas,
		"stamp_delta_count": stamp_delta_count,
		"stamp_delta_count_source": "stamp_shader_storage_buffer",
		"stamp_delta_readback_source": "stamp_shader_storage_buffer" if read_stamp_deltas else "disabled",
		"stamp_bounds": _decode_stamp_bounds(stamp_bounds_data, result_count, grid_size),
		"stamp_bounds_source": "stamp_shader_storage_buffer",
		"debug_voxel": _decode_float_array(debug_voxel_data, voxel_count * NUM_DEBUG_CHANNELS) if read_debug_voxel else PackedFloat32Array(),
		"debug_voxel_readback_source": "score_shader_debug_voxel_buffer" if read_debug_voxel else "disabled",
		"debug_channel_names": DEBUG_CHANNEL_NAMES,
		"debug_channel_count": NUM_DEBUG_CHANNELS,
		"debug_channel_max": score_contract_debug.get("debug_channel_max", PackedFloat32Array()),
		"debug_channel_max_source": score_contract_debug.get("debug_channel_max_source", ""),
		"tile_count": tile_count,
		"tile_counts": tile_counts,
		"candidate_voxel_sparse_count": candidate_voxel_sparse_count,
		"candidate_voxel_sparse_ids": candidate_voxel_sparse_ids,
		"candidate_voxel_dispatch_mode": "direct_all_tiles" if direct_all_tiles else "sparse_buffer",
		"candidate_count": candidate_voxel_sparse_count * top_k,
		"gpu_runtime_profile_contract": gpu_contract,
		"gpu_runtime_profile_binding_debug": score_contract_debug,
		"candidate_route_readback_source": _candidate_route_readback_source_from_settings(route_settings),
		"candidate_route_runtime_read_source": _candidate_route_runtime_read_source_from_settings(route_settings),
		"candidate_route_input_contract": _candidate_route_input_contract_from_settings(route_settings),
		"candidate_route_binding_debug": route_binding_debug,
		"target_read_buffer_summary": _target_read_buffer_summary(target_buffer_pack),
	}
	if str(gpu_contract.get("reason", "")) != "not_requested":
		output["cpu_fallback"] = false
	if bool(_state_chain_contract.get("cpu_state_chaining", false)):
		output["cpu_state_chain"] = _state_chain_contract
	if bool(_state_chain_contract.get("gpu_state_chaining", false)):
		output["gpu_state_chain"] = _state_chain_contract

	_free_gpu()
	return output


## 当 GPU 运行时契约校验失败时，为 run_multi_asset 构造统一的"已阻断"空结果：
## 为每个资产生成占位失败结果，并原样返回输入的 complexity/collision 字段。
func _gpu_contract_blocked_multi_asset_output(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	contract: Dictionary,
	route_settings: Dictionary = {}
) -> Dictionary:
	var asset_results: Array[Dictionary] = []
	for i in range(asset_defs.size()):
		asset_results.append({
			"ok": false,
			"asset_index": i,
			"results": [],
			"world_results": [],
			"result_count": 0,
			"gpu_runtime_profile_contract": contract,
			"contract_blocked": true,
			"gpu_first": true,
			"cpu_fallback": false,
			"runtime_read_source": "none",
			"readback_source": "none",
		})
	return {
		"ok": false,
		"asset_results": asset_results,
		"complexity_field_out": complexity_field.duplicate(),
		"collision_field_out": collision_field.duplicate(),
		"total_placed": 0,
		"processing_order": [],
		"gpu_runtime_profile_contract": contract,
		"contract_blocked": true,
		"skipped_gpu_runtime_profile_contract": true,
		"gpu_first": true,
		"cpu_fallback": false,
		"runtime_read_source": "none",
		"readback_source": "none",
		"candidate_route_readback_source": _candidate_route_readback_source_from_settings(route_settings),
		"candidate_route_runtime_read_source": _candidate_route_runtime_read_source_from_settings(route_settings),
		"candidate_route_input_contract": _candidate_route_input_contract_from_settings(route_settings),
	}


## 当 GPU 运行时契约校验失败或设备/管线未就绪时，为 run_minimal 构造统一的"已阻断"空结果，
## 包含空的放置结果与调试通道占位数据，并原样返回输入的 complexity/collision 字段。
func _gpu_contract_blocked_minimal_output(
	complexity_data: PackedFloat32Array,
	collision_data: PackedFloat32Array,
	voxel_count: int,
	tile_count: int,
	tile_counts: Vector3i,
	candidate_voxel_sparse_ids: PackedInt32Array,
	contract: Dictionary
) -> Dictionary:
	var debug_empty := PackedFloat32Array()
	debug_empty.resize(voxel_count * NUM_DEBUG_CHANNELS)
	var full_field_readback := _full_field_readback_contract(voxel_count, "input_cpu_state_no_gpu_readback", false)
	return {
		"ok": false,
		"result_count": 0,
		"results": [],
		"tile_topk": [],
		"complexity_field_out": complexity_data,
		"collision_field_out": collision_data,
		"complexity_field_out_source": full_field_readback.get("complexity_field_out_source", ""),
		"collision_field_out_source": full_field_readback.get("collision_field_out_source", ""),
		"complexity_field_out_byte_count": full_field_readback.get("complexity_field_out_byte_count", 0),
		"collision_field_out_byte_count": full_field_readback.get("collision_field_out_byte_count", 0),
		"full_field_readback": full_field_readback,
		"stamp_deltas": [],
		"stamp_delta_readback_source": "none",
		"stamp_bounds": [],
		"stamp_bounds_source": "none",
		"debug_voxel": debug_empty,
		"debug_channel_names": DEBUG_CHANNEL_NAMES,
		"debug_channel_count": NUM_DEBUG_CHANNELS,
		"tile_count": tile_count,
		"tile_counts": tile_counts,
		"candidate_voxel_sparse_count": candidate_voxel_sparse_ids.size(),
		"candidate_voxel_sparse_ids": candidate_voxel_sparse_ids,
		"candidate_count": 0,
		"gpu_runtime_profile_contract": contract,
		"contract_blocked": true,
		"skipped_gpu_runtime_profile_contract": true,
		"gpu_first": true,
		"cpu_fallback": false,
		"runtime_read_source": "none",
		"readback_source": "none",
	}


## 当候选 tile 预筛选结果为空时，为 run_minimal 构造空结果输出，
## 跳过本次 GPU 派发，直接原样返回输入的 complexity/collision 字段。
func _empty_prefilter_output(
	complexity_data: PackedFloat32Array,
	collision_data: PackedFloat32Array,
	voxel_count: int,
	tile_count: int,
	tile_counts: Vector3i,
	candidate_voxel_sparse_ids: PackedInt32Array
) -> Dictionary:
	var debug_empty := PackedFloat32Array()
	debug_empty.resize(voxel_count * NUM_DEBUG_CHANNELS)
	var full_field_readback := _full_field_readback_contract(voxel_count, "input_cpu_state_prefilter_skip", false)
	return {
		"result_count": 0,
		"results": [],
		"tile_topk": [],
		"complexity_field_out": complexity_data,
		"collision_field_out": collision_data,
		"complexity_field_out_source": full_field_readback.get("complexity_field_out_source", ""),
		"collision_field_out_source": full_field_readback.get("collision_field_out_source", ""),
		"complexity_field_out_byte_count": full_field_readback.get("complexity_field_out_byte_count", 0),
		"collision_field_out_byte_count": full_field_readback.get("collision_field_out_byte_count", 0),
		"full_field_readback": full_field_readback,
		"stamp_deltas": [],
		"stamp_delta_readback_source": "none",
		"stamp_bounds": [],
		"stamp_bounds_source": "none",
		"debug_voxel": debug_empty,
		"debug_channel_names": DEBUG_CHANNEL_NAMES,
		"debug_channel_count": NUM_DEBUG_CHANNELS,
		"tile_count": tile_count,
		"tile_counts": tile_counts,
		"candidate_voxel_sparse_count": 0,
		"candidate_voxel_sparse_ids": candidate_voxel_sparse_ids,
		"candidate_count": 0,
		"skipped_prefilter": true,
	}


## 将 settings 字典中的可选覆盖值应用到打分/放置相关成员变量（top_k、各类惩罚权重、资产索引等），
## 并对 top_k、result_capacity 做取值范围钳制。
func _apply_settings(settings: Dictionary) -> void:
	top_k = int(settings.get("top_k", top_k))
	result_capacity = int(settings.get("result_capacity", result_capacity))
	solid_threshold = float(settings.get("solid_threshold", solid_threshold))
	collision_limit = float(settings.get("collision_limit", collision_limit))
	min_support_ratio = float(settings.get("min_support_ratio", min_support_ratio))
	clearance_limit = float(settings.get("clearance_limit", clearance_limit))
	support_weight = float(settings.get("support_weight", support_weight))
	collision_penalty = float(settings.get("collision_penalty", collision_penalty))
	overlap_penalty = float(settings.get("overlap_penalty", overlap_penalty))
	clearance_penalty = float(settings.get("clearance_penalty", clearance_penalty))
	min_distance_voxels = float(settings.get("min_distance_voxels", min_distance_voxels))
	scene_write_scale = float(settings.get("scene_write_scale", scene_write_scale))
	collision_write_scale = float(settings.get("collision_write_scale", collision_write_scale))
	asset_index = int(settings.get("asset_index", asset_index))
	rotation_index = int(settings.get("rotation_index", rotation_index))
	scale_index = int(settings.get("scale_index", scale_index))
	asset_color = Color(settings.get("asset_color", asset_color))
	top_k = clampi(top_k, 1, 8)
	result_capacity = maxi(result_capacity, 1)


## 校验 GPU 自动物体运行时与体素画像容器是否就绪、渲染设备是否一致、
## 所需 GPU 缓冲区是否齐全，构建并返回 gpu_runtime_profile_contract 校验结果。
func _validate_gpu_runtime_profile_contract(settings: Dictionary) -> Dictionary:
	var runtime_provider = _first_config_object(settings, GPU_RUNTIME_PROVIDER_CONFIG_KEYS)
	var profile_container = _first_config_object(settings, GPU_PROFILE_CONTAINER_CONFIG_KEYS)
	var require_contract := bool(settings.get("require_gpu_runtime_profile_contract", false))
	if runtime_provider == null and profile_container == null:
		if require_contract:
			return _gpu_contract_result(false, "missing_gpu_runtime_profile_contract")
		return _gpu_contract_result(true, "not_requested")
	if runtime_provider == null:
		return _gpu_contract_result(false, "missing_gpu_autoobject_runtime")
	if profile_container == null:
		return _gpu_contract_result(false, "missing_auto_voxel_runtime_profile_container")

	var runtime_ready := _object_bool(runtime_provider, "is_gpu_ready", "is_ready")
	if not runtime_ready:
		return _gpu_contract_result(false, "gpu_autoobject_runtime_not_ready", runtime_provider, profile_container)
	var profile_ready := _object_bool(profile_container, "is_runtime_ready", "is_gpu_ready")
	if not profile_ready:
		return _gpu_contract_result(false, "auto_voxel_runtime_profile_container_not_ready", runtime_provider, profile_container)

	var runtime_rd: RenderingDevice = rendering_device_of(runtime_provider)
	var profile_rd: RenderingDevice = rendering_device_of(profile_container)
	if runtime_rd == null or profile_rd == null:
		return _gpu_contract_result(false, "missing_rendering_device", runtime_provider, profile_container)
	if runtime_rd != profile_rd:
		return _gpu_contract_result(false, "rendering_device_mismatch", runtime_provider, profile_container)

	if get_rendering_device() == null:
		if not attach_rendering_device(runtime_rd, false):
			return _gpu_contract_result(false, "vpg_attach_rendering_device_failed", runtime_provider, profile_container)
	elif get_rendering_device() != runtime_rd:
		return _gpu_contract_result(false, "vpg_rendering_device_mismatch", runtime_provider, profile_container)

	var runtime_buffers := _collect_gpu_buffers(runtime_provider, REQUIRED_GPU_RUNTIME_BUFFERS)
	var missing_runtime: Array[String] = runtime_buffers.get("missing", [])
	if not missing_runtime.is_empty():
		var result := _gpu_contract_result(false, "missing_gpu_autoobject_runtime_buffers", runtime_provider, profile_container)
		result["missing_runtime_buffers"] = missing_runtime
		return result

	var profile_buffers := _collect_gpu_buffers(profile_container, REQUIRED_GPU_PROFILE_BUFFERS)
	var missing_profiles: Array[String] = profile_buffers.get("missing", [])
	if not missing_profiles.is_empty():
		var result := _gpu_contract_result(false, "missing_auto_voxel_profile_buffers", runtime_provider, profile_container)
		result["missing_profile_buffers"] = missing_profiles
		return result

	_track_borrowed_gpu_buffers(runtime_buffers.get("buffers", {}), "gpu_autoobject_runtime")
	_track_borrowed_gpu_buffers(profile_buffers.get("buffers", {}), "auto_voxel_runtime_profile_container")

	var ok := _gpu_contract_result(true, "gpu_runtime_profile_buffers_ready", runtime_provider, profile_container)
	ok["runtime_buffers"] = runtime_buffers.get("buffers", {})
	ok["profile_buffers"] = profile_buffers.get("buffers", {})
	ok["runtime_buffer_count"] = (runtime_buffers.get("buffers", {}) as Dictionary).size()
	ok["profile_buffer_count"] = (profile_buffers.get("buffers", {}) as Dictionary).size()
	return ok


## 为"同类型物体最小间距"排斥检查准备 GPU 侧的 scene_voxel_tile_object_ref 缓冲区：
## 依次校验该功能是否需要启用、SceneVoxelCommitter 是否可用、渲染设备是否匹配，
## 以及 object ref 缓冲区的容量、步幅、tile 网格尺寸与编号 schema 等元数据是否自洽且未过期，
## 校验全部通过后借用该 RID 缓冲区，返回可供 score 着色器使用的排斥上下文。
func _prepare_scene_voxel_tile_object_ref_exclusion(
	gpu_contract: Dictionary,
	settings: Dictionary,
	tile_counts: Vector3i
) -> Dictionary:
	if not _score_same_type_spacing_active(gpu_contract, settings):
		return _scene_voxel_tile_object_ref_exclusion_result(true, "not_requested")

	var committer := _first_config_object(settings, SCENE_VOXEL_TILE_COMMITTER_CONFIG_KEYS)
	if committer == null:
		return _scene_voxel_tile_object_ref_unavailable("missing_scene_voxel_committer", gpu_contract, settings)
	if not committer.has_method("get_scene_voxel_tile_gpu_buffer") \
			or not committer.has_method("get_scene_voxel_tile_gpu_buffer_summary"):
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_gpu_buffer_api_missing", gpu_contract, settings)

	var committer_rd: RenderingDevice = rendering_device_of(committer)
	if committer_rd == null or _rd == null:
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_rendering_device_missing", gpu_contract, settings)
	if committer_rd != _rd:
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_rendering_device_mismatch", gpu_contract, settings)

	var raw_summary = committer.call("get_scene_voxel_tile_gpu_buffer_summary")
	if not raw_summary is Dictionary:
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_summary_invalid", gpu_contract, settings)
	var summary: Dictionary = raw_summary
	var object_ref_buffer: RID = committer.call("get_scene_voxel_tile_gpu_buffer", SCENE_VOXEL_TILE_OBJECT_REF_BUFFER_NAME)
	if not object_ref_buffer.is_valid():
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_object_ref_rid_invalid", gpu_contract, settings)

	var buffers: Dictionary = summary.get("buffers", {})
	var object_ref_summary: Dictionary = buffers.get(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER_NAME, {})
	var refs_per_tile := int(summary.get("refs_per_tile", SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT))
	var object_ref_tile_count := int(summary.get("object_ref_tile_count", 0))
	var object_ref_capacity := int(summary.get("object_ref_capacity", 0))
	var object_ref_stride := int(object_ref_summary.get("stride_bytes", 0))
	var object_ref_record_count := int(object_ref_summary.get("record_count", 0))
	var object_ref_tile_grid: Vector3i = VoxelGeneral.vector3i_from_value(
		summary.get("object_ref_tile_grid_size", tile_counts),
		tile_counts
	)
	var object_ref_tile_size: Vector3i = VoxelGeneral.vector3i_from_value(
		summary.get("object_ref_tile_size", Vector3i(TILE_SIZE, TILE_SIZE, TILE_SIZE)),
		Vector3i(TILE_SIZE, TILE_SIZE, TILE_SIZE)
	)
	if object_ref_tile_count <= 0:
		object_ref_tile_count = object_ref_tile_grid.x * object_ref_tile_grid.y * object_ref_tile_grid.z
	if object_ref_capacity <= 0:
		object_ref_capacity = object_ref_record_count

	if not bool(summary.get("runtime_ready", false)):
		return _scene_voxel_tile_object_ref_unavailable(str(summary.get("reason", "scene_voxel_tile_not_runtime_ready")), gpu_contract, settings)
	if bool(summary.get("buffers_stale", false)) or not bool(summary.get("uploaded_revision_matches_staging", false)):
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_object_refs_stale", gpu_contract, settings)
	if bool(summary.get("object_ref_rebuild_required", false)):
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_object_refs_rebuild_required", gpu_contract, settings)
	if int(summary.get("object_ref_overflow_count", 0)) > 0 or int(summary.get("overflow_tile_count", 0)) > 0:
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_object_refs_overflow", gpu_contract, settings)
	if object_ref_stride != SCENE_VOXEL_TILE_OBJECT_REF_STRIDE_BYTES:
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_object_ref_stride_mismatch", gpu_contract, settings)
	if refs_per_tile <= 0 or object_ref_tile_count <= 0 or object_ref_capacity != object_ref_tile_count * refs_per_tile:
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_object_ref_capacity_mismatch", gpu_contract, settings)
	if object_ref_record_count > 0 and object_ref_record_count != object_ref_capacity:
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_object_ref_record_count_mismatch", gpu_contract, settings)
	if object_ref_tile_grid.x <= 0 or object_ref_tile_grid.y <= 0 or object_ref_tile_grid.z <= 0:
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_object_ref_tile_grid_invalid", gpu_contract, settings)

	var numeric_schema := str(summary.get("gpu_autoobject_ref_key_schema", summary.get("object_ref_key_schema", "")))
	var numeric_confirmed := bool(summary.get(
		"gpu_autoobject_ref_key_schema_numeric_confirmed",
		summary.get("object_ref_numeric_schema_confirmed", false)
	)) and numeric_schema == SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_NUMERIC
	if not numeric_confirmed:
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_object_ref_numeric_schema_unconfirmed", gpu_contract, settings)
	if int(summary.get("object_ref_non_numeric_count", 0)) > 0:
		return _scene_voxel_tile_object_ref_unavailable("scene_voxel_tile_object_ref_non_numeric_diagnostics", gpu_contract, settings)

	track_borrowed_rid(object_ref_buffer, KIND_BUFFER, SCOPE_FRAME, "SceneVoxelCommitter:scene_voxel_tile_object_refs")
	var result := _scene_voxel_tile_object_ref_exclusion_result(true, "ok")
	result["scene_voxel_tile_object_ref_exclusion"] = true
	result["scene_voxel_tile_object_ref_buffer"] = object_ref_buffer
	result["same_type_exclusion_read_source"] = SCENE_VOXEL_TILE_OBJECT_REF_BUFFER_NAME
	result["same_type_exclusion_object_ref_read_source"] = SCENE_VOXEL_TILE_OBJECT_REF_BUFFER_NAME
	result["object_ref_tile_count"] = object_ref_tile_count
	result["object_ref_capacity"] = object_ref_capacity
	result["refs_per_tile"] = refs_per_tile
	result["object_ref_tile_grid_size"] = object_ref_tile_grid
	result["object_ref_tile_size"] = object_ref_tile_size
	result["object_ref_stride_bytes"] = object_ref_stride
	result["object_ref_key_schema"] = numeric_schema
	result["object_ref_numeric_schema_confirmed"] = true
	result["object_ref_summary"] = summary
	result["borrowed_from"] = "SceneVoxelCommitter"
	result["rendering_device_match"] = true
	return result


## 判断本次放置是否需要启用"同类型物体间距"打分排斥：
## 要求 GPU 运行时契约已就绪，settings 未关闭该功能，且 min_distance_voxels 大于 0。
func _score_same_type_spacing_active(gpu_contract: Dictionary, settings: Dictionary) -> bool:
	if str(gpu_contract.get("reason", "")) != "gpu_runtime_profile_buffers_ready":
		return false
	if not bool(settings.get("score_runtime_profile_avoidance", true)):
		return false
	return maxf(float(settings.get("min_distance_voxels", min_distance_voxels)), 0.0) > 0.0


## 处理 scene_voxel_tile_object_ref 缓冲区不可用的情况：若允许调试用的全量扫描回退
## 且未强制要求 object ref 排斥，则返回可继续但已降级的结果，否则返回阻断结果。
func _scene_voxel_tile_object_ref_unavailable(
	reason: String,
	gpu_contract: Dictionary,
	settings: Dictionary
) -> Dictionary:
	var require_object_refs := bool(settings.get(
		"require_scene_voxel_tile_object_ref_exclusion",
		settings.get("require_same_type_exclusion_object_refs", settings.get("require_object_ref_exclusion", false))
	))
	var fallback_allowed := _runtime_spacing_full_scan_debug_fallback_allowed(gpu_contract, settings)
	if fallback_allowed and not require_object_refs:
		var fallback := _scene_voxel_tile_object_ref_exclusion_result(true, reason)
		fallback["scene_voxel_tile_object_ref_exclusion"] = false
		fallback["same_type_exclusion_read_source"] = "score_shader_storage_buffer"
		fallback["same_type_exclusion_object_ref_read_source"] = "none"
		fallback["same_type_exclusion_full_runtime_scan_debug_fallback"] = true
		fallback["same_type_exclusion_object_ref_blocked_reason"] = reason
		return fallback

	var blocked_reason := reason if require_object_refs else "%s_full_runtime_scan_debug_fallback_not_enabled" % reason
	var blocked := _scene_voxel_tile_object_ref_exclusion_result(false, blocked_reason)
	blocked["contract_blocked"] = true
	blocked["same_type_exclusion_object_ref_required"] = require_object_refs
	blocked["same_type_exclusion_full_runtime_scan_debug_fallback"] = false
	blocked["same_type_exclusion_object_ref_blocked_reason"] = reason
	return blocked


## 判断在 object ref 缓冲区不可用时，是否允许退化为调试用的全量扫描间距检测：
## 需要 settings 显式开启该调试开关，且运行时物体数量未超过配置的上限。
func _runtime_spacing_full_scan_debug_fallback_allowed(gpu_contract: Dictionary, settings: Dictionary) -> bool:
	var requested := bool(settings.get(
		"allow_runtime_spacing_full_scan_debug",
		settings.get(
			"debug_allow_runtime_spacing_full_scan",
			settings.get("allow_same_type_exclusion_full_runtime_scan_debug", false)
		)
	))
	if not requested:
		return false
	var runtime_summary: Dictionary = gpu_contract.get("runtime_summary", {})
	var max_debug_objects := int(settings.get("runtime_spacing_full_scan_debug_max_objects", 256))
	return int(runtime_summary.get("max_objects", 0)) <= maxi(max_debug_objects, 0)


## 构造 scene_voxel_tile_object_ref 排斥检查结果的默认字典模板，
## 包含 ok/reason 等状态字段以及各项缓冲区元数据的空值/默认值。
func _scene_voxel_tile_object_ref_exclusion_result(ok: bool, reason: String) -> Dictionary:
	return {
		"ok": ok,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"contract_blocked": not ok,
		"scene_voxel_tile_object_ref_exclusion": false,
		"scene_voxel_tile_object_ref_buffer": RID(),
		"same_type_exclusion_read_source": "none",
		"same_type_exclusion_object_ref_read_source": "none",
		"same_type_exclusion_full_runtime_scan_debug_fallback": false,
		"same_type_exclusion_object_ref_blocked_reason": "none",
		"object_ref_tile_count": 0,
		"object_ref_capacity": 0,
		"refs_per_tile": SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT,
		"object_ref_tile_grid_size": Vector3i.ZERO,
		"object_ref_tile_size": Vector3i(TILE_SIZE, TILE_SIZE, TILE_SIZE),
		"object_ref_stride_bytes": SCENE_VOXEL_TILE_OBJECT_REF_STRIDE_BYTES,
		"object_ref_key_schema": "none",
		"object_ref_numeric_schema_confirmed": false,
		"borrowed_from": "none",
		"rendering_device_match": false,
	}


## 将 GPU 契约字典与场景体素分片对象引用契约合并：拷贝相关字段到结果中，
## 若对象引用契约标记为被阻断，则同步阻断合并后的结果。
func _merge_scene_voxel_tile_object_ref_contract(
	gpu_contract: Dictionary,
	object_ref_contract: Dictionary
) -> Dictionary:
	var merged := _with_same_type_exclusion_defaults(gpu_contract.duplicate(true))
	merged["scene_voxel_tile_object_ref_contract"] = object_ref_contract.duplicate(true)
	for key in [
		"scene_voxel_tile_object_ref_exclusion",
		"same_type_exclusion_read_source",
		"same_type_exclusion_object_ref_read_source",
		"same_type_exclusion_full_runtime_scan_debug_fallback",
		"same_type_exclusion_object_ref_blocked_reason",
		"object_ref_tile_count",
		"object_ref_capacity",
		"refs_per_tile",
		"object_ref_tile_grid_size",
		"object_ref_tile_size",
		"object_ref_stride_bytes",
		"object_ref_key_schema",
		"object_ref_numeric_schema_confirmed",
	]:
		if object_ref_contract.has(key):
			merged[key] = object_ref_contract[key]
	if bool(object_ref_contract.get("contract_blocked", false)):
		merged["ok"] = false
		merged["contract_blocked"] = true
		merged["reason"] = str(object_ref_contract.get("reason", "scene_voxel_tile_object_ref_exclusion_blocked"))
	return merged


## 构造标准化的 GPU 契约结果字典（ok/reason/gpu_first 等字段），
## 可选附加运行时提供者与 profile 容器的调试摘要信息。
func _gpu_contract_result(
	ok: bool,
	reason: String,
	runtime_provider = null,
	profile_container = null
) -> Dictionary:
	var result := {
		"ok": ok,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"contract_blocked": not ok,
		"requires_rendering_device": reason != "not_requested",
		"runtime_read_source": "gpu_storage_buffers" if ok and reason == "gpu_runtime_profile_buffers_ready" else "none",
		"readback_source": "none",
	}
	if runtime_provider != null:
		result["runtime_summary"] = _object_summary(runtime_provider)
	if profile_container != null:
		result["profile_summary"] = _object_summary(profile_container)
	return _with_same_type_exclusion_defaults(result)


## 为结果字典补全同类型排斥（same-type exclusion）相关字段的默认值，仅填充缺失的键。
static func _with_same_type_exclusion_defaults(result: Dictionary) -> Dictionary:
	if not result.has("score_shader_same_type_min_spacing_exclusion"):
		result["score_shader_same_type_min_spacing_exclusion"] = false
	if not result.has("score_shader_same_type_min_spacing_rejections"):
		result["score_shader_same_type_min_spacing_rejections"] = 0
	if not result.has("score_shader_same_type_min_spacing_tests"):
		result["score_shader_same_type_min_spacing_tests"] = 0
	if not result.has("score_shader_same_type_min_spacing_profile_matches"):
		result["score_shader_same_type_min_spacing_profile_matches"] = 0
	if not result.has("score_shader_same_type_min_spacing_min_distance"):
		result["score_shader_same_type_min_spacing_min_distance"] = 0.0
	if not result.has("same_type_exclusion_read_source"):
		result["same_type_exclusion_read_source"] = "none"
	if not result.has("same_type_exclusion_object_ref_read_source"):
		result["same_type_exclusion_object_ref_read_source"] = "none"
	if not result.has("scene_voxel_tile_object_ref_exclusion"):
		result["scene_voxel_tile_object_ref_exclusion"] = false
	if not result.has("same_type_exclusion_full_runtime_scan_debug_fallback"):
		result["same_type_exclusion_full_runtime_scan_debug_fallback"] = false
	if not result.has("same_type_exclusion_object_ref_blocked_reason"):
		result["same_type_exclusion_object_ref_blocked_reason"] = "none"
	return result


## 按顺序在 settings 中查找 keys 列表对应的值，返回第一个类型为 Object 的值；找不到则返回 null。
func _first_config_object(settings: Dictionary, keys: Array) -> Object:
	for key in keys:
		if settings.has(key):
			var value = settings.get(key)
			if value is Object:
				return value as Object
	return null


## 调用 object 上的 primary_method（缺失则尝试 secondary_method）并返回其布尔结果；object 为空时返回 false。
func _object_bool(object: Object, primary_method: String, secondary_method: String = "") -> bool:
	if object == null:
		return false
	if object.has_method(primary_method):
		return bool(object.call(primary_method))
	if not secondary_method.is_empty() and object.has_method(secondary_method):
		return bool(object.call(secondary_method))
	return false


## 优先调用 object 的 get_gpu_buffer_summary，其次 get_debug_summary，取得其调试摘要字典的副本。
func _object_summary(object: Object) -> Dictionary:
	if object == null:
		return {}
	if object.has_method("get_gpu_buffer_summary"):
		var summary = object.call("get_gpu_buffer_summary")
		if summary is Dictionary:
			return (summary as Dictionary).duplicate(true)
	if object.has_method("get_debug_summary"):
		var debug = object.call("get_debug_summary")
		if debug is Dictionary:
			return (debug as Dictionary).duplicate(true)
	return {}


## 从 provider 按名称批量获取 GPU 缓冲区 RID，返回已获取的缓冲区字典与缺失名称列表。
func _collect_gpu_buffers(provider: Object, buffer_names: Array) -> Dictionary:
	var buffers := {}
	var missing: Array[String] = []
	if provider == null or not provider.has_method("get_gpu_buffer"):
		for raw_name in buffer_names:
			missing.append(str(raw_name))
		return {"buffers": buffers, "missing": missing}
	for raw_name in buffer_names:
		var buffer_name := str(raw_name)
		var rid: RID = provider.call("get_gpu_buffer", buffer_name)
		if not rid.is_valid():
			missing.append(buffer_name)
			continue
		buffers[buffer_name] = rid
	return {"buffers": buffers, "missing": missing}


## 将 buffers 中每个有效 RID 登记为本帧借用的 GPU 缓冲区，用于生命周期追踪。
func _track_borrowed_gpu_buffers(buffers: Dictionary, label_prefix: String) -> void:
	for buffer_name in buffers.keys():
		var rid: RID = buffers[buffer_name]
		if rid.is_valid():
			track_borrowed_rid(rid, KIND_BUFFER, SCOPE_FRAME, "%s:%s" % [label_prefix, str(buffer_name)])


## 加载各计算着色器（打分/规约/印制边界初始化/印制/目标场打包/候选路由稀疏适配器及其 finalize）并创建对应的计算管线。
func _load_shaders() -> void:
	_shader_score = load_compute_shader("res://shaders/score_voxel_tile.glsl")
	_shader_reduce = load_compute_shader("res://shaders/reduce_voxel_tiles.glsl")
	_shader_init_stamp_bounds = load_compute_shader("res://shaders/init_stamp_bounds.glsl")
	_shader_stamp = load_compute_shader("res://shaders/stamp_voxel_field.glsl")
	_shader_pack_target_field = load_compute_shader("res://shaders/pack_target_field.glsl")
	_shader_candidate_route_sparse_adapter = load_compute_shader("res://shaders/candidate_route_sparse_adapter.glsl")
	_shader_candidate_route_sparse_adapter_finalize = load_compute_shader("res://shaders/candidate_route_sparse_adapter_finalize.glsl")
	if _shader_score.is_valid():
		_pipeline_score = create_compute_pipeline(_shader_score)
	if _shader_reduce.is_valid():
		_pipeline_reduce = create_compute_pipeline(_shader_reduce)
	if _shader_init_stamp_bounds.is_valid():
		_pipeline_init_stamp_bounds = create_compute_pipeline(_shader_init_stamp_bounds)
	if _shader_stamp.is_valid():
		_pipeline_stamp = create_compute_pipeline(_shader_stamp)
	if _shader_pack_target_field.is_valid():
		_pipeline_pack_target_field = create_compute_pipeline(_shader_pack_target_field)
	if _shader_candidate_route_sparse_adapter.is_valid():
		_pipeline_candidate_route_sparse_adapter = create_compute_pipeline(_shader_candidate_route_sparse_adapter)
	if _shader_candidate_route_sparse_adapter_finalize.is_valid():
		_pipeline_candidate_route_sparse_adapter_finalize = create_compute_pipeline(_shader_candidate_route_sparse_adapter_finalize)


## 检查放置流程所需的全部着色器与计算管线是否均已有效创建，用于判断放置管线是否就绪。
func _placement_pipeline_ready() -> bool:
	return _shader_score.is_valid() \
		and _shader_reduce.is_valid() \
		and _shader_init_stamp_bounds.is_valid() \
		and _shader_stamp.is_valid() \
		and _shader_pack_target_field.is_valid() \
		and _pipeline_score.is_valid() \
		and _pipeline_reduce.is_valid() \
		and _pipeline_init_stamp_bounds.is_valid() \
		and _pipeline_stamp.is_valid() \
		and _pipeline_pack_target_field.is_valid()


## 释放本生成器持有的 GPU 资源（各计算管线与着色器 RID 全部重置），并调用 dispose 清理其余借用资源。
func _free_gpu() -> void:
	dispose()
	_pipeline_score = RID()
	_pipeline_reduce = RID()
	_pipeline_init_stamp_bounds = RID()
	_pipeline_stamp = RID()
	_pipeline_pack_target_field = RID()
	_pipeline_candidate_route_sparse_adapter = RID()
	_pipeline_candidate_route_sparse_adapter_finalize = RID()
	_shader_score = RID()
	_shader_reduce = RID()
	_shader_init_stamp_bounds = RID()
	_shader_stamp = RID()
	_shader_pack_target_field = RID()
	_shader_candidate_route_sparse_adapter = RID()
	_shader_candidate_route_sparse_adapter_finalize = RID()


## 根据资产配置中的候选体素区域（CPU 侧配置项）转换为去重后的稀疏分片 ID 列表；
## 未配置候选区域或区域非法时返回空数组并给出警告。
func _build_candidate_voxel_sparse_ids(settings: Dictionary, tile_counts: Vector3i, tile_count: int) -> PackedInt32Array:
	var ids := PackedInt32Array()
	var raw_regions: Variant = null
	for key in ASSET_CANDIDATE_REGION_CONFIG_KEYS:
		if settings.has(key):
			raw_regions = settings.get(key)
			break
	if raw_regions == null:
		return ids
	if not raw_regions is Array:
		push_warning("VoxelPlacementGenerator: candidate_voxel_regions must be an Array; skipping asset")
		return ids

	var seen := {}
	for region in raw_regions:
		var tile_id := _voxel_sparse_to_tile_id(region, tile_counts)
		if tile_id < 0 or tile_id >= tile_count or seen.has(tile_id):
			continue
		seen[tile_id] = true
		ids.append(tile_id)

	if ids.is_empty():
		push_warning("VoxelPlacementGenerator: candidate_voxel_regions produced no valid regions; skipping asset")
	return ids


## 判断 settings 是否未配置任何候选体素区域键；若是，则应采用“直接测试全部分片”模式。
func _uses_direct_all_tile_candidates(settings: Dictionary) -> bool:
	for key in ASSET_CANDIDATE_REGION_CONFIG_KEYS:
		if settings.has(key):
			return false
	return true


## 将 region（Vector3i/Vector3/整数索引）转换为按 tile_counts 展开的一维分片 ID。
static func _voxel_sparse_to_tile_id(region: Variant, tile_counts: Vector3i) -> int:
	if region is Vector3i:
		return region.x + tile_counts.x * (region.y + tile_counts.y * region.z)
	if region is Vector3:
		var v := Vector3i(int(region.x), int(region.y), int(region.z))
		return v.x + tile_counts.x * (v.y + tile_counts.y * v.z)
	return int(region)


## 将 search_radius 配置值（标量或向量）归一化为 Vector3i，并将各分量夹紧到 [0, 4] 范围内。
static func _normalize_search_radius(value: Variant) -> Vector3i:
	if value is Vector3i:
		return Vector3i(
			clampi(value.x, 0, 4),
			clampi(value.y, 0, 4),
			clampi(value.z, 0, 4)
		)
	if value is Vector3:
		return Vector3i(
			clampi(int(value.x), 0, 4),
			clampi(int(value.y), 0, 4),
			clampi(int(value.z), 0, 4)
		)
	var radius := clampi(int(value), 0, 4)
	return Vector3i(radius, radius, radius)


## 打分计算着色器的调度入口：构建 3 组 uniform set（场体缓冲区、GPU 运行时 profile 契约、候选路由绑定），
## 并填充 128 字节 push constant（网格/分片尺寸、top_k、采样范围、资产颜色、各类阈值与惩罚系数、搜索半径等）。
## 根据 _score_dispatch_indirect_decision 的判定结果，选择直接 dispatch 还是通过间接参数缓冲区 dispatch，
## 最终返回本次调度所使用的决策信息字典。
func _dispatch_score(
	complexity_buffer: RID,
	collision_buffer: RID,
	footprint_pos_buffer: RID,
	footprint_weight_buffer: RID,
	candidate_voxel_sparse_buffer: RID,
	tile_topk_buffer: RID,
	target_field_buffer: RID,
	debug_voxel_buffer: RID,
	score_contract_debug_buffer: RID,
	route_binding: Dictionary,
	candidate_route_indirect_args_buffer: RID,
	grid_size: Vector3i,
	tile_counts: Vector3i,
	tile_count: int,
	candidate_voxel_sparse_count: int,
	direct_all_tiles: bool,
	footprint_count: int,
	has_target: int,
	gpu_contract: Dictionary,
	settings: Dictionary
) -> Dictionary:
	var set0 := create_uniform_set([
		make_storage_uniform(0, complexity_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, footprint_pos_buffer),
		make_storage_uniform(3, footprint_weight_buffer),
		make_storage_uniform(4, tile_topk_buffer),
		make_storage_uniform(5, candidate_voxel_sparse_buffer),
		make_storage_uniform(6, target_field_buffer),
		make_storage_uniform(7, debug_voxel_buffer),
	], _shader_score, 0)
	var score_contract_params_buffer := storage_buffer_from_bytes(
		_pack_score_contract_params(gpu_contract, settings),
		SCOPE_FRAME,
		"score_runtime_profile_contract_params"
	)
	var set1 := _create_score_runtime_profile_set(
		gpu_contract,
		score_contract_params_buffer,
		score_contract_debug_buffer
	)
	var set2 := _create_candidate_route_binding_set(route_binding)

	var sample_min: Vector3i = settings.get("sample_min", Vector3i.ZERO)
	var sample_max: Vector3i = settings.get("sample_max", grid_size)
	var search_radius: Vector3i = _normalize_search_radius(settings.get("search_radius", Vector3i.ZERO))
	var packed_color := _pack_color_rgba8(asset_color)
	var push := PackedByteArray()
	push.resize(128)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, grid_size.z)
	push.encode_s32(12, tile_count)
	push.encode_s32(16, tile_counts.x)
	push.encode_s32(20, tile_counts.y)
	push.encode_s32(24, tile_counts.z)
	push.encode_s32(28, top_k)
	push.encode_s32(32, sample_min.x)
	push.encode_s32(36, sample_min.y)
	push.encode_s32(40, sample_min.z)
	push.encode_u32(44, packed_color)
	push.encode_s32(48, sample_max.x)
	push.encode_s32(52, sample_max.y)
	push.encode_s32(56, sample_max.z)
	push.encode_s32(60, has_target)
	push.encode_s32(64, footprint_count)
	push.encode_s32(68, asset_index)
	push.encode_s32(72, rotation_index)
	push.encode_s32(76, scale_index)
	push.encode_float(80, solid_threshold)
	push.encode_float(84, collision_limit)
	push.encode_float(88, min_support_ratio)
	push.encode_float(92, clearance_limit)
	push.encode_float(96, support_weight)
	push.encode_float(100, collision_penalty)
	push.encode_float(104, overlap_penalty)
	push.encode_float(108, clearance_penalty)
	push.encode_s32(112, -candidate_voxel_sparse_count if direct_all_tiles else candidate_voxel_sparse_count)
	push.encode_s32(116, search_radius.x)
	push.encode_s32(120, search_radius.y)
	push.encode_s32(124, search_radius.z)

	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_score)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	if set1.is_valid():
		_rd.compute_list_bind_uniform_set(cl, set1, 1)
	if set2.is_valid():
		_rd.compute_list_bind_uniform_set(cl, set2, 2)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	var dispatch_result := _score_dispatch_indirect_decision(
		candidate_route_indirect_args_buffer,
		candidate_voxel_sparse_count,
		direct_all_tiles
	)
	if bool(dispatch_result.get("score_dispatch_indirect", false)):
		_rd.compute_list_dispatch_indirect(cl, candidate_route_indirect_args_buffer, 0)
	elif candidate_voxel_sparse_count > 0:
		_rd.compute_list_dispatch(cl, candidate_voxel_sparse_count, 1, 1)
	end_compute_list()
	return dispatch_result


## 判断打分调度是否可以使用间接 dispatch（indirect dispatch），并在无法使用时给出具体的阻断原因。
func _score_dispatch_indirect_decision(
	candidate_route_indirect_args_buffer: RID,
	candidate_voxel_sparse_count: int,
	direct_all_tiles: bool
) -> Dictionary:
	var api_supported := _rd != null and _rd.has_method("compute_list_dispatch_indirect")
	if direct_all_tiles:
		return {
			"score_dispatch_indirect": false,
			"score_dispatch_indirect_block_reason": "direct_all_tiles_dispatch",
			"score_dispatch_indirect_api_supported": api_supported,
		}
	if candidate_voxel_sparse_count <= 0:
		return {
			"score_dispatch_indirect": false,
			"score_dispatch_indirect_block_reason": "zero_candidate_count_indirect_dispatch_gated",
			"score_dispatch_indirect_api_supported": api_supported,
		}
	if not candidate_route_indirect_args_buffer.is_valid():
		return {
			"score_dispatch_indirect": false,
			"score_dispatch_indirect_block_reason": "missing_route_adapter_indirect_args_buffer",
			"score_dispatch_indirect_api_supported": api_supported,
		}
	if not api_supported:
		return {
			"score_dispatch_indirect": false,
			"score_dispatch_indirect_block_reason": "rendering_device_dispatch_indirect_api_unavailable",
			"score_dispatch_indirect_api_supported": false,
		}
	return {
		"score_dispatch_indirect": true,
		"score_dispatch_indirect_block_reason": "none",
		"score_dispatch_indirect_api_supported": true,
	}


## 校验常驻路由 GPU 稀疏适配器所需的前置条件（管线/着色器就绪、分片计数、路由缓冲区与容量等），
## 并预构建结果契约（占位候选 ID 数组与容量信息），整个过程不进行任何 CPU 回读。
func _prepare_candidate_sparse_ids_from_resident_route_gpu(route_binding: Dictionary, tile_count: int) -> Dictionary:
	if not bool(route_binding.get("bindable", false)):
		return {"ok": false, "reason": "route_binding_not_bindable"}
	if not _pipeline_candidate_route_sparse_adapter.is_valid() or not _shader_candidate_route_sparse_adapter.is_valid():
		return {"ok": false, "reason": "candidate_route_sparse_adapter_shader_not_ready"}
	if not _pipeline_candidate_route_sparse_adapter_finalize.is_valid() or not _shader_candidate_route_sparse_adapter_finalize.is_valid():
		return {"ok": false, "reason": "candidate_route_sparse_adapter_finalize_shader_not_ready"}
	if tile_count <= 0:
		return {"ok": false, "reason": "tile_count_not_positive"}
	var range_buffer: RID = route_binding.get("range_buffer", RID())
	var record_buffer: RID = route_binding.get("record_buffer", RID())
	var range_count := int(route_binding.get("range_count", 0))
	var record_capacity := int(route_binding.get("record_capacity", 0))
	if not range_buffer.is_valid() or not record_buffer.is_valid() or range_count <= 0:
		return {"ok": false, "reason": "missing_resident_route_buffers"}
	if record_capacity <= 0:
		return {"ok": false, "reason": "resident_route_record_capacity_missing"}
	var range_index := clampi(asset_index, 0, range_count - 1)
	var output_capacity := mini(record_capacity, tile_count)

	var ids := PackedInt32Array()
	ids.resize(output_capacity)
	ids.fill(tile_count)
	return {
		"ok": true,
		"reason": "ok",
		"candidate_voxel_sparse_ids": ids,
		"range_index": range_index,
		"range_start": 0,
		"range_count": 0,
		"record_reads": 0,
		"candidate_count": output_capacity,
		"source": "resident_route_gpu_sparse_adapter",
		"adapter_mode": "gpu_compute_copy_filter",
		"output_capacity": output_capacity,
		"resident_route_record_capacity": record_capacity,
		"candidate_count_source": "route_adapter_indirect_args_buffer",
		"candidate_count_semantics": "gpu_owned_runtime_count",
		"candidate_count_cpu_readback_required": false,
		"indirect_args_ready": true,
		"indirect_args_layout": "u32x3_group_count_xyz",
		"indirect_args_words": PackedInt32Array(),
		"indirect_args_source": "route_adapter_indirect_args_buffer",
		"debug_snapshot_enabled": false,
		"debug_snapshot_status": "disabled",
		"debug_count_snapshot_source": "disabled",
		"debug_sparse_ids_snapshot_source": "disabled",
		"debug_indirect_args_snapshot_source": "disabled",
	}


## 调度候选路由稀疏适配器计算通道：先展开常驻路由的 record/range 缓冲区，生成稀疏分片 ID 与计数，
## 再执行 finalize 通道生成间接 dispatch 参数；整个过程完全在 GPU 上完成，不做 CPU 回读。
func _dispatch_candidate_route_sparse_adapter(
	route_binding: Dictionary,
	candidate_voxel_sparse_buffer: RID,
	candidate_route_adapter_count_buffer: RID,
	candidate_route_indirect_args_buffer: RID,
	tile_count: int,
	output_capacity: int
) -> void:
	if not _pipeline_candidate_route_sparse_adapter.is_valid() or not _shader_candidate_route_sparse_adapter.is_valid():
		return
	if not _pipeline_candidate_route_sparse_adapter_finalize.is_valid() or not _shader_candidate_route_sparse_adapter_finalize.is_valid():
		return
	var record_buffer: RID = route_binding.get("record_buffer", RID())
	var range_buffer: RID = route_binding.get("range_buffer", RID())
	var debug_buffer: RID = route_binding.get("debug_buffer", RID())
	if not record_buffer.is_valid() or not range_buffer.is_valid() \
	   or not candidate_voxel_sparse_buffer.is_valid() or not debug_buffer.is_valid() \
	   or not candidate_route_adapter_count_buffer.is_valid() or not candidate_route_indirect_args_buffer.is_valid():
		return
	var set0 := create_uniform_set([
		make_storage_uniform(0, record_buffer),
		make_storage_uniform(1, range_buffer),
		make_storage_uniform(2, candidate_voxel_sparse_buffer),
		make_storage_uniform(3, debug_buffer),
		make_storage_uniform(4, candidate_route_adapter_count_buffer),
	], _shader_candidate_route_sparse_adapter, 0, SCOPE_PASS, "candidate_route_sparse_adapter")
	var finalize_set0 := create_uniform_set([
		make_storage_uniform(0, candidate_route_adapter_count_buffer),
		make_storage_uniform(1, candidate_route_indirect_args_buffer),
	], _shader_candidate_route_sparse_adapter_finalize, 0, SCOPE_PASS, "candidate_route_sparse_adapter_finalize")

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, asset_index)
	push.encode_s32(4, int(route_binding.get("range_count", 0)))
	push.encode_s32(8, tile_count)
	push.encode_s32(12, output_capacity)
	push.encode_s32(16, int(route_binding.get("record_capacity", 0)))

	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_candidate_route_sparse_adapter)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, ceil_div(output_capacity, CANDIDATE_ROUTE_SPARSE_ADAPTER_LOCAL_SIZE), 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_candidate_route_sparse_adapter_finalize)
	_rd.compute_list_bind_uniform_set(cl, finalize_set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	_rd.compute_list_add_barrier(cl)
	end_compute_list()


## 将候选路由稀疏适配器的调度结果汇总为契约字典（候选数量、range/record 读取信息、间接参数状态等）。
## 当 read_debug_snapshot 为 true 时，才会从 GPU 回读计数缓冲区、间接参数缓冲区与稀疏 ID 缓冲区生成调试快照；
## 默认（非调试）情况下不进行任何 CPU 回读，候选数量在语义上完全由 GPU 端间接参数缓冲区持有。
func _read_candidate_route_sparse_adapter_result(
	candidate_voxel_sparse_buffer: RID,
	candidate_route_adapter_count_buffer: RID,
	candidate_route_indirect_args_buffer: RID,
	route_binding_debug: Dictionary,
	tile_count: int,
	output_capacity: int,
	score_dispatch: Dictionary = {},
	read_debug_snapshot: bool = false
) -> Dictionary:
	var ids := PackedInt32Array()
	if read_debug_snapshot:
		ids.resize(output_capacity)
		ids.fill(tile_count)
	var count_words := PackedInt32Array()
	count_words.resize(CANDIDATE_ROUTE_ADAPTER_COUNT_WORDS)
	var debug_count_snapshot_source := "disabled"
	var debug_sparse_ids_snapshot_source := "disabled"
	var debug_indirect_args_snapshot_source := "disabled"
	if read_debug_snapshot and candidate_route_adapter_count_buffer.is_valid():
		var count_bytes := _rd.buffer_get_data(
			candidate_route_adapter_count_buffer,
			0,
			CANDIDATE_ROUTE_ADAPTER_COUNT_WORDS * 4
		)
		var count_available := mini(int(count_bytes.size() / 4), CANDIDATE_ROUTE_ADAPTER_COUNT_WORDS)
		for i in range(count_available):
			count_words[i] = int(count_bytes.decode_u32(i * 4))
		debug_count_snapshot_source = "route_adapter_count_buffer_debug_readback"
	var indirect_words := PackedInt32Array()
	if read_debug_snapshot and candidate_route_indirect_args_buffer.is_valid():
		indirect_words.resize(3)
		var indirect_bytes := _rd.buffer_get_data(
			candidate_route_indirect_args_buffer,
			0,
			CANDIDATE_ROUTE_INDIRECT_ARGS_BYTES
		)
		var indirect_available := mini(int(indirect_bytes.size() / 4), 3)
		for i in range(indirect_available):
			indirect_words[i] = int(indirect_bytes.decode_u32(i * 4))
		debug_indirect_args_snapshot_source = "route_adapter_indirect_args_debug_readback"
	var debug_requested_count := clampi(int(count_words[0]), 0, output_capacity) if read_debug_snapshot else 0
	var debug_ids := PackedInt32Array()
	if read_debug_snapshot and candidate_voxel_sparse_buffer.is_valid() and debug_requested_count > 0:
		var bytes := _rd.buffer_get_data(candidate_voxel_sparse_buffer, 0, output_capacity * 4)
		var available := mini(int(bytes.size() / 4), output_capacity)
		for i in range(available):
			var tile_id := int(bytes.decode_u32(i * 4))
			if tile_id >= 0 and tile_id < tile_count:
				debug_ids.append(tile_id)
				if debug_ids.size() >= debug_requested_count:
					break
		if not debug_ids.is_empty():
			ids = debug_ids
		debug_sparse_ids_snapshot_source = "candidate_voxel_sparse_ids_debug_readback"
	return {
		"ok": output_capacity > 0,
		"reason": "ok" if output_capacity > 0 else "resident_route_gpu_sparse_adapter_no_output_capacity",
		"candidate_voxel_sparse_ids": ids,
		"range_index": int(route_binding_debug.get("sparse_adapter_range_index", clampi(asset_index, 0, maxi(int(route_binding_debug.get("range_count", 1)) - 1, 0)))),
		"range_start": int(route_binding_debug.get("sparse_adapter_range_start", route_binding_debug.get("first_range_start", 0))),
		"range_count": int(route_binding_debug.get("sparse_adapter_range_count", route_binding_debug.get("first_range_count", 0))),
		"record_reads": int(route_binding_debug.get("sparse_adapter_record_reads", route_binding_debug.get("record_reads", 0))),
		"candidate_count": output_capacity,
		"source": "resident_route_gpu_sparse_adapter",
		"adapter_mode": "gpu_compute_copy_filter",
		"output_capacity": output_capacity,
		"resident_route_record_capacity": int(route_binding_debug.get("sparse_adapter_record_capacity", 0)),
		"candidate_count_source": "route_adapter_indirect_args_buffer",
		"candidate_count_semantics": "gpu_owned_runtime_count",
		"candidate_count_cpu_readback_required": false,
		"count_words": count_words,
		"count_record_reads": int(count_words[1]) if read_debug_snapshot else int(route_binding_debug.get("sparse_adapter_range_count", 0)),
		"count_truncation_or_overflow": int(count_words[2]) if read_debug_snapshot else 0,
		"count_magic": int(count_words[3]) if read_debug_snapshot else 0,
		"indirect_args_words": indirect_words,
		"indirect_args_ready": candidate_route_indirect_args_buffer.is_valid(),
		"indirect_args_layout": "u32x3_group_count_xyz",
		"indirect_args_source": "route_adapter_indirect_args_buffer",
		"debug_snapshot_enabled": read_debug_snapshot,
		"debug_snapshot_status": "available" if read_debug_snapshot else "disabled",
		"debug_count_snapshot": int(count_words[0]) if read_debug_snapshot else -1,
		"debug_count_snapshot_source": debug_count_snapshot_source,
		"debug_sparse_ids_snapshot": debug_ids,
		"debug_sparse_ids_snapshot_source": debug_sparse_ids_snapshot_source,
		"debug_indirect_args_snapshot_source": debug_indirect_args_snapshot_source,
		"score_dispatch_indirect": bool(score_dispatch.get("score_dispatch_indirect", false)),
		"score_dispatch_indirect_block_reason": str(score_dispatch.get("score_dispatch_indirect_block_reason", "none")),
		"score_dispatch_indirect_api_supported": bool(score_dispatch.get("score_dispatch_indirect_api_supported", false)),
	}


## 将常驻路由稀疏适配器的运行结果写入 candidate_route_input_contract 契约，标记适配器已就绪（未被阻断）。
func _mark_candidate_route_sparse_adapter_ready(route_settings: Dictionary, resident_route_sparse: Dictionary) -> void:
	var raw_contract = route_settings.get("candidate_route_input_contract", {})
	if not raw_contract is Dictionary:
		return
	var contract := raw_contract as Dictionary
	if contract.is_empty():
		return
	contract["direct_all_tiles"] = false
	contract["cpu_expanded_route_input"] = false
	contract["resident_route_sparse_adapter"] = true
	contract["resident_route_sparse_adapter_source"] = str(resident_route_sparse.get("source", "resident_route_gpu_sparse_adapter"))
	contract["resident_route_sparse_adapter_mode"] = str(resident_route_sparse.get("adapter_mode", "gpu_compute_copy_filter"))
	contract["resident_route_sparse_adapter_range_index"] = int(resident_route_sparse.get("range_index", 0))
	contract["resident_route_sparse_adapter_range_start"] = int(resident_route_sparse.get("range_start", 0))
	contract["resident_route_sparse_adapter_range_count"] = int(resident_route_sparse.get("range_count", 0))
	contract["resident_route_sparse_adapter_record_reads"] = int(resident_route_sparse.get("record_reads", 0))
	contract["resident_route_sparse_adapter_candidate_count"] = int(resident_route_sparse.get("candidate_count", 0))
	contract["resident_route_sparse_adapter_candidate_count_source"] = str(resident_route_sparse.get("candidate_count_source", "none"))
	contract["resident_route_sparse_adapter_candidate_count_semantics"] = str(resident_route_sparse.get("candidate_count_semantics", "none"))
	contract["resident_route_sparse_adapter_candidate_count_cpu_readback_required"] = bool(resident_route_sparse.get("candidate_count_cpu_readback_required", false))
	contract["resident_route_sparse_adapter_output_capacity"] = int(resident_route_sparse.get("output_capacity", 0))
	contract["resident_route_sparse_adapter_count_record_reads"] = int(resident_route_sparse.get("count_record_reads", 0))
	contract["resident_route_sparse_adapter_count_truncation_or_overflow"] = int(resident_route_sparse.get("count_truncation_or_overflow", 0))
	contract["resident_route_sparse_adapter_count_magic"] = int(resident_route_sparse.get("count_magic", 0))
	contract["resident_route_sparse_adapter_indirect_args_ready"] = bool(resident_route_sparse.get("indirect_args_ready", false))
	contract["resident_route_sparse_adapter_indirect_args_layout"] = str(resident_route_sparse.get("indirect_args_layout", "none"))
	contract["resident_route_sparse_adapter_indirect_args_words"] = resident_route_sparse.get("indirect_args_words", PackedInt32Array())
	contract["resident_route_sparse_adapter_indirect_args_source"] = str(resident_route_sparse.get("indirect_args_source", "none"))
	contract["resident_route_sparse_adapter_debug_snapshot_enabled"] = bool(resident_route_sparse.get("debug_snapshot_enabled", false))
	contract["resident_route_sparse_adapter_debug_snapshot_status"] = str(resident_route_sparse.get("debug_snapshot_status", "disabled"))
	contract["resident_route_sparse_adapter_debug_count_snapshot"] = int(resident_route_sparse.get("debug_count_snapshot", -1))
	contract["resident_route_sparse_adapter_debug_count_snapshot_source"] = str(resident_route_sparse.get("debug_count_snapshot_source", "disabled"))
	contract["resident_route_sparse_adapter_debug_sparse_ids_snapshot"] = resident_route_sparse.get("debug_sparse_ids_snapshot", PackedInt32Array())
	contract["resident_route_sparse_adapter_debug_sparse_ids_snapshot_source"] = str(resident_route_sparse.get("debug_sparse_ids_snapshot_source", "disabled"))
	contract["resident_route_sparse_adapter_debug_indirect_args_snapshot_source"] = str(resident_route_sparse.get("debug_indirect_args_snapshot_source", "disabled"))
	contract["resident_route_sparse_adapter_score_dispatch_indirect"] = bool(resident_route_sparse.get("score_dispatch_indirect", false))
	contract["resident_route_sparse_adapter_score_dispatch_indirect_block_reason"] = str(resident_route_sparse.get("score_dispatch_indirect_block_reason", "none"))
	contract["resident_route_sparse_adapter_score_dispatch_indirect_api_supported"] = bool(resident_route_sparse.get("score_dispatch_indirect_api_supported", false))
	contract["resident_route_sparse_adapter_block_reason"] = "none"
	route_settings["candidate_route_input_contract"] = contract
	route_settings["resident_candidate_route_contract"] = contract


## 将 candidate_route_input_contract 契约标记为适配器被阻断：把相关字段重置为默认值/false，并记录阻断原因。
func _mark_candidate_route_sparse_adapter_blocked(route_settings: Dictionary, reason: String) -> void:
	var raw_contract = route_settings.get("candidate_route_input_contract", {})
	if not raw_contract is Dictionary:
		return
	var contract := raw_contract as Dictionary
	if contract.is_empty():
		return
	contract["direct_all_tiles"] = false
	contract["resident_route_sparse_adapter"] = false
	contract["resident_route_sparse_adapter_block_reason"] = reason
	contract["resident_route_sparse_adapter_output_capacity"] = 0
	contract["resident_route_sparse_adapter_candidate_count"] = 0
	contract["resident_route_sparse_adapter_candidate_count_source"] = "none"
	contract["resident_route_sparse_adapter_candidate_count_semantics"] = "none"
	contract["resident_route_sparse_adapter_candidate_count_cpu_readback_required"] = false
	contract["resident_route_sparse_adapter_indirect_args_ready"] = false
	contract["resident_route_sparse_adapter_indirect_args_layout"] = "none"
	contract["resident_route_sparse_adapter_indirect_args_source"] = "none"
	contract["resident_route_sparse_adapter_debug_snapshot_enabled"] = false
	contract["resident_route_sparse_adapter_debug_snapshot_status"] = "disabled"
	contract["resident_route_sparse_adapter_debug_count_snapshot_source"] = "disabled"
	contract["resident_route_sparse_adapter_debug_sparse_ids_snapshot_source"] = "disabled"
	contract["resident_route_sparse_adapter_debug_indirect_args_snapshot_source"] = "disabled"
	contract["resident_route_sparse_adapter_score_dispatch_indirect"] = false
	contract["resident_route_sparse_adapter_score_dispatch_indirect_block_reason"] = reason
	route_settings["candidate_route_input_contract"] = contract
	route_settings["resident_candidate_route_contract"] = contract


## 准备候选体素路由（candidate route）的 GPU 绑定信息。
## 校验常驻路由契约中的 RID、步幅、schema 版本、渲染设备等是否满足直接绑定条件，
## 判定该路由能否在 GPU 端直接绑定（bindable）而无需 CPU 回读，并给出不可绑定时的原因，
## 同时生成调试缓冲区、更新 settings 中的契约字段，最终返回绑定结果字典。
func _prepare_candidate_route_binding(settings: Dictionary, direct_all_tiles: bool) -> Dictionary:
	var route_settings := settings.duplicate(true)
	var raw_contract = route_settings.get("candidate_route_input_contract", {})
	var resident_contract := (raw_contract as Dictionary).duplicate(true) if raw_contract is Dictionary else {}
	if route_settings.get("resident_candidate_route_contract", null) is Dictionary:
		resident_contract = (route_settings.get("resident_candidate_route_contract") as Dictionary).duplicate(true)
	var has_resident_contract := not resident_contract.is_empty()

	var record_rid: RID = _rid_from_contract(resident_contract, "resident_route_record_rid", "resident_route_record_buffer_rid")
	var range_rid: RID = _rid_from_contract(resident_contract, "resident_route_range_rid", "resident_route_range_buffer_rid")
	var record_stride := int(resident_contract.get("resident_route_record_stride", resident_contract.get("resident_route_record_stride_bytes", 0)))
	var range_stride := int(resident_contract.get("resident_route_range_stride", resident_contract.get("resident_route_range_stride_bytes", 0)))
	var range_count := int(resident_contract.get("resident_route_range_count", 0))
	var record_capacity := int(resident_contract.get("resident_route_record_capacity", resident_contract.get("resident_route_record_count", 0)))
	var schema_version := int(resident_contract.get("schema_version", resident_contract.get("resident_route_schema_version", 0)))
	var requested_readback := str(route_settings.get("candidate_route_readback_source", "none"))
	var requested_runtime := str(route_settings.get("candidate_route_runtime_read_source", "none"))
	var requested_resident_label := requested_readback != "none" or requested_runtime != "none"
	var cpu_route_dictionary := _has_candidate_regions_by_asset(route_settings)
	var cpu_expanded_route_input := _has_asset_candidate_regions(route_settings)
	var rd_matches_vpg := bool(resident_contract.get("same_rendering_device_as_vpg", resident_contract.get("rendering_device_matches_vpg", false)))
	var bindable := requested_resident_label \
		and has_resident_contract \
		and not cpu_route_dictionary \
		and record_rid.is_valid() \
		and range_rid.is_valid() \
		and rd_matches_vpg \
		and record_stride == CANDIDATE_ROUTE_RECORD_STRIDE_BYTES \
		and range_stride == CANDIDATE_ROUTE_RANGE_STRIDE_BYTES \
		and range_count > 0 \
		and schema_version == CANDIDATE_ROUTE_CONTRACT_SCHEMA_VERSION
	var bindable_block_reason := "none"
	if not bindable:
		if not requested_resident_label:
			bindable_block_reason = "resident_route_not_requested"
		elif not has_resident_contract:
			bindable_block_reason = "missing_resident_route_contract"
		elif cpu_route_dictionary:
			bindable_block_reason = "cpu_route_dictionary_present"
		elif cpu_expanded_route_input:
			bindable_block_reason = "asset_cpu_route_present"
		elif not record_rid.is_valid():
			bindable_block_reason = "missing_or_invalid_route_record_rid"
		elif not range_rid.is_valid():
			bindable_block_reason = "missing_or_invalid_route_range_rid"
		elif not rd_matches_vpg:
			bindable_block_reason = "rendering_device_mismatch_or_unverified"
		elif record_stride != CANDIDATE_ROUTE_RECORD_STRIDE_BYTES:
			bindable_block_reason = "route_record_stride_mismatch"
		elif range_stride != CANDIDATE_ROUTE_RANGE_STRIDE_BYTES:
			bindable_block_reason = "route_range_stride_mismatch"
		elif range_count <= 0:
			bindable_block_reason = "route_range_count_not_positive"
		elif schema_version != CANDIDATE_ROUTE_CONTRACT_SCHEMA_VERSION:
			bindable_block_reason = "route_schema_version_mismatch"
		else:
			bindable_block_reason = "unknown_route_binding_block"

	if bindable:
		track_borrowed_rid(record_rid, KIND_BUFFER, SCOPE_FRAME, "candidate_route_records")
		track_borrowed_rid(range_rid, KIND_BUFFER, SCOPE_FRAME, "candidate_route_ranges")

	var debug_bytes := PackedByteArray()
	debug_bytes.resize(CANDIDATE_ROUTE_BINDING_DEBUG_WORDS * 4)
	debug_bytes.encode_u32(0, 1 if bindable else 0)
	debug_bytes.encode_u32(4, maxi(range_count, 0) if bindable else 0)
	var debug_buffer := storage_buffer_from_bytes(debug_bytes, SCOPE_FRAME, "candidate_route_binding_debug")

	if has_resident_contract:
		resident_contract["vpg_binds_route_buffers"] = bindable
		resident_contract["vpg_route_buffer_binding_source"] = "score_shader_set2_uniform_set" if bindable else "none"
		resident_contract["vpg_route_buffer_binding_debug_source"] = "score_shader_candidate_route_binding_debug" if bindable else "none"
		resident_contract["vpg_route_buffer_binding_block_reason"] = bindable_block_reason
		resident_contract["cpu_expanded_route_input"] = bool(resident_contract.get("cpu_expanded_route_input", false)) or cpu_route_dictionary or cpu_expanded_route_input
		resident_contract["direct_all_tiles"] = bool(resident_contract.get("direct_all_tiles", false)) or direct_all_tiles
		route_settings["candidate_route_input_contract"] = resident_contract
		route_settings["resident_candidate_route_contract"] = resident_contract

	return {
		"settings": route_settings,
		"record_buffer": record_rid if bindable else RID(),
		"range_buffer": range_rid if bindable else RID(),
		"debug_buffer": debug_buffer,
		"bindable": bindable,
		"range_count": range_count if bindable else 0,
		"record_capacity": record_capacity if bindable else 0,
	}


## 根据路由绑定信息创建候选路由的 uniform set，供 score 着色器绑定使用。
## 当 record/range 缓冲区无效时，使用占位（dummy）缓冲区填充对应槽位。
func _create_candidate_route_binding_set(route_binding: Dictionary) -> RID:
	var debug_buffer: RID = route_binding.get("debug_buffer", RID())
	if not debug_buffer.is_valid():
		return RID()
	var dummy_buffer := storage_buffer_zero(16, SCOPE_PASS, "candidate_route_binding_dummy")
	var record_buffer: RID = route_binding.get("record_buffer", RID())
	var range_buffer: RID = route_binding.get("range_buffer", RID())
	if not record_buffer.is_valid():
		record_buffer = dummy_buffer
	if not range_buffer.is_valid():
		range_buffer = dummy_buffer
	return create_uniform_set([
		make_storage_uniform(0, record_buffer),
		make_storage_uniform(1, range_buffer),
		make_storage_uniform(2, debug_buffer),
	], _shader_score, 2, SCOPE_PASS, "candidate_route_binding")


## 读取候选路由绑定的调试缓冲区数据，解析为带命名字段的调试信息字典。
## 若未启用调试快照或调试缓冲区无效，则返回不读取任何数据的默认结果。
func _read_candidate_route_binding_debug(route_binding: Dictionary, read_debug_snapshot: bool = false) -> Dictionary:
	var debug_buffer: RID = route_binding.get("debug_buffer", RID())
	var words := PackedInt32Array()
	words.resize(CANDIDATE_ROUTE_BINDING_DEBUG_WORDS)
	if not read_debug_snapshot or not debug_buffer.is_valid():
		return {
			"read_source": "disabled" if not read_debug_snapshot else "none",
			"word_count": CANDIDATE_ROUTE_BINDING_DEBUG_WORDS,
			"words": words,
			"enabled": false,
			"range_count": int(route_binding.get("range_count", 0)),
			"range_reads": 0,
			"record_reads": 0,
			"sparse_adapter_output_capacity": int(route_binding.get("record_capacity", 0)),
			"sparse_adapter_record_capacity": int(route_binding.get("record_capacity", 0)),
		}
	var bytes := _rd.buffer_get_data(debug_buffer, 0, CANDIDATE_ROUTE_BINDING_DEBUG_WORDS * 4)
	var available := mini(int(bytes.size() / 4), CANDIDATE_ROUTE_BINDING_DEBUG_WORDS)
	for i in range(available):
		words[i] = bytes.decode_s32(i * 4)
	return {
		"read_source": "score_shader_candidate_route_binding_debug",
		"word_count": CANDIDATE_ROUTE_BINDING_DEBUG_WORDS,
		"words": words,
		"enabled": int(words[0]) != 0,
		"range_count": int(words[1]),
		"range_reads": int(words[2]),
		"record_reads": int(words[3]),
		"first_range_start": int(words[4]),
		"first_range_count": int(words[5]),
		"first_record_x": int(words[6]),
		"first_record_y": int(words[7]),
		"sparse_adapter_candidate_count": int(words[8]) if words.size() > 8 else 0,
		"sparse_adapter_record_reads": int(words[9]) if words.size() > 9 else 0,
		"sparse_adapter_range_index": int(words[10]) if words.size() > 10 else 0,
		"sparse_adapter_output_capacity": int(words[11]) if words.size() > 11 else 0,
		"sparse_adapter_range_start": int(words[12]) if words.size() > 12 else 0,
		"sparse_adapter_range_count": int(words[13]) if words.size() > 13 else 0,
		"sparse_adapter_record_capacity": int(words[14]) if words.size() > 14 else 0,
	}


## 将候选路由绑定的调试计数信息合并写回 settings 中的候选路由契约字典。
func _merge_candidate_route_binding_debug_into_settings(route_settings: Dictionary, route_binding_debug: Dictionary) -> void:
	var raw_contract = route_settings.get("candidate_route_input_contract", {})
	if not raw_contract is Dictionary:
		return
	var contract := raw_contract as Dictionary
	if contract.is_empty():
		return
	contract["vpg_route_buffer_binding_range_reads"] = int(route_binding_debug.get("range_reads", 0))
	contract["vpg_route_buffer_binding_record_reads"] = int(route_binding_debug.get("record_reads", 0))
	contract["vpg_route_buffer_binding_debug_enabled"] = bool(route_binding_debug.get("enabled", false))
	if int(route_binding_debug.get("sparse_adapter_output_capacity", 0)) > 0:
		contract["resident_route_sparse_adapter_record_reads"] = int(route_binding_debug.get("sparse_adapter_record_reads", 0))
		contract["resident_route_sparse_adapter_output_capacity"] = int(route_binding_debug.get("sparse_adapter_output_capacity", 0))
		contract["resident_route_sparse_adapter_range_start"] = int(route_binding_debug.get("sparse_adapter_range_start", 0))
		contract["resident_route_sparse_adapter_range_count"] = int(route_binding_debug.get("sparse_adapter_range_count", 0))
	route_settings["candidate_route_input_contract"] = contract
	route_settings["resident_candidate_route_contract"] = contract


## 根据 GPU 运行时/画像（profile）契约创建 score 着色器的运行时数据 uniform set。
## 汇总运行时对象缓冲区（alive/generation/type/profile/bounds）、画像表、
## 探针/枢轴记录及场景体素瓦片对象引用缓冲区等，对缺失或无效的 RID
## 统一回退为占位缓冲区，避免绑定失败。
func _create_score_runtime_profile_set(
	gpu_contract: Dictionary,
	score_contract_params_buffer: RID,
	score_contract_debug_buffer: RID
) -> RID:
	var runtime_buffers: Dictionary = gpu_contract.get("runtime_buffers", {})
	var profile_buffers: Dictionary = gpu_contract.get("profile_buffers", {})
	if not score_contract_params_buffer.is_valid() or not score_contract_debug_buffer.is_valid():
		return RID()
	var dummy_buffer := storage_buffer_zero(64, SCOPE_PASS, "score_runtime_profile_contract_dummy")
	var alive_buffer: RID = _gpu_buffer_or_dummy(runtime_buffers, "alive", dummy_buffer)
	var generation_buffer: RID = _gpu_buffer_or_dummy(runtime_buffers, "generation", dummy_buffer)
	var type_buffer: RID = _gpu_buffer_or_dummy(runtime_buffers, "type", dummy_buffer)
	var profile_buffer: RID = _gpu_buffer_or_dummy(runtime_buffers, "profile", dummy_buffer)
	var bounds_min_buffer: RID = _gpu_buffer_or_dummy(runtime_buffers, "bounds_min", dummy_buffer)
	var bounds_max_buffer: RID = _gpu_buffer_or_dummy(runtime_buffers, "bounds_max", dummy_buffer)
	var profile_table_buffer: RID = _gpu_buffer_or_dummy(profile_buffers, "profile_table", dummy_buffer)
	var probe_records_buffer: RID = _gpu_buffer_or_dummy(profile_buffers, "probe_records", dummy_buffer)
	var pivot_records_buffer: RID = _gpu_buffer_or_dummy(profile_buffers, "pivot_records", dummy_buffer)
	var object_ref_contract: Dictionary = gpu_contract.get("scene_voxel_tile_object_ref_contract", {})
	var object_ref_buffer: RID = object_ref_contract.get("scene_voxel_tile_object_ref_buffer", RID())
	if not object_ref_buffer.is_valid():
		object_ref_buffer = dummy_buffer
	return create_uniform_set([
		make_storage_uniform(0, alive_buffer),
		make_storage_uniform(1, generation_buffer),
		make_storage_uniform(2, type_buffer),
		make_storage_uniform(3, profile_buffer),
		make_storage_uniform(4, bounds_min_buffer),
		make_storage_uniform(5, bounds_max_buffer),
		make_storage_uniform(6, profile_table_buffer),
		make_storage_uniform(7, score_contract_params_buffer),
		make_storage_uniform(8, score_contract_debug_buffer),
		make_storage_uniform(9, probe_records_buffer),
		make_storage_uniform(11, pivot_records_buffer),
		make_storage_uniform(12, object_ref_buffer),
	], _shader_score, 1, SCOPE_PASS, "score_runtime_profile_contract")


## 从缓冲区字典中按名称取出 RID，若不存在或无效则返回占位（dummy）缓冲区。
func _gpu_buffer_or_dummy(buffers: Dictionary, buffer_name: String, dummy_buffer: RID) -> RID:
	var value = buffers.get(buffer_name, RID())
	if value is RID:
		var rid: RID = value
		if rid.is_valid():
			return rid
	return dummy_buffer


## 将 score 运行时契约（gpu_contract）与 settings 中的相关参数打包为
## 供 GPU 着色器读取的字节缓冲区（score contract params buffer）。
## 内容包括运行时容量、画像数量、资产画像 ID、探针/枢轴记录数、
## 最小间距，以及场景体素瓦片对象引用相关参数，按固定偏移量依次
## 写入 112 字节的缓冲区布局。
func _pack_score_contract_params(gpu_contract: Dictionary, settings: Dictionary) -> PackedByteArray:
	var runtime_summary: Dictionary = gpu_contract.get("runtime_summary", {})
	var profile_summary: Dictionary = gpu_contract.get("profile_summary", {})
	var runtime_buffers: Dictionary = runtime_summary.get("buffers", {})
	var profile_buffers: Dictionary = profile_summary.get("buffers", {})
	var contract_enabled := bool(gpu_contract.get("ok", false)) \
		and str(gpu_contract.get("reason", "")) == "gpu_runtime_profile_buffers_ready"
	var runtime_capacity := int(runtime_summary.get("max_objects", 0))
	if runtime_capacity <= 0 and runtime_buffers.has("alive"):
		runtime_capacity = int((runtime_buffers["alive"] as Dictionary).get("record_count", 0))
	var profile_count := int(profile_summary.get("staging_profile_count", 0))
	if profile_count <= 0 and profile_buffers.has("profile_table"):
		profile_count = int((profile_buffers["profile_table"] as Dictionary).get("record_count", 0))
	var probe_record_count := int((profile_buffers.get("probe_records", {}) as Dictionary).get("record_count", 0)) if profile_buffers.has("probe_records") else 0
	var pivot_record_count := int((profile_buffers.get("pivot_records", {}) as Dictionary).get("record_count", 0)) if profile_buffers.has("pivot_records") else 0
	var object_ref_contract: Dictionary = gpu_contract.get("scene_voxel_tile_object_ref_contract", {})
	var object_ref_enabled := bool(object_ref_contract.get("scene_voxel_tile_object_ref_exclusion", false))
	var object_ref_tile_count := int(object_ref_contract.get("object_ref_tile_count", 0)) if object_ref_enabled else 0
	var object_ref_capacity := int(object_ref_contract.get("object_ref_capacity", 0)) if object_ref_enabled else 0
	var refs_per_tile := int(object_ref_contract.get("refs_per_tile", SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT)) if object_ref_enabled else SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
	var object_ref_tile_grid: Vector3i = object_ref_contract.get("object_ref_tile_grid_size", Vector3i.ZERO) if object_ref_enabled else Vector3i.ZERO
	var object_ref_tile_size: Vector3i = object_ref_contract.get("object_ref_tile_size", Vector3i(TILE_SIZE, TILE_SIZE, TILE_SIZE)) if object_ref_enabled else Vector3i(TILE_SIZE, TILE_SIZE, TILE_SIZE)
	var full_scan_debug_fallback := bool(object_ref_contract.get("same_type_exclusion_full_runtime_scan_debug_fallback", false))
	var asset_profile_id := int(settings.get(
		"profile_id",
		settings.get(
			"auto_voxel_profile_id",
			settings.get("runtime_profile_id", settings.get("asset_profile_id", 0))
		)
	))
	var bytes := PackedByteArray()
	bytes.resize(112)
	bytes.encode_s32(0, 1 if contract_enabled else 0)
	bytes.encode_s32(4, runtime_capacity)
	bytes.encode_s32(8, profile_count)
	bytes.encode_s32(12, asset_profile_id)
	bytes.encode_s32(16, 1 if bool(settings.get("score_runtime_profile_avoidance", true)) else 0)
	bytes.encode_s32(20, 1 if bool(settings.get("score_profile_complexity_debug", true)) else 0)
	bytes.encode_s32(24, 1 if object_ref_enabled else 0)
	bytes.encode_s32(28, 1 if full_scan_debug_fallback else 0)
	bytes.encode_s32(32, probe_record_count)
	bytes.encode_s32(36, 0)
	bytes.encode_s32(40, pivot_record_count)
	bytes.encode_s32(44, 0)
	bytes.encode_float(48, maxf(float(settings.get("min_distance_voxels", min_distance_voxels)), 0.0))
	bytes.encode_float(52, 0.0)
	bytes.encode_float(56, 0.0)
	bytes.encode_float(60, 0.0)
	bytes.encode_s32(64, 1 if object_ref_enabled else 0)
	bytes.encode_s32(68, object_ref_tile_count)
	bytes.encode_s32(72, refs_per_tile)
	bytes.encode_s32(76, object_ref_capacity)
	bytes.encode_s32(80, object_ref_tile_grid.x)
	bytes.encode_s32(84, object_ref_tile_grid.y)
	bytes.encode_s32(88, object_ref_tile_grid.z)
	bytes.encode_s32(92, maxi(object_ref_tile_size.x, 1))
	bytes.encode_s32(96, 1 if full_scan_debug_fallback else 0)
	bytes.encode_s32(100, 1 if bool(object_ref_contract.get("same_type_exclusion_object_ref_required", false)) else 0)
	bytes.encode_s32(104, 1 if bool(object_ref_contract.get("object_ref_numeric_schema_confirmed", false)) else 0)
	bytes.encode_s32(108, 0)
	return bytes


## 将 score 着色器写回的原始调试计数缓冲区字节解码为带命名字段的字典，
## 字段名称对应 SCORE_CONTRACT_DEBUG_NAMES 中定义的布局（魔数、运行时/
## 画像读取计数、重叠测试、间距排斥、场景体素瓦片对象引用等），
## 同时提取各调试通道的最大值（debug_channel_max）供问题定位使用。
func _decode_score_contract_debug(bytes: PackedByteArray) -> Dictionary:
	var available_bytes := mini(bytes.size(), SCORE_CONTRACT_DEBUG_WORDS * 4)
	available_bytes -= available_bytes % 4
	var available_words := int(available_bytes / 4)
	var words := PackedInt32Array()
	words.resize(SCORE_CONTRACT_DEBUG_WORDS)
	for i in range(available_words):
		words[i] = bytes.decode_s32(i * 4)
	var values := {}
	for i in range(SCORE_CONTRACT_DEBUG_NAMES.size()):
		values[SCORE_CONTRACT_DEBUG_NAMES[i]] = words[i]
	var debug_channel_max := PackedFloat32Array()
	debug_channel_max.resize(NUM_DEBUG_CHANNELS)
	var debug_max_word_offset := 23
	for i in range(NUM_DEBUG_CHANNELS):
		var word_index := debug_max_word_offset + i
		if word_index < words.size():
			debug_channel_max[i] = float(words[word_index]) / 1000.0
	return {
		"read_source": "score_shader_storage_buffer",
		"word_count": SCORE_CONTRACT_DEBUG_WORDS,
		"words": words,
		"values": values,
		"magic_ok": int(words[0]) == SCORE_CONTRACT_MAGIC,
		"contract_enabled": int(words[1]) != 0,
		"runtime_object_capacity": int(words[2]),
		"profile_count": int(words[3]),
		"alive_object_reads": int(words[4]),
		"profile_records_matched": int(words[5]),
		"runtime_overlap_tests": int(words[6]),
		"runtime_overlap_hits": int(words[7]),
		"profile_table_reads": int(words[8]),
		"asset_profile_id": int(words[9]),
		"candidate_invocations": int(words[10]),
		"profile_complexity": float(words[11]) / 1000.0,
		"runtime_profile_reads": int(words[12]),
		"runtime_profile_matches": int(words[13]),
		"probe_record_reads": int(words[14]),
		"pivot_record_reads": int(words[16]),
		"probe_weight": float(words[17]) / 1000.0,
		"pivot_bias": float(words[19]) / 1000.0,
		"profile_probe_count": int(words[20]),
		"profile_pivot_count": int(words[22]),
		"runtime_spacing_tests": int(words[31]),
		"runtime_spacing_profile_matches": int(words[32]),
		"runtime_spacing_rejections": int(words[33]),
		"runtime_spacing_min_distance": float(words[34]) / 1000.0,
		"scene_voxel_tile_object_ref_enabled": int(words[35]) != 0,
		"scene_voxel_tile_object_ref_tile_reads": int(words[36]),
		"scene_voxel_tile_object_ref_slot_reads": int(words[37]),
		"scene_voxel_tile_object_ref_object_reads": int(words[38]),
		"scene_voxel_tile_object_ref_duplicate_reads": int(words[39]),
		"debug_channel_max": debug_channel_max,
		"debug_channel_max_source": "score_shader_storage_buffer",
	}


## 生成用于重置的 score 调试缓冲区字节数据，仅写入用于校验的魔数（magic）。
func _pack_score_contract_debug_reset() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(SCORE_CONTRACT_DEBUG_WORDS * 4)
	bytes.encode_u32(0, SCORE_CONTRACT_MAGIC)
	return bytes


## 结合 score 着色器实际写回的调试计数，对 gpu_contract 进行事后标注：
## 判断着色器是否真正绑定并消费了运行时/画像缓冲区、同类最小间距排斥、
## 场景体素瓦片对象引用排斥等功能是否生效；若关键缓冲区未被实际消费，
## 则将契约标记为不可用（ok = false）并给出对应 reason，
## 最终返回附带 score_shader_debug 等标注字段的契约字典。
func _annotate_score_contract_debug(gpu_contract: Dictionary, score_contract_debug: Dictionary) -> Dictionary:
	var annotated := _with_same_type_exclusion_defaults(gpu_contract.duplicate(true))
	if str(annotated.get("reason", "")) == "gpu_runtime_profile_buffers_ready":
		var runtime_summary: Dictionary = annotated.get("runtime_summary", {})
		var runtime_live_count := int(runtime_summary.get("live_count", 0))
		var consumed_profile_side_buffers := (
			(int(score_contract_debug.get("profile_probe_count", 0)) <= 0 or int(score_contract_debug.get("probe_record_reads", 0)) > 0)
			and (int(score_contract_debug.get("profile_pivot_count", 0)) <= 0 or int(score_contract_debug.get("pivot_record_reads", 0)) > 0)
		)
		var consumed_runtime_buffers := int(score_contract_debug.get("alive_object_reads", 0)) > 0
		if runtime_live_count > 0:
			consumed_runtime_buffers = consumed_runtime_buffers \
				and int(score_contract_debug.get("runtime_profile_reads", 0)) > 0 \
				and int(score_contract_debug.get("runtime_overlap_tests", 0)) > 0
		annotated["score_shader_bound_runtime_profile_buffers"] = bool(score_contract_debug.get("magic_ok", false)) \
			and bool(score_contract_debug.get("contract_enabled", false))
		annotated["score_shader_consumed_runtime_buffers"] = consumed_runtime_buffers
		annotated["score_shader_consumed_profile_buffers"] = int(score_contract_debug.get("profile_table_reads", 0)) > 0 \
			and consumed_profile_side_buffers
		annotated["score_shader_consumed_profile_side_buffers"] = consumed_profile_side_buffers
		annotated["score_shader_runtime_overlap_tests"] = int(score_contract_debug.get("runtime_overlap_tests", 0))
		annotated["score_shader_runtime_overlap_hits"] = int(score_contract_debug.get("runtime_overlap_hits", 0))
		annotated["score_shader_profile_records_matched"] = int(score_contract_debug.get("profile_records_matched", 0))
		annotated["score_shader_profile_complexity"] = float(score_contract_debug.get("profile_complexity", 0.0))
		annotated["score_shader_runtime_profile_reads"] = int(score_contract_debug.get("runtime_profile_reads", 0))
		annotated["score_shader_runtime_profile_matches"] = int(score_contract_debug.get("runtime_profile_matches", 0))
		annotated["score_shader_probe_record_reads"] = int(score_contract_debug.get("probe_record_reads", 0))
		annotated["score_shader_pivot_record_reads"] = int(score_contract_debug.get("pivot_record_reads", 0))
		annotated["score_shader_same_type_min_spacing_tests"] = int(score_contract_debug.get("runtime_spacing_tests", 0))
		annotated["score_shader_same_type_min_spacing_profile_matches"] = int(score_contract_debug.get("runtime_spacing_profile_matches", 0))
		annotated["score_shader_same_type_min_spacing_rejections"] = int(score_contract_debug.get("runtime_spacing_rejections", 0))
		annotated["score_shader_same_type_min_spacing_min_distance"] = float(score_contract_debug.get("runtime_spacing_min_distance", 0.0))
		annotated["score_shader_scene_voxel_tile_object_ref_enabled"] = bool(score_contract_debug.get("scene_voxel_tile_object_ref_enabled", false))
		annotated["score_shader_scene_voxel_tile_object_ref_tile_reads"] = int(score_contract_debug.get("scene_voxel_tile_object_ref_tile_reads", 0))
		annotated["score_shader_scene_voxel_tile_object_ref_slot_reads"] = int(score_contract_debug.get("scene_voxel_tile_object_ref_slot_reads", 0))
		annotated["score_shader_scene_voxel_tile_object_ref_object_reads"] = int(score_contract_debug.get("scene_voxel_tile_object_ref_object_reads", 0))
		annotated["score_shader_scene_voxel_tile_object_ref_duplicate_reads"] = int(score_contract_debug.get("scene_voxel_tile_object_ref_duplicate_reads", 0))
		var object_ref_contract: Dictionary = annotated.get("scene_voxel_tile_object_ref_contract", {})
		var object_ref_path_used := bool(object_ref_contract.get("scene_voxel_tile_object_ref_exclusion", false)) \
			and bool(score_contract_debug.get("scene_voxel_tile_object_ref_enabled", false))
		if object_ref_path_used:
			annotated["scene_voxel_tile_object_ref_exclusion"] = true
			annotated["same_type_exclusion_object_ref_read_source"] = SCENE_VOXEL_TILE_OBJECT_REF_BUFFER_NAME
			annotated["same_type_exclusion_read_source"] = SCENE_VOXEL_TILE_OBJECT_REF_BUFFER_NAME
		if int(score_contract_debug.get("runtime_spacing_rejections", 0)) > 0:
			annotated["score_shader_same_type_min_spacing_exclusion"] = true
			if not object_ref_path_used:
				annotated["same_type_exclusion_read_source"] = "score_shader_storage_buffer"
		if not bool(annotated.get("score_shader_bound_runtime_profile_buffers", false)):
			annotated["ok"] = false
			annotated["reason"] = "score_runtime_profile_binding_missing"
		elif not bool(annotated.get("score_shader_consumed_runtime_buffers", false)):
			annotated["ok"] = false
			annotated["reason"] = "score_runtime_buffers_not_consumed"
		elif not bool(annotated.get("score_shader_consumed_profile_buffers", false)):
			annotated["ok"] = false
			annotated["reason"] = "score_profile_buffers_not_consumed"
	if not bool(annotated.get("ok", true)):
		annotated["contract_blocked"] = true
		annotated["runtime_read_source"] = "none"
		annotated["readback_source"] = "none"
	elif str(annotated.get("reason", "")) == "gpu_runtime_profile_buffers_ready":
		annotated["runtime_read_source"] = "gpu_storage_buffers"
		annotated["readback_source"] = "score_shader_storage_buffer"
	annotated["score_shader_debug"] = score_contract_debug
	return annotated


## 派发 reduce 计算着色器：将各 tile 的 top-K 候选结果规约为最终的
## 放置结果列表，写入 result_buffer / result_count_buffer。
func _dispatch_reduce(tile_topk_buffer: RID, result_buffer: RID, result_count_buffer: RID, candidate_count: int) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, tile_topk_buffer),
		make_storage_uniform(1, result_buffer),
		make_storage_uniform(2, result_count_buffer),
	], _shader_reduce, 0)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, candidate_count)
	push.encode_s32(4, result_capacity)
	push.encode_s32(8, RECORD_STRIDE)
	push.encode_s32(12, 0)
	push.encode_float(16, min_distance_voxels)
	push.encode_float(20, 0.0)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_reduce)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	end_compute_list()


## 派发 stamp 计算着色器：先初始化 stamp_bounds 缓冲区（init pass），
## 再根据已接受的放置结果与资产足迹（footprint）将增量写入
## complexity/collision 场，同时生成紧凑的 stamp delta 数据，
## 供 CPU 端 / 紧凑状态链（compact state-chain）路径读取使用。
func _dispatch_stamp(
	complexity_buffer: RID,
	collision_buffer: RID,
	result_buffer: RID,
	result_count_buffer: RID,
	footprint_pos_buffer: RID,
	footprint_weight_buffer: RID,
	stamp_delta_buffer: RID,
	stamp_delta_count_buffer: RID,
	stamp_bounds_buffer: RID,
	grid_size: Vector3i,
	footprint_count: int,
	settings: Dictionary
) -> void:
	var init_set0 := create_uniform_set([
		make_storage_uniform(0, stamp_bounds_buffer),
	], _shader_init_stamp_bounds, 0)

	var set0 := create_uniform_set([
		make_storage_uniform(0, complexity_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, result_buffer),
		make_storage_uniform(3, result_count_buffer),
		make_storage_uniform(4, footprint_pos_buffer),
		make_storage_uniform(5, footprint_weight_buffer),
		make_storage_uniform(6, stamp_delta_buffer),
		make_storage_uniform(7, stamp_delta_count_buffer),
		make_storage_uniform(8, stamp_bounds_buffer),
	], _shader_stamp, 0)

	var write_min: Vector3i = settings.get("write_min", Vector3i.ZERO)
	var write_max: Vector3i = settings.get("write_max", grid_size)
	var push := PackedByteArray()
	push.resize(80)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, grid_size.z)
	push.encode_s32(12, footprint_count)
	push.encode_s32(16, write_min.x)
	push.encode_s32(20, write_min.y)
	push.encode_s32(24, write_min.z)
	push.encode_s32(28, 0)
	push.encode_s32(32, write_max.x)
	push.encode_s32(36, write_max.y)
	push.encode_s32(40, write_max.z)
	push.encode_s32(44, 0)
	push.encode_float(48, solid_threshold)
	push.encode_float(52, scene_write_scale)
	push.encode_float(56, collision_write_scale)
	push.encode_float(60, 0.0)
	push.encode_float(64, asset_color.r)
	push.encode_float(68, asset_color.g)
	push.encode_float(72, asset_color.b)
	push.encode_float(76, 0.0)

	var init_push := PackedByteArray()
	init_push.resize(16)
	init_push.encode_s32(0, maxi(result_capacity, 1))
	init_push.encode_s32(4, STAMP_BOUNDS_STRIDE)
	init_push.encode_s32(8, 0)
	init_push.encode_s32(12, 0)

	var total_threads := result_capacity * footprint_count
	var init_groups := ceili(float(maxi(result_capacity, 1)) / 64.0)
	var groups := ceili(float(maxi(total_threads, 1)) / 64.0)
	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_init_stamp_bounds)
	_rd.compute_list_bind_uniform_set(cl, init_set0, 0)
	_rd.compute_list_set_push_constant(cl, init_push, init_push.size())
	_rd.compute_list_dispatch(cl, init_groups, 1, 1)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_stamp)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	end_compute_list()


## 将资产的足迹（footprint，局部体素形状）数组打包为 GPU 可读取的
## 位置字节缓冲区（含碰撞强度）与权重字节缓冲区（含 flags、半径）。
func _pack_footprint(footprint: Array) -> Dictionary:
	var pos_bytes := PackedByteArray()
	var weight_bytes := PackedByteArray()
	pos_bytes.resize(footprint.size() * BufferUtils.IVEC4_BYTES)
	weight_bytes.resize(footprint.size() * BufferUtils.IVEC4_BYTES)

	for i in range(footprint.size()):
		var entry: Dictionary = footprint[i]
		var local_pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var collision_q8 := clampi(roundi(clampf(float(entry.get("collision_strength", 0.0)), 0.0, 1.0) * 255.0), 0, 255)
		var flags := int(entry.get("flags", 0))
		var weight := maxf(float(entry.get("weight", 1.0)), 0.0)
		var pos_offset := i * BufferUtils.IVEC4_BYTES
		BufferUtils.encode_vec3i4_with_w(pos_bytes, pos_offset, local_pos, collision_q8)
		weight_bytes.encode_float(pos_offset + 0, weight)
		weight_bytes.encode_float(pos_offset + 4, float(flags))
		weight_bytes.encode_float(pos_offset + 8, float(entry.get("radius", 0.0)))
		weight_bytes.encode_float(pos_offset + 12, 0.0)
	return {
		"pos_bytes": pos_bytes,
		"weight_bytes": weight_bytes,
	}


## 复制浮点数组并将其长度调整（补零或截断）为指定的期望大小。
func _normalize_float_array(values: PackedFloat32Array, expected_size: int) -> PackedFloat32Array:
	var result := values.duplicate()
	result.resize(expected_size)
	return result


## 将原始字节数据解码为指定数量的 32 位浮点数组，容忍数据不足（不足部分补零）。
func _decode_float_array(bytes: PackedByteArray, value_count: int) -> PackedFloat32Array:
	var available_bytes := mini(bytes.size(), value_count * 4)
	available_bytes -= available_bytes % 4
	var values := bytes.slice(0, available_bytes).to_float32_array()
	values.resize(value_count)
	return values


## 从字节缓冲区开头读取一个 32 位无符号整数，作为计数值返回。
func _decode_u32_count(bytes: PackedByteArray) -> int:
	if bytes.size() < 4:
		return 0
	return int(bytes.decode_u32(0))


## 将 GPU 结果缓冲区中的原始字节解码为放置结果记录数组（Array[Dictionary]）。
## 按 RECORD_STRIDE 定义的步幅依次解析每条记录的体素原点/分数、
## tile/asset/旋转/缩放索引，以及支撑率、碰撞、复杂度与间隙重叠等调试字段，
## 返回可供 CPU 端使用的记录列表。
func _decode_records(bytes: PackedByteArray, record_count: int) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var byte_stride := RECORD_STRIDE * 16
	var available_bytes := mini(bytes.size(), record_count * byte_stride)
	available_bytes -= available_bytes % byte_stride
	var available := mini(record_count, int(available_bytes / byte_stride))
	for i in range(available):
		var base := i * byte_stride
		var pose := Vector4(
			bytes.decode_float(base + 0),
			bytes.decode_float(base + 4),
			bytes.decode_float(base + 8),
			bytes.decode_float(base + 12)
		)
		var ids := Vector4(
			bytes.decode_float(base + 16),
			bytes.decode_float(base + 20),
			bytes.decode_float(base + 24),
			bytes.decode_float(base + 28)
		)
		var debug0 := Vector4(
			bytes.decode_float(base + 32),
			bytes.decode_float(base + 36),
			bytes.decode_float(base + 40),
			bytes.decode_float(base + 44)
		)
		var debug1 := Vector4(
			bytes.decode_float(base + 48),
			bytes.decode_float(base + 52),
			bytes.decode_float(base + 56),
			bytes.decode_float(base + 60)
		)
		records.append({
			"voxel_origin": Vector3i(int(roundf(pose.x)), int(roundf(pose.y)), int(roundf(pose.z))),
			"score": pose.w,
			"tile_id": int(roundf(ids.x)),
			"asset_index": int(roundf(ids.y)),
			"rotation_index": int(roundf(ids.z)),
			"scale_index": int(roundf(ids.w)),
			"support_ratio": debug0.x,
			"solid_collision": debug0.y,
			"complexity_overlap": debug0.z,
			"clearance_overlap": debug0.w,
			"ignored_sample": debug1.x,
			"valid": debug1.y > 0.5,
			"support_hit": debug1.z,
			"support_total": debug1.w,
		})
	return records


## 将 GPU stamp 着色器输出的原始字节解码为体素增量（stamp delta）记录数组。
## 每条记录包含体素坐标、场景复杂度、碰撞强度及结果/footprint 索引，写入标记无效的条目会被跳过。
func _decode_stamp_deltas(bytes: PackedByteArray, delta_count: int) -> Array[Dictionary]:
	var deltas: Array[Dictionary] = []
	var byte_stride := DELTA_STRIDE * 16
	var available_bytes := mini(bytes.size(), delta_count * byte_stride)
	available_bytes -= available_bytes % byte_stride
	var available := mini(delta_count, int(available_bytes / byte_stride))
	for i in range(available):
		var base := i * byte_stride
		var pos_scene := Vector4(
			bytes.decode_float(base + 0),
			bytes.decode_float(base + 4),
			bytes.decode_float(base + 8),
			bytes.decode_float(base + 12)
		)
		var collision_meta := Vector4(
			bytes.decode_float(base + 16),
			bytes.decode_float(base + 20),
			bytes.decode_float(base + 24),
			bytes.decode_float(base + 28)
		)
		if collision_meta.w <= 0.5:
			continue
		deltas.append({
			"voxel": Vector3i(int(roundf(pos_scene.x)), int(roundf(pos_scene.y)), int(roundf(pos_scene.z))),
			"scene_complexity": pos_scene.w,
			"collision_strength": collision_meta.x,
			"result_index": int(roundf(collision_meta.y)),
			"footprint_index": int(roundf(collision_meta.z)),
		})
	return deltas


## 将 GPU stamp bounds 缓冲区的原始字节解码为每次 stamp 写入的包围盒记录（voxel_min/voxel_max/written_count）。
## 坐标会被裁剪到网格范围内，写入数量为 0 或退化的包围盒会被跳过。
func _decode_stamp_bounds(bytes: PackedByteArray, bound_count: int, grid_size: Vector3i) -> Array[Dictionary]:
	var bounds: Array[Dictionary] = []
	var byte_stride := STAMP_BOUNDS_STRIDE * 16
	var available_bytes := mini(bytes.size(), bound_count * byte_stride)
	available_bytes -= available_bytes % byte_stride
	var available := mini(bound_count, int(available_bytes / byte_stride))
	for i in range(available):
		var base := i * byte_stride
		var written_count := int(bytes.decode_u32(base + 12))
		if written_count <= 0:
			continue
		var voxel_min := Vector3i(
			clampi(int(bytes.decode_u32(base + 0)), 0, grid_size.x),
			clampi(int(bytes.decode_u32(base + 4)), 0, grid_size.y),
			clampi(int(bytes.decode_u32(base + 8)), 0, grid_size.z)
		)
		var voxel_max := Vector3i(
			clampi(int(bytes.decode_u32(base + 16)), 0, grid_size.x),
			clampi(int(bytes.decode_u32(base + 20)), 0, grid_size.y),
			clampi(int(bytes.decode_u32(base + 24)), 0, grid_size.z)
		)
		if voxel_max.x <= voxel_min.x or voxel_max.y <= voxel_min.y or voxel_max.z <= voxel_min.z:
			continue
		bounds.append({
			"result_index": i,
			"voxel_min": voxel_min,
			"voxel_max": voxel_max,
			"written_count": written_count,
			"source": "stamp_shader_storage_buffer",
		})
	return bounds


## 将 Color 颜色打包为单个 RGBA8 整数（各分量量化到 0-255 并按 R/G/B/A 顺序移位组合）。
static func _pack_color_rgba8(c: Color) -> int:
	var r := clampi(int(roundf(c.r * 255.0)), 0, 255)
	var g := clampi(int(roundf(c.g * 255.0)), 0, 255)
	var b := clampi(int(roundf(c.b * 255.0)), 0, 255)
	var a := clampi(int(roundf(c.a * 255.0)), 0, 255)
	return (r << 24) | (g << 16) | (b << 8) | a


## 从 settings 中取出预打包的 target_color_rgba8_bytes，并按 voxel_count 截断/校验长度。
## 若数据不足则返回填零的字节数组。
func _target_color_rgba8_bytes_from_settings(settings: Dictionary, voxel_count: int) -> PackedByteArray:
	var expected_bytes := maxi(voxel_count, 1) * 4
	var prepacked: PackedByteArray = settings.get("target_color_rgba8_bytes", PackedByteArray())
	if prepacked.size() >= expected_bytes:
		if prepacked.size() == expected_bytes:
			return prepacked
		return prepacked.slice(0, expected_bytes)
	var bytes := PackedByteArray()
	bytes.resize(expected_bytes)
	return bytes


## 从 settings 中提取 target_field_bytes（支持 float 数组或字节数组两种输入），
## 归一化为按 voxel_count 匹配的 vec4 浮点数组，并返回包含 has_target 等元信息的字典。
func _target_field_bytes_from_settings(settings: Dictionary, voxel_count: int) -> Dictionary:
	var expected_floats := maxi(voxel_count, 1) * 4
	var raw_field = settings.get("target_field_bytes", PackedFloat32Array())
	var prepacked := PackedFloat32Array()
	if raw_field is PackedFloat32Array:
		prepacked = raw_field
	elif raw_field is PackedByteArray:
		prepacked = (raw_field as PackedByteArray).to_float32_array()
	if prepacked.size() >= expected_floats:
		var field_bytes := prepacked
		if field_bytes.size() > expected_floats:
			field_bytes = field_bytes.slice(0, expected_floats)
		return {
			"bytes": field_bytes,
			"has_target": true,
			"source": "target_field_bytes",
			"expected_float_count": expected_floats,
			"actual_float_count": field_bytes.size(),
			"target_field_byte_count": field_bytes.size() * 4,
			"target_field_format": "vec4",
			"target_field_stride_bytes": 16,
		}
	var empty := PackedFloat32Array()
	empty.resize(expected_floats)
	return {
		"bytes": empty,
		"has_target": false,
		"source": "none",
		"expected_float_count": expected_floats,
		"actual_float_count": prepacked.size(),
		"target_field_byte_count": 0,
		"target_field_format": "vec4",
		"target_field_stride_bytes": 16,
	}


## 组装本帧用于目标（target）评分的 GPU 读取缓冲区数据包，是 target read buffer 的统一入口。
## 优先尝试复用 ScenePlacementActor 提供的常驻 GPU 缓冲区（_borrowed_target_read_buffer_pack）；
## 若不可用，则回退到 settings 中的旧版 target_field/target_color 字节数组并在此处上传；
## 若声明了常驻交接但数据不足，则返回 blocked 包表示无法提供目标数据。
func _target_read_buffer_pack(settings: Dictionary, voxel_count: int) -> Dictionary:
	var expected_color_bytes := maxi(voxel_count, 1) * 4
	var expected_field_floats := maxi(voxel_count, 1) * 4
	var expected_field_bytes := expected_field_floats * 4
	var target_read_buffers: Dictionary = settings.get("target_read_buffers", {})
	if target_read_buffers.is_empty() and settings.get("resident_target_read_buffer_handoff_summary", null) is Dictionary:
		target_read_buffers = settings
	var borrowed := _borrowed_target_read_buffer_pack(target_read_buffers, expected_field_bytes)
	if bool(borrowed.get("ready", false)):
		return borrowed

	var field_input := _target_read_buffer_legacy_field(settings, target_read_buffers)
	var field_pack := _target_field_bytes_from_settings({"target_field_bytes": field_input}, voxel_count)
	var has_field := bool(field_pack.get("has_target", false))
	var color_input_bytes := _target_read_buffer_legacy_bytes(settings, target_read_buffers, "target_color_rgba8_bytes")
	var upload_reason := str(borrowed.get("reason", "resident_handoff_absent"))
	if _target_read_buffers_claim_resident(target_read_buffers) \
			and not has_field \
			and color_input_bytes.size() < expected_color_bytes:
		return _blocked_target_read_buffer_pack(
			upload_reason,
			expected_field_bytes,
			field_input.size() * 4,
			color_input_bytes.size()
		)

	if has_field:
		var field_bytes: PackedFloat32Array = field_pack.get("bytes", PackedFloat32Array())
		return {
			"ready": true,
			"target_read_buffer_source": "uploaded_target_field_bytes",
			"target_read_buffer_ownership": "vpg_uploaded_owned",
			"target_read_buffer_lifetime": "VoxelPlacementGenerator frame scope",
			"target_read_buffers_borrowed": false,
			"target_read_buffers_uploaded": true,
			"target_field_bytes_uploaded": true,
			"target_color_bytes_uploaded": false,
			"target_field_buffer": RID(),
			"target_field_bytes": field_bytes,
			"target_field_byte_count": field_bytes.size() * 4,
			"expected_byte_count": expected_field_bytes,
			"target_field_format": "vec4",
			"target_field_stride_bytes": 16,
			"target_color_rgba8_buffer": RID(),
			"target_color_rgba8_bytes": PackedByteArray(),
			"target_color_rgba8_byte_count": 0,
			"target_color_format": "none",
			"target_color_stride_bytes": 0,
			"has_target": true,
			"owner": "VoxelPlacementGenerator",
			"producer": "VoxelPlacementGenerator",
			"borrowed_from": "none",
			"source_reason": upload_reason,
			"rendering_device_match": false,
			"rid_valid": false,
			"gpu_first": true,
			"cpu_fallback": false,
		}

	var legacy_byte_settings := settings.duplicate(false)
	legacy_byte_settings["target_color_rgba8_bytes"] = color_input_bytes
	var color_bytes := _target_color_rgba8_bytes_from_settings(legacy_byte_settings, voxel_count)
	var has_color := color_bytes.size() >= expected_color_bytes
	return {
		"ready": true,
		"target_read_buffer_source": "uploaded_target_bytes",
		"target_read_buffer_ownership": "vpg_uploaded_owned",
		"target_read_buffer_lifetime": "VoxelPlacementGenerator frame scope",
		"target_read_buffers_borrowed": false,
		"target_read_buffers_uploaded": true,
		"target_field_bytes_uploaded": false,
		"target_color_bytes_uploaded": true,
		"target_field_buffer": RID(),
		"target_field_bytes": PackedFloat32Array(),
		"target_field_byte_count": expected_field_bytes,
		"expected_byte_count": expected_field_bytes,
		"target_field_format": "vec4",
		"target_field_stride_bytes": 16,
		"target_color_rgba8_buffer": RID(),
		"target_color_rgba8_bytes": color_bytes,
		"target_color_rgba8_byte_count": color_bytes.size(),
		"target_color_format": "rgba8_u32",
		"target_color_stride_bytes": 4,
		"has_target": has_color,
		"owner": "VoxelPlacementGenerator",
		"producer": "VoxelPlacementGenerator",
		"borrowed_from": "none",
		"source_reason": upload_reason,
		"rendering_device_match": false,
		"rid_valid": false,
		"gpu_first": true,
		"cpu_fallback": false,
	}


## 尝试直接复用外部（ScenePlacementActor）持有的常驻 GPU target_field 缓冲区，避免额外的 CPU 回读/上传。
## 依次校验 RID 是否有效、RenderingDevice 是否与本对象一致、字节数是否匹配期望大小；
## 全部通过则返回 ready=true 的"借用"数据包，否则返回 ready=false 并附带失败原因字符串。
func _borrowed_target_read_buffer_pack(target_read_buffers: Dictionary, expected_field_bytes: int) -> Dictionary:
	if target_read_buffers.is_empty():
		return {"ready": false, "reason": "resident_handoff_absent"}

	var summary: Dictionary = target_read_buffers.get("resident_target_read_buffer_handoff_summary", {})
	var raw_field = target_read_buffers.get(
		"target_field_buffer",
		target_read_buffers.get(
			"resident_target_field_buffer",
			summary.get(
				"target_field_buffer",
				summary.get("resident_target_field_buffer", summary.get("target_color_rgba8_buffer", RID()))
			)
		)
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
	if field_byte_count != expected_field_bytes:
		return {"ready": false, "reason": "resident_target_read_buffer_byte_count_mismatch"}

	return {
		"ready": true,
		"target_read_buffer_source": "borrowed_scene_placement_actor_resident",
		"target_read_buffer_ownership": "borrowed_external",
		"target_read_buffer_lifetime": str(target_read_buffers.get("resident_target_read_buffer_lifetime", summary.get("target_read_buffer_lifetime", "ScenePlacementActor owned"))),
		"target_read_buffers_borrowed": true,
		"target_read_buffers_uploaded": false,
		"target_field_bytes_uploaded": false,
		"target_color_bytes_uploaded": false,
		"target_field_buffer": field_buffer,
		"target_field_bytes": PackedFloat32Array(),
		"target_field_byte_count": field_byte_count,
		"expected_byte_count": expected_field_bytes,
		"target_field_format": str(target_read_buffers.get("target_field_format", summary.get("target_field_format", "vec4"))),
		"target_field_stride_bytes": int(target_read_buffers.get("target_field_stride_bytes", summary.get("target_field_stride_bytes", 16))),
		"target_color_rgba8_buffer": RID(),
		"target_color_rgba8_bytes": PackedByteArray(),
		"target_color_rgba8_byte_count": 0,
		"target_color_format": "none",
		"target_color_stride_bytes": 0,
		"has_target": true,
		"owner": str(target_read_buffers.get("resident_target_read_buffer_owner", summary.get("owner", "ScenePlacementActor"))),
		"producer": str(summary.get("producer", "ScenePlacementActorTargetReadBuffers")),
		"borrowed_from": "ScenePlacementActor",
		"source_reason": str(summary.get("reason", "ok")),
		"rendering_device_match": true,
		"rid_valid": true,
		"gpu_first": true,
		"cpu_fallback": false,
	}


## 判断调用方是否声明了"常驻目标读取缓冲区交接"（resident_target_read_buffer_handoff）。
## 该标记用于决定：当旧版字节数据缺失时，是否应视为错误并返回 blocked 结果。
func _target_read_buffers_claim_resident(target_read_buffers: Dictionary) -> bool:
	if target_read_buffers.is_empty():
		return false
	var summary: Dictionary = target_read_buffers.get("resident_target_read_buffer_handoff_summary", {})
	return bool(target_read_buffers.get(
		"resident_target_read_buffer_handoff",
		summary.get("resident_target_read_buffer_handoff", false)
	))


## 旧版回退路径：依次尝试从 settings、再从 target_read_buffers 交接字典中读取 target_field_bytes
## （兼容 PackedFloat32Array 与 PackedByteArray 两种存储形式），都取不到则返回空数组。
func _target_read_buffer_legacy_field(settings: Dictionary, target_read_buffers: Dictionary) -> PackedFloat32Array:
	var raw = settings.get("target_field_bytes", PackedFloat32Array())
	if raw is PackedFloat32Array:
		var field := raw as PackedFloat32Array
		if not field.is_empty():
			return field
	elif raw is PackedByteArray:
		var field_from_bytes := (raw as PackedByteArray).to_float32_array()
		if not field_from_bytes.is_empty():
			return field_from_bytes
	var raw_handoff = target_read_buffers.get("target_field_bytes", PackedFloat32Array())
	if raw_handoff is PackedFloat32Array:
		return raw_handoff
	if raw_handoff is PackedByteArray:
		return (raw_handoff as PackedByteArray).to_float32_array()
	return PackedFloat32Array()


## 通用的旧版字节数组回退读取：先从 settings 按 key 取值，取不到再从 target_read_buffers 交接字典中取，
## 都没有则返回空的 PackedByteArray。
func _target_read_buffer_legacy_bytes(settings: Dictionary, target_read_buffers: Dictionary, key: String) -> PackedByteArray:
	var raw = settings.get(key, PackedByteArray())
	if raw is PackedByteArray:
		var bytes := raw as PackedByteArray
		if not bytes.is_empty():
			return bytes
	var raw_handoff = target_read_buffers.get(key, PackedByteArray())
	if raw_handoff is PackedByteArray:
		return raw_handoff
	return PackedByteArray()


## 构造一个 ready=false 的"阻塞"目标读取缓冲区数据包：用于常驻交接已声明但既无 target_field
## 也无合法旧版颜色字节可用的情况，携带失败原因及期望/实际字节数用于诊断。
func _blocked_target_read_buffer_pack(
	borrow_reason: String,
	expected_field_bytes: int,
	actual_field_bytes: int,
	actual_color_bytes: int
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
		"target_field_bytes_uploaded": false,
		"target_color_bytes_uploaded": false,
		"target_field_buffer": RID(),
		"target_field_bytes": PackedFloat32Array(),
		"target_field_byte_count": actual_field_bytes,
		"expected_byte_count": expected_field_bytes,
		"target_field_format": "vec4",
		"target_field_stride_bytes": 16,
		"target_color_rgba8_buffer": RID(),
		"target_color_rgba8_bytes": PackedByteArray(),
		"target_color_rgba8_byte_count": actual_color_bytes,
		"target_color_format": "rgba8_u32",
		"target_color_stride_bytes": 4,
		"has_target": false,
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


## 将内部的目标读取缓冲区数据包（可能含原始 RID/字节数组）转换为轻量级摘要字典，
## 便于日志输出与调试：仅保留 RID 是否有效等标志位，不包含原始字节负载。
func _target_read_buffer_summary(pack: Dictionary) -> Dictionary:
	var raw_field = pack.get("target_field_buffer", RID())
	var field_buffer: RID = raw_field if raw_field is RID else RID()
	var raw_color = pack.get("target_color_rgba8_buffer", RID())
	var color_buffer: RID = raw_color if raw_color is RID else RID()
	return {
		"ready": bool(pack.get("ready", false)),
		"target_read_buffer_source": str(pack.get("target_read_buffer_source", "none")),
		"target_read_buffer_ownership": str(pack.get("target_read_buffer_ownership", "none")),
		"target_read_buffer_lifetime": str(pack.get("target_read_buffer_lifetime", "none")),
		"target_read_buffers_borrowed": bool(pack.get("target_read_buffers_borrowed", false)),
		"target_read_buffers_uploaded": bool(pack.get("target_read_buffers_uploaded", false)),
		"target_field_bytes_uploaded": bool(pack.get("target_field_bytes_uploaded", false)),
		"target_color_bytes_uploaded": bool(pack.get("target_color_bytes_uploaded", false)),
		"target_field_buffer_rid": "valid" if field_buffer.is_valid() else "none",
		"target_field_buffer_rid_valid": field_buffer.is_valid(),
		"target_field_byte_count": int(pack.get("target_field_byte_count", 0)),
		"target_field_format": str(pack.get("target_field_format", "none")),
		"target_field_stride_bytes": int(pack.get("target_field_stride_bytes", 0)),
		"target_color_rgba8_buffer_rid": "valid" if color_buffer.is_valid() else "none",
		"target_color_rgba8_buffer_rid_valid": color_buffer.is_valid(),
		"target_color_rgba8_byte_count": int(pack.get("target_color_rgba8_byte_count", 0)),
		"expected_byte_count": int(pack.get("expected_byte_count", 0)),
		"target_color_format": str(pack.get("target_color_format", "none")),
		"target_color_stride_bytes": int(pack.get("target_color_stride_bytes", 0)),
		"has_target": bool(pack.get("has_target", false)),
		"owner": str(pack.get("owner", "none")),
		"producer": str(pack.get("producer", "none")),
		"borrowed_from": str(pack.get("borrowed_from", "none")),
		"source_reason": str(pack.get("source_reason", "none")),
		"rendering_device_match": bool(pack.get("rendering_device_match", false)),
		"contract_blocked": bool(pack.get("contract_blocked", false)),
		"gpu_first": true,
		"cpu_fallback": false,
	}


## 通过 GPU 计算着色器（pack_target_field）将 target_color_rgba8、场景复杂度与碰撞字段
## 合并为单个 vec4 target_field 缓冲区；输入无效或管线未就绪时返回全零缓冲区。
func _ensure_combined_target_field_buffer(complexity_buffer: RID, collision_buffer: RID, target_color_buffer: RID, voxel_count: int) -> RID:
	# Combines target_color_rgba8 (u32 RGBA8) with scene/collision fields into a single vec4 target_field buffer.
	# target_field.a = completely = max(scene_complexity, collision); zero means the voxel is empty.
	if not target_color_buffer.is_valid() or not complexity_buffer.is_valid() or not collision_buffer.is_valid():
		return _create_zero_target_field_buffer(voxel_count)

	if not _pipeline_pack_target_field.is_valid() or not _shader_pack_target_field.is_valid():
		push_error("[VoxelPlacementGenerator] pack_target_field pipeline not ready")
		return RID()

	var output_buffer := storage_buffer_zero(voxel_count * 16, SCOPE_FRAME, "target_field_combined")
	if not output_buffer.is_valid():
		return RID()

	var set0 := create_uniform_set([
		make_storage_uniform(0, target_color_buffer),
		make_storage_uniform(1, complexity_buffer),
		make_storage_uniform(2, collision_buffer),
		make_storage_uniform(3, output_buffer),
	], _shader_pack_target_field, 0)
	if not set0.is_valid():
		release_rid(output_buffer)
		return RID()

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, voxel_count)

	var groups := ceili(float(maxi(voxel_count, 1)) / 64.0)
	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_pack_target_field)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	end_compute_list()

	return output_buffer

## 分配并清零一个与 target_field 同尺寸（voxel_count * 16 字节）的 GPU 临时缓冲区。
func _create_zero_target_field_buffer(voxel_count: int) -> RID:
	return storage_buffer_zero(voxel_count * 16, SCOPE_FRAME, "target_field_zero")


## 在 CPU 端从交错排列的逐体素调试缓冲区中提取指定通道（channel）的数据。
## 通道索引越界时返回全零数组。
static func get_debug_channel(debug_voxel: PackedFloat32Array, channel: int, voxel_count: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(voxel_count)
	if channel < 0 or channel >= NUM_DEBUG_CHANNELS:
		return result
	for i in range(mini(voxel_count, debug_voxel.size() / NUM_DEBUG_CHANNELS)):
		result[i] = debug_voxel[i * NUM_DEBUG_CHANNELS + channel]
	return result


## get_debug_channel 的 GPU 计算版本：校验通道索引与缓冲区大小后，
## 准备渲染设备/着色器/管线，将 debug_voxel 上传为存储缓冲区，
## 派发 extract_debug_voxel_channel 计算着色器提取单一通道并回读结果；
## 返回包含 ok/reason 及派发诊断信息的字典，成功或失败路径均会释放 GPU 资源。
func get_debug_channel_gpu(debug_voxel: PackedFloat32Array, channel: int, voxel_count: int) -> Dictionary:
	var safe_voxel_count := maxi(voxel_count, 0)
	var result := PackedFloat32Array()
	result.resize(safe_voxel_count)
	if channel < 0 or channel >= NUM_DEBUG_CHANNELS:
		return {
			"ok": false,
			"reason": "debug_channel_out_of_range",
			"gpu_first": true,
			"cpu_fallback": false,
			"channel": channel,
			"voxel_count": safe_voxel_count,
			"channel_stride": NUM_DEBUG_CHANNELS,
			"debug_channel": result,
		}

	var required_floats := safe_voxel_count * NUM_DEBUG_CHANNELS
	if debug_voxel.size() < required_floats:
		return {
			"ok": false,
			"reason": "debug_voxel_size_mismatch",
			"gpu_first": true,
			"cpu_fallback": false,
			"channel": channel,
			"voxel_count": safe_voxel_count,
			"channel_stride": NUM_DEBUG_CHANNELS,
			"expected_floats": required_floats,
			"actual_floats": debug_voxel.size(),
			"debug_channel": result,
		}
	if safe_voxel_count <= 0:
		return {
			"ok": true,
			"reason": "empty",
			"gpu_first": true,
			"cpu_fallback": false,
			"channel": channel,
			"voxel_count": safe_voxel_count,
			"channel_stride": NUM_DEBUG_CHANNELS,
			"debug_channel": result,
		}

	log_name = "VoxelPlacementDebugChannel"
	sync_global_device = true
	if not ensure_device(true, true):
		return {
			"ok": false,
			"reason": "missing_rendering_device",
			"gpu_first": true,
			"cpu_fallback": false,
			"channel": channel,
			"voxel_count": safe_voxel_count,
			"channel_stride": NUM_DEBUG_CHANNELS,
			"debug_channel": result,
		}

	var shader := load_compute_shader("res://shaders/extract_debug_voxel_channel.glsl")
	var pipeline := create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		dispose()
		return {
			"ok": false,
			"reason": "debug_channel_shader_not_ready",
			"gpu_first": true,
			"cpu_fallback": false,
			"channel": channel,
			"voxel_count": safe_voxel_count,
			"channel_stride": NUM_DEBUG_CHANNELS,
			"debug_channel": result,
		}

	var input_buffer := storage_buffer_from_floats(debug_voxel.slice(0, required_floats), SCOPE_FRAME, "debug_voxel_r32f")
	var output_buffer := storage_buffer_zero(safe_voxel_count * 4, SCOPE_FRAME, "debug_channel_r32f")
	var set0 := create_uniform_set([
		make_storage_uniform(0, input_buffer),
		make_storage_uniform(1, output_buffer),
	], shader, 0)
	if not set0.is_valid():
		dispose()
		return {
			"ok": false,
			"reason": "debug_channel_uniform_set_not_ready",
			"gpu_first": true,
			"cpu_fallback": false,
			"channel": channel,
			"voxel_count": safe_voxel_count,
			"channel_stride": NUM_DEBUG_CHANNELS,
			"debug_channel": result,
		}

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, safe_voxel_count)
	push.encode_s32(4, channel)
	push.encode_s32(8, NUM_DEBUG_CHANNELS)
	push.encode_s32(12, 0)

	var groups := ceili(float(safe_voxel_count) / 64.0)
	var cl := begin_compute_list()
	if cl < 0:
		dispose()
		return {
			"ok": false,
			"reason": "debug_channel_compute_list_begin_failed",
			"gpu_first": true,
			"cpu_fallback": false,
			"channel": channel,
			"voxel_count": safe_voxel_count,
			"channel_stride": NUM_DEBUG_CHANNELS,
			"debug_channel": result,
		}
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	end_compute_list()
	submit_and_sync(true)

	var out_bytes := _rd.buffer_get_data(output_buffer, 0, safe_voxel_count * 4)
	dispose()

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"channel": channel,
		"voxel_count": safe_voxel_count,
		"channel_stride": NUM_DEBUG_CHANNELS,
		"input_format": "r32f_interleaved_debug_voxel",
		"output_format": "r32f_channel",
		"local_size_x": 64,
		"dispatch_groups_x": groups,
		"debug_channel": out_bytes.to_float32_array(),
		"readback_source": "extract_debug_voxel_channel_compute",
	}


# ---------------------------------------------------------------------------
# Footprint baking: collision -> GPU footprint array
# ---------------------------------------------------------------------------

## 委托给 VoxelFootprintBakerScript，从碰撞层烘焙出资产的本地体素 footprint 形状数组。
static func bake_footprint_from_collision(
	collision_layers: Array,
	voxel_size: Vector3,
	add_support: bool = true,
	clearance_slices: int = 1,
	prefer_gpu: bool = true
) -> Array[Dictionary]:
	return VoxelFootprintBakerScript.bake_footprint_from_collision(collision_layers, voxel_size, add_support, clearance_slices, prefer_gpu)

## 委托给 VoxelFootprintBakerScript，将已烘焙的 footprint 绕 Y 轴旋转 yaw_degrees 度。
static func rotate_footprint_y(
	footprint: Array[Dictionary], yaw_degrees: float
) -> Array[Dictionary]:
	return VoxelFootprintBakerScript.rotate_footprint_y(footprint, yaw_degrees)



## ===== VoxelPlacementWriteback delegates =====
## 转发给 VoxelPlacementWriteback：合并 GPU AutoObject 运行时写回报告。
func _merge_gpu_autoobject_runtime_writeback_report(target: Dictionary, source: Dictionary) -> void:
	_ensure_placement_writeback()._merge_gpu_autoobject_runtime_writeback_report(target, source)
## 转发给 VoxelPlacementWriteback：创建新的 GPU AutoObject 运行时写回报告。
func _new_gpu_autoobject_runtime_writeback_report(runtime_provider: Object,
	profile_container: Object,
	gpu_contract: Dictionary,
	enabled: bool) -> Dictionary:
	return _ensure_placement_writeback()._new_gpu_autoobject_runtime_writeback_report(runtime_provider, profile_container, gpu_contract, enabled)
## 转发给 VoxelPlacementWriteback：将已接受的放置结果写入 GPU AutoObject 运行时。
func _write_accepted_placements_to_gpu_runtime(runtime_provider: Object,
	asset_index: int,
	asset_def: Dictionary,
	per_asset_settings: Dictionary,
	world_results: Array,
	raw_results: Array,
	stamp_deltas: Array,
	stamp_bounds: Array,
	common_settings: Dictionary) -> Dictionary:
	return _ensure_placement_writeback()._write_accepted_placements_to_gpu_runtime(runtime_provider, asset_index, asset_def, per_asset_settings, world_results, raw_results, stamp_deltas, stamp_bounds, common_settings)
## 转发给 VoxelPlacementWriteback：将已接受的放置结果写入场景体素瓦片提交器（committer）。
func _write_accepted_placements_to_scene_voxel_committer(asset_defs: Array,
	result_by_index: Dictionary,
	asset_results: Array[Dictionary],
	common_settings: Dictionary,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3) -> Dictionary:
	return _ensure_placement_writeback()._write_accepted_placements_to_scene_voxel_committer(asset_defs, result_by_index, asset_results, common_settings, grid_size, voxel_size, grid_origin)
## 转发给 VoxelPlacementWriteback：校验 GPU 运行时 profile 契约是否满足。
func validate_gpu_runtime_profile_contract(settings: Dictionary) -> Dictionary:
	return _ensure_placement_writeback().validate_gpu_runtime_profile_contract(settings)
