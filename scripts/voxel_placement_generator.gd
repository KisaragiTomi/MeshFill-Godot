class_name VoxelPlacementGenerator


extends "res://scripts/godot_compute_shader_base.gd"
## Minimal GPU prototype for 3D voxel-space object placement.
##
## This is intentionally independent from the heightfield fitting path:
## callers provide compact scene/collision field buffers and a simplified
## asset footprint, then receive compact placement records and stamped occupancy.

const TILE_SIZE := 8
const FOOTPRINT_CAPACITY := 128
const RECORD_STRIDE := 4
const DELTA_STRIDE := 2
const STAMP_BOUNDS_STRIDE := 2
const FLAG_SUPPORT := 1
const FLAG_CLEARANCE := 2
const NUM_DEBUG_CHANNELS := 8
const SCORE_CONTRACT_DEBUG_WORDS := 32
const SCORE_CONTRACT_MAGIC := 0x4D465052 # MFPR: MeshFill placement runtime/profile.
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
const CANDIDATE_REGION_BY_ASSET_CONFIG_KEYS := [
	"candidate_voxel_regions_by_asset",
	"candidate_voxel_sparses_by_asset",
]
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
	"collision_records",
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
	"collision_record_reads",
	"pivot_record_reads",
	"probe_weight_q1000",
	"collision_strength_q1000",
	"pivot_bias_q1000",
	"profile_probe_count",
	"profile_collision_count",
	"profile_pivot_count",
	"debug_max_target_coverage_q1000",
	"debug_max_target_complexity_fit_q1000",
	"debug_max_target_color_fit_q1000",
	"debug_max_target_density_q1000",
	"debug_max_placement_score_q1000",
	"debug_max_support_ratio_q1000",
	"debug_max_solid_collision_q1000",
	"debug_max_clearance_overlap_q1000",
	"reserved31",
]
const SCENE_VOXEL_COMMITTER_CONFIG_KEY := "scene_voxel_committer"
const PREVIOUS_SCENE_VOXEL_COMMITTER_CONFIG_KEY := "vegetation" + "_exclusion"
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
]

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
var _pipeline_score: RID
var _pipeline_reduce: RID
var _pipeline_init_stamp_bounds: RID
var _pipeline_stamp: RID


static func _get_config_voxel_write_spec(config: Dictionary) -> Dictionary:
	for key in AutoObject.voxel_write_spec_meta_keys():
		var raw_record = config.get(key, {})
		if raw_record is Dictionary:
			var record := raw_record as Dictionary
			if not record.is_empty():
				return record.duplicate(true)
	return {}


static func _should_create_voxel_write_spec(config: Dictionary) -> bool:
	return bool(config.get("create_voxel_write_spec", false))


static func _scene_voxel_committer_from_config(config: Dictionary):
	return config.get(SCENE_VOXEL_COMMITTER_CONFIG_KEY, config.get(PREVIOUS_SCENE_VOXEL_COMMITTER_CONFIG_KEY, null))


static func _has_candidate_regions_by_asset(settings: Dictionary) -> bool:
	for key in CANDIDATE_REGION_BY_ASSET_CONFIG_KEYS:
		if settings.get(key, null) is Dictionary:
			return true
	return false


static func _candidate_regions_by_asset_from_settings(settings: Dictionary) -> Dictionary:
	for key in CANDIDATE_REGION_BY_ASSET_CONFIG_KEYS:
		var value = settings.get(key, {})
		if value is Dictionary:
			return (value as Dictionary).duplicate(true)
	return {}


static func _candidate_route_readback_source_from_settings(settings: Dictionary) -> String:
	if _has_candidate_regions_by_asset(settings):
		return "gpu_vote_buffer_readback"
	return "none"


static func _candidate_route_runtime_read_source_from_settings(settings: Dictionary) -> String:
	if _has_candidate_regions_by_asset(settings):
		return "cpu_debug_bridge"
	return "none"


static func _candidate_route_input_contract_from_settings(settings: Dictionary) -> Dictionary:
	var has_cpu_route := _has_candidate_regions_by_asset(settings)
	var requested_readback := str(settings.get("candidate_route_readback_source", "none"))
	var requested_runtime := str(settings.get("candidate_route_runtime_read_source", "none"))
	var requested_resident_label := requested_readback != "none" or requested_runtime != "none"
	return {
		"route_input": "common_cpu_dictionary" if has_cpu_route else "none",
		"resident_route_input_ready": false,
		"resident_route_owner": "none",
		"resident_route_buffer_lifetime": "none",
		"resident_route_record_stride": 0,
		"resident_route_range_count": 0,
		"debug_snapshot_api": "none",
		"requested_readback_source": requested_readback,
		"requested_runtime_read_source": requested_runtime,
		"requested_source_labels_normalized": requested_resident_label,
		"normalized_readback_source": _candidate_route_readback_source_from_settings(settings),
		"normalized_runtime_read_source": _candidate_route_runtime_read_source_from_settings(settings),
	}


static func _full_field_readback_contract(voxel_count: int, output_source: String, is_gpu_readback: bool) -> Dictionary:
	var byte_count := maxi(voxel_count, 0) * 4
	return {
		"scene_field_out_source": output_source,
		"collision_field_out_source": output_source,
		"scene_field_out_is_full_field": true,
		"collision_field_out_is_full_field": true,
		"scene_field_out_byte_count": byte_count,
		"collision_field_out_byte_count": byte_count,
		"scene_field_out_gpu_storage_buffer_readback": is_gpu_readback,
		"collision_field_out_gpu_storage_buffer_readback": is_gpu_readback,
		"cpu_state_chaining": true,
	}


static func _has_asset_candidate_regions(asset_def: Dictionary) -> bool:
	for key in ASSET_CANDIDATE_REGION_CONFIG_KEYS:
		if asset_def.has(key):
			return true
	return false


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
#           scene_field_out, collision_field_out, total_placed,
#           processing_order: [original indices in execution order],
#           gpu_autoobject_runtime_writeback: optional runtime writeback report}

func run_multi_asset(
	scene_field: PackedFloat32Array,
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
			scene_field,
			collision_field,
			asset_defs,
			gpu_contract,
			common_settings
		)

	var current_scene := scene_field.duplicate()
	var current_collision := collision_field.duplicate()
	var total_placed := 0
	var global_quota := int(common_settings.get("global_quota", -1))

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
			var gpu_out := run_minimal(current_scene, current_collision, footprint, grid_size, per_asset_settings)
			if bool(gpu_out.get("contract_blocked", false)):
				return _gpu_contract_blocked_multi_asset_output(
					scene_field,
					collision_field,
					asset_defs,
					gpu_out.get("gpu_runtime_profile_contract", gpu_contract),
					common_settings
				)
			var pivot_score := _placement_output_score(gpu_out) + float(pivot.get("score_bias", 0.0))
			if not gpu_out.is_empty() and pivot_score > best_pivot_score:
				best_gpu_out = gpu_out
				best_pivot = pivot
				best_pivot_score = pivot_score

		if best_gpu_out.is_empty():
			result_by_index[orig_idx] = {
				"asset_index": orig_idx, "results": [], "world_results": [], "result_count": 0,
			}
			continue

		var count := int(best_gpu_out.get("result_count", 0))
		var raw_results: Array = best_gpu_out.get("results", [])
		var world := results_to_world(raw_results, voxel_size, grid_origin, 24, best_pivot)

		current_scene = best_gpu_out.get("scene_field_out", current_scene)
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
		if best_gpu_out.has("gpu_runtime_profile_contract"):
			asset_result["gpu_runtime_profile_contract"] = best_gpu_out.get("gpu_runtime_profile_contract", {})
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
		"scene_field_out": current_scene,
		"collision_field_out": current_collision,
		"total_placed": total_placed,
		"processing_order": order,
		"gpu_runtime_profile_contract": gpu_contract,
		"candidate_route_readback_source": _candidate_route_readback_source_from_settings(common_settings),
		"candidate_route_runtime_read_source": _candidate_route_runtime_read_source_from_settings(common_settings),
		"candidate_route_input_contract": _candidate_route_input_contract_from_settings(common_settings),
	}
	if write_accepted_placements_to_gpu_runtime:
		output["gpu_autoobject_runtime_writeback"] = runtime_writeback_report
	if not instance_stamp_writeback.is_empty():
		output["instance_stamp_writeback"] = instance_stamp_writeback
	if str(gpu_contract.get("reason", "")) != "not_requested":
		output["cpu_fallback"] = false
	return output


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


static func _runtime_writeback_mode_from_api(spawn_api: String, enabled: bool) -> String:
	if not enabled:
		return "not_requested"
	if spawn_api == "stage_command_flush_command_queue":
		return "cpu_dictionary_to_gpu_runtime_batched_command_queue"
	return "cpu_dictionary_to_gpu_runtime_spawn"


func _new_gpu_autoobject_runtime_writeback_report(
	runtime_provider: Object,
	profile_container: Object,
	gpu_contract: Dictionary,
	enabled: bool
) -> Dictionary:
	var runtime_summary := _object_summary(runtime_provider)
	var profile_summary := _object_summary(profile_container)
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
		"accepted_placement_record_stride_bytes": 0,
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"resident_gpu_allocator_record_stride_bytes": 0,
		"resident_gpu_allocator_owner": "none",
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
		"resident_gpu_allocator_record_stride_bytes",
		"resident_gpu_allocator_owner",
	]:
		if source.has(key):
			target[key] = source[key]
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


func _write_accepted_placements_to_scene_voxel_committer(
	asset_defs: Array,
	result_by_index: Dictionary,
	asset_results: Array[Dictionary],
	common_settings: Dictionary,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3
) -> Dictionary:
	var report := {
		"ok": true,
		"reason": "not_requested",
		"gpu_first": true,
		"cpu_fallback": false,
		"accepted_placement_writeback_mode": "cpu_dictionary_to_scene_voxel_committer",
		"accepted_placement_record_source": "cpu_instance_stamp_write_spec_dictionaries",
		"source_write_handoff_mode": "none",
		"source_write_batch_api": "none",
		"cpu_pending_source_candidate_bridge": false,
		"pending_source_candidate_flush_api": "none",
		"source_candidate_resolve_api": "none",
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
		"resident_source_candidate_staging_epoch": 0,
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"source_record_count": 0,
		"applied_count": 0,
		"failed_count": 0,
		"asset_reports": [],
	}
	for orig_idx in range(asset_defs.size()):
		var asset_def: Dictionary = asset_defs[orig_idx]
		var asset_result: Dictionary = result_by_index.get(orig_idx, {})
		if asset_result.is_empty() or int(asset_result.get("result_count", 0)) <= 0:
			continue
		var cfg := _runtime_voxel_write_spec_config(asset_def, common_settings, orig_idx, grid_size, voxel_size, grid_origin)
		var target = _scene_voxel_committer_from_config(cfg)
		var provided_record := _get_config_voxel_write_spec(cfg)
		var should_create := _should_create_voxel_write_spec(cfg) or not provided_record.is_empty()
		if target == null or not should_create:
			continue
		report["reason"] = "scene_voxel_committer_writeback_ready"
		var asset_report := _apply_asset_placements_to_scene_voxel_committer(
			target,
			asset_result,
			asset_def,
			cfg,
			orig_idx
		)
		(report["asset_reports"] as Array).append(asset_report)
		if (report["asset_reports"] as Array).size() == 1:
			for key in SCENE_VOXEL_SOURCE_WRITE_DIAGNOSTIC_KEYS:
				report[key] = asset_report.get(key, report.get(key))
		report["source_record_count"] = int(report.get("source_record_count", 0)) + int(asset_report.get("source_record_count", 0))
		report["applied_count"] = int(report.get("applied_count", 0)) + int(asset_report.get("applied_count", 0))
		report["failed_count"] = int(report.get("failed_count", 0)) + int(asset_report.get("failed_count", 0))
		if not bool(asset_report.get("ok", false)):
			report["ok"] = false
			report["reason"] = str(asset_report.get("reason", "scene_voxel_committer_writeback_failed"))
		asset_result["instance_stamp_writeback"] = asset_report
		if asset_report.has("instance_stamp_write_specs"):
			asset_result["instance_stamp_write_specs"] = asset_report.get("instance_stamp_write_specs", [])
		result_by_index[orig_idx] = asset_result
		if orig_idx < asset_results.size():
			asset_results[orig_idx] = asset_result
	if int(report.get("source_record_count", 0)) <= 0 and str(report.get("reason", "")) == "not_requested":
		return {}
	return report


