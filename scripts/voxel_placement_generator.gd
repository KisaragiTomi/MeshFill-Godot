class_name VoxelPlacementGenerator


extends "res://scripts/godot_compute_shader_base.gd"
## Anchor-origin residual-gain GPU placement.
##
## Consumes the probe prefilter's resident anchor handoff (anchor_buf +
## anchor_count_buf + per-anchor asset top-K) and the profile container's
## resident asset_voxel_records, then runs one GPU chain over ALL assets:
##   fine_score_dispatch_finalize -> score_anchor_asset_residual (indirect)
##   -> reduce_anchor_candidates (common pool) -> init_stamp_bounds
##   -> stamp_asset_voxels (mixed-asset).
## origin_count == anchor_count (origin_contract "one_origin_per_anchor");
## the candidate score is the five-dimension residual gain
## D(CurrentSV, TargetSV) - D(compose(CurrentSV, AD), TargetSV), with no-op as
## the implicit baseline (valid requires score_gain > gain threshold).
## The old Candidate route / tile / 512-origin machinery is gone.

const VoxelPlacementWritebackScript := preload("res://scripts/voxel_placement_writeback.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const VoxelPlacementTargetReaderScript := preload("res://scripts/voxel_placement_target_reader.gd")
const VoxelPlacementStateChainScript := preload("res://scripts/voxel_placement_state_chain.gd")
const VoxelPlacementOutputScript := preload("res://scripts/voxel_placement_output.gd")
const DebugBufferSetScript := preload("res://scripts/utils/debug_buffer_set.gd")
const ScoreTimingProfilerScript := preload("res://scripts/utils/score_timing_profiler.gd")
const ReportSchema := preload("res://scripts/utils/report_schema.gd")

var _placement_writeback = null

## Lazily creates the delegated placement writeback helper.
func _ensure_placement_writeback():
	if _placement_writeback == null:
		_placement_writeback = VoxelPlacementWritebackScript.new()
		_placement_writeback._generator = self
	if not _placement_writeback._rd and _rd:
		_placement_writeback.attach_rendering_device(_rd, false)
	return _placement_writeback


const RECORD_STRIDE := 4
const DELTA_STRIDE := 2
const STAMP_BOUNDS_STRIDE := 2
# Fixed fine-score dispatch width; must match the prefilter's anchor grid so
# anchor_id decodes identically on both sides (see prefilter ANCHOR_GRID_X).
const ANCHOR_GRID_X := 256
const MAX_ASSETS := 256
const SCORE_SUM_SHADER_PATH := "res://shaders/placement_result_score_sum.glsl"
const GPU_RUNTIME_PROVIDER_CONFIG_KEY := "gpu_autoobject_runtime"
const GPU_PROFILE_CONTAINER_CONFIG_KEY := "auto_voxel_runtime_profile_container"
const REQUIRED_GPU_RUNTIME_BUFFERS := [
	"alive",
	"generation",
	"object_type",
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
	"asset_voxel_records",
]

# Push-constant schemas (std430, sequential scalars). See PushConstantLayout.
const FINE_FINALIZE_PUSH := [
	["anchor_grid_x", "uint"],    # 0
	["topk", "uint"],             # 4
	["anchor_capacity", "uint"],  # 8
	["_pad0", "uint"],            # 12
]
const FINE_SCORE_PUSH := [
	["grid_x", "int"],                  # 0
	["grid_y", "int"],                  # 4
	["grid_z", "int"],                  # 8
	["has_target", "int"],              # 12
	["voxel_size_x", "float"],          # 16
	["voxel_size_y", "float"],          # 20
	["voxel_size_z", "float"],          # 24
	["gain_threshold", "float"],        # 28
	["rotation_slots", "int"],          # 32
	["topk", "int"],                    # 36
	["asset_count", "int"],             # 40
	["anchor_capacity", "int"],         # 44
	["solid_threshold", "float"],       # 48
	["collision_limit", "float"],       # 52
	["clearance_limit", "float"],       # 56
	["complexity_write_scale", "float"], # 60
	["collision_write_scale", "float"], # 64
	["dim_w_collision", "float"],       # 68
	["dim_w_complexity", "float"],      # 72
	["dim_w_color", "float"],           # 76
	["contract_enabled", "int"],        # 80
	["profile_count", "int"],           # 84
	["debug_write_mask", "int"],        # 88
	["_pad0", "int"],                   # 92
	# capacities ivec4: host-passed buffer element counts for the shader's
	# capacity gates (replaces GLSL .length()/OpArrayLength, unsupported by
	# Godot's SPIR-V path).
	["asset_lookup_capacity", "int"],         # 96
	["profile_table_capacity", "int"],        # 100
	["asset_voxel_records_capacity", "int"],  # 104
	["pivot_records_capacity", "int"],        # 108
]
const REDUCE_PUSH := [
	["topk", "int"],                    # 0
	["result_capacity", "int"],         # 4
	["asset_count", "int"],             # 8
	["anchor_capacity", "int"],         # 12
	["min_distance_voxels", "float"],   # 16
	["_padf0", "float"],                # 20
	["_padf1", "float"],                # 24
	["_padf2", "float"],                # 28
]
const STAMP_PUSH := [
	["grid_x", "int"],                  # 0
	["grid_y", "int"],                  # 4
	["grid_z", "int"],                  # 8
	["rotation_slots", "int"],          # 12
	["write_min_x", "int"],             # 16
	["write_min_y", "int"],             # 20
	["write_min_z", "int"],             # 24
	["profile_count", "int"],           # 28
	["write_max_x", "int"],             # 32
	["write_max_y", "int"],             # 36
	["write_max_z", "int"],             # 40
	["stamp_delta_capacity", "int"],    # 44
	["solid_threshold", "float"],       # 48
	["complexity_write_scale", "float"], # 52
	["collision_write_scale", "float"], # 56
	["dual_commit", "float"],           # 60
	["voxel_size_x", "float"],          # 64
	["voxel_size_y", "float"],          # 68
	["voxel_size_z", "float"],          # 72
	["_padf0", "float"],                # 76
	# capacities ivec4: host-passed buffer element counts for the shader's
	# capacity gates (replaces GLSL .length()/OpArrayLength, unsupported by
	# Godot's SPIR-V path).
	["profile_table_capacity", "int"],        # 80
	["asset_voxel_records_capacity", "int"],  # 84
	["pivot_records_capacity", "int"],        # 88
	["_pad0", "int"],                         # 92
]
const STAMP_INIT_PUSH := [
	["result_capacity", "int"],   # 0
	["stamp_bounds_stride", "int"], # 4
	["_pad0", "int"],             # 8
	["_pad1", "int"],             # 12
]
const PACK_TARGET_FIELD_PUSH := [
	["voxel_count", "int"],       # 0
	["_pad0", "int"],             # 4
	["_pad1", "int"],             # 8
	["_pad2", "int"],             # 12
]
const SCORE_SUM_PUSH := [
	["result_capacity", "int"],   # 0
	["record_stride", "int"],     # 4
	["_pad0", "int"],             # 8
	["_pad1", "int"],             # 12
]

var result_capacity: int = 8
var solid_threshold: float = 192.0 / 255.0
var collision_limit: float = 0.0
var clearance_limit: float = 0.0
var min_distance_voxels: float = 2.0
var scene_write_scale: float = 1.0
var collision_write_scale: float = 1.0
var rotation_slots: int = 12
# No-op baseline gate: a candidate is valid only when its residual gain exceeds
# this threshold; if nothing improves the TargetSV residual, place nothing.
var score_gain_threshold: float = 0.0
# Five-dimension weights [collision, complexity, color-per-channel]; the three
# color channels share one weight so they sum to ~1 against the other two.
var dim_weight_collision: float = 1.0
var dim_weight_complexity: float = 1.0
var dim_weight_color: float = 0.34

var _shader_fine_finalize: RID
var _shader_fine_score: RID
var _shader_reduce: RID
var _shader_init_stamp_bounds: RID
var _shader_stamp: RID
var _shader_pack_target_field: RID
var _pipeline_fine_finalize: RID
var _pipeline_fine_score: RID
var _pipeline_reduce: RID
var _pipeline_init_stamp_bounds: RID
var _pipeline_stamp: RID
var _pipeline_pack_target_field: RID


## Multi-asset placement over the anchor fine pipeline. All assets enter one
## common candidate pool (anchor x top-K asset x pivot x yaw) and compete by
## residual gain in a single reduce; there is no per-asset / per-pivot GPU loop.
func run_multi_asset(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3 = Vector3.ZERO,
	common_settings: Dictionary = {}
) -> Dictionary:
	var run_result := _run_anchor_fine_pipeline(
		complexity_field, collision_field, asset_defs, grid_size, voxel_size, grid_origin, common_settings)
	_free_gpu()
	return run_result


func _run_anchor_fine_pipeline(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3,
	common_settings: Dictionary
) -> Dictionary:
	_apply_settings(common_settings)
	var include_diagnostics := bool(common_settings.get("include_diagnostics", false))
	var _prof := ScoreTimingProfilerScript.new(
		bool(common_settings.get("score_timing_profile", false)),
		str(common_settings.get("score_timing_label", "anchor_fine")))
	_prof.mark("run_start")

	var voxel_count := VoxelGeneral.voxel_count(grid_size)
	if voxel_count <= 0:
		push_error("VoxelPlacementGenerator: grid_size must be positive")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "invalid_grid_size"), common_settings)

	if int(common_settings.get("global_quota", -1)) == 0:
		return _empty_placement_output(
			complexity_field, collision_field, asset_defs, "global_quota_zero", common_settings)

	var runtime_provider := _config_object(common_settings, GPU_RUNTIME_PROVIDER_CONFIG_KEY)
	var profile_container := _config_object(common_settings, GPU_PROFILE_CONTAINER_CONFIG_KEY)
	var write_accepted_placements_to_gpu_runtime := bool(common_settings.get("write_accepted_placements_to_gpu_runtime", false))
	var gpu_direct_runtime_writeback := write_accepted_placements_to_gpu_runtime \
		and runtime_provider != null \
		and runtime_provider.has_method("spawn_batch_from_accepted_placement_gpu_buffers")
	var gpu_contract_settings := common_settings.duplicate(true)
	if write_accepted_placements_to_gpu_runtime:
		gpu_contract_settings["require_gpu_runtime_profile_contract"] = true
	var gpu_contract := _validate_gpu_runtime_profile_contract(gpu_contract_settings)
	if not bool(gpu_contract.get("ok", true)):
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs, gpu_contract, common_settings)

	# Anchor handoff is the ONLY candidate source (resident-or-error, no
	# all-tiles fallback): origin_count == anchor_count by contract.
	var anchor_handoff := _resolve_anchor_candidate_handoff(common_settings)
	if not bool(anchor_handoff.get("ok", false)):
		var handoff_reason := "anchor_candidate_handoff_unavailable:%s" % str(anchor_handoff.get("reason", "missing"))
		push_error("VoxelPlacementGenerator: %s" % handoff_reason)
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, handoff_reason), common_settings)

	var container_binding := _resolve_profile_container_buffers(common_settings)
	if not bool(container_binding.get("ok", false)):
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, str(container_binding.get("reason", "profile_container_unavailable"))),
			common_settings)

	log_name = "VoxelPlacementGenerator"
	sync_global_device = true
	if get_rendering_device() == null and not ensure_device():
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "missing_rendering_device"), common_settings)

	_load_shaders()
	if not _placement_pipeline_ready():
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "placement_shader_pipeline_not_ready"), common_settings)

	var anchor_capacity := int(anchor_handoff.get("anchor_capacity", 0))
	var topk := int(anchor_handoff.get("topk", 4))
	var anchor_buffer: RID = anchor_handoff.get("anchor_buffer_rid", RID())
	var anchor_count_buffer: RID = anchor_handoff.get("anchor_count_buffer_rid", RID())
	var topk_buffer: RID = anchor_handoff.get("topk_buffer_rid", RID())
	track_borrowed_rid(anchor_buffer, KIND_BUFFER, SCOPE_FRAME, "prefilter:anchor_records")
	track_borrowed_rid(anchor_count_buffer, KIND_BUFFER, SCOPE_FRAME, "prefilter:anchor_count")
	track_borrowed_rid(topk_buffer, KIND_BUFFER, SCOPE_FRAME, "prefilter:anchor_topk")

	var profile_table_buffer: RID = container_binding.get("profile_table_buffer", RID())
	var asset_voxel_records_buffer: RID = container_binding.get("asset_voxel_records_buffer", RID())
	var pivot_records_buffer: RID = container_binding.get("pivot_records_buffer", RID())
	var profile_count := int(container_binding.get("profile_count", 0))
	# Explicit element capacities for the shader capacity gates (see the
	# capacities push members in score_anchor_asset_residual/stamp_asset_voxels).
	var profile_table_capacity := int(container_binding.get("profile_table_capacity", 0))
	var asset_voxel_records_capacity := int(container_binding.get("asset_voxel_records_capacity", 0))
	var pivot_records_capacity := int(container_binding.get("pivot_records_capacity", 0))
	track_borrowed_rid(profile_table_buffer, KIND_BUFFER, SCOPE_FRAME, "auto_voxel_runtime_profile_container:profile_table")
	track_borrowed_rid(asset_voxel_records_buffer, KIND_BUFFER, SCOPE_FRAME, "auto_voxel_runtime_profile_container:asset_voxel_records")
	track_borrowed_rid(pivot_records_buffer, KIND_BUFFER, SCOPE_FRAME, "auto_voxel_runtime_profile_container:pivot_records")

	var asset_lookup := _build_asset_lookup(asset_defs, container_binding.get("container"), common_settings)
	var asset_lookup_bytes: PackedByteArray = asset_lookup.get("bytes", PackedByteArray())
	# Element capacity (ivec4 stride 16 B) — explicit capacity for the shader gates.
	var asset_lookup_capacity := asset_lookup_bytes.size() / 16
	var asset_lookup_buffer := storage_buffer_from_bytes(
		asset_lookup_bytes, SCOPE_FRAME, "placement_asset_lookup")
	var max_ad_count := int(asset_lookup.get("max_ad_count", 0))
	if max_ad_count <= 0:
		return _empty_placement_output(
			complexity_field, collision_field, asset_defs,
			"no_registered_asset_voxels", common_settings)

	# CurrentSV read pair: resident (BlendSV or committed SV) or packed from the
	# caller's CPU arrays.
	var complexity_field_gpu_rid: RID = VariantUtils.rid_from_value(common_settings.get("complexity_field_buffer_rid", RID()))
	var collision_field_gpu_rid: RID = VariantUtils.rid_from_value(common_settings.get("collision_field_buffer_rid", RID()))
	var gpu_resident_fields := complexity_field_gpu_rid.is_valid() and collision_field_gpu_rid.is_valid()
	var gpu_state_chain_active := gpu_resident_fields and VoxelPlacementStateChainScript._gpu_state_chain_enabled(common_settings)
	var gpu_state_chain_owner := str(common_settings.get("complexity_field_buffer_owner", "external"))
	var gpu_state_chain_source := str(common_settings.get("gpu_state_chain_source", "caller_provided_complexity_collision_field_rids"))
	var complexity_data := PackedFloat32Array() if gpu_resident_fields else VoxelGeneral.fit_float_array(complexity_field, voxel_count)
	var collision_data := PackedFloat32Array() if gpu_resident_fields else VoxelGeneral.fit_float_array(collision_field, voxel_count)
	var complexity_buffer: RID = complexity_field_gpu_rid
	var collision_buffer: RID = collision_field_gpu_rid
	if gpu_resident_fields:
		track_borrowed_rid(complexity_buffer, KIND_BUFFER, SCOPE_FRAME, "%s:complexity_field" % gpu_state_chain_owner)
		track_borrowed_rid(collision_buffer, KIND_BUFFER, SCOPE_FRAME, "%s:collision_field" % gpu_state_chain_owner)
	else:
		complexity_buffer = storage_buffer_from_bytes(
			SceneVoxelTileCodecScript.pack_complexity_field_rgba8_bytes(complexity_data, voxel_count),
			SCOPE_FRAME, "placement_complexity_field_rgba8")
		collision_buffer = storage_buffer_from_bytes(
			SceneVoxelTileCodecScript.pack_collision_field_u32_bytes(collision_data, voxel_count),
			SCOPE_FRAME, "placement_collision_field_u32")

	# TargetSV: independent field + collision pair (borrowed resident or uploaded).
	var target_buffer_pack := _target_read_buffer_pack(common_settings, voxel_count)
	if not bool(target_buffer_pack.get("ready", false)):
		var blocked_reason := str(target_buffer_pack.get("reason", "target_read_buffer_not_ready"))
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, blocked_reason), common_settings,
			{"target_read_buffer_summary": _target_read_buffer_summary(target_buffer_pack)})
	var has_target := 1 if bool(target_buffer_pack.get("has_target", false)) else 0
	var target_buffers := _resolve_target_buffers(target_buffer_pack, common_settings, voxel_count)
	var target_field_buffer: RID = target_buffers.get("target_field_buffer", RID())
	var target_collision_buffer: RID = target_buffers.get("target_collision_buffer", RID())
	if not target_field_buffer.is_valid() or not target_collision_buffer.is_valid():
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "target_field_buffer_not_ready"), common_settings,
			{"target_read_buffer_summary": _target_read_buffer_summary(target_buffer_pack)})

	# Output/working buffers.
	var candidate_buffer := storage_buffer_zero(
		maxi(anchor_capacity * topk, 1) * RECORD_STRIDE * 16, SCOPE_FRAME, "fine_candidates")
	var result_buffer := storage_buffer_zero(result_capacity * RECORD_STRIDE * 16, SCOPE_FRAME, "placement_results")
	var result_count_buffer := storage_buffer_zero(4, SCOPE_FRAME, "placement_result_count")
	var stamp_capacity := result_capacity * max_ad_count
	var stamp_delta_buffer := storage_buffer_zero(maxi(stamp_capacity, 1) * DELTA_STRIDE * 16, SCOPE_FRAME, "stamp_delta")
	var stamp_delta_count_buffer := storage_buffer_zero(4, SCOPE_FRAME, "stamp_delta_count")
	var stamp_bounds_buffer := storage_buffer_zero(maxi(result_capacity, 1) * STAMP_BOUNDS_STRIDE * 16, SCOPE_FRAME, "stamp_bounds")
	var fine_indirect_args_buffer := dispatch_indirect_args_buffer_zero(SCOPE_FRAME, "fine_score_indirect_args")

	var debug_read_voxel := bool(common_settings.get("debug_read_voxel_channels", false))
	var voxel_debug_set := DebugBufferSetScript.new(DebugBufferSetScript.VOXEL_DEBUG_CHANNELS)
	var debug_voxel_buffer := voxel_debug_set.allocate(self, voxel_count if debug_read_voxel else 1, {}, SCOPE_FRAME)
	var debug_write_mask := 1 if debug_read_voxel else 0
	var score_contract_debug_buffer := storage_buffer_from_bytes(_pack_score_contract_debug_reset())

	var contract_enabled := 1 if str(gpu_contract.get("reason", "")) == "gpu_runtime_profile_buffers_ready" else 0
	_prof.mark("setup")

	# Pass 1: finalize the indirect args in its own compute list (same pattern
	# as the prefilter: end the list before the indirect consumer reads args).
	var finalize_set0 := create_uniform_set([
		make_storage_uniform(0, anchor_count_buffer),
		make_storage_uniform(1, fine_indirect_args_buffer),
	], _shader_fine_finalize, 0, SCOPE_PASS, "fine_finalize_set0")
	var finalize_push := PushConstantLayout.new(FINE_FINALIZE_PUSH).pack({
		anchor_grid_x = ANCHOR_GRID_X,
		topk = topk,
		anchor_capacity = anchor_capacity,
	})
	ComputePassChain.run(self, [
		{pipeline = _pipeline_fine_finalize, uniform_sets = [finalize_set0], push = finalize_push, groups = Vector3i(1, 1, 1)},
	], false)

	# Pass 2..5: fine score (indirect) -> reduce -> init bounds -> stamp.
	var score_set0 := create_uniform_set([
		make_storage_uniform(0, complexity_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, target_field_buffer),
		make_storage_uniform(3, target_collision_buffer),
		make_storage_uniform(4, anchor_buffer),
		make_storage_uniform(5, anchor_count_buffer),
		make_storage_uniform(6, topk_buffer),
		make_storage_uniform(7, debug_voxel_buffer),
		make_storage_uniform(8, candidate_buffer),
	], _shader_fine_score, 0)
	var score_set1 := create_uniform_set([
		make_storage_uniform(6, profile_table_buffer),
		make_storage_uniform(8, score_contract_debug_buffer),
		make_storage_uniform(11, pivot_records_buffer),
		make_storage_uniform(13, asset_voxel_records_buffer),
		make_storage_uniform(14, asset_lookup_buffer),
	], _shader_fine_score, 1)
	var score_push := PushConstantLayout.new(FINE_SCORE_PUSH).pack({
		grid_x = grid_size.x, grid_y = grid_size.y, grid_z = grid_size.z,
		has_target = has_target,
		voxel_size_x = voxel_size.x, voxel_size_y = voxel_size.y, voxel_size_z = voxel_size.z,
		gain_threshold = score_gain_threshold,
		rotation_slots = rotation_slots,
		topk = topk,
		asset_count = mini(asset_defs.size(), MAX_ASSETS),
		anchor_capacity = anchor_capacity,
		solid_threshold = solid_threshold,
		collision_limit = collision_limit,
		clearance_limit = clearance_limit,
		complexity_write_scale = scene_write_scale,
		collision_write_scale = collision_write_scale,
		dim_w_collision = dim_weight_collision,
		dim_w_complexity = dim_weight_complexity,
		dim_w_color = dim_weight_color,
		contract_enabled = contract_enabled,
		profile_count = profile_count,
		debug_write_mask = debug_write_mask,
		asset_lookup_capacity = asset_lookup_capacity,
		profile_table_capacity = profile_table_capacity,
		asset_voxel_records_capacity = asset_voxel_records_capacity,
		pivot_records_capacity = pivot_records_capacity,
	})

	var reduce_set0 := create_uniform_set([
		make_storage_uniform(0, candidate_buffer),
		make_storage_uniform(1, anchor_count_buffer),
		make_storage_uniform(2, asset_lookup_buffer),
		make_storage_uniform(3, result_buffer),
		make_storage_uniform(4, result_count_buffer),
	], _shader_reduce, 0)
	var reduce_push := PushConstantLayout.new(REDUCE_PUSH).pack({
		topk = topk,
		result_capacity = result_capacity,
		asset_count = mini(asset_defs.size(), MAX_ASSETS),
		anchor_capacity = anchor_capacity,
		min_distance_voxels = min_distance_voxels,
	})

	var init_set0 := create_uniform_set([
		make_storage_uniform(0, stamp_bounds_buffer),
	], _shader_init_stamp_bounds, 0)
	var init_push := PushConstantLayout.new(STAMP_INIT_PUSH).pack({
		result_capacity = maxi(result_capacity, 1),
		stamp_bounds_stride = STAMP_BOUNDS_STRIDE,
	})

	# Stamp-only commit: when the read pair is a BlendSV working pair the stamp
	# double-writes the committed SV resident pair (dual_commit); otherwise the
	# commit bindings alias the read pair and the second write is skipped.
	var commit_complexity_buffer: RID = VariantUtils.rid_from_value(common_settings.get("commit_complexity_field_buffer_rid", RID()))
	var commit_collision_buffer: RID = VariantUtils.rid_from_value(common_settings.get("commit_collision_field_buffer_rid", RID()))
	var dual_commit := commit_complexity_buffer.is_valid() \
		and commit_collision_buffer.is_valid() \
		and (commit_complexity_buffer != complexity_buffer or commit_collision_buffer != collision_buffer)
	if not commit_complexity_buffer.is_valid():
		commit_complexity_buffer = complexity_buffer
	if not commit_collision_buffer.is_valid():
		commit_collision_buffer = collision_buffer
	if dual_commit:
		track_borrowed_rid(commit_complexity_buffer, KIND_BUFFER, SCOPE_FRAME, "commit:complexity_field")
		track_borrowed_rid(commit_collision_buffer, KIND_BUFFER, SCOPE_FRAME, "commit:collision_field")
	var stamp_set0 := create_uniform_set([
		make_storage_uniform(0, complexity_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, result_buffer),
		make_storage_uniform(3, result_count_buffer),
		make_storage_uniform(4, profile_table_buffer),
		make_storage_uniform(5, pivot_records_buffer),
		make_storage_uniform(6, asset_voxel_records_buffer),
		make_storage_uniform(7, stamp_delta_buffer),
		make_storage_uniform(8, stamp_delta_count_buffer),
		make_storage_uniform(9, stamp_bounds_buffer),
		make_storage_uniform(10, commit_complexity_buffer),
		make_storage_uniform(11, commit_collision_buffer),
	], _shader_stamp, 0)
	var write_min: Vector3i = common_settings.get("write_min", Vector3i.ZERO)
	var write_max: Vector3i = common_settings.get("write_max", grid_size)
	var stamp_push := PushConstantLayout.new(STAMP_PUSH).pack({
		grid_x = grid_size.x, grid_y = grid_size.y, grid_z = grid_size.z,
		rotation_slots = rotation_slots,
		write_min_x = write_min.x, write_min_y = write_min.y, write_min_z = write_min.z,
		profile_count = profile_count,
		write_max_x = write_max.x, write_max_y = write_max.y, write_max_z = write_max.z,
		stamp_delta_capacity = maxi(stamp_capacity, 0),
		solid_threshold = solid_threshold,
		complexity_write_scale = scene_write_scale,
		collision_write_scale = collision_write_scale,
		dual_commit = 1.0 if dual_commit else 0.0,
		voxel_size_x = voxel_size.x, voxel_size_y = voxel_size.y, voxel_size_z = voxel_size.z,
		profile_table_capacity = profile_table_capacity,
		asset_voxel_records_capacity = asset_voxel_records_capacity,
		pivot_records_capacity = pivot_records_capacity,
	})

	var placement_passes := [
		{pipeline = _pipeline_fine_score, uniform_sets = [score_set0, score_set1], push = score_push, indirect_args = fine_indirect_args_buffer},
		{pipeline = _pipeline_reduce, uniform_sets = [reduce_set0], push = reduce_push, groups = Vector3i(1, 1, 1)},
		{pipeline = _pipeline_init_stamp_bounds, uniform_sets = [init_set0], push = init_push, groups = Vector3i(ceil_div(maxi(result_capacity, 1), 64), 1, 1)},
		{pipeline = _pipeline_stamp, uniform_sets = [stamp_set0], push = stamp_push, groups = Vector3i(maxi(result_capacity, 1), 1, 1)},
	]
	if _prof.enabled:
		# Profile 模式：逐 pass 单独提交同步，相邻 mark 差即该 pass 的真实 GPU 耗时
		# （分段法见 ScoreTimingProfiler 类注释）。fine_score 段含 pass-1 finalize
		# （1 workgroup 写 3 uint，可忽略）；关闭时走下方单链路径，行为不变。
		var pass_names: Array[String] = ["fine_score", "reduce", "init_bounds", "stamp"]
		for i in range(placement_passes.size()):
			ComputePassChain.run(self, [placement_passes[i]], false)
			submit_and_sync(true)
			_prof.mark(pass_names[i])
	else:
		ComputePassChain.run(self, placement_passes, false)

	var retain_placement_result_buffers := gpu_direct_runtime_writeback \
		or bool(common_settings.get("retain_placement_result_buffers", false))
	var score_sum_buffer := RID()
	if retain_placement_result_buffers:
		score_sum_buffer = _dispatch_placement_score_sum(result_buffer, result_count_buffer, result_capacity)

	submit_and_sync(true)

	# Readbacks: the result records are tiny (result_capacity * 64 B), so they
	# are always read — per-asset grouping and reports need them even when the
	# resident buffers are also retained for the GPU-direct writeback.
	var result_count_data := _rd.buffer_get_data(result_count_buffer)
	var result_count := clampi(BufferUtils.decode_u32_count(result_count_data), 0, result_capacity)
	var result_data := _rd.buffer_get_data(result_buffer, 0, maxi(result_count, 0) * RECORD_STRIDE * 16)
	var results := _decode_records(result_data, result_count)
	var placement_score_sum := 0.0
	var placement_valid_count := 0
	if score_sum_buffer.is_valid():
		var score_sum_bytes := _rd.buffer_get_data(score_sum_buffer, 0, 8)
		if score_sum_bytes.size() >= 8:
			placement_score_sum = score_sum_bytes.decode_float(0)
			placement_valid_count = int(score_sum_bytes.decode_u32(4))

	var compact_state_chain := VoxelPlacementStateChainScript._compact_delta_state_chain_requested(common_settings) and not gpu_state_chain_active
	var read_stamp_deltas := bool(common_settings.get("read_stamp_deltas", false)) or compact_state_chain
	var stamp_delta_count := 0
	var decoded_stamp_deltas: Array[Dictionary] = []
	if read_stamp_deltas:
		var stamp_delta_count_data := _rd.buffer_get_data(stamp_delta_count_buffer)
		stamp_delta_count = clampi(BufferUtils.decode_u32_count(stamp_delta_count_data), 0, stamp_capacity)
		var stamp_delta_data := _rd.buffer_get_data(stamp_delta_buffer, 0, stamp_delta_count * DELTA_STRIDE * 16)
		decoded_stamp_deltas = _decode_stamp_deltas(stamp_delta_data, stamp_delta_count)
	var stamp_bounds_data := _rd.buffer_get_data(stamp_bounds_buffer, 0, result_count * STAMP_BOUNDS_STRIDE * 16)
	var stamp_bounds := _decode_stamp_bounds(stamp_bounds_data, result_count, grid_size)
	var debug_voxel_data := _rd.buffer_get_data(debug_voxel_buffer) if debug_read_voxel else PackedByteArray()
	# Observability opt-in: read the whole fine candidate pool back (one record
	# per anchor x topk slot) — demo/debug ranking data, never a production path.
	var fine_candidates: Array[Dictionary] = []
	if bool(common_settings.get("debug_read_fine_candidates", false)):
		var anchor_count_bytes := _rd.buffer_get_data(anchor_count_buffer, 0, 4)
		var live_anchor_count := clampi(BufferUtils.decode_u32_count(anchor_count_bytes), 0, anchor_capacity)
		var candidate_record_count := live_anchor_count * topk
		var candidate_bytes := _rd.buffer_get_data(candidate_buffer, 0, candidate_record_count * RECORD_STRIDE * 16)
		fine_candidates = _decode_records(candidate_bytes, candidate_record_count)
	var score_contract_debug_data := _rd.buffer_get_data(score_contract_debug_buffer)
	var score_contract_debug := _decode_score_contract_debug(score_contract_debug_data)
	gpu_contract = _annotate_score_contract_debug(gpu_contract, score_contract_debug)
	_prof.mark("readback")
	if not bool(gpu_contract.get("ok", true)):
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs, gpu_contract, common_settings)

	# CPU state update (no GPU state chain): apply the mixed stamp deltas once.
	var current_complexity := PackedFloat32Array()
	var current_collision := PackedFloat32Array()
	var compact_state_chain_report := {}
	if not gpu_resident_fields:
		current_complexity = complexity_data.duplicate()
		current_collision = collision_data.duplicate()
		if compact_state_chain:
			compact_state_chain_report = VoxelPlacementStateChainScript._apply_stamp_deltas_to_cpu_state(
				current_complexity, current_collision, decoded_stamp_deltas, grid_size)

	# World conversion. GPU-direct writeback converts on the resident buffers
	# inside the writeback dispatch; the CPU dict path serves everything else.
	var world_results: Array = []
	var world_gpu_report := {}
	if not gpu_direct_runtime_writeback and result_count > 0:
		var world_gpu := VoxelPlacementOutputScript.results_to_world_gpu(
			results, voxel_size, grid_origin, rotation_slots, {}, get_rendering_device(), pivot_records_buffer)
		world_results = world_gpu.get("world_results", []) if bool(world_gpu.get("ok", false)) else []
		world_gpu_report = world_gpu.duplicate(true)
		world_gpu_report.erase("world_results")
		world_gpu_report.erase("world_result_bytes")
	elif gpu_direct_runtime_writeback:
		world_gpu_report = {
			"ok": true,
			"reason": "resident_gpu_direct_no_cpu_world_results",
			"record_count": result_count,
			"readback_source": "none",
		}

	# Per-asset grouping for the report contract.
	var asset_results: Array[Dictionary] = []
	var per_asset_results: Array = []
	var per_asset_world: Array = []
	for _i in range(asset_defs.size()):
		per_asset_results.append([])
		per_asset_world.append([])
	for record in results:
		var record_asset := int(record.get("asset_index", -1))
		if record_asset >= 0 and record_asset < asset_defs.size():
			(per_asset_results[record_asset] as Array).append(record)
	for world_record in world_results:
		var world_asset := int(world_record.get("asset_index", -1))
		if world_asset >= 0 and world_asset < asset_defs.size():
			(per_asset_world[world_asset] as Array).append(world_record)
	var total_placed := result_count
	for i in range(asset_defs.size()):
		var asset_records: Array = per_asset_results[i]
		var asset_result := {
			"asset_index": i,
			"results": asset_records,
			"world_results": per_asset_world[i],
			"result_count": asset_records.size(),
			"rotation_slots_used": rotation_slots,
			"placement_output_gpu": world_gpu_report,
			"placement_output_readback_source": str(world_gpu_report.get("readback_source", "none")),
		}
		if gpu_contract.has("reason") and str(gpu_contract.get("reason", "")) != "not_requested":
			asset_result["cpu_fallback"] = false
		asset_results.append(_emit_multi_asset_result(asset_result, include_diagnostics))

	# GPU-direct mixed-asset runtime writeback: one dispatch for the whole pool.
	var runtime_writeback_report: Dictionary = _ensure_placement_writeback()._new_gpu_autoobject_runtime_writeback_report(
		runtime_provider, profile_container, gpu_contract,
		write_accepted_placements_to_gpu_runtime, include_diagnostics)
	if gpu_direct_runtime_writeback and result_count > 0:
		var writeback: Dictionary = _ensure_placement_writeback()._write_mixed_accepted_placements_to_gpu_runtime(
			runtime_provider,
			{
				"placement_results_rid": result_buffer,
				"stamp_bounds_rid": stamp_bounds_buffer,
				"result_count": result_count,
				"asset_lookup_capacity": asset_lookup_capacity,
			},
			asset_lookup_buffer,
			pivot_records_buffer,
			rotation_slots,
			common_settings,
			{
				"grid_size": grid_size,
				"voxel_size": voxel_size,
				"grid_origin": grid_origin,
			}
		)
		_ensure_placement_writeback()._merge_gpu_autoobject_runtime_writeback_report(runtime_writeback_report, writeback)

	# Optional resident handoff for callers that keep consuming the buffers
	# after this run (untracked RIDs survive _free_gpu; caller frees them via
	# _release_placement_result_buffers).
	var placement_result_buffers := {}
	if bool(common_settings.get("retain_placement_result_buffers", false)):
		placement_result_buffers = {
			"placement_results_rid": untrack_rid(result_buffer),
			"result_count_rid": untrack_rid(result_count_buffer),
			"stamp_bounds_rid": untrack_rid(stamp_bounds_buffer),
			"result_capacity": result_capacity,
			"result_count": result_count,
			"owner": "VoxelPlacementGenerator",
			"rendering_device": _rd,
		}

	var output := {
		"asset_results": asset_results,
		"complexity_field_out": current_complexity,
		"collision_field_out": current_collision,
		"total_placed": total_placed,
		"processing_order": range(asset_defs.size()),
		"gpu_runtime_profile_contract": gpu_contract,
		"anchor_fine_contract": {
			"origin_contract": "one_origin_per_anchor",
			"origin_count_source": "anchor_count_buffer",
			"anchor_capacity": anchor_capacity,
			"topk": topk,
			"asset_count": mini(asset_defs.size(), MAX_ASSETS),
			"candidate_pool": "anchor_x_topk_asset_x_pivot_x_yaw",
			"score_model": "residual_gain",
			"gain_threshold": score_gain_threshold,
			"consumed_by_vpg": true,
		},
		"target_read_buffer_summary": _target_read_buffer_summary(target_buffer_pack),
	}
	if not placement_result_buffers.is_empty():
		output["placement_result_buffers"] = placement_result_buffers
		output["placement_score_sum"] = placement_score_sum
		output["placement_valid_count"] = placement_valid_count
	elif retain_placement_result_buffers:
		output["placement_score_sum"] = placement_score_sum
		output["placement_valid_count"] = placement_valid_count
	if read_stamp_deltas:
		output["stamp_delta_count"] = stamp_delta_count
	if not stamp_bounds.is_empty():
		output["stamp_bounds"] = stamp_bounds
	if debug_read_voxel:
		output["debug_voxel"] = voxel_debug_set.readback(self, debug_voxel_data).get("data", PackedFloat32Array())
	if bool(common_settings.get("debug_read_fine_candidates", false)):
		output["fine_candidates"] = fine_candidates
	if gpu_state_chain_active:
		output["gpu_state_chain"] = {
			"mode": "gpu_resident",
			"source": gpu_state_chain_source,
			"gpu_state_chaining": true,
			"cpu_state_chaining": false,
			"full_field_readback_required": false,
			"stamp_delta_cpu_state_chaining": false,
			"read_full_field_outputs": false,
			"complexity_field_buffer_rid": complexity_field_gpu_rid,
			"collision_field_buffer_rid": collision_field_gpu_rid,
			"complexity_field_buffer_borrowed": true,
			"collision_field_buffer_borrowed": true,
			"owner": gpu_state_chain_owner,
			"borrowed_from": gpu_state_chain_owner,
			"blocked_reason": "none",
		}
		output["instance_stamp_writeback"] = {
			"ok": true,
			"reason": "gpu_state_chain_stamp_committed",
			"gpu_first": true,
			"cpu_fallback": false,
			"accepted_placement_writeback_mode": "gpu_state_chain_stamp",
			"applied_count": total_placed,
			"failed_count": 0,
			"commit_owner": gpu_state_chain_owner,
		}
		if bool(common_settings.get("read_full_field_outputs", false)):
			submit_and_sync(true)
			var scene_out := _rd.buffer_get_data(complexity_field_gpu_rid)
			var collision_out := _rd.buffer_get_data(collision_field_gpu_rid)
			output["complexity_field_out"] = SceneVoxelTileCodecScript.decode_complexity_field_rgba8_alpha_bytes(scene_out, voxel_count)
			output["collision_field_out"] = SceneVoxelTileCodecScript.decode_collision_field_u32_bytes(collision_out, voxel_count)
	elif compact_state_chain:
		compact_state_chain_report["asset_index"] = -1
		compact_state_chain_report["result_count"] = result_count
		output["cpu_state_chain"] = {
			"mode": "compact_stamp_deltas",
			"source": "stamp_shader_storage_buffer",
			"cpu_state_chaining": true,
			"full_field_readback_required": false,
			"stamp_delta_cpu_state_chaining": true,
			"read_stamp_deltas": true,
			"asset_reports": [compact_state_chain_report],
			"applied_delta_count": int(compact_state_chain_report.get("applied_delta_count", 0)),
		}
	if write_accepted_placements_to_gpu_runtime:
		output["gpu_autoobject_runtime_writeback"] = ReportSchema.validate_report(
			ReportSchema.WRITEBACK_REPORT, runtime_writeback_report, include_diagnostics)
	if str(gpu_contract.get("reason", "")) != "not_requested":
		output["cpu_fallback"] = false
	_prof.mark("done")
	if _prof.enabled:
		output["score_timing_profile"] = _prof.build_report()
		print(_prof.format_report())
	return _emit_multi_asset_report(output, include_diagnostics)


