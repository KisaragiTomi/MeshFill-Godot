extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")
const SPA := preload("res://scripts/scene_placement_actor.gd")
const AutoVoxelDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")
const Runtime := preload("res://scripts/gpu_autoobject_runtime.gd")


func _init() -> void:
	var generator := VPG.new()
	var grid_size := Vector3i(16, 4, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)
	var footprint: Array[Dictionary] = [{
		"local_pos": Vector3i.ZERO,
		"collision_strength": 1.0,
		"flags": 1,
		"weight": 1.0,
	}]

	var explicit_empty := generator.run_minimal(scene, collision, footprint, grid_size, {
		"candidate_voxel_sparses": [],
	})
	if explicit_empty.is_empty():
		push_error("[VoxelCandidateRouting] Explicit empty candidates should return a skip result before GPU dispatch")
		quit(1)
		return
	if int(explicit_empty.get("candidate_voxel_sparse_count", -1)) != 0:
		push_error("[VoxelCandidateRouting] Expected zero candidate voxel regions")
		quit(1)
		return
	if int(explicit_empty.get("result_count", -1)) != 0 or not bool(explicit_empty.get("skipped_prefilter", false)):
		push_error("[VoxelCandidateRouting] Empty candidate regions should not fall back to full grid")
		quit(1)
		return

	var explicit_empty_regions_alias := generator.run_minimal(scene, collision, footprint, grid_size, {
		"candidate_voxel_regions": [],
	})
	if explicit_empty_regions_alias.is_empty():
		push_error("[VoxelCandidateRouting] candidate_voxel_regions alias should return a skip result before GPU dispatch")
		quit(1)
		return
	if int(explicit_empty_regions_alias.get("candidate_voxel_sparse_count", -1)) != 0 \
	   or int(explicit_empty_regions_alias.get("result_count", -1)) != 0 \
	   or not bool(explicit_empty_regions_alias.get("skipped_prefilter", false)):
		push_error("[VoxelCandidateRouting] candidate_voxel_regions alias should behave like the legacy sparse key")
		quit(1)
		return

	var explicit_non_empty_regions_alias := generator.run_minimal(scene, collision, footprint, grid_size, {
		"candidate_voxel_regions": [Vector3i.ZERO],
	})
	if explicit_non_empty_regions_alias.is_empty():
		push_error("[VoxelCandidateRouting] candidate_voxel_regions non-empty alias should return explicit output")
		quit(1)
		return
	if int(explicit_non_empty_regions_alias.get("candidate_voxel_sparse_count", -1)) != 1:
		push_error("[VoxelCandidateRouting] candidate_voxel_regions non-empty alias should preserve one candidate region")
		quit(1)
		return

	var asset_defs: Array[Dictionary] = [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
		"candidate_voxel_sparses": [],
	}]
	var multi := generator.run_multi_asset(scene, collision, asset_defs, grid_size, Vector3.ONE)
	var asset_results: Array = multi.get("asset_results", [])
	if asset_results.size() != 1:
		push_error("[VoxelCandidateRouting] Expected one asset result")
		quit(1)
		return
	var first: Dictionary = asset_results[0]
	if int(first.get("result_count", -1)) != 0 or not bool(first.get("skipped_prefilter", false)):
		push_error("[VoxelCandidateRouting] Asset with no routed regions should be skipped")
		quit(1)
		return

	var routed_by_int := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_voxel_sparses_by_asset": {
			0: [],
		},
	})
	var routed_int_results: Array = routed_by_int.get("asset_results", [])
	if routed_int_results.size() != 1 or not bool((routed_int_results[0] as Dictionary).get("skipped_prefilter", false)):
		push_error("[VoxelCandidateRouting] Int asset route key should be consumed")
		quit(1)
		return
	if not _assert_common_route_source_defaults(routed_by_int, "int asset route"):
		quit(1)
		return

	var routed_by_string := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_voxel_sparses_by_asset": {
			"0": [],
		},
	})
	var routed_string_results: Array = routed_by_string.get("asset_results", [])
	if routed_string_results.size() != 1 or not bool((routed_string_results[0] as Dictionary).get("skipped_prefilter", false)):
		push_error("[VoxelCandidateRouting] String asset route key should be consumed")
		quit(1)
		return
	if not _assert_common_route_source_defaults(routed_by_string, "string asset route"):
		quit(1)
		return

	var routed_by_regions_alias := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_voxel_regions_by_asset": {
			0: [],
		},
		"candidate_route_readback_source": "gpu_vote_buffer_readback",
		"candidate_route_runtime_read_source": "cpu_debug_bridge",
	})
	var routed_regions_alias_results: Array = routed_by_regions_alias.get("asset_results", [])
	if routed_regions_alias_results.size() != 1 or not bool((routed_regions_alias_results[0] as Dictionary).get("skipped_prefilter", false)):
		push_error("[VoxelCandidateRouting] candidate_voxel_regions_by_asset alias should be consumed")
		quit(1)
		return
	if str(routed_by_regions_alias.get("candidate_route_readback_source", "")) != "gpu_vote_buffer_readback" \
	   or str(routed_by_regions_alias.get("candidate_route_runtime_read_source", "")) != "cpu_debug_bridge":
		push_error("[VoxelCandidateRouting] VPG should echo candidate route source metadata from common_settings")
		quit(1)
		return
	var fake_resident_source := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_voxel_regions_by_asset": {
			0: [],
		},
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "gpu_route_buffers",
	})
	if str(fake_resident_source.get("candidate_route_readback_source", "")) != "gpu_vote_buffer_readback":
		push_error("[VoxelCandidateRouting] Common CPU route dictionaries must keep readback source gpu_vote_buffer_readback")
		quit(1)
		return
	if str(fake_resident_source.get("candidate_route_runtime_read_source", "")) != "cpu_debug_bridge":
		push_error("[VoxelCandidateRouting] Common CPU route dictionaries must keep runtime source cpu_debug_bridge")
		quit(1)
		return
	if not _assert_route_input_contract(
		fake_resident_source,
		"common CPU route dictionary",
		"common_cpu_dictionary",
		true,
		"gpu_vote_buffer_readback",
		"cpu_debug_bridge"
	):
		quit(1)
		return

	var fake_legacy_resident_source := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_voxel_sparses_by_asset": {
			0: [],
		},
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "gpu_route_buffers",
	})
	if str(fake_legacy_resident_source.get("candidate_route_readback_source", "")) != "gpu_vote_buffer_readback":
		push_error("[VoxelCandidateRouting] Legacy common CPU route dictionaries must keep readback source gpu_vote_buffer_readback")
		quit(1)
		return
	if str(fake_legacy_resident_source.get("candidate_route_runtime_read_source", "")) != "cpu_debug_bridge":
		push_error("[VoxelCandidateRouting] Legacy common CPU route dictionaries must keep runtime source cpu_debug_bridge")
		quit(1)
		return

	var metadata_only_source := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "gpu_route_buffers",
	})
	if str(metadata_only_source.get("candidate_route_readback_source", "")) != "none":
		push_error("[VoxelCandidateRouting] Candidate route readback metadata without route data must not claim a resident source")
		quit(1)
		return
	if str(metadata_only_source.get("candidate_route_runtime_read_source", "")) != "none":
		push_error("[VoxelCandidateRouting] Candidate route runtime metadata without route data must not claim a resident source")
		quit(1)
		return
	if not _assert_route_input_contract(
		metadata_only_source,
		"metadata-only route labels",
		"none",
		true,
		"none",
		"none"
	):
		quit(1)
		return

	var route_profile_metadata_only_source := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_route_profiles": [{
			"asset_index": 0,
			"tile_radius": Vector3i.ONE,
		}],
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "gpu_route_buffers",
	})
	if str(route_profile_metadata_only_source.get("candidate_route_readback_source", "")) != "none":
		push_error("[VoxelCandidateRouting] Candidate route profiles without route data must not claim a resident readback source")
		quit(1)
		return
	if str(route_profile_metadata_only_source.get("candidate_route_runtime_read_source", "")) != "none":
		push_error("[VoxelCandidateRouting] Candidate route profiles without route data must not claim a resident runtime source")
		quit(1)
		return
	if not _assert_route_input_contract(
		route_profile_metadata_only_source,
		"candidate_route_profiles-only route labels",
		"none",
		true,
		"none",
		"none"
	):
		quit(1)
		return

	if not _test_zero_count_indirect_dispatch_contract():
		quit(1)
		return

	if not _test_resident_route_contract_gate():
		quit(1)
		return

	var malformed_route_source := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_voxel_regions_by_asset": [],
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "gpu_route_buffers",
	})
	if str(malformed_route_source.get("candidate_route_readback_source", "")) != "none":
		push_error("[VoxelCandidateRouting] Malformed common route data must not claim a resident readback source")
		quit(1)
		return
	if str(malformed_route_source.get("candidate_route_runtime_read_source", "")) != "none":
		push_error("[VoxelCandidateRouting] Malformed common route data must not claim a resident runtime source")
		quit(1)
		return

	if not _test_contract_blocked_multi_asset_route_source_gate(generator, scene, collision, grid_size):
		quit(1)
		return

	var common_current_priority := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_voxel_regions_by_asset": {
			0: [],
		},
		"candidate_voxel_sparses_by_asset": {
			0: [Vector3i.ZERO],
		},
	})
	var common_priority_results: Array = common_current_priority.get("asset_results", [])
	if common_priority_results.size() != 1 or not bool((common_priority_results[0] as Dictionary).get("skipped_prefilter", false)):
		push_error("[VoxelCandidateRouting] candidate_voxel_regions_by_asset should override legacy common sparse routes")
		quit(1)
		return

	var asset_key_priority := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
		"candidate_voxel_sparses": [],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_voxel_sparses_by_asset": {
			0: [Vector3i.ZERO],
		},
	})
	var priority_results: Array = asset_key_priority.get("asset_results", [])
	if priority_results.size() != 1 or not bool((priority_results[0] as Dictionary).get("skipped_prefilter", false)):
		push_error("[VoxelCandidateRouting] Asset-owned candidate_voxel_sparses should override common routed regions")
		quit(1)
		return

	var asset_regions_alias_priority := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
		"candidate_voxel_regions": [],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_voxel_sparses_by_asset": {
			0: [Vector3i.ZERO],
		},
	})
	var alias_priority_results: Array = asset_regions_alias_priority.get("asset_results", [])
	if alias_priority_results.size() != 1 or not bool((alias_priority_results[0] as Dictionary).get("skipped_prefilter", false)):
		push_error("[VoxelCandidateRouting] Asset-owned candidate_voxel_regions alias should override common routed regions")
		quit(1)
		return

	var asset_current_priority := generator.run_multi_asset(scene, collision, [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
		"candidate_voxel_regions": [],
		"candidate_voxel_sparses": [Vector3i.ZERO],
	}], grid_size, Vector3.ONE, Vector3.ZERO, {
		"candidate_voxel_sparses_by_asset": {
			0: [Vector3i.ZERO],
		},
	})
	var asset_current_priority_results: Array = asset_current_priority.get("asset_results", [])
	if asset_current_priority_results.size() != 1 or not bool((asset_current_priority_results[0] as Dictionary).get("skipped_prefilter", false)):
		push_error("[VoxelCandidateRouting] Asset-owned candidate_voxel_regions should override legacy asset sparse routes")
		quit(1)
		return

	if not _test_physical_shader_has_no_route_terms():
		quit(1)
		return
	if not _test_scene_placement_asset_defs_keep_route_in_common_settings():
		quit(1)
		return
	if not _test_scene_placement_pipeline_reports_normalized_route_source():
		quit(1)
		return
	if not _test_scene_placement_resident_route_handoff_default():
		quit(1)
		return

	print("[VoxelCandidateRouting] explicit empty route, int/string/alias common keys, and asset-owned priority OK")
	print("[VoxelCandidateRouting] ALL TESTS PASSED")
	quit(0)