func _apply_asset_placements_to_scene_voxel_committer(
	target: Object,
	asset_result: Dictionary,
	asset_def: Dictionary,
	cfg: Dictionary,
	asset_index: int
) -> Dictionary:
	var report := {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"asset_index": asset_index,
		"accepted_placement_writeback_mode": "cpu_dictionary_to_scene_voxel_committer",
		"accepted_placement_record_source": "cpu_instance_stamp_write_spec_dictionaries",
		"source_write_handoff_mode": "cpu_per_record_isws_source_apply",
		"source_write_batch_api": "none",
		"cpu_pending_source_candidate_bridge": false,
		"pending_source_candidate_flush_api": "none",
		"source_candidate_resolve_api": "none",
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
		"resident_source_candidate_staging_epoch": 0,
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"source_record_count": 0,
		"applied_count": 0,
		"failed_count": 0,
		"instance_stamp_write_specs": [],
		"apply_results": [],
	}
	if target == null:
		report["ok"] = false
		report["reason"] = "missing_scene_voxel_committer_write_target"
		return report

	var batch_method := ""
	if target.has_method("apply_instance_stamp_write_specs"):
		batch_method = "apply_instance_stamp_write_specs"
	elif target.has_method("apply_voxel_write_specs"):
		batch_method = "apply_voxel_write_specs"

	var apply_method := ""
	if target.has_method("apply_instance_stamp_write_spec"):
		apply_method = "apply_instance_stamp_write_spec"
	elif target.has_method("apply_voxel_write_spec"):
		apply_method = "apply_voxel_write_spec"
	if batch_method.is_empty() and apply_method.is_empty():
		report["ok"] = false
		report["reason"] = "missing_scene_voxel_committer_write_target"
		return report

	var world_results: Array = asset_result.get("world_results", [])
	var result_indices := _scene_voxel_source_write_result_indices(asset_result, world_results.size())
	var provided_record := _get_config_voxel_write_spec(cfg)
	var defer_blend := bool(cfg.get("defer_blend", false))
	var generation_tick := int(cfg.get("generation_tick", -1))
	for raw_i in result_indices:
		var i := int(raw_i)
		if i < 0 or i >= world_results.size():
			continue
		var world_result: Dictionary = world_results[i]
		var record := _runtime_placement_voxel_write_spec(world_result, asset_def, cfg, asset_index, i, provided_record)
		if record.is_empty():
			report["ok"] = false
			report["reason"] = "instance_stamp_write_spec_create_failed"
			report["failed_count"] = int(report.get("failed_count", 0)) + 1
			continue
		(report["instance_stamp_write_specs"] as Array).append(record)
		report["source_record_count"] = int(report.get("source_record_count", 0)) + 1

	if not batch_method.is_empty():
		report["source_write_handoff_mode"] = "cpu_batch_isws_pending_source_candidate_bridge"
		report["source_write_batch_api"] = batch_method
		report["cpu_pending_source_candidate_bridge"] = true
		report["pending_source_candidate_flush_api"] = "blend_scene_voxels->_flush_pending_scene_voxel_source_candidates"
		report["source_candidate_resolve_api"] = "resolve_scene_voxel_sources.glsl"
		var batch_result = target.call(batch_method, report.get("instance_stamp_write_specs", []), defer_blend, generation_tick)
		if batch_result is Dictionary:
			var batch_report := batch_result as Dictionary
			for key in SCENE_VOXEL_SOURCE_WRITE_DIAGNOSTIC_KEYS:
				report[key] = batch_report.get(key, report.get(key))
			var batch_apply_results: Array = batch_report.get("apply_results", [])
			for raw_applied in batch_apply_results:
				if raw_applied is Dictionary:
					(report["apply_results"] as Array).append((raw_applied as Dictionary).duplicate(true))
			report["applied_count"] = int(batch_report.get("applied_count", 0))
			report["failed_count"] = int(report.get("failed_count", 0)) + int(batch_report.get("failed_count", 0))
			if not bool(batch_report.get("ok", false)):
				report["ok"] = false
				report["reason"] = str(batch_report.get("reason", "scene_voxel_committer_batch_apply_failed"))
		else:
			report["ok"] = false
			report["reason"] = "scene_voxel_committer_batch_apply_failed"
			report["failed_count"] = int(report.get("failed_count", 0)) + int(report.get("source_record_count", 0))
	else:
		for record in report.get("instance_stamp_write_specs", []):
			var applied = target.call(apply_method, record, defer_blend, generation_tick)
			if applied is Dictionary and not (applied as Dictionary).is_empty():
				(report["apply_results"] as Array).append((applied as Dictionary).duplicate(true))
				report["applied_count"] = int(report.get("applied_count", 0)) + 1
			else:
				report["ok"] = false
				report["reason"] = "scene_voxel_committer_apply_failed"
				report["failed_count"] = int(report.get("failed_count", 0)) + 1
	if target.has_method("get_committed_tick"):
		report["committed_tick"] = int(target.call("get_committed_tick"))
	if target.has_method("get_voxel_write_spec_count"):
		report["committer_source_record_count"] = int(target.call("get_voxel_write_spec_count"))
	return report


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
	var record := provided_record.duplicate(true) if not provided_record.is_empty() else make_voxel_write_spec(world_result, null, record_cfg)
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
	var base_px := _placement_base_pixel(world_result, record_cfg, capture_size, resolution)
	record["base_pixel"] = base_px
	record["voxel_xz"] = base_px
	record["volume_xz_resolution"] = resolution
	if not record.has("collision") and asset_def.has("collision"):
		record["collision"] = asset_def.get("collision", [])
	return record


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
		"accepted_placement_record_stride_bytes": 0,
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"resident_gpu_allocator_record_stride_bytes": 0,
		"resident_gpu_allocator_owner": "none",
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
	if not _object_bool(runtime_provider, "is_gpu_ready", "is_ready"):
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
		for i in range(spawn_records.size()):
			var command := spawn_records[i].duplicate(true)
			command["command"] = "spawn"
			var raw_stage_result = runtime_provider.call("stage_command", command)
			if raw_stage_result is Dictionary:
				var stage_result := (raw_stage_result as Dictionary).duplicate(true)
				stage_reports.append(stage_result)
				if bool(stage_result.get("ok", false)):
					staged_records.append(command)
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

		if not staged_records.is_empty():
			var raw_flush_result = runtime_provider.call("flush_command_queue")
			if raw_flush_result is Dictionary:
				var flush_result := (raw_flush_result as Dictionary).duplicate(true)
				report["runtime_command_queue_flush_report"] = flush_result
				report["command_queue_flush_count"] = 1
				if not bool(flush_result.get("ok", false)):
					report["ok"] = false
					report["reason"] = "runtime_spawn_failed"
					if not report.has("writeback_detail_reason"):
						report["writeback_detail_reason"] = str(flush_result.get("reason", "flush_command_queue_failed"))
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
	else:
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

	var runtime_summary := _object_summary(runtime_provider)
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


static func _runtime_writeback_dirty_flags(asset_def: Dictionary, per_asset_settings: Dictionary, common_settings: Dictionary) -> Dictionary:
	var flags := {"auto": true, "object_refs": true}
	_runtime_writeback_merge_flags(flags, common_settings.get("runtime_writeback_dirty_flags", {}))
	_runtime_writeback_merge_flags(flags, asset_def.get("runtime_writeback_dirty_flags", {}))
	_runtime_writeback_merge_flags(flags, per_asset_settings.get("runtime_writeback_dirty_flags", {}))
	return flags


static func _runtime_writeback_merge_flags(target: Dictionary, source) -> void:
	if not (source is Dictionary):
		return
	for key in (source as Dictionary).keys():
		target[key] = bool((source as Dictionary)[key])


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


static func _runtime_writeback_transform(world_result: Dictionary) -> Transform3D:
	var position: Vector3 = world_result.get("position", Vector3.ZERO)
	var rotation_degrees: Vector3 = world_result.get("rotation_degrees", Vector3.ZERO)
	var yaw := deg_to_rad(float(rotation_degrees.y))
	return Transform3D(Basis.from_euler(Vector3(0.0, yaw, 0.0)), position)


func validate_gpu_runtime_profile_contract(settings: Dictionary) -> Dictionary:
	return _validate_gpu_runtime_profile_contract(settings)


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
		entry["local_pos"] = _vector3i_from_value(entry.get("local_pos", Vector3i.ZERO), Vector3i.ZERO) - pivot_voxels
		shifted.append(entry)
	return shifted


static func _world_offset_to_voxels(offset: Vector3, voxel_size: Vector3) -> Vector3i:
	return Vector3i(
		roundi(offset.x / maxf(voxel_size.x, 0.0001)),
		roundi(offset.y / maxf(voxel_size.y, 0.0001)),
		roundi(offset.z / maxf(voxel_size.z, 0.0001))
	)


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


# ---------------------------------------------------------------------------
# Instantiation — create AutoObject nodes from GPU placement results
# ---------------------------------------------------------------------------
# node_class: "canopy_tree", "midstory_tree", "bush", "grass", "rock", "vegetation"