## Demo/test convenience: builds an anchor handoff dict structurally identical
## to the prefilter's from a CPU anchor list. Every anchor gets the same top-K
## slots (slot k = asset k while k < asset_count, empty beyond), so ALL assets
## enter the fine score at every anchor — ranking/observability runs, not the
## production coarse->fine route. The caller owns (and must free) the 3 RIDs.
static func build_cpu_anchor_handoff(rd: RenderingDevice, anchors: Array, asset_count: int, topk: int = -1) -> Dictionary:
	if rd == null or anchors.is_empty():
		return {"ok": false, "reason": "missing_rendering_device_or_anchors"}
	var anchor_capacity := anchors.size()
	var slots := maxi(topk if topk > 0 else asset_count, 1)
	var anchor_bytes := PackedByteArray()
	anchor_bytes.resize(anchor_capacity * 16)
	var topk_bytes := PackedByteArray()
	topk_bytes.resize(anchor_capacity * slots * 8)
	for i in range(anchor_capacity):
		var p := VoxelGeneral.vector3i_from_value(anchors[i], Vector3i.ZERO)
		var base := i * 16
		anchor_bytes.encode_u32(base + 0, maxi(p.x, 0))
		anchor_bytes.encode_u32(base + 4, maxi(p.y, 0))
		anchor_bytes.encode_u32(base + 8, maxi(p.z, 0))
		anchor_bytes.encode_u32(base + 12, 0)
		for k in range(slots):
			var entry := (i * slots + k) * 8
			if k < asset_count:
				topk_bytes.encode_u32(entry + 0, k)
				topk_bytes.encode_float(entry + 4, 1.0)
			else:
				topk_bytes.encode_u32(entry + 0, 0xFFFFFFFF)
				topk_bytes.encode_float(entry + 4, -1.0)
	var count_bytes := PackedByteArray()
	count_bytes.resize(4)
	count_bytes.encode_u32(0, anchor_capacity)
	var anchor_buffer := rd.storage_buffer_create(anchor_bytes.size(), anchor_bytes)
	var count_buffer := rd.storage_buffer_create(count_bytes.size(), count_bytes)
	var topk_buffer := rd.storage_buffer_create(topk_bytes.size(), topk_bytes)
	if not anchor_buffer.is_valid() or not count_buffer.is_valid() or not topk_buffer.is_valid():
		for rid in [anchor_buffer, count_buffer, topk_buffer]:
			if (rid as RID).is_valid():
				rd.free_rid(rid)
		return {"ok": false, "reason": "buffer_create_failed"}
	return {
		"ok": true,
		"anchor_buffer_rid": anchor_buffer,
		"anchor_count_buffer_rid": count_buffer,
		"topk_buffer_rid": topk_buffer,
		"anchor_capacity": anchor_capacity,
		"topk": slots,
		"asset_count": asset_count,
		"anchor_stride_bytes": 16,
		"topk_stride_bytes": 8,
		"origin_contract": "one_origin_per_anchor",
		"producer": "cpu_anchor_handoff",
		"owner": "caller",
		"gpu_first": true,
	}