func _test_physical_shader_has_no_route_terms() -> bool:
	var shader_path := "res://shaders/score_voxel_tile.glsl"
	var source := FileAccess.get_file_as_string(shader_path)
	if FileAccess.get_open_error() != OK:
		push_error("[VoxelCandidateRouting] Could not read %s" % shader_path)
		return false

	for forbidden in [
		"asset_embedding_buffer",
		"voxel_asset_topk_buffer",
		"tile_asset_topk_buffer",
		"semantic_score",
		"route_score",
		"spatial_hash",
		"count_objects_per_cell",
		"sorted_object_id_buffer",
	]:
		if source.find(forbidden) >= 0:
			push_error("[VoxelCandidateRouting] Physical placement shader contains route-only term '%s'" % forbidden)
			return false

	if source.find("SceneVoxelTile") >= 0:
		push_error("[VoxelCandidateRouting] Physical placement region shader should not name placement TILE_SIZE regions as SceneVoxelTile")
		return false

	print("[VoxelCandidateRouting] physical shader route-term boundary OK")
	return true


func _assert_common_route_source_defaults(result: Dictionary, label: String) -> bool:
	if str(result.get("candidate_route_readback_source", "")) != "gpu_vote_buffer_readback":
		push_error("[VoxelCandidateRouting] %s should default candidate route readback source to gpu_vote_buffer_readback" % label)
		return false
	if str(result.get("candidate_route_runtime_read_source", "")) != "cpu_debug_bridge":
		push_error("[VoxelCandidateRouting] %s should default candidate route runtime source to cpu_debug_bridge" % label)
		return false
	return true