static func instantiate_placement(
	world_result: Dictionary,
	node_class: String,
	placement_mesh: Mesh,
	extra_config: Dictionary = {}
) -> AutoObject:
	var node: AutoObject = _create_node_for_class(node_class)
	var cfg := extra_config.duplicate(true)

	cfg["position"] = world_result.get("position", Vector3.ZERO)
	cfg["rotation_mode"] = "Y"
	cfg["rotation_degrees"] = world_result.get("rotation_degrees", Vector3.ZERO)
	cfg["scale"] = world_result.get("scale", Vector3.ONE)
	cfg["mesh"] = placement_mesh
	cfg["auto_source"] = "voxel_placement"

	if not cfg.has("name"):
		cfg["name"] = "%s_%d" % [node_class, int(world_result.get("asset_index", 0))]

	var asset = cfg.get("asset", null)
	if node is AutoRock and asset is AutoRock:
		(node as AutoRock).configure_from_rock_asset(asset as AutoRock, cfg)
	else:
		_configure_node(node, node_class, cfg)

	var record := _get_config_voxel_write_spec(cfg)
	if not record.is_empty():
		record = attach_placement_voxel_write_spec(node, record)
	elif _should_create_voxel_write_spec(cfg):
		record = make_placement_voxel_write_spec(node, world_result, node_class, cfg)
		if not record.is_empty():
			record = attach_placement_voxel_write_spec(node, record)

	var target = _scene_voxel_committer_from_config(cfg)
	if not record.is_empty() and target != null and (target.has_method("apply_instance_stamp_write_spec") or target.has_method("apply_voxel_write_spec")):
		var apply_method := "apply_instance_stamp_write_spec" if target.has_method("apply_instance_stamp_write_spec") else "apply_voxel_write_spec"
		var applied: Dictionary = target.call(
			apply_method,
			record,
			bool(cfg.get("defer_blend", false)),
			int(cfg.get("generation_tick", -1))
		)
		if not applied.is_empty():
			attach_placement_voxel_write_spec(node, applied)
	return node


static func instantiate_placements(
	world_results: Array,
	node_class: String,
	placement_mesh: Mesh,
	extra_config: Dictionary = {}
) -> Array[AutoObject]:
	var nodes: Array[AutoObject] = []
	for i in range(world_results.size()):
		var cfg := extra_config.duplicate(true)
		cfg["name"] = "%s_%d" % [node_class, i]
		var node := instantiate_placement(world_results[i], node_class, placement_mesh, cfg)
		nodes.append(node)
	return nodes


static func make_placement_voxel_write_spec(
	node: AutoObject,
	world_result: Dictionary,
	node_class: String,
	record_config: Dictionary = {}
) -> Dictionary:
	if node == null:
		return {}

	var resolution := maxi(int(record_config.get("volume_xz_resolution", record_config.get("texture_resolution", 256))), 1)
	var capture := float(record_config.get("capture_size", record_config.get("world_capture_size", float(resolution))))
	if capture <= 0.0:
		capture = float(resolution)
	var base_px := _placement_base_pixel(world_result, record_config, capture, resolution)
	var record_id := str(record_config.get("record_id", record_config.get("id", node.name)))
	if record_id.is_empty():
		record_id = "%s_%d" % [node_class, int(world_result.get("asset_index", 0))]

	var fields := _placement_record_extra_fields(node, world_result, node_class, record_config)
	var record := node.make_instance_stamp_write_spec(
		record_id,
		base_px,
		resolution,
		fields
	)
	record["rotation_mode"] = str(world_result.get("rotation_mode", record_config.get("rotation_mode", "Y"))).to_upper()
	record["rotation_degrees"] = world_result.get("rotation_degrees", node.rotation_degrees)
	record["mesh_name"] = node.name
	return record


static func attach_placement_voxel_write_spec(node: AutoObject, record: Dictionary) -> Dictionary:
	if node == null or record.is_empty():
		return {}
	var rec := record.duplicate(true)
	node.refresh_bound_spacing()
	var instance_id := node.refresh_instance_id()
	var record_id := str(rec.get("id", node.name))
	if record_id.is_empty():
		record_id = node.name
	rec["id"] = record_id
	rec["mesh_name"] = node.name
	rec["position"] = node.position
	rec["scale"] = node.scale
	rec["rotation_degrees"] = rec.get("rotation_degrees", node.rotation_degrees)
	rec["instance_id"] = instance_id
	rec["auto_instance_id"] = instance_id
	if node.auto_id.is_empty():
		node.auto_id = record_id
	rec["auto_id"] = node.auto_id
	rec["auto_object_id"] = node.auto_id
	rec["instance_mesh_id"] = instance_id
	rec["mesh_instance_id"] = instance_id
	if not rec.has("auto_source"):
		rec["auto_source"] = node.get_record_auto_source("voxel_placement")
	if not rec.has("object_type"):
		rec["object_type"] = node.get_record_object_type()
	if not rec.has("object_subtype"):
		var node_subtype := node.get_record_object_subtype()
		if not node_subtype.is_empty():
			rec["object_subtype"] = node_subtype
	if node.is_inside_tree():
		rec["node_path"] = str(node.get_path())
	node.set_instance_stamp_write_spec(rec)
	return node.get_instance_stamp_write_spec()


static func world_to_texture_pixel(
	world_pos: Vector3,
	capture_size: float,
	resolution: int
) -> Vector2i:
	var res := maxi(resolution, 1)
	var size := maxf(capture_size, 0.0001)
	var half := size * 0.5
	var px := clampi(floori((world_pos.x + half) / size * float(res)), 0, res - 1)
	var pz := clampi(floori((world_pos.z + half) / size * float(res)), 0, res - 1)
	return Vector2i(px, pz)


static func world_to_volume_pixel(
	world_pos: Vector3,
	resolution: int,
	p_grid_origin: Vector3,
	p_voxel_size: Vector3
) -> Vector2i:
	var res := maxi(resolution, 1)
	var safe_voxel_size := Vector3(
		maxf(p_voxel_size.x, 0.0001),
		maxf(p_voxel_size.y, 0.0001),
		maxf(p_voxel_size.z, 0.0001)
	)
	var local := world_pos - p_grid_origin
	return Vector2i(
		clampi(floori(local.x / safe_voxel_size.x), 0, res - 1),
		clampi(floori(local.z / safe_voxel_size.z), 0, res - 1)
	)


static func _placement_base_pixel(
	world_result: Dictionary,
	record_config: Dictionary,
	capture_size: float,
	resolution: int
) -> Vector2i:
	var raw_base = record_config.get("base_pixel", world_result.get("base_pixel", null))
	if raw_base is Vector2i:
		return raw_base as Vector2i
	if raw_base is Vector2:
		var v := raw_base as Vector2
		return Vector2i(roundi(v.x), roundi(v.y))
	if raw_base is Array:
		var arr := raw_base as Array
		if arr.size() >= 2:
			return Vector2i(int(arr[0]), int(arr[1]))
	var world_pos: Vector3 = world_result.get("position", Vector3.ZERO)
	var target = _scene_voxel_committer_from_config(record_config)
	if target != null and target.has_method("world_to_volume_pixel"):
		return target.call("world_to_volume_pixel", world_pos, resolution)
	if record_config.has("grid_origin") or record_config.has("voxel_size"):
		var fallback_voxel_size := Vector3(
			capture_size / float(maxi(resolution, 1)),
			1.0,
			capture_size / float(maxi(resolution, 1))
		)
		var fallback_grid_origin := Vector3(-capture_size * 0.5, 0.0, -capture_size * 0.5)
		return world_to_volume_pixel(
			world_pos,
			resolution,
			_vector3_from_value(record_config.get("grid_origin", fallback_grid_origin), fallback_grid_origin),
			_vector3_from_value(record_config.get("voxel_size", fallback_voxel_size), fallback_voxel_size)
		)
	return world_to_texture_pixel(world_pos, capture_size, resolution)


static func _placement_record_extra_fields(
	node: AutoObject,
	world_result: Dictionary,
	node_class: String,
	record_config: Dictionary
) -> Dictionary:
	var fields := {}
	for key in record_config.keys():
		if VOXEL_WRITE_SPEC_CONFIG_KEYS.has(key) or AutoObject.voxel_write_spec_meta_keys().has(key):
			continue
		fields[key] = record_config[key]

	fields["auto_source"] = str(record_config.get("auto_source", node.get_record_auto_source("voxel_placement")))
	fields["placement_source"] = "voxel_placement"
	fields["source_voxel_type"] = str(record_config.get("source_voxel_type", "AutoSceneVoxel"))
	var node_subtype := node.get_record_object_subtype()
	fields["object_subtype"] = node_subtype if not node_subtype.is_empty() else node_class
	fields["asset_index"] = int(world_result.get("asset_index", record_config.get("asset_index", 0)))
	fields["rotation_index"] = int(world_result.get("rotation_index", record_config.get("rotation_index", 0)))
	fields["scale_index"] = int(world_result.get("scale_index", record_config.get("scale_index", 0)))
	fields["voxel_origin"] = world_result.get("voxel_origin", Vector3i.ZERO)

	for debug_key in [
		"score",
		"support_ratio",
		"solid_collision",
		"scene_overlap",
		"clearance_overlap",
		"ignored_sample",
	]:
		if world_result.has(debug_key):
			fields[debug_key] = world_result[debug_key]
	if node is AutoRock:
		fields["mesh_index"] = int((node as AutoRock).mesh_index)
	return fields


static func _create_node_for_class(node_class: String) -> AutoObject:
	match node_class:
		"canopy_tree", "midstory_tree", "bush", "grass":
			return AutoObject.new()
		"rock", "cliff":
			return AutoRock.new()
		_:
			return AutoObject.new()


static func _configure_node(node: AutoObject, node_class: String, cfg: Dictionary) -> void:
	match node_class:
		"canopy_tree":
			cfg["object_subtype"] = "canopy_tree"
			cfg["object_type"] = "vegetation"
			if not cfg.has("group"):
				cfg["group"] = "placed_canopy_trees"
			node.configure_auto_object(cfg)
		"midstory_tree":
			cfg["object_subtype"] = "midstory_tree"
			cfg["object_type"] = "vegetation"
			if not cfg.has("group"):
				cfg["group"] = "placed_midstory_trees"
			node.configure_auto_object(cfg)
		"bush":
			cfg["object_subtype"] = "bush"
			cfg["object_type"] = "vegetation"
			if not cfg.has("group"):
				cfg["group"] = "placed_bushes"
			node.configure_auto_object(cfg)
		"grass":
			cfg["object_subtype"] = "grass"
			cfg["object_type"] = "vegetation"
			if not cfg.has("group"):
				cfg["group"] = "placed_grass"
			node.configure_auto_object(cfg)
		"rock", "cliff":
			cfg["object_subtype"] = node_class
			(node as AutoRock).configure_rock(cfg)
		_:
			node.configure_auto_object(cfg)


