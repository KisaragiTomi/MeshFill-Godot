extends SceneTree

const ScenePlacementActorScript := preload("res://scripts/scene_placement_actor.gd")
const AssetDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")
const RuntimeScript := preload("res://scripts/gpu_autoobject_runtime.gd")
const VPGScript := preload("res://scripts/voxel_placement_generator.gd")


func _init() -> void:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		print("[ScenePlacementTargetReadBuffersGPU] SKIP: no RenderingDevice")
		quit(OK)
		return
	probe_rd.free()

	var ok := true
	ok = _test_gpu_prepare_trims_and_zero_fills() and ok
	ok = _test_gpu_prepare_edge_guard() and ok
	ok = _test_gpu_prepare_resident_handoff_default_and_legacy_opt_out() and ok
	ok = _test_vpg_blocks_failed_resident_target_borrow_without_bytes() and ok
	ok = _test_actor_pipeline_preserves_target_read_buffer_summaries() and ok

	if ok:
		print("[ScenePlacementTargetReadBuffersGPU] ALL TESTS PASSED")
		quit(OK)
	else:
		push_error("[ScenePlacementTargetReadBuffersGPU] SOME TESTS FAILED")
		quit(FAILED)


func _test_gpu_prepare_trims_and_zero_fills() -> bool:
	print("[ScenePlacementTargetReadBuffersGPU] test_gpu_prepare_trims_and_zero_fills...")
	var grid_size := Vector3i(2, 1, 2)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var expected_bytes := voxel_count * 4
	var color_bytes := PackedByteArray()
	color_bytes.resize(expected_bytes + 8)
	for i in range(voxel_count):
		color_bytes.encode_u32(i * 4, 0x10203040 + i)

	var actor := ScenePlacementActorScript.new()
	var result := actor.prepare_target_read_buffers_from_common_gpu({
		"target_color_rgba8_bytes": color_bytes,
		"debug_read_target_read_buffer_bytes": true,
	}, {"grid_size": grid_size})
	actor.dispose(true)

	if not bool(result.get("ok", false)):
		push_error("  FAIL: GPU prepare failed: %s" % str(result))
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("  FAIL: GPU prepare must not report CPU fallback")
		return false
	if str(result.get("stats_source", "")) != "prepare_target_read_buffers_compute":
		push_error("  FAIL: wrong stats source: %s" % str(result))
		return false
	if int(result.get("expected_byte_count", 0)) != expected_bytes or int(result.get("voxel_count", 0)) != voxel_count:
		push_error("  FAIL: byte-count metadata mismatch: %s" % str(result))
		return false
	if int((result.get("dispatch_groups", Vector3i.ZERO) as Vector3i).x) != 1:
		push_error("  FAIL: expected one dispatch group for four voxels")
		return false

	var out_field: PackedFloat32Array = result.get("target_field_bytes", PackedFloat32Array())
	var field_floats := voxel_count * 4
	if out_field.size() != field_floats:
		push_error("  FAIL: output field float count mismatch (expected %d got %d)" % [field_floats, out_field.size()])
		return false
	for i in range(voxel_count):
		var base := i * 4
		if out_field[base + 0] <= 0.0 and out_field[base + 1] <= 0.0 and out_field[base + 2] <= 0.0:
			push_error("  FAIL: field color channels should be non-zero for given input at voxel %d" % i)
			return false
		if out_field[base + 3] < 0.0 or out_field[base + 3] > 1.0:
			push_error("  FAIL: field alpha (occupancy) out of range at voxel %d: %f" % [i, out_field[base + 3]])
			return false
	if str(result.get("target_field_source", "")) != "target_color_rgba8_bytes":
		push_error("  FAIL: source metadata mismatch: %s" % str(result))
		return false

	var missing_actor := ScenePlacementActorScript.new()
	var missing := missing_actor.prepare_target_read_buffers_from_common_gpu({
		"debug_read_target_read_buffer_bytes": true,
	}, {"grid_size": grid_size})
	missing_actor.dispose(true)
	if not bool(missing.get("ok", false)):
		push_error("  FAIL: missing-input zero-fill path failed: %s" % str(missing))
		return false
	var missing_field: PackedFloat32Array = missing.get("target_field_bytes", PackedFloat32Array())
	for i in range(voxel_count):
		var base := i * 4
		if absf(missing_field[base + 0]) > 0.001 or absf(missing_field[base + 1]) > 0.001 \
				or absf(missing_field[base + 2]) > 0.001 or absf(missing_field[base + 3]) > 0.001:
			push_error("  FAIL: missing inputs should produce zero-filled field")
			return false
	if str(missing.get("target_field_source", "")) != "zero_filled":
		push_error("  FAIL: missing-input source metadata mismatch: %s" % str(missing))
		return false

	print("  OK: GPU prepared TargetSV read buffers preserve packed words and zero-fill missing inputs")
	return true