func _assert_route_input_contract(
	result: Dictionary,
	label: String,
	expected_route_input: String,
	expected_normalized: bool,
	expected_readback: String,
	expected_runtime: String
) -> bool:
	var contract: Dictionary = result.get("candidate_route_input_contract", {})
	if contract.is_empty():
		push_error("[VoxelCandidateRouting] %s should expose candidate_route_input_contract diagnostics" % label)
		return false
	if str(contract.get("route_input", "")) != expected_route_input:
		push_error("[VoxelCandidateRouting] %s route_input should be %s, got %s" % [label, expected_route_input, str(contract.get("route_input", ""))])
		return false
	if bool(contract.get("resident_route_input_ready", true)):
		push_error("[VoxelCandidateRouting] %s must not mark resident route input ready before owner/RID/stride/range contract exists" % label)
		return false
	if str(contract.get("resident_route_owner", "")) != "none":
		push_error("[VoxelCandidateRouting] %s must not claim a resident route owner" % label)
		return false
	if str(contract.get("resident_route_buffer_rid", "")) != "none":
		push_error("[VoxelCandidateRouting] %s must not claim a resident route buffer RID" % label)
		return false
	if int(contract.get("resident_route_record_stride", -1)) != 0:
		push_error("[VoxelCandidateRouting] %s must not claim a resident route record stride" % label)
		return false
	if int(contract.get("resident_route_range_count", -1)) != 0:
		push_error("[VoxelCandidateRouting] %s must not claim resident route ranges" % label)
		return false
	if str(contract.get("debug_snapshot_api", "")) != "none":
		push_error("[VoxelCandidateRouting] %s must not claim a resident debug snapshot API" % label)
		return false
	if bool(contract.get("requested_source_labels_normalized", false)) != expected_normalized:
		push_error("[VoxelCandidateRouting] %s requested_source_labels_normalized mismatch" % label)
		return false
	if str(contract.get("normalized_readback_source", "")) != expected_readback:
		push_error("[VoxelCandidateRouting] %s normalized readback source mismatch" % label)
		return false
	if str(contract.get("normalized_runtime_read_source", "")) != expected_runtime:
		push_error("[VoxelCandidateRouting] %s normalized runtime source mismatch" % label)
		return false
	return true