## Frees the three RIDs of a build_cpu_anchor_handoff dict (idempotent).
static func release_cpu_anchor_handoff(rd: RenderingDevice, handoff: Dictionary) -> void:
	if rd == null:
		return
	for key in ["anchor_buffer_rid", "anchor_count_buffer_rid", "topk_buffer_rid"]:
		var rid_value = handoff.get(key, RID())
		if rid_value is RID and (rid_value as RID).is_valid():
			rd.free_rid(rid_value)


## Validates and unpacks the prefilter's resident anchor handoff. This is the
## ONLY candidate source: missing/invalid handoff hard-fails (no all-tiles or
## CPU fallback).
func _resolve_anchor_candidate_handoff(settings: Dictionary) -> Dictionary:
	var raw = settings.get("anchor_candidate_handoff", null)
	if not (raw is Dictionary) or (raw as Dictionary).is_empty():
		return {"ok": false, "reason": "missing_anchor_candidate_handoff"}
	var handoff := raw as Dictionary
	if not bool(handoff.get("ok", false)):
		return {"ok": false, "reason": str(handoff.get("reason", "handoff_not_ok"))}
	var origin_contract := str(handoff.get("origin_contract", ""))
	if origin_contract != "one_origin_per_anchor":
		return {"ok": false, "reason": "origin_contract_mismatch:%s" % origin_contract}
	var anchor_buffer: RID = VariantUtils.rid_from_value(handoff.get("anchor_buffer_rid", RID()))
	var anchor_count_buffer: RID = VariantUtils.rid_from_value(handoff.get("anchor_count_buffer_rid", RID()))
	var topk_buffer: RID = VariantUtils.rid_from_value(handoff.get("topk_buffer_rid", RID()))
	if not anchor_buffer.is_valid() or not anchor_count_buffer.is_valid() or not topk_buffer.is_valid():
		return {"ok": false, "reason": "anchor_handoff_rid_invalid"}
	var anchor_capacity := int(handoff.get("anchor_capacity", 0))
	var topk := int(handoff.get("topk", 0))
	if anchor_capacity <= 0 or topk <= 0:
		return {"ok": false, "reason": "anchor_handoff_capacity_invalid"}
	return {
		"ok": true,
		"reason": "ok",
		"anchor_buffer_rid": anchor_buffer,
		"anchor_count_buffer_rid": anchor_count_buffer,
		"topk_buffer_rid": topk_buffer,
		"anchor_capacity": anchor_capacity,
		"topk": topk,
		"asset_count": int(handoff.get("asset_count", 0)),
	}