func run_minimal(
	scene_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	footprint: Array,
	grid_size: Vector3i,
	settings: Dictionary = {}
) -> Dictionary:
	_apply_settings(settings)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	if voxel_count <= 0:
		push_error("VoxelPlacementGenerator: grid_size must be positive")
		return {}
	if footprint.is_empty():
		push_error("VoxelPlacementGenerator: footprint must not be empty")
		return {}
	if footprint.size() > FOOTPRINT_CAPACITY:
		push_error("VoxelPlacementGenerator: footprint is limited to %d voxels" % FOOTPRINT_CAPACITY)
		return {}

	var scene_data := _normalize_float_array(scene_field, voxel_count)
	var collision_data := _normalize_float_array(collision_field, voxel_count)
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
			scene_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids,
			gpu_contract
		)
	if candidate_voxel_sparse_count <= 0:
		return _empty_prefilter_output(
			scene_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids
		)

	log_name = "VoxelPlacementGenerator"
	sync_global_device = true
	if not _ensure_placement_rendering_device():
		return _gpu_contract_blocked_minimal_output(
			scene_data,
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
			scene_data,
			collision_data,
			voxel_count,
			tile_count,
			tile_counts,
			candidate_voxel_sparse_ids,
			_gpu_contract_result(false, "placement_shader_pipeline_not_ready")
		)

	var candidate_count := candidate_voxel_sparse_count * top_k
	var stamp_capacity := result_capacity * footprint.size()

	var scene_buffer := storage_buffer_from_floats(scene_data)
	var collision_buffer := storage_buffer_from_floats(collision_data)
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

	var target_occupancy_pack := _target_occupancy_bytes_from_settings(settings, voxel_count)
	var has_target := 1 if bool(target_occupancy_pack.get("has_target", false)) else 0
	var target_buffer := storage_buffer_from_bytes(target_occupancy_pack.get("bytes", PackedByteArray()))

	var target_color_buffer := storage_buffer_from_bytes(
		_target_color_rgba8_bytes_from_settings(settings, voxel_count)
	)

	var debug_voxel_buffer := storage_buffer_zero(voxel_count * NUM_DEBUG_CHANNELS * 4)
	var score_contract_debug_buffer := storage_buffer_from_bytes(_pack_score_contract_debug_reset())

	_dispatch_score(
		scene_buffer,
		collision_buffer,
		footprint_pos_buffer,
		footprint_weight_buffer,
		candidate_voxel_sparse_buffer,
		tile_topk_buffer,
		target_buffer,
		target_color_buffer,
		debug_voxel_buffer,
		score_contract_debug_buffer,
		grid_size,
		tile_counts,
		tile_count,
		candidate_voxel_sparse_count,
		direct_all_tiles,
		footprint.size(),
		has_target,
		gpu_contract,
		settings
	)
	_dispatch_reduce(tile_topk_buffer, result_buffer, result_count_buffer, candidate_count)
	_dispatch_stamp(
		scene_buffer,
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
	var scene_out_data := _rd.buffer_get_data(scene_buffer)
	var collision_out_data := _rd.buffer_get_data(collision_buffer)
	var stamp_delta_count_data := _rd.buffer_get_data(stamp_delta_count_buffer)
	var stamp_delta_count := clampi(_decode_u32_count(stamp_delta_count_data), 0, stamp_capacity)
	var read_stamp_deltas := bool(settings.get("read_stamp_deltas", false))
	var stamp_delta_data := _rd.buffer_get_data(stamp_delta_buffer, 0, stamp_delta_count * DELTA_STRIDE * 16) if read_stamp_deltas else PackedByteArray()
	var stamp_bounds_data := _rd.buffer_get_data(stamp_bounds_buffer, 0, result_count * STAMP_BOUNDS_STRIDE * 16)
	var read_debug_voxel := bool(settings.get("read_debug_voxel", false))
	var debug_voxel_data := _rd.buffer_get_data(debug_voxel_buffer) if read_debug_voxel else PackedByteArray()
	var score_contract_debug_data := _rd.buffer_get_data(score_contract_debug_buffer)
	var score_contract_debug := _decode_score_contract_debug(score_contract_debug_data)
	gpu_contract = _annotate_score_contract_debug(gpu_contract, score_contract_debug)
	if not bool(gpu_contract.get("ok", true)):
		var blocked_output := _gpu_contract_blocked_minimal_output(
			scene_data,
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

	var full_field_readback := _full_field_readback_contract(voxel_count, "scene_collision_storage_buffer_full_field_readback", true)
	var output := {
		"result_count": result_count,
		"result_readback_bytes": result_readback_bytes,
		"result_readback_count_source": "reduce_shader_result_count_buffer",
		"results": _decode_records(result_data, result_count),
		"tile_topk": _decode_records(tile_topk_data, candidate_count) if read_tile_topk else [],
		"tile_topk_readback_source": "score_shader_tile_topk_buffer" if read_tile_topk else "disabled",
		"scene_field_out": _decode_float_array(scene_out_data, voxel_count),
		"collision_field_out": _decode_float_array(collision_out_data, voxel_count),
		"scene_field_out_source": full_field_readback.get("scene_field_out_source", ""),
		"collision_field_out_source": full_field_readback.get("collision_field_out_source", ""),
		"scene_field_out_byte_count": full_field_readback.get("scene_field_out_byte_count", 0),
		"collision_field_out_byte_count": full_field_readback.get("collision_field_out_byte_count", 0),
		"full_field_readback": full_field_readback,
		"stamp_deltas": _decode_stamp_deltas(stamp_delta_data, stamp_delta_count) if read_stamp_deltas else [],
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
		"candidate_count": candidate_count,
		"gpu_runtime_profile_contract": gpu_contract,
		"gpu_runtime_profile_binding_debug": score_contract_debug,
	}
	if str(gpu_contract.get("reason", "")) != "not_requested":
		output["cpu_fallback"] = false

	_free_gpu()
	return output


func _gpu_contract_blocked_multi_asset_output(
	scene_field: PackedFloat32Array,
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
		"scene_field_out": scene_field.duplicate(),
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


func _gpu_contract_blocked_minimal_output(
	scene_data: PackedFloat32Array,
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
		"scene_field_out": scene_data,
		"collision_field_out": collision_data,
		"scene_field_out_source": full_field_readback.get("scene_field_out_source", ""),
		"collision_field_out_source": full_field_readback.get("collision_field_out_source", ""),
		"scene_field_out_byte_count": full_field_readback.get("scene_field_out_byte_count", 0),
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


func _empty_prefilter_output(
	scene_data: PackedFloat32Array,
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
		"scene_field_out": scene_data,
		"collision_field_out": collision_data,
		"scene_field_out_source": full_field_readback.get("scene_field_out_source", ""),
		"collision_field_out_source": full_field_readback.get("collision_field_out_source", ""),
		"scene_field_out_byte_count": full_field_readback.get("scene_field_out_byte_count", 0),
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


func _ensure_placement_rendering_device() -> bool:
	if get_rendering_device() != null:
		return true
	var local_rd := RenderingServer.create_local_rendering_device()
	if local_rd != null:
		return attach_rendering_device(local_rd, true)
	var global_rd := RenderingServer.get_rendering_device()
	if global_rd != null:
		return attach_rendering_device(global_rd, false)
	return false


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

	var runtime_rd: RenderingDevice = _object_rendering_device(runtime_provider)
	var profile_rd: RenderingDevice = _object_rendering_device(profile_container)
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
	return result


func _first_config_object(settings: Dictionary, keys: Array) -> Object:
	for key in keys:
		if settings.has(key):
			var value = settings.get(key)
			if value is Object:
				return value as Object
	return null


func _object_bool(object: Object, primary_method: String, secondary_method: String = "") -> bool:
	if object == null:
		return false
	if object.has_method(primary_method):
		return bool(object.call(primary_method))
	if not secondary_method.is_empty() and object.has_method(secondary_method):
		return bool(object.call(secondary_method))
	return false


func _object_rendering_device(object: Object) -> RenderingDevice:
	if object != null and object.has_method("get_rendering_device"):
		return object.call("get_rendering_device")
	return null


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


func _track_borrowed_gpu_buffers(buffers: Dictionary, label_prefix: String) -> void:
	for buffer_name in buffers.keys():
		var rid: RID = buffers[buffer_name]
		if rid.is_valid():
			track_borrowed_rid(rid, KIND_BUFFER, SCOPE_FRAME, "%s:%s" % [label_prefix, str(buffer_name)])


func _load_shaders() -> void:
	_shader_score = load_compute_shader("res://shaders/score_voxel_tile.glsl")
	_shader_reduce = load_compute_shader("res://shaders/reduce_voxel_tiles.glsl")
	_shader_init_stamp_bounds = load_compute_shader("res://shaders/init_stamp_bounds.glsl")
	_shader_stamp = load_compute_shader("res://shaders/stamp_voxel_field.glsl")
	if _shader_score.is_valid():
		_pipeline_score = create_compute_pipeline(_shader_score)
	if _shader_reduce.is_valid():
		_pipeline_reduce = create_compute_pipeline(_shader_reduce)
	if _shader_init_stamp_bounds.is_valid():
		_pipeline_init_stamp_bounds = create_compute_pipeline(_shader_init_stamp_bounds)
	if _shader_stamp.is_valid():
		_pipeline_stamp = create_compute_pipeline(_shader_stamp)


func _placement_pipeline_ready() -> bool:
	return _shader_score.is_valid() \
		and _shader_reduce.is_valid() \
		and _shader_init_stamp_bounds.is_valid() \
		and _shader_stamp.is_valid() \
		and _pipeline_score.is_valid() \
		and _pipeline_reduce.is_valid() \
		and _pipeline_init_stamp_bounds.is_valid() \
		and _pipeline_stamp.is_valid()


func _free_gpu() -> void:
	dispose()
	_pipeline_score = RID()
	_pipeline_reduce = RID()
	_pipeline_init_stamp_bounds = RID()
	_pipeline_stamp = RID()
	_shader_score = RID()
	_shader_reduce = RID()
	_shader_init_stamp_bounds = RID()
	_shader_stamp = RID()


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


func _uses_direct_all_tile_candidates(settings: Dictionary) -> bool:
	for key in ASSET_CANDIDATE_REGION_CONFIG_KEYS:
		if settings.has(key):
			return false
	return true


static func _voxel_sparse_to_tile_id(region: Variant, tile_counts: Vector3i) -> int:
	if region is Vector3i:
		return region.x + tile_counts.x * (region.y + tile_counts.y * region.z)
	if region is Vector3:
		var v := Vector3i(int(region.x), int(region.y), int(region.z))
		return v.x + tile_counts.x * (v.y + tile_counts.y * v.z)
	return int(region)


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


func _dispatch_score(
	scene_buffer: RID,
	collision_buffer: RID,
	footprint_pos_buffer: RID,
	footprint_weight_buffer: RID,
	candidate_voxel_sparse_buffer: RID,
	tile_topk_buffer: RID,
	target_buffer: RID,
	target_color_buffer: RID,
	debug_voxel_buffer: RID,
	score_contract_debug_buffer: RID,
	grid_size: Vector3i,
	tile_counts: Vector3i,
	tile_count: int,
	candidate_voxel_sparse_count: int,
	direct_all_tiles: bool,
	footprint_count: int,
	has_target: int,
	gpu_contract: Dictionary,
	settings: Dictionary
) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, scene_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, footprint_pos_buffer),
		make_storage_uniform(3, footprint_weight_buffer),
		make_storage_uniform(4, tile_topk_buffer),
		make_storage_uniform(5, candidate_voxel_sparse_buffer),
		make_storage_uniform(6, target_buffer),
		make_storage_uniform(7, target_color_buffer),
		make_storage_uniform(8, debug_voxel_buffer),
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
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, candidate_voxel_sparse_count, 1, 1)
	end_compute_list()


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
	var collision_records_buffer: RID = _gpu_buffer_or_dummy(profile_buffers, "collision_records", dummy_buffer)
	var pivot_records_buffer: RID = _gpu_buffer_or_dummy(profile_buffers, "pivot_records", dummy_buffer)
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
		make_storage_uniform(10, collision_records_buffer),
		make_storage_uniform(11, pivot_records_buffer),
	], _shader_score, 1, SCOPE_PASS, "score_runtime_profile_contract")


func _gpu_buffer_or_dummy(buffers: Dictionary, buffer_name: String, dummy_buffer: RID) -> RID:
	var value = buffers.get(buffer_name, RID())
	if value is RID:
		var rid: RID = value
		if rid.is_valid():
			return rid
	return dummy_buffer


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
	var collision_record_count := int((profile_buffers.get("collision_records", {}) as Dictionary).get("record_count", 0)) if profile_buffers.has("collision_records") else 0
	var pivot_record_count := int((profile_buffers.get("pivot_records", {}) as Dictionary).get("record_count", 0)) if profile_buffers.has("pivot_records") else 0
	var asset_profile_id := int(settings.get(
		"profile_id",
		settings.get(
			"auto_voxel_profile_id",
			settings.get("runtime_profile_id", settings.get("asset_profile_id", 0))
		)
	))
	var bytes := PackedByteArray()
	bytes.resize(64)
	bytes.encode_s32(0, 1 if contract_enabled else 0)
	bytes.encode_s32(4, runtime_capacity)
	bytes.encode_s32(8, profile_count)
	bytes.encode_s32(12, asset_profile_id)
	bytes.encode_s32(16, 1 if bool(settings.get("score_runtime_profile_avoidance", true)) else 0)
	bytes.encode_s32(20, 1 if bool(settings.get("score_profile_complexity_debug", true)) else 0)
	bytes.encode_s32(24, 0)
	bytes.encode_s32(28, 0)
	bytes.encode_s32(32, probe_record_count)
	bytes.encode_s32(36, collision_record_count)
	bytes.encode_s32(40, pivot_record_count)
	bytes.encode_s32(44, 0)
	return bytes


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
		"collision_record_reads": int(words[15]),
		"pivot_record_reads": int(words[16]),
		"probe_weight": float(words[17]) / 1000.0,
		"collision_strength": float(words[18]) / 1000.0,
		"pivot_bias": float(words[19]) / 1000.0,
		"profile_probe_count": int(words[20]),
		"profile_collision_count": int(words[21]),
		"profile_pivot_count": int(words[22]),
		"debug_channel_max": debug_channel_max,
		"debug_channel_max_source": "score_shader_storage_buffer",
	}