func _test_resident_route_contract_gate() -> bool:
	var metadata_only_contract := VPG._candidate_route_input_contract_from_settings({
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "resident",
		"candidate_route_input_contract": {
			"owner": "AutoObjectProbePrefilterGPU",
			"resident_route_record_stride": 16,
			"resident_route_range_stride": 16,
			"resident_route_range_count": 2,
			"resident_route_schema_version": 1,
			"asset_count": 1,
			"profile_count": 1,
			"debug_snapshot_api": "readback_candidate_route_snapshot",
			"debug_snapshot_status": "available",
		},
	})
	if bool(metadata_only_contract.get("resident_route_input_ready", true)):
		push_error("[VoxelCandidateRouting] Metadata-only resident route contract must not be ready")
		return false
	if str(metadata_only_contract.get("route_input", "")) != "resident_contract":
		push_error("[VoxelCandidateRouting] Metadata-only resident route contract should be diagnosed as resident_contract input")
		return false
	if str(metadata_only_contract.get("normalized_runtime_read_source", "")) != "none":
		push_error("[VoxelCandidateRouting] Metadata-only resident route contract must normalize runtime source to none")
		return false
	if str(metadata_only_contract.get("rejection_reason", "")) != "missing_or_invalid_route_record_rid":
		push_error("[VoxelCandidateRouting] Metadata-only resident route contract should reject missing route record RID")
		return false
	if int(metadata_only_contract.get("asset_count", 0)) != 1 \
	   or int(metadata_only_contract.get("profile_count", 0)) != 1 \
	   or str(metadata_only_contract.get("debug_snapshot_api", "")) != "readback_candidate_route_snapshot":
		push_error("[VoxelCandidateRouting] Resident route contract diagnostics should preserve owner counts and debug snapshot API")
		return false

	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		print("[VoxelCandidateRouting] SKIP resident route RID gate: no RenderingDevice")
		return true
	var route_record_bytes := PackedByteArray()
	route_record_bytes.resize(16)
	var route_range_bytes := PackedByteArray()
	route_range_bytes.resize(16)
	var record_rid := rd.storage_buffer_create(route_record_bytes.size(), route_record_bytes)
	var range_rid := rd.storage_buffer_create(route_range_bytes.size(), route_range_bytes)
	var rid_contract := VPG._candidate_route_input_contract_from_settings({
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "resident",
		"candidate_route_input_contract": {
			"owner": "AutoObjectProbePrefilterGPU",
			"resident_route_record_rid": record_rid,
			"resident_route_range_rid": range_rid,
			"resident_route_record_stride": 16,
			"resident_route_record_capacity": 1,
			"resident_route_range_stride": 16,
			"resident_route_range_count": 1,
			"resident_route_schema_version": 1,
			"same_rendering_device_as_vpg": true,
			"vpg_binds_route_buffers": false,
			"asset_count": 1,
			"profile_count": 1,
		},
	})
	if record_rid.is_valid():
		rd.free_rid(record_rid)
	if range_rid.is_valid():
		rd.free_rid(range_rid)
	rd.free()
	if bool(rid_contract.get("resident_route_input_ready", true)):
		push_error("[VoxelCandidateRouting] Valid route RIDs must not be resident-ready until VPG binds route buffers")
		return false
	if not bool(rid_contract.get("resident_route_record_rid_valid", false)) \
	   or not bool(rid_contract.get("resident_route_range_rid_valid", false)):
		push_error("[VoxelCandidateRouting] Resident route contract should diagnose record/range RID validity")
		return false
	if str(rid_contract.get("rejection_reason", "")) != "vpg_route_buffer_binding_not_implemented":
		push_error("[VoxelCandidateRouting] Valid metadata-only route buffers should reject on missing VPG binding")
		return false
	if str(rid_contract.get("normalized_readback_source", "")) != "none" \
	   or str(rid_contract.get("normalized_runtime_read_source", "")) != "none":
		push_error("[VoxelCandidateRouting] Unbound route buffers must normalize resident sources to none")
		return false

	var default_generator := VPG.new()
	var default_rd := RenderingServer.create_local_rendering_device()
	if default_rd == null:
		print("[VoxelCandidateRouting] SKIP default resident route binding fixture: no RenderingDevice")
		return true
	if not default_generator.attach_rendering_device(default_rd, false):
		default_rd.free()
		push_error("[VoxelCandidateRouting] Default resident route binding fixture should attach VPG RenderingDevice")
		return false
	var default_record_bytes := PackedByteArray()
	default_record_bytes.resize(16)
	default_record_bytes.encode_u32(0, 0)
	default_record_bytes.encode_u32(4, 456)
	var default_range_bytes := PackedByteArray()
	default_range_bytes.resize(16)
	default_range_bytes.encode_u32(0, 0)
	default_range_bytes.encode_u32(4, 1)
	var default_record_rid := default_rd.storage_buffer_create(default_record_bytes.size(), default_record_bytes)
	var default_range_rid := default_rd.storage_buffer_create(default_range_bytes.size(), default_range_bytes)
	var default_scene := PackedFloat32Array([1.0])
	var default_collision := PackedFloat32Array([1.0])
	var default_footprint: Array[Dictionary] = [{
		"local_pos": Vector3i.ZERO,
		"collision_strength": 1.0,
		"flags": 0,
		"weight": 1.0,
	}]
	var default_result := default_generator.run_minimal(default_scene, default_collision, default_footprint, Vector3i.ONE, {
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "resident",
		"candidate_route_input_contract": {
			"owner": "AutoObjectProbePrefilterGPU",
			"resident_route_record_rid": default_record_rid,
			"resident_route_range_rid": default_range_rid,
			"resident_route_record_stride": 16,
			"resident_route_record_capacity": 1,
			"resident_route_range_stride": 16,
			"resident_route_range_count": 1,
			"resident_route_schema_version": 1,
			"same_rendering_device_as_vpg": true,
			"asset_count": 1,
			"profile_count": 1,
		},
	})
	var default_contract: Dictionary = default_result.get("candidate_route_input_contract", {})
	var default_debug: Dictionary = default_result.get("candidate_route_binding_debug", {})
	if default_record_rid.is_valid():
		default_rd.free_rid(default_record_rid)
	if default_range_rid.is_valid():
		default_rd.free_rid(default_range_rid)
	default_generator.dispose(false)
	default_rd.free()
	if default_contract.is_empty():
		push_error("[VoxelCandidateRouting] Default resident route binding fixture should expose VPG route contract diagnostics")
		return false
	if not bool(default_contract.get("resident_route_input_ready", false)) \
	   or not bool(default_contract.get("vpg_binds_route_buffers", false)):
		push_error("[VoxelCandidateRouting] Default resident route path should keep readiness diagnostics GPU-owned: %s" % str(default_contract))
		return false
	if int(default_contract.get("vpg_route_buffer_binding_range_reads", -1)) != 0 \
	   or int(default_contract.get("vpg_route_buffer_binding_record_reads", -1)) != 0 \
	   or bool(default_contract.get("vpg_route_buffer_binding_debug_enabled", true)):
		push_error("[VoxelCandidateRouting] Default resident route path must not merge binding debug readback fields: %s / %s" % [str(default_contract), str(default_debug)])
		return false
	if str(default_debug.get("read_source", "")) != "disabled":
		push_error("[VoxelCandidateRouting] Default resident route binding debug readback should be disabled: %s" % str(default_debug))
		return false
	if bool(default_contract.get("resident_route_sparse_adapter_debug_snapshot_enabled", true)) \
	   or str(default_contract.get("resident_route_sparse_adapter_debug_count_snapshot_source", "")) != "disabled" \
	   or str(default_contract.get("resident_route_sparse_adapter_debug_indirect_args_snapshot_source", "")) != "disabled":
		push_error("[VoxelCandidateRouting] Default resident route sparse adapter must not publish debug snapshots: %s" % str(default_contract))
		return false
	var default_indirect_args = default_contract.get("resident_route_sparse_adapter_indirect_args_words", PackedInt32Array())
	if default_indirect_args.size() != 0:
		push_error("[VoxelCandidateRouting] Default resident route indirect args words are a debug snapshot and should stay empty, got %s" % str(default_indirect_args))
		return false
	if not bool(default_contract.get("resident_route_sparse_adapter_indirect_args_ready", false)) \
	   or str(default_contract.get("resident_route_sparse_adapter_indirect_args_source", "")) != "route_adapter_indirect_args_buffer":
		push_error("[VoxelCandidateRouting] Default resident route should keep indirect args readiness/source without readback: %s" % str(default_contract))
		return false
	if str(default_contract.get("resident_route_sparse_adapter_candidate_count_source", "")) != "route_adapter_indirect_args_buffer" \
	   or bool(default_contract.get("resident_route_sparse_adapter_candidate_count_cpu_readback_required", true)):
		push_error("[VoxelCandidateRouting] Default resident route count diagnostics should stay GPU-owned: %s" % str(default_contract))
		return false
	var default_sparse_ids: PackedInt32Array = default_result.get("candidate_voxel_sparse_ids", PackedInt32Array())
	if not default_sparse_ids.is_empty():
		push_error("[VoxelCandidateRouting] Default resident route sparse IDs are a debug snapshot and should stay empty, got %s" % str(default_sparse_ids))
		return false

	var bind_generator := VPG.new()
	var bind_rd := RenderingServer.create_local_rendering_device()
	if bind_rd == null:
		print("[VoxelCandidateRouting] SKIP resident route binding fixture: no RenderingDevice")
		return true
	if not bind_generator.attach_rendering_device(bind_rd, false):
		bind_rd.free()
		push_error("[VoxelCandidateRouting] Resident route binding fixture should attach VPG RenderingDevice")
		return false
	var bind_record_bytes := PackedByteArray()
	bind_record_bytes.resize(16)
	bind_record_bytes.encode_u32(0, 0)
	bind_record_bytes.encode_u32(4, 456)
	var bind_range_bytes := PackedByteArray()
	bind_range_bytes.resize(16)
	bind_range_bytes.encode_u32(0, 0)
	bind_range_bytes.encode_u32(4, 1)
	var bind_record_rid := bind_rd.storage_buffer_create(bind_record_bytes.size(), bind_record_bytes)
	var bind_range_rid := bind_rd.storage_buffer_create(bind_range_bytes.size(), bind_range_bytes)
	var bind_scene := PackedFloat32Array([1.0])
	var bind_collision := PackedFloat32Array([1.0])
	var bind_footprint: Array[Dictionary] = [{
		"local_pos": Vector3i.ZERO,
		"collision_strength": 1.0,
		"flags": 0,
		"weight": 1.0,
	}]
	var bind_result := bind_generator.run_minimal(bind_scene, bind_collision, bind_footprint, Vector3i.ONE, {
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "resident",
		"read_candidate_route_sparse_adapter_debug": true,
		"candidate_route_input_contract": {
			"owner": "AutoObjectProbePrefilterGPU",
			"resident_route_record_rid": bind_record_rid,
			"resident_route_range_rid": bind_range_rid,
			"resident_route_record_stride": 16,
			"resident_route_record_capacity": 1,
			"resident_route_range_stride": 16,
			"resident_route_range_count": 1,
			"resident_route_schema_version": 1,
			"same_rendering_device_as_vpg": true,
			"asset_count": 1,
			"profile_count": 1,
		},
	})
	var bind_contract: Dictionary = bind_result.get("candidate_route_input_contract", {})
	var bind_debug: Dictionary = bind_result.get("candidate_route_binding_debug", {})
	if bind_record_rid.is_valid():
		bind_rd.free_rid(bind_record_rid)
	if bind_range_rid.is_valid():
		bind_rd.free_rid(bind_range_rid)
	bind_generator.dispose(false)
	bind_rd.free()
	if bind_contract.is_empty():
		push_error("[VoxelCandidateRouting] Resident route binding fixture should expose VPG route contract diagnostics")
		return false
	if not bool(bind_contract.get("vpg_binds_route_buffers", false)):
		push_error("[VoxelCandidateRouting] VPG should report route buffer binding only after creating the score shader route set")
		return false
	if str(bind_contract.get("vpg_route_buffer_binding_source", "")) != "score_shader_set2_uniform_set":
		push_error("[VoxelCandidateRouting] VPG route binding source should name the score shader uniform set")
		return false
	if int(bind_contract.get("vpg_route_buffer_binding_range_reads", 0)) <= 0 \
	   or int(bind_contract.get("vpg_route_buffer_binding_record_reads", 0)) <= 0:
		push_error("[VoxelCandidateRouting] VPG route binding fixture should consume route range and record buffers: %s" % str(bind_debug))
		return false
	if not bool(bind_contract.get("resident_route_input_ready", false)):
		push_error("[VoxelCandidateRouting] Bound route buffers should be resident-ready after VPG derives sparse candidates from resident route ranges: %s" % str(bind_contract))
		return false
	if str(bind_contract.get("rejection_reason", "")) != "none":
		push_error("[VoxelCandidateRouting] Bound route buffers should not reject after resident sparse adapter, got %s" % str(bind_contract.get("rejection_reason", "")))
		return false
	if str(bind_result.get("candidate_route_readback_source", "")) != "resident_route_snapshot" \
	   or str(bind_result.get("candidate_route_runtime_read_source", "")) != "resident":
		push_error("[VoxelCandidateRouting] Resident sparse adapter should normalize route sources to resident")
		return false
	if str(bind_result.get("candidate_voxel_dispatch_mode", "")) != "sparse_buffer":
		push_error("[VoxelCandidateRouting] Resident route adapter must dispatch through the sparse candidate buffer")
		return false
	var bind_sparse_ids: PackedInt32Array = bind_result.get("candidate_voxel_sparse_ids", PackedInt32Array())
	if bind_sparse_ids.size() != 1 or int(bind_sparse_ids[0]) != 0:
		push_error("[VoxelCandidateRouting] Resident route adapter should derive one candidate tile id from route records, got %s" % str(bind_sparse_ids))
		return false
	if not bool(bind_contract.get("resident_route_sparse_adapter", false)) \
	   or int(bind_contract.get("resident_route_sparse_adapter_record_reads", 0)) != 1 \
	   or int(bind_contract.get("resident_route_sparse_adapter_candidate_count", 0)) != 1:
		push_error("[VoxelCandidateRouting] Resident sparse adapter diagnostics should report one record-derived candidate: %s" % str(bind_contract))
		return false
	if str(bind_contract.get("resident_route_sparse_adapter_source", "")) != "resident_route_gpu_sparse_adapter" \
	   or str(bind_contract.get("resident_route_sparse_adapter_mode", "")) != "gpu_compute_copy_filter":
		push_error("[VoxelCandidateRouting] Resident route fixture must exercise GPU sparse adapter, got %s" % str(bind_contract))
		return false
	if int(bind_contract.get("resident_route_sparse_adapter_output_capacity", 0)) != 1:
		push_error("[VoxelCandidateRouting] Resident GPU sparse adapter should report one-slot sparse output capacity: %s" % str(bind_contract))
		return false
	if str(bind_contract.get("resident_route_sparse_adapter_candidate_count_source", "")) != "route_adapter_indirect_args_buffer":
		push_error("[VoxelCandidateRouting] Resident GPU sparse adapter should source compact count from GPU-owned indirect args: %s" % str(bind_contract))
		return false
	if bool(bind_contract.get("resident_route_sparse_adapter_candidate_count_cpu_readback_required", true)):
		push_error("[VoxelCandidateRouting] Resident GPU sparse adapter count diagnostics must not require CPU readback: %s" % str(bind_contract))
		return false
	if str(bind_contract.get("resident_route_sparse_adapter_candidate_count_semantics", "")) != "gpu_owned_runtime_count":
		push_error("[VoxelCandidateRouting] Resident GPU sparse adapter should label count semantics as GPU-owned runtime count: %s" % str(bind_contract))
		return false
	if not bool(bind_contract.get("resident_route_sparse_adapter_indirect_args_ready", false)) \
	   or str(bind_contract.get("resident_route_sparse_adapter_indirect_args_layout", "")) != "u32x3_group_count_xyz":
		push_error("[VoxelCandidateRouting] Resident GPU sparse adapter should prepare u32x3 indirect args diagnostics: %s" % str(bind_contract))
		return false
	if str(bind_contract.get("resident_route_sparse_adapter_indirect_args_source", "")) != "route_adapter_indirect_args_buffer":
		push_error("[VoxelCandidateRouting] Resident GPU sparse adapter should name the indirect args buffer as the args source: %s" % str(bind_contract))
		return false
	if not bool(bind_contract.get("resident_route_sparse_adapter_debug_snapshot_enabled", false)) \
	   or str(bind_contract.get("resident_route_sparse_adapter_debug_count_snapshot_source", "")) != "route_adapter_count_buffer_debug_readback" \
	   or str(bind_contract.get("resident_route_sparse_adapter_debug_indirect_args_snapshot_source", "")) != "route_adapter_indirect_args_debug_readback":
		push_error("[VoxelCandidateRouting] Opt-in resident adapter debug snapshot should clearly label count/args readbacks: %s" % str(bind_contract))
		return false
	var indirect_args = bind_contract.get("resident_route_sparse_adapter_indirect_args_words", PackedInt32Array())
	if indirect_args.size() < 3 or int(indirect_args[0]) != 1 or int(indirect_args[1]) != 1 or int(indirect_args[2]) != 1:
		push_error("[VoxelCandidateRouting] Resident GPU sparse adapter indirect args should be [candidate_count, 1, 1], got %s" % str(indirect_args))
		return false
	if bool(bind_contract.get("resident_route_sparse_adapter_score_dispatch_indirect_api_supported", true)):
		if not bool(bind_contract.get("resident_route_sparse_adapter_score_dispatch_indirect", false)):
			push_error("[VoxelCandidateRouting] Positive resident adapter count should score-dispatch through indirect args when the API is available: %s" % str(bind_contract))
			return false
		if str(bind_contract.get("resident_route_sparse_adapter_score_dispatch_indirect_block_reason", "")) != "none":
			push_error("[VoxelCandidateRouting] Positive indirect score dispatch should not report a block reason: %s" % str(bind_contract))
			return false
	else:
		if bool(bind_contract.get("resident_route_sparse_adapter_score_dispatch_indirect", false)):
			push_error("[VoxelCandidateRouting] Score dispatch must not claim indirect dispatch when the RenderingDevice API is unavailable: %s" % str(bind_contract))
			return false
		if str(bind_contract.get("resident_route_sparse_adapter_score_dispatch_indirect_block_reason", "")) != "rendering_device_dispatch_indirect_api_unavailable":
			push_error("[VoxelCandidateRouting] API-unavailable indirect dispatch should report a clear block reason: %s" % str(bind_contract))
			return false
	if int(bind_contract.get("resident_route_record_capacity", 0)) != 1:
		push_error("[VoxelCandidateRouting] Resident GPU sparse adapter should preserve fixed record capacity in diagnostics: %s" % str(bind_contract))
		return false

	print("[VoxelCandidateRouting] resident route contract gate OK")
	return true