## Resolves the profile container's resident buffers (asset shape + pivot
## source of truth) and aligns this generator to the container's device.
func _resolve_profile_container_buffers(settings: Dictionary) -> Dictionary:
	var container = _config_object(settings, GPU_PROFILE_CONTAINER_CONFIG_KEY)
	if container == null:
		return {"ok": false, "reason": "missing_auto_voxel_runtime_profile_container"}
	if not _object_bool(container, "is_runtime_ready", "is_gpu_ready"):
		return {"ok": false, "reason": "auto_voxel_runtime_profile_container_not_ready"}
	var container_rd: RenderingDevice = rendering_device_of(container)
	if container_rd == null:
		return {"ok": false, "reason": "container_missing_rendering_device"}
	if get_rendering_device() == null:
		if not attach_rendering_device(container_rd, false):
			return {"ok": false, "reason": "vpg_attach_rendering_device_failed"}
	elif get_rendering_device() != container_rd:
		return {"ok": false, "reason": "rendering_device_mismatch"}
	var profile_table_buffer: RID = container.call("get_gpu_buffer", "profile_table")
	var asset_voxel_records_buffer: RID = RID()
	if container.has_method("get_asset_voxel_records_buffer"):
		asset_voxel_records_buffer = container.get_asset_voxel_records_buffer()
	var pivot_records_buffer: RID = container.call("get_gpu_buffer", "pivot_records")
	if not profile_table_buffer.is_valid() or not asset_voxel_records_buffer.is_valid() or not pivot_records_buffer.is_valid():
		return {"ok": false, "reason": "missing_auto_voxel_profile_buffers"}
	var profile_count := 0
	if container.has_method("get_profile_count"):
		profile_count = int(container.get_profile_count())
	return {
		"ok": true,
		"reason": "ok",
		"container": container,
		"profile_table_buffer": profile_table_buffer,
		"asset_voxel_records_buffer": asset_voxel_records_buffer,
		"pivot_records_buffer": pivot_records_buffer,
		"profile_count": profile_count,
		# Element capacities from the allocation point — passed to the score/
		# stamp shaders as explicit push values for their capacity gates.
		"profile_table_capacity": _container_record_count(container, "profile_table"),
		"asset_voxel_records_capacity": _container_record_count(container, "asset_voxel_records"),
		"pivot_records_capacity": _container_record_count(container, "pivot_records"),
	}


