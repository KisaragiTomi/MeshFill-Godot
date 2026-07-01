extends SceneTree

const Prefilter := preload("res://scripts/autoobject_probe_prefilter_gpu.gd")
const ProbeProfile := preload("res://scripts/semantic_probe_profile.gd")
const RuntimeProfileContainerScript := preload("res://scripts/auto_voxel_runtime_profile_container.gd")
const ScenePlacementActorScript := preload("res://scripts/scene_placement_actor.gd")
const TestUtils := preload("res://scripts/utils/test_utils.gd")
const AutoObjectScript := preload("res://scripts/auto_object.gd")
const SceneVoxelFixture := preload("res://scripts/utils/scene_voxel_fixture.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_position_only_anchor_layers()
	ok = ok and _test_candidate_routes_expand_for_probe_footprint_context_guard()
	ok = ok and _test_candidate_route_profile_debug_schema()
	ok = ok and _test_prefilter_dispatch_bounds_helpers()
	ok = ok and _test_prefilter_decode_output_contract()
	ok = ok and _test_scene_voxel_tile_dirty_bounds_feed_shader_tile_ids()
	ok = ok and _test_probe_expected_rgba8_repacked_for_shader()
	ok = ok and _test_prefilter_borrows_scene_placement_actor_target_read_buffers_or_blocks()
	ok = ok and _test_prefilter_output_reports_gpu_profile_probe_contract()
	ok = ok and _test_profile_pack_block_reasons_fail_contract()
	ok = ok and _test_pipeline_readiness_contract()
	ok = ok and _test_prefilter_borrows_profile_container_probe_records_or_skip()
	if ok:
		print("[AutoObjectProbePrefilter] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[AutoObjectProbePrefilter] SOME TESTS FAILED")
		quit(1)


func _test_position_only_anchor_layers() -> bool:
	print("[AutoObjectProbePrefilter] test_position_only_anchor_layers...")
	if not TestUtils.has_rendering_device():
		print("  SKIP: no RenderingDevice available for GPU-only anchor collection")
		return true
	var grid_size := Vector3i(16, 8, 16)
	var voxel_size := Vector3.ONE
	var sv := SceneVoxelFixture.make_flat_ground_sv(grid_size, voxel_size)

	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var target_field := PackedFloat32Array()
	target_field.resize(voxel_count * 4)
	for i in range(voxel_count):
		target_field[i * 4 + 0] = 0.4
		target_field[i * 4 + 1] = 0.4
		target_field[i * 4 + 2] = 0.4
		target_field[i * 4 + 3] = 0.0

	for z in range(4, 8):
		for x in range(4, 8):
			target_field[(x + grid_size.x * (z + grid_size.z * 1)) * 4 + 3] = 1.0
			target_field[(x + grid_size.x * (z + grid_size.z * 4)) * 4 + 3] = 1.0

	var supported_asset := AutoObjectScript.new()
	supported_asset.name = "supported_asset"
	supported_asset.set_semantic_probes([
		ProbeProfile.make_probe(Vector3.ZERO, Color.WHITE, 1.0, 0.0, 0.0, 1.0, "test")
	])

	var upper_asset := AutoObjectScript.new()
	upper_asset.name = "upper_asset"
	upper_asset.set_pivot_variants([{"name": "middle", "offset": Vector3(0.0, 3.0, 0.0), "score_bias": 0.0}])
	upper_asset.set_semantic_probes([
		ProbeProfile.make_probe(Vector3(0.0, 3.0, 0.0), Color.WHITE, 1.0, 0.0, 0.0, 1.0, "test")
	])

	var prefilter := Prefilter.new()
	prefilter.min_prefilter_score = 0.9
	var result: Dictionary = prefilter.run_probe_prefilter(
		sv,
		[supported_asset, upper_asset],
		Prefilter.all_tile_ids(sv),
		null,
		target_field,
		{"debug_read_candidate_route_cpu_expansion": true}
	)
	var anchors: Array = result.get("anchors", [])
	if anchors.is_empty():
		prefilter.dispose()
		supported_asset.free()
		upper_asset.free()
		push_error("  FAIL: expected position-only anchors")
		return false

	var has_supported_position := false
	for anchor in anchors:
		if not anchor is Dictionary:
			continue
		if (anchor as Dictionary).has("anchor_kind"):
			prefilter.dispose()
			supported_asset.free()
			upper_asset.free()
			push_error("  FAIL: position-only anchor should not carry anchor_kind")
			return false
		var voxel_pos := (anchor as Dictionary).get("voxel_pos", Vector3i(-1, -1, -1)) as Vector3i
		if voxel_pos.y == 1:
			has_supported_position = true
	if not has_supported_position:
		prefilter.dispose()
		supported_asset.free()
		upper_asset.free()
		push_error("  FAIL: expected supported position-only anchor candidates")
		return false

	# Candidate voxel regions now live in resident GPU route buffers (no CPU
	# readback), so this test only validates the position-only anchor readback.
	prefilter.dispose()
	supported_asset.free()
	upper_asset.free()
	print("  OK: anchors=%d position-only supported_y=true" % [
		anchors.size(),
	])
	return true
func _test_candidate_routes_expand_for_probe_footprint_context_guard() -> bool:
	print("[AutoObjectProbePrefilter] test_candidate_routes_expand_for_probe_footprint_context_guard...")
	var profile := Prefilter._build_route_profile_from_arrays(
		[
			ProbeProfile.make_probe(Vector3(9.0, 0.0, 0.0), Color.WHITE, 0.0, 1.0, 0.0, 0.0, "test"),
		],
		[
			{"shape": "box", "size": Vector3(1.0, 1.0, 1.0), "collision_strength": 1.0},
		],
		Vector3.ONE,
		2.0,
		0
	)
	var tile_radius: Vector3i = profile.get("tile_radius", Vector3i.ZERO)
	if tile_radius.x < 2:
		push_error("  FAIL: expected probe/context route expansion on X, got %s" % str(tile_radius))
		return false
	if tile_radius.y < 1 or tile_radius.z < 1:
		push_error("  FAIL: interpolation guard should expand neighboring voxel regions, got %s" % str(tile_radius))
		return false
	if int(profile.get("interpolation_guard_voxels", 0)) < 1:
		push_error("  FAIL: interpolation guard must be at least 1 voxel")
		return false

	print("  OK: tile_radius=%s interpolation_guard=%d" % [str(tile_radius), int(profile.get("interpolation_guard_voxels", 0))])
	return true


func _test_candidate_route_profile_debug_schema() -> bool:
	print("[AutoObjectProbePrefilter] test_candidate_route_profile_debug_schema...")
	var profile := Prefilter._build_route_profile_from_arrays(
		[
			ProbeProfile.make_probe(Vector3(0.0, 2.0, -3.0), Color.WHITE, 0.0, 1.0, 0.0, 0.0, "schema"),
		],
		[
			{"shape": "box", "size": Vector3(2.0, 1.0, 2.0), "collision_strength": 1.0},
		],
		Vector3.ONE,
		1.5,
		7
	)
	for key in [
		"asset_index",
		"probe_min",
		"probe_max",
		"footprint_min",
		"footprint_max",
		"context_radius_voxels",
		"interpolation_guard_voxels",
		"tile_radius",
	]:
		if not profile.has(key):
			push_error("  FAIL: route profile missing key %s" % key)
			return false
	if int(profile.get("asset_index", -1)) != 7:
		push_error("  FAIL: route profile should preserve asset_index")
		return false
	if not profile.get("probe_min", null) is Vector3i or not profile.get("probe_max", null) is Vector3i:
		push_error("  FAIL: route profile probe bounds should be Vector3i")
		return false
	if not profile.get("footprint_min", null) is Vector3i or not profile.get("footprint_max", null) is Vector3i:
		push_error("  FAIL: route profile footprint bounds should be Vector3i")
		return false
	if not profile.get("context_radius_voxels", null) is Vector3i or not profile.get("tile_radius", null) is Vector3i:
		push_error("  FAIL: route profile context/tile radius should be Vector3i")
		return false
	if int(profile.get("interpolation_guard_voxels", 0)) < 1:
		push_error("  FAIL: route profile interpolation guard should be at least 1")
		return false
	print("  OK: route profile schema keys=%d" % profile.keys().size())
	return true


func _test_prefilter_dispatch_bounds_helpers() -> bool:
	print("[AutoObjectProbePrefilter] test_prefilter_dispatch_bounds_helpers...")
	if Prefilter._ceil_div_positive(17, 8) != 3 or Prefilter._ceil_div_positive(0, 8) != 0:
		push_error("  FAIL: ceil_div helper should clamp non-positive values and round positive values up")
		return false
	var dispatch_groups := Prefilter._linear_dispatch_groups(Prefilter.PREFILTER_DISPATCH_AXIS_LIMIT + 7)
	if dispatch_groups != Vector3i(Prefilter.PREFILTER_DISPATCH_AXIS_LIMIT, 2, 1):
		push_error("  FAIL: linear dispatch should split oversized work over X/Y, got %s" % str(dispatch_groups))
		return false
	var anchor_dispatch := Prefilter._anchor_dispatch_groups(Prefilter.ANCHOR_CAPACITY + 4096)
	if anchor_dispatch == Vector3i.ZERO \
			or anchor_dispatch.x * anchor_dispatch.y < Prefilter.ANCHOR_CAPACITY \
			or anchor_dispatch.x > Prefilter.PREFILTER_DISPATCH_AXIS_LIMIT \
			or anchor_dispatch.y > Prefilter.PREFILTER_DISPATCH_AXIS_LIMIT:
		push_error("  FAIL: anchor dispatch should clamp to buffer capacity and stay within axis limits: %s" % str(anchor_dispatch))
		return false
	var asset_blocks := Prefilter._score_asset_block_dispatch_groups(Prefilter.MAX_ASSETS + 1)
	if asset_blocks != 16:
		push_error("  FAIL: asset-block dispatch should ceil-div and clamp to MAX_ASSETS, got %d" % asset_blocks)
		return false
	var sanitized := Prefilter._sanitize_prefilter_tile_ids([0, 0, 3, -1, 4, 999], 4)
	if sanitized != [0, 3]:
		push_error("  FAIL: dirty tile sanitizer should drop invalid ids and duplicates, got %s" % str(sanitized))
		return false
	print("  OK: dispatch_groups=%s anchor_groups=%s asset_blocks=%s sanitized=%s" % [
		str(dispatch_groups),
		str(anchor_dispatch),
		str(asset_blocks),
		str(sanitized),
	])
	return true

# _test_candidate_route_handoff_payload_schema was removed: the CPU-side
# build_candidate_route_handoff_payload packer no longer exists — candidate route
# records/ranges are now packed into resident GPU route buffers, so there is no
# CPU byte layout left to assert here.


func _test_prefilter_decode_output_contract() -> bool:
	print("[AutoObjectProbePrefilter] test_prefilter_decode_output_contract...")
	var prefilter := Prefilter.new()
	var anchors_bytes := PackedByteArray()
	anchors_bytes.resize(16)
	anchors_bytes.encode_u32(0, 1)
	anchors_bytes.encode_u32(4, 0)
	anchors_bytes.encode_u32(8, 1)
	anchors_bytes.encode_u32(12, 0)

	var asset_count := 2
	var tile_count := 4
	var result := prefilter._decode_results(
		anchors_bytes,
		1,
		asset_count,
		tile_count,
		{},
		Vector3i(2, 1, 2),
		[
			Prefilter._empty_route_profile(0),
			Prefilter._empty_route_profile(1),
		]
	)

	# Candidate voxel regions now live in resident GPU route buffers, so the CPU
	# decode exposes only empty debug aliases plus the resident route sources.
	for key in [
		"autoobject_candidate_voxel_sparses",
		"candidate_voxel_regions_by_asset",
		"candidate_voxel_sparses_by_asset",
	]:
		var alias = result.get(key, null)
		if not alias is Dictionary or not (alias as Dictionary).is_empty():
			push_error("  FAIL: %s should be an empty resident-route alias, got %s" % [key, str(alias)])
			return false
	if str(result.get("candidate_route_readback_source", "")) != "resident_route_snapshot":
		push_error("  FAIL: decode output should name the resident route snapshot readback source")
		return false
	if str(result.get("candidate_route_runtime_read_source", "")) != "resident":
		push_error("  FAIL: decode output route runtime source should be resident")
		return false
	if bool(result.get("cpu_fallback", true)) or not bool(result.get("gpu_first", false)):
		push_error("  FAIL: decode output must stay GPU-first with no CPU fallback")
		return false

	var profiles: Array = result.get("candidate_route_profiles", [])
	if profiles.size() != asset_count:
		push_error("  FAIL: expected one candidate_route_profiles entry per asset")
		return false
	for asset_id in range(asset_count):
		if not profiles[asset_id] is Dictionary \
		   or int((profiles[asset_id] as Dictionary).get("asset_index", -1)) != asset_id:
			push_error("  FAIL: candidate_route_profiles[%d] should carry asset_index=%d" % [asset_id, asset_id])
			return false

	var anchors: Array = result.get("anchors", [])
	if anchors.size() != 1 or (anchors[0] as Dictionary).get("voxel_pos", Vector3i.ZERO) != Vector3i(1, 0, 1):
		push_error("  FAIL: anchor readback should remain position-only")
		return false
	if (anchors[0] as Dictionary).has("anchor_kind"):
		push_error("  FAIL: anchor debug readback should not expose anchor_kind")
		return false

	print("  OK: empty resident aliases profiles=%d anchors=%d" % [profiles.size(), anchors.size()])
	prefilter.dispose()
	return true


func _test_scene_voxel_tile_dirty_bounds_feed_shader_tile_ids() -> bool:
	print("[AutoObjectProbePrefilter] test_scene_voxel_tile_dirty_bounds_feed_shader_tile_ids...")
	var prefilter := Prefilter.new()
	var tile_grid := Vector3i(3, 2, 3)
	var sv := {
		"tile_grid_size": tile_grid,
		"total_tiles": tile_grid.x * tile_grid.y * tile_grid.z,
		# Tier 2: _dirty_tile_ids_from_sv reads only dirty_scene_voxel_tiles (B); the
		# legacy dirty_tiles (A) map is no longer consumed, so all expected tile ids
		# below come purely from these SceneVoxelTile voxel bounds.
		"dirty_scene_voxel_tiles": {
			"scene_a": {
				"voxel_min": Vector3i(7, 0, 7),
				"voxel_max": Vector3i(9, 1, 9),
			},
			"scene_b": {
				"voxel_min": [16, 8, 0],
				"voxel_max": {"x": 24, "y": 16, "z": 8},
			},
		},
	}
	var ids := prefilter._dirty_tile_ids_from_sv(sv)
	var expected_positions := [
		Vector3i(0, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, 1),
		Vector3i(1, 0, 1),
		Vector3i(2, 1, 0),
	]
	for p in expected_positions:
		var tile_id := Prefilter._tile_pos_to_id(p, tile_grid)
		if ids.find(tile_id) < 0:
			push_error("  FAIL: SceneVoxelTile dirty bounds missing shader tile %s id=%d from %s" % [str(p), tile_id, str(ids)])
			return false
	if ids.size() != expected_positions.size():
		push_error("  FAIL: expected unique shader tile ids from SceneVoxelTile dirty bounds, got %s" % str(ids))
		return false
	print("  OK: SceneVoxelTile dirty bounds mapped to %d shader tile ids" % ids.size())
	prefilter.dispose()
	return true


func _test_probe_expected_rgba8_repacked_for_shader() -> bool:
	print("[AutoObjectProbePrefilter] test_probe_expected_rgba8_repacked_for_shader...")
	var color := Color(0.1, 0.4, 0.7, 0.25)
	var semantic_packed := ProbeProfile.pack_rgba8(color)
	var shader_from_color := Prefilter._shader_rgba8_from_probe({
		"expected_color": color,
		"expected_complexity": color.a,
	})
	var shader_from_semantic := Prefilter._shader_rgba8_from_probe({
		"expected_rgba8": semantic_packed,
	})
	var expected_shader := Prefilter._pack_rgba8(color)
	if shader_from_color != expected_shader:
		push_error("  FAIL: expected_color did not pack to shader byte order")
		return false
	if shader_from_semantic != expected_shader:
		push_error("  FAIL: expected_rgba8 did not convert to shader byte order")
		return false
	if semantic_packed == expected_shader:
		push_error("  FAIL: test color should expose byte-order differences")
		return false
	print("  OK: semantic=0x%x shader=0x%x" % [semantic_packed, expected_shader])
	return true


func _test_prefilter_borrows_scene_placement_actor_target_read_buffers_or_blocks() -> bool:
	print("[AutoObjectProbePrefilter] test_prefilter_borrows_scene_placement_actor_target_read_buffers_or_blocks...")
	if not TestUtils.has_rendering_device():
		print("  SKIP: no RenderingDevice available for GPU-only TargetSV read-buffer borrowing")
		return true

	var grid_size := Vector3i(2, 2, 2)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var color_bytes := PackedByteArray()
	color_bytes.resize(voxel_count * 4)
	for i in range(voxel_count):
		color_bytes.encode_u32(i * 4, 0xC0002000 | i)

	var actor := ScenePlacementActorScript.new()
	var target_buffers := actor.prepare_target_read_buffers_from_common_gpu({
		"target_color_rgba8_bytes": color_bytes,
	}, {"grid_size": grid_size})
	if not bool(target_buffers.get("ok", false)):
		actor.dispose(true)
		push_error("  FAIL: resident TargetSV producer should be ready: %s" % str(target_buffers))
		return false

	var prefilter := Prefilter.new()
	if not prefilter.attach_rendering_device(actor.get_rendering_device(), false):
		prefilter.dispose()
		actor.dispose(true)
		push_error("  FAIL: prefilter should attach actor RenderingDevice for same-RD borrow")
		return false
	var borrowed: Dictionary = prefilter._target_read_buffer_pack(target_buffers, PackedFloat32Array(), voxel_count)
	if not bool(borrowed.get("target_read_buffers_borrowed", false)) \
			or str(borrowed.get("target_read_buffer_source", "")) != "borrowed_scene_placement_actor_resident" \
			or str(borrowed.get("target_read_buffer_ownership", "")) != "borrowed_external" \
			or bool(borrowed.get("cpu_fallback", true)):
		prefilter.dispose()
		actor.dispose(true)
		push_error("  FAIL: same-RD resident buffers should be borrowed without CPU fallback: %s" % str(borrowed))
		return false
	var borrowed_summary := prefilter._target_read_buffer_summary(borrowed)
	if str(borrowed_summary.get("owner", "")) != "ScenePlacementActor" \
			or str(borrowed_summary.get("target_field_buffer_rid", "")) != "valid" \
			or str(borrowed_summary.get("target_read_buffer_lifetime", "")) == "none":
		prefilter.dispose()
		actor.dispose(true)
		push_error("  FAIL: borrowed diagnostics should expose owner/RID/lifetime: %s" % str(borrowed_summary))
		return false
	prefilter.dispose()

	# CPU upload fallback removed: a prefilter on a different RenderingDevice cannot
	# borrow the resident buffer, so it must block explicitly (the pack also calls
	# push_error) instead of uploading CPU bytes.
	var mismatch_prefilter := Prefilter.new()
	if not mismatch_prefilter.ensure_device(true, false):
		mismatch_prefilter.dispose()
		actor.dispose(true)
		print("  SKIP: no second local RenderingDevice available for mismatch block branch")
		return true
	var blocked: Dictionary = mismatch_prefilter._target_read_buffer_pack(target_buffers, PackedFloat32Array(), voxel_count)
	if bool(blocked.get("ready", true)) \
			or not bool(blocked.get("contract_blocked", false)) \
			or str(blocked.get("reason", "")) != "resident_target_read_buffer_rendering_device_mismatch_gpu_resident_required" \
			or bool(blocked.get("target_read_buffers_borrowed", true)) \
			or bool(blocked.get("target_read_buffers_uploaded", true)) \
			or bool(blocked.get("cpu_fallback", true)):
		mismatch_prefilter.dispose()
		actor.dispose(true)
		push_error("  FAIL: RD mismatch must block explicitly with no CPU upload: %s" % str(blocked))
		return false
	mismatch_prefilter.dispose()
	actor.dispose(true)

	print("  OK: same-RD resident target_field buffers are borrowed; RD mismatch blocks (no CPU upload)")
	return true


func _test_prefilter_output_reports_gpu_profile_probe_contract() -> bool:
	print("[AutoObjectProbePrefilter] test_prefilter_output_reports_gpu_profile_probe_contract...")
	var prefilter := Prefilter.new()
	var anchors_bytes := PackedByteArray()
	anchors_bytes.resize(16)
	anchors_bytes.encode_u32(0, 0)
	anchors_bytes.encode_u32(4, 0)
	anchors_bytes.encode_u32(8, 0)
	anchors_bytes.encode_u32(12, 0)
	var result := prefilter._decode_results(
		anchors_bytes,
		1,
		1,
		1,
		{},
		Vector3i.ONE,
		[Prefilter._empty_route_profile(0)],
		{
			"ready": true,
			"probe_data_borrowed": true,
			"probe_source": "auto_voxel_runtime_profile_container.probe_records",
			"profile_ids": [123],
			"total_probes": 4,
		}
	)
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: prefilter output must report no CPU fallback")
		return false
	var summary: Dictionary = result.get("profile_probe_pack", {})
	if not bool(summary.get("ready", false)):
		push_error("  FAIL: profile probe pack summary should be ready")
		return false
	if not bool(summary.get("probe_data_borrowed", false)):
		push_error("  FAIL: profile probe pack summary should expose borrowed probe records")
		return false
	if str(summary.get("runtime_read_source", "")) != "gpu_profile_buffers":
		push_error("  FAIL: borrowed probe pack should report gpu_profile_buffers runtime read source")
		return false
	var borrowed_buffers: Array = summary.get("borrowed_buffers", [])
	if borrowed_buffers.find("probe_records") < 0:
		push_error("  FAIL: borrowed probe summary should name probe_records")
		return false
	var profile_ids: Array = summary.get("profile_ids", [])
	if profile_ids.size() != 1 or int(profile_ids[0]) != 123:
		push_error("  FAIL: profile probe summary should preserve profile ids")
		return false

	var blocked := prefilter._empty_result("missing_rendering_device", {
		"ready": false,
		"reason": "missing_rendering_device",
		"cpu_fallback": false,
		"probe_source": "none",
	})
	if bool(blocked.get("cpu_fallback", true)):
		push_error("  FAIL: blocked prefilter output must not report CPU fallback")
		return false
	if bool(blocked.get("ok", true)):
		push_error("  FAIL: blocked prefilter output should report ok=false")
		return false
	if not bool(blocked.get("contract_blocked", false)):
		push_error("  FAIL: blocked prefilter output should expose contract_blocked=true")
		return false
	if not bool(blocked.get("gpu_first", false)):
		push_error("  FAIL: blocked prefilter output must keep gpu_first=true")
		return false
	if not _assert_blocked_candidate_aliases_empty(blocked, "missing_rendering_device"):
		return false
	var blocked_summary: Dictionary = blocked.get("profile_probe_pack", {})
	if str(blocked.get("prefilter_reason", "")) != "missing_rendering_device" \
	   or str(blocked_summary.get("reason", "")) != "missing_rendering_device":
		push_error("  FAIL: blocked prefilter should preserve no-RD reason")
		return false

	print("  OK: borrowed probe pack and blocked status are explicit GPU-first debug contracts")
	prefilter.dispose()
	return true


func _test_profile_pack_block_reasons_fail_contract() -> bool:
	print("[AutoObjectProbePrefilter] test_profile_pack_block_reasons_fail_contract...")
	var prefilter := Prefilter.new()
	var probe_pack := prefilter._blocked_probe_pack(
		"missing_profile_id_for_asset:0",
		[],
		0,
		Vector3.ONE
	)
	if not bool(probe_pack.get("gpu_first", false)):
		push_error("  FAIL: raw blocked probe pack must keep gpu_first=true")
		return false
	if bool(probe_pack.get("cpu_fallback", true)):
		push_error("  FAIL: raw blocked probe pack must not report CPU fallback")
		return false
	var result: Dictionary = prefilter._empty_result("missing_profile_id_for_asset:0", probe_pack)
	if bool(result.get("ok", true)):
		push_error("  FAIL: missing profile_id block must report ok=false")
		return false
	if not bool(result.get("contract_blocked", false)):
		push_error("  FAIL: missing profile_id block must report contract_blocked=true")
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: missing profile_id block must not report CPU fallback")
		return false
	if not bool(result.get("gpu_first", false)):
		push_error("  FAIL: missing profile_id block must keep gpu_first=true")
		return false
	if not _assert_blocked_candidate_aliases_empty(result, "missing_profile_id_for_asset"):
		return false
	if str(result.get("prefilter_reason", "")) != "missing_profile_id_for_asset:0":
		push_error("  FAIL: missing profile_id block should preserve the exact reason")
		return false
	var summary: Dictionary = result.get("profile_probe_pack", {})
	if bool(summary.get("ok", true)) or bool(summary.get("ready", true)):
		push_error("  FAIL: blocked profile probe pack summary must report ok=false/ready=false")
		return false
	if not bool(summary.get("contract_blocked", false)):
		push_error("  FAIL: blocked profile probe pack summary must report contract_blocked=true")
		return false
	if bool(summary.get("cpu_fallback", true)):
		push_error("  FAIL: blocked profile probe pack summary must not report CPU fallback")
		return false
	if not bool(summary.get("gpu_first", false)):
		push_error("  FAIL: blocked profile probe pack summary must keep gpu_first=true")
		return false
	if str(summary.get("reason", "")) != "missing_profile_id_for_asset:0":
		push_error("  FAIL: blocked profile probe pack summary should preserve exact reason")
		return false
	print("  OK: missing_profile_id_for_asset blocks the GPU-only contract without CPU fallback")
	prefilter.dispose()
	return true


func _test_pipeline_readiness_contract() -> bool:
	print("[AutoObjectProbePrefilter] test_pipeline_readiness_contract...")
	var prefilter := Prefilter.new()
	var readiness: Dictionary = prefilter._pipeline_readiness()
	for pass_name in ["collect", "score", "topk", "reduce"]:
		if not readiness.has(pass_name):
			push_error("  FAIL: pipeline readiness missing pass %s" % pass_name)
			return false
		var pass_status: Dictionary = readiness.get(pass_name, {})
		for key in ["shader_rid_valid", "pipeline_rid_valid", "ready"]:
			if not pass_status.has(key):
				push_error("  FAIL: pipeline readiness pass %s missing key %s" % [pass_name, key])
				return false
	if bool(readiness.get("all_ready", true)):
		push_error("  FAIL: new prefilter without loaded RIDs should not report all_ready")
		return false
	var blocked := prefilter._empty_result("prefilter_shader_pipeline_not_ready", {}, readiness)
	if bool(blocked.get("ok", true)):
		push_error("  FAIL: invalid shader/pipeline RIDs must report ok=false")
		return false
	if not bool(blocked.get("contract_blocked", false)):
		push_error("  FAIL: invalid shader/pipeline RIDs must report contract_blocked=true")
		return false
	var blocked_probe_pack: Dictionary = blocked.get("profile_probe_pack", {})
	if not bool(blocked_probe_pack.get("contract_blocked", false)):
		push_error("  FAIL: blocked empty probe-pack summary must mirror contract_blocked=true")
		return false
	if str(blocked_probe_pack.get("reason", "")) != "prefilter_shader_pipeline_not_ready":
		push_error("  FAIL: blocked empty probe-pack summary should preserve the top-level blocked reason")
		return false
	if not bool(blocked.get("gpu_first", false)):
		push_error("  FAIL: pipeline blocked output must keep gpu_first=true")
		return false
	if not _assert_blocked_candidate_aliases_empty(blocked, "prefilter_shader_pipeline_not_ready"):
		return false
	var blocked_readiness: Dictionary = blocked.get("pipeline_readiness", {})
	if not blocked_readiness.has("collect") or bool(blocked_readiness.get("all_ready", true)):
		push_error("  FAIL: blocked result should expose collect/score/topk/reduce readiness")
		return false
	print("  OK: pipeline readiness exposes collect/score/topk/reduce RID validity")
	prefilter.dispose()
	return true


func _assert_blocked_candidate_aliases_empty(result: Dictionary, label: String) -> bool:
	for key in [
		"autoobject_candidate_voxel_sparses",
		"candidate_voxel_regions_by_asset",
		"candidate_voxel_sparses_by_asset",
	]:
		var value = result.get(key, null)
		if not value is Dictionary:
			push_error("  FAIL: %s blocked output missing dictionary alias %s" % [label, key])
			return false
		if not (value as Dictionary).is_empty():
			push_error("  FAIL: %s blocked output alias %s should be empty" % [label, key])
			return false
	if str(result.get("candidate_route_readback_source", "")) != "none":
		push_error("  FAIL: %s blocked output should not expose candidate route readback source" % label)
		return false
	if str(result.get("candidate_route_runtime_read_source", "")) != "none":
		push_error("  FAIL: %s blocked output should not expose candidate route runtime source" % label)
		return false
	if not _assert_route_input_contract(result, label, "none", "none", "none"):
		return false
	return true


func _assert_route_input_contract(
	result: Dictionary,
	label: String,
	expected_route_input: String,
	expected_readback_source: String,
	expected_runtime_source: String
) -> bool:
	var contract: Dictionary = result.get("candidate_route_input_contract", {})
	if contract.is_empty():
		push_error("  FAIL: %s should expose candidate_route_input_contract diagnostics" % label)
		return false
	if str(contract.get("route_input", "")) != expected_route_input:
		push_error("  FAIL: %s route_input should be %s, got %s" % [label, expected_route_input, str(contract.get("route_input", ""))])
		return false
	if bool(contract.get("resident_route_input_ready", true)):
		push_error("  FAIL: %s should not claim resident route input readiness" % label)
		return false
	if str(contract.get("resident_route_owner", "")) != "none" \
	   or str(contract.get("resident_route_buffer_rid", "")) != "none" \
	   or str(contract.get("resident_route_buffer_lifetime", "")) != "none" \
	   or str(contract.get("debug_snapshot_api", "")) != "none":
		push_error("  FAIL: %s resident owner/RID/lifetime/debug snapshot API should remain unset" % label)
		return false
	if int(contract.get("resident_route_record_stride", -1)) != 0 \
	   or int(contract.get("resident_route_range_count", -1)) != 0:
		push_error("  FAIL: %s resident stride/ranges should remain unset" % label)
		return false
	if str(contract.get("normalized_readback_source", "")) != expected_readback_source \
	   or str(contract.get("normalized_runtime_read_source", "")) != expected_runtime_source:
		push_error("  FAIL: %s normalized route sources should be %s/%s" % [label, expected_readback_source, expected_runtime_source])
		return false
	return true


func _test_prefilter_borrows_profile_container_probe_records_or_skip() -> bool:
	print("[AutoObjectProbePrefilter] test_prefilter_borrows_profile_container_probe_records_or_skip...")
	if not TestUtils.has_rendering_device():
		print("  SKIP: no RenderingDevice available for GPU-only profile probe buffer borrowing")
		return true
	var asset := AutoObjectScript.new()
	asset.name = "borrowed_profile_probe_asset"
	asset.semantic_probe_density = 1.0
	asset.set_semantic_probes([
		ProbeProfile.make_probe(Vector3(1.0, 0.0, 0.0), Color(0.2, 0.3, 0.4, 0.5), 0.25, 2.0, 0.0, 0.0, "borrow"),
	])

	var container = RuntimeProfileContainerScript.new()
	if not container.ensure_device():
		asset.free()
		print("  SKIP: no RenderingDevice available for profile container upload")
		return true
	var profile_id: int = container.register_descriptor(
		asset.voxel_descriptor,
		0.0,
		asset.semantic_probe_density,
		Vector3.ONE,
		asset.mesh
	)
	if profile_id <= 0 or not container.upload_profiles():
		asset.free()
		container.dispose(true)
		push_error("  FAIL: expected runtime profile container upload to succeed")
		return false

	var prefilter := Prefilter.new()
	var pack: Dictionary = prefilter._pack_all_probes([asset], 1, Vector3.ONE, container)
	if not bool(pack.get("ready", false)):
		prefilter.dispose()
		asset.free()
		container.dispose(true)
		push_error("  FAIL: profile container probe pack should be ready: %s" % str(pack))
		return false
	if not bool(pack.get("probe_data_borrowed", false)):
		prefilter.dispose()
		asset.free()
		container.dispose(true)
		push_error("  FAIL: prefilter should borrow profile container probe_records")
		return false
	var borrowed_probe_buffer: RID = pack.get("probe_data_buffer", RID())
	if borrowed_probe_buffer != container.get_probe_buffer():
		prefilter.dispose()
		asset.free()
		container.dispose(true)
		push_error("  FAIL: borrowed probe RID should be the profile container probe_records buffer")
		return false
	var range_bytes: PackedByteArray = pack.get("range_bytes", PackedByteArray())
	var range_words := range_bytes.to_int32_array()
	if range_bytes.size() != 8 or range_words.size() < 2 or int(range_words[0]) != 0 or int(range_words[1]) != 1:
		prefilter.dispose()
		asset.free()
		container.dispose(true)
		push_error("  FAIL: borrowed probe range should map asset 0 to the profile probe_records slice")
		return false
	var profile_ids: Array = pack.get("profile_ids", [])
	if profile_ids.size() != 1 or int(profile_ids[0]) != profile_id:
		prefilter.dispose()
		asset.free()
		container.dispose(true)
		push_error("  FAIL: borrowed probe pack should expose the mapped profile_id")
		return false

	prefilter.dispose()
	container.dispose(true)
	asset.free()
	print("  OK: borrowed profile_id=%d probe_records range=%d:%d" % [
		profile_id,
		int(range_words[0]),
		int(range_words[1]),
	])
	return true