func _test_gpu_prepare_edge_guard() -> bool:
	print("[ScenePlacementTargetReadBuffersGPU] test_gpu_prepare_edge_guard...")
	var grid_size := Vector3i(5, 3, 5)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var expected_bytes := voxel_count * 4
	var color_bytes := PackedByteArray()
	color_bytes.resize(expected_bytes)
	for i in range(voxel_count):
		color_bytes.encode_u32(i * 4, 0xA0000000 | i)

	var actor := ScenePlacementActorScript.new()
	var result := actor.prepare_target_read_buffers_from_common_gpu({
		"target_color_rgba8_bytes": color_bytes,
		"debug_read_target_read_buffer_bytes": true,
	}, {"grid_size": grid_size})
	actor.dispose(true)

	if not bool(result.get("ok", false)):
		push_error("  FAIL: edge-guard GPU prepare failed: %s" % str(result))
		return false
	if (result.get("dispatch_groups", Vector3i.ZERO) as Vector3i).x != 2:
		push_error("  FAIL: expected ceil(75 / 64) = 2 dispatch groups")
		return false
	var out_field: PackedFloat32Array = result.get("target_field_bytes", PackedFloat32Array())
	if out_field.size() != voxel_count * 4:
		push_error("  FAIL: guarded output field float count mismatch")
		return false
	var last_base := (voxel_count - 1) * 4
	if out_field[last_base + 0] <= 0.0 or out_field[last_base + 1] <= 0.0 or out_field[last_base + 2] <= 0.0:
		push_error("  FAIL: guarded field color channels should be non-zero at last voxel")
		return false
	if out_field[last_base + 3] < 0.0 or out_field[last_base + 3] > 1.0:
		push_error("  FAIL: guarded field alpha (occupancy) out of range at last voxel")
		return false

	print("  OK: non-multiple voxel count is edge-guarded")
	return true