## 容量守卫用的显式元素数（等价于 shader 侧原 buffer.length()）：优先容器的
## get_gpu_record_count，缺失时退回 get_gpu_buffer_summary 的 record_count。
func _container_record_count(container, buffer_name: String) -> int:
	if container.has_method("get_gpu_record_count"):
		return maxi(int(container.get_gpu_record_count(buffer_name)), 0)
	if container.has_method("get_gpu_buffer_summary"):
		var raw_summary = container.get_gpu_buffer_summary()
		if raw_summary is Dictionary:
			var buffers: Dictionary = (raw_summary as Dictionary).get("buffers", {})
			var entry_value = buffers.get(buffer_name, {})
			if entry_value is Dictionary:
				return maxi(int((entry_value as Dictionary).get("record_count", 0)), 0)
	return 0


## Packs the asset_lookup ivec4 stream: asset_index -> (profile_id,
## profile_index, quota, object_type). Assets whose profile has no baked AD
## voxels get profile_index -1 (the scorer writes invalid records for them).
## quota <= 0 means unlimited; per-asset quota comes from asset_def.quota or
## asset_def.result_capacity.
func _build_asset_lookup(asset_defs: Array, container, common_settings: Dictionary) -> Dictionary:
	var profile_index_by_id := {}
	if container != null and container.has_method("export_profile_table"):
		for entry in container.export_profile_table():
			if entry is Dictionary:
				profile_index_by_id[int((entry as Dictionary).get("profile_id", -1))] = int((entry as Dictionary).get("profile_index", -1))
	var count := mini(asset_defs.size(), MAX_ASSETS)
	var bytes := PackedByteArray()
	bytes.resize(maxi(count, 1) * 16)
	var max_ad_count := 0
	for i in range(count):
		var asset_def: Dictionary = asset_defs[i] if asset_defs[i] is Dictionary else {}
		var profile_id := int(asset_def.get("profile_id", -1))
		var ad_count := 0
		if container != null and container.has_method("get_asset_voxel_range_for_profile_id"):
			ad_count = int((container.get_asset_voxel_range_for_profile_id(profile_id) as Dictionary).get("count", 0))
		var profile_index := int(profile_index_by_id.get(profile_id, -1)) if ad_count > 0 else -1
		var quota := int(asset_def.get("quota", asset_def.get("result_capacity", 0)))
		var object_type := VoxelPlacementWritebackScript._runtime_writeback_object_type(asset_def, {}, common_settings)
		max_ad_count = maxi(max_ad_count, ad_count)
		var base := i * 16
		bytes.encode_s32(base + 0, profile_id)
		bytes.encode_s32(base + 4, profile_index)
		bytes.encode_s32(base + 8, quota)
		bytes.encode_s32(base + 12, object_type)
	return {"bytes": bytes, "max_ad_count": max_ad_count, "asset_count": count}


