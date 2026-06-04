extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")
const SVC := preload("res://scripts/scene_voxel_committer.gd")
const Runtime := preload("res://scripts/gpu_autoobject_runtime.gd")
const ProfileContainer := preload("res://scripts/auto_voxel_runtime_profile_container.gd")
const SPA := preload("res://scripts/scene_placement_actor.gd")


func _has_rendering_device() -> bool:
	if RenderingServer.get_rendering_device() != null:
		return true
	var local_rd := RenderingServer.create_local_rendering_device()
	if local_rd == null:
		return false
	local_rd.free()
	return true


func _init() -> void:
	var ok := true
	ok = ok and _test_multi_asset_pipeline()
	ok = ok and _test_run_multi_asset_compact_state_chain_or_skip()
	ok = ok and _test_gpu_runtime_profile_contract_or_skip()
	ok = ok and _test_score_dispatch_consumes_gpu_runtime_profile_buffers_or_skip()
	ok = ok and _test_same_profile_min_spacing_excludes_runtime_neighbor_or_skip()
	ok = ok and _test_same_profile_min_spacing_uses_scene_voxel_tile_object_refs_or_skip()
	ok = ok and _test_vpg_pipeline_rids_ready_or_skip()
	ok = ok and _test_post_dispatch_contract_failure_blocks_multi_asset_or_skip()
	ok = ok and _test_accepted_placement_writeback_to_gpu_runtime_or_blocked()
	ok = ok and _test_gpu_runtime_writeback_report_merges_resident_shader_contract()
	ok = ok and _test_accepted_placement_writeback_failure_reason_or_skip()
	ok = ok and _test_run_multi_asset_writes_instance_stamp_specs_to_committer_or_skip()
	ok = ok and _test_run_multi_asset_stages_source_candidates_to_resident_buffers_or_skip()
	ok = ok and _test_run_multi_asset_preserves_target_read_buffer_diagnostics_or_skip()
	ok = ok and _test_gpu_runtime_profile_contract_has_no_cpu_fallback()
	ok = ok and _test_gpu_compute_blocked_has_no_empty_success()
	ok = ok and _test_instantiate_placements()
	ok = ok and _test_instantiate_placement_voxel_write_spec_commit()
	ok = ok and _test_multi_asset_collision_avoidance()

	if ok:
		print("[VoxelMultiAsset] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[VoxelMultiAsset] SOME TESTS FAILED")
		quit(1)


func _test_multi_asset_pipeline() -> bool:
	print("[VoxelMultiAsset] test_multi_asset_pipeline...")
	if not _has_rendering_device():
		print("  SKIP: no RenderingDevice available for GPU-only multi-asset placement")
		return true
	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var grid_origin := Vector3(-4.0, 0.0, -4.0)

	var generator := VPG.new()
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var asset_defs: Array = [
		{
			"collision": [
				{"shape": "cylinder", "radius": 0.45, "y_min": 0.0, "y_max": 2.0, "collision_strength": 1.0}
			],
			"result_capacity": 3,
			"min_distance_voxels": 3.0,
		},
		{
			"collision": [
				{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "collision_strength": 0.8}
			],
			"result_capacity": 4,
			"min_distance_voxels": 2.0,
		},
	]

	var common_settings := {
		"top_k": 4,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
	}

	var result := generator.run_multi_asset(
		scene, collision, asset_defs, grid_size, voxel_size, grid_origin, common_settings)

	if result.is_empty():
		push_error("  FAIL: run_multi_asset returned empty")
		return false

	var asset_results: Array = result.get("asset_results", [])
	if asset_results.size() != 2:
		push_error("  FAIL: expected 2 asset results, got %d" % asset_results.size())
		return false

	var total := int(result.get("total_placed", 0))
	if total <= 0:
		push_error("  FAIL: no placements at all")
		return false

	var a0: Dictionary = asset_results[0]
	var a1: Dictionary = asset_results[1]
	var a0_count := int(a0.get("result_count", 0))
	var a1_count := int(a1.get("result_count", 0))

	if a0_count <= 0:
		push_error("  FAIL: asset 0 has no placements")
		return false
	if a1_count <= 0:
		push_error("  FAIL: asset 1 has no placements")
		return false

	var a0_world: Array = a0.get("world_results", [])
	var a1_world: Array = a1.get("world_results", [])
	if a0_world.is_empty() or a1_world.is_empty():
		push_error("  FAIL: world results missing")
		return false

	print("  OK: asset0=%d asset1=%d total=%d world0=%d world1=%d" % [
		a0_count, a1_count, total, a0_world.size(), a1_world.size()])
	return true