func _test_zero_count_indirect_dispatch_contract() -> bool:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		print("[VoxelCandidateRouting] SKIP zero-count indirect dispatch fixture: no RenderingDevice")
		return true
	var generator := VPG.new()
	if not generator.attach_rendering_device(rd, false):
		rd.free()
		push_error("[VoxelCandidateRouting] Zero-count indirect dispatch fixture should attach VPG RenderingDevice")
		return false
	var indirect_args := generator.dispatch_indirect_args_buffer_zero(
		"frame",
		"zero_count_candidate_route_score_indirect_args_u32x3"
	)
	var decision: Dictionary = generator._score_dispatch_indirect_decision(indirect_args, 0, false)
	var indirect_words := PackedInt32Array()
	indirect_words.resize(3)
	if indirect_args.is_valid():
		var bytes := rd.buffer_get_data(indirect_args, 0, 12)
		for i in range(mini(3, int(bytes.size() / 4))):
			indirect_words[i] = int(bytes.decode_u32(i * 4))
	generator.dispose(false)
	rd.free()
	if not bool(decision.get("score_dispatch_indirect_api_supported", false)):
		print("[VoxelCandidateRouting] SKIP zero-count indirect dispatch fixture: compute_list_dispatch_indirect unavailable")
		return true
	if bool(decision.get("score_dispatch_indirect", true)):
		push_error("[VoxelCandidateRouting] Zero-count score dispatch must be gated instead of submitted indirectly: %s" % str(decision))
		return false
	if str(decision.get("score_dispatch_indirect_block_reason", "")) != "zero_candidate_count_indirect_dispatch_gated":
		push_error("[VoxelCandidateRouting] Zero-count indirect dispatch should report the gated block reason: %s" % str(decision))
		return false
	if indirect_words.size() < 3 or int(indirect_words[0]) != 0 or int(indirect_words[1]) != 0 or int(indirect_words[2]) != 0:
		push_error("[VoxelCandidateRouting] Zero-count indirect args buffer should stay [0, 0, 0], got %s" % str(indirect_words))
		return false

	print("[VoxelCandidateRouting] zero-count indirect dispatch contract OK")
	return true