## Resolves the TargetSV field + collision buffer pair from the target reader
## pack: borrowed resident pair, uploaded target_field floats, or uploaded
## rgba8 color unpacked on the GPU. The collision half falls back to a zeroed
## r8 buffer when no target collision input exists.
func _resolve_target_buffers(target_buffer_pack: Dictionary, settings: Dictionary, voxel_count: int) -> Dictionary:
	var target_field_buffer: RID = target_buffer_pack.get("target_field_buffer", RID())
	var target_collision_buffer: RID = target_buffer_pack.get("target_collision_buffer", RID())
	if bool(target_buffer_pack.get("target_read_buffers_borrowed", false)):
		track_borrowed_rid(target_field_buffer, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_field")
		if target_collision_buffer.is_valid():
			track_borrowed_rid(target_collision_buffer, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_collision")
	elif bool(target_buffer_pack.get("target_field_bytes_uploaded", false)):
		var target_field_data: PackedFloat32Array = target_buffer_pack.get("target_field_bytes", PackedFloat32Array())
		target_field_buffer = storage_buffer_from_floats(target_field_data, SCOPE_FRAME, "target_field_uploaded")
		target_collision_buffer = RID()
	else:
		var target_color_buffer := storage_buffer_from_bytes(
			target_buffer_pack.get("target_visual_rgba8_bytes", PackedByteArray()),
			SCOPE_FRAME, "target_visual_rgba8_uploaded")
		target_field_buffer = _unpack_target_field_buffer(target_color_buffer, voxel_count)
		target_collision_buffer = RID()
	if not target_collision_buffer.is_valid():
		var collision_bytes := VoxelPlacementTargetReaderScript.target_collision_r8_bytes_from_settings(settings, voxel_count)
		var expected := SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count)
		if collision_bytes.size() == expected:
			target_collision_buffer = storage_buffer_from_bytes(collision_bytes, SCOPE_FRAME, "target_collision_uploaded")
		else:
			target_collision_buffer = storage_buffer_zero(expected, SCOPE_FRAME, "target_collision_zero")
	return {
		"target_field_buffer": target_field_buffer,
		"target_collision_buffer": target_collision_buffer,
	}


## Unpacks uploaded rgba8 target color into the vec4 target_field buffer on
## the GPU (pack_target_field.glsl passthrough: rgb = color, a = complexity).
func _unpack_target_field_buffer(target_color_buffer: RID, voxel_count: int) -> RID:
	if not target_color_buffer.is_valid():
		return storage_buffer_zero(voxel_count * 16, SCOPE_FRAME, "target_field_zero")
	if not _pipeline_pack_target_field.is_valid() or not _shader_pack_target_field.is_valid():
		push_error("[VoxelPlacementGenerator] pack_target_field pipeline not ready")
		return RID()
	var output_buffer := storage_buffer_zero(voxel_count * 16, SCOPE_FRAME, "target_field_combined")
	if not output_buffer.is_valid():
		return RID()
	var set0 := create_uniform_set([
		make_storage_uniform(0, target_color_buffer),
		make_storage_uniform(1, output_buffer),
	], _shader_pack_target_field, 0)
	if not set0.is_valid():
		release_rid(output_buffer)
		return RID()
	var push := PushConstantLayout.new(PACK_TARGET_FIELD_PUSH).pack({
		voxel_count = voxel_count,
	})
	ComputePassChain.run(self, [
		{pipeline = _pipeline_pack_target_field, uniform_sets = [set0], push = push, groups = Vector3i(ceil_div(maxi(voxel_count, 1), 64), 1, 1)},
	], false)
	return output_buffer


## 当 GPU 运行时契约校验失败时，为 run_multi_asset 构造统一的"已阻断"空结果：
## 为每个资产生成占位失败结果，并原样返回输入的 complexity/collision 字段。
func _gpu_contract_blocked_multi_asset_output(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	contract: Dictionary,
	settings: Dictionary = {},
	extra: Dictionary = {}
) -> Dictionary:
	var include_diagnostics := bool(settings.get("include_diagnostics", false))
	var asset_results: Array[Dictionary] = []
	for i in range(asset_defs.size()):
		asset_results.append(_emit_multi_asset_result({
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
		}, include_diagnostics))
	var values := {
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
	}
	for key in extra:
		values[key] = extra[key]
	return _emit_multi_asset_report(values, include_diagnostics)


## 空候选/空资产形状时的空结果（非契约阻断，正常空帧）。
func _empty_placement_output(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	reason: String,
	settings: Dictionary
) -> Dictionary:
	var include_diagnostics := bool(settings.get("include_diagnostics", false))
	var asset_results: Array[Dictionary] = []
	for i in range(asset_defs.size()):
		asset_results.append(_emit_multi_asset_result({
			"asset_index": i, "results": [], "world_results": [], "result_count": 0,
		}, include_diagnostics))
	return _emit_multi_asset_report({
		"asset_results": asset_results,
		"complexity_field_out": complexity_field.duplicate(),
		"collision_field_out": collision_field.duplicate(),
		"total_placed": 0,
		"processing_order": [],
		"anchor_fine_contract": {
			"origin_contract": "one_origin_per_anchor",
			"origin_count_source": "anchor_count_buffer",
			"consumed_by_vpg": false,
			"skipped_reason": reason,
		},
	}, include_diagnostics)


## 唯一发射口：run_multi_asset 顶层输出族一律经 ReportSchema.build 组装
##（键清单/分级/消费者名单见 ReportSchema.VPG_MULTI_ASSET_REPORT）。
func _emit_multi_asset_report(values: Dictionary, include_diagnostics: bool = false) -> Dictionary:
	return ReportSchema.build(ReportSchema.VPG_MULTI_ASSET_REPORT, values, include_diagnostics)


## 唯一发射口：per-asset asset_result 族一律经 ReportSchema.build 组装
##（键清单/分级/消费者名单见 ReportSchema.VPG_MULTI_ASSET_RESULT）。
func _emit_multi_asset_result(values: Dictionary, include_diagnostics: bool = false) -> Dictionary:
	return ReportSchema.build(ReportSchema.VPG_MULTI_ASSET_RESULT, values, include_diagnostics)


## 将 settings 字典中的可选覆盖值应用到打分/放置相关成员变量，并做取值范围钳制。
func _apply_settings(settings: Dictionary) -> void:
	result_capacity = maxi(int(settings.get("result_capacity", result_capacity)), 1)
	solid_threshold = float(settings.get("solid_threshold", solid_threshold))
	collision_limit = float(settings.get("collision_limit", collision_limit))
	clearance_limit = float(settings.get("clearance_limit", clearance_limit))
	min_distance_voxels = float(settings.get("min_distance_voxels", min_distance_voxels))
	scene_write_scale = float(settings.get("scene_write_scale", scene_write_scale))
	collision_write_scale = float(settings.get("collision_write_scale", collision_write_scale))
	rotation_slots = maxi(int(settings.get("rotation_slots", rotation_slots)), 1)
	score_gain_threshold = float(settings.get("score_gain_threshold", score_gain_threshold))
	var dim_weights = settings.get("residual_dim_weights", null)
	if dim_weights is Array and (dim_weights as Array).size() >= 3:
		dim_weight_collision = maxf(float((dim_weights as Array)[0]), 0.0)
		dim_weight_complexity = maxf(float((dim_weights as Array)[1]), 0.0)
		dim_weight_color = maxf(float((dim_weights as Array)[2]), 0.0)
	var global_quota := int(settings.get("global_quota", -1))
	if global_quota > 0:
		result_capacity = mini(result_capacity, global_quota)


## 校验 GPU 自动物体运行时与体素画像容器是否就绪、渲染设备是否一致、
## 所需 GPU 缓冲区是否齐全，构建并返回 gpu_runtime_profile_contract 校验结果。
func _validate_gpu_runtime_profile_contract(settings: Dictionary) -> Dictionary:
	var runtime_provider = _config_object(settings, GPU_RUNTIME_PROVIDER_CONFIG_KEY)
	var profile_container = _config_object(settings, GPU_PROFILE_CONTAINER_CONFIG_KEY)
	var require_contract := bool(settings.get("require_gpu_runtime_profile_contract", false))
	if runtime_provider == null and profile_container == null:
		if require_contract:
			return _gpu_contract_result(false, "missing_gpu_runtime_profile_contract")
		return _gpu_contract_result(true, "not_requested")
	if runtime_provider == null:
		# 容器单独存在是合法的"形状来源"配置——asset_voxel_records 的读取由
		# _resolve_profile_container_buffers 独立解析；只有显式 require（GPU 直写
		# 回写路径）才把缺 runtime 视为契约失败。
		if require_contract:
			return _gpu_contract_result(false, "missing_gpu_autoobject_runtime")
		return _gpu_contract_result(true, "not_requested")
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
	return result


## 从 settings 按 key 取出配置对象；不存在或类型不为 Object 时返回 null。
func _config_object(settings: Dictionary, key: String) -> Object:
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


## 加载各计算着色器并创建对应的计算管线（fine finalize/score、公共 reduce、
## stamp bounds 初始化、mixed-asset stamp、目标场解包）。
func _load_shaders() -> void:
	if _placement_pipeline_ready():
		return
	_shader_fine_finalize = load_compute_shader("res://shaders/fine_score_dispatch_finalize.glsl")
	_shader_fine_score = load_compute_shader("res://shaders/score_anchor_asset_residual.glsl")
	_shader_reduce = load_compute_shader("res://shaders/reduce_anchor_candidates.glsl")
	_shader_init_stamp_bounds = load_compute_shader("res://shaders/init_stamp_bounds.glsl")
	_shader_stamp = load_compute_shader("res://shaders/stamp_asset_voxels.glsl")
	_shader_pack_target_field = load_compute_shader("res://shaders/pack_target_field.glsl")
	if _shader_fine_finalize.is_valid():
		_pipeline_fine_finalize = create_compute_pipeline(_shader_fine_finalize)
	if _shader_fine_score.is_valid():
		_pipeline_fine_score = create_compute_pipeline(_shader_fine_score)
	if _shader_reduce.is_valid():
		_pipeline_reduce = create_compute_pipeline(_shader_reduce)
	if _shader_init_stamp_bounds.is_valid():
		_pipeline_init_stamp_bounds = create_compute_pipeline(_shader_init_stamp_bounds)
	if _shader_stamp.is_valid():
		_pipeline_stamp = create_compute_pipeline(_shader_stamp)
	if _shader_pack_target_field.is_valid():
		_pipeline_pack_target_field = create_compute_pipeline(_shader_pack_target_field)


## 检查放置流程所需的全部着色器与计算管线是否均已有效创建。
func _placement_pipeline_ready() -> bool:
	return _shader_fine_finalize.is_valid() \
		and _shader_fine_score.is_valid() \
		and _shader_reduce.is_valid() \
		and _shader_init_stamp_bounds.is_valid() \
		and _shader_stamp.is_valid() \
		and _shader_pack_target_field.is_valid() \
		and _pipeline_fine_finalize.is_valid() \
		and _pipeline_fine_score.is_valid() \
		and _pipeline_reduce.is_valid() \
		and _pipeline_init_stamp_bounds.is_valid() \
		and _pipeline_stamp.is_valid() \
		and _pipeline_pack_target_field.is_valid()


## 在常驻 result 记录上调度分数求和 pass，输出 8 字节控制标量（residual gain
## 总和 + 有效数），供报告消费，免除额外回读。
func _dispatch_placement_score_sum(result_buffer: RID, result_count_buffer: RID, capacity: int) -> RID:
	var shader := load_compute_shader(SCORE_SUM_SHADER_PATH, SCOPE_FRAME, "placement_result_score_sum")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "placement_result_score_sum")
	if not shader.is_valid() or not pipeline.is_valid():
		return RID()
	var score_sum_buffer := storage_buffer_zero(8, SCOPE_FRAME, "placement_score_sum_out")
	if not score_sum_buffer.is_valid():
		return RID()
	var set0 := create_uniform_set([
		make_storage_uniform(0, result_buffer),
		make_storage_uniform(1, result_count_buffer),
		make_storage_uniform(2, score_sum_buffer),
	], shader, 0, SCOPE_PASS, "placement_result_score_sum_set0")
	if not set0.is_valid():
		return RID()
	var push := PushConstantLayout.new(SCORE_SUM_PUSH).pack({
		result_capacity = capacity,
		record_stride = RECORD_STRIDE,
	})
	ComputePassChain.run(self, [
		{pipeline = pipeline, uniform_sets = [set0], push = push, groups = Vector3i(1, 1, 1)},
	], false)
	return score_sum_buffer


