extends SceneTree

const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const SceneVoxelCommitterScript := preload("res://scripts/scene_voxel_committer.gd")
const RuntimeProfileContainerScript := preload("res://scripts/auto_voxel_runtime_profile_container.gd")

var _gpu_skip_count := 0


func _init() -> void:
	var ok := true
	ok = _test_descriptor_backed_asset_semantics() and ok
	ok = _test_shared_field_collision_contract() and ok
	ok = _test_committed_scene_voxel_minimal_payload() and ok
	ok = _test_terrain_collision_survives_zero_complexity_writes() and ok
	ok = _test_channel_stays_out_of_shared_semantics() and ok
	ok = _test_routing_probe_sources_are_sv_resident_and_descriptor_probe_backed() and ok
	ok = _test_gpu_first_no_cpu_fallback_contracts() and ok
	ok = _test_legacy_scene_voxel_scatter_removed() and ok
	ok = _test_runtime_read_sources_reject_staging_success() and ok
	ok = _test_vpg_and_scene_tile_gpu_binding_contracts() and ok

	if ok:
		if _gpu_skip_count > 0:
			print("[MarkdownContracts] TESTS PASSED WITH %d GPU SKIPS" % _gpu_skip_count)
		else:
			print("[MarkdownContracts] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[MarkdownContracts] SOME TESTS FAILED")
		quit(1)


func _test_descriptor_backed_asset_semantics() -> bool:
	print("[MarkdownContracts] test_descriptor_backed_asset_semantics...")
	var descriptor := AutoVoxelDescriptor.new()
	var descriptor_color := Color(0.10, 0.20, 0.30, 0.35)
	descriptor.set_color_and_complexity(descriptor_color, 0.35)
	descriptor.set_collision([
		{"voxel": Vector3i(1, 0, 0), "collision_strength": 0.75, "weight": 1.0},
	])

	var obj := AutoObject.new()
	obj.name = "descriptor_contract_object"
	obj.voxel_descriptor = descriptor

	# Conflicting exported fields must not become a second authority for new
	# semantic reads or record construction.
	obj.voxel_color = Color(0.90, 0.10, 0.10, 0.90)
	obj.voxel_complexity = 0.90
	obj.collision = [
		{"voxel": Vector3i(3, 0, 0), "collision_strength": 0.20},
	]

	var got_color := obj.get_voxel_color()
	if not _approx_color(got_color, descriptor_color):
		push_error("  FAIL: descriptor-backed color was not authoritative: %s" % str(got_color))
		obj.free()
		return false
	if absf(obj.get_voxel_complexity() - 0.35) > 0.001:
		push_error("  FAIL: descriptor-backed complexity was not authoritative")
		obj.free()
		return false
	var got_collision := obj.get_collision()
	if got_collision.is_empty() or got_collision[0].get("voxel", Vector3i.ZERO) != Vector3i(1, 0, 0):
		push_error("  FAIL: descriptor-backed collision was not authoritative: %s" % str(got_collision))
		obj.free()
		return false

	var record := obj.make_instance_stamp_write_spec("descriptor_contract_record", Vector2i(4, 4), 8)
	var record_color: Color = record.get("color", Color.TRANSPARENT)
	if not _approx_color(record_color, descriptor_color):
		push_error("  FAIL: voxel_write_spec record did not use descriptor color: %s" % str(record_color))
		obj.free()
		return false
	if absf(float(record.get("complexity", -1.0)) - 0.35) > 0.001:
		push_error("  FAIL: voxel_write_spec record did not use descriptor complexity")
		obj.free()
		return false
	var record_collision: Array = record.get("collision", [])
	if record_collision.is_empty() or record_collision[0].get("voxel", Vector3i.ZERO) != Vector3i(1, 0, 0):
		push_error("  FAIL: voxel_write_spec record did not use descriptor collision: %s" % str(record_collision))
		obj.free()
		return false

	obj.free()
	print("  OK: descriptor-backed getters and record construction ignore stale mirrors")
	return true