func _test_contract_blocked_multi_asset_route_source_gate(
	generator: VoxelPlacementGenerator,
	scene: PackedFloat32Array,
	collision: PackedFloat32Array,
	grid_size: Vector3i
) -> bool:
	var asset_defs: Array[Dictionary] = [{
		"collision": [{
			"voxel": Vector3i.ZERO,
			"collision_strength": 1.0,
		}],
	}]
	var blocked_cpu_route := generator.run_multi_asset(scene, collision, asset_defs, grid_size, Vector3.ONE, Vector3.ZERO, {
		"write_accepted_placements_to_gpu_runtime": true,
		"candidate_voxel_regions_by_asset": {
			0: [],
		},
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "gpu_route_buffers",
	})
	if not bool(blocked_cpu_route.get("contract_blocked", false)) or bool(blocked_cpu_route.get("ok", true)):
		push_error("[VoxelCandidateRouting] Missing runtime/profile contract should produce blocked multi-asset output")
		return false
	var contract: Dictionary = blocked_cpu_route.get("gpu_runtime_profile_contract", {})
	if str(contract.get("reason", "")) != "missing_gpu_runtime_profile_contract":
		push_error("[VoxelCandidateRouting] Blocked multi-asset output should preserve missing contract reason")
		return false
	if str(blocked_cpu_route.get("candidate_route_readback_source", "")) != "gpu_vote_buffer_readback":
		push_error("[VoxelCandidateRouting] Blocked common CPU route dictionaries must keep readback source gpu_vote_buffer_readback")
		return false
	if str(blocked_cpu_route.get("candidate_route_runtime_read_source", "")) != "cpu_debug_bridge":
		push_error("[VoxelCandidateRouting] Blocked common CPU route dictionaries must keep runtime source cpu_debug_bridge")
		return false
	var asset_results: Array = blocked_cpu_route.get("asset_results", [])
	if asset_results.size() != 1 or not bool((asset_results[0] as Dictionary).get("contract_blocked", false)):
		push_error("[VoxelCandidateRouting] Blocked multi-asset output should annotate each asset as contract_blocked")
		return false

	var blocked_metadata_only := generator.run_multi_asset(scene, collision, asset_defs, grid_size, Vector3.ONE, Vector3.ZERO, {
		"write_accepted_placements_to_gpu_runtime": true,
		"candidate_route_readback_source": "resident_route_snapshot",
		"candidate_route_runtime_read_source": "gpu_route_buffers",
	})
	if not bool(blocked_metadata_only.get("contract_blocked", false)):
		push_error("[VoxelCandidateRouting] Metadata-only blocked multi-asset output should still expose the contract block")
		return false
	if str(blocked_metadata_only.get("candidate_route_readback_source", "")) != "none":
		push_error("[VoxelCandidateRouting] Blocked metadata-only fake labels must not claim a resident readback source")
		return false
	if str(blocked_metadata_only.get("candidate_route_runtime_read_source", "")) != "none":
		push_error("[VoxelCandidateRouting] Blocked metadata-only fake labels must not claim a resident runtime source")
		return false

	print("[VoxelCandidateRouting] blocked multi-asset route source gate OK")
	return true


func _test_scene_placement_asset_defs_keep_route_in_common_settings() -> bool:
	var actor := SPA.new()
	var descriptor := AutoVoxelDescriptorScript.new()
	actor._registered_descriptors = [descriptor]
	actor._registered_profile_ids = [42]

	var asset_defs: Array = actor._build_placement_asset_defs()
	if asset_defs.size() != 1:
		push_error("[VoxelCandidateRouting] ScenePlacementActor should build one asset_def")
		return false

	var asset_def: Dictionary = asset_defs[0]
	if int(asset_def.get("asset_index", -1)) != 0 or int(asset_def.get("profile_id", -1)) != 42:
		push_error("[VoxelCandidateRouting] ScenePlacementActor asset_def should keep asset identity/profile data")
		return false
	for route_key in [
		"candidate_voxel_regions",
		"candidate_voxel_sparses",
		"candidate_route_readback_source",
		"candidate_route_runtime_read_source",
	]:
		if asset_def.has(route_key):
			push_error("[VoxelCandidateRouting] ScenePlacementActor asset_def should not carry %s; route stays in common_settings" % route_key)
			return false

	print("[VoxelCandidateRouting] ScenePlacementActor route handoff boundary OK")
	return true


func _test_scene_placement_pipeline_reports_normalized_route_source() -> bool:
	var actor := SPA.new()
	if not actor.initialize(true, false):
		print("[VoxelCandidateRouting] SKIP: no RenderingDevice for ScenePlacementActor route source boundary")
		return true

	var descriptor := AutoVoxelDescriptorScript.new()
	descriptor.asset_id = "candidate_route_source_boundary"
	descriptor.set_collision([{
		"voxel": Vector3i.ZERO,
		"collision_strength": 1.0,
		"weight": 1.0,
	}])
	var profile_id := actor.register_asset(descriptor)
	if profile_id < 0:
		actor.dispose(true)
		push_error("[VoxelCandidateRouting] ScenePlacementActor should register route boundary descriptor")
		return false

	var fake_prefilter := FakeRouteSourcePrefilter.new()
	actor._prefilter = fake_prefilter
	var grid_size := Vector3i(1, 1, 1)
	var scene := PackedFloat32Array([0.0])
	var collision := PackedFloat32Array([0.0])
	var result := actor.run_placement_pipeline({
		"grid_size": grid_size,
		"voxel_size": Vector3.ONE,
		"grid_origin": Vector3.ZERO,
		"scene_field": scene,
		"collision_field": collision,
	}, [], 1, {}).duplicate(true)
	actor.dispose(true)

	if not bool(result.get("ok", false)):
		push_error("[VoxelCandidateRouting] ScenePlacementActor route source boundary should complete: %s" % str(result))
		return false
	var placement: Dictionary = result.get("placement_result", {})
	if str(placement.get("candidate_route_readback_source", "")) != "gpu_vote_buffer_readback" \
	   or str(placement.get("candidate_route_runtime_read_source", "")) != "cpu_debug_bridge":
		push_error("[VoxelCandidateRouting] VPG should normalize fake prefilter route source labels at placement boundary")
		return false
	if str(result.get("candidate_route_readback_source", "")) != "gpu_vote_buffer_readback" \
	   or str(result.get("candidate_route_runtime_read_source", "")) != "cpu_debug_bridge":
		push_error("[VoxelCandidateRouting] ScenePlacementActor last pipeline route metadata must mirror VPG-normalized CPU route source labels")
		return false
	if not _assert_route_input_contract(
		result,
		"ScenePlacementActor pipeline fake prefilter CPU route dictionary",
		"common_cpu_dictionary",
		true,
		"gpu_vote_buffer_readback",
		"cpu_debug_bridge"
	):
		return false
	var asset_defs: Array = result.get("placement_result", {}).get("asset_results", [])
	if asset_defs.size() != 1:
		push_error("[VoxelCandidateRouting] ScenePlacementActor route source boundary should keep one asset result")
		return false

	print("[VoxelCandidateRouting] ScenePlacementActor normalized route source boundary OK")
	return true