func _test_gpu_prepare_resident_handoff_default_and_legacy_opt_out() -> bool:
	print("[ScenePlacementTargetReadBuffersGPU] test_gpu_prepare_resident_handoff_default_and_legacy_opt_out...")
	var grid_size := Vector3i(2, 2, 2)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var expected_bytes := voxel_count * 4
	var color_bytes := PackedByteArray()
	color_bytes.resize(expected_bytes)
	for i in range(voxel_count):
		color_bytes.encode_u32(i * 4, 0xB0001000 | i)

	var actor := ScenePlacementActorScript.new()
	var result := actor.prepare_target_read_buffers_from_common_gpu({
		"target_color_rgba8_bytes": color_bytes,
	}, {"grid_size": grid_size})

	if not bool(result.get("ok", false)):
		actor.dispose(true)
		push_error("  FAIL: default GPU prepare failed: %s" % str(result))
		return false
	if not bool(result.get("resident_target_read_buffer_handoff", false)):
		actor.dispose(true)
		push_error("  FAIL: default result should report resident handoff: %s" % str(result))
		return false
	if bool(result.get("cpu_fallback", true)):
		actor.dispose(true)
		push_error("  FAIL: resident handoff must not report CPU fallback")
		return false
	if not bool(result.get("resident_target_read_buffer_handoff_defaulted", false)) \
			or str(result.get("target_read_handoff_mode", "")) != "zero_readback_resident":
		actor.dispose(true)
		push_error("  FAIL: resident handoff should default to zero-readback mode: %s" % str(result))
		return false
	var default_field_bytes: PackedFloat32Array = result.get("target_field_bytes", PackedFloat32Array())
	if not default_field_bytes.is_empty():
		actor.dispose(true)
		push_error("  FAIL: default resident handoff should leave CPU field byte array empty")
		return false

	var summary: Dictionary = result.get("resident_target_read_buffer_handoff_summary", {})
	if str(summary.get("owner", "")) != "ScenePlacementActor" \
			or str(summary.get("target_field_buffer_rid", "")) != "valid":
		actor.dispose(true)
		push_error("  FAIL: resident owner/RID diagnostics mismatch: %s" % str(summary))
		return false
	var field_byte_count := voxel_count * 16
	if int(summary.get("target_field_byte_count", 0)) != field_byte_count \
			or int(summary.get("voxel_count", 0)) != voxel_count:
		actor.dispose(true)
		push_error("  FAIL: resident byte/count diagnostics mismatch: %s" % str(summary))
		return false
	if str(summary.get("target_read_buffer_lifetime", "")) == "none":
		actor.dispose(true)
		push_error("  FAIL: resident lifetime contract missing: %s" % str(summary))
		return false

	var rd := actor.get_rendering_device()
	var field_rid: RID = result.get("target_field_buffer", RID())
	if rd == null or not field_rid.is_valid():
		actor.dispose(true)
		push_error("  FAIL: resident RIDs must be borrowable before actor disposal")
		return false
	var field_byte_count := voxel_count * 16
	var resident_field := rd.buffer_get_data(field_rid, 0, field_byte_count)
	if resident_field.size() != field_byte_count:
		actor.dispose(true)
		push_error("  FAIL: resident readback byte size mismatch")
		return false
	var resident_floats := resident_field.to_float32_array()
	var last_base := (voxel_count - 1) * 4
	if resident_floats[last_base + 0] <= 0.0 or resident_floats[last_base + 1] <= 0.0 or resident_floats[last_base + 2] <= 0.0:
		actor.dispose(true)
		push_error("  FAIL: resident field color channels should be non-zero at last voxel")
		return false
	if resident_floats[last_base + 3] < 0.0 or resident_floats[last_base + 3] > 1.0:
		actor.dispose(true)
		push_error("  FAIL: resident field alpha (occupancy) out of range at last voxel")
		return false

	var normal := actor.prepare_target_read_buffers_from_common_gpu({
		"target_color_rgba8_bytes": color_bytes,
		"use_resident_target_read_buffer_handoff": false,
	}, {"grid_size": grid_size})
	actor.dispose(true)
	if not bool(normal.get("ok", false)):
		push_error("  FAIL: legacy opt-out GPU prepare after resident handoff failed: %s" % str(normal))
		return false
	if bool(normal.get("resident_target_read_buffer_handoff", true)) \
			or bool(normal.get("resident_target_read_buffer_handoff_opt_in", true)) \
			or str(normal.get("resident_target_field_buffer_rid", "")) != "none":
		push_error("  FAIL: explicit legacy path must not claim resident handoff: %s" % str(normal))
		return false
	var legacy_field: PackedFloat32Array = normal.get("target_field_bytes", PackedFloat32Array())
	if legacy_field.size() != voxel_count * 4:
		push_error("  FAIL: explicit legacy path should preserve field byte readback: %s" % str(normal))
		return false

	print("  OK: default TargetSV read buffers stay ScenePlacementActor-owned and explicit legacy opt-out remains nonresident")
	return true


func _test_actor_pipeline_preserves_target_read_buffer_summaries() -> bool:
	print("[ScenePlacementTargetReadBuffersGPU] test_actor_pipeline_preserves_target_read_buffer_summaries...")
	var grid_size := Vector3i.ONE
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var expected_bytes := voxel_count * 4
	var color_bytes := PackedByteArray()
	color_bytes.resize(expected_bytes)
	color_bytes.encode_u32(0, 0x4488ccff)

	var resident_result := _run_fake_pipeline_with_target_buffers(grid_size, color_bytes, true)
	if resident_result.is_empty():
		return false
	if not _assert_pipeline_target_summary(resident_result.get("prefilter_result", {}), true, expected_bytes, "resident prefilter_result"):
		return false
	if not _assert_pipeline_target_summary(resident_result.get("placement_result", {}), true, expected_bytes, "resident placement_result"):
		return false
	if not _assert_pipeline_target_summary(resident_result, true, expected_bytes, "resident actor result"):
		return false

	var uploaded_result := _run_fake_pipeline_with_target_buffers(grid_size, color_bytes, false)
	if uploaded_result.is_empty():
		return false
	if not _assert_pipeline_target_summary(uploaded_result.get("prefilter_result", {}), false, expected_bytes, "uploaded prefilter_result"):
		return false
	if not _assert_pipeline_target_summary(uploaded_result.get("placement_result", {}), false, expected_bytes, "uploaded placement_result"):
		return false
	if not _assert_pipeline_target_summary(uploaded_result, false, expected_bytes, "uploaded actor result"):
		return false

	print("  OK: ScenePlacementActor preserves TargetSV read-buffer summaries through prefilter, placement, and actor result")
	return true


