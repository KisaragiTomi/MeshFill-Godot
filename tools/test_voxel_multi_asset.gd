extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")
const SVC := preload("res://scripts/scene_voxel_committer.gd")
const Runtime := preload("res://scripts/gpu_autoobject_runtime.gd")
const ProfileContainer := preload("res://scripts/auto_voxel_runtime_profile_container.gd")


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
	ok = ok and _test_gpu_runtime_profile_contract_or_skip()
	ok = ok and _test_score_dispatch_consumes_gpu_runtime_profile_buffers_or_skip()
	ok = ok and _test_vpg_pipeline_rids_ready_or_skip()
	ok = ok and _test_post_dispatch_contract_failure_blocks_multi_asset_or_skip()
	ok = ok and _test_accepted_placement_writeback_to_gpu_runtime_or_blocked()
	ok = ok and _test_accepted_placement_writeback_failure_reason_or_skip()
	ok = ok and _test_run_multi_asset_writes_instance_stamp_specs_to_committer_or_skip()
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
	if bool(writeback.get("resident_gpu_allocator_writeback", true)):
		push_error("  FAIL: accepted placement writeback must not claim resident GPU allocator writeback")
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
	if int(writeback.get("spawned_count", -1)) != 1 or int(writeback.get("failed_count", 0)) <= 0:
		push_error("  FAIL: writeback should spawn exactly one object and count later failures")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	var source_writeback: Dictionary = result.get("instance_stamp_writeback", {})
	if source_writeback.is_empty():
		push_error("  FAIL: partial runtime writeback should still report source writeback for successful spawns")
		generator.dispose()
		container.dispose()
		runtime.dispose()
		return false
	if int(source_writeback.get("applied_count", 0)) > int(writeback.get("spawned_count", 0)):
		push_error("  FAIL: source writeback must not apply placements that failed GPU runtime spawn")
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
	var tree_mesh := VegetationScatter.create_tree_mesh()
	var bush_mesh := VegetationScatter.create_bush_mesh()

	var tree_results: Array = [
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

	var bush_results: Array = [
		{
			"position": Vector3(3.0, 0.3, 1.0),
			"rotation_degrees": Vector3(0.0, 15.0, 0.0),
			"scale": Vector3.ONE * 0.8,
			"asset_index": 1,
		},
	]

	var tree_config := {
		"color": Color(0.25, 0.50, 0.20, 0.8),
		"complexity": 0.8,
		"visual_layer": VegetationScatter.TREE_VISUAL_LAYER,
	}

	var tree_nodes := VPG.instantiate_placements(tree_results, "canopy_tree", tree_mesh, tree_config)
	var bush_nodes := VPG.instantiate_placements(bush_results, "bush", bush_mesh)

	if tree_nodes.size() != 2:
		push_error("  FAIL: expected 2 tree nodes, got %d" % tree_nodes.size())
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	if bush_nodes.size() != 1:
		push_error("  FAIL: expected 1 bush node, got %d" % bush_nodes.size())
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	var t0: AutoObject = tree_nodes[0]
	if not t0 is AutoObject:
		push_error("  FAIL: tree node is not AutoObject")
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	if t0.position.distance_to(Vector3(1.0, 0.5, 2.0)) > 0.01:
		push_error("  FAIL: tree position mismatch: %s" % str(t0.position))
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	if t0.mesh == null:
		push_error("  FAIL: tree has no mesh")
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	var b0: AutoObject = bush_nodes[0]
	if not b0 is AutoObject:
		push_error("  FAIL: bush node is not AutoObject")
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	var bush_subtype := b0.get_record_object_subtype()
	if bush_subtype != "bush":
		push_error("  FAIL: bush subtype is '%s'" % bush_subtype)
		_free_nodes(tree_nodes)
		_free_nodes(bush_nodes)
		return false

	print("  OK: trees=%d bushes=%d type=%s subtype=%s pos=%s" % [
		tree_nodes.size(), bush_nodes.size(),
		t0.get_class(), bush_subtype, str(t0.position)])
	_free_nodes(tree_nodes)
	_free_nodes(bush_nodes)
	return true


func _test_instantiate_placement_voxel_write_spec_commit() -> bool:
	print("[VoxelMultiAsset] test_instantiate_placement_voxel_write_spec_commit...")
	var mesh := VegetationScatter.create_bush_mesh()
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

	var node := VPG.instantiate_placement(world_result, "bush", mesh, {
		"name": "VoxelBushRecord_0",
		"record_id": "voxel_bush_record_0",
		"create_voxel_write_spec": true,
		"scene_voxel_committer": committer,
		"capture_size": 32.0,
		"volume_xz_resolution": 32,
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
	if str(record.get("id", "")) != "voxel_bush_record_0":
		push_error("  FAIL: wrong record id: %s" % str(record.get("id", "")))
		node.free()
		return false
	if record.get("base_pixel", Vector2i(-1, -1)) != Vector2i(16, 16):
		push_error("  FAIL: base_pixel mismatch: %s" % str(record.get("base_pixel", Vector2i(-1, -1))))
		node.free()
		return false
	var committed_record := committer.get_instance_stamp_write_spec("voxel_bush_record_0")
	if str(committed_record.get("id", "")) != "voxel_bush_record_0":
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


func _free_nodes(nodes: Array) -> void:
	for node in nodes:
		if node is Node and is_instance_valid(node):
			node.free()