func _test_scene_placement_resident_route_handoff_default() -> bool:
	var actor := SPA.new()
	if not actor.initialize(true, false):
		print("[VoxelCandidateRouting] SKIP: no RenderingDevice for ScenePlacementActor resident route handoff")
		return true
	var runtime := Runtime.new(4, false)
	if not runtime.attach_rendering_device(actor.get_rendering_device(), false):
		runtime.dispose(true)
		actor.dispose(true)
		push_error("[VoxelCandidateRouting] Resident route handoff fixture should attach runtime to SPA RenderingDevice")
		return false
	runtime.configure_capacity(4, true)
	if not runtime.is_gpu_ready():
		runtime.dispose(true)
		actor.dispose(true)
		push_error("[VoxelCandidateRouting] Resident route handoff fixture runtime should be GPU-ready")
		return false
	actor.attach_gpu_runtime(runtime)

	var descriptor := AutoVoxelDescriptorScript.new()
	descriptor.asset_id = "candidate_route_resident_handoff"
	descriptor.set_collision([{
		"voxel": Vector3i.ZERO,
		"collision_strength": 1.0,
		"weight": 1.0,
	}])
	var profile_id := actor.register_asset(descriptor)
	if profile_id < 0:
		runtime.dispose(true)
		actor.dispose(true)
		push_error("[VoxelCandidateRouting] ScenePlacementActor should register resident route handoff descriptor")
		return false

	var fake_prefilter := FakeResidentRoutePrefilter.new()
	if not fake_prefilter.attach_rendering_device(actor.get_rendering_device(), false):
		runtime.dispose(true)
		actor.dispose(true)
		push_error("[VoxelCandidateRouting] Resident route handoff fake prefilter should attach to SPA RenderingDevice")
		return false
	actor._prefilter = fake_prefilter
	var asset_defs: Array = actor._build_placement_asset_defs()
	if asset_defs.is_empty() or not asset_defs[0] is Dictionary or (asset_defs[0] as Dictionary).get("collision", []).is_empty():
		runtime.dispose(true)
		actor.dispose(true)
		push_error("[VoxelCandidateRouting] ScenePlacementActor resident route handoff fixture should pass descriptor collision to VPG: %s" % str(asset_defs))
		return false
	var baked_footprint := VPG.bake_footprint_from_collision(
		(asset_defs[0] as Dictionary).get("collision", []),
		Vector3.ONE
	)
	if baked_footprint.is_empty():
		runtime.dispose(true)
		actor.dispose(true)
		push_error("[VoxelCandidateRouting] ScenePlacementActor resident route handoff fixture collision should bake into a VPG footprint: %s" % str(asset_defs))
		return false
	var result := actor.run_placement_pipeline({
		"grid_size": Vector3i(1, 1, 1),
		"voxel_size": Vector3.ONE,
		"grid_origin": Vector3.ZERO,
		"scene_field": PackedFloat32Array([0.0]),
		"collision_field": PackedFloat32Array([0.0]),
	}, [], 1, {
		"read_candidate_route_sparse_adapter_debug": true,
	}).duplicate(true)
	runtime.dispose(true)
	actor.dispose(true)

	if not bool(result.get("ok", false)):
		push_error("[VoxelCandidateRouting] ScenePlacementActor resident route handoff should complete: %s" % str(result))
		return false
	var placement: Dictionary = result.get("placement_result", {})
	if str(placement.get("candidate_route_readback_source", "")) != "resident_route_snapshot" \
	   or str(placement.get("candidate_route_runtime_read_source", "")) != "resident":
		push_error("[VoxelCandidateRouting] VPG should normalize consumed resident route handoff to resident sources: %s" % str(placement))
		return false
	var contract: Dictionary = placement.get("candidate_route_input_contract", {})
	if str(contract.get("route_input", "")) != "resident_contract" \
	   or not bool(contract.get("resident_route_input_ready", false)) \
	   or str(contract.get("resident_route_owner", "")) != "AutoObjectProbePrefilterGPU":
		push_error("[VoxelCandidateRouting] VPG should report borrowed resident prefilter route contract readiness: %s" % str(contract))
		return false
	if bool(contract.get("cpu_expanded_route_input", true)) \
	   or str(contract.get("rejection_reason", "")) != "none":
		push_error("[VoxelCandidateRouting] Resident handoff must not reach VPG as a CPU-expanded route dictionary: %s" % str(contract))
		return false
	if not bool(contract.get("vpg_binds_route_buffers", false)) \
	   or not bool(contract.get("resident_route_sparse_adapter", false)) \
	   or int(contract.get("vpg_route_buffer_binding_record_reads", 0)) <= 0 \
	   or int(contract.get("vpg_route_buffer_binding_range_reads", 0)) <= 0:
		push_error("[VoxelCandidateRouting] VPG should bind/read resident route buffers in default handoff: %s" % str(contract))
		return false
	var handoff: Dictionary = result.get("resident_candidate_route_handoff", {})
	if not bool(handoff.get("upload_ok", false)) \
	   or not bool(handoff.get("resident_candidate_route_success", false)) \
	   or not bool(handoff.get("vpg_resident_route_input_ready", false)):
		push_error("[VoxelCandidateRouting] SPA resident route handoff success must come from VPG normalized result: %s" % str(handoff))
		return false
	if bool(handoff.get("resident_candidate_route_handoff_opt_in", true)) \
	   or not bool(handoff.get("resident_candidate_route_handoff_defaulted", false)):
		push_error("[VoxelCandidateRouting] SPA should default to resident route handoff without requiring the opt-in setting: %s" % str(handoff))
		return false
	var handoff_contract: Dictionary = handoff.get("contract", {})
	if str(handoff_contract.get("owner", "")) != "AutoObjectProbePrefilterGPU" \
	   or str(handoff_contract.get("producer", "")) != "AutoObjectProbePrefilterGPU" \
	   or str(handoff_contract.get("source_label", "")) != "gpu_vote_buffer_gpu_pack" \
	   or int(handoff_contract.get("resident_route_record_stride", 0)) != 16 \
	   or int(handoff_contract.get("resident_route_range_stride", 0)) != 16:
		push_error("[VoxelCandidateRouting] SPA handoff contract should expose borrowed owner/producer/source/stride: %s" % str(handoff_contract))
		return false
	if not bool(handoff_contract.get("resident_route_buffer_borrowed", false)) \
	   or bool(handoff_contract.get("resident_route_readback_derived", true)) \
	   or bool(handoff_contract.get("cpu_expanded_route_input", true)):
		push_error("[VoxelCandidateRouting] SPA should borrow resident prefilter route RIDs without CPU byte expansion: %s" % str(handoff_contract))
		return false
	if bool(handoff.get("readback_derived", true)) \
	   or not bool(handoff.get("resident_route_buffer_borrowed", false)) \
	   or str(handoff.get("resident_route_buffer_owner", "")) != "AutoObjectProbePrefilterGPU":
		push_error("[VoxelCandidateRouting] SPA handoff summary should report borrowed non-readback route buffers: %s" % str(handoff))
		return false
	if str(result.get("candidate_route_readback_source", "")) != "resident_route_snapshot" \
	   or str(result.get("candidate_route_runtime_read_source", "")) != "resident":
		push_error("[VoxelCandidateRouting] ScenePlacementActor top-level route metadata should mirror VPG-normalized resident route labels")
		return false
	var prefilter_result: Dictionary = result.get("prefilter_result", {})
	if not prefilter_result.has("candidate_voxel_regions_by_asset"):
		push_error("[VoxelCandidateRouting] Prefilter debug dictionary should remain available even when SPA omits it from VPG handoff")
		return false

	print("[VoxelCandidateRouting] ScenePlacementActor resident route handoff default OK")
	return true