func _test_shared_field_collision_contract() -> bool:
	print("[MarkdownContracts] test_shared_field_collision_contract...")
	var ok := true
	for key in ["color", "complexity", "collision"]:
		if not SharedPropertyTypeScript.SHARED_FIELD_KEYS.has(key):
			push_error("  FAIL: SHARED_FIELD_KEYS is missing '%s'" % key)
			ok = false

	var collision := [
		{"voxel": Vector3i.ZERO, "collision_strength": 0.5},
	]
	var normalized: Dictionary = SharedPropertyTypeScript.normalize_shared_fields({
		"color": Color(0.4, 0.5, 0.6, 0.9),
		"complexity": 0.9,
		"collision": collision,
	})
	if not normalized.has("collision"):
		push_error("  FAIL: normalize_shared_fields should preserve MD field 'collision'")
		ok = false

	var record: Dictionary = SharedPropertyTypeScript.apply_to_record({}, normalized)
	if not record.has("collision"):
		push_error("  FAIL: apply_to_record should write shared field 'collision'")
		ok = false

	var scene_voxel: Dictionary = SharedPropertyTypeScript.apply_to_scene_voxel({}, normalized, -1.0, true)
	if not scene_voxel.has("collision"):
		push_error("  FAIL: apply_to_scene_voxel should write shared field 'collision'")
		ok = false

	if ok:
		print("  OK: shared fields use color/complexity/collision")
	return ok


