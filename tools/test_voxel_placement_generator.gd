extends SceneTree

const VoxelPlacementGeneratorScript := preload("res://scripts/voxel_placement_generator.gd")
const ScenePlacementActorScript := preload("res://scripts/scene_placement_actor.gd")
const FLAG_SUPPORT := 1
const FLAG_CLEARANCE := 2


func _init() -> void:
	var grid_size := Vector3i(16, 4, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var generator = VoxelPlacementGeneratorScript.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var footprint: Array[Dictionary] = [
		{
			"local_pos": Vector3i(0, 0, 0),
			"collision_strength": 0.25,
			"flags": FLAG_SUPPORT,
			"weight": 1.0,
		},
		{
			"local_pos": Vector3i(0, 1, 0),
			"collision_strength": 1.0,
			"flags": 0,
			"weight": 1.0,
		},
		{
			"local_pos": Vector3i(0, 2, 0),
			"collision_strength": 0.0,
			"flags": FLAG_CLEARANCE,
			"weight": 1.0,
		},
	]

	var settings := {
		"top_k": 4,
		"result_capacity": 4,
		"min_distance_voxels": 2.0,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
	}

	var first := generator.run_minimal(scene, collision, footprint, grid_size, settings)
	if _is_missing_rendering_device_skip(first):
		print("[VoxelPlacementTest] SKIP: no RenderingDevice available for GPU-only placement")
		quit(0)
		return
	if first.is_empty() or int(first.get("result_count", 0)) <= 0:
		push_error("[VoxelPlacementTest] Expected at least one placement")
		quit(1)
		return
	if str(first.get("candidate_voxel_dispatch_mode", "")) != "direct_all_tiles":
		push_error("[VoxelPlacementTest] Default placement should use direct all-tile dispatch")
		quit(1)
		return
	if str(first.get("result_readback_count_source", "")) != "reduce_shader_result_count_buffer":
		push_error("[VoxelPlacementTest] Result readback count should come from reduce shader result_count buffer")
		quit(1)
		return
	if int(first.get("result_readback_bytes", -1)) != int(first.get("result_count", 0)) * VoxelPlacementGeneratorScript.RECORD_STRIDE * 16:
		push_error("[VoxelPlacementTest] Result readback byte range should match compact result count")
		quit(1)
		return
	# P0 #1 (Compact State Chain): compact_stamp_deltas is now the default.
	# Full-field readback is opt-in via force_full_field_readback=true.
	var first_full_field: Dictionary = first.get("full_field_readback", {})
	if str(first_full_field.get("complexity_field_out_source", "")) != "cpu_state_chain_compact_stamp_deltas":
		push_error("[VoxelPlacementTest] Complexity field output should report compact-stamp-delta state chain (P0 #1 default)")
		quit(1)
		return
	if str(first_full_field.get("collision_field_out_source", "")) != "cpu_state_chain_compact_stamp_deltas":
		push_error("[VoxelPlacementTest] Collision field output should report compact-stamp-delta state chain (P0 #1 default)")
		quit(1)
		return
	if bool(first_full_field.get("complexity_field_out_is_full_field", true)):
		push_error("[VoxelPlacementTest] Compact state chain should not be marked as full-field scene output")
		quit(1)
		return
	if bool(first_full_field.get("collision_field_out_is_full_field", true)):
		push_error("[VoxelPlacementTest] Compact state chain should not be marked as full-field collision output")
		quit(1)
		return
	if bool(first_full_field.get("complexity_field_out_gpu_storage_buffer_readback", true)):
		push_error("[VoxelPlacementTest] Compact state chain should skip GPU full-field scene storage-buffer readback")
		quit(1)
		return
	if bool(first_full_field.get("collision_field_out_gpu_storage_buffer_readback", true)):
		push_error("[VoxelPlacementTest] Compact state chain should skip GPU full-field collision storage-buffer readback")
		quit(1)
		return
	if int(first_full_field.get("complexity_field_out_byte_count", -1)) != 0 or int(first_full_field.get("collision_field_out_byte_count", -1)) != 0:
		push_error("[VoxelPlacementTest] Compact stamp-delta readback should have zero full-field byte count")
		quit(1)
		return
	if not bool(first_full_field.get("cpu_state_chaining", false)):
		push_error("[VoxelPlacementTest] Compact stamp-delta state chain should be marked as CPU state chaining")
		quit(1)
		return
	if str(first_full_field.get("cpu_state_chain_mode", "")) != "compact_stamp_deltas":
		push_error("[VoxelPlacementTest] Compact state chain mode should be compact_stamp_deltas")
		quit(1)
		return
	if str(first.get("tile_topk_readback_source", "")) != "disabled" or not (first.get("tile_topk", []) as Array).is_empty():
		push_error("[VoxelPlacementTest] Default placement should skip tile_topk debug readback")
		quit(1)
		return
	if str(first.get("debug_voxel_readback_source", "")) != "disabled" or not (first.get("debug_voxel", PackedFloat32Array()) as PackedFloat32Array).is_empty():
		push_error("[VoxelPlacementTest] Default placement should skip full-volume debug voxel readback")
		quit(1)
		return
	if not (first.get("candidate_voxel_sparse_ids", PackedInt32Array()) as PackedInt32Array).is_empty():
		push_error("[VoxelPlacementTest] Direct all-tile dispatch should not build a CPU sparse id list")
		quit(1)
		return
	if not _test_gpu_footprint_bake_entrypoint():
		quit(1)
		return

	var results: Array = first.get("results", [])
	var first_result: Dictionary = results[0]
	if not bool(first_result.get("valid", false)):
		push_error("[VoxelPlacementTest] First placement should be valid")
		quit(1)
		return
	if float(first_result.get("support_ratio", 0.0)) < 1.0:
		push_error("[VoxelPlacementTest] Expected full support under first placement")
		quit(1)
		return

	var actor = ScenePlacementActorScript.new()
	if not actor.initialize(true, false):
		push_error("[VoxelPlacementTest] Expected ScenePlacementActor to initialize for resident TargetSV test")
		quit(1)
		return
	var target_color_rgba8 := PackedByteArray()
	target_color_rgba8.resize(voxel_count * 4)
	var target_buffers: Dictionary = actor.prepare_target_read_buffers_from_common_gpu(
		{
			"target_color_rgba8_bytes": target_color_rgba8,
		},
		{"grid_size": grid_size}
	)
	if not bool(target_buffers.get("resident_target_read_buffer_handoff", false)):
		actor.dispose()
		push_error("[VoxelPlacementTest] Expected resident TargetSV read-buffer handoff")
		quit(1)
		return
	generator.attach_rendering_device(actor.get_rendering_device(), false)
	var borrowed_settings := settings.duplicate(true)
	borrowed_settings["target_read_buffers"] = target_buffers
	borrowed_settings["target_color_rgba8_bytes"] = target_color_rgba8
	var borrowed := generator.run_minimal(scene, collision, footprint, grid_size, borrowed_settings)
	var borrowed_summary: Dictionary = borrowed.get("target_read_buffer_summary", {})
	if str(borrowed_summary.get("target_read_buffer_source", "")) != "borrowed_scene_placement_actor_resident":
		actor.dispose()
		push_error("[VoxelPlacementTest] VPG should borrow resident TargetSV buffers, got %s" % str(borrowed_summary))
		quit(1)
		return
	if not bool(borrowed_summary.get("target_read_buffers_borrowed", false)) or bool(borrowed_summary.get("target_read_buffers_uploaded", true)):
		actor.dispose()
		push_error("[VoxelPlacementTest] Borrowed TargetSV summary should not report byte upload")
		quit(1)
		return
	if str(borrowed_summary.get("target_read_buffer_ownership", "")) != "borrowed_external":
		actor.dispose()
		push_error("[VoxelPlacementTest] Borrowed TargetSV summary should report external ownership")
		quit(1)
		return
	if not bool(borrowed_summary.get("rendering_device_match", false)) or not bool(borrowed_summary.get("target_color_rgba8_buffer_rid_valid", false)):
		actor.dispose()
		push_error("[VoxelPlacementTest] Borrowed TargetSV summary should report valid same-RD RIDs")
		quit(1)
		return
	if bool(borrowed_summary.get("cpu_fallback", true)):
		actor.dispose()
		push_error("[VoxelPlacementTest] Borrowed TargetSV path must not report CPU fallback")
		quit(1)
		return
	generator.attach_rendering_device(actor.get_rendering_device(), false)
	var mismatch_buffers := target_buffers.duplicate(true)
	mismatch_buffers["target_color_rgba8_byte_count"] = 4
	var mismatch_settings := borrowed_settings.duplicate(true)
	mismatch_settings["target_read_buffers"] = mismatch_buffers
	var mismatch := generator.run_minimal(scene, collision, footprint, grid_size, mismatch_settings)
	var mismatch_summary: Dictionary = mismatch.get("target_read_buffer_summary", {})
	if str(mismatch_summary.get("target_read_buffer_source", "")) != "uploaded_target_bytes":
		actor.dispose()
		push_error("[VoxelPlacementTest] Mismatched TargetSV resident byte counts should upload bytes, got %s" % str(mismatch_summary))
		quit(1)
		return
	if str(mismatch_summary.get("source_reason", "")) != "resident_target_read_buffer_byte_count_mismatch":
		actor.dispose()
		push_error("[VoxelPlacementTest] Mismatched TargetSV fallback should report byte-count reason")
		quit(1)
		return
	if bool(mismatch_summary.get("target_read_buffers_borrowed", true)) or not bool(mismatch_summary.get("target_read_buffers_uploaded", false)):
		actor.dispose()
		push_error("[VoxelPlacementTest] Mismatched TargetSV fallback should use uploaded bytes")
		quit(1)
		return
	generator.attach_rendering_device(actor.get_rendering_device(), false)
	var blocked_settings := settings.duplicate(true)
	blocked_settings["target_read_buffers"] = mismatch_buffers
	var blocked := generator.run_minimal(scene, collision, footprint, grid_size, blocked_settings)
	var blocked_summary: Dictionary = blocked.get("target_read_buffer_summary", {})
	if not bool(blocked.get("contract_blocked", false)) \
			or str(blocked.get("target_read_buffer_blocked_reason", "")) != "resident_target_read_buffer_byte_count_mismatch_no_debug_or_legacy_bytes":
		actor.dispose()
		push_error("[VoxelPlacementTest] Mismatched resident TargetSV without bytes should block explicitly, got %s" % str(blocked))
		quit(1)
		return
	if not bool(blocked_summary.get("contract_blocked", false)) \
			or bool(blocked_summary.get("target_read_buffers_uploaded", true)) \
			or bool(blocked_summary.get("target_read_buffers_borrowed", true)) \
			or bool(blocked_summary.get("cpu_fallback", true)):
		actor.dispose()
		push_error("[VoxelPlacementTest] Blocked TargetSV summary should expose no upload/borrow fallback: %s" % str(blocked_summary))
		quit(1)
		return
	actor.dispose()

	var first_origin: Vector3i = first_result.voxel_origin
	var stamped_collision: PackedFloat32Array = first.get("collision_field_out", PackedFloat32Array())
	var collision_idx := generator.voxel_index(first_origin + Vector3i(0, 1, 0), grid_size)
	if stamped_collision[collision_idx] <= 0.01:
		push_error("[VoxelPlacementTest] Stamp pass did not write collision field")
		quit(1)
		return
	if str(first.get("stamp_delta_count_source", "")) != "stamp_shader_storage_buffer":
		push_error("[VoxelPlacementTest] Stamp delta count should come from GPU storage buffer")
		quit(1)
		return
	if str(first.get("stamp_delta_readback_source", "")) != "disabled" or not (first.get("stamp_deltas", []) as Array).is_empty():
		push_error("[VoxelPlacementTest] Default placement should skip compact stamp delta readback")
		quit(1)
		return
	if str(first.get("stamp_bounds_source", "")) != "stamp_shader_storage_buffer":
		push_error("[VoxelPlacementTest] Stamp bounds should come from GPU storage buffer")
		quit(1)
		return
	if (first.get("stamp_bounds", []) as Array).is_empty():
		push_error("[VoxelPlacementTest] Stamp bounds should be available without delta readback")
		quit(1)
		return
	var overlap_footprint: Array[Dictionary] = [
		{
			"local_pos": Vector3i(0, 0, 0),
			"collision_strength": 0.25,
			"flags": FLAG_SUPPORT,
			"weight": 0.25,
		},
		{
			"local_pos": Vector3i(0, 0, 0),
			"collision_strength": 1.0,
			"flags": FLAG_SUPPORT,
			"weight": 0.85,
		},
	]
	var overlap_settings := settings.duplicate()
	overlap_settings["result_capacity"] = 1
	overlap_settings["min_distance_voxels"] = 0.0
	var overlap := generator.run_minimal(scene, collision, overlap_footprint, grid_size, overlap_settings)
	if overlap.is_empty() or int(overlap.get("result_count", 0)) <= 0:
		push_error("[VoxelPlacementTest] Expected overlapping stamp placement")
		quit(1)
		return
	var overlap_result: Dictionary = (overlap.get("results", []) as Array)[0]
	var overlap_origin: Vector3i = overlap_result.get("voxel_origin", Vector3i.ZERO)
	var overlap_idx := generator.voxel_index(overlap_origin, grid_size)
	var overlap_scene: PackedFloat32Array = overlap.get("complexity_field_out", PackedFloat32Array())
	var overlap_collision: PackedFloat32Array = overlap.get("collision_field_out", PackedFloat32Array())
	if overlap_scene[overlap_idx] < 0.84:
		push_error("[VoxelPlacementTest] Overlapping stamp should keep max scene value, got %.3f" % overlap_scene[overlap_idx])
		quit(1)
		return
	if overlap_collision[overlap_idx] < 0.99:
		push_error("[VoxelPlacementTest] Overlapping stamp should keep max collision value, got %.3f" % overlap_collision[overlap_idx])
		quit(1)
		return

	var second := generator.run_minimal(
		first.get("complexity_field_out", PackedFloat32Array()),
		first.get("collision_field_out", PackedFloat32Array()),
		footprint,
		grid_size,
		settings
	)
	if second.is_empty() or int(second.get("result_count", 0)) <= 0:
		push_error("[VoxelPlacementTest] Expected a second placement after stamp")
		quit(1)
		return
	if str(second.get("stamp_delta_readback_source", "")) != "disabled" or not (second.get("stamp_deltas", []) as Array).is_empty():
		push_error("[VoxelPlacementTest] Second placement should skip compact stamp delta readback by default")
		quit(1)
		return

	var second_results: Array = second.get("results", [])
	var second_origin: Vector3i = second_results[0].get("voxel_origin", Vector3i.ZERO)
	if second_origin == first_origin:
		push_error("[VoxelPlacementTest] Second placement should avoid the stamped collision cell")
		quit(1)
		return

	var compact_scene := PackedFloat32Array()
	var compact_collision := PackedFloat32Array()
	compact_scene.resize(voxel_count)
	compact_collision.resize(voxel_count)
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			compact_scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var blocker_origin := Vector3i(7, 1, 0)
	compact_collision[generator.voxel_index(blocker_origin + Vector3i(0, 1, 0), grid_size)] = 1.0
	var compact_settings := settings.duplicate()
	compact_settings["candidate_voxel_sparses"] = [Vector3i(0, 0, 0)]
	compact_settings["search_radius"] = Vector3i(1, 0, 0)
	compact_settings["sample_min"] = Vector3i(7, 0, 0)
	compact_settings["result_capacity"] = 1
	compact_settings["min_distance_voxels"] = 0.0
	var compact := generator.run_minimal(compact_scene, compact_collision, footprint, grid_size, compact_settings)
	if compact.is_empty() or int(compact.get("candidate_voxel_sparse_count", 0)) != 1:
		push_error("[VoxelPlacementTest] Expected compact candidate voxel-region dispatch")
		quit(1)
		return
	if str(compact.get("candidate_voxel_dispatch_mode", "")) != "sparse_buffer":
		push_error("[VoxelPlacementTest] Explicit compact candidate regions should use sparse buffer dispatch")
		quit(1)
		return
	var compact_results: Array = compact.get("results", [])
	if compact_results.is_empty():
		push_error("[VoxelPlacementTest] Expected compact dispatch result")
		quit(1)
		return
	var compact_origin: Vector3i = compact_results[0].get("voxel_origin", Vector3i.ZERO)
	if compact_origin != Vector3i(8, 1, 0):
		push_error("[VoxelPlacementTest] Search radius should find neighbor origin, got %s" % str(compact_origin))
		quit(1)
		return

	var delta_settings := compact_settings.duplicate(true)
	delta_settings["read_stamp_deltas"] = true
	var debug_deltas := generator.run_minimal(compact_scene, compact_collision, footprint, grid_size, delta_settings)
	if str(debug_deltas.get("stamp_delta_readback_source", "")) != "stamp_shader_storage_buffer":
		push_error("[VoxelPlacementTest] Explicit stamp delta readback should report stamp shader source")
		quit(1)
		return
	if int(debug_deltas.get("stamp_delta_count", -1)) != (debug_deltas.get("stamp_deltas", []) as Array).size():
		push_error("[VoxelPlacementTest] Explicit compact stamp delta count mismatch")
		quit(1)
		return
	if not _stamp_bounds_match_deltas(debug_deltas.get("stamp_bounds", []) as Array, debug_deltas.get("stamp_deltas", []) as Array):
		push_error("[VoxelPlacementTest] GPU stamp bounds do not match explicit compact stamp deltas")
		quit(1)
		return

	var debug_settings := compact_settings.duplicate(true)
	debug_settings["read_tile_topk"] = true
	var debug_topk := generator.run_minimal(compact_scene, compact_collision, footprint, grid_size, debug_settings)
	if str(debug_topk.get("tile_topk_readback_source", "")) != "score_shader_tile_topk_buffer":
		push_error("[VoxelPlacementTest] Explicit tile_topk debug readback should report score shader source")
		quit(1)
		return
	if (debug_topk.get("tile_topk", []) as Array).is_empty():
		push_error("[VoxelPlacementTest] Explicit tile_topk debug readback should return records")
		quit(1)
		return

	var empty_candidate_settings := settings.duplicate()
	empty_candidate_settings["candidate_voxel_sparses"] = []
	var empty_candidates := generator.run_minimal(compact_scene, compact_collision, footprint, grid_size, empty_candidate_settings)
	if empty_candidates.is_empty() or int(empty_candidates.get("candidate_voxel_sparse_count", -1)) != 0:
		push_error("[VoxelPlacementTest] Explicit empty candidate regions should skip dispatch, got %s" % str(empty_candidates.get("candidate_voxel_sparse_count", -1)))
		quit(1)
		return
	if int(empty_candidates.get("result_count", -1)) != 0 or not bool(empty_candidates.get("skipped_prefilter", false)):
		push_error("[VoxelPlacementTest] Empty candidate regions should not fall back to full-grid placement")
		quit(1)
		return
	var empty_full_field: Dictionary = empty_candidates.get("full_field_readback", {})
	if bool(empty_full_field.get("complexity_field_out_gpu_storage_buffer_readback", true)) or bool(empty_full_field.get("collision_field_out_gpu_storage_buffer_readback", true)):
		push_error("[VoxelPlacementTest] Empty candidate skip should not report GPU full-field readback")
		quit(1)
		return
	if str(empty_full_field.get("complexity_field_out_source", "")) != "input_cpu_state_prefilter_skip":
		push_error("[VoxelPlacementTest] Empty candidate skip should report input CPU scene state source")
		quit(1)
		return

	print("[VoxelPlacementTest] first=%s second=%s compact=%s stamped=%d deltas=%d tiles=%d compact_tiles=%d" % [
		str(first_origin),
		str(second_origin),
		str(compact_origin),
		int(first.get("stamp_delta_count", 0)),
		int(second.get("stamp_delta_count", 0)),
		int(first.get("tile_count", 0)),
		int(compact.get("candidate_voxel_sparse_count", 0)),
	])
	quit(0)


func _is_missing_rendering_device_skip(result: Dictionary) -> bool:
	if not bool(result.get("contract_blocked", false)):
		return false
	var contract: Dictionary = result.get("gpu_runtime_profile_contract", {})
	if str(contract.get("reason", "")) != "missing_rendering_device":
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("[VoxelPlacementTest] GPU blocked path must not enable CPU fallback")
		return false
	if str(result.get("readback_source", "")) != "none":
		push_error("[VoxelPlacementTest] GPU blocked path must not expose readback_source")
		return false
	return true


func _test_gpu_footprint_bake_entrypoint() -> bool:
	var collision := {
		"shape": "cylinder",
		"offset": Vector3(0.5, 0.25, -0.5),
		"radius": 0.75,
		"y_min": 0.0,
		"y_max": 1.0,
		"collision_strength": 0.65,
	}
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var gpu := VoxelPlacementGeneratorScript.bake_cylinder_footprint_gpu(collision, voxel_size, true, 1)
	if not bool(gpu.get("ok", false)):
		push_error("[VoxelPlacementTest] Expected GPU cylinder footprint bake, got %s" % str(gpu))
		return false
	if bool(gpu.get("cpu_fallback", true)):
		push_error("[VoxelPlacementTest] GPU footprint bake must not report CPU fallback")
		return false
	if str(gpu.get("readback_source", "")) != "bake_cylinder_footprint_compute":
		push_error("[VoxelPlacementTest] GPU footprint bake should report compute readback source")
		return false
	var default_footprint := VoxelPlacementGeneratorScript.bake_footprint_from_collision([collision], voxel_size, true, 1)
	var cpu_debug_footprint := VoxelPlacementGeneratorScript.bake_footprint_from_collision([collision], voxel_size, true, 1, false)
	var gpu_footprint: Array = gpu.get("footprint", [])
	if default_footprint.size() != gpu_footprint.size():
		push_error("[VoxelPlacementTest] Default footprint entrypoint should use GPU bake count")
		return false
	if not _footprints_match(default_footprint, cpu_debug_footprint):
		push_error("[VoxelPlacementTest] GPU default footprint should preserve CPU/debug collision semantics")
		return false
	return true


func _footprints_match(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var by_pos := {}
	for raw_entry in a:
		if not raw_entry is Dictionary:
			return false
		var entry := raw_entry as Dictionary
		var pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		by_pos["%d,%d,%d" % [pos.x, pos.y, pos.z]] = entry
	for raw_entry in b:
		if not raw_entry is Dictionary:
			return false
		var entry := raw_entry as Dictionary
		var pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var key := "%d,%d,%d" % [pos.x, pos.y, pos.z]
		if not by_pos.has(key):
			return false
		var other: Dictionary = by_pos[key]
		if absf(float(other.get("collision_strength", 0.0)) - float(entry.get("collision_strength", 0.0))) > (1.0 / 255.0 + 0.001):
			return false
		if int(other.get("flags", 0)) != int(entry.get("flags", 0)):
			return false
		if absf(float(other.get("weight", 0.0)) - float(entry.get("weight", 0.0))) > 0.001:
			return false
	return true


func _stamp_bounds_match_deltas(stamp_bounds: Array, stamp_deltas: Array) -> bool:
	var expected := {}
	for raw_delta in stamp_deltas:
		if not raw_delta is Dictionary:
			continue
		var delta: Dictionary = raw_delta
		var result_index := int(delta.get("result_index", -1))
		if result_index < 0:
			continue
		var voxel: Vector3i = delta.get("voxel", Vector3i.ZERO)
		var entry: Dictionary = expected.get(result_index, {})
		if entry.is_empty():
			expected[result_index] = {
				"voxel_min": voxel,
				"voxel_max": voxel + Vector3i.ONE,
				"written_count": 1,
			}
			continue
		var voxel_min: Vector3i = entry.get("voxel_min", voxel)
		var voxel_max: Vector3i = entry.get("voxel_max", voxel + Vector3i.ONE)
		entry["voxel_min"] = Vector3i(
			mini(voxel_min.x, voxel.x),
			mini(voxel_min.y, voxel.y),
			mini(voxel_min.z, voxel.z)
		)
		entry["voxel_max"] = Vector3i(
			maxi(voxel_max.x, voxel.x + 1),
			maxi(voxel_max.y, voxel.y + 1),
			maxi(voxel_max.z, voxel.z + 1)
		)
		entry["written_count"] = int(entry.get("written_count", 0)) + 1
		expected[result_index] = entry
	if expected.is_empty() or stamp_bounds.size() != expected.size():
		return false
	for raw_bounds in stamp_bounds:
		if not raw_bounds is Dictionary:
			return false
		var bounds: Dictionary = raw_bounds
		var result_index := int(bounds.get("result_index", -1))
		var entry: Dictionary = expected.get(result_index, {})
		if entry.is_empty():
			return false
		if bounds.get("voxel_min", Vector3i.ZERO) != entry.get("voxel_min", Vector3i.ZERO):
			return false
		if bounds.get("voxel_max", Vector3i.ZERO) != entry.get("voxel_max", Vector3i.ZERO):
			return false
		if int(bounds.get("written_count", 0)) != int(entry.get("written_count", 0)):
			return false
	return true