func _test_run_multi_asset_compact_state_chain_or_skip() -> bool:
	print("[VoxelMultiAsset] test_run_multi_asset_compact_state_chain_or_skip...")
	if not _has_rendering_device():
		print("  SKIP: no RenderingDevice available for compact state-chain placement")
		return true

	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var fill_generator := VPG.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[fill_generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0
	fill_generator.dispose()

	var asset_defs: Array = [
		{
			"collision": [
				{"shape": "cylinder", "radius": 0.45, "y_min": 0.0, "y_max": 2.0, "collision_strength": 1.0}
			],
			"result_capacity": 2,
			"min_distance_voxels": 3.0,
			"priority": 10,
		},
		{
			"collision": [
				{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "collision_strength": 0.8}
			],
			"result_capacity": 3,
			"min_distance_voxels": 2.0,
			"priority": 0,
		},
	]
	var common_settings := {
		"top_k": 4,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
		"seed": 42,
	}

	var full_generator := VPG.new()
	var full_result := full_generator.run_multi_asset(
		scene,
		collision,
		asset_defs,
		grid_size,
		voxel_size,
		Vector3.ZERO,
		common_settings
	)
	full_generator.dispose()
	if full_result.is_empty() or int(full_result.get("total_placed", 0)) <= 0:
		push_error("  FAIL: full-field chain baseline returned no placements")
		return false

	var compact_settings := common_settings.duplicate(true)
	compact_settings["use_compact_state_chain"] = true
	var compact_generator := VPG.new()
	var compact_result := compact_generator.run_multi_asset(
		scene,
		collision,
		asset_defs,
		grid_size,
		voxel_size,
		Vector3.ZERO,
		compact_settings
	)
	compact_generator.dispose()
	if compact_result.is_empty():
		push_error("  FAIL: compact state-chain run_multi_asset returned empty")
		return false
	if int(compact_result.get("total_placed", -1)) != int(full_result.get("total_placed", -2)):
		push_error("  FAIL: compact state chain changed placement count, compact=%d full=%d" % [
			int(compact_result.get("total_placed", -1)),
			int(full_result.get("total_placed", -2)),
		])
		return false

	var chain: Dictionary = compact_result.get("cpu_state_chain", {})
	if str(chain.get("mode", "")) != "compact_stamp_deltas" \
			or not bool(chain.get("stamp_delta_cpu_state_chaining", false)) \
			or bool(chain.get("full_field_readback_required", true)) \
			or int(chain.get("applied_delta_count", 0)) <= 0:
		push_error("  FAIL: compact aggregate state-chain contract is invalid: %s" % str(chain))
		return false

	var asset_results: Array = compact_result.get("asset_results", [])
	if asset_results.size() != asset_defs.size():
		push_error("  FAIL: compact state-chain asset result count mismatch")
		return false
	for raw_asset in asset_results:
		if not raw_asset is Dictionary:
			push_error("  FAIL: compact state-chain asset result is not a Dictionary")
			return false
		var asset_result: Dictionary = raw_asset
		if int(asset_result.get("result_count", 0)) <= 0:
			continue
		var full_field: Dictionary = asset_result.get("full_field_readback", {})
		if bool(full_field.get("scene_field_out_is_full_field", true)) \
				or bool(full_field.get("collision_field_out_is_full_field", true)) \
				or bool(full_field.get("scene_field_out_gpu_storage_buffer_readback", true)) \
				or bool(full_field.get("collision_field_out_gpu_storage_buffer_readback", true)) \
				or bool(full_field.get("full_field_readback_required", true)):
			push_error("  FAIL: compact asset should not require full scene/collision field readback: %s" % str(full_field))
			return false
		if str(full_field.get("cpu_state_chain_mode", "")) != "compact_stamp_deltas" \
				or not bool(full_field.get("stamp_delta_cpu_state_chaining", false)):
			push_error("  FAIL: compact asset full-field contract should identify compact stamp deltas: %s" % str(full_field))
			return false
		if str(asset_result.get("stamp_delta_readback_source", "")) != "stamp_shader_storage_buffer" \
				or (asset_result.get("stamp_deltas", []) as Array).is_empty():
			push_error("  FAIL: compact asset should read existing stamp deltas for CPU state chaining")
			return false
		var compact_asset_chain: Dictionary = asset_result.get("compact_state_chain", {})
		if int(compact_asset_chain.get("applied_delta_count", 0)) <= 0:
			push_error("  FAIL: compact asset state-chain report should apply at least one delta: %s" % str(compact_asset_chain))
			return false

	var compact_scene: PackedFloat32Array = compact_result.get("scene_field_out", PackedFloat32Array())
	var compact_collision: PackedFloat32Array = compact_result.get("collision_field_out", PackedFloat32Array())
	var full_scene: PackedFloat32Array = full_result.get("scene_field_out", PackedFloat32Array())
	var full_collision: PackedFloat32Array = full_result.get("collision_field_out", PackedFloat32Array())
	if not _float_arrays_match(compact_scene, full_scene) or not _float_arrays_match(compact_collision, full_collision):
		push_error("  FAIL: compact stamp-delta state chain should match full-field chained scene/collision state")
		return false

	print("  OK: compact state chain applied %d deltas without per-asset full-field readback" % int(chain.get("applied_delta_count", 0)))
	return true


func _test_gpu_runtime_profile_contract_or_skip() -> bool:
	print("[VoxelMultiAsset] test_gpu_runtime_profile_contract_or_skip...")
	var runtime := Runtime.new(4)
	if not runtime.is_gpu_ready():
		var generator := VPG.new()
		var blocked := generator.validate_gpu_runtime_profile_contract({
			"require_gpu_runtime_profile_contract": true,
			"gpu_autoobject_runtime": runtime,
		})
		if bool(blocked.get("ok", true)):
			push_error("  FAIL: missing profile container must not pass GPU runtime/profile contract")
			return false
		if bool(blocked.get("cpu_fallback", true)):
			push_error("  FAIL: no-RD contract path must not report CPU fallback")
			return false
		if not bool(blocked.get("contract_blocked", false)):
			push_error("  FAIL: no-RD contract path must report contract_blocked=true")
			return false
		print("  SKIP: no RenderingDevice available for GPU runtime/profile contract")
		runtime.dispose()
		return true

	var container = ProfileContainer.new()
	if not container.attach_rendering_device(runtime.get_rendering_device(), false):
		push_error("  FAIL: profile container should attach runtime RenderingDevice")
		runtime.dispose()
		return false
	var profile_id: int = container.register_normalized_profile({
		"color": Color(0.2, 0.6, 0.3, 0.9),
		"complexity": 0.9,
		"collision": [
			{"voxel": Vector3i.ZERO, "collision_strength": 0.8, "weight": 1.0}
		],
		"pivot_variants": [
			{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}
		],
	})
	if profile_id <= 0:
		push_error("  FAIL: expected valid GPU profile id")
		runtime.dispose()
		container.dispose()
		return false
	if not container.upload_profiles():
		push_error("  FAIL: profile container should upload buffers on shared runtime RD")
		runtime.dispose()
		container.dispose()
		return false

	var object_id: int = runtime.spawn(profile_id, 11, Vector3i(0, 0, 0), Vector3i(2, 1, 2))
	if object_id < 0:
		push_error("  FAIL: runtime should spawn object into GPU buffers")
		runtime.dispose()
		container.dispose()
		return false

	var generator := VPG.new()
	var contract := generator.validate_gpu_runtime_profile_contract({
		"require_gpu_runtime_profile_contract": true,
		"gpu_autoobject_runtime": runtime,
		"auto_voxel_runtime_profile_container": container,
	})
	if not bool(contract.get("ok", false)):
		push_error("  FAIL: expected VPG to accept GPU resident runtime/profile buffers: %s" % str(contract))
		runtime.dispose()
		container.dispose()
		return false
	if str(contract.get("reason", "")) != "gpu_runtime_profile_buffers_ready":
		push_error("  FAIL: unexpected contract reason: %s" % str(contract.get("reason", "")))
		runtime.dispose()
		container.dispose()
		return false
	if bool(contract.get("cpu_fallback", true)):
		push_error("  FAIL: GPU-ready contract must explicitly reject CPU fallback")
		runtime.dispose()
		container.dispose()
		return false
	if int(contract.get("runtime_buffer_count", 0)) < VPG.REQUIRED_GPU_RUNTIME_BUFFERS.size():
		push_error("  FAIL: missing borrowed runtime buffers in VPG contract")
		runtime.dispose()
		container.dispose()
		return false
	if int(contract.get("profile_buffer_count", 0)) < VPG.REQUIRED_GPU_PROFILE_BUFFERS.size():
		push_error("  FAIL: missing borrowed profile buffers in VPG contract")
		runtime.dispose()
		container.dispose()
		return false

	generator.dispose()
	container.dispose()
	runtime.dispose()
	print("  OK: VPG accepts shared-RD GPU runtime/profile storage buffers")
	return true


func _test_score_dispatch_consumes_gpu_runtime_profile_buffers_or_skip() -> bool:
	print("[VoxelMultiAsset] test_score_dispatch_consumes_gpu_runtime_profile_buffers_or_skip...")
	var runtime := Runtime.new(4)
	if not runtime.is_gpu_ready():
		print("  SKIP: no RenderingDevice available for score dispatch runtime/profile binding")
		runtime.dispose()
		return true

	var container = ProfileContainer.new()
	if not container.attach_rendering_device(runtime.get_rendering_device(), false):
		push_error("  FAIL: profile container should attach runtime RenderingDevice")
		runtime.dispose()
		return false

	var profile_id: int = container.register_normalized_profile({
		"color": Color(0.8, 0.2, 0.1, 0.37),
		"complexity": 0.37,
		"semantic_probes": [
			{
				"offset": Vector3.ZERO,
				"expected_color": Color(0.8, 0.2, 0.1, 0.37),
				"expected_complexity": 0.37,
				"expected_collision": 0.4,
				"weight": 1.0,
				"flags": 7,
				"kind": "positive",
				"source": "test",
			}
		],
		"collision": [
			{"voxel": Vector3i.ZERO, "collision_strength": 0.4, "weight": 1.0}
		],
		"pivot_variants": [
			{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}
		],
	})
	if profile_id <= 0 or not container.upload_profiles():
		push_error("  FAIL: expected uploaded GPU profile buffers")
		container.dispose()
		runtime.dispose()
		return false

	var object_id := runtime.spawn(profile_id, 21, Vector3i(0, 0, 0), Vector3i(8, 8, 8))
	if object_id < 0:
		push_error("  FAIL: runtime should spawn object into GPU buffers")
		container.dispose()
		runtime.dispose()
		return false

	var grid_size := Vector3i(8, 8, 8)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)
	var footprint := [
		{
			"local_pos": Vector3i.ZERO,
			"collision_strength": 1.0,
			"weight": 1.0,
			"flags": 0,
		}
	]

	var generator := VPG.new()
	var result := generator.run_minimal(scene, collision, footprint, grid_size, {
		"require_gpu_runtime_profile_contract": true,
		"gpu_autoobject_runtime": runtime,
		"auto_voxel_runtime_profile_container": container,
		"profile_id": profile_id,
		"top_k": 1,
		"result_capacity": 1,
		"candidate_voxel_sparses": [Vector3i.ZERO],
		"min_support_ratio": 0.0,
		"collision_limit": 0.0,
		"clearance_limit": 0.0,
		"score_runtime_profile_avoidance": true,
		"min_distance_voxels": 0.0,
	})
	if result.is_empty():
		push_error("  FAIL: run_minimal returned empty for GPU runtime/profile score contract")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	var contract: Dictionary = result.get("gpu_runtime_profile_contract", {})
	var debug: Dictionary = result.get("gpu_runtime_profile_binding_debug", {})
	if bool(contract.get("cpu_fallback", true)):
		push_error("  FAIL: score dispatch contract must not report CPU fallback")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not bool(contract.get("score_shader_bound_runtime_profile_buffers", false)):
		push_error("  FAIL: score shader did not report bound runtime/profile buffers: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not bool(contract.get("score_shader_consumed_runtime_buffers", false)):
		push_error("  FAIL: score shader did not consume runtime buffers: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not bool(contract.get("score_shader_consumed_profile_buffers", false)):
		push_error("  FAIL: score shader did not consume profile buffers: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not bool(contract.get("score_shader_consumed_profile_side_buffers", false)):
		push_error("  FAIL: score shader did not consume profile probe/collision/pivot buffers: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(debug.get("runtime_overlap_hits", 0)) <= 0:
		push_error("  FAIL: expected runtime bounds to reject candidate origins: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(debug.get("runtime_profile_reads", 0)) <= 0:
		push_error("  FAIL: expected score shader to read runtime profile buffer: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(debug.get("runtime_profile_matches", 0)) <= 0:
		push_error("  FAIL: expected score shader to match runtime profile id: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(debug.get("probe_record_reads", 0)) <= 0:
		push_error("  FAIL: expected score shader to read runtime probe records: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(debug.get("collision_record_reads", 0)) <= 0:
		push_error("  FAIL: expected score shader to read runtime collision records: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(debug.get("pivot_record_reads", 0)) <= 0:
		push_error("  FAIL: expected score shader to read runtime pivot records: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if absf(float(debug.get("profile_complexity", 0.0)) - 0.37) > 0.02:
		push_error("  FAIL: expected shader profile table readback complexity near 0.37: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(result.get("result_count", -1)) != 0:
		push_error("  FAIL: runtime bounds avoidance should block placements in occupied bounds")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	generator.dispose()
	container.dispose()
	runtime.dispose()
	print("  OK: score shader bound and consumed GPU runtime/profile buffers")
	return true


func _test_same_profile_min_spacing_excludes_runtime_neighbor_or_skip() -> bool:
	print("[VoxelMultiAsset] test_same_profile_min_spacing_excludes_runtime_neighbor_or_skip...")
	var runtime := Runtime.new(4)
	if not runtime.is_gpu_ready():
		print("  SKIP: no RenderingDevice available for same-profile runtime spacing")
		runtime.dispose()
		return true

	var same_profile := {
		"color": Color(0.25, 0.65, 0.35, 0.8),
		"complexity": 0.8,
		"collision": [
			{"voxel": Vector3i.ZERO, "collision_strength": 1.0, "weight": 1.0}
		],
		"pivot_variants": [
			{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}
		],
	}
	var other_profile := {
		"color": Color(0.65, 0.25, 0.35, 0.6),
		"complexity": 0.6,
		"collision": [
			{"voxel": Vector3i.ZERO, "collision_strength": 1.0, "weight": 1.0}
		],
		"pivot_variants": [
			{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}
		],
	}
	var grid_size := Vector3i(8, 2, 8)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)
	var footprint := [
		{
			"local_pos": Vector3i.ZERO,
			"collision_strength": 1.0,
			"weight": 1.0,
			"flags": 0,
		}
	]

	var container = ProfileContainer.new()
	if not container.attach_rendering_device(runtime.get_rendering_device(), false):
		push_error("  FAIL: profile container should attach runtime RenderingDevice")
		runtime.dispose()
		return false
	var same_profile_id: int = container.register_normalized_profile(same_profile.duplicate(true))
	var other_profile_id: int = container.register_normalized_profile(other_profile.duplicate(true))
	if same_profile_id <= 0 or other_profile_id <= 0 or not container.upload_profiles():
		push_error("  FAIL: expected uploaded profiles for same-profile runtime spacing")
		container.dispose()
		runtime.dispose()
		return false
	var same_object_id := runtime.spawn(same_profile_id, 51, Vector3i(8, 0, 0), Vector3i(9, 1, 1))
	if same_object_id < 0:
		push_error("  FAIL: runtime should spawn same-profile neighbor")
		container.dispose()
		runtime.dispose()
		return false

	var generator := VPG.new()
	var same_result := generator.run_minimal(scene, collision, footprint, grid_size, {
		"require_gpu_runtime_profile_contract": true,
		"gpu_autoobject_runtime": runtime,
		"auto_voxel_runtime_profile_container": container,
		"profile_id": same_profile_id,
		"top_k": 1,
		"result_capacity": 1,
		"candidate_voxel_sparses": [Vector3i.ZERO],
		"min_support_ratio": 0.0,
		"collision_limit": 0.0,
		"clearance_limit": 0.0,
		"score_runtime_profile_avoidance": true,
		"min_distance_voxels": 16.0,
		"allow_runtime_spacing_full_scan_debug": true,
		"runtime_spacing_full_scan_debug_max_objects": 4,
	})
	var same_contract: Dictionary = same_result.get("gpu_runtime_profile_contract", {})
	var same_debug: Dictionary = same_result.get("gpu_runtime_profile_binding_debug", {})
	var same_results: Array = same_result.get("results", [])
	if same_result.is_empty() or bool(same_result.get("contract_blocked", false)):
		push_error("  FAIL: same-profile spacing run should complete on GPU: %s" % str(same_contract))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(same_result.get("cpu_fallback", false)):
		push_error("  FAIL: same-profile spacing run must not CPU fallback")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(same_result.get("result_count", -1)) != 0 or not same_results.is_empty():
		push_error("  FAIL: same-profile runtime spacing should reject all candidates")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(same_debug.get("runtime_overlap_hits", 0)) != 0:
		push_error("  FAIL: runtime spacing test should not rely on bounds-origin overlap: %s" % str(same_debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(same_debug.get("runtime_spacing_rejections", 0)) <= 0:
		push_error("  FAIL: expected GPU same-profile spacing rejections: %s" % str(same_debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not bool(same_contract.get("score_shader_same_type_min_spacing_exclusion", false)) \
			or int(same_contract.get("score_shader_same_type_min_spacing_rejections", 0)) <= 0 \
			or str(same_contract.get("same_type_exclusion_read_source", "none")) != "score_shader_storage_buffer":
		push_error("  FAIL: same-profile spacing contract did not annotate GPU exclusion: %s" % str(same_contract))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(same_contract.get("scene_voxel_tile_object_ref_exclusion", true)) \
			or str(same_contract.get("same_type_exclusion_object_ref_read_source", "")) != "none":
		push_error("  FAIL: same-profile spacing must not claim SceneVoxelTile object-ref exclusion: %s" % str(same_contract))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not bool(same_contract.get("same_type_exclusion_full_runtime_scan_debug_fallback", false)):
		push_error("  FAIL: full runtime scan spacing requires explicit debug fallback annotation: %s" % str(same_contract))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	generator.dispose()
	container.dispose()
	runtime.dispose()

	var runtime_other := Runtime.new(4)
	if not runtime_other.is_gpu_ready():
		print("  SKIP: no RenderingDevice available for different-profile spacing follow-up")
		runtime_other.dispose()
		return true
	var container_other = ProfileContainer.new()
	if not container_other.attach_rendering_device(runtime_other.get_rendering_device(), false):
		push_error("  FAIL: second profile container should attach runtime RenderingDevice")
		runtime_other.dispose()
		return false
	var same_profile_id_other: int = container_other.register_normalized_profile(same_profile.duplicate(true))
	var other_profile_id_other: int = container_other.register_normalized_profile(other_profile.duplicate(true))
	if same_profile_id_other <= 0 or other_profile_id_other <= 0 or not container_other.upload_profiles():
		push_error("  FAIL: expected uploaded profiles for different-profile runtime spacing")
		container_other.dispose()
		runtime_other.dispose()
		return false
	var other_object_id := runtime_other.spawn(other_profile_id_other, 52, Vector3i(8, 0, 0), Vector3i(9, 1, 1))
	if other_object_id < 0:
		push_error("  FAIL: runtime should spawn different-profile neighbor")
		container_other.dispose()
		runtime_other.dispose()
		return false

	var generator_other := VPG.new()
	var other_result := generator_other.run_minimal(scene, collision, footprint, grid_size, {
		"require_gpu_runtime_profile_contract": true,
		"gpu_autoobject_runtime": runtime_other,
		"auto_voxel_runtime_profile_container": container_other,
		"profile_id": same_profile_id_other,
		"top_k": 1,
		"result_capacity": 1,
		"candidate_voxel_sparses": [Vector3i.ZERO],
		"min_support_ratio": 0.0,
		"collision_limit": 0.0,
		"clearance_limit": 0.0,
		"score_runtime_profile_avoidance": true,
		"min_distance_voxels": 16.0,
		"allow_runtime_spacing_full_scan_debug": true,
		"runtime_spacing_full_scan_debug_max_objects": 4,
	})
	var other_contract: Dictionary = other_result.get("gpu_runtime_profile_contract", {})
	var other_debug: Dictionary = other_result.get("gpu_runtime_profile_binding_debug", {})
	if other_result.is_empty() or bool(other_result.get("contract_blocked", false)):
		push_error("  FAIL: different-profile spacing run should complete on GPU: %s" % str(other_contract))
		generator_other.dispose()
		container_other.dispose()
		runtime_other.dispose()
		return false
	if bool(other_result.get("cpu_fallback", false)):
		push_error("  FAIL: different-profile spacing run must not CPU fallback")
		generator_other.dispose()
		container_other.dispose()
		runtime_other.dispose()
		return false
	if int(other_result.get("result_count", 0)) <= 0:
		push_error("  FAIL: different-profile neighbor should not block placement")
		generator_other.dispose()
		container_other.dispose()
		runtime_other.dispose()
		return false
	if int(other_debug.get("runtime_spacing_rejections", 0)) != 0 \
			or int(other_debug.get("runtime_spacing_profile_matches", 0)) != 0:
		push_error("  FAIL: different-profile neighbor should not trigger same-profile spacing: %s" % str(other_debug))
		generator_other.dispose()
		container_other.dispose()
		runtime_other.dispose()
		return false
	if bool(other_contract.get("score_shader_same_type_min_spacing_exclusion", false)) \
			or bool(other_contract.get("scene_voxel_tile_object_ref_exclusion", true)):
		push_error("  FAIL: different-profile spacing contract should keep exclusion fields default: %s" % str(other_contract))
		generator_other.dispose()
		container_other.dispose()
		runtime_other.dispose()
		return false
	if str(other_contract.get("same_type_exclusion_read_source", "")) != "score_shader_storage_buffer" \
			or not bool(other_contract.get("same_type_exclusion_full_runtime_scan_debug_fallback", false)):
		push_error("  FAIL: different-profile debug fallback should report storage-buffer read source without exclusion: %s" % str(other_contract))
		generator_other.dispose()
		container_other.dispose()
		runtime_other.dispose()
		return false

	generator_other.dispose()
	container_other.dispose()
	runtime_other.dispose()
	print("  OK: same-profile runtime spacing rejects; different profile does not")
	return true


func _test_same_profile_min_spacing_uses_scene_voxel_tile_object_refs_or_skip() -> bool:
	print("[VoxelMultiAsset] test_same_profile_min_spacing_uses_scene_voxel_tile_object_refs_or_skip...")
	var committer := SVC.new(8, 8.0, false)
	committer.configure_scene_voxel_grid(Vector3i(8, 2, 8), Vector3.ONE, Vector3.ZERO)
	if not committer.ensure_scene_voxel_tile_buffers_uploaded(true):
		print("  SKIP: SceneVoxelTile GPU buffers unavailable for object-ref spacing")
		committer.dispose()
		return true

	var runtime := Runtime.new(0)
	var setup_result := runtime.setup_for_scene_voxel_committer(committer, 4, true)
	if not bool(setup_result.get("ok", false)) or not runtime.is_gpu_ready():
		print("  SKIP: GPUAutoObjectRuntime could not share SceneVoxelTile RenderingDevice: %s" % str(setup_result))
		runtime.dispose()
		committer.dispose()
		return true

	var container = ProfileContainer.new()
	if not container.attach_rendering_device(runtime.get_rendering_device(), false):
		push_error("  FAIL: profile container should attach object-ref runtime RenderingDevice")
		runtime.dispose()
		committer.dispose()
		return false

	var profile := {
		"color": Color(0.25, 0.65, 0.35, 0.8),
		"complexity": 0.8,
		"collision": [
			{"voxel": Vector3i.ZERO, "collision_strength": 1.0, "weight": 1.0}
		],
		"pivot_variants": [
			{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}
		],
	}
	var profile_id: int = container.register_normalized_profile(profile.duplicate(true))
	if profile_id <= 0 or not container.upload_profiles():
		push_error("  FAIL: expected uploaded profiles for SceneVoxelTile object-ref spacing")
		container.dispose()
		runtime.dispose()
		committer.dispose()
		return false

	var object_id := runtime.spawn(profile_id, 51, Vector3i(4, 0, 0), Vector3i(5, 1, 1))
	if object_id < 0:
		push_error("  FAIL: runtime should spawn object-ref spacing neighbor")
		container.dispose()
		runtime.dispose()
		committer.dispose()
		return false
	var flush_result := runtime.flush_to_scene_voxel_committer(committer, {})
	if not bool(flush_result.get("resident_gpu_dirty_delta_update_pass", false)):
		push_error("  FAIL: expected resident object-ref update pass before VPG scoring: %s" % str(flush_result))
		container.dispose()
		runtime.dispose()
		committer.dispose()
		return false

	var summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
	if str(summary.get("gpu_autoobject_ref_key_schema", "")) != "u32_numeric_ref_key_v1" \
			or not bool(summary.get("gpu_autoobject_ref_key_schema_numeric_confirmed", false)):
		push_error("  FAIL: committer must expose numeric object-ref schema before VPG borrow: %s" % str(summary))
		container.dispose()
		runtime.dispose()
		committer.dispose()
		return false

	var grid_size := Vector3i(8, 2, 8)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)
	var footprint := [{
		"local_pos": Vector3i.ZERO,
		"collision_strength": 1.0,
		"weight": 1.0,
		"flags": 0,
	}]

	var generator := VPG.new()
	var result := generator.run_minimal(scene, collision, footprint, grid_size, {
		"require_gpu_runtime_profile_contract": true,
		"gpu_autoobject_runtime": runtime,
		"auto_voxel_runtime_profile_container": container,
		"scene_voxel_committer": committer,
		"require_scene_voxel_tile_object_ref_exclusion": true,
		"profile_id": profile_id,
		"top_k": 1,
		"result_capacity": 1,
		"candidate_voxel_sparses": [Vector3i.ZERO],
		"min_support_ratio": 0.0,
		"collision_limit": 0.0,
		"clearance_limit": 0.0,
		"score_runtime_profile_avoidance": true,
		"min_distance_voxels": 16.0,
	})
	var contract: Dictionary = result.get("gpu_runtime_profile_contract", {})
	var debug: Dictionary = result.get("gpu_runtime_profile_binding_debug", {})
	if result.is_empty() or bool(result.get("contract_blocked", false)):
		push_error("  FAIL: object-ref spacing run should complete on GPU: %s" % str(contract))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		committer.dispose()
		return false
	if int(result.get("result_count", -1)) != 0:
		push_error("  FAIL: SceneVoxelTile object-ref spacing should reject the candidate")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		committer.dispose()
		return false
	if not bool(contract.get("scene_voxel_tile_object_ref_exclusion", false)) \
			or str(contract.get("same_type_exclusion_object_ref_read_source", "none")) != "scene_voxel_tile_object_refs" \
			or str(contract.get("same_type_exclusion_read_source", "none")) != "scene_voxel_tile_object_refs":
		push_error("  FAIL: contract should report SceneVoxelTile object-ref spacing: %s" % str(contract))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		committer.dispose()
		return false
	if int(debug.get("scene_voxel_tile_object_ref_tile_reads", 0)) <= 0 \
			or int(debug.get("scene_voxel_tile_object_ref_slot_reads", 0)) <= 0 \
			or int(debug.get("scene_voxel_tile_object_ref_object_reads", 0)) <= 0 \
			or int(debug.get("runtime_spacing_rejections", 0)) <= 0:
		push_error("  FAIL: score shader should read SceneVoxelTile refs and reject via spacing: %s" % str(debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		committer.dispose()
		return false

	generator.dispose()
	container.dispose()
	runtime.dispose()
	committer.dispose()
	print("  OK: same-profile spacing uses SceneVoxelTile object refs as GPU shortlist")
	return true


func _test_vpg_pipeline_rids_ready_or_skip() -> bool:
	print("[VoxelMultiAsset] test_vpg_pipeline_rids_ready_or_skip...")
	var generator := VPG.new()
	if not generator._ensure_placement_rendering_device():
		print("  SKIP: no RenderingDevice available for VPG pipeline readiness")
		generator.dispose()
		return true
	generator._load_shaders()
	if not generator._placement_pipeline_ready():
		push_error("  FAIL: VPG GPU-ready path requires valid score/reduce/stamp pipelines")
		generator._free_gpu()
		return false
	generator._free_gpu()
	print("  OK: score/reduce/stamp shader and pipeline RIDs are ready")
	return true


func _test_post_dispatch_contract_failure_blocks_multi_asset_or_skip() -> bool:
	print("[VoxelMultiAsset] test_post_dispatch_contract_failure_blocks_multi_asset_or_skip...")
	var runtime := Runtime.new(2)
	if not runtime.is_gpu_ready():
		print("  SKIP: no RenderingDevice available for post-dispatch contract failure")
		runtime.dispose()
		return true

	var container = ProfileContainer.new()
	if not container.attach_rendering_device(runtime.get_rendering_device(), false):
		push_error("  FAIL: profile container should attach runtime RenderingDevice")
		runtime.dispose()
		return false

	var profile_id: int = container.register_normalized_profile({
		"color": Color(0.15, 0.55, 0.25, 0.7),
		"complexity": 0.7,
		"collision": [
			{"voxel": Vector3i.ZERO, "collision_strength": 1.0, "weight": 1.0}
		],
		"pivot_variants": [
			{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}
		],
	})
	if profile_id <= 0 or not container.upload_profiles():
		push_error("  FAIL: expected uploaded GPU profile buffers for post-dispatch failure test")
		container.dispose()
		runtime.dispose()
		return false

	var grid_size := Vector3i(8, 4, 8)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var generator := VPG.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var result := generator.run_multi_asset(
		scene,
		collision,
		[
			{
				"collision": [
					{"shape": "cylinder", "radius": 0.3, "y_min": 0.0, "y_max": 1.0, "collision_strength": 1.0}
				],
				"result_capacity": 1,
				"profile_id": profile_id,
				"object_type": 39,
			}
		],
		grid_size,
		Vector3.ONE,
		Vector3.ZERO,
		{
			"top_k": 1,
			"collision_limit": 0.0,
			"min_support_ratio": 1.0,
			"clearance_limit": 0.0,
			"require_gpu_runtime_profile_contract": true,
			"gpu_autoobject_runtime": runtime,
			"auto_voxel_runtime_profile_container": container,
			"score_runtime_profile_avoidance": false,
		}
	)
	if result.is_empty():
		push_error("  FAIL: post-dispatch contract failure must return blocked output, not empty")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not bool(result.get("contract_blocked", false)):
		push_error("  FAIL: post-dispatch score contract failure must block multi-asset output")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(result.get("ok", true)):
		push_error("  FAIL: blocked post-dispatch contract must report ok=false")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: post-dispatch contract failure must not CPU fallback")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	var contract: Dictionary = result.get("gpu_runtime_profile_contract", {})
	if bool(contract.get("ok", true)):
		push_error("  FAIL: unconsumed runtime buffers must set contract ok=false")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not bool(contract.get("contract_blocked", false)):
		push_error("  FAIL: unconsumed runtime buffers must set nested contract_blocked=true")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(contract.get("reason", "")) != "score_runtime_buffers_not_consumed":
		push_error("  FAIL: expected score_runtime_buffers_not_consumed, got %s" % str(contract.get("reason", "")))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(result.get("total_placed", -1)) != 0:
		push_error("  FAIL: blocked post-dispatch contract must not publish placements")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var asset_results: Array = result.get("asset_results", [])
	if asset_results.size() != 1 or int((asset_results[0] as Dictionary).get("result_count", -1)) != 0:
		push_error("  FAIL: blocked post-dispatch contract must not publish asset results")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	generator.dispose()
	container.dispose()
	runtime.dispose()
	print("  OK: post-dispatch score contract failure blocks multi-asset output")
	return true


func _test_accepted_placement_writeback_to_gpu_runtime_or_blocked() -> bool:
	print("[VoxelMultiAsset] test_accepted_placement_writeback_to_gpu_runtime_or_blocked...")
	var runtime := Runtime.new(8)
	if not runtime.is_gpu_ready():
		print("  SKIP: no RenderingDevice available for accepted placement runtime writeback")
		runtime.dispose()
		return true

	var container = ProfileContainer.new()
	if not container.attach_rendering_device(runtime.get_rendering_device(), false):
		push_error("  FAIL: profile container should attach runtime RenderingDevice")
		runtime.dispose()
		return false

	var profile_id: int = container.register_normalized_profile({
		"color": Color(0.15, 0.55, 0.25, 0.7),
		"complexity": 0.7,
		"collision": [
			{"voxel": Vector3i.ZERO, "collision_strength": 1.0, "weight": 1.0}
		],
		"pivot_variants": [
			{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}
		],
	})
	if profile_id <= 0 or not container.upload_profiles():
		push_error("  FAIL: expected uploaded GPU profile buffers for placement writeback")
		container.dispose()
		runtime.dispose()
		return false

	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var generator := VPG.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	runtime.set_use_resident_accepted_placement_writeback(true)
	var writeback_object_type := 37
	var result := generator.run_multi_asset(
		scene,
		collision,
		[
			{
				"collision": [
					{"shape": "cylinder", "radius": 0.3, "y_min": 0.0, "y_max": 1.0, "collision_strength": 1.0}
				],
				"result_capacity": 1,
				"profile_id": profile_id,
				"object_type": writeback_object_type,
			}
		],
		grid_size,
		Vector3.ONE,
		Vector3.ZERO,
		{
			"top_k": 2,
			"collision_limit": 0.0,
			"min_support_ratio": 1.0,
			"clearance_limit": 0.0,
			"require_gpu_runtime_profile_contract": true,
			"gpu_autoobject_runtime": runtime,
			"auto_voxel_runtime_profile_container": container,
			"min_distance_voxels": 0.0,
			"write_accepted_placements_to_gpu_runtime": true,
			"runtime_writeback_object_type": writeback_object_type,
			"runtime_writeback_dirty_flags": {"auto": true, "collision": true, "scoring": true},
		}
	)

	if result.is_empty():
		push_error("  FAIL: run_multi_asset returned empty for accepted placement writeback")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(result.get("contract_blocked", false)):
		push_error("  FAIL: runtime/profile contract should be ready before writeback: %s" % str(result.get("gpu_runtime_profile_contract", {})))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: placement writeback path must report cpu_fallback=false")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	var accepted_count := int(result.get("total_placed", 0))
	if accepted_count <= 0:
		push_error("  FAIL: writeback test needs at least one accepted placement")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	var runtime_debug := runtime.get_selected_debug_summary()
	if str(runtime_debug.get("readback_source", "")) != "gpu_storage_buffers":
		push_error("  FAIL: runtime debug readback should come from GPU storage buffers")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(runtime_debug.get("cpu_fallback", false)):
		push_error("  FAIL: runtime debug summary must not claim CPU fallback")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(runtime_debug.get("reserved_object_id_count", -1)) != 0:
		push_error("  FAIL: successful VPG writeback should not leave reserved object IDs: %s" % str(runtime_debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	var writeback: Dictionary = result.get("gpu_autoobject_runtime_writeback", {})
	var live_count := int(runtime_debug.get("live_count", runtime.get_live_count()))
	if writeback.is_empty():
		push_error("  FAIL: run_multi_asset should report gpu_autoobject_runtime_writeback when writeback is requested")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(writeback.get("cpu_fallback", true)):
		push_error("  FAIL: writeback report must keep cpu_fallback=false")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("accepted_placement_writeback_mode", "")) != "cpu_dictionary_to_gpu_runtime_batched_command_queue":
		push_error("  FAIL: accepted placement writeback should identify CPU batched command queue mode: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("accepted_placement_record_source", "")) != "cpu_spawn_command_dictionaries":
		push_error("  FAIL: accepted placement writeback should identify CPU spawn command dictionaries as the runtime record source")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("accepted_placement_origin_record_source", "")) != "cpu_world_result_and_raw_result_dictionaries":
		push_error("  FAIL: accepted placement writeback should identify CPU world/raw dictionaries as the origin source")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("accepted_placement_spawn_api", "")) != "stage_command_flush_command_queue":
		push_error("  FAIL: accepted placement writeback should use runtime command queue bridge: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not bool(writeback.get("cpu_batched_command_queue_bridge", false)):
		push_error("  FAIL: accepted placement writeback should report CPU batched command queue bridge")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(writeback.get("command_queue_stage_count", 0)) < accepted_count or int(writeback.get("command_queue_flush_count", 0)) <= 0:
		push_error("  FAIL: accepted placement writeback should stage and flush queued runtime commands: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var asset_writeback: Dictionary = ((result.get("asset_results", []) as Array)[0] as Dictionary).get("gpu_autoobject_runtime_writeback", {})
	var reservation: Dictionary = asset_writeback.get("accepted_placement_object_id_reservation", {})
	if not bool(reservation.get("ok", false)) \
			or int(reservation.get("reserved_count", 0)) < accepted_count \
			or int(reservation.get("reserved_object_id_count", -1)) < accepted_count:
		push_error("  FAIL: VPG writeback should reserve accepted-placement object IDs before staging: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("runtime_command_flush_mode", "")) != "resident_accepted_placement_record_shader_writeback":
		push_error("  FAIL: VPG writeback should surface resident accepted-record shader flush mode: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not bool(writeback.get("accepted_placement_record_shader_consumed", false)):
		push_error("  FAIL: VPG writeback should surface consumed accepted-record shader dispatch: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var record_count := int(writeback.get("accepted_placement_record_count", 0))
	if int(writeback.get("accepted_placement_record_schema_version", -1)) != Runtime.ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION \
			or int(writeback.get("accepted_placement_record_stride_bytes", -1)) != Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES \
			or record_count < accepted_count:
		push_error("  FAIL: VPG writeback should carry accepted-record schema/stride/count diagnostics: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(writeback.get("accepted_placement_record_byte_count", -1)) != record_count * Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES \
			or not bool(writeback.get("accepted_placement_record_debug_packed", false)):
		push_error("  FAIL: VPG writeback should carry accepted-record packed byte diagnostics: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("accepted_placement_record_shader_name", "")) != Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_NAME \
			or str(writeback.get("accepted_placement_record_shader_path", "")) != Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_PATH:
		push_error("  FAIL: VPG writeback should surface accepted-record shader identity: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var expected_dispatch_count := int(ceil(float(record_count) / float(Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X)))
	if int(writeback.get("accepted_placement_record_shader_dispatch_count", 0)) != expected_dispatch_count \
			or int(writeback.get("accepted_placement_record_shader_local_size_x", 0)) != Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X:
		push_error("  FAIL: VPG writeback should surface accepted-record shader dispatch/local size: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var shader_stats: Dictionary = writeback.get("accepted_placement_record_shader_stats", {})
	if not bool(shader_stats.get("ok", false)) \
			or str(shader_stats.get("reason", "")) != "deferred_no_readback" \
			or str(shader_stats.get("readback_source", "")) != "none":
		push_error("  FAIL: VPG writeback should surface accepted-record shader no-readback contract: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(writeback.get("resident_gpu_allocator_writeback", true)):
		push_error("  FAIL: accepted-record shader path must not claim resident GPU allocator ownership")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var finalize: Dictionary = asset_writeback.get("accepted_placement_object_id_reservation_finalize", {})
	if not bool(finalize.get("ok", false)) \
			or int(finalize.get("finalized_count", 0)) < accepted_count \
			or int(finalize.get("reserved_object_id_count", -1)) != 0:
		push_error("  FAIL: VPG writeback should finalize reserved IDs only after accepted-record shader success: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("resident_gpu_allocator_writeback_mode", "")) != "resident_object_buffer_writeback" \
			or int(writeback.get("resident_gpu_allocator_record_stride_bytes", -1)) != Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES \
			or str(writeback.get("resident_gpu_allocator_owner", "")) != "GPUAutoObjectRuntime" \
			or str(writeback.get("resident_gpu_allocator_writeback_blocked_reason", "")) != "none":
		push_error("  FAIL: VPG writeback should surface resident object-buffer writeback diagnostics: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("readback_source", "gpu_storage_buffers")) != "gpu_storage_buffers":
		push_error("  FAIL: writeback report should read back from gpu_storage_buffers: %s" % str(writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(writeback.get("accepted_count", 0)) < accepted_count:
		push_error("  FAIL: writeback report accepted_count should cover accepted placements")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(writeback.get("spawned_count", 0)) < accepted_count:
		push_error("  FAIL: writeback report spawned_count should cover accepted placements")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if live_count < accepted_count:
		push_error("  FAIL: accepted placements were not written into GPUAutoObjectRuntime live buffers")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	var matched_objects := 0
	var objects: Array = runtime_debug.get("objects", [])
	for raw_object in objects:
		if not raw_object is Dictionary:
			continue
		var object: Dictionary = raw_object
		if int(object.get("profile_id", -1)) == profile_id and int(object.get("object_type", -1)) == writeback_object_type:
			matched_objects += 1
	if matched_objects < accepted_count:
		push_error("  FAIL: GPU runtime objects should preserve accepted placement profile/type")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if runtime.get_pending_dirty_delta_count() < accepted_count:
		push_error("  FAIL: placement writeback should emit GPU dirty deltas for accepted objects")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	generator.dispose()
	container.dispose()
	runtime.dispose()
	print("  OK: accepted placements wrote to GPUAutoObjectRuntime live buffers")
	return true


func _test_gpu_runtime_writeback_report_merges_resident_shader_contract() -> bool:
	print("[VoxelMultiAsset] test_gpu_runtime_writeback_report_merges_resident_shader_contract...")
	var generator := VPG.new()
	var aggregate := generator._new_gpu_autoobject_runtime_writeback_report(
		null,
		null,
		{"ok": true, "reason": "gpu_runtime_profile_buffers_ready"},
		true
	)
	for source in [
		{
			"ok": true,
			"reason": "gpu_runtime_writeback_ready",
			"accepted_count": 1,
			"spawned_count": 1,
			"runtime_command_flush_mode": "resident_accepted_placement_record_shader_writeback",
			"accepted_placement_record_schema_version": Runtime.ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION,
			"accepted_placement_record_stride_bytes": Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
			"accepted_placement_record_count": 1,
			"accepted_placement_record_byte_count": Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
			"accepted_placement_record_debug_packed": true,
			"accepted_placement_record_shader_consumed": true,
			"accepted_placement_record_shader_name": Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_NAME,
			"accepted_placement_record_shader_path": Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_PATH,
			"accepted_placement_record_shader_dispatch_count": 1,
			"accepted_placement_record_shader_local_size_x": Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X,
			"accepted_placement_record_shader_stats": {"applied": 1, "record_count": 1, "dispatched": 1},
			"resident_gpu_allocator_writeback": false,
			"resident_gpu_allocator_writeback_mode": "resident_object_buffer_writeback",
			"resident_gpu_allocator_record_stride_bytes": Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
			"resident_gpu_allocator_owner": "GPUAutoObjectRuntime",
			"resident_gpu_allocator_writeback_blocked_reason": "none",
		},
		{
			"ok": true,
			"reason": "gpu_runtime_writeback_ready",
			"accepted_count": 2,
			"spawned_count": 2,
			"runtime_command_flush_mode": "resident_accepted_placement_record_shader_writeback",
			"accepted_placement_record_schema_version": Runtime.ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION,
			"accepted_placement_record_stride_bytes": Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
			"accepted_placement_record_count": 2,
			"accepted_placement_record_byte_count": 2 * Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
			"accepted_placement_record_debug_packed": true,
			"accepted_placement_record_shader_consumed": true,
			"accepted_placement_record_shader_name": Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_NAME,
			"accepted_placement_record_shader_path": Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_PATH,
			"accepted_placement_record_shader_dispatch_count": 1,
			"accepted_placement_record_shader_local_size_x": Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X,
			"accepted_placement_record_shader_stats": {"applied": 2, "record_count": 2, "dispatched": 1},
			"resident_gpu_allocator_writeback": false,
			"resident_gpu_allocator_writeback_mode": "resident_object_buffer_writeback",
			"resident_gpu_allocator_record_stride_bytes": Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
			"resident_gpu_allocator_owner": "GPUAutoObjectRuntime",
			"resident_gpu_allocator_writeback_blocked_reason": "none",
		},
	]:
		generator._merge_gpu_autoobject_runtime_writeback_report(aggregate, source)
	if str(aggregate.get("runtime_command_flush_mode", "")) != "resident_accepted_placement_record_shader_writeback" \
			or not bool(aggregate.get("accepted_placement_record_shader_consumed", false)):
		push_error("  FAIL: aggregate should preserve consumed resident shader mode: %s" % str(aggregate))
		generator.dispose()
		return false
	if int(aggregate.get("accepted_placement_record_count", 0)) != 3 \
			or int(aggregate.get("accepted_placement_record_byte_count", 0)) != 3 * Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES \
			or not bool(aggregate.get("accepted_placement_record_debug_packed", false)):
		push_error("  FAIL: aggregate should sum accepted-record count/bytes/debug-packed contract: %s" % str(aggregate))
		generator.dispose()
		return false
	if int(aggregate.get("accepted_placement_record_shader_dispatch_count", 0)) != 2 \
			or int(aggregate.get("accepted_placement_record_shader_local_size_x", 0)) != Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X:
		push_error("  FAIL: aggregate should preserve shader dispatch/local size diagnostics: %s" % str(aggregate))
		generator.dispose()
		return false
	var stats: Dictionary = aggregate.get("accepted_placement_record_shader_stats", {})
	if int(stats.get("applied", 0)) != 3 \
			or int(stats.get("record_count", 0)) != 3 \
			or int(stats.get("dispatched", 0)) != 2:
		push_error("  FAIL: aggregate should merge shader stats: %s" % str(aggregate))
		generator.dispose()
		return false
	if bool(aggregate.get("resident_gpu_allocator_writeback", true)) \
			or str(aggregate.get("resident_gpu_allocator_writeback_mode", "")) != "resident_object_buffer_writeback" \
			or int(aggregate.get("resident_gpu_allocator_record_stride_bytes", 0)) != Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES \
			or str(aggregate.get("resident_gpu_allocator_owner", "")) != "GPUAutoObjectRuntime" \
			or str(aggregate.get("resident_gpu_allocator_writeback_blocked_reason", "")) != "none":
		push_error("  FAIL: aggregate should preserve resident object-buffer diagnostics without allocator ownership: %s" % str(aggregate))
		generator.dispose()
		return false
	var blocked_aggregate := generator._new_gpu_autoobject_runtime_writeback_report(
		null,
		null,
		{"ok": true, "reason": "gpu_runtime_profile_buffers_ready"},
		true
	)
	generator._merge_gpu_autoobject_runtime_writeback_report(blocked_aggregate, {
		"ok": true,
		"reason": "gpu_runtime_writeback_ready",
		"accepted_count": 1,
		"spawned_count": 1,
		"runtime_command_flush_mode": "cpu_bulk_spawn_buffer_update",
		"accepted_placement_record_schema_version": Runtime.ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION,
		"accepted_placement_record_stride_bytes": Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
		"accepted_placement_record_count": 1,
		"accepted_placement_record_byte_count": Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
		"accepted_placement_record_debug_packed": true,
		"accepted_placement_record_shader_consumed": false,
		"accepted_placement_record_shader_name": "none",
		"accepted_placement_record_shader_path": "none",
		"accepted_placement_record_shader_dispatch_count": 0,
		"accepted_placement_record_shader_local_size_x": Runtime.ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X,
		"accepted_placement_record_shader_stats": {},
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"resident_gpu_allocator_record_stride_bytes": 0,
		"resident_gpu_allocator_owner": "none",
		"resident_gpu_allocator_writeback_blocked_reason": "no_resident_allocator_shader_dispatch",
	})
	if bool(blocked_aggregate.get("accepted_placement_record_shader_consumed", true)) \
			or str(blocked_aggregate.get("resident_gpu_allocator_writeback_blocked_reason", "")) != "no_resident_allocator_shader_dispatch":
		push_error("  FAIL: aggregate must not claim shader consumption for blocked CPU bulk flush: %s" % str(blocked_aggregate))
		generator.dispose()
		return false
	generator.dispose()
	print("  OK: runtime writeback aggregate preserves resident shader diagnostics")
	return true


func _test_accepted_placement_writeback_failure_reason_or_skip() -> bool:
	print("[VoxelMultiAsset] test_accepted_placement_writeback_failure_reason_or_skip...")
	var runtime := Runtime.new(1)
	if not runtime.is_gpu_ready():
		print("  SKIP: no RenderingDevice available for writeback failure reason")
		runtime.dispose()
		return true

	var container = ProfileContainer.new()
	if not container.attach_rendering_device(runtime.get_rendering_device(), false):
		push_error("  FAIL: profile container should attach runtime RenderingDevice")
		runtime.dispose()
		return false

	var profile_id: int = container.register_normalized_profile({
		"color": Color(0.15, 0.55, 0.25, 0.7),
		"complexity": 0.7,
		"collision": [
			{"voxel": Vector3i.ZERO, "collision_strength": 1.0, "weight": 1.0}
		],
		"pivot_variants": [
			{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}
		],
	})
	if profile_id <= 0 or not container.upload_profiles():
		push_error("  FAIL: expected uploaded GPU profile buffers for writeback failure test")
		container.dispose()
		runtime.dispose()
		return false

	var committer := SVC.new(16, 16.0, false)
	committer.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.15, 0.55, 0.25, 1.0), "complexity": 0.7, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var generator := VPG.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var result := generator.run_multi_asset(
		scene,
		collision,
		[
			{
				"collision": [
					{"shape": "cylinder", "radius": 0.3, "y_min": 0.0, "y_max": 1.0, "collision_strength": 1.0}
				],
				"result_capacity": 2,
				"profile_id": profile_id,
				"object_type": 38,
				"channel": 0,
				"radius": 1.0,
				"complexity": 0.7,
				"color": Color(0.15, 0.55, 0.25, 0.7),
			}
		],
		grid_size,
		Vector3.ONE,
		Vector3.ZERO,
		{
			"top_k": 4,
			"collision_limit": 0.0,
			"min_support_ratio": 1.0,
			"clearance_limit": 0.0,
			"min_distance_voxels": 0.0,
			"require_gpu_runtime_profile_contract": true,
			"gpu_autoobject_runtime": runtime,
			"auto_voxel_runtime_profile_container": container,
			"write_accepted_placements_to_gpu_runtime": true,
			"runtime_writeback_object_type": 38,
			"runtime_writeback_dirty_flags": {"auto": true, "collision": true, "scoring": true},
			"scene_voxel_committer": committer,
			"create_voxel_write_spec": true,
			"defer_blend": true,
			"capture_size": 16.0,
			"volume_xz_resolution": 16,
		}
	)
	var accepted_count := int(result.get("total_placed", 0))
	if accepted_count < 2:
		push_error("  FAIL: writeback failure test needs at least two accepted placements, got %d" % accepted_count)
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	var writeback: Dictionary = result.get("gpu_autoobject_runtime_writeback", {})
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: writeback failure result must keep cpu_fallback=false")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(writeback.get("ok", true)):
		push_error("  FAIL: capacity-limited writeback should report ok=false")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("reason", "")) == "gpu_runtime_profile_buffers_ready":
		push_error("  FAIL: writeback failure must not keep the ready contract reason")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("writeback_reason", "")) != "runtime_spawn_failed":
		push_error("  FAIL: writeback failure should expose runtime_spawn_failed, got %s" % str(writeback.get("writeback_reason", "")))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(writeback.get("readback_source", "")) != "none":
		push_error("  FAIL: failed merged writeback must not keep gpu_storage_buffers readback source")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(writeback.get("cpu_fallback", true)):
		push_error("  FAIL: failed merged writeback must report cpu_fallback=false")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var asset_writeback: Dictionary = ((result.get("asset_results", []) as Array)[0] as Dictionary).get("gpu_autoobject_runtime_writeback", {})
	if str(asset_writeback.get("readback_source", "")) != "none":
		push_error("  FAIL: failed per-asset writeback must not keep gpu_storage_buffers readback source")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(asset_writeback.get("cpu_fallback", true)):
		push_error("  FAIL: failed per-asset writeback must report cpu_fallback=false")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(writeback.get("spawned_count", -1)) != 0 or int(writeback.get("failed_count", 0)) < accepted_count:
		push_error("  FAIL: reservation failure should block staging and count accepted placements as failed")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var reservation: Dictionary = asset_writeback.get("accepted_placement_object_id_reservation", {})
	if bool(reservation.get("ok", true)) \
			or str(reservation.get("reason", "")) != "capacity_full" \
			or int(reservation.get("reserved_object_id_count", -1)) != 0:
		push_error("  FAIL: capacity-limited writeback should fail reservation without leaking reserved IDs: %s" % str(asset_writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var runtime_debug := runtime.get_debug_summary()
	if int(runtime_debug.get("reserved_object_id_count", -1)) != 0:
		push_error("  FAIL: failed VPG reservation path should leave no reserved object IDs: %s" % str(runtime_debug))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var source_writeback: Dictionary = result.get("instance_stamp_writeback", {})
	if not source_writeback.is_empty() and int(source_writeback.get("applied_count", 0)) > 0:
		push_error("  FAIL: reservation failure must not apply source writeback for unspawned placements")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if committer.get_voxel_write_spec_count() > int(writeback.get("spawned_count", 0)):
		push_error("  FAIL: committer must not retain ISWS/source records for unspawned placements")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	generator.dispose()
	container.dispose()
	runtime.dispose()
	print("  OK: writeback failure reason stays distinct from ready contract")
	return true


func _assert_cpu_scene_voxel_source_handoff_contract(report: Dictionary, label: String) -> bool:
	if str(report.get("source_write_handoff_mode", "")) != "cpu_batch_isws_pending_source_candidate_bridge":
		push_error("  FAIL: %s should identify CPU batch/pending-source SceneVoxel handoff: %s" % [label, str(report)])
		return false
	if str(report.get("source_write_batch_api", "")) != "apply_instance_stamp_write_specs":
		push_error("  FAIL: %s should use the committer ISWS batch API: %s" % [label, str(report)])
		return false
	if not bool(report.get("cpu_pending_source_candidate_bridge", false)):
		push_error("  FAIL: %s should report the CPU pending-source candidate bridge" % label)
		return false
	if str(report.get("pending_source_candidate_flush_api", "")) != "blend_scene_voxels->_flush_pending_scene_voxel_source_candidates":
		push_error("  FAIL: %s should identify the pending source candidate flush API" % label)
		return false
	if str(report.get("source_candidate_resolve_api", "")) != "resolve_scene_voxel_sources.glsl":
		push_error("  FAIL: %s should identify the source candidate resolve shader" % label)
		return false
	if bool(report.get("resident_source_write_buffer", true)):
		push_error("  FAIL: %s must not claim a resident source-write buffer" % label)
		return false
	if str(report.get("resident_source_write_buffer_owner", "")) != "none":
		push_error("  FAIL: %s resident source-write owner must be none" % label)
		return false
	if str(report.get("resident_source_write_buffer_rid", "")) != "none":
		push_error("  FAIL: %s resident source-write RID must be none" % label)
		return false
	if str(report.get("resident_source_write_buffer_lifetime", "")) != "none":
		push_error("  FAIL: %s resident source-write lifetime must be none" % label)
		return false
	if int(report.get("resident_source_write_buffer_stride_bytes", -1)) != 0:
		push_error("  FAIL: %s resident source-write stride must be 0" % label)
		return false
	if int(report.get("resident_source_write_buffer_range_count", -1)) != 0:
		push_error("  FAIL: %s resident source-write range count must be 0" % label)
		return false
	return true


func _test_run_multi_asset_writes_instance_stamp_specs_to_committer_or_skip() -> bool:
	print("[VoxelMultiAsset] test_run_multi_asset_writes_instance_stamp_specs_to_committer_or_skip...")
	var runtime := Runtime.new(8)
	if not runtime.is_gpu_ready():
		print("  SKIP: no RenderingDevice available for run_multi_asset committer writeback")
		runtime.dispose()
		return true

	var container = ProfileContainer.new()
	if not container.attach_rendering_device(runtime.get_rendering_device(), false):
		push_error("  FAIL: profile container should attach runtime RenderingDevice")
		runtime.dispose()
		return false
	var profile_id: int = container.register_normalized_profile({
		"color": Color(0.2, 0.7, 0.25, 0.8),
		"complexity": 0.8,
		"collision": [
			{"voxel": Vector3i.ZERO, "collision_strength": 1.0, "weight": 1.0}
		],
		"pivot_variants": [
			{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}
		],
	})
	if profile_id <= 0 or not container.upload_profiles():
		push_error("  FAIL: expected uploaded GPU profile buffers for committer writeback")
		container.dispose()
		runtime.dispose()
		return false

	var committer := SVC.new(16, 16.0, false)
	committer.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.2, 0.7, 0.25, 1.0), "complexity": 0.8, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var generator := VPG.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var writeback_object_type := 39
	var result := generator.run_multi_asset(
		scene,
		collision,
		[
			{
				"collision": [
					{"shape": "cylinder", "radius": 0.3, "y_min": 0.0, "y_max": 1.0, "collision_strength": 1.0}
				],
				"result_capacity": 1,
				"profile_id": profile_id,
				"object_type": writeback_object_type,
				"channel": 0,
				"radius": 1.0,
				"complexity": 0.8,
				"color": Color(0.2, 0.7, 0.25, 0.8),
			}
		],
		grid_size,
		Vector3.ONE,
		Vector3.ZERO,
		{
			"top_k": 2,
			"collision_limit": 0.0,
			"min_support_ratio": 1.0,
			"clearance_limit": 0.0,
			"require_gpu_runtime_profile_contract": true,
			"gpu_autoobject_runtime": runtime,
			"auto_voxel_runtime_profile_container": container,
			"min_distance_voxels": 0.0,
			"write_accepted_placements_to_gpu_runtime": true,
			"runtime_writeback_object_type": writeback_object_type,
			"runtime_writeback_dirty_flags": {"auto": true, "collision": true, "scoring": true},
			"scene_voxel_committer": committer,
			"create_voxel_write_spec": true,
			"defer_blend": true,
			"capture_size": 16.0,
			"volume_xz_resolution": 16,
		}
	)

	var accepted_count := int(result.get("total_placed", 0))
	if accepted_count <= 0:
		push_error("  FAIL: committer writeback test needs accepted placements")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var runtime_writeback: Dictionary = result.get("gpu_autoobject_runtime_writeback", {})
	if not bool(runtime_writeback.get("ok", false)) or bool(runtime_writeback.get("cpu_fallback", true)):
		push_error("  FAIL: GPU runtime writeback should remain successful without CPU fallback")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var source_writeback: Dictionary = result.get("instance_stamp_writeback", {})
	if not bool(source_writeback.get("ok", false)):
		push_error("  FAIL: run_multi_asset should write accepted placements as ISWS/source records: %s" % str(source_writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(source_writeback.get("accepted_placement_writeback_mode", "")) != "cpu_dictionary_to_scene_voxel_committer":
		push_error("  FAIL: source writeback should identify CPU dictionary SceneVoxelCommitter mode: %s" % str(source_writeback))
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if str(source_writeback.get("accepted_placement_record_source", "")) != "cpu_instance_stamp_write_spec_dictionaries":
		push_error("  FAIL: source writeback should identify CPU ISWS dictionaries as the record source")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if bool(source_writeback.get("resident_gpu_allocator_writeback", true)):
		push_error("  FAIL: source writeback must not claim resident GPU allocator writeback")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if not _assert_cpu_scene_voxel_source_handoff_contract(source_writeback, "source writeback"):
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var source_asset_reports: Array = source_writeback.get("asset_reports", [])
	if source_asset_reports.is_empty():
		push_error("  FAIL: source writeback should include per-asset report contract")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var source_asset_report: Dictionary = source_asset_reports[0] as Dictionary
	if not _assert_cpu_scene_voxel_source_handoff_contract(source_asset_report, "source asset writeback"):
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(source_writeback.get("applied_count", 0)) < accepted_count:
		push_error("  FAIL: source writeback should apply every accepted placement")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if committer.get_instance_stamp_write_specs().size() < accepted_count:
		push_error("  FAIL: committer should retain ISWS/source records from run_multi_asset")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("  FAIL: source records should mark dirty SceneVoxelTiles before deferred blend")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	committer.blend_scene_voxels()
	if committer.get_scene_voxels().is_empty():
		push_error("  FAIL: deferred source records should publish committed SceneVoxel payload")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false

	generator.dispose()
	container.dispose()
	runtime.dispose()
	print("  OK: run_multi_asset writes accepted placements through ISWS into SceneVoxelCommitter")
	return true


func _test_run_multi_asset_stages_source_candidates_to_resident_buffers_or_skip() -> bool:
	print("[VoxelMultiAsset] test_run_multi_asset_stages_source_candidates_to_resident_buffers_or_skip...")
	if not _has_rendering_device():
		print("  SKIP: no RenderingDevice available for resident candidate staging")
		return true

	var committer := SVC.new(16, 16.0, false)
	if not committer._gpu_ready:
		push_error("  FAIL: SceneVoxelCommitter GPU resources are not ready")
		committer.dispose(true)
		return false
	committer.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.2, 0.7, 0.25, 1.0), "complexity": 0.8, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var generator := VPG.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var settings := {
		"top_k": 2,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
		"scene_voxel_committer": committer,
		"create_voxel_write_spec": true,
		"defer_blend": true,
		"capture_size": 16.0,
		"volume_xz_resolution": 16,
	}
	settings[VPG.STAGE_SCENE_VOXEL_SOURCE_CANDIDATES_CONFIG_KEY] = true

	var result := generator.run_multi_asset(
		scene,
		collision,
		[
			{
				"collision": [
					{"shape": "cylinder", "radius": 0.3, "y_min": 0.0, "y_max": 1.0, "collision_strength": 1.0}
				],
				"result_capacity": 1,
				"channel": 0,
				"radius": 1.0,
				"complexity": 0.8,
				"color": Color(0.2, 0.7, 0.25, 0.8),
			}
		],
		grid_size,
		Vector3.ONE,
		Vector3.ZERO,
		settings
	)

	var accepted_count := int(result.get("total_placed", 0))
	if accepted_count <= 0:
		push_error("  FAIL: staged source-candidate handoff test needs accepted placements")
		generator.dispose()
		committer.dispose(true)
		return false

	var source_writeback: Dictionary = result.get("instance_stamp_writeback", {})
	if not bool(source_writeback.get("ok", false)):
		push_error("  FAIL: opt-in source writeback should succeed: %s" % str(source_writeback))
		generator.dispose()
		committer.dispose(true)
		return false
	if int(source_writeback.get("applied_count", 0)) < accepted_count or committer.get_instance_stamp_write_specs().size() < accepted_count:
		push_error("  FAIL: accepted placements should write ISWS records before staging: %s" % str(source_writeback))
		generator.dispose()
		committer.dispose(true)
		return false
	if not bool(source_writeback.get("cpu_pending_source_candidate_bridge", false)):
		push_error("  FAIL: staged handoff should keep the CPU pending-source bridge true: %s" % str(source_writeback))
		generator.dispose()
		committer.dispose(true)
		return false
	if not bool(source_writeback.get("resident_source_write_buffer", false)):
		push_error("  FAIL: opt-in handoff should stage resident source-candidate buffers: %s" % str(source_writeback))
		generator.dispose()
		committer.dispose(true)
		return false
	if str(source_writeback.get("resident_source_write_buffer_owner", "")) != "SceneVoxelCommitter":
		push_error("  FAIL: staged resident candidate buffer owner mismatch: %s" % str(source_writeback))
		generator.dispose()
		committer.dispose(true)
		return false
	if int(source_writeback.get("resident_source_candidate_buffer_stride_bytes", -1)) != 16 \
			or int(source_writeback.get("resident_source_range_buffer_stride_bytes", -1)) != 8:
		push_error("  FAIL: staged resident candidate/range strides should be 16/8 bytes: %s" % str(source_writeback))
		generator.dispose()
		committer.dispose(true)
		return false
	if int(source_writeback.get("resident_source_candidate_buffer_count", 0)) <= 0 \
			or int(source_writeback.get("resident_source_range_buffer_count", 0)) <= 0:
		push_error("  FAIL: staged resident candidate/range counts should be positive: %s" % str(source_writeback))
		generator.dispose()
		committer.dispose(true)
		return false
	var staging_report := _source_candidate_staging_report_from_writeback(source_writeback)
	if staging_report.is_empty():
		push_error("  FAIL: opt-in handoff should include a full source-candidate staging report")
		generator.dispose()
		committer.dispose(true)
		return false
	if not bool(staging_report.get("resident_source_candidate_payload_buffer", false)) \
			or not bool(staging_report.get("resident_source_candidate_group_index_buffer", false)):
		push_error("  FAIL: staged handoff should include resident full candidate payload and key-index buffers: %s" % str(staging_report))
		generator.dispose()
		committer.dispose(true)
		return false
	if int(staging_report.get("resident_source_candidate_payload_buffer_stride_bytes", -1)) != SVC.SCENE_VOXEL_SOURCE_PAYLOAD_STRIDE_BYTES \
			or int(staging_report.get("resident_source_candidate_group_index_buffer_stride_bytes", -1)) != 4:
		push_error("  FAIL: staged payload/group-index strides should be 64/4 bytes: %s" % str(staging_report))
		generator.dispose()
		committer.dispose(true)
		return false
	if int(staging_report.get("resident_source_candidate_payload_buffer_count", 0)) <= 0 \
			or int(staging_report.get("resident_source_candidate_group_index_buffer_count", 0)) <= 0:
		push_error("  FAIL: staged payload/group-index counts should be positive: %s" % str(staging_report))
		generator.dispose()
		committer.dispose(true)
		return false
	if str(source_writeback.get("runtime_read_source", "")) != "none" \
			or bool(source_writeback.get("final_source_stream_resident", true)) \
			or str(source_writeback.get("final_source_stream_resident_source", "")) != "none":
		push_error("  FAIL: candidate staging must not claim resident final source streams: %s" % str(source_writeback))
		generator.dispose()
		committer.dispose(true)
		return false
	if bool(source_writeback.get("resident_gpu_allocator_writeback", true)) \
			or str(source_writeback.get("resident_gpu_allocator_writeback_mode", "")) != "none":
		push_error("  FAIL: source-candidate staging must not claim resident GPU allocator writeback: %s" % str(source_writeback))
		generator.dispose()
		committer.dispose(true)
		return false
	if not committer.get_scene_voxels().is_empty():
		push_error("  FAIL: staged source candidates should not materialize public SceneVoxels before blend")
		generator.dispose()
		committer.dispose(true)
		return false

	committer.blend_scene_voxels()
	var blend_summary_before_api := committer.get_last_blend_scene_voxel_commit_summary()
	if not bool(blend_summary_before_api.get("resident_committed_scene_voxel_payload_buffer", false)) \
			or str(blend_summary_before_api.get("committed_scene_voxel_runtime_read_source", "")) != "resident_committed_scene_voxel_payload_buffer":
		push_error("  FAIL: blend should retain the committed SceneVoxel payload buffer as the runtime source before public API access: %s" % str(blend_summary_before_api))
		generator.dispose()
		committer.dispose(true)
		return false
	if not _assert_public_scene_voxel_debug_api_projection(blend_summary_before_api, "blend summary before public API", false):
		generator.dispose()
		committer.dispose(true)
		return false

	var public_scene_voxels_after_blend := committer.get_scene_voxels()
	if public_scene_voxels_after_blend.is_empty():
		push_error("  FAIL: deferred staged source candidates should hydrate public SceneVoxel cache on API access")
		generator.dispose()
		committer.dispose(true)
		return false
	var first_public_key := str(public_scene_voxels_after_blend.keys()[0])
	var first_public_key_parts := first_public_key.split(":")
	if first_public_key_parts.size() != 3:
		push_error("  FAIL: hydrated public SceneVoxel key should be slice:x:z, got %s" % first_public_key)
		generator.dispose()
		committer.dispose(true)
		return false
	var public_scene_voxel := committer.get_scene_voxel(
		int(first_public_key_parts[0]),
		Vector2i(int(first_public_key_parts[1]), int(first_public_key_parts[2]))
	)
	if public_scene_voxel.is_empty():
		push_error("  FAIL: get_scene_voxel should read from the hydrated debug/API cache for key %s" % first_public_key)
		generator.dispose()
		committer.dispose(true)
		return false
	var resolve_summary := committer.get_last_scene_voxel_source_resolve_summary()
	if not bool(resolve_summary.get("gpu_dispatched", false)) \
			or bool(resolve_summary.get("cpu_runtime_fallback", true)):
		push_error("  FAIL: source candidate resolve should be a real GPU dispatch without CPU runtime fallback: %s" % str(resolve_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if not bool(resolve_summary.get("final_source_stream_resident", false)) \
			or str(resolve_summary.get("final_source_stream_resident_source", "")) != "resolve_scene_voxel_sources.glsl":
		push_error("  FAIL: GPU resolve should publish resident final source streams: %s" % str(resolve_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if str(resolve_summary.get("source_candidate_winner_readback_source", "")) != "none" \
			or int(resolve_summary.get("source_candidate_winner_readback_count", -1)) != 0 \
			or bool(resolve_summary.get("source_candidate_cpu_apply_bridge", true)) \
			or str(resolve_summary.get("source_candidate_cpu_apply_bridge_target", "")) != "none":
		push_error("  FAIL: GPU resolve must not read back winners or use the CPU apply bridge: %s" % str(resolve_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if int(resolve_summary.get("final_source_stream_resident_stride_bytes", -1)) != SVC.SCENE_VOXEL_SOURCE_PAYLOAD_STRIDE_BYTES \
			or int(resolve_summary.get("final_source_stream_resident_count", 0)) <= 0:
		push_error("  FAIL: resident final source stream diagnostics should retain count/stride: %s" % str(resolve_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if str(resolve_summary.get("resident_auto_source_stream_buffer_rid", "none")) == "none" \
			or str(resolve_summary.get("resident_brush_source_stream_buffer_rid", "none")) == "none":
		push_error("  FAIL: resident final Auto/Brush source stream RIDs should be retained: %s" % str(resolve_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	var blend_summary := committer.get_last_blend_scene_voxel_commit_summary()
	if bool(blend_summary.get("source_candidate_cpu_apply_bridge", true)) \
			or not bool(blend_summary.get("final_source_stream_resident", false)) \
			or bool(blend_summary.get("cpu_fallback", true)):
		push_error("  FAIL: blend should keep CPU dictionaries as projection while using GPU-resident final source streams: %s" % str(blend_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if str(blend_summary.get("source_candidate_winner_readback_source", "")) != "none" \
			or int(blend_summary.get("source_candidate_winner_readback_count", -1)) != 0 \
			or str(blend_summary.get("source_candidate_cpu_apply_bridge_target", "")) != "none":
		push_error("  FAIL: blend summary must preserve no winner readback / no CPU apply bridge diagnostics: %s" % str(blend_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if str(blend_summary.get("runtime_read_source", "")) != "resident_resolved_source_stream_buffers":
		push_error("  FAIL: blend summary should identify the resident resolved source stream path: %s" % str(blend_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if not bool(blend_summary.get("resident_committed_scene_voxel_payload_buffer", false)) \
			or str(blend_summary.get("committed_scene_voxel_runtime_read_source", "")) != "resident_committed_scene_voxel_payload_buffer":
		push_error("  FAIL: blend should retain the committed SceneVoxel payload buffer as the runtime source: %s" % str(blend_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if str(blend_summary.get("committed_scene_voxel_payload_buffer_rid", "none")) == "none" \
			or int(blend_summary.get("committed_scene_voxel_payload_buffer_stride_bytes", -1)) != SVC.SCENE_VOXEL_COMMITTED_PAYLOAD_STRIDE_BYTES \
			or int(blend_summary.get("committed_scene_voxel_payload_buffer_count", 0)) <= 0:
		push_error("  FAIL: committed SceneVoxel payload buffer RID/stride/count diagnostics are invalid: %s" % str(blend_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	var committed_payload_count := int(blend_summary.get("committed_scene_voxel_payload_buffer_count", 0))
	if not bool(blend_summary.get("resident_committed_scene_voxel_key_coord_buffer", false)) \
			or str(blend_summary.get("committed_scene_voxel_key_coord_runtime_read_source", "")) != "resident_committed_scene_voxel_key_coord_buffer":
		push_error("  FAIL: committed SceneVoxel payload slots should have a resident key/coordinate map: %s" % str(blend_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if str(blend_summary.get("committed_scene_voxel_key_coord_buffer_rid", "none")) == "none" \
			or str(blend_summary.get("committed_scene_voxel_key_coord_buffer_owner", "")) != "SceneVoxelCommitter" \
			or str(blend_summary.get("committed_scene_voxel_key_coord_buffer_lifetime", "")) != "persistent_until_next_scene_voxel_commit" \
			or int(blend_summary.get("committed_scene_voxel_key_coord_buffer_stride_bytes", -1)) != SVC.SCENE_VOXEL_COMMITTED_KEY_COORD_STRIDE_BYTES \
			or str(blend_summary.get("committed_scene_voxel_key_coord_buffer_format", "")) != SVC.SCENE_VOXEL_COMMITTED_KEY_COORD_FORMAT \
			or int(blend_summary.get("committed_scene_voxel_key_coord_buffer_count", -1)) != committed_payload_count:
		push_error("  FAIL: committed SceneVoxel key/coordinate buffer RID/owner/lifetime/stride/format/count diagnostics are invalid: %s" % str(blend_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if str(blend_summary.get("committed_scene_voxel_payload_slot_map_runtime_source", "")) != "resident_committed_scene_voxel_key_coord_buffer" \
			or bool(blend_summary.get("committed_scene_voxel_payload_slot_map_cpu_dictionary_source", true)) \
			or bool(blend_summary.get("committed_scene_voxel_payload_slot_map_public_dictionary_source", true)):
		push_error("  FAIL: committed payload slot mapping must not claim CPU source-key order or public dictionaries as runtime source: %s" % str(blend_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if not _assert_public_scene_voxel_debug_api_projection(blend_summary, "blend summary"):
		generator.dispose()
		committer.dispose(true)
		return false
	var committed_payload_summary := committer.get_committed_scene_voxel_payload_buffer_summary()
	if not bool(committed_payload_summary.get("rendering_device_available", false)) \
			or not bool(committed_payload_summary.get("resident_committed_scene_voxel_payload_buffer", false)) \
			or bool(committed_payload_summary.get("cpu_fallback", true)):
		push_error("  FAIL: committed SceneVoxel payload summary must prove a resident RD buffer with no CPU fallback: %s" % str(committed_payload_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if not _assert_public_scene_voxel_debug_api_projection(committed_payload_summary, "committed payload summary"):
		generator.dispose()
		committer.dispose(true)
		return false
	var committed_key_coord_summary := committer.get_committed_scene_voxel_key_coord_buffer_summary()
	if not committer.get_committed_scene_voxel_key_coord_buffer().is_valid() \
			or not bool(committed_key_coord_summary.get("rendering_device_available", false)) \
			or not bool(committed_key_coord_summary.get("resident_committed_scene_voxel_key_coord_buffer", false)) \
			or bool(committed_key_coord_summary.get("cpu_fallback", true)) \
			or str(committed_key_coord_summary.get("committed_scene_voxel_payload_slot_map_runtime_source", "")) != "resident_committed_scene_voxel_key_coord_buffer" \
			or bool(committed_key_coord_summary.get("committed_scene_voxel_payload_slot_map_cpu_dictionary_source", true)) \
			or bool(committed_key_coord_summary.get("committed_scene_voxel_payload_slot_map_public_dictionary_source", true)):
		push_error("  FAIL: committed SceneVoxel key/coordinate summary/accessor must prove resident RD slot mapping without CPU dictionary runtime source: %s" % str(committed_key_coord_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	var sv := committer.get_sv()
	if str(sv.get("scene_field_source", "")) != "resident_committed_scene_voxel_payload_buffers" \
			or str(sv.get("scene_field_projection_mode", "")) != "committed_payload_dense_scatter" \
			or str(sv.get("scene_field_runtime_read_source", "")) != "resident_committed_scene_voxel_payload_buffer" \
			or not bool(sv.get("scene_field_committed_payload_projection", false)):
		push_error("  FAIL: dense SV scene_field should scatter from resident committed payload/key buffers, not CPU source-key projection: %s" % str(sv))
		generator.dispose()
		committer.dispose(true)
		return false
	if int(sv.get("scene_field_committed_payload_count", -1)) != committed_payload_count \
			or int(sv.get("scene_field_committed_key_coord_count", -1)) != committed_payload_count:
		push_error("  FAIL: dense SV scene_field committed payload/key scatter counts should match committed payload count: %s" % str(sv))
		generator.dispose()
		committer.dispose(true)
		return false
	var sv_payload_summary: Dictionary = sv.get("committed_scene_voxel_payload_buffer_summary", {})
	if not bool(sv_payload_summary.get("committed_scene_voxel_dense_projection_ready", false)) \
			or str(sv_payload_summary.get("committed_scene_voxel_scene_field_projection_source", "")) != "resident_committed_scene_voxel_payload_buffer":
		push_error("  FAIL: SV should carry committed-payload dense projection diagnostics: %s" % str(sv_payload_summary))
		generator.dispose()
		committer.dispose(true)
		return false
	if not _assert_public_scene_voxel_debug_api_projection(sv_payload_summary, "SV payload summary"):
		generator.dispose()
		committer.dispose(true)
		return false
	if not _assert_public_scene_voxel_debug_api_projection(sv, "SV public projection"):
		generator.dispose()
		committer.dispose(true)
		return false
	var scene_field: PackedFloat32Array = sv.get("scene_field", PackedFloat32Array())
	var nonzero_scene_field_cells := 0
	for value in scene_field:
		if float(value) > 0.001:
			nonzero_scene_field_cells += 1
	if nonzero_scene_field_cells <= 0:
		push_error("  FAIL: dense SV scene_field scatter from committed payloads produced no occupied cells")
		generator.dispose()
		committer.dispose(true)
		return false

	generator.dispose()
	committer.dispose(true)
	print("  OK: opt-in VPG handoff resolves source streams and retains committed SceneVoxel payload/key-coordinate buffers")
	return true


func _assert_public_scene_voxel_debug_api_projection(summary: Dictionary, label: String, expect_hydrated: bool = true) -> bool:
	if str(summary.get("public_scene_voxel_projection_source", "")) != "resident_committed_scene_voxel_payload_key_coord_buffers" \
			or str(summary.get("public_scene_voxel_projection_role", "")) != "debug_api_projection" \
			or not bool(summary.get("public_scene_voxel_projection_debug_only", false)) \
			or not bool(summary.get("public_scene_voxel_projection_api_only", false)) \
			or bool(summary.get("public_scene_voxel_projection_runtime_owner", true)) \
			or bool(summary.get("public_scene_voxel_projection_scene_field_source", true)) \
			or str(summary.get("public_scene_voxel_projection_runtime_read_source", "")) != "none" \
			or str(summary.get("public_scene_voxel_projection_api", "")) != "get_scene_voxels/get_scene_voxel":
		push_error("  FAIL: %s must label public SceneVoxel dictionaries as debug/API-only readback, not runtime ownership/source: %s" % [label, str(summary)])
		return false
	if bool(summary.get("public_scene_voxel_projection_readback", false)) != expect_hydrated \
			or bool(summary.get("public_scene_voxel_projection_cache_hydrated", false)) != expect_hydrated:
		push_error("  FAIL: %s public SceneVoxel cache hydrated/readback state mismatch: %s" % [label, str(summary)])
		return false
	if int(summary.get("public_scene_voxel_projection_expected_count", 0)) <= 0:
		push_error("  FAIL: %s public SceneVoxel projection should retain expected count: %s" % [label, str(summary)])
		return false
	if expect_hydrated:
		if str(summary.get("public_scene_voxel_projection_readback_source", "")) != "resident_committed_scene_voxel_payload_buffer_debug_api_readback" \
				or bool(summary.get("public_scene_voxel_projection_cache_pending", true)) \
				or int(summary.get("public_scene_voxel_projection_cache_count", 0)) <= 0:
			push_error("  FAIL: %s should report hydrated debug/API readback from resident committed buffers: %s" % [label, str(summary)])
			return false
	elif str(summary.get("public_scene_voxel_projection_readback_source", "")) != "none" \
			or not bool(summary.get("public_scene_voxel_projection_cache_pending", false)) \
			or int(summary.get("public_scene_voxel_projection_cache_count", -1)) != 0:
		push_error("  FAIL: %s should report pending lazy debug/API cache before public getter access: %s" % [label, str(summary)])
		return false
	return true


func _source_candidate_staging_report_from_writeback(source_writeback: Dictionary) -> Dictionary:
	var direct = source_writeback.get("source_candidate_staging_report", {})
	if direct is Dictionary and not (direct as Dictionary).is_empty():
		return (direct as Dictionary).duplicate(true)

	var asset_reports: Array = source_writeback.get("asset_reports", [])
	for raw_report in asset_reports:
		if not raw_report is Dictionary:
			continue
		var asset_report := raw_report as Dictionary
		var nested = asset_report.get("source_candidate_staging_report", {})
		if nested is Dictionary and not (nested as Dictionary).is_empty():
			return (nested as Dictionary).duplicate(true)
	return {}


func _test_run_multi_asset_preserves_target_read_buffer_diagnostics_or_skip() -> bool:
	print("[VoxelMultiAsset] test_run_multi_asset_preserves_target_read_buffer_diagnostics_or_skip...")
	if not _has_rendering_device():
		print("  SKIP: no RenderingDevice available for resident TargetSV read-buffer handoff")
		return true

	var grid_size := Vector3i(8, 4, 8)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var fill_generator := VPG.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[fill_generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0
	fill_generator.dispose()

	var expected_bytes := voxel_count * 4
	var target_color_rgba8_bytes := PackedByteArray()
	var target_occupancy_bytes := PackedByteArray()
	target_color_rgba8_bytes.resize(expected_bytes)
	target_occupancy_bytes.resize(expected_bytes)
	for i in range(voxel_count):
		target_color_rgba8_bytes.encode_u32(i * 4, 0x3366ccff)
		target_occupancy_bytes.encode_float(i * 4, 0.5)

	var asset_defs := [
		{
			"collision": [
				{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "collision_strength": 1.0}
			],
			"result_capacity": 1,
		}
	]
	var common_settings := {
		"top_k": 1,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
		"target_color_rgba8_bytes": target_color_rgba8_bytes,
		"target_occupancy_bytes": target_occupancy_bytes,
	}

	var actor := SPA.new()
	if not actor.initialize(true, false):
		push_error("  FAIL: ScenePlacementActor should initialize a RenderingDevice for resident TargetSV buffers")
		actor.dispose(true)
		return false
	var target_settings := common_settings.duplicate(true)
	target_settings[SPA.RESIDENT_TARGET_READ_BUFFERS_OPT_IN_KEY] = true
	var sv := {
		"grid_size": grid_size,
		"voxel_size": Vector3.ONE,
		"scene_field": scene,
		"collision_field": collision,
	}
	var target_buffers: Dictionary = actor.prepare_target_read_buffers_from_common_gpu(target_settings, sv)
	if not bool(target_buffers.get("ok", false)) or not bool(target_buffers.get("resident_target_read_buffer_handoff", false)):
		push_error("  FAIL: resident TargetSV read-buffer prep should succeed: %s" % str(target_buffers))
		actor.dispose(true)
		return false

	var borrowed_generator := VPG.new()
	if not borrowed_generator.attach_rendering_device(actor.get_rendering_device(), false):
		push_error("  FAIL: VPG should attach the ScenePlacementActor RenderingDevice")
		actor.dispose(true)
		return false
	var external_scene_field_buffer := actor.storage_buffer_from_floats(scene, "persistent", "test_external_scene_field")
	var external_collision_field_buffer := actor.storage_buffer_from_floats(collision, "persistent", "test_external_collision_field")
	if not external_scene_field_buffer.is_valid() or not external_collision_field_buffer.is_valid():
		push_error("  FAIL: external resident scene/collision test buffers should be valid")
		actor.dispose(true)
		return false
	var borrowed_settings := common_settings.duplicate(true)
	borrowed_settings["target_read_buffers"] = target_buffers
	borrowed_settings["scene_field_buffer_rid"] = external_scene_field_buffer
	borrowed_settings["collision_field_buffer_rid"] = external_collision_field_buffer
	borrowed_settings["scene_field_buffer_borrowed"] = true
	borrowed_settings["collision_field_buffer_borrowed"] = true
	borrowed_settings["scene_field_buffer_owner"] = "test_external_scene_voxel_committer"
	borrowed_settings["collision_field_buffer_owner"] = "test_external_scene_voxel_committer"
	borrowed_settings["gpu_state_chain_source"] = "test_external_scene_voxel_tile_resident_fields"
	var borrowed_result := borrowed_generator.run_multi_asset(
		scene,
		collision,
		asset_defs,
		grid_size,
		Vector3.ONE,
		Vector3.ZERO,
		borrowed_settings
	)
	if not _assert_target_read_buffer_summary(borrowed_result, true, expected_bytes, "borrowed resident TargetSV"):
		actor.dispose(true)
		return false
	if not _assert_external_field_buffer_handoff(
		borrowed_result,
		external_scene_field_buffer,
		external_collision_field_buffer
	):
		actor.dispose(true)
		return false
	actor.dispose(true)

	var uploaded_generator := VPG.new()
	var uploaded_result := uploaded_generator.run_multi_asset(
		scene,
		collision,
		asset_defs,
		grid_size,
		Vector3.ONE,
		Vector3.ZERO,
		common_settings
	)
	if not _assert_target_read_buffer_summary(uploaded_result, false, expected_bytes, "uploaded TargetSV bytes"):
		uploaded_generator.dispose()
		return false
	uploaded_generator.dispose()

	print("  OK: multi-asset preserves TargetSV read-buffer diagnostics for resident borrow and byte upload")
	return true


func _assert_external_field_buffer_handoff(result: Dictionary, scene_rid: RID, collision_rid: RID) -> bool:
	var chain: Dictionary = result.get("gpu_state_chain", {})
	if chain.is_empty():
		push_error("  FAIL: borrowed field run should report gpu_state_chain diagnostics")
		return false
	if not bool(chain.get("gpu_state_chaining", false)) or bool(chain.get("cpu_state_chaining", true)):
		push_error("  FAIL: borrowed field chain should stay GPU-resident: %s" % str(chain))
		return false
	var result_scene_rid: RID = chain.get("scene_field_buffer_rid", RID())
	var result_collision_rid: RID = chain.get("collision_field_buffer_rid", RID())
	if result_scene_rid != scene_rid or result_collision_rid != collision_rid:
		push_error("  FAIL: VPG overwrote caller-provided field RIDs: %s" % str(chain))
		return false
	if not bool(chain.get("scene_field_buffer_borrowed", false)) or not bool(chain.get("collision_field_buffer_borrowed", false)):
		push_error("  FAIL: VPG should report caller field RIDs as borrowed: %s" % str(chain))
		return false
	if str(chain.get("source", "")) != "test_external_scene_voxel_tile_resident_fields":
		push_error("  FAIL: VPG should preserve external field source label: %s" % str(chain))
		return false
	var scene_out: PackedFloat32Array = result.get("scene_field_out", PackedFloat32Array())
	var collision_out: PackedFloat32Array = result.get("collision_field_out", PackedFloat32Array())
	if scene_out.size() > 0 or collision_out.size() > 0:
		push_error("  FAIL: resident field chain should not read back full fields by default")
		return false
	return true


func _assert_target_read_buffer_summary(result: Dictionary, expect_borrowed: bool, expected_bytes: int, label: String) -> bool:
	if result.is_empty():
		push_error("  FAIL: %s run_multi_asset returned empty" % label)
		return false
	if bool(result.get("cpu_fallback", false)):
		push_error("  FAIL: %s aggregate must not claim CPU fallback" % label)
		return false
	var asset_results: Array = result.get("asset_results", [])
	if asset_results.size() != 1:
		push_error("  FAIL: %s expected one asset result, got %d" % [label, asset_results.size()])
		return false
	var aggregate_summary: Dictionary = result.get("target_read_buffer_summary", {})
	var asset_summary: Dictionary = (asset_results[0] as Dictionary).get("target_read_buffer_summary", {})
	for summary in [aggregate_summary, asset_summary]:
		if summary.is_empty():
			push_error("  FAIL: %s missing target_read_buffer_summary in aggregate or per-asset result" % label)
			return false
		if not bool(summary.get("ready", false)):
			push_error("  FAIL: %s target summary should report ready=true: %s" % [label, str(summary)])
			return false
		if bool(summary.get("cpu_fallback", true)) or not bool(summary.get("gpu_first", false)):
			push_error("  FAIL: %s target summary must stay GPU-first with cpu_fallback=false: %s" % [label, str(summary)])
			return false
		if int(summary.get("target_color_rgba8_byte_count", 0)) != expected_bytes \
				or int(summary.get("target_occupancy_byte_count", 0)) != expected_bytes:
			push_error("  FAIL: %s target byte counts were not preserved: %s" % [label, str(summary)])
			return false
		if bool(summary.get("target_read_buffers_borrowed", false)) != expect_borrowed:
			push_error("  FAIL: %s borrowed flag mismatch: %s" % [label, str(summary)])
			return false
		if bool(summary.get("target_read_buffers_uploaded", false)) == expect_borrowed:
			push_error("  FAIL: %s uploaded flag mismatch: %s" % [label, str(summary)])
			return false
		var expected_source := "borrowed_scene_placement_actor_resident" if expect_borrowed else "uploaded_target_bytes"
		if str(summary.get("target_read_buffer_source", "")) != expected_source:
			push_error("  FAIL: %s target source mismatch: %s" % [label, str(summary)])
			return false
		if expect_borrowed:
			if str(summary.get("borrowed_from", "")) != "ScenePlacementActor" \
					or str(summary.get("owner", "")) != "ScenePlacementActor" \
					or not bool(summary.get("rendering_device_match", false)):
				push_error("  FAIL: %s resident borrow ownership diagnostics missing: %s" % [label, str(summary)])
				return false
		elif str(summary.get("borrowed_from", "")) != "none" or bool(summary.get("rendering_device_match", true)):
			push_error("  FAIL: %s uploaded byte path should stay explicit and non-borrowed: %s" % [label, str(summary)])
			return false
	return true


func _test_gpu_runtime_profile_contract_has_no_cpu_fallback() -> bool:
	print("[VoxelMultiAsset] test_gpu_runtime_profile_contract_has_no_cpu_fallback...")
	var generator := VPG.new()
	var runtime := Runtime.new(2, false)
	var grid_size := Vector3i(4, 2, 4)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)
	var asset_defs := [
		{
			"collision": [{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0}],
			"result_capacity": 1,
		}
	]
	var result := generator.run_multi_asset(
		scene,
		collision,
		asset_defs,
		grid_size,
		Vector3.ONE,
		Vector3.ZERO,
		{
			"require_gpu_runtime_profile_contract": true,
			"gpu_autoobject_runtime": runtime,
		}
	)
	var contract: Dictionary = result.get("gpu_runtime_profile_contract", {})
	if not bool(result.get("contract_blocked", false)):
		push_error("  FAIL: missing GPU profile container should block placement contract")
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: blocked placement contract must not CPU fallback")
		return false
	if not bool(result.get("gpu_first", false)):
		push_error("  FAIL: blocked placement contract must keep gpu_first=true")
		return false
	if str(result.get("readback_source", "")) != "none":
		push_error("  FAIL: blocked placement contract must not expose a success readback source")
		return false
	if bool(contract.get("ok", true)):
		push_error("  FAIL: blocked placement contract should report ok=false")
		return false
	if str(contract.get("reason", "")) == "not_requested":
		push_error("  FAIL: required GPU runtime/profile contract must not be treated as optional")
		return false
	var asset_results: Array = result.get("asset_results", [])
	if asset_results.size() != 1 or int((asset_results[0] as Dictionary).get("result_count", -1)) != 0:
		push_error("  FAIL: blocked contract should not produce placement results")
		return false
	var asset_result: Dictionary = asset_results[0] as Dictionary
	if not bool(asset_result.get("gpu_first", false)) or bool(asset_result.get("cpu_fallback", true)):
		push_error("  FAIL: blocked per-asset contract must stay GPU-first with no CPU fallback")
		return false
	if str(asset_result.get("readback_source", "")) != "none":
		push_error("  FAIL: blocked per-asset contract must not expose a success readback source")
		return false

	runtime.dispose()
	generator.dispose()
	print("  OK: missing GPU buffers block placement without CPU fallback")
	return true


func _test_gpu_compute_blocked_has_no_empty_success() -> bool:
	print("[VoxelMultiAsset] test_gpu_compute_blocked_has_no_empty_success...")
	var generator := VPG.new()
	var grid_size := Vector3i(4, 2, 4)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)
	var result := generator.run_minimal(
		scene,
		collision,
		[{"local_pos": Vector3i.ZERO, "collision_strength": 1.0, "weight": 1.0}],
		grid_size,
		{
			"candidate_voxel_sparses": [Vector3i.ZERO],
			"top_k": 1,
			"result_capacity": 1,
			"min_support_ratio": 0.0,
			"collision_limit": 0.0,
			"clearance_limit": 0.0,
		}
	)
	if result.is_empty():
		push_error("  FAIL: GPU compute init failure must return blocked output, not empty success")
		return false
	var contract: Dictionary = result.get("gpu_runtime_profile_contract", {})
	if str(contract.get("reason", "")) == "missing_rendering_device" and not bool(result.get("contract_blocked", false)):
		push_error("  FAIL: missing_rendering_device must report contract_blocked=true")
		generator.dispose()
		return false
	if bool(result.get("contract_blocked", false)):
		if bool(result.get("cpu_fallback", true)):
			push_error("  FAIL: GPU compute blocked output must not report CPU fallback")
			generator.dispose()
			return false
		if not bool(result.get("gpu_first", false)):
			push_error("  FAIL: GPU compute blocked output must keep gpu_first=true")
			generator.dispose()
			return false
		if str(result.get("readback_source", "")) != "none":
			push_error("  FAIL: GPU compute blocked output must not expose a success readback source")
			generator.dispose()
			return false
		if bool(result.get("ok", true)):
			push_error("  FAIL: GPU compute blocked output must report ok=false")
			generator.dispose()
			return false
		if bool(contract.get("ok", true)) or str(contract.get("reason", "")) != "missing_rendering_device":
			push_error("  FAIL: no-RD GPU compute block should preserve missing_rendering_device: %s" % str(contract))
			generator.dispose()
			return false
		print("  OK: no RenderingDevice blocks GPU compute without CPU fallback")
		generator.dispose()
		return true
	if int(result.get("tile_count", 0)) <= 0:
		push_error("  FAIL: GPU compute output should expose tile metadata when RD exists")
		generator.dispose()
		return false
	generator.dispose()
	print("  OK: GPU compute path returned explicit output")
	return true


func _test_instantiate_placements() -> bool:
	print("[VoxelMultiAsset] test_instantiate_placements...")
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.5, 0.75, 0.5)

	var world_results: Array = [
		{
			"position": Vector3(1.0, 0.5, 2.0),
			"rotation_degrees": Vector3(0.0, 45.0, 0.0),
			"scale": Vector3.ONE,
			"asset_index": 0,
		},
		{
			"position": Vector3(5.0, 0.5, 3.0),
			"rotation_degrees": Vector3(0.0, 90.0, 0.0),
			"scale": Vector3.ONE,
			"asset_index": 0,
		},
	]

	var config := {
		"color": Color(0.25, 0.50, 0.20, 0.8),
		"complexity": 0.8,
		"object_type": "object",
	}

	var nodes := VPG.instantiate_placements(world_results, "autoobject", mesh, config)

	if nodes.size() != 2:
		push_error("  FAIL: expected 2 AutoObject nodes, got %d" % nodes.size())
		_free_nodes(nodes)
		return false

	var node0: AutoObject = nodes[0]
	if not node0 is AutoObject:
		push_error("  FAIL: instantiated node is not AutoObject")
		_free_nodes(nodes)
		return false

	if node0.position.distance_to(Vector3(1.0, 0.5, 2.0)) > 0.01:
		push_error("  FAIL: AutoObject position mismatch: %s" % str(node0.position))
		_free_nodes(nodes)
		return false

	if node0.mesh == null:
		push_error("  FAIL: AutoObject has no mesh")
		_free_nodes(nodes)
		return false

	if node0.get_record_object_type() != "object":
		push_error("  FAIL: AutoObject type should come from config, got %s" % node0.get_record_object_type())
		_free_nodes(nodes)
		return false

	if not node0.get_record_object_subtype().is_empty():
		push_error("  FAIL: generic AutoObject should not get a hardcoded subtype")
		_free_nodes(nodes)
		return false

	print("  OK: autoobjects=%d type=%s pos=%s" % [
		nodes.size(), node0.get_class(), str(node0.position)])
	_free_nodes(nodes)
	return true


func _test_instantiate_placement_voxel_write_spec_commit() -> bool:
	print("[VoxelMultiAsset] test_instantiate_placement_voxel_write_spec_commit...")
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.5, 0.75, 0.5)
	var committer := SVC.new(32, 32.0, false)

	var world_result := {
		"position": Vector3(0.0, 0.5, 0.0),
		"rotation_degrees": Vector3(0.0, 30.0, 0.0),
		"scale": Vector3.ONE,
		"asset_index": 2,
		"rotation_index": 2,
		"voxel_origin": Vector3i(8, 1, 8),
		"score": 7.5,
	}

	var node := VPG.instantiate_placement(world_result, "autoobject", mesh, {
		"name": "VoxelAutoObjectRecord_0",
		"record_id": "voxel_autoobject_record_0",
		"create_voxel_write_spec": true,
		"scene_voxel_committer": committer,
		"capture_size": 32.0,
		"volume_xz_resolution": 32,
		"channel": 0,
		"radius": 1.0,
	})

	if node == null:
		push_error("  FAIL: node was not created")
		return false
	if not node.has_meta(AutoObject.INSTANCE_STAMP_WRITE_SPEC_META_KEY):
		push_error("  FAIL: node has no canonical instance_stamp_write_spec metadata")
		node.free()
		return false
	if not node.has_meta(AutoObject.VOXEL_WRITE_SPEC_META_KEY):
		push_error("  FAIL: node has no legacy voxel_write_spec metadata")
		node.free()
		return false

	var record: Dictionary = node.get_instance_stamp_write_spec()
	if str(record.get("id", "")) != "voxel_autoobject_record_0":
		push_error("  FAIL: wrong record id: %s" % str(record.get("id", "")))
		node.free()
		return false
	if record.get("base_pixel", Vector2i(-1, -1)) != Vector2i(16, 16):
		push_error("  FAIL: base_pixel mismatch: %s" % str(record.get("base_pixel", Vector2i(-1, -1))))
		node.free()
		return false
	var committed_record := committer.get_instance_stamp_write_spec("voxel_autoobject_record_0")
	if str(committed_record.get("id", "")) != "voxel_autoobject_record_0":
		push_error("  FAIL: committer could not read back canonical ISWS record")
		node.free()
		return false

	committer.build_voxel_volume(16, [
		{"channel": 0, "color": Color(0.2, 0.8, 0.2, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 0.3, "subdivisions": 1},
		{"channel": 1, "color": Color(0.8, 0.6, 0.2, 0.8), "complexity": 0.8, "y_min": 0.3, "y_max": 2.0, "subdivisions": 1},
	])
	var scene_voxels := committer.get_scene_voxels()
	if scene_voxels.is_empty():
		push_error("  FAIL: expected committed SceneVoxel entries")
		node.free()
		return false
	var has_committed_payload := false
	for scene_voxel in scene_voxels.values():
		if scene_voxel is Dictionary and float((scene_voxel as Dictionary).get("complexity", 0.0)) > 0.01:
			has_committed_payload = true
			break
	if not has_committed_payload:
		push_error("  FAIL: expected committed SceneVoxel payload entries")
		node.free()
		return false

	print("  OK: record=%s scene_voxels=%d commit_tick=%d" % [
		str(record.id),
		scene_voxels.size(),
		committer.get_committed_tick(),
	])
	node.free()
	return true


func _test_multi_asset_collision_avoidance() -> bool:
	print("[VoxelMultiAsset] test_multi_asset_collision_avoidance...")
	if not _has_rendering_device():
		print("  SKIP: no RenderingDevice available for GPU-only collision avoidance placement")
		return true
	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var voxel_size := Vector3(0.5, 0.5, 0.5)

	var generator := VPG.new()
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var large_cylinder := {
		"collision": [
			{"shape": "cylinder", "radius": 1.5, "y_min": 0.0, "y_max": 3.0, "collision_strength": 1.0}
		],
		"result_capacity": 2,
		"min_distance_voxels": 4.0,
	}
	var small_cylinder := {
		"collision": [
			{"shape": "cylinder", "radius": 0.25, "y_min": 0.0, "y_max": 1.0, "collision_strength": 1.0}
		],
		"result_capacity": 4,
		"min_distance_voxels": 2.0,
	}

	var common_settings := {
		"top_k": 4,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
	}

	var result := generator.run_multi_asset(
		scene, collision, [large_cylinder, small_cylinder],
		grid_size, voxel_size, Vector3.ZERO, common_settings)

	var asset_results: Array = result.get("asset_results", [])
	var large_results: Array = asset_results[0].get("world_results", [])
	var small_results: Array = asset_results[1].get("world_results", [])

	for large_wr in large_results:
		var large_pos: Vector3 = large_wr.position
		for small_wr in small_results:
			var small_pos: Vector3 = small_wr.position
			var dist := large_pos.distance_to(small_pos)
			if dist < 0.5:
				push_error("  FAIL: small object placed on top of large at distance %.2f" % dist)
				return false

	print("  OK: large=%d small=%d (no collision overlap)" % [
		large_results.size(), small_results.size()])
	return true


func _float_arrays_match(a: PackedFloat32Array, b: PackedFloat32Array, epsilon: float = 0.0001) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if absf(a[i] - b[i]) > epsilon:
			return false
	return true


func _free_nodes(nodes: Array) -> void:
	for node in nodes:
		if node is Node and is_instance_valid(node):
			node.free()