func _test_vpg_blocks_failed_resident_target_borrow_without_bytes() -> bool:
	print("[ScenePlacementTargetReadBuffersGPU] test_vpg_blocks_failed_resident_target_borrow_without_bytes...")
	var grid_size := Vector3i(4, 2, 4)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var expected_bytes := voxel_count * 4
	var color_bytes := PackedByteArray()
	color_bytes.resize(expected_bytes)

	var actor := ScenePlacementActorScript.new()
	var target_buffers := actor.prepare_target_read_buffers_from_common_gpu({
		"target_color_rgba8_bytes": color_bytes,
	}, {"grid_size": grid_size})
	if not bool(target_buffers.get("resident_target_read_buffer_handoff", false)):
		actor.dispose(true)
		push_error("  FAIL: fixture should prepare default resident TargetSV buffers: %s" % str(target_buffers))
		return false

	var generator := VPGScript.new()
	if not generator.attach_rendering_device(actor.get_rendering_device(), false):
		generator.dispose()
		actor.dispose(true)
		push_error("  FAIL: VPG should attach actor RenderingDevice")
		return false

	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0
	var footprint: Array[Dictionary] = [{
		"local_pos": Vector3i.ZERO,
		"collision_strength": 0.25,
		"flags": 1,
		"weight": 1.0,
	}]

	var mismatch_buffers := target_buffers.duplicate(true)
	mismatch_buffers["target_field_byte_count"] = 4
	var result := generator.run_minimal(scene, collision, footprint, grid_size, {
		"target_read_buffers": mismatch_buffers,
		"top_k": 1,
		"result_capacity": 1,
	})
	var summary: Dictionary = result.get("target_read_buffer_summary", {})
	generator.dispose()
	actor.dispose(true)
	if not bool(result.get("contract_blocked", false)) \
			or str(result.get("target_read_buffer_blocked_reason", "")) != "resident_target_read_buffer_byte_count_mismatch_no_debug_or_legacy_bytes":
		push_error("  FAIL: VPG should block failed resident TargetSV borrow without bytes: %s" % str(result))
		return false
	if not bool(summary.get("contract_blocked", false)) \
			or bool(summary.get("target_read_buffers_uploaded", true)) \
			or bool(summary.get("target_read_buffers_borrowed", true)) \
			or bool(summary.get("cpu_fallback", true)):
		push_error("  FAIL: blocked TargetSV summary should expose no CPU/upload fallback: %s" % str(summary))
		return false

	print("  OK: VPG blocks failed resident TargetSV borrow when no debug/legacy bytes are present")
	return true


func _run_fake_pipeline_with_target_buffers(
	grid_size: Vector3i,
	color_bytes: PackedByteArray,
	resident_handoff: bool
) -> Dictionary:
	var actor := ScenePlacementActorScript.new()
	if not actor.initialize(true, false):
		print("  SKIP: no RenderingDevice for actor pipeline TargetSV summary fixture")
		return {}

	var descriptor := AssetDescriptorScript.new()
	descriptor.asset_id = "target_read_buffer_pipeline_summary"
	descriptor.set_collision([])
	if actor.register_asset(descriptor) < 0:
		actor.dispose(true)
		push_error("  FAIL: actor pipeline TargetSV fixture should register descriptor")
		return {}

	var runtime := RuntimeScript.new(4, false)
	if not runtime.attach_rendering_device(actor.get_rendering_device(), false):
		runtime.dispose(true)
		actor.dispose(true)
		push_error("  FAIL: actor pipeline TargetSV fixture should attach runtime RenderingDevice")
		return {}
	runtime.configure_capacity(4, true)
	if not runtime.is_gpu_ready():
		runtime.dispose(true)
		actor.dispose(true)
		push_error("  FAIL: actor pipeline TargetSV fixture runtime should be GPU-ready")
		return {}
	actor.attach_gpu_runtime(runtime)

	var fake_prefilter := FakeTargetReadBufferPrefilter.new()
	if not fake_prefilter.attach_rendering_device(actor.get_rendering_device(), false):
		fake_prefilter.dispose()
		runtime.dispose(true)
		actor.dispose(true)
		push_error("  FAIL: fake prefilter should attach to actor RenderingDevice")
		return {}
	actor._prefilter = fake_prefilter

	var placement_common := {
		"target_color_rgba8_bytes": color_bytes,
		"result_capacity": 1,
	}
	if resident_handoff:
		placement_common["use_resident_target_read_buffer_handoff"] = true
	else:
		placement_common["use_resident_target_read_buffer_handoff"] = false

	var result := actor.run_placement_pipeline({
		"grid_size": grid_size,
		"voxel_size": Vector3.ONE,
		"grid_origin": Vector3.ZERO,
		"complexity_field": PackedFloat32Array([0.0]),
		"collision_field": PackedFloat32Array([0.0]),
	}, [], 1, placement_common).duplicate(true)
	runtime.dispose(true)
	actor.dispose(true)

	if not bool(result.get("ok", false)):
		push_error("  FAIL: actor pipeline TargetSV summary fixture should complete: %s" % str(result))
		return {}
	return result