## 释放 run_multi_asset 交接出的常驻 placement 缓冲区 RID（untrack 后由调用方负责生命周期），
## 幂等：释放后清空 handoff 字典。gpu_out 可为 run_multi_asset 输出或 asset_result。
func _release_placement_result_buffers(gpu_out: Dictionary) -> void:
	if gpu_out.is_empty():
		return
	var handoff: Dictionary = gpu_out.get("placement_result_buffers", {})
	if handoff.is_empty():
		return
	var raw_handoff_rd = handoff.get("rendering_device", null)
	var handoff_rd: RenderingDevice = raw_handoff_rd if raw_handoff_rd is RenderingDevice else _rd
	for key in ["placement_results_rid", "result_count_rid", "stamp_bounds_rid"]:
		var rid_value = handoff.get(key, RID())
		if rid_value is RID and (rid_value as RID).is_valid():
			if handoff_rd != null:
				handoff_rd.free_rid(rid_value)
			else:
				release_rid(rid_value, false)
	gpu_out["placement_result_buffers"] = {}


## 释放本生成器持有的 GPU 资源（各计算管线与着色器 RID 全部重置），并调用 dispose 清理其余借用资源。
func _free_gpu() -> void:
	dispose()
	_pipeline_fine_finalize = RID()
	_pipeline_fine_score = RID()
	_pipeline_reduce = RID()
	_pipeline_init_stamp_bounds = RID()
	_pipeline_stamp = RID()
	_pipeline_pack_target_field = RID()
	_shader_fine_finalize = RID()
	_shader_fine_score = RID()
	_shader_reduce = RID()
	_shader_init_stamp_bounds = RID()
	_shader_stamp = RID()
	_shader_pack_target_field = RID()