func _pack_score_contract_debug_reset() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(SCORE_CONTRACT_DEBUG_WORDS * 4)
	bytes.encode_u32(0, SCORE_CONTRACT_MAGIC)
	return bytes


func _annotate_score_contract_debug(gpu_contract: Dictionary, score_contract_debug: Dictionary) -> Dictionary:
	var annotated := gpu_contract.duplicate(true)
	if str(annotated.get("reason", "")) == "gpu_runtime_profile_buffers_ready":
		var runtime_summary: Dictionary = annotated.get("runtime_summary", {})
		var runtime_live_count := int(runtime_summary.get("live_count", 0))
		var consumed_profile_side_buffers := (
			(int(score_contract_debug.get("profile_probe_count", 0)) <= 0 or int(score_contract_debug.get("probe_record_reads", 0)) > 0)
			and (int(score_contract_debug.get("profile_collision_count", 0)) <= 0 or int(score_contract_debug.get("collision_record_reads", 0)) > 0)
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
		annotated["score_shader_collision_record_reads"] = int(score_contract_debug.get("collision_record_reads", 0))
		annotated["score_shader_pivot_record_reads"] = int(score_contract_debug.get("pivot_record_reads", 0))
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


func _dispatch_stamp(
	scene_buffer: RID,
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
		make_storage_uniform(0, scene_buffer),
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
	push.resize(64)
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


func _pack_footprint(footprint: Array) -> Dictionary:
	var pos_bytes := PackedByteArray()
	var weight_bytes := PackedByteArray()
	pos_bytes.resize(footprint.size() * 16)
	weight_bytes.resize(footprint.size() * 16)

	for i in range(footprint.size()):
		var entry: Dictionary = footprint[i]
		var local_pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var collision_q8 := clampi(roundi(clampf(float(entry.get("collision_strength", 0.0)), 0.0, 1.0) * 255.0), 0, 255)
		var flags := int(entry.get("flags", 0))
		var weight := maxf(float(entry.get("weight", 1.0)), 0.0)
		var pos_offset := i * 16
		pos_bytes.encode_s32(pos_offset + 0, local_pos.x)
		pos_bytes.encode_s32(pos_offset + 4, local_pos.y)
		pos_bytes.encode_s32(pos_offset + 8, local_pos.z)
		pos_bytes.encode_s32(pos_offset + 12, collision_q8)
		weight_bytes.encode_float(pos_offset + 0, weight)
		weight_bytes.encode_float(pos_offset + 4, float(flags))
		weight_bytes.encode_float(pos_offset + 8, float(entry.get("radius", 0.0)))
		weight_bytes.encode_float(pos_offset + 12, 0.0)
	return {
		"pos_bytes": pos_bytes,
		"weight_bytes": weight_bytes,
	}


func _normalize_float_array(values: PackedFloat32Array, expected_size: int) -> PackedFloat32Array:
	var result := values.duplicate()
	result.resize(expected_size)
	return result


func _decode_float_array(bytes: PackedByteArray, value_count: int) -> PackedFloat32Array:
	var available_bytes := mini(bytes.size(), value_count * 4)
	available_bytes -= available_bytes % 4
	var values := bytes.slice(0, available_bytes).to_float32_array()
	values.resize(value_count)
	return values


func _decode_u32_count(bytes: PackedByteArray) -> int:
	if bytes.size() < 4:
		return 0
	return int(bytes.decode_u32(0))


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
			"scene_overlap": debug0.z,
			"clearance_overlap": debug0.w,
			"ignored_sample": debug1.x,
			"valid": debug1.y > 0.5,
			"support_hit": debug1.z,
			"support_total": debug1.w,
		})
	return records


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


static func _pack_color_rgba8(c: Color) -> int:
	var r := clampi(int(roundf(c.r * 255.0)), 0, 255)
	var g := clampi(int(roundf(c.g * 255.0)), 0, 255)
	var b := clampi(int(roundf(c.b * 255.0)), 0, 255)
	var a := clampi(int(roundf(c.a * 255.0)), 0, 255)
	return (r << 24) | (g << 16) | (b << 8) | a


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


func _target_occupancy_bytes_from_settings(settings: Dictionary, voxel_count: int) -> Dictionary:
	var expected_bytes := maxi(voxel_count, 1) * 4
	var prepacked: PackedByteArray = settings.get("target_occupancy_bytes", PackedByteArray())
	if prepacked.size() >= expected_bytes:
		return {
			"bytes": prepacked if prepacked.size() == expected_bytes else prepacked.slice(0, expected_bytes),
			"has_target": true,
			"source": "target_occupancy_bytes",
		}

	var bytes := PackedByteArray()
	bytes.resize(expected_bytes)
	return {
		"bytes": bytes,
		"has_target": false,
		"source": "none",
	}


static func get_debug_channel(debug_voxel: PackedFloat32Array, channel: int, voxel_count: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(voxel_count)
	if channel < 0 or channel >= NUM_DEBUG_CHANNELS:
		return result
	for i in range(mini(voxel_count, debug_voxel.size() / NUM_DEBUG_CHANNELS)):
		result[i] = debug_voxel[i * NUM_DEBUG_CHANNELS + channel]
	return result


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


func voxel_index(p: Vector3i, grid_size: Vector3i) -> int:
	return p.x + grid_size.x * (p.z + grid_size.z * p.y)


# ---------------------------------------------------------------------------
# Footprint baking: collision -> GPU footprint array
# ---------------------------------------------------------------------------

static func bake_footprint_from_collision(
	collision_layers: Array,
	voxel_size: Vector3,
	add_support: bool = true,
	clearance_slices: int = 1
) -> Array[Dictionary]:
	var combined: Array[Dictionary] = []
	var point_samples: Array[Dictionary] = []
	for cv in collision_layers:
		if not cv is Dictionary:
			continue
		var collision_entry := cv as Dictionary
		if _is_point_collision_sample(collision_entry):
			point_samples.append(collision_entry)
			continue
		var shape := str(collision_entry.get("shape", "cylinder")).to_lower()
		if shape == "cylinder":
			combined.append_array(
				_bake_cylinder(collision_entry, voxel_size, add_support, clearance_slices))
		elif shape == "box" or shape == "cube":
			combined.append_array(
				_bake_box(collision_entry, voxel_size, add_support, clearance_slices))
	if not point_samples.is_empty():
		combined.append_array(_bake_point_collision(point_samples, add_support, clearance_slices))
	var result := _deduplicate_footprint(combined)
	if result.size() > FOOTPRINT_CAPACITY:
		push_warning("VoxelPlacementGenerator: footprint has %d voxels, truncating to %d" % [
			result.size(), FOOTPRINT_CAPACITY])
		result.resize(FOOTPRINT_CAPACITY)
	return result


static func bake_box_footprint_gpu(
	collision_entry: Dictionary,
	voxel_size: Vector3,
	add_support: bool = true,
	clearance_slices: int = 1
) -> Dictionary:
	var generator := VoxelPlacementGenerator.new()
	return generator._bake_box_footprint_gpu(collision_entry, voxel_size, add_support, clearance_slices)


static func bake_cylinder_footprint_gpu(
	collision_entry: Dictionary,
	voxel_size: Vector3,
	add_support: bool = true,
	clearance_slices: int = 1
) -> Dictionary:
	var generator := VoxelPlacementGenerator.new()
	return generator._bake_cylinder_footprint_gpu(collision_entry, voxel_size, add_support, clearance_slices)


func _bake_box_footprint_gpu(
	collision_entry: Dictionary,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Dictionary:
	if collision_entry.is_empty():
		return _box_footprint_gpu_blocked("missing_collision_entry")
	var shape := str(collision_entry.get("shape", "box")).to_lower()
	if shape != "box" and shape != "cube":
		return _box_footprint_gpu_blocked("unsupported_shape")
	if voxel_size.x <= 0.0 or voxel_size.y <= 0.0 or voxel_size.z <= 0.0:
		return _box_footprint_gpu_blocked("invalid_voxel_size")

	var bounds := _box_footprint_voxel_bounds(collision_entry, voxel_size)
	var x_min_v := int(bounds.get("x_min", 0))
	var x_max_v := int(bounds.get("x_max", -1))
	var y_min_v := int(bounds.get("y_min", 0))
	var y_max_v := int(bounds.get("y_max", -1))
	var z_min_v := int(bounds.get("z_min", 0))
	var z_max_v := int(bounds.get("z_max", -1))
	var dim_x := x_max_v - x_min_v + 1
	var dim_y := y_max_v - y_min_v + 1
	var dim_z := z_max_v - z_min_v + 1
	if dim_x <= 0 or dim_y <= 0 or dim_z <= 0:
		return _box_footprint_gpu_blocked("empty_box_bounds")

	var solid_count := dim_x * dim_y * dim_z
	var clear_slices := maxi(clearance_slices, 0)
	var clearance_count := dim_x * clear_slices * dim_z
	var total_count := solid_count + clearance_count
	var write_count := mini(total_count, FOOTPRINT_CAPACITY)
	if write_count <= 0:
		return _box_footprint_gpu_blocked("empty_footprint")

	log_name = "VoxelPlacementBoxFootprintBake"
	sync_global_device = false
	if not ensure_device(true, false):
		dispose()
		return _box_footprint_gpu_blocked("missing_rendering_device", total_count, write_count)

	var shader := load_compute_shader(BOX_FOOTPRINT_BAKE_SHADER_PATH)
	var pipeline := create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		dispose()
		return _box_footprint_gpu_blocked("box_footprint_shader_not_ready", total_count, write_count)

	var pos_buffer := storage_buffer_zero(write_count * 16, SCOPE_FRAME, "box_footprint_pos_strength_i32x4")
	var weight_buffer := storage_buffer_zero(write_count * 16, SCOPE_FRAME, "box_footprint_weight_flags_f32x4")
	if not pos_buffer.is_valid() or not weight_buffer.is_valid():
		dispose()
		return _box_footprint_gpu_blocked("box_footprint_buffer_create_failed", total_count, write_count)

	var set0 := create_uniform_set([
		make_storage_uniform(0, pos_buffer),
		make_storage_uniform(1, weight_buffer),
	], shader, 0, SCOPE_PASS, "box_footprint_bake_set0")
	if not set0.is_valid():
		dispose()
		return _box_footprint_gpu_blocked("box_footprint_uniform_set_failed", total_count, write_count)

	var push := PackedByteArray()
	push.resize(80)
	push.encode_s32(0, x_min_v)
	push.encode_s32(4, y_min_v)
	push.encode_s32(8, z_min_v)
	push.encode_s32(12, solid_count)
	push.encode_s32(16, dim_x)
	push.encode_s32(20, dim_y)
	push.encode_s32(24, dim_z)
	push.encode_s32(28, 1 if add_support else 0)
	push.encode_s32(32, x_min_v)
	push.encode_s32(36, y_max_v + 1)
	push.encode_s32(40, z_min_v)
	push.encode_s32(44, clearance_count)
	push.encode_s32(48, dim_x)
	push.encode_s32(52, clear_slices)
	push.encode_s32(56, dim_z)
	push.encode_s32(60, write_count)
	push.encode_float(64, clampf(float(collision_entry.get("collision_strength", 1.0)), 0.0, 1.0))
	push.encode_float(68, 1.0)
	push.encode_float(72, 0.5)
	push.encode_float(76, 0.0)

	var groups := dispatch_groups_1d(write_count, BOX_FOOTPRINT_BAKE_LOCAL_SIZE)
	var cl := begin_compute_list()
	if cl < 0:
		dispose()
		return _box_footprint_gpu_blocked("box_footprint_compute_list_begin_failed", total_count, write_count)
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, 1, 1)
	end_compute_list()
	submit_and_sync()

	var pos_bytes := _rd.buffer_get_data(pos_buffer, 0, write_count * 16)
	var weight_bytes := _rd.buffer_get_data(weight_buffer, 0, write_count * 16)
	dispose()
	if pos_bytes.size() != write_count * 16 or weight_bytes.size() != write_count * 16:
		return _box_footprint_gpu_blocked("box_footprint_readback_failed", total_count, write_count)

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"shape": shape,
		"voxel_size": voxel_size,
		"bounds_min": Vector3i(x_min_v, y_min_v, z_min_v),
		"bounds_max": Vector3i(x_max_v, y_max_v, z_max_v),
		"solid_count": solid_count,
		"clearance_count": clearance_count,
		"total_generated_count": total_count,
		"footprint_count": write_count,
		"output_capacity": FOOTPRINT_CAPACITY,
		"truncated": total_count > write_count,
		"pos_strength_format": "ivec4(x,y,z,collision_q8)",
		"weight_flags_format": "vec4(weight,flags,radius,pad)",
		"pos_strength_stride_bytes": 16,
		"weight_flags_stride_bytes": 16,
		"local_size_x": BOX_FOOTPRINT_BAKE_LOCAL_SIZE,
		"dispatch_groups": groups,
		"pos_bytes": pos_bytes,
		"weight_bytes": weight_bytes,
		"footprint": _decode_gpu_footprint_buffers(pos_bytes, weight_bytes, write_count),
		"readback_source": "bake_box_footprint_compute",
	}


