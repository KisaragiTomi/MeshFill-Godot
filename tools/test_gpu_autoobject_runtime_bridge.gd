extends SceneTree

const SVC := preload("res://scripts/scene_voxel_committer.gd")
const Runtime := preload("res://scripts/gpu_autoobject_runtime.gd")
const RuntimeProfileContainerScript := preload("res://scripts/auto_voxel_runtime_profile_container.gd")
const SPA := preload("res://scripts/scene_placement_actor.gd")
const PrefilterScript := preload("res://scripts/autoobject_probe_prefilter_gpu.gd")
const VPGScript := preload("res://scripts/voxel_placement_generator.gd")
const AutoVoxelDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")


class FailingCommitter:
	extends RefCounted

	func apply_gpu_autoobject_dirty_delta(_delta: Dictionary) -> Dictionary:
		return {
			"ok": false,
			"reason": "forced_commit_failure",
			"cpu_fallback": false,
		}

	func get_dirty_scene_voxel_tiles() -> Dictionary:
		return {}


func _init() -> void:
	var ok := true
	ok = ok and _test_gpu_disabled_runtime_has_no_cpu_fallback()
	ok = ok and _test_setup_for_scene_voxel_committer_attaches_before_buffers()
	ok = ok and _test_setup_for_scene_voxel_committer_blocks_after_buffer_allocation()
	ok = ok and _test_scene_placement_actor_sets_up_runtime_for_committer()
	ok = ok and _test_scene_placement_actor_flushes_resident_dirty_delta_after_placement()
	ok = ok and _test_scene_placement_actor_scopes_accepted_record_shader_opt_in()
	ok = ok and _test_spawn_update_flush_to_scene_voxel_tiles()
	ok = ok and _test_resident_opt_in_flush_uses_borrowed_dirty_delta_buffer()
	ok = ok and _test_update_profile_and_flags_flush_dirty_delta()
	ok = ok and _test_profile_hot_update_reverse_maps_refs()
	ok = ok and _test_dirty_profile_container_handoff_to_runtime_delta()
	ok = ok and _test_dirty_delta_readback_failure_reports_gpu_failure()
	ok = ok and _test_committer_apply_failure_clears_readback_source()
	ok = ok and _test_dirty_count_write_failure_rejects_dirty_append()
	ok = ok and _test_profile_dirty_capacity_failure_clears_readback_source()
	ok = ok and _test_capacity_and_debug_readback()
	ok = ok and _test_accepted_placement_object_id_reservation_contract()
	ok = ok and _test_kill_clears_scene_voxel_ref()
	ok = ok and _test_bulk_spawn_command_flush_uses_batched_buffer_updates()
	ok = ok and _test_bulk_spawn_opt_in_accepted_record_shader_writeback_matches_cpu()
	ok = ok and _test_enqueue_commands_and_bounds_helper()
	ok = ok and _test_failed_command_flush_clears_readback_source()

	if ok:
		print("[GPUAutoObjectRuntimeBridge] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[GPUAutoObjectRuntimeBridge] SOME TESTS FAILED")
		quit(1)