## 将 score 着色器写回的原始调试计数缓冲区字节解码为带命名字段的字典，
## 字段名称对应 DebugBufferSet(SCORE_CONTRACT_STATS) 定义的 48 槽布局。
func _decode_score_contract_debug(bytes: PackedByteArray) -> Dictionary:
	var decoded := DebugBufferSetScript.new(DebugBufferSetScript.SCORE_CONTRACT_STATS).readback(self, bytes)
	var words: PackedInt32Array = decoded.get("words", PackedInt32Array())
	return {
		"read_source": "score_shader_storage_buffer",
		"word_count": int(decoded.get("word_count", 0)),
		"words": words,
		"values": decoded.get("values", {}),
		"magic_ok": bool(decoded.get("magic_ok", false)),
		"contract_enabled": int(words[1]) != 0 if words.size() > 1 else false,
		"profile_count": int(words[3]) if words.size() > 3 else 0,
		"profile_table_reads": int(words[8]) if words.size() > 8 else 0,
		"asset_profile_id": int(words[9]) if words.size() > 9 else 0,
		"candidate_invocations": int(words[10]) if words.size() > 10 else 0,
		"pivot_record_reads": int(words[16]) if words.size() > 16 else 0,
		"profile_pivot_count": int(words[22]) if words.size() > 22 else 0,
	}


## 生成用于重置的 score 调试缓冲区字节数据，仅写入用于校验的魔数（magic）。
func _pack_score_contract_debug_reset() -> PackedByteArray:
	return DebugBufferSetScript.new(DebugBufferSetScript.SCORE_CONTRACT_STATS).reset_bytes()


## 结合 score 着色器实际写回的调试计数，对 gpu_contract 进行事后标注：
## 按 anchor-fine contract 校验着色器是否真正绑定并消费了 profile 侧缓冲区
##（profile table / pivot records / candidate 遍历）。runtime 侧缓冲区不再由
## score 着色器消费（旧 avoidance/spacing gate 已随 tile 细筛裁撤），仅保留
## 存在性校验（_validate_gpu_runtime_profile_contract）。
func _annotate_score_contract_debug(gpu_contract: Dictionary, score_contract_debug: Dictionary) -> Dictionary:
	var annotated := gpu_contract.duplicate(true)
	if str(annotated.get("reason", "")) == "gpu_runtime_profile_buffers_ready":
		annotated["score_shader_bound_runtime_profile_buffers"] = bool(score_contract_debug.get("magic_ok", false)) \
			and bool(score_contract_debug.get("contract_enabled", false))
		annotated["score_shader_consumed_profile_buffers"] = int(score_contract_debug.get("profile_table_reads", 0)) > 0
		annotated["score_shader_candidate_invocations"] = int(score_contract_debug.get("candidate_invocations", 0))
		annotated["score_shader_pivot_record_reads"] = int(score_contract_debug.get("pivot_record_reads", 0))
		if not bool(annotated.get("score_shader_bound_runtime_profile_buffers", false)):
			annotated["ok"] = false
			annotated["reason"] = "score_runtime_profile_binding_missing"
		elif int(score_contract_debug.get("candidate_invocations", 0)) > 0 \
				and not bool(annotated.get("score_shader_consumed_profile_buffers", false)):
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


## 将 GPU 结果缓冲区中的原始字节解码为放置结果记录数组（Array[Dictionary]）。
## 记录布局（4 × vec4）：
##   [0] origin.xyz, residual gain；[1] anchor_id, asset_index, yaw_slot,
##   global_pivot_index；[2] solid_collision, loss_before, loss_after,
##   clearance_overlap；[3] profile_index, valid, coarse probe score, reserved。
func _decode_records(bytes: PackedByteArray, record_count: int) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var byte_stride := RECORD_STRIDE * 16
	var available := BufferUtils.decoded_record_count(bytes, record_count, byte_stride)
	for i in range(available):
		var base := i * byte_stride
		var origin_score := BufferUtils.decode_vec4(bytes, base + 0)
		var anchor_meta := BufferUtils.decode_vec4(bytes, base + 16)
		var loss_meta := BufferUtils.decode_vec4(bytes, base + 32)
		var validity_meta := BufferUtils.decode_vec4(bytes, base + 48)
		records.append({
			"voxel_origin": Vector3i(
				int(roundf(origin_score.x)),
				int(roundf(origin_score.y)),
				int(roundf(origin_score.z))
			),
			"score": origin_score.w,
			"anchor_id": int(roundf(anchor_meta.x)),
			"asset_index": int(roundf(anchor_meta.y)),
			"rotation_index": int(roundf(anchor_meta.z)),
			"global_pivot_index": int(roundf(anchor_meta.w)),
			"solid_collision": loss_meta.x,
			"loss_before": loss_meta.y,
			"loss_after": loss_meta.z,
			"clearance_overlap": loss_meta.w,
			"profile_index": int(roundf(validity_meta.x)),
			"valid": validity_meta.y > 0.5,
			"coarse_score": validity_meta.z,
		})
	return records


## 将 GPU stamp 着色器输出的原始字节解码为体素增量（stamp delta）记录数组。
func _decode_stamp_deltas(bytes: PackedByteArray, delta_count: int) -> Array[Dictionary]:
	var deltas: Array[Dictionary] = []
	var byte_stride := DELTA_STRIDE * 16
	var available := BufferUtils.decoded_record_count(bytes, delta_count, byte_stride)
	for i in range(available):
		var base := i * byte_stride
		var pos_scene := BufferUtils.decode_vec4(bytes, base + 0)
		var collision_meta := BufferUtils.decode_vec4(bytes, base + 16)
		if collision_meta.w <= 0.5:
			continue
		deltas.append({
			"voxel": Vector3i(int(roundf(pos_scene.x)), int(roundf(pos_scene.y)), int(roundf(pos_scene.z))),
			"complexity": pos_scene.w,
			"collision_strength": collision_meta.x,
			"result_index": int(roundf(collision_meta.y)),
			"sample_index": int(roundf(collision_meta.z)),
		})
	return deltas


## 将 GPU stamp bounds 缓冲区的原始字节解码为每次 stamp 写入的包围盒记录。
func _decode_stamp_bounds(bytes: PackedByteArray, bound_count: int, grid_size: Vector3i) -> Array[Dictionary]:
	var bounds: Array[Dictionary] = []
	var byte_stride := STAMP_BOUNDS_STRIDE * 16
	var available := BufferUtils.decoded_record_count(bytes, bound_count, byte_stride)
	for i in range(available):
		var base := i * byte_stride
		var written_count := int(bytes.decode_u32(base + 12))
		if written_count <= 0:
			continue
		var voxel_min := _decode_grid_clamped_vec3i(bytes, base, grid_size)
		var voxel_max := _decode_grid_clamped_vec3i(bytes, base + 16, grid_size)
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


## 从 stamp bounds 缓冲区中连续的 3 个 u32 字（word_offset 起）解码出体素坐标，并按 grid_size 逐轴裁剪。
static func _decode_grid_clamped_vec3i(bytes: PackedByteArray, word_offset: int, grid_size: Vector3i) -> Vector3i:
	return Vector3i(
		clampi(int(bytes.decode_u32(word_offset + 0)), 0, grid_size.x),
		clampi(int(bytes.decode_u32(word_offset + 4)), 0, grid_size.y),
		clampi(int(bytes.decode_u32(word_offset + 8)), 0, grid_size.z)
	)


## 从 settings 解析目标读取缓冲（borrow 常驻对 / 上传字节），委托 VoxelPlacementTargetReader。
func _target_read_buffer_pack(settings: Dictionary, voxel_count: int) -> Dictionary:
	return VoxelPlacementTargetReaderScript.pack(settings, voxel_count, _rd)


func _target_read_buffer_summary(pack_data: Dictionary) -> Dictionary:
	return VoxelPlacementTargetReaderScript.summary(pack_data)
