extends SceneTree

const Prefilter := preload("res://scripts/autoobject_probe_prefilter_gpu.gd")
const VPG := preload("res://scripts/voxel_placement_generator.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_vote_entries_pack_resident_schema_bytes()
	ok = ok and _test_decode_payload_uses_vote_tile_layout_not_debug_region_repack()
	ok = ok and _test_gpu_route_pack_pass_opt_in_keeps_candidate_set_with_explicit_order()
	if ok:
		print("[AutoObjectProbePrefilterRouteHandoff] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[AutoObjectProbePrefilterRouteHandoff] SOME TESTS FAILED")
		quit(1)


func _has_rendering_device() -> bool:
	if RenderingServer.get_rendering_device() != null:
		return true
	var local_rd := RenderingServer.create_local_rendering_device()
	if local_rd == null:
		return false
	local_rd.free()
	return true


func _test_vote_entries_pack_resident_schema_bytes() -> bool:
	print("[AutoObjectProbePrefilterRouteHandoff] test_vote_entries_pack_resident_schema_bytes...")
	var tile_grid := Vector3i(2, 3, 4)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	var payload := Prefilter.build_candidate_route_handoff_payload_from_vote_entries({
		0: [
			{"tile_id": 13, "score": 0.5},
			{"tile_id": 13, "score": 0.25},
			{"tile_id": 15, "score": 0.75},
			{"tile_id": -1, "score": 1.0},
			{"tile_id": tile_count, "score": 1.0},
		],
		1: [
			{"tile_id": 0, "score": 1.0},
		],
	}, [
		{"asset_index": 0, "tile_radius": Vector3i.ZERO},
		{"asset_index": 1, "tile_radius": Vector3i.ZERO},
	], 3, tile_grid, tile_count)

	if not _assert_payload_contract(payload, 3, 3, tile_count, "gpu_vote_buffer_readback_vote_entries"):
		return false
	if int(payload.get("duplicate_tile_id_count", -1)) != 1 \
	   or int(payload.get("invalid_tile_id_count", -1)) != 2 \
	   or int(payload.get("empty_range_count", -1)) != 1:
		push_error("  FAIL: payload should count duplicate, invalid, and empty route ranges: %s" % str(payload))
		return false

	var record_bytes: PackedByteArray = payload.get("record_bytes", PackedByteArray())
	var range_bytes: PackedByteArray = payload.get("range_bytes", PackedByteArray())
	if record_bytes.size() != 48 or range_bytes.size() != 48:
		push_error("  FAIL: record/range byte sizes should be stride * count")
		return false
	if not _assert_uvec4(record_bytes, 0, [15, 0, 0, 0], "asset 0 first record") \
	   or not _assert_uvec4(record_bytes, 16, [13, 0, 0, 0], "asset 0 second record") \
	   or not _assert_uvec4(record_bytes, 32, [0, 0, 0, 0], "asset 1 first record"):
		return false
	if not _assert_uvec4(range_bytes, 0, [0, 2, 0, 0], "asset 0 range") \
	   or not _assert_uvec4(range_bytes, 16, [2, 1, 0, 0], "asset 1 range") \
	   or not _assert_uvec4(range_bytes, 32, [3, 0, 0, 0], "asset 2 empty range"):
		return false

	print("  OK: canonical record/range byte layout")
	return true


func _test_decode_payload_uses_vote_tile_layout_not_debug_region_repack() -> bool:
	print("[AutoObjectProbePrefilterRouteHandoff] test_decode_payload_uses_vote_tile_layout_not_debug_region_repack...")
	var prefilter := Prefilter.new()
	var tile_grid := Vector3i(2, 3, 4)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	var votes_bytes := PackedByteArray()
	votes_bytes.resize(tile_count * 4)
	votes_bytes.encode_float(13 * 4, 1.0)

	var result := prefilter._decode_results(
		PackedByteArray(),
		votes_bytes,
		0,
		1,
		tile_count,
		{},
		tile_grid,
		[{"asset_index": 0, "tile_radius": Vector3i.ZERO}]
	)
	var debug_regions: Dictionary = result.get("candidate_voxel_regions_by_asset", {})
	var asset_regions: Array = debug_regions.get(0, [])
	if asset_regions.size() != 1 or asset_regions[0] != Vector3i(1, 1, 2):
		prefilter.dispose()
		push_error("  FAIL: CPU debug region dictionary should remain expanded Vector3i data: %s" % str(debug_regions))
		return false

	var payload: Dictionary = result.get("candidate_route_handoff_payload", {})
	if not _assert_payload_contract(payload, 1, 1, tile_count, "gpu_vote_buffer_readback_vote_entries"):
		prefilter.dispose()
		return false
	var record_bytes: PackedByteArray = payload.get("record_bytes", PackedByteArray())
	if record_bytes.size() != 16 or int(record_bytes.decode_u32(0)) != 13:
		prefilter.dispose()
		push_error("  FAIL: route payload should preserve reducer/VPG tile id 13, not repack debug Vector3i as another layout")
		return false
	if str(result.get("candidate_route_runtime_read_source", "")) != "cpu_debug_bridge":
		prefilter.dispose()
		push_error("  FAIL: prefilter runtime source should stay cpu_debug_bridge")
		return false
	var route_contract: Dictionary = result.get("candidate_route_input_contract", {})
	if bool(route_contract.get("resident_route_input_ready", true)):
		prefilter.dispose()
		push_error("  FAIL: producer payload bytes must not mark resident route input ready")
		return false

	print("  OK: decode payload sourced from GPU vote entries")
	prefilter.dispose()
	return true


func _test_gpu_route_pack_pass_opt_in_keeps_candidate_set_with_explicit_order() -> bool:
	print("[AutoObjectProbePrefilterRouteHandoff] test_gpu_route_pack_pass_opt_in_keeps_candidate_set_with_explicit_order...")
	if not _has_rendering_device():
		print("  SKIP: no RenderingDevice available for GPU route pack pass")
		return true

	var tile_grid := Vector3i(3, 1, 1)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	var votes_bytes := PackedByteArray()
	votes_bytes.resize(tile_count * 4)
	votes_bytes.encode_float(2 * 4, 1.0)
	votes_bytes.encode_float(0 * 4, 0.5)
	var route_profiles := [{"asset_index": 0, "tile_radius": Vector3i.ZERO}]

	var prefilter := Prefilter.new()
	prefilter.use_gpu_candidate_route_pack = true
	if not prefilter.ensure_device(true, true):
		prefilter.dispose()
		print("  SKIP: no RenderingDevice available after ensure_device for GPU route pack pass")
		return true
	prefilter._load_shaders(true)
	var readiness: Dictionary = prefilter._pipeline_readiness(true)
	if not bool(readiness.get("all_ready", false)):
		prefilter.dispose()
		push_error("  FAIL: route pack shader pipeline should be ready: %s" % str(readiness))
		return false
	var votes_buf := prefilter.storage_buffer_from_bytes(votes_bytes)
	var gpu_payload: Dictionary = prefilter._run_candidate_route_gpu_pack_pass(
		votes_buf,
		route_profiles,
		tile_grid,
		tile_count,
		1
	)
	if not bool(gpu_payload.get("ok", false)):
		prefilter.dispose()
		push_error("  FAIL: GPU route pack payload should be ready: %s" % str(gpu_payload))
		return false
	if not _assert_resident_payload_contract(gpu_payload, 2, 1, tile_count, "gpu_dense_vote_buffer", "gpu_vote_buffer_gpu_pack"):
		prefilter.dispose()
		return false
	if bool(gpu_payload.get("cpu_expanded_route_input", true)) \
			or bool(gpu_payload.get("readback_derived", true)) \
			or not bool(gpu_payload.get("resident_route_input_ready", false)):
		prefilter.dispose()
		push_error("  FAIL: GPU route pack handoff should be resident, not CPU-expanded/readback-derived: %s" % str(gpu_payload))
		return false
	if bool(gpu_payload.get("score_order_preserved", true)) \
			or str(gpu_payload.get("ordering_contract", "")) != "candidate_set_equivalent_not_score_sorted":
		prefilter.dispose()
		push_error("  FAIL: GPU route pack must explicitly report non-score order: %s" % str(gpu_payload))
		return false
	var runtime_record_bytes: PackedByteArray = gpu_payload.get("record_bytes", PackedByteArray())
	var runtime_range_bytes: PackedByteArray = gpu_payload.get("range_bytes", PackedByteArray())
	if not runtime_record_bytes.is_empty() or not runtime_range_bytes.is_empty():
		prefilter.dispose()
		push_error("  FAIL: runtime GPU route pack should not read back record/range bytes unless explicitly requested")
		return false

	var cpu_payload := Prefilter.build_candidate_route_handoff_payload_from_vote_entries(
		{0: [{"tile_id": 2, "score": 1.0}, {"tile_id": 0, "score": 0.5}]},
		route_profiles,
		1,
		tile_grid,
		tile_count
	)
	var cpu_record_bytes: PackedByteArray = cpu_payload.get("record_bytes", PackedByteArray())
	if int(cpu_record_bytes.decode_u32(0)) != 2 or int(cpu_record_bytes.decode_u32(16)) != 0:
		prefilter.dispose()
		push_error("  FAIL: CPU default pack should remain score-sorted [2, 0], got bytes=%s" % str(cpu_record_bytes))
		return false

	var decode_prefilter := Prefilter.new()
	var result := decode_prefilter._decode_results(
		PackedByteArray(),
		PackedByteArray(),
		0,
		1,
		tile_count,
		{},
		tile_grid,
		route_profiles,
		{},
		{},
		{},
		gpu_payload,
		false
	)
	var selected_payload: Dictionary = result.get("candidate_route_handoff_payload", {})
	if str(selected_payload.get("source_label", "")) != "gpu_vote_buffer_gpu_pack" \
			or not bool(selected_payload.get("gpu_route_pack_used", false)):
		decode_prefilter.dispose()
		prefilter.dispose()
		push_error("  FAIL: decode should select successful opt-in GPU route payload: %s" % str(selected_payload))
		return false
	if bool(selected_payload.get("cpu_expanded_route_input", true)) \
			or bool(selected_payload.get("readback_derived", true)) \
			or str(result.get("candidate_route_runtime_read_source", "")) != "resident":
		decode_prefilter.dispose()
		prefilter.dispose()
		push_error("  FAIL: selected GPU payload should stay resident and non-CPU-expanded: %s" % str(result))
		return false
	var route_contract: Dictionary = result.get("candidate_route_input_contract", {})
	if str(route_contract.get("route_input", "")) == "common_cpu_dictionary" \
			or bool(route_contract.get("cpu_expanded_route_input", true)):
		decode_prefilter.dispose()
		prefilter.dispose()
		push_error("  FAIL: route contract should not describe the GPU handoff as CPU-expanded: %s" % str(route_contract))
		return false
	var debug_regions: Dictionary = result.get("candidate_voxel_regions_by_asset", {})
	if not debug_regions.is_empty() \
			or not (result.get("candidate_route_cpu_handoff_payload", {}) as Dictionary).is_empty() \
			or bool(result.get("candidate_route_cpu_debug_readback_performed", true)):
		decode_prefilter.dispose()
		prefilter.dispose()
		push_error("  FAIL: resident GPU route handoff should not CPU-expand dense vote debug by default: %s" % str(result))
		return false

	var debug_decode_result := decode_prefilter._decode_results(
		PackedByteArray(),
		votes_bytes,
		0,
		1,
		tile_count,
		{},
		tile_grid,
		route_profiles,
		{},
		{},
		{},
		gpu_payload,
		true
	)
	var debug_regions_explicit: Dictionary = debug_decode_result.get("candidate_voxel_regions_by_asset", {})
	var debug_cpu_payload: Dictionary = debug_decode_result.get("candidate_route_cpu_handoff_payload", {})
	if debug_regions_explicit.is_empty() \
			or not debug_regions_explicit.has(0) \
			or debug_cpu_payload.is_empty() \
			or not bool(debug_decode_result.get("candidate_route_cpu_debug_readback_performed", false)):
		decode_prefilter.dispose()
		prefilter.dispose()
		push_error("  FAIL: explicit CPU route debug readback should still expand route dictionaries: %s" % str(debug_decode_result))
		return false
	if str(debug_decode_result.get("candidate_route_runtime_read_source", "")) != "resident" \
			or bool((debug_decode_result.get("candidate_route_handoff_payload", {}) as Dictionary).get("cpu_expanded_route_input", true)):
		decode_prefilter.dispose()
		prefilter.dispose()
		push_error("  FAIL: explicit CPU debug expansion must not replace resident GPU runtime handoff: %s" % str(debug_decode_result))
		return false

	var debug_payload: Dictionary = prefilter._run_candidate_route_gpu_pack_pass(
		votes_buf,
		route_profiles,
		tile_grid,
		tile_count,
		1,
		true
	)
	if not bool(debug_payload.get("ok", false)):
		decode_prefilter.dispose()
		prefilter.dispose()
		push_error("  FAIL: GPU route pack debug payload should be ready: %s" % str(debug_payload))
		return false
	var gpu_record_bytes: PackedByteArray = debug_payload.get("record_bytes", PackedByteArray())
	if gpu_record_bytes.size() != 32 or int(gpu_record_bytes.decode_u32(0)) != 0 or int(gpu_record_bytes.decode_u32(16)) != 2:
		decode_prefilter.dispose()
		prefilter.dispose()
		push_error("  FAIL: GPU route pack debug readback should emit deterministic tile-id order [0, 2], got bytes=%s" % str(gpu_record_bytes))
		return false

	decode_prefilter.dispose()
	prefilter.dispose()
	print("  OK: GPU payload candidate set matches while ordering metadata stays explicit")
	return true


func _assert_payload_contract(
	payload: Dictionary,
	expected_records: int,
	expected_ranges: int,
	expected_tile_count: int,
	expected_pack_input_source: String,
	expected_source_label: String = "gpu_vote_buffer_readback_cpu_pack"
) -> bool:
	if int(payload.get("schema_version", 0)) != VPG.CANDIDATE_ROUTE_CONTRACT_SCHEMA_VERSION \
	   or int(payload.get("resident_route_schema_version", 0)) != VPG.CANDIDATE_ROUTE_CONTRACT_SCHEMA_VERSION:
		push_error("  FAIL: route payload schema version should match resident route schema")
		return false
	if int(payload.get("record_stride_bytes", 0)) != VPG.CANDIDATE_ROUTE_RECORD_STRIDE_BYTES \
	   or int(payload.get("range_stride_bytes", 0)) != VPG.CANDIDATE_ROUTE_RANGE_STRIDE_BYTES:
		push_error("  FAIL: route payload strides should match resident route schema")
		return false
	if int(payload.get("record_count", -1)) != expected_records \
	   or int(payload.get("range_count", -1)) != expected_ranges \
	   or int(payload.get("tile_count", -1)) != expected_tile_count:
		push_error("  FAIL: route payload counts mismatch: %s" % str(payload))
		return false
	if str(payload.get("source_label", "")) != expected_source_label \
	   or str(payload.get("pack_input_source", "")) != expected_pack_input_source:
		push_error("  FAIL: route payload should identify producer pack input/source: %s" % str(payload))
		return false
	if not bool(payload.get("readback_derived", false)) \
	   or bool(payload.has("resident_route_record_rid")) \
	   or bool(payload.has("resident_route_range_rid")):
		push_error("  FAIL: route payload should be readback-derived bytes, not live resident RIDs")
		return false
	return true


func _assert_resident_payload_contract(
	payload: Dictionary,
	expected_records: int,
	expected_ranges: int,
	expected_tile_count: int,
	expected_pack_input_source: String,
	expected_source_label: String
) -> bool:
	if int(payload.get("schema_version", 0)) != VPG.CANDIDATE_ROUTE_CONTRACT_SCHEMA_VERSION \
	   or int(payload.get("resident_route_schema_version", 0)) != VPG.CANDIDATE_ROUTE_CONTRACT_SCHEMA_VERSION:
		push_error("  FAIL: resident route payload schema version should match resident route schema")
		return false
	if int(payload.get("record_stride_bytes", 0)) != VPG.CANDIDATE_ROUTE_RECORD_STRIDE_BYTES \
	   or int(payload.get("range_stride_bytes", 0)) != VPG.CANDIDATE_ROUTE_RANGE_STRIDE_BYTES:
		push_error("  FAIL: resident route payload strides should match resident route schema")
		return false
	if int(payload.get("record_count", -1)) != expected_records \
	   or int(payload.get("range_count", -1)) != expected_ranges \
	   or int(payload.get("tile_count", -1)) != expected_tile_count:
		push_error("  FAIL: resident route payload counts mismatch: %s" % str(payload))
		return false
	if str(payload.get("source_label", "")) != expected_source_label \
	   or str(payload.get("pack_input_source", "")) != expected_pack_input_source:
		push_error("  FAIL: resident route payload should identify producer pack input/source: %s" % str(payload))
		return false
	var record_rid: RID = payload.get("resident_route_record_rid", RID())
	var range_rid: RID = payload.get("resident_route_range_rid", RID())
	if not record_rid.is_valid() \
	   or not range_rid.is_valid() \
	   or not bool(payload.get("resident_route_record_rid_valid", false)) \
	   or not bool(payload.get("resident_route_range_rid_valid", false)):
		push_error("  FAIL: resident route payload should expose live record/range RIDs: %s" % str(payload))
		return false
	return true


func _assert_uvec4(bytes: PackedByteArray, offset: int, expected: Array[int], label: String) -> bool:
	for i in range(4):
		var actual := int(bytes.decode_u32(offset + i * 4))
		if actual != expected[i]:
			push_error("  FAIL: %s word %d expected %d got %d" % [label, i, expected[i], actual])
			return false
	return true