func _test_spawn_update_flush_to_scene_voxel_tiles() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_spawn_update_flush_to_scene_voxel_tiles...")
	var runtime := Runtime.new(4)
	if not _runtime_ready_or_skip(runtime):
		return true
	var committer := _make_committer()
	var object_id: int = runtime.spawn(
		7,
		2,
		Vector3i(0, 0, 0),
		Vector3i(4, 1, 4),
		Transform3D.IDENTITY,
		{"collision": true}
	)
	if object_id != 0:
		push_error("  FAIL: expected first object id 0, got %d" % object_id)
		return false
	if not runtime.update_transform(
		object_id,
		Transform3D(Basis(), Vector3(12.0, 0.0, 12.0)),
		Vector3i(12, 0, 12),
		Vector3i(17, 1, 17),
		{"collision": true}
	):
		push_error("  FAIL: expected update_transform to accept live object")
		return false

	var result := runtime.flush_to_scene_voxel_committer(committer)
	if not bool(result.get("ok", false)):
		push_error("  FAIL: runtime flush should accept SceneVoxelCommitter bridge")
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: runtime flush should explicitly reject CPU fallback")
		return false
	var deltas: Array = result.get("dirty_deltas", [])
	if deltas.size() != 2:
		push_error("  FAIL: RenderingDevice-mismatch flush should CPU-read back spawn and update dirty deltas, got %d" % deltas.size())
		return false
	if int(result.get("dirty_delta_count", -1)) != 2 or int(result.get("commit_result_count", -1)) != 2:
		push_error("  FAIL: RenderingDevice-mismatch flush should report dirty and CPU projection result counts")
		return false
	if str(result.get("dirty_delta_apply_api", "")) != "apply_gpu_autoobject_dirty_deltas":
		push_error("  FAIL: RenderingDevice-mismatch flush should use committer batch API after readback")
		return false
	if str(result.get("dirty_delta_bridge_mode", "")) != "gpu_scene_voxel_tile_object_ref_update_with_cpu_debug_projection":
		push_error("  FAIL: RenderingDevice-mismatch flush should stage CPU-readback deltas into GPU object-ref update")
		return false
	if not bool(result.get("resident_gpu_dirty_delta_update_pass", false)):
		push_error("  FAIL: runtime flush should claim resident GPU dirty-delta update pass")
		return false
	if str(result.get("resident_gpu_dirty_delta_update_pass_owner", "")) != "SceneVoxelCommitter" \
	   or str(result.get("resident_gpu_dirty_delta_update_pass_shader", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME \
	   or int(result.get("resident_gpu_dirty_delta_update_pass_dispatch_count", 0)) != 1:
		push_error("  FAIL: resident GPU dirty-delta update-pass diagnostics should name the committer shader")
		return false
	if str(result.get("readback_source", "")) != "gpu_dirty_delta_buffer" \
	   or str(result.get("failed_readback_source", "")) != "none":
		push_error("  FAIL: RenderingDevice-mismatch flush should identify GPU dirty-delta readback source")
		return false
	if int(result.get("pending_dirty_delta_count", -1)) != 0 or runtime.get_pending_dirty_delta_count() != 0:
		push_error("  FAIL: flush should clear pending dirty count")
		return false
	if not _assert_object_ref_range_policy(result, "runtime flush"):
		return false
	var update_delta: Dictionary = deltas[1]
	if update_delta.get("old_voxel_min", Vector3i.ZERO) != Vector3i(0, 0, 0):
		push_error("  FAIL: update delta missing previous voxel min")
		return false
	if update_delta.get("new_voxel_max", Vector3i.ZERO) != Vector3i(17, 1, 17):
		push_error("  FAIL: update delta missing current voxel max")
		return false
	if not _assert_transient_dirty_tile_result(
		result,
		["0:0:0", "3:0:3", "4:0:3", "3:0:4", "4:0:4"],
		"scene_voxel_tile_dirty_flags",
		"spawn/update staged runtime flush"
	):
		return false
	var summary := runtime.get_object_summary(object_id)
	if not bool(summary.get("readback_snapshot", false)):
		push_error("  FAIL: selected object summary should be a GPU readback snapshot")
		return false
	if not bool(summary.get("alive", false)):
		push_error("  FAIL: selected object summary should report alive object")
		return false
	if int(summary.get("profile_id", -1)) != 7 or int(summary.get("object_type", -1)) != 2:
		push_error("  FAIL: selected object summary should preserve profile/type")
		return false

	runtime.dispose()
	print("  OK: spawn/update readback bridge stages deltas into resident SceneVoxelTile object-ref pass")
	return true


func _test_resident_opt_in_flush_uses_borrowed_dirty_delta_buffer() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_resident_opt_in_flush_uses_borrowed_dirty_delta_buffer...")
	var committer := _make_committer()
	var shared_rd: RenderingDevice = committer.get_rendering_device()
	if shared_rd == null:
		print("  SKIP: committer RenderingDevice not ready")
		return true

	var runtime := Runtime.new(4, false)
	var setup_result := runtime.setup_for_scene_voxel_committer(committer, 4, true)
	if not bool(setup_result.get("ok", false)):
		push_error("  FAIL: runtime should attach committer RenderingDevice for explicit opt-in: %s" % str(setup_result))
		return false
	if runtime.get_rendering_device() != shared_rd:
		push_error("  FAIL: runtime should use committer RenderingDevice for explicit opt-in")
		return false
	if not _runtime_ready_or_skip(runtime):
		return true
	if not committer.ensure_scene_voxel_tile_buffers_uploaded(true):
		var skipped_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
		if str(skipped_summary.get("gpu_upload_status", "")) == "skip":
			print("  SKIP: SceneVoxelTile buffers not ready for resident opt-in (%s)" % str(skipped_summary.get("skip_reason", "")))
			runtime.dispose()
			return true
		push_error("  FAIL: SceneVoxelTile buffers should upload before resident opt-in: %s" % str(skipped_summary))
		return false

	var object_id := runtime.spawn(
		7,
		2,
		Vector3i(0, 0, 0),
		Vector3i(4, 1, 4),
		Transform3D.IDENTITY,
		{"object_refs": true}
	)
	if object_id != 0:
		push_error("  FAIL: expected first resident opt-in object id 0, got %d" % object_id)
		return false
	if runtime.get_pending_dirty_delta_count() != 1:
		push_error("  FAIL: resident opt-in should have one pending dirty delta before flush")
		return false

	# P0: resident GPU update pass 现在默认启用，不再需要显式 opt-in flag。
	var result := runtime.flush_to_scene_voxel_committer(committer, {})
	if not bool(result.get("ok", false)):
		push_error("  FAIL: resident opt-in flush should dispatch: %s" % str(result))
		return false
	if str(result.get("dirty_delta_apply_api", "")) != "try_apply_gpu_autoobject_object_ref_update_pass_from_buffer":
		push_error("  FAIL: resident opt-in should use borrowed-buffer committer API")
		return false
	if str(result.get("dirty_delta_bridge_mode", "")) != "explicit_scene_voxel_tile_object_ref_update_pass":
		push_error("  FAIL: resident opt-in should report explicit GPU pass bridge")
		return false
	if not bool(result.get("resident_gpu_dirty_delta_update_pass", false)):
		push_error("  FAIL: resident opt-in should report resident GPU dirty-delta pass")
		return false
	if str(result.get("resident_gpu_dirty_delta_update_pass_owner", "")) != "SceneVoxelCommitter" \
	   or str(result.get("resident_gpu_dirty_delta_update_pass_shader", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME \
	   or int(result.get("resident_gpu_dirty_delta_update_pass_dispatch_count", 0)) != 1:
		push_error("  FAIL: resident opt-in pass diagnostics mismatch: %s" % str(result))
		return false
	var update_result: Dictionary = result.get("object_ref_update_result", {})
	if str(update_result.get("dirty_delta_source", "")) != "gpu_autoobject_runtime_autoobject_dirty_delta":
		push_error("  FAIL: resident opt-in should identify borrowed runtime dirty-delta buffer")
		return false
	if not bool(result.get("object_ref_update_stats_available", false)) \
	   or not bool(result.get("object_ref_update_gpu_dispatched", false)) \
	   or int(result.get("object_ref_inserted_slot_count", 0)) != 1:
		push_error("  FAIL: resident opt-in should expose dispatch stats: %s" % str(result))
		return false
	if not _assert_transient_dirty_tile_result(
		result,
		["0:0:0"],
		"gpu_autoobject_runtime_dirty_flags",
		"resident opt-in borrowed runtime buffer"
	):
		return false
	if str(result.get("readback_source", "")) != "borrowed_gpu_dirty_delta_buffer" \
	   or str(result.get("failed_readback_source", "")) != "none":
		push_error("  FAIL: resident opt-in should not report dirty-delta CPU readback")
		return false
	if int(result.get("pending_dirty_delta_count", -1)) != 0 or runtime.get_pending_dirty_delta_count() != 0:
		push_error("  FAIL: resident opt-in should clear pending dirty count after dispatch")
		return false
	runtime.dispose()
	print("  OK: resident opt-in borrowed runtime dirty-delta buffer into SceneVoxelCommitter pass")
	return true


func _test_setup_for_scene_voxel_committer_attaches_before_buffers() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_setup_for_scene_voxel_committer_attaches_before_buffers...")
	var committer := _make_committer()
	var shared_rd: RenderingDevice = committer.get_rendering_device()
	if shared_rd == null:
		print("  SKIP: committer RenderingDevice not ready")
		return true

	var runtime := Runtime.new(4, false)
	var setup_result := runtime.setup_for_scene_voxel_committer(committer, 4, true)
	if not bool(setup_result.get("ok", false)):
		push_error("  FAIL: setup helper should attach committer RenderingDevice before buffers: %s" % str(setup_result))
		return false
	if runtime.get_rendering_device() != shared_rd:
		push_error("  FAIL: setup helper should keep runtime on the committer RenderingDevice")
		return false
	if not bool(setup_result.get("same_rendering_device", false)):
		push_error("  FAIL: setup helper should report same RenderingDevice")
		return false
	if bool(setup_result.get("buffers_allocated_before_setup", true)):
		push_error("  FAIL: setup helper should report no pre-existing runtime buffers")
		return false
	if not bool(setup_result.get("buffers_allocated_after_setup", false)):
		push_error("  FAIL: setup helper should allocate runtime buffers after attaching")
		return false
	if not runtime.is_ready():
		push_error("  FAIL: setup helper should leave runtime ready")
		return false
	var buffer_summary := runtime.get_gpu_buffer_summary()
	if not bool(buffer_summary.get("dirty_delta_buffer", false)):
		push_error("  FAIL: setup helper should create dirty-delta buffer")
		return false
	runtime.dispose()
	print("  OK: setup helper attaches committer RenderingDevice before runtime buffers")
	return true


func _test_setup_for_scene_voxel_committer_blocks_after_buffer_allocation() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_setup_for_scene_voxel_committer_blocks_after_buffer_allocation...")
	var runtime := Runtime.new(4)
	if not _runtime_ready_or_skip(runtime):
		return true
	var runtime_rd: RenderingDevice = runtime.get_rendering_device()
	var committer := _make_committer()
	var committer_rd: RenderingDevice = committer.get_rendering_device()
	if committer_rd == null or runtime_rd == null:
		print("  SKIP: RenderingDevice not ready")
		runtime.dispose()
		return true
	if committer_rd == runtime_rd:
		print("  SKIP: runtime and committer unexpectedly share RenderingDevice")
		runtime.dispose()
		return true

	var setup_result := runtime.setup_for_scene_voxel_committer(committer, 4, true)
	if bool(setup_result.get("ok", true)):
		push_error("  FAIL: setup helper must not migrate already allocated runtime buffers: %s" % str(setup_result))
		return false
	if str(setup_result.get("reason", "")) != "runtime_buffers_already_allocated_on_different_rendering_device":
		push_error("  FAIL: setup helper should report allocated-buffer RD mismatch: %s" % str(setup_result))
		return false
	if runtime.get_rendering_device() != runtime_rd:
		push_error("  FAIL: blocked setup must keep the original runtime RenderingDevice")
		return false
	if not runtime.is_ready():
		push_error("  FAIL: blocked setup should not tear down existing runtime buffers")
		return false
	runtime.dispose()
	print("  OK: setup helper blocks cross-RD setup after runtime buffers exist")
	return true


func _test_scene_placement_actor_sets_up_runtime_for_committer() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_scene_placement_actor_sets_up_runtime_for_committer...")
	var committer := _make_committer()
	var shared_rd: RenderingDevice = committer.get_rendering_device()
	if shared_rd == null:
		print("  SKIP: committer RenderingDevice not ready")
		return true

	var runtime := Runtime.new(4, false)
	var actor := SPA.new()
	if not actor.initialize(true, false, committer, runtime):
		print("  SKIP: ScenePlacementActor RenderingDevice not ready")
		runtime.dispose()
		return true

	var setup_result: Dictionary = actor.get_merged_gpu_buffer_summary().get("gpu_runtime_scene_voxel_setup", {})
	if not bool(setup_result.get("ok", false)):
		push_error("  FAIL: SPA should set up runtime for committer: %s" % str(setup_result))
		actor.dispose(true)
		return false
	if runtime.get_rendering_device() != shared_rd:
		push_error("  FAIL: SPA setup should attach runtime to committer RenderingDevice")
		actor.dispose(true)
		return false
	if not bool(setup_result.get("same_rendering_device", false)) \
			or not bool(setup_result.get("resident_gpu_dirty_delta_update_pass_opt_in_ready", false)):
		push_error("  FAIL: SPA setup should report resident opt-in readiness: %s" % str(setup_result))
		actor.dispose(true)
		return false
	if str(setup_result.get("source", "")) != "ScenePlacementActor" \
			or str(setup_result.get("runtime_setup_api", "")) != "GPUAutoObjectRuntime.setup_for_scene_voxel_committer":
		push_error("  FAIL: SPA setup diagnostics should name source/API: %s" % str(setup_result))
		actor.dispose(true)
		return false

	actor.dispose(true)
	print("  OK: SPA initializes GPUAutoObjectRuntime on SceneVoxelCommitter RenderingDevice")
	return true


func _test_scene_placement_actor_flushes_resident_dirty_delta_after_placement() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_scene_placement_actor_flushes_resident_dirty_delta_after_placement...")
	var committer := _make_committer()
	if committer.get_rendering_device() == null:
		print("  SKIP: committer RenderingDevice not ready")
		return true

	var runtime := Runtime.new(4, false)
	var actor := SPA.new()
	if not actor.initialize(true, false, committer, runtime):
		print("  SKIP: ScenePlacementActor RenderingDevice not ready")
		runtime.dispose()
		return true

	var descriptor := AutoVoxelDescriptorScript.new()
	descriptor.asset_id = "spa_runtime_dirty_delta_flush"
	var profile_id := actor.register_asset(descriptor)
	if profile_id < 0:
		push_error("  FAIL: SPA should register descriptor before placement flush test")
		actor.dispose(true)
		return false

	actor._prefilter = SPADirtyDeltaFakePrefilter.new()
	actor._placer = SPADirtyDeltaFakePlacer.new()
	var grid_size := Vector3i(32, 4, 32)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var result := actor.run_placement_pipeline({
		"grid_size": grid_size,
		"voxel_size": Vector3.ONE,
		"grid_origin": Vector3.ZERO,
		"complexity_field": scene,
		"collision_field": collision,
	}, [], 1, {})
	if not bool(result.get("ok", false)):
		push_error("  FAIL: SPA pipeline should complete fake placement: %s" % str(result))
		actor.dispose(true)
		return false

	var flush_result: Dictionary = result.get("runtime_dirty_delta_flush_result", {})
	if not bool(flush_result.get("ok", false)):
		push_error("  FAIL: SPA should flush runtime dirty deltas after placement: %s" % str(flush_result))
		actor.dispose(true)
		return false
	if not bool(flush_result.get("resident_gpu_dirty_delta_update_pass", false)):
		push_error("  FAIL: SPA flush should claim resident pass only after dispatch: %s" % str(flush_result))
		actor.dispose(true)
		return false
	if str(flush_result.get("dirty_delta_apply_api", "")) != "try_apply_gpu_autoobject_object_ref_update_pass_from_buffer" \
			or str(flush_result.get("dirty_delta_bridge_mode", "")) != "explicit_scene_voxel_tile_object_ref_update_pass":
		push_error("  FAIL: SPA flush should use borrowed-buffer resident bridge: %s" % str(flush_result))
		actor.dispose(true)
		return false
	if str(flush_result.get("resident_gpu_dirty_delta_update_pass_owner", "")) != "SceneVoxelCommitter" \
			or str(flush_result.get("resident_gpu_dirty_delta_update_pass_shader", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME \
			or int(flush_result.get("resident_gpu_dirty_delta_update_pass_dispatch_count", 0)) <= 0:
		push_error("  FAIL: SPA flush resident diagnostics mismatch: %s" % str(flush_result))
		actor.dispose(true)
		return false
	if str(flush_result.get("source", "")) != "ScenePlacementActor" \
			or str(flush_result.get("runtime_flush_api", "")) != "GPUAutoObjectRuntime.flush_to_scene_voxel_committer":
		push_error("  FAIL: SPA flush diagnostics should name source/API: %s" % str(flush_result))
		actor.dispose(true)
		return false
	if bool(flush_result.get("blocked", true)) \
			or str(flush_result.get("resident_gpu_dirty_delta_update_pass_blocked_reason", "")) != "none":
		push_error("  FAIL: SPA resident success should clear blocked diagnostics: %s" % str(flush_result))
		actor.dispose(true)
		return false
	if int(flush_result.get("pending_dirty_delta_count", -1)) != 0 or runtime.get_pending_dirty_delta_count() != 0:
		push_error("  FAIL: SPA resident flush should clear runtime dirty count")
		actor.dispose(true)
		return false

	actor.dispose(true)
	print("  OK: SPA pipeline flushes placement runtime deltas through resident SceneVoxelTile pass")
	return true


func _test_scene_placement_actor_scopes_accepted_record_shader_opt_in() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_scene_placement_actor_scopes_accepted_record_shader_opt_in...")
	var committer := _make_committer()
	if committer.get_rendering_device() == null:
		print("  SKIP: committer RenderingDevice not ready")
		return true

	var runtime := Runtime.new(4, false)
	var actor := SPA.new()
	if not actor.initialize(true, false, committer, runtime):
		print("  SKIP: ScenePlacementActor RenderingDevice not ready")
		runtime.dispose()
		return true

	var descriptor := AutoVoxelDescriptorScript.new()
	descriptor.asset_id = "spa_accepted_record_writeback"
	var profile_id := actor.register_asset(descriptor)
	if profile_id < 0:
		push_error("  FAIL: SPA should register descriptor before accepted-record writeback test")
		actor.dispose(true)
		return false
	if runtime.get_use_resident_accepted_placement_writeback():
		push_error("  FAIL: runtime accepted-record writeback opt-in should default false before SPA placement")
		actor.dispose(true)
		return false

	actor._prefilter = SPADirtyDeltaFakePrefilter.new()
	actor._placer = SPAAcceptedRecordFakePlacer.new()
	var grid_size := Vector3i(32, 4, 32)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var result := actor.run_placement_pipeline({
		"grid_size": grid_size,
		"voxel_size": Vector3.ONE,
		"grid_origin": Vector3.ZERO,
		"complexity_field": scene,
		"collision_field": collision,
	}, [], 1, {})
	if not bool(result.get("ok", false)):
		push_error("  FAIL: SPA pipeline should complete accepted-record fake placement: %s" % str(result))
		actor.dispose(true)
		return false
	if runtime.get_use_resident_accepted_placement_writeback():
		push_error("  FAIL: SPA should restore runtime accepted-record writeback opt-in after placement")
		actor.dispose(true)
		return false

	var placement_result: Dictionary = result.get("placement_result", {})
	if not bool(placement_result.get("use_compact_state_chain_received", false)) \
			or str(placement_result.get("cpu_state_chain_mode_received", "")) != "compact_stamp_deltas":
		push_error("  FAIL: SPA should pass compact stamp-delta chain settings to VPG when resident writeback is ready: %s" % str(placement_result))
		actor.dispose(true)
		return false
	var compact_summary: Dictionary = result.get("compact_state_chain_summary", {})
	if not bool(compact_summary.get("ok", false)) \
			or str(compact_summary.get("mode", "")) != "compact_stamp_deltas" \
			or not bool(compact_summary.get("avoids_full_field_readback", false)) \
			or bool(compact_summary.get("full_field_readback_required", true)) \
			or bool(compact_summary.get("cpu_fallback", true)):
		push_error("  FAIL: SPA compact summary should report stamp deltas with no full-field readback and no CPU fallback: %s" % str(compact_summary))
		actor.dispose(true)
		return false
	var writeback: Dictionary = placement_result.get("gpu_autoobject_runtime_writeback", {})
	if not bool(writeback.get("ok", false)):
		push_error("  FAIL: fake placer no-option command flush should succeed: %s" % str(writeback))
		actor.dispose(true)
		return false
	if str(writeback.get("runtime_command_flush_mode", "")) != "resident_accepted_placement_record_shader_writeback":
		push_error("  FAIL: SPA opt-in should make no-option flush use accepted-record shader: %s" % str(writeback))
		actor.dispose(true)
		return false
	if not bool(writeback.get("accepted_placement_record_shader_consumed", false)):
		push_error("  FAIL: accepted-record shader should be consumed during SPA-scoped no-option flush: %s" % str(writeback))
		actor.dispose(true)
		return false
	if int(writeback.get("accepted_placement_record_schema_version", -1)) != Runtime.ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION \
			or int(writeback.get("accepted_placement_record_stride_bytes", -1)) != Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES:
		push_error("  FAIL: accepted-record schema/stride diagnostics mismatch: %s" % str(writeback))
		actor.dispose(true)
		return false
	if bool(writeback.get("resident_gpu_allocator_writeback", true)) \
			or str(writeback.get("resident_gpu_allocator_writeback_mode", "")) != "resident_object_buffer_writeback":
		push_error("  FAIL: accepted-record path should report object-buffer writeback without allocator ownership: %s" % str(writeback))
		actor.dispose(true)
		return false
	if int(writeback.get("accepted_placement_record_shader_dispatch_count", 0)) != 1:
		push_error("  FAIL: accepted-record shader should dispatch once for staged fake placements: %s" % str(writeback))
		actor.dispose(true)
		return false
	var stats: Dictionary = writeback.get("accepted_placement_record_shader_stats", {})
	if int(stats.get("applied", -1)) != 2 \
			or int(stats.get("invalid_object_id", -1)) != 0 \
			or int(stats.get("dirty_overflow", -1)) != 0 \
			or int(stats.get("already_alive", -1)) != 0 \
			or int(stats.get("skipped", -1)) != 0:
		push_error("  FAIL: accepted-record shader stats mismatch for SPA fake placer: %s" % str(writeback))
		actor.dispose(true)
		return false
	if str(writeback.get("resident_gpu_allocator_writeback_blocked_reason", "")) != "none":
		push_error("  FAIL: accepted-record shader success should clear blocked reason: %s" % str(writeback))
		actor.dispose(true)
		return false

	var summary: Dictionary = result.get("accepted_placement_writeback_summary", {})
	if summary.is_empty():
		push_error("  FAIL: SPA result should expose accepted placement writeback summary")
		actor.dispose(true)
		return false
	if str(summary.get("source", "")) != "placement_result.gpu_autoobject_runtime_writeback" \
			or not bool(summary.get("production_opt_in_enabled", false)):
		push_error("  FAIL: SPA writeback summary should identify production opt-in source: %s" % str(summary))
		actor.dispose(true)
		return false
	if str(summary.get("runtime_command_flush_mode", "")) != "resident_accepted_placement_record_shader_writeback" \
			or not bool(summary.get("accepted_placement_record_shader_consumed", false)):
		push_error("  FAIL: SPA writeback summary should surface shader consumption: %s" % str(summary))
		actor.dispose(true)
		return false
	if int(summary.get("accepted_placement_record_schema_version", -1)) != Runtime.ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION \
			or int(summary.get("accepted_placement_record_stride_bytes", -1)) != Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES:
		push_error("  FAIL: SPA writeback summary schema/stride mismatch: %s" % str(summary))
		actor.dispose(true)
		return false
	if bool(summary.get("resident_gpu_allocator_writeback", true)) \
			or str(summary.get("resident_gpu_allocator_writeback_mode", "")) != "resident_object_buffer_writeback" \
			or str(summary.get("resident_gpu_allocator_writeback_blocked_reason", "")) != "none":
		push_error("  FAIL: SPA writeback summary should report object-buffer mode without allocator ownership: %s" % str(summary))
		actor.dispose(true)
		return false
	if int(summary.get("accepted_placement_record_shader_dispatch_count", 0)) != 1:
		push_error("  FAIL: SPA writeback summary should surface dispatch count: %s" % str(summary))
		actor.dispose(true)
		return false
	var summary_stats: Dictionary = summary.get("accepted_placement_record_shader_stats", {})
	if int(summary_stats.get("applied", -1)) != 2 \
			or int(summary_stats.get("invalid_object_id", -1)) != 0 \
			or int(summary_stats.get("dirty_overflow", -1)) != 0 \
			or int(summary_stats.get("already_alive", -1)) != 0 \
			or int(summary_stats.get("skipped", -1)) != 0:
		push_error("  FAIL: SPA writeback summary should surface shader stats: %s" % str(summary))
		actor.dispose(true)
		return false

	var runtime_flush: Dictionary = result.get("runtime_dirty_delta_flush_result", {})
	if not bool(runtime_flush.get("ok", false)):
		push_error("  FAIL: SPA should flush shader-written dirty deltas to SceneVoxel committer: %s" % str(runtime_flush))
		actor.dispose(true)
		return false
	if int(runtime_flush.get("pending_dirty_delta_count", -1)) != 0 or runtime.get_pending_dirty_delta_count() != 0:
		push_error("  FAIL: SPA should clear shader-written dirty deltas after committer flush")
		actor.dispose(true)
		return false

	actor.dispose(true)
	print("  OK: SPA scopes no-option queue flush into resident accepted-record shader writeback and restores runtime flag")
	return true


func _assert_transient_dirty_tile_result(
	result: Dictionary,
	expected_tile_ids: Array,
	expected_schema: String,
	label: String
) -> bool:
	if not bool(result.get("transient_dirty_scene_voxel_tile_gpu_emitted", false)):
		push_error("  FAIL: %s should report GPU-emitted transient dirty SceneVoxelTiles" % label)
		return false
	if int(result.get("transient_dirty_scene_voxel_tile_count", -1)) != expected_tile_ids.size():
		push_error("  FAIL: %s transient dirty tile count mismatch: %s" % [label, str(result)])
		return false
	if int(result.get("transient_dirty_scene_voxel_tile_worklist_count", -1)) != expected_tile_ids.size():
		push_error("  FAIL: %s transient dirty worklist count mismatch: %s" % [label, str(result)])
		return false
	if int(result.get("transient_dirty_scene_voxel_tile_worklist_overflow_count", -1)) != 0:
		push_error("  FAIL: %s transient dirty worklist should not overflow: %s" % [label, str(result)])
		return false
	if str(result.get("transient_dirty_scene_voxel_tile_flag_schema", "")) != expected_schema:
		push_error("  FAIL: %s transient dirty flag schema mismatch: %s" % [label, str(result)])
		return false
	if str(result.get("transient_dirty_scene_voxel_tile_cpu_metadata_bridge", "")) != "none":
		push_error("  FAIL: %s should not claim a CPU metadata bridge for transient dirty tiles" % label)
		return false

	var tile_ids: Array = result.get("transient_dirty_scene_voxel_tile_ids", [])
	var flags_by_id: Dictionary = result.get("transient_dirty_scene_voxel_tile_flags", {})
	for raw_id in expected_tile_ids:
		var tile_id := str(raw_id)
		if not tile_ids.has(tile_id):
			push_error("  FAIL: %s missing transient dirty SceneVoxelTile %s in %s" % [label, tile_id, str(tile_ids)])
			return false
		var flags: Dictionary = flags_by_id.get(tile_id, {})
		if not bool(flags.get("auto", false)) or not bool(flags.get("object_refs", false)):
			push_error("  FAIL: %s transient dirty flags missing auto/object_refs for %s: %s" % [label, tile_id, str(flags)])
			return false
	return true


func _assert_object_ref_range_policy(result: Dictionary, label: String) -> bool:
	if str(result.get("object_ref_range_policy", "")) != "fixed_per_tile_object_ref_update_pass":
		push_error("  FAIL: %s should report fixed per-tile object-ref update policy" % label)
		return false
	if str(result.get("object_ref_range_owner", "")) != "SceneVoxelCommitter":
		push_error("  FAIL: %s should report SceneVoxelCommitter as object-ref range owner" % label)
		return false
	if str(result.get("object_ref_range_shader", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME:
		push_error("  FAIL: %s should report the object-ref update shader" % label)
		return false
	if str(result.get("object_ref_range_shader_path", "")) != SVC.SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH:
		push_error("  FAIL: %s should report the object-ref update shader path" % label)
		return false
	if not bool(result.get("object_ref_range_shader_ready", false)):
		push_error("  FAIL: %s should report object-ref shader readiness" % label)
		return false
	var refs_per_tile := int(result.get("refs_per_tile", -1))
	var tile_count := int(result.get("object_ref_tile_count", -1))
	var capacity := int(result.get("object_ref_capacity", -1))
	if refs_per_tile != 8 or tile_count <= 0 or capacity != tile_count * refs_per_tile:
		push_error("  FAIL: %s object-ref capacity contract mismatch: %s" % [label, str(result)])
		return false
	if bool(result.get("object_ref_rebuild_required", true)):
		push_error("  FAIL: %s should not require rebuild without overflow/mismatch" % label)
		return false
	if int(result.get("object_ref_overflow_count", -1)) != 0 or int(result.get("overflow_tile_count", -1)) != 0:
		push_error("  FAIL: %s should report zero object-ref overflow diagnostics" % label)
		return false
	if bool(result.get("object_ref_update_gpu_dispatched", false)) and int(result.get("object_ref_update_dispatch_count", -1)) <= 0:
		push_error("  FAIL: %s should report a positive dispatch count when object-ref shader dispatch is true" % label)
		return false
	if not bool(result.get("object_ref_update_gpu_dispatched", false)):
		if int(result.get("object_ref_non_numeric_count", -1)) != 0 \
		   or int(result.get("object_ref_duplicate_count", -1)) != 0 \
		   or int(result.get("object_ref_touched_count", -1)) != 0:
			push_error("  FAIL: %s should report zero object-ref shader stats before dispatch" % label)
			return false
	if str(result.get("gpu_autoobject_ref_key_schema", "")) != "u32_numeric_ref_key_v1":
		push_error("  FAIL: %s should report explicit numeric GPU AutoObject ref-key schema" % label)
		return false
	if not str(result.get("gpu_autoobject_ref_key_schema_note", "")).contains("u32 ref_key"):
		push_error("  FAIL: %s should include numeric u32 ref-key schema note" % label)
		return false
	return true


func _test_update_profile_and_flags_flush_dirty_delta() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_update_profile_and_flags_flush_dirty_delta...")
	var runtime := Runtime.new(4)
	if not _runtime_ready_or_skip(runtime):
		return true
	var committer := _make_committer()
	var object_id: int = runtime.spawn(
		7,
		2,
		Vector3i(0, 0, 0),
		Vector3i(4, 1, 4),
		Transform3D.IDENTITY,
		{"collision": true},
		Runtime.OBJECT_FLAG_VISIBLE
	)
	if object_id != 0:
		push_error("  FAIL: expected first object id 0 for profile/flags test")
		return false
	runtime.flush_to_scene_voxel_committer(committer)
	committer.clear_sv_dirty()

	if not runtime.update_profile(
		object_id,
		11,
		{"collision": true, "scoring": true},
		Vector3i(12, 0, 12),
		Vector3i(17, 1, 17)
	):
		push_error("  FAIL: update_profile should accept live GPU object")
		return false
	var profile_result := runtime.flush_to_scene_voxel_committer(committer)
	var profile_deltas: Array = profile_result.get("dirty_deltas", [])
	if profile_deltas.size() != 1:
		push_error("  FAIL: update_profile should flush exactly one dirty delta")
		return false
	var profile_delta: Dictionary = profile_deltas[0]
	if bool(profile_delta.get("cpu_fallback", true)):
		push_error("  FAIL: profile dirty delta should report cpu_fallback=false")
		return false
	if int(profile_delta.get("profile_id", -1)) != 11:
		push_error("  FAIL: profile dirty delta should carry the new profile id")
		return false
	if profile_delta.get("old_voxel_min", Vector3i.ZERO) != Vector3i(0, 0, 0):
		push_error("  FAIL: update_profile delta missing old voxel bounds")
		return false
	if profile_delta.get("new_voxel_max", Vector3i.ZERO) != Vector3i(17, 1, 17):
		push_error("  FAIL: update_profile delta missing new voxel bounds")
		return false
	var profile_dirty_tiles := committer.get_dirty_scene_voxel_tiles()
	for expected_id in ["0:0:0", "3:0:3", "4:0:4"]:
		if not profile_dirty_tiles.has(expected_id):
			push_error("  FAIL: update_profile missing dirty SceneVoxelTile %s" % expected_id)
			return false
	var profile_summary := runtime.get_object_summary(object_id)
	if int(profile_summary.get("profile_id", -1)) != 11:
		push_error("  FAIL: GPU readback summary should expose updated profile_id")
		return false
	if bool(profile_summary.get("cpu_fallback", true)):
		push_error("  FAIL: GPU readback summary should report cpu_fallback=false")
		return false

	committer.clear_sv_dirty()
	var next_flags := Runtime.OBJECT_FLAG_VISIBLE | Runtime.OBJECT_FLAG_SELECTED | Runtime.OBJECT_FLAG_LOCKED
	if not runtime.update_flags(object_id, next_flags, {"object_refs": true, "auto": true}):
		push_error("  FAIL: update_flags should accept live GPU object")
		return false
	var flags_summary := runtime.get_object_summary(object_id)
	if int(flags_summary.get("object_flags", -1)) != next_flags or int(flags_summary.get("flags", -1)) != next_flags:
		push_error("  FAIL: update_flags should update GPU object flags readback")
		return false
	var buffer_summary: Dictionary = runtime.get_gpu_buffer_summary()
	if bool(buffer_summary.get("cpu_fallback", true)):
		push_error("  FAIL: GPU buffer summary should report cpu_fallback=false")
		return false
	if not bool(buffer_summary.get("flags_buffer", false)):
		push_error("  FAIL: GPU buffer summary should expose flags buffer")
		return false
	var flags_result := runtime.flush_to_scene_voxel_committer(committer)
	var flags_deltas: Array = flags_result.get("dirty_deltas", [])
	if flags_deltas.size() != 1:
		push_error("  FAIL: update_flags should flush exactly one dirty delta")
		return false
	var flags_delta: Dictionary = flags_deltas[0]
	if flags_delta.get("old_voxel_min", Vector3i.ZERO) != Vector3i(12, 0, 12) or flags_delta.get("new_voxel_max", Vector3i.ZERO) != Vector3i(17, 1, 17):
		push_error("  FAIL: update_flags dirty delta should cover current bounds")
		return false
	if committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("  FAIL: update_flags should dirty SceneVoxelTile object refs")
		return false

	runtime.dispose()
	print("  OK: update_profile/update_flags stay GPU-resident and flush dirty deltas")
	return true


func _test_profile_hot_update_reverse_maps_refs() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_profile_hot_update_reverse_maps_refs...")
	var runtime := Runtime.new(4)
	if not _runtime_ready_or_skip(runtime):
		return true
	var committer := _make_committer()

	var a: int = runtime.spawn(7, 2, Vector3i(0, 0, 0), Vector3i(4, 1, 4))
	var b: int = runtime.spawn(7, 2, Vector3i(12, 0, 12), Vector3i(17, 1, 17))
	var c: int = runtime.spawn(8, 2, Vector3i(24, 0, 24), Vector3i(28, 1, 28))
	if a != 0 or b != 1 or c != 2:
		push_error("  FAIL: expected three fixed-capacity object ids [0, 1, 2]")
		return false
	runtime.flush_to_scene_voxel_committer(committer)
	committer.clear_sv_dirty()

	var refs := runtime.get_object_ids_for_profile([7])
	if not bool(refs.get("ok", false)):
		push_error("  FAIL: profile reverse lookup should read GPU object buffers")
		return false
	if bool(refs.get("cpu_fallback", true)):
		push_error("  FAIL: profile reverse lookup must report cpu_fallback=false")
		return false
	var ref_ids: Array = refs.get("object_ids", [])
	if ref_ids.size() != 2 or not ref_ids.has(0) or not ref_ids.has(1) or ref_ids.has(2):
		push_error("  FAIL: profile reverse lookup returned wrong object ids: %s" % str(ref_ids))
		return false

	var mark_result := runtime.mark_profile_objects_dirty([7], {"scoring": true})
	if not bool(mark_result.get("ok", false)):
		push_error("  FAIL: profile hot update should append dirty deltas: %s" % str(mark_result))
		return false
	if bool(mark_result.get("cpu_fallback", true)):
		push_error("  FAIL: profile hot update dirtying must report cpu_fallback=false")
		return false
	if int(mark_result.get("matched_object_count", -1)) != 2 or int(mark_result.get("appended_dirty_delta_count", -1)) != 2:
		push_error("  FAIL: profile hot update should dirty exactly the two referencing objects")
		return false
	var flags: Dictionary = mark_result.get("dirty_flags", {})
	for key in ["auto", "object_refs", "scene", "collision", "scoring"]:
		if not bool(flags.get(key, false)):
			push_error("  FAIL: profile hot update dirty flags missing %s: %s" % [key, str(flags)])
			return false

	var flush_result := runtime.flush_to_scene_voxel_committer(committer)
	var deltas: Array = flush_result.get("dirty_deltas", [])
	if deltas.size() != 2:
		push_error("  FAIL: profile hot update should flush two dirty deltas")
		return false
	for delta in deltas:
		var typed_delta: Dictionary = delta
		if int(typed_delta.get("profile_id", -1)) != 7:
			push_error("  FAIL: profile hot update delta should only include profile 7")
			return false
		if typed_delta.get("old_voxel_min", Vector3i.ZERO) != typed_delta.get("new_voxel_min", Vector3i.ONE):
			push_error("  FAIL: profile hot update delta should use current bounds as old/new")
			return false
	if int(flush_result.get("dirty_scene_voxel_tile_count", 0)) <= 0:
		push_error("  FAIL: profile hot update should dirty SceneVoxelTiles through committer handoff")
		return false
	var dirty_tiles := committer.get_dirty_scene_voxel_tiles()
	for expected_id in ["0:0:0", "3:0:3", "4:0:4"]:
		if not dirty_tiles.has(expected_id):
			push_error("  FAIL: profile hot update missing dirty SceneVoxelTile %s" % expected_id)
			return false
	for unrelated_id in ["6:0:6"]:
		if dirty_tiles.has(unrelated_id):
			push_error("  FAIL: profile hot update dirtied unrelated profile SceneVoxelTile %s" % unrelated_id)
			return false

	runtime.dispose()
	print("  OK: profile hot update reverse-mapped GPU refs into SceneVoxelTile dirty deltas")
	return true


func _test_dirty_profile_container_handoff_to_runtime_delta() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_dirty_profile_container_handoff_to_runtime_delta...")
	var container = RuntimeProfileContainerScript.new()
	var profile_id: int = container.register_normalized_profile({
		"color": Color(0.2, 0.3, 0.4, 1.0),
		"complexity": 0.75,
		"semantic_probes": [],
		"collision": [],
		"pivot_variants": [],
	})
	if profile_id <= 0:
		push_error("  FAIL: expected runtime profile container to register a profile")
		return false
	container.mark_profile_dirty(profile_id)

	var disabled_runtime := Runtime.new(1, false)
	var disabled_result := disabled_runtime.mark_profile_objects_dirty(container, {"scoring": true})
	if bool(disabled_result.get("ok", true)):
		push_error("  FAIL: not-ready runtime must reject container dirty handoff")
		return false
	if str(disabled_result.get("reason", "")) != "runtime_not_ready":
		push_error("  FAIL: not-ready dirty handoff should report runtime_not_ready")
		return false
	if bool(disabled_result.get("cpu_fallback", true)):
		push_error("  FAIL: not-ready dirty handoff must report cpu_fallback=false")
		return false
	if int(disabled_result.get("pending_dirty_delta_count", -1)) != 0:
		push_error("  FAIL: not-ready dirty handoff must not append dirty deltas")
		return false
	var disabled_profile_ids: Array = disabled_result.get("profile_ids", [])
	if not disabled_profile_ids.has(profile_id):
		push_error("  FAIL: not-ready dirty handoff should preserve dirty_profile_ids")
		return false
	disabled_runtime.dispose()

	var runtime := Runtime.new(4)
	if not _runtime_ready_or_skip(runtime):
		container.dispose()
		return true
	var object_id: int = runtime.spawn(profile_id, 2, Vector3i(0, 0, 0), Vector3i(4, 1, 4))
	if object_id != 0:
		push_error("  FAIL: expected dirty profile handoff object id 0")
		return false
	runtime.flush_dirty_deltas()

	var mark_result := runtime.mark_profile_objects_dirty(container, {"feedback": true})
	if not bool(mark_result.get("ok", false)):
		push_error("  FAIL: runtime should accept profile container dirty handoff: %s" % str(mark_result))
		return false
	if bool(mark_result.get("cpu_fallback", true)):
		push_error("  FAIL: container dirty handoff must report cpu_fallback=false")
		return false
	if int(mark_result.get("matched_object_count", -1)) != 1 or int(mark_result.get("appended_dirty_delta_count", -1)) != 1:
		push_error("  FAIL: container dirty handoff should append one dirty delta")
		return false
	var deltas := runtime.flush_dirty_deltas()
	if deltas.size() != 1:
		push_error("  FAIL: container dirty handoff should flush one dirty delta")
		return false
	var delta: Dictionary = deltas[0]
	if int(delta.get("profile_id", -1)) != profile_id:
		push_error("  FAIL: container dirty handoff delta should keep profile_id")
		return false
	var flags: Dictionary = delta.get("dirty_flags", {})
	for key in ["auto", "object_refs", "scene", "collision", "routing", "scoring", "feedback"]:
		if not bool(flags.get(key, false)):
			push_error("  FAIL: container dirty handoff delta missing dirty flag %s" % key)
			return false
	if delta.get("old_voxel_min", Vector3i.ONE) != delta.get("new_voxel_min", Vector3i.ZERO):
		push_error("  FAIL: container dirty handoff should use current bounds as old/new")
		return false

	runtime.dispose()
	container.dispose()
	print("  OK: dirty_profile_ids hand off from profile container to GPU dirty delta")
	return true


func _test_dirty_delta_readback_failure_reports_gpu_failure() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_dirty_delta_readback_failure_reports_gpu_failure...")
	var runtime := Runtime.new(2)
	if not _runtime_ready_or_skip(runtime):
		return true
	var committer := _make_committer()
	var object_id: int = runtime.spawn(5, 2, Vector3i(0, 0, 0), Vector3i(2, 1, 2))
	if object_id != 0:
		push_error("  FAIL: expected object id 0 before dirty-delta readback failure")
		return false
	if runtime.get_pending_dirty_delta_count() != 1:
		push_error("  FAIL: expected one pending dirty delta before forced readback failure")
		return false

	var original_dirty_delta_buffer: RID = runtime._dirty_delta_buffer
	runtime._dirty_delta_buffer = RID()
	var flush_result := runtime.flush_to_scene_voxel_committer(committer)
	runtime._dirty_delta_buffer = original_dirty_delta_buffer
	if bool(flush_result.get("ok", true)):
		push_error("  FAIL: dirty-delta readback failure must not report success")
		return false
	if str(flush_result.get("reason", "")) != "dirty_delta_readback_failed":
		push_error("  FAIL: dirty-delta readback failure should report dirty_delta_readback_failed: %s" % str(flush_result))
		return false
	if bool(flush_result.get("cpu_fallback", true)):
		push_error("  FAIL: dirty-delta readback failure must report cpu_fallback=false")
		return false
	if str(flush_result.get("readback_source", "")) != "none":
		push_error("  FAIL: dirty-delta readback failure must not expose a success readback source")
		return false
	if str(flush_result.get("failed_readback_source", "")) != "gpu_dirty_delta_buffer":
		push_error("  FAIL: dirty-delta readback failure should preserve diagnostic failed_readback_source")
		return false
	if int(flush_result.get("commit_result_count", -1)) != 0 or int(flush_result.get("dirty_delta_count", -1)) != 0:
		push_error("  FAIL: dirty-delta readback failure must not emit commits or drained deltas")
		return false
	if int(flush_result.get("pending_dirty_delta_count", -1)) != 1 or runtime.get_pending_dirty_delta_count() != 1:
		push_error("  FAIL: dirty-delta readback failure must keep pending dirty state")
		return false
	if not committer.get_dirty_scene_voxel_tiles().is_empty():
		push_error("  FAIL: dirty-delta readback failure must not dirty SceneVoxelTiles")
		return false

	runtime.dispose()
	print("  OK: dirty-delta readback failure reports GPU-only failure and keeps pending state")
	return true


func _test_committer_apply_failure_clears_readback_source() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_committer_apply_failure_clears_readback_source...")
	var runtime := Runtime.new(2)
	if not _runtime_ready_or_skip(runtime):
		return true
	var object_id: int = runtime.spawn(5, 2, Vector3i(0, 0, 0), Vector3i(2, 1, 2))
	if object_id != 0:
		push_error("  FAIL: expected object id 0 before forced commit failure")
		return false

	var flush_result := runtime.flush_to_scene_voxel_committer(FailingCommitter.new())
	if bool(flush_result.get("ok", true)):
		push_error("  FAIL: forced committer failure must not report success")
		return false
	if str(flush_result.get("reason", "")) != "forced_commit_failure":
		push_error("  FAIL: forced committer failure reason should be preserved: %s" % str(flush_result))
		return false
	if bool(flush_result.get("cpu_fallback", true)):
		push_error("  FAIL: forced committer failure must report cpu_fallback=false")
		return false
	if str(flush_result.get("readback_source", "")) != "none":
		push_error("  FAIL: forced committer failure must not expose a success readback source")
		return false
	if str(flush_result.get("failed_readback_source", "")) != "gpu_dirty_delta_buffer":
		push_error("  FAIL: forced committer failure should preserve diagnostic failed_readback_source")
		return false

	runtime.dispose()
	print("  OK: forced committer failure clears success-style readback source")
	return true


func _test_dirty_count_write_failure_rejects_dirty_append() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_dirty_count_write_failure_rejects_dirty_append...")
	var runtime := Runtime.new(2)
	if not _runtime_ready_or_skip(runtime):
		return true
	var object_id: int = runtime.spawn(5, 2, Vector3i(0, 0, 0), Vector3i(2, 1, 2))
	if object_id != 0:
		push_error("  FAIL: expected object id 0 before dirty-count write failure")
		return false
	if runtime.flush_dirty_deltas().size() != 1:
		push_error("  FAIL: expected spawn dirty delta to flush before write-failure check")
		return false

	var original_dirty_count_buffer: RID = runtime._dirty_count_buffer
	runtime._dirty_count_buffer = RID()
	var mark_result := runtime.mark_profile_objects_dirty([5], {"scoring": true})
	runtime._dirty_count_buffer = original_dirty_count_buffer
	if bool(mark_result.get("ok", true)):
		push_error("  FAIL: dirty-count write failure must reject dirty append")
		return false
	if str(mark_result.get("reason", "")) != "append_dirty_delta_failed":
		push_error("  FAIL: dirty-count write failure should surface append_dirty_delta_failed: %s" % str(mark_result))
		return false
	if bool(mark_result.get("cpu_fallback", true)):
		push_error("  FAIL: dirty-count write failure must report cpu_fallback=false")
		return false
	if str(mark_result.get("readback_source", "")) != "none":
		push_error("  FAIL: dirty-count write failure must not keep gpu_storage_buffers readback source")
		return false
	if int(mark_result.get("appended_dirty_delta_count", -1)) != 0 or runtime.get_pending_dirty_delta_count() != 0:
		push_error("  FAIL: failed dirty-count write must not advance pending dirty count")
		return false

	runtime.dispose()
	print("  OK: dirty-count write failure rejects append without CPU fallback")
	return true


func _test_profile_dirty_capacity_failure_clears_readback_source() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_profile_dirty_capacity_failure_clears_readback_source...")
	var runtime := Runtime.new(1)
	if not _runtime_ready_or_skip(runtime):
		return true
	var object_id: int = runtime.spawn(5, 2, Vector3i.ZERO, Vector3i.ONE)
	if object_id != 0:
		push_error("  FAIL: expected object id 0 before capacity failure")
		return false
	runtime.flush_dirty_deltas()
	runtime._dirty_delta_count = runtime.dirty_delta_capacity
	var mark_result := runtime.mark_profile_objects_dirty([5], {"scoring": true})
	if bool(mark_result.get("ok", true)):
		push_error("  FAIL: profile dirty capacity failure must reject dirty append")
		return false
	if str(mark_result.get("reason", "")) != "dirty_delta_capacity_full":
		push_error("  FAIL: profile dirty capacity failure should report dirty_delta_capacity_full")
		return false
	if bool(mark_result.get("cpu_fallback", true)):
		push_error("  FAIL: profile dirty capacity failure must report cpu_fallback=false")
		return false
	if str(mark_result.get("readback_source", "")) != "none":
		push_error("  FAIL: profile dirty capacity failure must not keep gpu_storage_buffers readback source")
		return false
	runtime.dispose()
	print("  OK: profile dirty capacity failure clears success-style readback source")
	return true


func _test_capacity_and_debug_readback() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_capacity_and_debug_readback...")
	var runtime := Runtime.new(2)
	if not _runtime_ready_or_skip(runtime):
		return true
	var a: int = runtime.spawn(1, 10, Vector3i(0, 0, 0), Vector3i(1, 1, 1))
	var b: int = runtime.spawn(2, 20, Vector3i(2, 0, 2), Vector3i(3, 1, 3))
	var c: int = runtime.spawn(3, 30, Vector3i(4, 0, 4), Vector3i(5, 1, 5))
	if a != 0 or b != 1 or c != -1:
		push_error("  FAIL: fixed capacity allocation returned unexpected ids [%d, %d, %d]" % [a, b, c])
		return false
	var debug := runtime.get_selected_debug_summary([a, b, 99])
	if not bool(debug.get("readback_snapshot", false)):
		push_error("  FAIL: debug summary should be read back from GPU buffers")
		return false
	if int(debug.get("live_count", -1)) != 2 or int(debug.get("free_count", -1)) != 0:
		push_error("  FAIL: debug counters should reflect fixed capacity pool")
		return false
	var objects: Array = debug.get("objects", [])
	if objects.size() != 2:
		push_error("  FAIL: selected debug readback should return the two valid ids")
		return false
	if int((objects[1] as Dictionary).get("object_type", -1)) != 20:
		push_error("  FAIL: selected debug readback should keep object_type")
		return false

	runtime.dispose()
	print("  OK: fixed capacity and selected debug readback are stable")
	return true


func _test_accepted_placement_object_id_reservation_contract() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_accepted_placement_object_id_reservation_contract...")
	var runtime := Runtime.new(4)
	if not _runtime_ready_or_skip(runtime):
		return true

	var reservation := runtime.reserve_accepted_placement_object_ids(2)
	var reserved_ids: Array = reservation.get("object_ids", [])
	if not bool(reservation.get("ok", false)) or reserved_ids.size() != 2 or int(reserved_ids[0]) != 0 or int(reserved_ids[1]) != 1:
		push_error("  FAIL: reservation should return deterministic record-order ids [0, 1]: %s" % str(reservation))
		runtime.dispose()
		return false
	if bool(runtime.get_object_summary(0).get("alive", true)) or bool(runtime.get_object_summary(1).get("alive", true)):
		push_error("  FAIL: reserved ids must remain reserved-but-not-alive")
		runtime.dispose()
		return false
	var debug := runtime.get_selected_debug_summary([0, 1])
	if int(debug.get("live_count", -1)) != 0 \
			or int(debug.get("reserved_object_id_count", -1)) != 2 \
			or int(debug.get("free_count", -1)) != 2:
		push_error("  FAIL: reservation should remove ids from free pool without making them live: %s" % str(debug))
		runtime.dispose()
		return false

	var ordinary_spawn_id := runtime.spawn(7, 3, Vector3i(2, 0, 2), Vector3i(3, 1, 3))
	if ordinary_spawn_id != 2:
		push_error("  FAIL: ordinary spawn must not reuse reserved ids before rollback, got %d" % ordinary_spawn_id)
		runtime.dispose()
		return false

	var premature_finalize := runtime.finalize_accepted_placement_object_id_reservation(reservation, {
		"ok": true,
		"accepted_placement_record_shader_consumed": false,
	})
	if bool(premature_finalize.get("ok", true)) \
			or str(premature_finalize.get("reason", "")) != "accepted_record_shader_success_required":
		push_error("  FAIL: finalize should require accepted-record shader success before commit: %s" % str(premature_finalize))
		runtime.dispose()
		return false

	var rollback := runtime.rollback_accepted_placement_object_ids(reservation)
	if not bool(rollback.get("ok", false)) \
			or int(rollback.get("released_count", -1)) != 2 \
			or int(rollback.get("reserved_object_id_count", -1)) != 0:
		push_error("  FAIL: rollback should release both uncommitted reserved ids: %s" % str(rollback))
		runtime.dispose()
		return false
	var double_rollback := runtime.rollback_accepted_placement_object_ids(reserved_ids)
	if bool(double_rollback.get("ok", true)) \
			or int(double_rollback.get("released_count", -1)) != 0 \
			or int(double_rollback.get("skipped_count", -1)) != 2:
		push_error("  FAIL: double rollback should skip without double-freeing ids: %s" % str(double_rollback))
		runtime.dispose()
		return false

	var reused_a := runtime.spawn(8, 4, Vector3i(4, 0, 4), Vector3i(5, 1, 5))
	var reused_b := runtime.spawn(9, 5, Vector3i(6, 0, 6), Vector3i(7, 1, 7))
	var final_id := runtime.spawn(10, 6, Vector3i(8, 0, 8), Vector3i(9, 1, 9))
	var overflow_id := runtime.spawn(11, 7, Vector3i(10, 0, 10), Vector3i(11, 1, 11))
	if reused_a != 1 or reused_b != 0 or final_id != 3 or overflow_id != -1:
		push_error("  FAIL: rollback should restore each id exactly once, got [%d, %d, %d, %d]" % [reused_a, reused_b, final_id, overflow_id])
		runtime.dispose()
		return false

	runtime.dispose()
	print("  OK: accepted-placement object-id reservation orders, rolls back, and blocks spawn reuse")
	return true


func _test_kill_clears_scene_voxel_ref() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_kill_clears_scene_voxel_ref...")
	var runtime := Runtime.new(2)
	if not _runtime_ready_or_skip(runtime):
		return true
	var committer := _make_committer()
	var object_id: int = runtime.spawn(4, 5, Vector3i(8, 0, 8), Vector3i(12, 1, 12))
	runtime.flush_to_scene_voxel_committer(committer)
	var sv_with_ref := committer.get_sv()
	if int(sv_with_ref.get("scene_voxel_tile_gpu_autoobject_ref_count", 0)) != 1:
		push_error("  FAIL: expected live ref after spawn")
		return false

	if not runtime.kill(object_id, {"collision": true}):
		push_error("  FAIL: kill should accept live object")
		return false
	var result := runtime.flush_to_scene_voxel_committer(committer)
	var deltas: Array = result.get("dirty_deltas", [])
	if deltas.size() != 1 or not bool((deltas[0] as Dictionary).get("removed", false)):
		push_error("  FAIL: kill should flush one removed dirty delta")
		return false
	var dirty_tiles := committer.get_dirty_scene_voxel_tiles()
	if dirty_tiles.is_empty():
		push_error("  FAIL: kill should dirty previous SceneVoxelTile bounds")
		return false
	var sv_after_kill := committer.get_sv()
	if int(sv_after_kill.get("scene_voxel_tile_gpu_autoobject_ref_count", -1)) != 0:
		push_error("  FAIL: dead object should be erased from GPU AutoObject tile refs")
		return false
	var object_ids: Array = sv_after_kill.get("scene_voxel_tile_object_ids_debug", [])
	if object_ids.has(str(object_id)):
		push_error("  FAIL: dead object should not remain in compact object debug refs")
		return false
	var summary := runtime.get_object_summary(object_id)
	if bool(summary.get("alive", true)):
		push_error("  FAIL: killed object summary should report dead state")
		return false

	runtime.dispose()
	print("  OK: kill delta dirties old bounds and clears live refs")
	return true


func _test_bulk_spawn_command_flush_uses_batched_buffer_updates() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_bulk_spawn_command_flush_uses_batched_buffer_updates...")
	var runtime := Runtime.new(4)
	if not _runtime_ready_or_skip(runtime):
		return true
	for i in range(3):
		var enqueue_result := runtime.enqueue({
			"command": "SpawnObject",
			"profile_id": 20 + i,
			"object_type": 7 + i,
			"voxel_min": Vector3i(i * 3, 0, i * 3),
			"voxel_max": Vector3i(i * 3 + 2, 1, i * 3 + 2),
			"dirty_flags": {"scene": true},
			"flags": {"visible": true},
		})
		if not bool(enqueue_result.get("ok", false)) or int(enqueue_result.get("object_id", -1)) != i:
			push_error("  FAIL: expected staged bulk spawn id %d, got %s" % [i, str(enqueue_result)])
			runtime.dispose()
			return false
	if runtime.get_pending_dirty_delta_count() != 0:
		push_error("  FAIL: staged bulk spawns must not append dirty deltas before flush")
		runtime.dispose()
		return false
	var flush_result := runtime.flush_command_queue()
	if not bool(flush_result.get("ok", false)):
		push_error("  FAIL: bulk spawn flush should succeed: %s" % str(flush_result))
		runtime.dispose()
		return false
	if str(flush_result.get("runtime_command_flush_mode", "")) != "cpu_bulk_spawn_buffer_update":
		push_error("  FAIL: all-spawn queue should use cpu_bulk_spawn_buffer_update: %s" % str(flush_result))
		runtime.dispose()
		return false
	if bool(flush_result.get("resident_gpu_allocator_writeback", true)) \
			or str(flush_result.get("resident_gpu_allocator_writeback_mode", "")) != "none":
		push_error("  FAIL: bulk spawn flush must not claim resident GPU allocator writeback")
		runtime.dispose()
		return false
	if int(flush_result.get("accepted_placement_record_schema_version", -1)) != Runtime.ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION \
			or int(flush_result.get("accepted_placement_record_stride_bytes", -1)) != Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES:
		push_error("  FAIL: bulk spawn flush should report accepted-placement record schema/stride: %s" % str(flush_result))
		runtime.dispose()
		return false
	if int(flush_result.get("accepted_placement_record_count", -1)) != 3 \
			or int(flush_result.get("accepted_placement_record_byte_count", -1)) != 3 * Runtime.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES:
		push_error("  FAIL: bulk spawn flush should pack one accepted-placement debug record per staged spawn")
		runtime.dispose()
		return false
	if not bool(flush_result.get("accepted_placement_record_debug_packed", false)) \
			or bool(flush_result.get("accepted_placement_record_shader_consumed", true)):
		push_error("  FAIL: accepted-placement records should be debug-packed but not shader-consumed yet: %s" % str(flush_result))
		runtime.dispose()
		return false
	if str(flush_result.get("resident_gpu_allocator_writeback_blocked_reason", "")) != "no_resident_allocator_shader_dispatch":
		push_error("  FAIL: bulk spawn flush should explain why resident allocator writeback remains blocked")
		runtime.dispose()
		return false
	var contract := Runtime.get_accepted_placement_record_contract()
	if int(contract.get("schema_version", -1)) != 1 \
			or int(contract.get("stride_bytes", -1)) != 128 \
			or str(contract.get("layout", "")) != "std430":
		push_error("  FAIL: accepted-placement record contract summary mismatch: %s" % str(contract))
		runtime.dispose()
		return false
	var fields: Array = contract.get("fields", [])
	if fields.size() != 11:
		push_error("  FAIL: accepted-placement record contract should expose 11 fields")
		runtime.dispose()
		return false
	if int(flush_result.get("command_count", -1)) != 3 \
			or int(flush_result.get("applied_count", -1)) != 3 \
			or int(flush_result.get("failed_count", -1)) != 0:
		push_error("  FAIL: bulk spawn flush should apply exactly three commands")
		runtime.dispose()
		return false
	if runtime.get_pending_command_count() != 0 or runtime.get_pending_dirty_delta_count() != 3:
		push_error("  FAIL: bulk spawn flush should clear commands and append three dirty deltas")
		runtime.dispose()
		return false
	var summary := runtime.get_selected_debug_summary([0, 1, 2])
	if int(summary.get("live_count", -1)) != 3:
		push_error("  FAIL: bulk spawned objects should be live in GPU storage buffers")
		runtime.dispose()
		return false
	for i in range(3):
		var object_summary := runtime.get_object_summary(i)
		if int(object_summary.get("profile_id", -1)) != 20 + i \
				or int(object_summary.get("object_type", -1)) != 7 + i \
				or int(object_summary.get("object_flags", 0)) != Runtime.OBJECT_FLAG_VISIBLE:
			push_error("  FAIL: bulk spawned object %d readback mismatch: %s" % [i, str(object_summary)])
			runtime.dispose()
			return false
	var deltas := runtime.flush_dirty_deltas()
	if deltas.size() != 3:
		push_error("  FAIL: bulk spawn flush should write three dirty deltas")
		runtime.dispose()
		return false
	for i in range(3):
		var delta: Dictionary = deltas[i]
		if int(delta.get("object_id", -1)) != i or not bool(delta.get("alive", false)) or bool(delta.get("removed", true)):
			push_error("  FAIL: bulk spawn dirty delta %d mismatch: %s" % [i, str(delta)])
			runtime.dispose()
			return false

	runtime.dispose()
	print("  OK: all-spawn command queue uses CPU bulk buffer-update flush")
	return true


func _test_bulk_spawn_opt_in_accepted_record_shader_writeback_matches_cpu() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_bulk_spawn_opt_in_accepted_record_shader_writeback_matches_cpu...")
	var cpu_runtime := Runtime.new(4)
	var shader_runtime := Runtime.new(4)
	if not _runtime_ready_or_skip(cpu_runtime) or not _runtime_ready_or_skip(shader_runtime):
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return true

	for runtime in [cpu_runtime, shader_runtime]:
		for i in range(3):
			var enqueue_result: Dictionary = runtime.enqueue({
				"command": "SpawnObject",
				"profile_id": 30 + i,
				"object_type": 10 + i,
				"voxel_min": Vector3i(i * 4, 0, i * 5),
				"voxel_max": Vector3i(i * 4 + 3, 2, i * 5 + 4),
				"dirty_flags": {"scene": true, "collision": i == 1},
				"flags": {"visible": true, "source": i == 2},
				"asset_index": 100 + i,
				"result_index": 200 + i,
			})
			if not bool(enqueue_result.get("ok", false)) or int(enqueue_result.get("object_id", -1)) != i:
				push_error("  FAIL: expected staged object id %d, got %s" % [i, str(enqueue_result)])
				cpu_runtime.dispose()
				shader_runtime.dispose()
				return false

	var cpu_flush: Dictionary = cpu_runtime.flush_command_queue()
	var shader_flush: Dictionary = shader_runtime.flush_command_queue({
		"use_accepted_placement_record_shader": true,
	})
	if not bool(cpu_flush.get("ok", false)):
		push_error("  FAIL: CPU reference bulk flush should succeed: %s" % str(cpu_flush))
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return false
	if not bool(shader_flush.get("ok", false)):
		push_error("  FAIL: opt-in accepted-placement shader flush should succeed: %s" % str(shader_flush))
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return false
	if str(shader_flush.get("runtime_command_flush_mode", "")) != "resident_accepted_placement_record_shader_writeback":
		push_error("  FAIL: opt-in flush should report resident accepted-record writeback mode: %s" % str(shader_flush))
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return false
	if not bool(shader_flush.get("accepted_placement_record_shader_consumed", false)):
		push_error("  FAIL: opt-in flush should claim accepted records only after shader dispatch")
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return false
	if bool(shader_flush.get("resident_gpu_allocator_writeback", true)):
		push_error("  FAIL: accepted-record shader path must not claim GPU allocator ownership")
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return false
	if str(shader_flush.get("resident_gpu_allocator_writeback_mode", "")) != "resident_object_buffer_writeback":
		push_error("  FAIL: shader path should report resident object-buffer writeback mode: %s" % str(shader_flush))
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return false
	if int(shader_flush.get("accepted_placement_record_shader_dispatch_count", 0)) != 1:
		push_error("  FAIL: three records should dispatch one 64-wide workgroup: %s" % str(shader_flush))
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return false
	var stats: Dictionary = shader_flush.get("accepted_placement_record_shader_stats", {})
	if int(stats.get("applied", -1)) != 3 \
			or int(stats.get("invalid_object_id", -1)) != 0 \
			or int(stats.get("dirty_overflow", -1)) != 0 \
			or int(stats.get("already_alive", -1)) != 0 \
			or int(stats.get("skipped", -1)) != 0:
		push_error("  FAIL: accepted-record shader stats mismatch: %s" % str(shader_flush))
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return false
	if cpu_runtime.get_pending_dirty_delta_count() != 3 or shader_runtime.get_pending_dirty_delta_count() != 3:
		push_error("  FAIL: CPU and shader paths should both append three dirty rows")
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return false

	for i in range(3):
		var cpu_summary := cpu_runtime.get_object_summary(i)
		var shader_summary := shader_runtime.get_object_summary(i)
		for key in ["alive", "profile_id", "object_type", "object_flags", "voxel_min", "voxel_max", "previous_voxel_min", "previous_voxel_max"]:
			if cpu_summary.get(key) != shader_summary.get(key):
				push_error("  FAIL: shader object summary key %s mismatch for object %d: cpu=%s shader=%s" % [key, i, str(cpu_summary), str(shader_summary)])
				cpu_runtime.dispose()
				shader_runtime.dispose()
				return false

	var cpu_deltas := cpu_runtime.flush_dirty_deltas()
	var shader_deltas := shader_runtime.flush_dirty_deltas()
	if cpu_deltas.size() != 3 or shader_deltas.size() != 3:
		push_error("  FAIL: CPU and shader paths should flush three dirty deltas")
		cpu_runtime.dispose()
		shader_runtime.dispose()
		return false
	for i in range(3):
		var cpu_delta: Dictionary = cpu_deltas[i]
		var shader_delta: Dictionary = shader_deltas[i]
		for key in ["object_id", "object_type", "profile_id", "generation", "old_voxel_min", "old_voxel_max", "new_voxel_min", "new_voxel_max", "removed", "alive", "flush_epoch"]:
			if cpu_delta.get(key) != shader_delta.get(key):
				push_error("  FAIL: shader dirty delta key %s mismatch at row %d: cpu=%s shader=%s" % [key, i, str(cpu_delta), str(shader_delta)])
				cpu_runtime.dispose()
				shader_runtime.dispose()
				return false
		var cpu_flags: Dictionary = cpu_delta.get("dirty_flags", {})
		var shader_flags: Dictionary = shader_delta.get("dirty_flags", {})
		for flag_key in ["auto", "object_refs", "scene", "collision"]:
			if bool(cpu_flags.get(flag_key, false)) != bool(shader_flags.get(flag_key, false)):
				push_error("  FAIL: shader dirty flags mismatch at row %d: cpu=%s shader=%s" % [i, str(cpu_delta), str(shader_delta)])
				cpu_runtime.dispose()
				shader_runtime.dispose()
				return false

	cpu_runtime.dispose()
	shader_runtime.dispose()
	print("  OK: opt-in accepted-placement shader writes object buffers and dirty rows like CPU bulk path")
	return true


func _test_enqueue_commands_and_bounds_helper() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_enqueue_commands_and_bounds_helper...")
	var runtime := Runtime.new(1)
	if not _runtime_ready_or_skip(runtime):
		return true
	var spawn_result := runtime.enqueue({
		"command": "SpawnObject",
		"profile_id": 9,
		"object_type": 3,
		"voxel_bounds": Runtime.make_voxel_bounds(Vector3i(5, 0, 5), Vector3i(6, 1, 6)),
	})
	if not bool(spawn_result.get("ok", false)) or not bool(spawn_result.get("queued", false)) or int(spawn_result.get("object_id", -1)) != 0:
		push_error("  FAIL: enqueue SpawnObject should stage object 0")
		return false
	var update_result := runtime.enqueue({
		"command": "UpdateTransform",
		"object_id": 0,
		"voxel_min": [6, 0, 6],
		"voxel_max": {"x": 10, "y": 1, "z": 10},
	})
	if not bool(update_result.get("ok", false)) or str(update_result.get("reason", "")) != "queued":
		push_error("  FAIL: enqueue UpdateTransform should stage array/dictionary bounds")
		return false
	var profile_result := runtime.enqueue({
		"command": "UpdateProfile",
		"object_id": 0,
		"new_profile_id": 12,
		"voxel_bounds": Runtime.make_voxel_bounds(Vector3i(10, 0, 10), Vector3i(12, 1, 12)),
	})
	if not bool(profile_result.get("ok", false)) or str(profile_result.get("reason", "")) != "queued":
		push_error("  FAIL: enqueue UpdateProfile should stage new profile and bounds")
		return false
	var flags_result := runtime.enqueue({
		"command": "UpdateFlags",
		"object_id": 0,
		"flags": {"visible": true, "selected": true},
	})
	if not bool(flags_result.get("ok", false)) or str(flags_result.get("reason", "")) != "queued":
		push_error("  FAIL: enqueue UpdateFlags should stage dictionary flags")
		return false
	if runtime.get_pending_command_count() != 4:
		push_error("  FAIL: enqueue spawn/update/profile/flags should stage four commands")
		return false
	if runtime.get_pending_dirty_delta_count() != 0:
		push_error("  FAIL: staged commands must not create GPU dirty deltas before flush")
		return false
	var preflush_summary := runtime.get_selected_debug_summary([0])
	if int(preflush_summary.get("live_count", -1)) != 0:
		push_error("  FAIL: staged SpawnObject must not create live GPU state before flush")
		return false
	var bad_update := runtime.enqueue({"command": "UpdateTransform", "object_id": 8, "voxel_min": Vector3i.ZERO, "voxel_max": Vector3i.ONE})
	if bool(bad_update.get("ok", true)) or str(bad_update.get("reason", "")) == "":
		push_error("  FAIL: update on missing object should fail")
		return false
	if bool(bad_update.get("cpu_fallback", true)):
		push_error("  FAIL: failed enqueue should report cpu_fallback=false")
		return false
	if runtime.get_pending_command_count() != 4 or runtime.get_pending_dirty_delta_count() != 0:
		push_error("  FAIL: failed command should not add staged commands or dirty deltas")
		return false

	var flush_result := runtime.flush_command_queue()
	if not bool(flush_result.get("ok", false)):
		push_error("  FAIL: command queue flush should apply staged commands: %s" % str(flush_result))
		return false
	if bool(flush_result.get("cpu_fallback", true)):
		push_error("  FAIL: command queue flush must report cpu_fallback=false")
		return false
	if int(flush_result.get("command_count", -1)) != 4 or int(flush_result.get("applied_count", -1)) != 4:
		push_error("  FAIL: command queue flush should apply four staged commands")
		return false
	if runtime.get_pending_command_count() != 0 or int(flush_result.get("pending_command_count", -1)) != 0:
		push_error("  FAIL: command queue should be empty after flush")
		return false
	if runtime.get_pending_dirty_delta_count() != 4:
		push_error("  FAIL: command queue flush should produce four GPU dirty deltas")
		return false
	var summary := runtime.get_object_summary(0)
	if int(summary.get("profile_id", -1)) != 12:
		push_error("  FAIL: flushed UpdateProfile should update GPU profile readback")
		return false
	var expected_flags := Runtime.OBJECT_FLAG_VISIBLE | Runtime.OBJECT_FLAG_SELECTED
	if int(summary.get("object_flags", -1)) != expected_flags:
		push_error("  FAIL: flushed UpdateFlags should update GPU flags readback")
		return false
	var deltas := runtime.flush_dirty_deltas()
	if deltas.size() != 4:
		push_error("  FAIL: flush_dirty_deltas should return queued command deltas")
		return false
	if not runtime.flush_dirty_deltas().is_empty():
		push_error("  FAIL: second flush should be empty")
		return false

	runtime.dispose()
	print("  OK: staged enqueue/flush and caller-provided voxel bounds helper work")
	return true


func _test_failed_command_flush_clears_readback_source() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_failed_command_flush_clears_readback_source...")
	var runtime := Runtime.new(1)
	if not _runtime_ready_or_skip(runtime):
		return true
	var object_id := runtime.spawn(9, 3, Vector3i.ZERO, Vector3i.ONE)
	if object_id != 0:
		push_error("  FAIL: expected object id 0 before failed flush test")
		runtime.dispose()
		return false
	var enqueue_result := runtime.enqueue({
		"command": "UpdateTransform",
		"object_id": object_id,
		"voxel_min": Vector3i(2, 0, 2),
		"voxel_max": Vector3i(3, 1, 3),
	})
	if not bool(enqueue_result.get("ok", false)):
		push_error("  FAIL: expected live object update to stage before kill")
		runtime.dispose()
		return false
	if not runtime.kill(object_id):
		push_error("  FAIL: expected immediate kill to invalidate staged update")
		runtime.dispose()
		return false
	var flush_result := runtime.flush_command_queue()
	if bool(flush_result.get("ok", true)):
		push_error("  FAIL: staged update for killed object should fail during flush")
		runtime.dispose()
		return false
	if str(flush_result.get("readback_source", "")) != "none":
		push_error("  FAIL: failed command flush must not keep gpu_storage_buffers readback source")
		runtime.dispose()
		return false
	if bool(flush_result.get("cpu_fallback", true)):
		push_error("  FAIL: failed command flush must report cpu_fallback=false")
		runtime.dispose()
		return false
	runtime.dispose()
	print("  OK: failed command flush clears success-style readback source")
	return true


func _test_gpu_disabled_runtime_has_no_cpu_fallback() -> bool:
	print("[GPUAutoObjectRuntimeBridge] test_gpu_disabled_runtime_has_no_cpu_fallback...")
	var runtime := Runtime.new(1, false)
	if runtime.is_ready():
		push_error("  FAIL: GPU-disabled runtime should not report ready")
		return false
	if runtime.spawn(1, 2, Vector3i.ZERO, Vector3i.ONE) != -1:
		push_error("  FAIL: GPU-disabled runtime should reject spawn instead of using CPU fallback")
		return false
	var enqueue_result := runtime.enqueue({"command": "UpdateProfile", "object_id": 0, "profile_id": 3})
	if bool(enqueue_result.get("ok", true)):
		push_error("  FAIL: GPU-disabled runtime should reject enqueue UpdateProfile")
		return false
	if bool(enqueue_result.get("cpu_fallback", true)):
		push_error("  FAIL: GPU-disabled enqueue should report cpu_fallback=false")
		return false
	var profile_dirty_result := runtime.mark_profile_objects_dirty([1])
	if bool(profile_dirty_result.get("ok", true)):
		push_error("  FAIL: GPU-disabled runtime should reject profile hot update dirtying")
		return false
	if bool(profile_dirty_result.get("cpu_fallback", true)):
		push_error("  FAIL: GPU-disabled profile hot update should report cpu_fallback=false")
		return false
	if runtime.get_live_count() != 0 or runtime.get_pending_dirty_delta_count() != 0:
		push_error("  FAIL: GPU-disabled runtime should not expose CPU-side live or dirty state")
		return false
	var summary := runtime.get_selected_debug_summary()
	if bool(summary.get("cpu_fallback", true)):
		push_error("  FAIL: GPU-disabled debug summary should report cpu_fallback=false")
		return false
	if bool(summary.get("readback_snapshot", true)):
		push_error("  FAIL: GPU-disabled debug summary should not claim a readback snapshot")
		return false
	if str(summary.get("readback_source", "")) != "none":
		push_error("  FAIL: GPU-disabled debug summary must not expose a success readback source")
		return false
	var object_summary := runtime.get_object_summary(0)
	if bool(object_summary.get("cpu_fallback", true)):
		push_error("  FAIL: GPU-disabled object summary should report cpu_fallback=false")
		return false
	if str(object_summary.get("readback_source", "")) != "none":
		push_error("  FAIL: GPU-disabled object summary must not expose a success readback source")
		return false
	var committer := _make_committer()
	var flush_result := runtime.flush_to_scene_voxel_committer(committer)
	if bool(flush_result.get("ok", true)):
		push_error("  FAIL: GPU-disabled flush_to_scene_voxel_committer should not report success")
		return false
	if str(flush_result.get("reason", "")) != "runtime_not_ready":
		push_error("  FAIL: GPU-disabled flush should report runtime_not_ready")
		return false
	if bool(flush_result.get("cpu_fallback", true)):
		push_error("  FAIL: GPU-disabled flush must report cpu_fallback=false")
		return false
	if int(flush_result.get("dirty_delta_count", -1)) != 0 or int(flush_result.get("commit_result_count", -1)) != 0:
		push_error("  FAIL: GPU-disabled flush must not emit dirty deltas or commit results")
		return false
	runtime.dispose()
	print("  OK: GPU-disabled runtime stays not-ready and has no CPU fallback")
	return true


func _runtime_ready_or_skip(runtime) -> bool:
	if runtime.is_ready():
		return true
	print("  SKIP: GPU runtime not ready (%s)" % runtime.get_not_ready_reason())
	runtime.dispose()
	return false


func _make_committer() -> SceneVoxelCommitter:
	var committer := SVC.new(32, 32.0, false)
	committer.configure_scene_voxel_grid(Vector3i(32, 4, 32), Vector3.ONE, Vector3.ZERO)
	committer.build_voxel_volume(32, [
		{"channel": 0, "color": Color(1.0, 1.0, 1.0, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 4.0, "subdivisions": 4},
	])
	committer.clear_sv_dirty()
	return committer


class SPADirtyDeltaFakePrefilter:
	extends "res://scripts/autoobject_probe_prefilter_gpu.gd"

	func run_probe_prefilter(
		_sv: Dictionary,
		_autoobjects: Array,
		_dirty_tile_ids: Array[int] = [],
		_runtime_profile_container: Object = null,
		_target_field_bytes: PackedFloat32Array = PackedFloat32Array(),
		_target_read_buffers: Dictionary = {}
	) -> Dictionary:
		return {
			"ok": true,
			"anchors": [],
			"anchor_autoobject_topk": {},
			"candidate_voxel_regions_by_asset": {0: []},
			"candidate_route_readback_source": "fake_spa_prefilter",
			"candidate_route_runtime_read_source": "fake_spa_prefilter",
			"profile_probe_pack": {},
		}


class SPADirtyDeltaFakePlacer:
	extends "res://scripts/voxel_placement_generator.gd"

	func run_multi_asset(
		complexity_field: PackedFloat32Array,
		collision_field: PackedFloat32Array,
		asset_defs: Array,
		grid_size: Vector3i,
		voxel_size: Vector3,
		grid_origin: Vector3 = Vector3.ZERO,
		common_settings: Dictionary = {}
	) -> Dictionary:
		var runtime = common_settings.get("gpu_autoobject_runtime", null)
		var object_id := -1
		if runtime != null and runtime.has_method("spawn"):
			object_id = int(runtime.call(
				"spawn",
				7,
				2,
				Vector3i(0, 0, 0),
				Vector3i(4, 1, 4),
				Transform3D.IDENTITY,
				{"object_refs": true}
			))
		return {
			"ok": object_id >= 0,
			"reason": "ok" if object_id >= 0 else "fake_runtime_spawn_failed",
			"complexity_field_out": complexity_field,
			"collision_field_out": collision_field,
			"asset_results": [{
				"asset_index": 0,
				"results": [],
				"world_results": [],
				"result_count": 0,
				"spawned_runtime_object_id": object_id,
			}],
			"accepted_placements": [],
			"total_placed": 0,
			"processing_order": [0] if not asset_defs.is_empty() else [],
			"candidate_route_readback_source": "fake_spa_prefilter",
			"candidate_route_runtime_read_source": "fake_spa_prefilter",
			"candidate_route_input_contract": {},
			"gpu_autoobject_runtime_writeback": {
				"ok": object_id >= 0,
				"reason": "ok" if object_id >= 0 else "fake_runtime_spawn_failed",
				"resident_gpu_allocator_writeback": true,
				"resident_gpu_allocator_writeback_mode": "gpu_autoobject_runtime",
				"pending_dirty_delta_count": 1 if object_id >= 0 else 0,
			},
			"grid_size": grid_size,
			"voxel_size": voxel_size,
			"grid_origin": grid_origin,
		}


class SPAAcceptedRecordFakePlacer:
	extends "res://scripts/voxel_placement_generator.gd"

	func run_multi_asset(
		complexity_field: PackedFloat32Array,
		collision_field: PackedFloat32Array,
		asset_defs: Array,
		grid_size: Vector3i,
		voxel_size: Vector3,
		grid_origin: Vector3 = Vector3.ZERO,
		common_settings: Dictionary = {}
	) -> Dictionary:
		var runtime = common_settings.get("gpu_autoobject_runtime", null)
		var writeback := {
			"ok": false,
			"reason": "missing_gpu_autoobject_runtime",
			"resident_gpu_allocator_writeback": false,
			"resident_gpu_allocator_writeback_mode": "none",
		}
		if runtime != null and runtime.has_method("enqueue") and runtime.has_method("flush_command_queue"):
			for i in range(2):
				var enqueue_result: Dictionary = runtime.call("enqueue", {
					"command": "SpawnObject",
					"profile_id": 40 + i,
					"object_type": 12 + i,
					"voxel_min": Vector3i(i * 4, 0, i * 4),
					"voxel_max": Vector3i(i * 4 + 3, 1, i * 4 + 3),
					"dirty_flags": {"object_refs": true, "scene": true},
					"flags": {"visible": true},
					"asset_index": i,
					"result_index": 10 + i,
				})
				if not bool(enqueue_result.get("ok", false)):
					writeback = enqueue_result
					break
			if bool(writeback.get("ok", false)) == false and str(writeback.get("reason", "")) == "missing_gpu_autoobject_runtime":
				writeback = runtime.call("flush_command_queue")
			elif runtime.has_method("get_pending_command_count") and int(runtime.call("get_pending_command_count")) > 0:
				writeback = runtime.call("flush_command_queue")
		var use_compact_state_chain := bool(common_settings.get("use_compact_state_chain", false))
		var cpu_state_chain_mode := str(common_settings.get("cpu_state_chain_mode", "none"))
		var cpu_state_chain := {
			"mode": cpu_state_chain_mode,
			"source": "stamp_shader_storage_buffer" if use_compact_state_chain else "complexity_collision_storage_buffer_full_field_readback",
			"cpu_state_chaining": true,
			"full_field_readback_required": not use_compact_state_chain,
			"stamp_delta_cpu_state_chaining": use_compact_state_chain,
			"stamp_delta_count": 2 if use_compact_state_chain else 0,
			"applied_delta_count": 2 if use_compact_state_chain else 0,
		}
		var full_field_readback := {
			"		complexity_field_out_source": "cpu_state_chain_compact_stamp_deltas" if use_compact_state_chain else "complexity_collision_storage_buffer_full_field_readback",
			"collision_field_out_source": "cpu_state_chain_compact_stamp_deltas" if use_compact_state_chain else "complexity_collision_storage_buffer_full_field_readback",
			"complexity_field_out_is_full_field": not use_compact_state_chain,
			"collision_field_out_is_full_field": not use_compact_state_chain,
			"complexity_field_out_gpu_storage_buffer_readback": false,
			"collision_field_out_gpu_storage_buffer_readback": false,
			"cpu_state_chain_mode": cpu_state_chain_mode,
			"stamp_delta_cpu_state_chaining": use_compact_state_chain,
			"full_field_readback_required": not use_compact_state_chain,
		}
		return {
			"ok": bool(writeback.get("ok", false)),
			"reason": "ok" if bool(writeback.get("ok", false)) else str(writeback.get("reason", "fake_runtime_flush_failed")),
			"complexity_field_out": complexity_field,
			"collision_field_out": collision_field,
			"asset_results": [{
				"asset_index": 0,
				"results": [],
				"world_results": [],
				"result_count": 0,
			}],
			"accepted_placements": [],
			"total_placed": 0,
			"processing_order": [0] if not asset_defs.is_empty() else [],
			"candidate_route_readback_source": "fake_spa_prefilter",
			"candidate_route_runtime_read_source": "fake_spa_prefilter",
			"candidate_route_input_contract": {},
			"use_compact_state_chain_received": use_compact_state_chain,
			"cpu_state_chain_mode_received": cpu_state_chain_mode,
			"cpu_state_chain": cpu_state_chain,
			"full_field_readback": full_field_readback,
			"stamp_delta_readback_source": "stamp_shader_storage_buffer" if use_compact_state_chain else "disabled",
			"gpu_autoobject_runtime_writeback": writeback,
			"grid_size": grid_size,
			"voxel_size": voxel_size,
			"grid_origin": grid_origin,
		}