func _assert_pipeline_target_summary(result: Dictionary, expect_borrowed: bool, expected_bytes: int, label: String) -> bool:
	var summary: Dictionary = result.get("target_read_buffer_summary", {})
	if summary.is_empty():
		push_error("  FAIL: %s missing target_read_buffer_summary: %s" % [label, str(result)])
		return false
	if not bool(summary.get("ready", false)):
		push_error("  FAIL: %s target summary should be ready: %s" % [label, str(summary)])
		return false
	if int(summary.get("target_color_rgba8_byte_count", 0)) != expected_bytes:
		push_error("  FAIL: %s target byte counts mismatch: %s" % [label, str(summary)])
		return false
	if bool(summary.get("target_read_buffers_borrowed", false)) != expect_borrowed:
		push_error("  FAIL: %s borrowed flag mismatch: %s" % [label, str(summary)])
		return false
	if bool(summary.get("target_read_buffers_uploaded", false)) == expect_borrowed:
		push_error("  FAIL: %s uploaded flag mismatch: %s" % [label, str(summary)])
		return false
	if bool(summary.get("cpu_fallback", true)):
		push_error("  FAIL: %s TargetSV summary must not report CPU fallback: %s" % [label, str(summary)])
		return false

	var expected_source := "borrowed_scene_placement_actor_resident" if expect_borrowed else "uploaded_target_bytes"
	if str(summary.get("target_read_buffer_source", "")) != expected_source:
		push_error("  FAIL: %s target source mismatch: %s" % [label, str(summary)])
		return false
	if expect_borrowed:
		if str(summary.get("borrowed_from", "")) != "ScenePlacementActor" \
				or str(summary.get("target_read_buffer_ownership", "")) != "borrowed_external" \
				or not bool(summary.get("rendering_device_match", false)):
			push_error("  FAIL: %s resident borrow diagnostics missing: %s" % [label, str(summary)])
			return false
	else:
		if str(summary.get("borrowed_from", "")) != "none" \
				or bool(summary.get("rendering_device_match", true)) \
				or str(summary.get("source_reason", "")) == "none":
			push_error("  FAIL: %s byte-upload fallback should stay explicit: %s" % [label, str(summary)])
			return false
	return true


class FakeTargetReadBufferPrefilter:
	extends "res://scripts/autoobject_probe_prefilter_gpu.gd"

	func run_probe_prefilter(
		sv: Dictionary,
		autoobjects: Array,
		dirty_tile_ids: Array[int] = [],
		runtime_profile_container: Object = null,
		target_field_bytes: PackedFloat32Array = PackedFloat32Array(),
		target_read_buffers: Dictionary = {}
	) -> Dictionary:
		var grid_size: Vector3i = sv.get("grid_size", Vector3i.ONE)
		var voxel_count := maxi(grid_size.x * grid_size.y * grid_size.z, 1)
		var target_pack := _target_read_buffer_pack(
			target_read_buffers,
			target_field_bytes,
			voxel_count
		)
		var target_summary := _target_read_buffer_summary(target_pack)
		var regions := {
			0: [Vector3i.ZERO],
		}
		return {
			"ok": true,
			"anchors": [],
			"anchor_autoobject_topk": {},
			"autoobject_candidate_voxel_sparses": regions,
			"candidate_voxel_regions_by_asset": regions,
			"candidate_voxel_sparses_by_asset": regions,
			"candidate_route_profiles": [],
			"candidate_route_readback_source": "gpu_vote_buffer_readback",
			"candidate_route_runtime_read_source": "cpu_debug_bridge",
			"candidate_route_input_contract": {},
			"anchor_count": 0,
			"profile_probe_pack": {},
			"target_read_buffer_source": str(target_summary.get("target_read_buffer_source", "none")),
			"target_read_buffer_summary": target_summary,
			"prefilter_reason": "fake_target_read_buffer_pipeline_summary",
			"gpu_first": true,
			"cpu_fallback": false,
		}