func _bake_cylinder_footprint_gpu(
	collision_entry: Dictionary,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Dictionary:
	if collision_entry.is_empty():
		return _cylinder_footprint_gpu_blocked("missing_collision_entry")
	var shape := str(collision_entry.get("shape", "cylinder")).to_lower()
	if shape != "cylinder":
		return _cylinder_footprint_gpu_blocked("unsupported_shape")
	if voxel_size.x <= 0.0 or voxel_size.y <= 0.0 or voxel_size.z <= 0.0:
		return _cylinder_footprint_gpu_blocked("invalid_voxel_size")

	var radius := maxf(float(collision_entry.get("radius", 1.0)), 0.01)
	var y_min := float(collision_entry.get("y_min", 0.0))
	var y_max := maxf(float(collision_entry.get("y_max", 2.0)), y_min + 0.01)
	var center := _vector3_from_value(
		collision_entry.get("offset", collision_entry.get("center", collision_entry.get("position", Vector3.ZERO))),
		Vector3.ZERO
	)
	var r_vx := ceili(radius / voxel_size.x)
	var r_vz := ceili(radius / voxel_size.z)
	var center_x_v := roundi(center.x / voxel_size.x)
	var center_z_v := roundi(center.z / voxel_size.z)
	var y_min_v := floori((center.y + y_min) / voxel_size.y)
	var y_max_v := ceili((center.y + y_max) / voxel_size.y)
	var solid_y_count := y_max_v - y_min_v + 1
	var x_count := r_vx * 2 + 1
	var z_count := r_vz * 2 + 1
	if solid_y_count <= 0 or x_count <= 0 or z_count <= 0:
		return _cylinder_footprint_gpu_blocked("empty_cylinder_bounds")

	var clear_slices := maxi(clearance_slices, 0)
	var solid_candidate_count := solid_y_count * x_count * z_count
	var clearance_candidate_count := clear_slices * x_count * z_count
	var candidate_count := solid_candidate_count + clearance_candidate_count
	var output_capacity := mini(candidate_count, FOOTPRINT_CAPACITY)
	if output_capacity <= 0:
		return _cylinder_footprint_gpu_blocked("empty_footprint")

	log_name = "VoxelPlacementCylinderFootprintBake"
	sync_global_device = false
	if not ensure_device(true, false):
		dispose()
		return _cylinder_footprint_gpu_blocked("missing_rendering_device", candidate_count, 0, output_capacity)

	var shader := load_compute_shader(CYLINDER_FOOTPRINT_BAKE_SHADER_PATH)
	var pipeline := create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		dispose()
		return _cylinder_footprint_gpu_blocked("cylinder_footprint_shader_not_ready", candidate_count, 0, output_capacity)

	var pos_buffer := storage_buffer_zero(output_capacity * 16, SCOPE_FRAME, "cylinder_footprint_pos_strength_i32x4")
	var weight_buffer := storage_buffer_zero(output_capacity * 16, SCOPE_FRAME, "cylinder_footprint_weight_flags_f32x4")
	var stats_buffer := storage_buffer_zero(4, SCOPE_FRAME, "cylinder_footprint_stats_u32")
	if not pos_buffer.is_valid() or not weight_buffer.is_valid() or not stats_buffer.is_valid():
		dispose()
		return _cylinder_footprint_gpu_blocked("cylinder_footprint_buffer_create_failed", candidate_count, 0, output_capacity)

	var set0 := create_uniform_set([
		make_storage_uniform(0, pos_buffer),
		make_storage_uniform(1, weight_buffer),
		make_storage_uniform(2, stats_buffer),
	], shader, 0, SCOPE_PASS, "cylinder_footprint_bake_set0")
	if not set0.is_valid():
		dispose()
		return _cylinder_footprint_gpu_blocked("cylinder_footprint_uniform_set_failed", candidate_count, 0, output_capacity)

	var push := PackedByteArray()
	push.resize(96)
	push.encode_s32(0, center_x_v)
	push.encode_s32(4, center_z_v)
	push.encode_s32(8, r_vx)
	push.encode_s32(12, r_vz)
	push.encode_s32(16, y_min_v)
	push.encode_s32(20, solid_y_count)
	push.encode_s32(24, y_max_v + 1)
	push.encode_s32(28, clear_slices)
	push.encode_s32(32, x_count)
	push.encode_s32(36, z_count)
	push.encode_s32(40, solid_candidate_count)
	push.encode_s32(44, candidate_count)
	push.encode_s32(48, output_capacity)
	push.encode_s32(52, 1 if add_support else 0)
	push.encode_s32(56, 0)
	push.encode_s32(60, 0)
	push.encode_float(64, voxel_size.x)
	push.encode_float(68, voxel_size.z)
	push.encode_float(72, radius * radius)
	push.encode_float(76, clampf(float(collision_entry.get("collision_strength", 1.0)), 0.0, 1.0))
	push.encode_float(80, 1.0)
	push.encode_float(84, 0.5)
	push.encode_float(88, 0.0)
	push.encode_float(92, 0.0)

	var groups := dispatch_groups_1d(candidate_count, CYLINDER_FOOTPRINT_BAKE_LOCAL_SIZE)
	var cl := begin_compute_list()
	if cl < 0:
		dispose()
		return _cylinder_footprint_gpu_blocked("cylinder_footprint_compute_list_begin_failed", candidate_count, 0, output_capacity)
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, 1, 1)
	end_compute_list()
	submit_and_sync()

	var stats_bytes := _rd.buffer_get_data(stats_buffer, 0, 4)
	var generated_count := int(stats_bytes.decode_u32(0)) if stats_bytes.size() >= 4 else 0
	var footprint_count := mini(generated_count, output_capacity)
	var pos_bytes := _rd.buffer_get_data(pos_buffer, 0, footprint_count * 16)
	var weight_bytes := _rd.buffer_get_data(weight_buffer, 0, footprint_count * 16)
	dispose()
	if stats_bytes.size() < 4 or pos_bytes.size() != footprint_count * 16 or weight_bytes.size() != footprint_count * 16:
		return _cylinder_footprint_gpu_blocked("cylinder_footprint_readback_failed", candidate_count, generated_count, output_capacity)

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"shape": shape,
		"voxel_size": voxel_size,
		"center_voxel_xz": Vector2i(center_x_v, center_z_v),
		"radius": radius,
		"radius_voxels": Vector2i(r_vx, r_vz),
		"solid_y_range": Vector2i(y_min_v, y_max_v),
		"candidate_count": candidate_count,
		"total_generated_count": generated_count,
		"footprint_count": footprint_count,
		"output_capacity": output_capacity,
		"truncated": generated_count > output_capacity,
		"pos_strength_format": "ivec4(x,y,z,collision_q8)",
		"weight_flags_format": "vec4(weight,flags,radius,pad)",
		"pos_strength_stride_bytes": 16,
		"weight_flags_stride_bytes": 16,
		"stats_format": "u32_valid_count",
		"stats_stride_bytes": 4,
		"volume_layout": "solid_y_z_x_then_clearance_y_z_x",
		"local_size_x": CYLINDER_FOOTPRINT_BAKE_LOCAL_SIZE,
		"dispatch_groups": groups,
		"pos_bytes": pos_bytes,
		"weight_bytes": weight_bytes,
		"footprint": _decode_gpu_footprint_buffers(pos_bytes, weight_bytes, footprint_count),
		"readback_source": "bake_cylinder_footprint_compute",
	}