class FakeRouteSourcePrefilter:
	extends "res://scripts/autoobject_probe_prefilter_gpu.gd"

	func run_probe_prefilter(
		sv: Dictionary,
		autoobjects: Array,
		dirty_tile_ids: Array[int] = [],
		runtime_profile_container: Object = null,
		target_color_rgba8_bytes: PackedByteArray = PackedByteArray(),
		target_occupancy_bytes: PackedByteArray = PackedByteArray(),
		target_read_buffers: Dictionary = {}
	) -> Dictionary:
		return {
			"ok": true,
			"anchors": [],
			"anchor_autoobject_topk": {},
			"autoobject_candidate_voxel_sparses": {},
			"candidate_voxel_regions_by_asset": {
				0: [],
			},
			"candidate_voxel_sparses_by_asset": {},
			"candidate_route_profiles": [{
				"asset_index": 0,
				"tile_radius": Vector3i.ONE,
			}],
			"candidate_route_readback_source": "resident_route_snapshot",
			"candidate_route_runtime_read_source": "gpu_route_buffers",
			"anchor_count": 0,
			"profile_probe_pack": {},
			"prefilter_reason": "fake_route_source_boundary",
		}


class FakeResidentRoutePrefilter:
	extends "res://scripts/autoobject_probe_prefilter_gpu.gd"

	var _fake_record_rid: RID
	var _fake_range_rid: RID

	func run_probe_prefilter(
		sv: Dictionary,
		autoobjects: Array,
		dirty_tile_ids: Array[int] = [],
		runtime_profile_container: Object = null,
		target_color_rgba8_bytes: PackedByteArray = PackedByteArray(),
		target_occupancy_bytes: PackedByteArray = PackedByteArray(),
		target_read_buffers: Dictionary = {}
	) -> Dictionary:
		var regions := {
			0: [Vector3i.ZERO],
		}
		if _fake_record_rid.is_valid():
			release_rid(_fake_record_rid)
		if _fake_range_rid.is_valid():
			release_rid(_fake_range_rid)
		var record_bytes := PackedByteArray()
		record_bytes.resize(16)
		record_bytes.encode_u32(0, 0)
		var range_bytes := PackedByteArray()
		range_bytes.resize(16)
		range_bytes.encode_u32(0, 0)
		range_bytes.encode_u32(4, 1)
		_fake_record_rid = track_rid(
			_rd.storage_buffer_create(record_bytes.size(), record_bytes),
			KIND_BUFFER,
			SCOPE_PERSISTENT,
			"fake_prefilter_resident_route_records"
		)
		_fake_range_rid = track_rid(
			_rd.storage_buffer_create(range_bytes.size(), range_bytes),
			KIND_BUFFER,
			SCOPE_PERSISTENT,
			"fake_prefilter_resident_route_ranges"
		)
		return {
			"ok": true,
			"anchors": [],
			"anchor_autoobject_topk": {},
			"autoobject_candidate_voxel_sparses": regions,
			"candidate_voxel_regions_by_asset": regions,
			"candidate_voxel_sparses_by_asset": regions,
			"candidate_route_profiles": [{
				"asset_index": 0,
				"tile_radius": Vector3i.ZERO,
			}],
			"candidate_route_readback_source": "gpu_vote_buffer_readback",
			"candidate_route_runtime_read_source": "cpu_debug_bridge",
			"candidate_route_input_contract": {},
			"candidate_route_handoff_payload": {
				"ok": _fake_record_rid.is_valid() and _fake_range_rid.is_valid(),
				"reason": "ok",
				"source": "gpu_vote_buffer_gpu_pack",
				"source_label": "gpu_vote_buffer_gpu_pack",
				"producer": "AutoObjectProbePrefilterGPU",
				"schema_version": 1,
				"resident_route_schema_version": 1,
				"record_stride_bytes": 16,
				"range_stride_bytes": 16,
				"resident_route_record_stride_bytes": 16,
				"resident_route_range_stride_bytes": 16,
				"resident_route_record_rid": _fake_record_rid,
				"resident_route_range_rid": _fake_range_rid,
				"resident_route_record_rid_valid": _fake_record_rid.is_valid(),
				"resident_route_range_rid_valid": _fake_range_rid.is_valid(),
				"resident_route_record_capacity": 1,
				"resident_route_record_count": 1,
				"resident_route_range_count": 1,
				"record_count": 1,
				"range_count": 1,
				"asset_count": 1,
				"record_bytes": PackedByteArray(),
				"range_bytes": PackedByteArray(),
				"has_records": true,
				"resident_route_buffer_owner": "AutoObjectProbePrefilterGPU",
				"resident_route_owner": "AutoObjectProbePrefilterGPU",
				"resident_route_producer": "AutoObjectProbePrefilterGPU",
				"resident_route_source_label": "gpu_vote_buffer_gpu_pack",
				"resident_route_buffer_lifetime": "AutoObjectProbePrefilterGPU owned until fake prefilter dispose",
				"same_rendering_device_as_vpg": true,
				"rendering_device_matches_vpg": true,
				"readback_derived": false,
				"debug_readback_derived": false,
				"resident_route_input_ready": true,
				"resident_candidate_route_handoff": true,
				"cpu_expanded_route_input": false,
				"status": "gpu_pack_resident",
				"debug_status": "gpu_route_pack_resident_no_record_range_readback",
			},
			"anchor_count": 0,
			"profile_probe_pack": {},
			"prefilter_reason": "fake_resident_route_handoff",
		}