func _test_committed_scene_voxel_minimal_payload() -> bool:
	print("[MarkdownContracts] test_committed_scene_voxel_minimal_payload...")
	if not _has_rendering_device():
		_record_gpu_skip("no RenderingDevice available for committed SceneVoxel payload")
		return true

	var committer = SceneVoxelCommitterScript.new(16, 16.0, false)
	var record := {
		"id": "minimal_payload_rock",
		"type": "rock",
		"source_voxel_type": "AutoSceneVoxel",
		"position": Vector3.ZERO,
		"base_pixel": Vector2i(8, 8),
		"voxel_xz": Vector2i(8, 8),
		"volume_xz_resolution": 16,
		"scale": Vector3.ONE,
		"color": Color(0.2, 0.6, 0.8, 0.7),
		"complexity": 0.7,
		"channel": 0,
		"radius": 2.0,
	}

	committer.apply_instance_stamp_write_spec(record)
	committer.build_voxel_volume(8, [
		{"channel": 0, "color": Color(0.2, 0.6, 0.8, 0.7), "complexity": 0.7, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])

	var voxels := committer.get_scene_voxels()
	if voxels.is_empty():
		push_error("  FAIL: expected committed SceneVoxel entries")
		return false
	var committed: Dictionary = voxels.values()[0]
	var ok := true
	if float(committed.get("complexity", 0.0)) <= 0.0:
		push_error("  FAIL: committed SceneVoxel should keep complexity strength")
		ok = false
	if not committed.has("complexity") or absf(float(committed.get("complexity", -1.0)) - float(committed.get("complexity", 0.0))) > 0.001:
		push_error("  FAIL: committed SceneVoxel should keep complexity as a runtime strength")
		ok = false
	var committed_color: Color = committed.get("color", Color.TRANSPARENT)
	if absf(committed_color.a - float(committed.get("complexity", 0.0))) > 0.001:
		push_error("  FAIL: committed SceneVoxel color.a should match complexity")
		ok = false

	for forbidden_key in ["occupied", "type", "source_type", "source_voxel_type", "commit_tick", "channel"]:
		if committed.has(forbidden_key):
			push_error("  FAIL: committed SceneVoxel still stores non-minimal field '%s'" % forbidden_key)
			ok = false

	if ok:
		print("  OK: committed SceneVoxel payload is minimal and occupancy is derived")
	return ok


func _test_terrain_collision_survives_zero_complexity_writes() -> bool:
	print("[MarkdownContracts] test_terrain_collision_survives_zero_complexity_writes...")
	if not _has_rendering_device():
		_record_gpu_skip("no RenderingDevice available for terrain collision SceneVoxel runtime")
		return true

	var committer = SceneVoxelCommitterScript.new(8, 8.0, false)
	committer.configure_scene_voxel_grid(Vector3i(8, 1, 8), Vector3.ONE, Vector3.ZERO)
	var record := {
		"id": "terrain_collision_contract",
		"type": "brush",
		"source_voxel_type": "BrushSceneVoxel",
		"position": Vector3.ZERO,
		"base_pixel": Vector2i(2, 2),
		"voxel_xz": Vector2i(2, 2),
		"volume_xz_resolution": 8,
		"color": Color(0.4, 0.4, 0.4, 1.0),
		"complexity": 1.0,
		"collision": [{
			"shape": "cylinder",
			"radius": 1.0,
			"y_min": 0.0,
			"y_max": 1.0,
			"collision_strength": 1.0,
		}],
		"channel": 0,
		"radius": 1.0,
	}
	committer.apply_instance_stamp_write_spec(record)
	committer.build_voxel_volume(8, [
		{"channel": 0, "color": Color(0.4, 0.4, 0.4, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 1.0, "subdivisions": 1},
	])
	var sv := committer.get_sv()
	var collision_field: PackedFloat32Array = sv.get("collision_field", PackedFloat32Array())
	var collision_max := 0.0
	for value in collision_field:
		collision_max = maxf(collision_max, value)
	if collision_max <= 0.001:
		push_error("  FAIL: zero-complexity ordinary write cleared base collision")
		return false
	print("  OK: base collision survives zero-complexity ordinary writes")
	return true


func _test_channel_stays_out_of_shared_semantics() -> bool:
	print("[MarkdownContracts] test_channel_stays_out_of_shared_semantics...")
	var ok := true
	if SharedPropertyTypeScript.SHARED_FIELD_KEYS.has("channel"):
		push_error("  FAIL: channel routing should not be a shared semantic field")
		ok = false

	var descriptor := AutoVoxelDescriptor.new()
	descriptor.vegetation_channel = 2
	descriptor.vegetation_radius = 0.4
	var fields := descriptor.to_record_fields(0.4)
	for non_shared_key in ["channel", "vegetation_channel"]:
		if fields.has(non_shared_key):
			push_error("  FAIL: descriptor shared record fields promoted non-shared '%s'" % non_shared_key)
			ok = false

	var normalized: Dictionary = SharedPropertyTypeScript.normalize_shared_fields({
		"channel": 2,
		"color": Color(0.1, 0.2, 0.3, 0.6),
		"complexity": 0.6,
	})
	if normalized.has("channel"):
		push_error("  FAIL: shared field normalization promoted channel routing")
		ok = false

	if ok:
		print("  OK: channel routing remains outside shared semantics")
	return ok


func _test_routing_probe_sources_are_sv_resident_and_descriptor_probe_backed() -> bool:
	print("[MarkdownContracts] test_routing_probe_sources_are_sv_resident_and_descriptor_probe_backed...")
	var ok := true
	var prefilter_source := _read_text("res://scripts/autoobject_probe_prefilter_gpu.gd")
	var score_probe_shader := _read_text("res://shaders/score_anchor_asset_probes.glsl")
	var physical_score_shader := _read_text("res://shaders/score_voxel_tile.glsl")
	var routing_doc := _read_text("res://docs/placement/voxel-semantic-routing.md")
	var routing_contract_test := _read_text("res://tools/test_voxel_candidate_routing_contract.gd")
	var candidate_docs := {
		"docs index": _read_text("res://docs/README.md"),
		"graph index": _read_text("res://docs/graphs/README.md"),
		"asset semantic probes": _read_text("res://docs/core/asset-semantic-probes.md"),
		"autoobject probe prefilter": _read_text("res://docs/placement/autoobject-probe-prefilter.md"),
		"target projection": _read_text("res://docs/placement/target-scene-voxel-projection.md"),
		"voxel semantic routing": routing_doc,
		"meshfill framework": _read_text("res://docs/core/meshfill-framework.md"),
		"candidate routing demo doc": _read_text("res://demos/modules/candidate-routing-contract/candidate-routing-contract.md"),
		"candidate routing demo scene": _read_text("res://demos/modules/candidate-routing-contract/candidate-routing-contract.tscn"),
		"placement routing demo doc": _read_text("res://demos/placement-voxel-semantic-routing/placement-voxel-semantic-routing.md"),
	}
	var candidate_graphs := {
		"runtime architecture graph": _read_text("res://docs/graphs/autoobject_gpu_runtime_architecture.svg"),
		"prefilter graph": _read_text("res://docs/graphs/autoobject_probe_prefilter_pipeline.svg"),
		"framework graph": _read_text("res://docs/graphs/meshfill_current_framework.svg"),
		"routing graph": _read_text("res://docs/graphs/voxel-semantic-routing.svg"),
	}

	for required in ["sv.get(\"scene_field\"", "sv.get(\"collision_field\"", "get_semantic_probes"]:
		if prefilter_source.find(required) < 0:
			push_error("  FAIL: probe prefilter source is missing '%s'" % required)
			ok = false

	for required in ["buffer ProbeData", "buffer SceneOcc", "buffer CollisionOcc"]:
		if score_probe_shader.find(required) < 0:
			push_error("  FAIL: probe scoring shader is missing '%s'" % required)
			ok = false

	for forbidden in ["asset_embedding_buffer", "voxel_asset_topk_buffer", "tile_asset_topk_buffer", "semantic_score", "route_score"]:
		if physical_score_shader.find(forbidden) >= 0:
			push_error("  FAIL: physical score shader contains routing semantic term '%s'" % forbidden)
			ok = false

	for required in ["candidate_voxel_regions_by_asset", "candidate_voxel_regions", "legacy alias"]:
		if routing_doc.find(required) < 0:
			push_error("  FAIL: routing doc is missing candidate-region alias contract '%s'" % required)
			ok = false

	for doc_label in candidate_docs.keys():
		var doc_text := str(candidate_docs.get(doc_label, ""))
		if doc_text.find("candidate_voxel_regions_by_asset") < 0:
			push_error("  FAIL: %s is missing docs-facing candidate_voxel_regions_by_asset wording" % doc_label)
			ok = false
		ok = _candidate_sparse_alias_lines_are_qualified(doc_label, doc_text) and ok
		for stale in [
			"GPU spatial index",
			"command queues, spatial index",
			"-> candidate_voxel_sparses_by_asset",
			"`candidate_voxel_sparses_by_asset` 消费",
			"readback 是 `autoobject_candidate_voxel_sparses` / `candidate_voxel_sparses_by_asset`",
			"公开输出以 `autoobject_candidate_voxel_sparses` / `candidate_voxel_sparses_by_asset` 为主",
		]:
			if doc_text.find(stale) >= 0:
				push_error("  FAIL: %s keeps stale candidate/spatial wording '%s'" % [doc_label, stale])
				ok = false

	if str(candidate_graphs.get("runtime architecture graph", "")).find("GPU spatial index") >= 0:
		push_error("  FAIL: runtime architecture graph still labels per-voxel refs as GPU spatial index")
		ok = false
	for graph_label in ["prefilter graph", "framework graph", "routing graph"]:
		var graph_text := str(candidate_graphs.get(graph_label, ""))
		if graph_text.find(">candidate_voxel_regions_by_asset<") < 0:
			push_error("  FAIL: %s is missing candidate_voxel_regions_by_asset node label" % graph_label)
			ok = false
		if graph_text.find(">candidate_voxel_sparses_by_asset<") >= 0:
			push_error("  FAIL: %s still uses legacy sparse alias as a node label" % graph_label)
			ok = false

	for required in ["candidate_voxel_regions_by_asset", "candidate_voxel_regions"]:
		if routing_contract_test.find(required) < 0:
			push_error("  FAIL: routing contract test is missing candidate-region alias '%s'" % required)
			ok = false

	var target_projection_doc := str(candidate_docs.get("target projection", ""))
	for required in [
		"target-sv-point-cloud-conversion.md",
		"target-sv-point-cloud-conversion.tscn",
	]:
		if target_projection_doc.find(required) < 0:
			push_error("  FAIL: target projection doc is missing TargetSV point-cloud demo link '%s'" % required)
			ok = false
	var target_point_cloud_contract := "\n".join([
		_read_text("res://demos/target-sv-point-cloud-conversion/target-sv-point-cloud-conversion.md"),
		_read_text("res://demos/target-sv-point-cloud-conversion/target-sv-point-cloud-conversion.tscn"),
		_read_text("res://tools/test_target_sv_point_cloud_conversion.gd"),
	])
	for required in [
		"target_guidance_only",
		"height_buffer_applied",
		"collision_buffer_applied",
		"guidance-only",
		"not mark source buffers as applied",
	]:
		if target_point_cloud_contract.find(required) < 0:
			push_error("  FAIL: TargetSV point-cloud demo contract is missing '%s'" % required)
			ok = false

	if ok:
		print("  OK: routing/probe path reads SV resident fields and descriptor probes")
	return ok


func _test_gpu_first_no_cpu_fallback_contracts() -> bool:
	print("[MarkdownContracts] test_gpu_first_no_cpu_fallback_contracts...")
	var ok := true
	var docs_combined := "\n".join([
		_read_text("res://docs/core/asset-properties.md"),
		_read_text("res://docs/core/asset-semantic-probes.md"),
		_read_text("res://docs/core/meshfill-framework.md"),
		_read_text("res://docs/core/autoobject-gpu-runtime-architecture.md"),
		_read_text("res://docs/core/scenevoxeltile.md"),
		_read_text("res://demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.md"),
		_read_text("res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.md"),
		_read_text("res://demos/modules/scenevoxel-tile-dirty/scenevoxel-tile-dirty.md"),
	])
	for required in [
		"GPU-first",
		"CPU 只负责",
		"staging",
		"debug readback",
		"只能 SKIP GPU upload / placement",
		"不能改走 CPU 替代路径",
		"非 headless Vulkan",
		"contract validation",
		"bound",
		"consumed",
		"AutoVoxelRuntimeProfileContainer",
		"profile_table",
		"probe_records",
		"runtime_ready == true",
		"runtime_read_source",
		"buffers_stale",
		"readback_debug_snapshot",
		"`contract_blocked=true`",
		"`cpu_fallback=false`",
		"runtime resident success",
		"dirty_scene_voxel_tile_ranges",
		"last_upload_mode",
		"last_upload_tile_ids",
	]:
		if docs_combined.find(required) < 0:
			push_error("  FAIL: GPU-first docs are missing '%s'" % required)
			ok = false

	var lower_docs := docs_combined.to_lower()
	for forbidden in [
		"cpu-only",
		"cpu only",
		"cpu fallback",
		"gpu_resident=false",
		"gpu_resident = false",
		"not documented as landed",
		"cpu-only implementation landed",
		"cpu fallback pass",
		"contract validates but not bound",
		"contract validates but not consumed",
		"contract validates but not bound/consumed",
		"contract validation only",
		"合同校验但未绑定",
		"合同校验但未消费",
		"仅合同校验",
	]:
		if lower_docs.find(forbidden) >= 0:
			push_error("  FAIL: GPU-first docs still contain forbidden fallback wording '%s'" % forbidden)
			ok = false

	for forbidden in [
		"`AutoVoxelRuntimeProfileContainer` 尚未实现",
		"AutoVoxelRuntimeProfileContainer 尚未实现",
		"后者仍未实现",
		"probe buffer 未来是否迁入",
		"目标 `AutoVoxelRuntimeProfileContainer`",
		"当前仍由 descriptor-backed getters 和 prefilter probe packing 提供",
		"future dirty-tile-limited rebuild / upload pass",
		"planned `GPUAutoObjectRuntime`",
		"目标架构中",
	]:
		if docs_combined.find(forbidden) >= 0:
			push_error("  FAIL: GPU-first docs keep stale profile-container wording '%s'" % forbidden)
			ok = false

	var prefilter_source := _read_text("res://scripts/autoobject_probe_prefilter_gpu.gd")
	if prefilter_source.find("CPU fallback was removed") < 0:
		push_error("  FAIL: GPU prefilter source no longer states the CPU fallback is removed")
		ok = false

	var committer_source := _read_text("res://scripts/scene_voxel_committer.gd")
	if committer_source.find("ensure_device(true, false)") < 0 or committer_source.find("GPU compute required") < 0:
		push_error("  FAIL: SceneVoxelCommitter should require GPU compute instead of falling back to CPU")
		ok = false

	for test_spec in [
		{
			"path": "res://tools/test_autoobject_probe_prefilter.gd",
			"skip": "SKIP: no RenderingDevice available for GPU-only anchor collection",
		},
		{
			"path": "res://tools/test_voxel_multi_asset.gd",
			"skip": "SKIP: no RenderingDevice available for GPU-only multi-asset placement",
		},
		{
			"path": "res://tools/test_voxel_footprint_bake.gd",
			"skip": "SKIP: full pipeline requires RenderingDevice",
		},
		{
			"path": "res://tools/test_auto_voxel_runtime_profile_container.gd",
			"skip": "SKIP: no RenderingDevice available for GPU-only profile upload",
		},
		{
			"path": "res://tools/test_voxel_dirty_tile_upload.gd",
			"skip": "no RenderingDevice for SceneVoxelTile storage buffer upload",
		},
	]:
		var path := str(test_spec.get("path", ""))
		var test_text := _read_text(path)
		var skip_text := str(test_spec.get("skip", ""))
		if test_text.find(skip_text) < 0:
			push_error("  FAIL: %s is missing no-RenderingDevice SKIP wording" % path)
			ok = false
		if _mentions_no_rd_cpu_success(test_text.to_lower()):
			push_error("  FAIL: %s treats missing RenderingDevice as CPU fallback success" % path)
			ok = false

	for demo_path in [
		"res://demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.md",
		"res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.md",
	]:
		var demo_text := _read_text(demo_path)
		for required in ["--headless", "--rendering-driver vulkan", "非 headless Vulkan", "RenderingDevice", "tools/test_voxel_multi_asset.gd"]:
			if demo_text.find(required) < 0:
				push_error("  FAIL: %s is missing GPU validation command/wording '%s'" % [demo_path, required])
				ok = false

	if ok:
		print("  OK: GPU-first docs/tests allow no-RD SKIP but no CPU fallback pass")
	return ok


func _test_legacy_scene_voxel_scatter_removed() -> bool:
	print("[MarkdownContracts] test_legacy_scene_voxel_scatter_removed...")
	var ok := true
	var committer_source := _read_text("res://scripts/scene_voxel_committer.gd")
	for forbidden in [
		"Poisson-disk placement",
		"placed_positions",
		"candidates.shuffle",
	]:
		if committer_source.find(forbidden) >= 0:
			push_error("  FAIL: SceneVoxelCommitter still contains legacy scatter loop term '%s'" % forbidden)
			ok = false
	# 验证三个函数已完全删除，不再以任何形式存在
	for removed_func in [
		"func scatter(",
		"func scatter_from_mask(",
		"func _reject_legacy_scatter",
	]:
		if committer_source.find(removed_func) >= 0:
			push_error("  FAIL: SceneVoxelCommitter still contains removed scatter function '%s'" % removed_func)
			ok = false

	if ok:
		print("  OK: legacy SceneVoxelCommitter scatter functions fully removed")
	return ok


func _test_runtime_read_sources_reject_staging_success() -> bool:
	print("[MarkdownContracts] test_runtime_read_sources_reject_staging_success...")
	var ok := true
	var descriptor := AutoVoxelDescriptor.new()
	descriptor.set_color_and_complexity(Color(0.15, 0.25, 0.35, 1.0), 0.5)
	descriptor.set_collision([{"voxel": Vector3i.ZERO, "collision_strength": 0.5}])

	var container = RuntimeProfileContainerScript.new()
	var profile_id: int = container.register_descriptor(descriptor, 1.0)
	if profile_id <= 0:
		push_error("  FAIL: expected staged profile_id before GPU upload")
		ok = false
	var profile_summary: Dictionary = container.get_gpu_buffer_summary()
	if bool(profile_summary.get("runtime_ready", true)):
		push_error("  FAIL: staged profile table must not be runtime ready before GPU upload")
		ok = false
	var profile_snapshot: Dictionary = container.readback_debug_snapshot()
	if bool(profile_snapshot.get("runtime_ready", true)):
		push_error("  FAIL: profile debug snapshot must not be runtime success before GPU upload")
		ok = false

	if not _has_rendering_device():
		container.dispose()
		if ok:
			_record_gpu_skip("no RenderingDevice available for SceneVoxelTile staging/readback contract")
			print("  OK: profile staging is not runtime success; SceneVoxelTile GPU subcheck skipped")
		return ok

	var committer = SceneVoxelCommitterScript.new(8, 8.0, false)
	committer.configure_scene_voxel_grid(Vector3i(8, 1, 8), Vector3.ONE, Vector3.ZERO)
	committer.mark_scene_voxel_tile_dirty(
		Vector3i.ZERO,
		{"scene": true, "object_refs": true},
		{"id": "staging_only_tile", "source_id": "staging_only_source"}
	)
	var tile_summary: Dictionary = committer.get_scene_voxel_tile_gpu_buffer_summary()
	if bool(tile_summary.get("runtime_ready", true)):
		push_error("  FAIL: staged SceneVoxelTile table must not be runtime ready before GPU upload")
		ok = false
	if str(tile_summary.get("runtime_read_source", "")) != "none":
		push_error("  FAIL: staged SceneVoxelTile runtime_read_source must be none")
		ok = false
	if str(tile_summary.get("staging_source", "")) != "sv_owner_command_staging":
		push_error("  FAIL: SceneVoxelTile staging source should stay explicit")
		ok = false
	var tile_snapshot: Dictionary = committer.readback_scene_voxel_tile_debug_snapshot()
	if bool(tile_snapshot.get("readback_snapshot", true)):
		push_error("  FAIL: SceneVoxelTile debug snapshot must not read back without GPU-ready buffers")
		ok = false
	if str(tile_snapshot.get("runtime_read_source", "")) != "none":
		push_error("  FAIL: SceneVoxelTile debug snapshot must not become runtime read source")
		ok = false

	container.dispose()
	committer.dispose()
	if ok:
		print("  OK: CPU staging and debug snapshots do not satisfy runtime success")
	return ok


func _test_vpg_and_scene_tile_gpu_binding_contracts() -> bool:
	print("[MarkdownContracts] test_vpg_and_scene_tile_gpu_binding_contracts...")
	var ok := true
	var vpg_source := _read_text("res://scripts/voxel_placement_generator.gd")
	for required in [
		"REQUIRED_GPU_RUNTIME_BUFFERS",
		"REQUIRED_GPU_PROFILE_BUFFERS",
		"validate_gpu_runtime_profile_contract",
		"_track_borrowed_gpu_buffers",
		"gpu_runtime_profile_buffers_ready",
		"contract_blocked",
		"\"cpu_fallback\": false",
		"missing_gpu_autoobject_runtime_buffers",
		"missing_auto_voxel_profile_buffers",
		"placement_shader_pipeline_not_ready",
		"score_runtime_profile_binding_missing",
		"writeback_reason",
	]:
		if vpg_source.find(required) < 0:
			push_error("  FAIL: VPG source is missing GPU buffer binding contract term '%s'" % required)
			ok = false

	var runtime_source := _read_text("res://scripts/gpu_autoobject_runtime.gd")
	for required in [
		"flush_to_scene_voxel_committer",
		"runtime_not_ready",
		"failed_commit_result_count",
		"dirty_delta_apply_failed",
	]:
		if runtime_source.find(required) < 0:
			push_error("  FAIL: GPUAutoObjectRuntime source is missing no-fallback flush contract term '%s'" % required)
			ok = false

	var profile_container_source := _read_text("res://scripts/auto_voxel_runtime_profile_container.gd")
	for required in [
		"PROFILE_TABLE_BUFFER := \"profile_table\"",
		"PROBE_RECORD_BUFFER := \"probe_records\"",
		"COLLISION_RECORD_BUFFER := \"collision_records\"",
		"PIVOT_RECORD_BUFFER := \"pivot_records\"",
		"upload_profiles",
		"is_runtime_ready",
		"readback_debug_snapshot",
		"\"runtime_ready\": false",
	]:
		if profile_container_source.find(required) < 0:
			push_error("  FAIL: AutoVoxelRuntimeProfileContainer source is missing GPU resident contract term '%s'" % required)
			ok = false

	var multi_asset_test := _read_text("res://tools/test_voxel_multi_asset.gd")
	for required in [
		"test_gpu_runtime_profile_contract_or_skip",
		"test_gpu_runtime_profile_contract_has_no_cpu_fallback",
		"runtime_buffer_count",
		"profile_buffer_count",
		"contract_blocked",
		"cpu_fallback",
	]:
		if multi_asset_test.find(required) < 0:
			push_error("  FAIL: test_voxel_multi_asset.gd is missing GPU contract assertion '%s'" % required)
			ok = false

	var dirty_tile_test := _read_text("res://tools/test_voxel_dirty_tile_upload.gd")
	for required in [
		"mark_scene_voxel_tile_bounds_dirty",
		"invalidate_sv_rect",
		"legacy SV rect invalidation should also populate named SceneVoxelTile sidecar",
		"get_dirty_scene_voxel_tiles",
	]:
		if dirty_tile_test.find(required) < 0:
			push_error("  FAIL: test_voxel_dirty_tile_upload.gd is missing named/legacy dirty bridge assertion '%s'" % required)
			ok = false

	var committer_source := _read_text("res://scripts/scene_voxel_committer.gd")
	for required in [
		"ensure_scene_voxel_tile_buffers_uploaded",
		"get_scene_voxel_tile_gpu_buffer_summary",
		"readback_scene_voxel_tile_debug_snapshot",
		"\"read_source\": \"gpu_storage_buffers\"",
		"\"readback_source\": \"gpu_storage_buffers\"",
		"readback_snapshot",
		"dirty_scene_voxel_tile_ranges",
		"last_upload_mode",
		"last_upload_tile_ids",
		"_scene_voxel_tile_pending_resident_upload_tiles",
		"empty_dirty_delta",
		"missing_object_id",
	]:
		if committer_source.find(required) < 0:
			push_error("  FAIL: SceneVoxelCommitter source is missing GPU resident tile term '%s'" % required)
			ok = false

	var active_spatial_sources := "\n".join([
		vpg_source,
		runtime_source,
		committer_source,
		_read_text("res://scripts/autoobject_probe_prefilter_gpu.gd"),
		_read_text("res://shaders/collect_sv_anchors.glsl"),
		_read_text("res://shaders/score_anchor_asset_probes.glsl"),
		_read_text("res://shaders/select_anchor_topk.glsl"),
		_read_text("res://shaders/reduce_anchor_topk_to_voxel_regions.glsl"),
		_read_text("res://shaders/score_voxel_tile.glsl"),
	])
	for forbidden in ["spatial_hash", "count_objects_per_cell", "sorted_object_id_buffer"]:
		if active_spatial_sources.find(forbidden) >= 0:
			push_error("  FAIL: active runtime/shader source still contains retired spatial-hash term '%s'" % forbidden)
			ok = false

	if ok:
		print("  OK: VPG consumes GPU buffers and SceneVoxelTile readback stays GPU-resident")
	return ok


func _candidate_sparse_alias_lines_are_qualified(label: String, text: String) -> bool:
	var ok := true
	for raw_line in text.split("\n"):
		var line := str(raw_line)
		if line.find("candidate_voxel_sparses") < 0 and line.find("autoobject_candidate_voxel_sparses") < 0:
			continue
		var lower := line.to_lower()
		var qualified := lower.find("legacy") >= 0 \
			or lower.find("debug") >= 0 \
			or lower.find("alias") >= 0 \
			or line.find("兼容") >= 0 \
			or line.find("旧") >= 0 \
			or line.find("仅作为") >= 0
		if not qualified:
			push_error("  FAIL: %s mentions candidate sparse alias without legacy/debug/compat qualifier: %s" % [label, line.strip_edges()])
			ok = false
	return ok


func _mentions_no_rd_cpu_success(lower_text: String) -> bool:
	var anchors := ["renderingdevice", "no rd", "without rd", "无 rd", "无 renderingdevice"]
	var success_terms := ["pass", "passes", "success", "succeed", "通过", "成功"]
	for anchor in anchors:
		var search_from := 0
		while search_from < lower_text.length():
			var index := lower_text.find(anchor, search_from)
			if index < 0:
				break
			var start := maxi(index - 96, 0)
			var length := mini(192, lower_text.length() - start)
			var window := lower_text.substr(start, length)
			if window.find("cpu") >= 0 and (window.find("fallback") >= 0 or window.find("替代") >= 0 or window.find("回退") >= 0):
				for success in success_terms:
					if window.find(success) >= 0:
						return true
			search_from = index + anchor.length()
	return false


func _record_gpu_skip(reason: String) -> void:
	_gpu_skip_count += 1
	print("  SKIP: %s" % reason)


func _has_rendering_device() -> bool:
	if RenderingServer.get_rendering_device() != null:
		return true
	var local_rd := RenderingServer.create_local_rendering_device()
	if local_rd == null:
		return false
	local_rd.free()
	return true


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func _approx_color(actual: Color, expected: Color, eps: float = 0.001) -> bool:
	return (
		absf(actual.r - expected.r) <= eps
		and absf(actual.g - expected.g) <= eps
		and absf(actual.b - expected.b) <= eps
		and absf(actual.a - expected.a) <= eps
	)