static func _cylinder_footprint_gpu_blocked(
	reason: String,
	candidate_count: int = 0,
	generated_count: int = 0,
	output_capacity: int = 0
) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"candidate_count": candidate_count,
		"total_generated_count": generated_count,
		"footprint_count": mini(generated_count, output_capacity),
		"output_capacity": output_capacity,
	}


static func _box_footprint_gpu_blocked(reason: String, total_count: int = 0, write_count: int = 0) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"total_generated_count": total_count,
		"footprint_count": write_count,
	}


static func _box_footprint_voxel_bounds(cv: Dictionary, voxel_size: Vector3) -> Dictionary:
	var center := _vector3_from_value(cv.get("offset", cv.get("center", cv.get("position", Vector3.ZERO))), Vector3.ZERO)
	var half_extents := _vector3_from_value(cv.get("half_extents", Vector3.ZERO), Vector3.ZERO)
	var min_world: Vector3
	var max_world: Vector3
	if half_extents.length_squared() <= 0.0001:
		var size := _vector3_from_value(cv.get("size", Vector3.ZERO), Vector3.ZERO)
		if size.length_squared() > 0.0001:
			half_extents = size * 0.5
	if half_extents.length_squared() > 0.0001:
		min_world = center - half_extents
		max_world = center + half_extents
		if cv.has("y_min") or cv.has("y_max"):
			min_world.y = center.y + float(cv.get("y_min", min_world.y - center.y))
			max_world.y = center.y + float(cv.get("y_max", max_world.y - center.y))
	else:
		var radius := maxf(float(cv.get("radius", 1.0)), 0.01)
		var y_min := float(cv.get("y_min", 0.0))
		var y_max := maxf(float(cv.get("y_max", 2.0)), y_min + 0.01)
		min_world = center + Vector3(-radius, y_min, -radius)
		max_world = center + Vector3(radius, y_max, radius)
	return {
		"x_min": floori(min_world.x / voxel_size.x),
		"x_max": ceili(max_world.x / voxel_size.x),
		"y_min": floori(min_world.y / voxel_size.y),
		"y_max": ceili(max_world.y / voxel_size.y),
		"z_min": floori(min_world.z / voxel_size.z),
		"z_max": ceili(max_world.z / voxel_size.z),
	}


static func _is_point_collision_sample(collision: Dictionary) -> bool:
	return collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset")


static func _collision_sample_position(collision: Dictionary) -> Vector3i:
	return _vector3i_from_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3i.ZERO))), Vector3i.ZERO)


static func _collision_sample_strength(collision: Dictionary) -> float:
	return clampf(float(collision.get("collision_strength", 1.0)), 0.0, 1.0)


static func _bake_point_collision(
	collision_layers: Array[Dictionary],
	add_support: bool,
	clearance_slices: int
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var min_y := 2147483647
	var top_by_xz := {}
	for collision_entry in collision_layers:
		if not bool(collision_entry.get("enabled", true)):
			continue
		var local_pos := _collision_sample_position(collision_entry)
		var collision_strength := _collision_sample_strength(collision_entry)
		var flags := int(collision_entry.get("flags", 0))
		var weight := maxf(float(collision_entry.get("weight", 1.0)), 0.0)
		result.append({
			"local_pos": local_pos,
			"collision_strength": collision_strength,
			"flags": flags,
			"weight": weight,
		})
		if collision_strength <= 0.0:
			continue
		min_y = mini(min_y, local_pos.y)
		var key := "%d,%d" % [local_pos.x, local_pos.z]
		if not top_by_xz.has(key) or local_pos.y > int(top_by_xz[key].y):
			top_by_xz[key] = local_pos
	if add_support and min_y < 2147483647:
		for entry in result:
			var pos: Vector3i = entry.local_pos
			if pos.y == min_y and float(entry.collision_strength) > 0.0:
				entry["flags"] = int(entry.flags) | FLAG_SUPPORT
	if clearance_slices > 0:
		for top in top_by_xz.values():
			var pos := top as Vector3i
			for cy in range(pos.y + 1, pos.y + 1 + clearance_slices):
				result.append({
					"local_pos": Vector3i(pos.x, cy, pos.z),
					"collision_strength": 0.0,
					"flags": FLAG_CLEARANCE,
					"weight": 0.5,
				})
	return result


static func _bake_cylinder(
	cv: Dictionary,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Array[Dictionary]:
	var radius := maxf(float(cv.get("radius", 1.0)), 0.01)
	var y_min := float(cv.get("y_min", 0.0))
	var y_max := maxf(float(cv.get("y_max", 2.0)), y_min + 0.01)
	var collision_strength := clampf(float(cv.get("collision_strength", 1.0)), 0.0, 1.0)
	var center := _vector3_from_value(cv.get("offset", cv.get("center", cv.get("position", Vector3.ZERO))), Vector3.ZERO)

	var r_vx := ceili(radius / voxel_size.x)
	var r_vz := ceili(radius / voxel_size.z)
	var center_x_v := roundi(center.x / voxel_size.x)
	var center_z_v := roundi(center.z / voxel_size.z)
	var y_min_v := floori((center.y + y_min) / voxel_size.y)
	var y_max_v := ceili((center.y + y_max) / voxel_size.y)
	var radius_sq := radius * radius

	var result: Array[Dictionary] = []

	for y in range(y_min_v, y_max_v + 1):
		for z in range(-r_vz, r_vz + 1):
			for x in range(-r_vx, r_vx + 1):
				var wx := float(x) * voxel_size.x
				var wz := float(z) * voxel_size.z
				if wx * wx + wz * wz > radius_sq:
					continue
				var flags := 0
				if add_support and y == y_min_v:
					flags |= FLAG_SUPPORT
				result.append({
					"local_pos": Vector3i(center_x_v + x, y, center_z_v + z),
					"collision_strength": collision_strength,
					"flags": flags,
					"weight": 1.0,
				})

	if clearance_slices > 0:
		for cy in range(y_max_v + 1, y_max_v + 1 + clearance_slices):
			for z in range(-r_vz, r_vz + 1):
				for x in range(-r_vx, r_vx + 1):
					var wx := float(x) * voxel_size.x
					var wz := float(z) * voxel_size.z
					if wx * wx + wz * wz > radius_sq:
						continue
					result.append({
						"local_pos": Vector3i(center_x_v + x, cy, center_z_v + z),
						"collision_strength": 0.0,
						"flags": FLAG_CLEARANCE,
						"weight": 0.5,
					})

	return result


static func _bake_box(
	cv: Dictionary,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Array[Dictionary]:
	var center := _vector3_from_value(cv.get("offset", cv.get("center", cv.get("position", Vector3.ZERO))), Vector3.ZERO)
	var half_extents := _vector3_from_value(cv.get("half_extents", Vector3.ZERO), Vector3.ZERO)
	if half_extents.length_squared() <= 0.0001:
		var size := _vector3_from_value(cv.get("size", Vector3.ZERO), Vector3.ZERO)
		if size.length_squared() > 0.0001:
			half_extents = size * 0.5
	var min_world: Vector3
	var max_world: Vector3
	if half_extents.length_squared() > 0.0001:
		min_world = center - half_extents
		max_world = center + half_extents
		if cv.has("y_min") or cv.has("y_max"):
			min_world.y = center.y + float(cv.get("y_min", min_world.y - center.y))
			max_world.y = center.y + float(cv.get("y_max", max_world.y - center.y))
	else:
		var radius := maxf(float(cv.get("radius", 1.0)), 0.01)
		var y_min := float(cv.get("y_min", 0.0))
		var y_max := maxf(float(cv.get("y_max", 2.0)), y_min + 0.01)
		min_world = center + Vector3(-radius, y_min, -radius)
		max_world = center + Vector3(radius, y_max, radius)
	var collision_strength := clampf(float(cv.get("collision_strength", 1.0)), 0.0, 1.0)
	var x_min_v := floori(min_world.x / voxel_size.x)
	var x_max_v := ceili(max_world.x / voxel_size.x)
	var y_min_v := floori(min_world.y / voxel_size.y)
	var y_max_v := ceili(max_world.y / voxel_size.y)
	var z_min_v := floori(min_world.z / voxel_size.z)
	var z_max_v := ceili(max_world.z / voxel_size.z)
	var result: Array[Dictionary] = []
	for y in range(y_min_v, y_max_v + 1):
		for z in range(z_min_v, z_max_v + 1):
			for x in range(x_min_v, x_max_v + 1):
				var flags := 0
				if add_support and y == y_min_v:
					flags |= FLAG_SUPPORT
				result.append({
					"local_pos": Vector3i(x, y, z),
					"collision_strength": collision_strength,
					"flags": flags,
					"weight": 1.0,
				})
	if clearance_slices > 0:
		for cy in range(y_max_v + 1, y_max_v + 1 + clearance_slices):
			for z in range(z_min_v, z_max_v + 1):
				for x in range(x_min_v, x_max_v + 1):
					result.append({
						"local_pos": Vector3i(x, cy, z),
						"collision_strength": 0.0,
						"flags": FLAG_CLEARANCE,
						"weight": 0.5,
					})
	return result


static func _deduplicate_footprint(entries: Array[Dictionary]) -> Array[Dictionary]:
	var by_pos := {}
	for entry in entries:
		var pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var key := "%d,%d,%d" % [pos.x, pos.y, pos.z]
		if by_pos.has(key):
			var existing: Dictionary = by_pos[key]
			existing["collision_strength"] = maxf(
				float(existing.get("collision_strength", 0.0)), float(entry.get("collision_strength", 0.0)))
			existing["flags"] = int(existing.flags) | int(entry.flags)
			existing["weight"] = maxf(float(existing.weight), float(entry.weight))
		else:
			by_pos[key] = entry.duplicate()
	var result: Array[Dictionary] = []
	for entry in by_pos.values():
		result.append(entry)
	return result


static func _decode_gpu_footprint_buffers(pos_bytes: PackedByteArray, weight_bytes: PackedByteArray, count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var available := mini(count, mini(int(pos_bytes.size() / 16), int(weight_bytes.size() / 16)))
	for i in range(available):
		var pos_offset := i * 16
		var weight_offset := i * 16
		result.append({
			"local_pos": Vector3i(
				pos_bytes.decode_s32(pos_offset + 0),
				pos_bytes.decode_s32(pos_offset + 4),
				pos_bytes.decode_s32(pos_offset + 8)
			),
			"collision_strength": clampf(float(pos_bytes.decode_s32(pos_offset + 12)) / 255.0, 0.0, 1.0),
			"flags": roundi(weight_bytes.decode_float(weight_offset + 4)),
			"weight": maxf(weight_bytes.decode_float(weight_offset + 0), 0.0),
		})
	return result


# ---------------------------------------------------------------------------
# Footprint rotation — pre-bake 24 yaw versions
# ---------------------------------------------------------------------------

static func rotate_footprint_y(
	footprint: Array[Dictionary], yaw_degrees: float
) -> Array[Dictionary]:
	if absf(yaw_degrees) < 0.01:
		var out: Array[Dictionary] = []
		for e in footprint:
			out.append(e.duplicate())
		return out
	var rad := deg_to_rad(yaw_degrees)
	var cos_r := cos(rad)
	var sin_r := sin(rad)
	var rotated: Array[Dictionary] = []
	for entry in footprint:
		var pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var rx := float(pos.x) * cos_r - float(pos.z) * sin_r
		var rz := float(pos.x) * sin_r + float(pos.z) * cos_r
		var new_entry := entry.duplicate()
		new_entry["local_pos"] = Vector3i(roundi(rx), pos.y, roundi(rz))
		rotated.append(new_entry)
	return _deduplicate_footprint(rotated)


static func rotate_footprint_y_gpu(footprint: Array[Dictionary], yaw_degrees: float) -> Dictionary:
	var generator := VoxelPlacementGenerator.new()
	return generator._rotate_footprint_y_gpu(footprint, yaw_degrees)


func _rotate_footprint_y_gpu(footprint: Array[Dictionary], yaw_degrees: float) -> Dictionary:
	var footprint_count := footprint.size()
	if footprint_count <= 0:
		return _rotate_footprint_y_gpu_blocked("empty_footprint")

	var packed := _pack_footprint(footprint)
	var input_pos_bytes: PackedByteArray = packed.get("pos_bytes", PackedByteArray())
	var input_weight_bytes: PackedByteArray = packed.get("weight_bytes", PackedByteArray())
	if input_pos_bytes.size() != footprint_count * 16 or input_weight_bytes.size() != footprint_count * 16:
		return _rotate_footprint_y_gpu_blocked("pack_failed", footprint_count)

	log_name = "VoxelPlacementFootprintRotateY"
	sync_global_device = false
	if not ensure_device(true, false):
		dispose()
		return _rotate_footprint_y_gpu_blocked("missing_rendering_device", footprint_count)

	var shader := load_compute_shader(ROTATE_FOOTPRINT_Y_SHADER_PATH)
	var pipeline := create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		dispose()
		return _rotate_footprint_y_gpu_blocked("rotate_footprint_shader_not_ready", footprint_count)

	var pos_in_buffer := storage_buffer_from_bytes(input_pos_bytes, SCOPE_FRAME, "rotate_footprint_pos_in_i32x4")
	var weight_in_buffer := storage_buffer_from_bytes(input_weight_bytes, SCOPE_FRAME, "rotate_footprint_weight_in_f32x4")
	var pos_out_buffer := storage_buffer_zero(footprint_count * 16, SCOPE_FRAME, "rotate_footprint_pos_out_i32x4")
	var weight_out_buffer := storage_buffer_zero(footprint_count * 16, SCOPE_FRAME, "rotate_footprint_weight_out_f32x4")
	if (
		not pos_in_buffer.is_valid()
		or not weight_in_buffer.is_valid()
		or not pos_out_buffer.is_valid()
		or not weight_out_buffer.is_valid()
	):
		dispose()
		return _rotate_footprint_y_gpu_blocked("rotate_footprint_buffer_create_failed", footprint_count)

	var set0 := create_uniform_set([
		make_storage_uniform(0, pos_in_buffer),
		make_storage_uniform(1, weight_in_buffer),
		make_storage_uniform(2, pos_out_buffer),
		make_storage_uniform(3, weight_out_buffer),
	], shader, 0, SCOPE_PASS, "rotate_footprint_y_set0")
	if not set0.is_valid():
		dispose()
		return _rotate_footprint_y_gpu_blocked("rotate_footprint_uniform_set_failed", footprint_count)

	var radians := deg_to_rad(yaw_degrees)
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, footprint_count)
	push.encode_float(4, cos(radians))
	push.encode_float(8, sin(radians))
	push.encode_float(12, 0.0)

	var groups := dispatch_groups_1d(footprint_count, ROTATE_FOOTPRINT_Y_LOCAL_SIZE)
	var cl := begin_compute_list()
	if cl < 0:
		dispose()
		return _rotate_footprint_y_gpu_blocked("rotate_footprint_compute_list_begin_failed", footprint_count)
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	end_compute_list()
	submit_and_sync()

	var pos_bytes := _rd.buffer_get_data(pos_out_buffer, 0, footprint_count * 16)
	var weight_bytes := _rd.buffer_get_data(weight_out_buffer, 0, footprint_count * 16)
	dispose()
	if pos_bytes.size() != footprint_count * 16 or weight_bytes.size() != footprint_count * 16:
		return _rotate_footprint_y_gpu_blocked("rotate_footprint_readback_failed", footprint_count)

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"rotation_axis": "Y",
		"yaw_degrees": yaw_degrees,
		"footprint_count": footprint_count,
		"pos_strength_format": "ivec4(x,y,z,collision_q8)",
		"weight_flags_format": "vec4(weight,flags,radius,pad)",
		"pos_strength_stride_bytes": 16,
		"weight_flags_stride_bytes": 16,
		"valid_range": "collision_q8 clamped 0..255; weight/flags/radius copied",
		"volume_layout": "one packed footprint entry per invocation",
		"local_size_x": ROTATE_FOOTPRINT_Y_LOCAL_SIZE,
		"dispatch_groups": groups,
		"edge_guard": "idx >= footprint_count returns without writing",
		"pos_bytes": pos_bytes,
		"weight_bytes": weight_bytes,
		"footprint": _decode_gpu_footprint_buffers(pos_bytes, weight_bytes, footprint_count),
		"readback_source": "rotate_footprint_y_compute",
	}


static func _rotate_footprint_y_gpu_blocked(reason: String, footprint_count: int = 0) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"footprint_count": footprint_count,
	}


static func bake_rotated_footprints(
	collision: Array,
	voxel_size: Vector3,
	rotation_count: int = 24,
	add_support: bool = true,
	clearance_slices: int = 1
) -> Array:
	var base := bake_footprint_from_collision(
		collision, voxel_size, add_support, clearance_slices)
	var result: Array = []
	for i in range(rotation_count):
		var yaw := float(i) * 360.0 / float(maxi(rotation_count, 1))
		result.append(rotate_footprint_y(base, yaw))
	return result


# ---------------------------------------------------------------------------
# GPU result → world-space placement data
# ---------------------------------------------------------------------------

static func results_to_world(
	results: Array[Dictionary],
	voxel_size: Vector3,
	grid_origin: Vector3,
	rotation_count: int = 24,
	pivot_variant: Dictionary = {}
) -> Array[Dictionary]:
	var world_results: Array[Dictionary] = []
	for r in results:
		if not bool(r.get("valid", false)):
			continue
		var origin: Vector3i = r.get("voxel_origin", Vector3i.ZERO)
		var rot_idx := int(r.get("rotation_index", 0))
		var scale_idx := int(r.get("scale_index", 0))
		var world_pos := grid_origin + Vector3(
			float(origin.x) * voxel_size.x,
			float(origin.y) * voxel_size.y,
			float(origin.z) * voxel_size.z
		)
		var yaw := float(rot_idx) * 360.0 / float(maxi(rotation_count, 1))
		var pivot_offset := _vector3_from_value(pivot_variant.get("offset", Vector3.ZERO), Vector3.ZERO)
		var pivot_world_offset := pivot_offset.rotated(Vector3.UP, deg_to_rad(yaw))
		var instance_pos := world_pos - pivot_world_offset
		world_results.append({
			"position": instance_pos,
			"anchor_position": world_pos,
			"pivot_variant": str(pivot_variant.get("name", "bottom")),
			"pivot_offset": pivot_offset,
			"rotation_degrees": Vector3(0.0, yaw, 0.0),
			"rotation_mode": "Y",
			"scale": Vector3.ONE,
			"score": float(r.get("score", 0.0)),
			"voxel_origin": origin,
			"rotation_index": rot_idx,
			"scale_index": scale_idx,
			"asset_index": int(r.get("asset_index", 0)),
			"support_ratio": float(r.get("support_ratio", 0.0)),
			"solid_collision": float(r.get("solid_collision", 0.0)),
			"scene_overlap": float(r.get("scene_overlap", 0.0)),
			"clearance_overlap": float(r.get("clearance_overlap", 0.0)),
			"ignored_sample": float(r.get("ignored_sample", 0.0)),
		})
	return world_results


# ---------------------------------------------------------------------------
# voxel_write_spec creation
# ---------------------------------------------------------------------------

static func make_voxel_write_spec(
	world_result: Dictionary,
	node: AutoObject,
	config: Dictionary = {}
) -> Dictionary:
	if node != null:
		var node_record_id := str(config.get("id", node.name if not node.name.is_empty() else "voxel_placement_%d" % int(world_result.get("asset_index", 0))))
		var fields := config.duplicate(true)
		fields.erase("id")
		fields.erase("id_prefix")
		if not fields.has("auto_source"):
			fields["auto_source"] = "voxel_placement"
		if not fields.has("source_voxel_type"):
			fields["source_voxel_type"] = "AutoSceneVoxel"
		fields["score"] = float(world_result.get("score", 0.0))
		fields["voxel_origin"] = world_result.get("voxel_origin", Vector3i.ZERO)
		fields["rotation_index"] = int(world_result.get("rotation_index", 0))
		fields["asset_index"] = int(world_result.get("asset_index", 0))
		var node_record := node.make_instance_stamp_write_spec(node_record_id, Vector2i.ZERO, 0, fields)
		node_record["position"] = world_result.get("position", node.position)
		node_record["scale"] = world_result.get("scale", node.scale)
		if world_result.has("rotation_degrees"):
			node_record["rotation_degrees"] = world_result.rotation_degrees
		return node_record

	var color: Color = config.get("color", Color.WHITE)
	var complexity := clampf(float(config.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity
	var position: Vector3 = world_result.get("position", Vector3.ZERO)
	var scale_val: Vector3 = world_result.get("scale", Vector3.ONE)
	var record_id := str(config.get("id", "voxel_placement_%d" % int(world_result.get("asset_index", 0))))
	var collision_layers: Array = config.get("collision", [])

	var record := {
		"id": record_id,
		"type": config.get("type", "vegetation"),
		"auto_source": "voxel_placement",
		"source_voxel_type": "AutoSceneVoxel",
		"position": position,
		"scale": scale_val,
		"base_pixel": Vector2i.ZERO,
		"voxel_xz": Vector2i.ZERO,
		"volume_xz_resolution": 0,
		"color": color,
		"complexity": complexity,
		"collision": collision_layers,
		"score": float(world_result.get("score", 0.0)),
		"voxel_origin": world_result.get("voxel_origin", Vector3i.ZERO),
		"rotation_index": int(world_result.get("rotation_index", 0)),
		"rotation_mode": str(world_result.get("rotation_mode", "Y")).to_upper(),
		"rotation_degrees": world_result.get("rotation_degrees", Vector3.ZERO),
		"asset_index": int(world_result.get("asset_index", 0)),
	}
	if config.has("channel"):
		record["channel"] = int(config.channel)
		record["radius"] = float(config.get("radius", 0.0))
		if config.has("y_min"):
			record["y_min"] = float(config.y_min)
		if config.has("y_max"):
			record["y_max"] = float(config.y_max)
	return record


static func make_voxel_write_specs(
	world_results: Array,
	nodes: Array,
	config: Dictionary = {}
) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for i in range(world_results.size()):
		var node: AutoObject = nodes[i] if i < nodes.size() else null
		var cfg := config.duplicate(true)
		cfg["id"] = "%s_%d" % [str(config.get("id_prefix", "voxel_placement")), i]
		records.append(make_voxel_write_spec(world_results[i], node, cfg))
	return records
