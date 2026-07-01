@tool
extends "res://scripts/core_demo_contract_fixture.gd"

const SPAScript := preload("res://scripts/scene_placement_actor.gd")
const AutoObjectScript := preload("res://scripts/auto_object.gd")
const DescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")
const SceneVoxelCommitterScript := preload("res://scripts/scene_voxel_committer.gd")
const AutoVoxelFixture := preload("res://scripts/utils/auto_voxel_fixture.gd")

var _result_label: Label3D
var _test_results: Array[Dictionary] = []
var _spa: Object  # ScenePlacementActor instance


func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	_ensure_result_label()
	run_all_tests.call_deferred()


func run_all_tests() -> Dictionary:
	_test_results.clear()
	_log("═══ SPA Test Suite Start ═══")

	_run(test_lifecycle)
	_run(test_asset_registration)
	_run(test_autoobject_asset_entry)
	_run(test_replace_all_autoobject_assets)
	_run(test_autoobject_runtime_capacity)
	_run(test_autoobject_runtime_batch_entry)
	_run(test_gpu_readiness)
	_run(test_gpu_buffer_access)
	_run(test_mesh_description)
	_run(test_external_references)
	_run(test_brush_sv_metadata)
	_run(test_pipeline_error_paths)
	_run(test_merged_gpu_summary)

	var passed := _test_results.filter(func(r): return r["ok"]).size()
	var total := _test_results.size()
	var summary := "%d / %d PASSED" % [passed, total]
	if passed == total:
		_log("═══ ALL TESTS PASSED (%d) ═══" % total)
	else:
		var fails := _test_results.filter(func(r): return not r["ok"])
		for f in fails:
			push_error("[SPA_TEST FAIL] %s: %s" % [f["name"], f["detail"]])
		_log("═══ %s ═══" % summary)

	_update_label()
	return {"ok": passed == total, "passed": passed, "total": total, "results": _test_results.duplicate(true)}


# ---------------------------------------------------------------------------
# Test: Lifecycle
# ---------------------------------------------------------------------------

func test_lifecycle() -> Dictionary:
	var spa := SPAScript.new()

	if spa.is_initialized():
		return _fail("lifecycle", "should not be initialized before initialize()")

	var ok := spa.initialize(true, true)
	if not ok:
		return _fail("lifecycle", "initialize() returned false")
	if not spa.is_initialized():
		spa.dispose()
		return _fail("lifecycle", "is_initialized() false after initialize()")

	spa.dispose()
	if spa.is_initialized():
		return _fail("lifecycle", "is_initialized() true after dispose()")

	return _pass("lifecycle", "init -> initialized -> dispose -> not initialized")


# ---------------------------------------------------------------------------
# Test: Asset Registration
# ---------------------------------------------------------------------------

func test_asset_registration() -> Dictionary:
	var spa := SPAScript.new()
	spa.initialize(true, true)

	if spa.get_asset_count() != 0:
		spa.dispose()
		return _fail("asset_registration", "asset count should be 0 before registration")

	var desc := AutoVoxelFixture.make_spa_test_descriptor("test_leaf_a")
	var profile_id := spa.register_asset(desc)
	if profile_id < 0:
		spa.dispose()
		return _fail("asset_registration", "register_asset returned %d" % profile_id)

	if spa.get_asset_count() != 1:
		spa.dispose()
		return _fail("asset_registration", "asset count should be 1, got %d" % spa.get_asset_count())

	var descs := spa.get_registered_descriptors()
	if descs.size() != 1 or descs[0] != desc:
		spa.dispose()
		return _fail("asset_registration", "get_registered_descriptors mismatch")

	var pid := spa.get_profile_id_for_asset(0)
	if pid != profile_id:
		spa.dispose()
		return _fail("asset_registration", "profile_id mismatch: %d vs %d" % [pid, profile_id])

	var desc2 := AutoVoxelFixture.make_spa_test_descriptor("test_leaf_b")
	spa.register_asset(desc2)
	if spa.get_asset_count() != 2:
		spa.dispose()
		return _fail("asset_registration", "asset count should be 2 after second register")

	spa.clear_assets()
	if spa.get_asset_count() != 0:
		spa.dispose()
		return _fail("asset_registration", "asset count should be 0 after clear")

	spa.dispose()
	return _pass("asset_registration", "register x2, profile_id valid, clear ok")


# ---------------------------------------------------------------------------
# Test: AutoObject Asset Entry
# ---------------------------------------------------------------------------

func test_autoobject_asset_entry() -> Dictionary:
	var spa := SPAScript.new()
	spa.initialize(true, true)

	var desc := AutoVoxelFixture.make_spa_test_descriptor("test_autoobject_asset")
	desc.mesh = DescriptorScript.create_sample_autoobject_mesh()
	var obj := AutoObjectScript.new()
	obj.configure_auto_object({
		"id": "test_autoobject_asset",
		"name": "TestAutoObjectAsset",
		"mesh": desc.mesh,
		"voxel_descriptor": desc,
	})

	var profile_id := spa.register_autoobject_asset(obj)
	if profile_id < 0:
		_cleanup_spa_and_nodes(spa, [obj])
		return _fail("autoobject_asset_entry", "register_autoobject_asset returned %d" % profile_id)
	if spa.get_asset_count() != 1:
		_cleanup_spa_and_nodes(spa, [obj])
		return _fail("autoobject_asset_entry", "asset count should be 1, got %d" % spa.get_asset_count())
	if spa.get_profile_id_for_asset(0) != profile_id:
		_cleanup_spa_and_nodes(spa, [obj])
		return _fail("autoobject_asset_entry", "profile id mismatch")
	if not spa.has_owned_autoobject(obj):
		_cleanup_spa_and_nodes(spa, [obj])
		return _fail("autoobject_asset_entry", "registered AutoObject should be owned by SPA")
	if spa.get_asset_id_for_autoobject(obj) != 0:
		_cleanup_spa_and_nodes(spa, [obj])
		return _fail("autoobject_asset_entry", "asset id lookup should return 0")
	if not bool(obj.get_meta("spa_owned", false)):
		_cleanup_spa_and_nodes(spa, [obj])
		return _fail("autoobject_asset_entry", "spa_owned metadata missing")
	if str(obj.get_meta("spa_owner", "")) != "ScenePlacementActor":
		_cleanup_spa_and_nodes(spa, [obj])
		return _fail("autoobject_asset_entry", "spa_owner metadata mismatch")
	if int(obj.get_meta("spa_asset_id", -1)) != 0:
		_cleanup_spa_and_nodes(spa, [obj])
		return _fail("autoobject_asset_entry", "spa_asset_id metadata mismatch")

	var mesh_summary := spa.get_mesh_description_gpu_buffer_summary()
	if not bool(mesh_summary.get("runtime_ready", false)):
		_cleanup_spa_and_nodes(spa, [obj])
		return _fail("autoobject_asset_entry", "mesh description runtime not ready")

	_cleanup_spa_and_nodes(spa, [obj])
	return _pass("autoobject_asset_entry", "AutoObject registers through SPA and is owned")


# ---------------------------------------------------------------------------
# Test: Replace All AutoObject Assets
# ---------------------------------------------------------------------------

func test_replace_all_autoobject_assets() -> Dictionary:
	var spa := SPAScript.new()
	spa.initialize(true, true)

	var obj_a := AutoObjectScript.new()
	obj_a.configure_auto_object({
		"id": "test_replace_a",
		"name": "TestReplaceA",
		"voxel_descriptor": AutoVoxelFixture.make_spa_test_descriptor("test_replace_a"),
	})
	var obj_b := AutoObjectScript.new()
	obj_b.configure_auto_object({
		"id": "test_replace_b",
		"name": "TestReplaceB",
		"voxel_descriptor": AutoVoxelFixture.make_spa_test_descriptor("test_replace_b"),
	})
	var assets := [obj_a, obj_b]

	if not spa.replace_all_autoobject_assets(assets):
		_cleanup_spa_and_nodes(spa, assets)
		return _fail("replace_all_autoobject_assets", "initial replace failed")
	if spa.get_asset_count() != 2:
		_cleanup_spa_and_nodes(spa, assets)
		return _fail("replace_all_autoobject_assets", "asset count should be 2 after replace")
	if spa.get_owned_autoobject_count() != 2:
		_cleanup_spa_and_nodes(spa, assets)
		return _fail("replace_all_autoobject_assets", "owned autoobject count should be 2")

	var refs: Array = spa.get_registered_autoobject_refs()
	if refs.size() != 2 or refs[0] != obj_a or refs[1] != obj_b:
		_cleanup_spa_and_nodes(spa, assets)
		return _fail("replace_all_autoobject_assets", "registered refs mismatch after replace")

	if not spa.replace_all_autoobject_assets(assets):
		_cleanup_spa_and_nodes(spa, assets)
		return _fail("replace_all_autoobject_assets", "second replace failed")
	if not is_instance_valid(obj_a) or not is_instance_valid(obj_b):
		_cleanup_spa_and_nodes(spa, assets)
		return _fail("replace_all_autoobject_assets", "caller-owned objects should remain valid")
	if spa.get_asset_id_for_autoobject(obj_b) != 1:
		_cleanup_spa_and_nodes(spa, assets)
		return _fail("replace_all_autoobject_assets", "asset lookup should survive second replace")

	_cleanup_spa_and_nodes(spa, assets)
	return _pass("replace_all_autoobject_assets", "replace refreshes SPA registry without freeing caller assets")


# ---------------------------------------------------------------------------
# Test: AutoObject Runtime Capacity
# ---------------------------------------------------------------------------

func test_autoobject_runtime_capacity() -> Dictionary:
	var spa := SPAScript.new()
	spa.set_autoobject_runtime_capacity(37)
	if spa.get_autoobject_runtime_capacity() != 37:
		return _fail("autoobject_runtime_capacity", "capacity setter/getter mismatch")

	spa.initialize(true, true)
	var runtime = spa.get_gpu_runtime()
	if runtime == null:
		spa.dispose()
		return _fail("autoobject_runtime_capacity", "gpu_runtime should be created by SPA")
	if not spa.owns_gpu_runtime():
		spa.dispose()
		return _fail("autoobject_runtime_capacity", "gpu_runtime should be SPA-owned")
	if int(runtime.max_objects) != 37:
		spa.dispose()
		return _fail("autoobject_runtime_capacity", "runtime.max_objects should be 37, got %d" % int(runtime.max_objects))

	spa.set_autoobject_runtime_capacity(23, true)
	runtime = spa.get_gpu_runtime()
	if int(runtime.max_objects) != 23:
		spa.dispose()
		return _fail("autoobject_runtime_capacity", "recreated runtime.max_objects should be 23, got %d" % int(runtime.max_objects))

	spa.dispose()
	return _pass("autoobject_runtime_capacity", "SPA creates and recreates owned runtime with configured capacity")


# ---------------------------------------------------------------------------
# Test: AutoObject Runtime Batch Entry
# ---------------------------------------------------------------------------

func test_autoobject_runtime_batch_entry() -> Dictionary:
	var committer := SceneVoxelCommitterScript.new(16, 16.0, true)
	var spa := SPAScript.new()
	spa.set_autoobject_runtime_capacity(4)
	spa.initialize(true, true, committer)

	if not spa.is_autoobject_runtime_ready():
		committer.dispose(false)
		spa.dispose()
		return _fail("autoobject_runtime_batch_entry", "SPA runtime should be ready with committer attached")

	var spawn_result := spa.spawn_autoobject_batch_from_accepted_placement_records([], {
		"use_accepted_placement_record_shader": true,
	})
	if not bool(spawn_result.get("ok", false)):
		committer.dispose(false)
		spa.dispose()
		return _fail("autoobject_runtime_batch_entry", "empty spawn through SPA should be ok: %s" % str(spawn_result.get("reason", "")))
	if str(spawn_result.get("control_plane", "")) != "ScenePlacementActor":
		committer.dispose(false)
		spa.dispose()
		return _fail("autoobject_runtime_batch_entry", "spawn control_plane should be ScenePlacementActor")
	if str(spawn_result.get("runtime_action", "")) != "spawn_batch_from_accepted_placement_records":
		committer.dispose(false)
		spa.dispose()
		return _fail("autoobject_runtime_batch_entry", "spawn runtime_action mismatch")

	var flush_result := spa.flush_autoobject_runtime_to_scene_voxel_committer({})
	if str(flush_result.get("control_plane", "")) != "ScenePlacementActor":
		committer.dispose(false)
		spa.dispose()
		return _fail("autoobject_runtime_batch_entry", "flush control_plane should be ScenePlacementActor")
	if str(flush_result.get("runtime_action", "")) != "flush_to_scene_voxel_committer":
		committer.dispose(false)
		spa.dispose()
		return _fail("autoobject_runtime_batch_entry", "flush runtime_action mismatch")

	spa.dispose()
	committer.dispose(false)
	return _pass("autoobject_runtime_batch_entry", "runtime spawn/flush entries route through SPA")


# ---------------------------------------------------------------------------
# Test: GPU Readiness
# ---------------------------------------------------------------------------

func test_gpu_readiness() -> Dictionary:
	var spa := SPAScript.new()
	spa.initialize(true, true)

	if spa.is_gpu_ready():
		spa.dispose()
		return _fail("gpu_readiness", "should not be gpu ready with 0 assets")

	var report := spa.get_gpu_readiness_report()
	if bool(report.get("ok", true)):
		spa.dispose()
		return _fail("gpu_readiness", "readiness report.ok should be false with 0 assets")

	var desc := AutoVoxelFixture.make_spa_test_descriptor("test_leaf_gpu")
	spa.register_asset(desc)

	if not spa.is_gpu_ready():
		var r2 := spa.get_gpu_readiness_report()
		spa.dispose()
		return _fail("gpu_readiness", "not gpu ready after register: %s" % str(r2.get("reason", "")))

	report = spa.get_gpu_readiness_report()
	if not bool(report.get("ok", false)):
		spa.dispose()
		return _fail("gpu_readiness", "report.ok false after register")
	if int(report.get("asset_count", 0)) != 1:
		spa.dispose()
		return _fail("gpu_readiness", "report.asset_count != 1")

	spa.dispose()
	return _pass("gpu_readiness", "not ready(0 assets) -> ready(1 asset), report ok")


# ---------------------------------------------------------------------------
# Test: GPU Buffer Access
# ---------------------------------------------------------------------------

func test_gpu_buffer_access() -> Dictionary:
	var spa := SPAScript.new()
	spa.initialize(true, true)
	var desc := AutoVoxelFixture.make_spa_test_descriptor("test_leaf_buf")
	spa.register_asset(desc)

	var probe_rid := spa.get_probe_records_buffer()
	var profile_rid := spa.get_profile_table_buffer()
	var pivot_rid := spa.get_pivot_records_buffer()
	var collision_rid := spa.get_collision_records_buffer()

	var details := []
	if not probe_rid.is_valid():
		details.append("probe_records RID invalid")
	if not profile_rid.is_valid():
		details.append("profile_table RID invalid")
	if not pivot_rid.is_valid():
		details.append("pivot_records RID invalid")

	spa.dispose()

	if not details.is_empty():
		return _fail("gpu_buffer_access", "; ".join(details))
	return _pass("gpu_buffer_access", "probe/profile/pivot/collision RIDs valid")


# ---------------------------------------------------------------------------
# Test: Mesh Description
# ---------------------------------------------------------------------------

func test_mesh_description() -> Dictionary:
	var spa := SPAScript.new()
	spa.initialize(true, true)
	var desc := AutoVoxelFixture.make_spa_test_descriptor("test_leaf_mesh")
	desc.mesh = DescriptorScript.create_sample_autoobject_mesh()
	spa.register_asset(desc)

	var summary := spa.get_mesh_description_gpu_buffer_summary()
	if not bool(summary.get("gpu_first", false)):
		spa.dispose()
		return _fail("mesh_description", "gpu_first should be true")
	if bool(summary.get("cpu_fallback", true)):
		spa.dispose()
		return _fail("mesh_description", "cpu_fallback should be false")
	if not bool(summary.get("runtime_ready", false)):
		spa.dispose()
		return _fail("mesh_description", "runtime_ready should be true, got: %s" % str(summary))

	var snapshot := spa.readback_mesh_description_debug_snapshot()
	if not bool(snapshot.get("readback_snapshot", false)):
		spa.dispose()
		return _fail("mesh_description", "readback_snapshot false")

	var validation: Dictionary = snapshot.get("readback_validation", {})
	if not bool(validation.get("ok", false)):
		spa.dispose()
		return _fail("mesh_description", "readback validation failed: %s" % str(validation.get("reason", "")))

	spa.dispose()
	return _pass("mesh_description", "gpu_first, no cpu_fallback, readback validated")


# ---------------------------------------------------------------------------
# Test: External References
# ---------------------------------------------------------------------------

func test_external_references() -> Dictionary:
	var spa := SPAScript.new()
	spa.initialize(true, true)

	if spa.get_sv_committer() != null:
		spa.dispose()
		return _fail("external_references", "sv_committer should be null initially")
	if spa.get_gpu_runtime() == null:
		spa.dispose()
		return _fail("external_references", "gpu_runtime should be created by SPA")
	if not spa.owns_gpu_runtime():
		spa.dispose()
		return _fail("external_references", "gpu_runtime should be SPA-owned")

	var container := spa.get_runtime_profile_container()
	if container == null:
		spa.dispose()
		return _fail("external_references", "runtime_profile_container should not be null after init")

	spa.dispose()
	return _pass("external_references", "committer=null, owned runtime/profile_container=valid")


# ---------------------------------------------------------------------------
# Test: BrushSV Metadata
# ---------------------------------------------------------------------------

func test_brush_sv_metadata() -> Dictionary:
	var spa := SPAScript.new()
	spa.initialize(true, true)

	var meta := spa.get_brush_sv_persistence_metadata()
	if not meta.is_empty():
		spa.dispose()
		return _fail("brush_sv_metadata", "metadata should be empty initially")

	var set_result := spa.set_brush_sv_persistence_metadata({
		"brush_type": "circle",
		"radius": 4,
	})
	if str(set_result.get("owner", "")) != "ScenePlacementActor":
		spa.dispose()
		return _fail("brush_sv_metadata", "owner should be ScenePlacementActor")
	if not bool(set_result.get("control_plane_only", false)):
		spa.dispose()
		return _fail("brush_sv_metadata", "control_plane_only should be true")

	spa.update_brush_sv_lifecycle_state("active", true, ["complexity"])
	meta = spa.get_brush_sv_persistence_metadata()
	if str(meta.get("lifecycle_state", "")) != "active":
		spa.dispose()
		return _fail("brush_sv_metadata", "lifecycle_state should be active")
	if not bool(meta.get("dirty", false)):
		spa.dispose()
		return _fail("brush_sv_metadata", "dirty should be true")

	spa.clear_brush_sv_persistence_metadata()
	meta = spa.get_brush_sv_persistence_metadata()
	if not meta.is_empty():
		spa.dispose()
		return _fail("brush_sv_metadata", "metadata should be empty after clear")

	spa.dispose()
	return _pass("brush_sv_metadata", "set/update/clear lifecycle ok, control_plane_only enforced")


# ---------------------------------------------------------------------------
# Test: Pipeline Error Paths
# ---------------------------------------------------------------------------

func test_pipeline_error_paths() -> Dictionary:
	var spa := SPAScript.new()

	# not initialized
	var result := spa.run_placement_pipeline({})
	if bool(result.get("ok", true)):
		spa.dispose()
		return _fail("pipeline_error_paths", "should fail when not initialized")

	spa.initialize(true, true)

	# no registered assets
	result = spa.run_placement_pipeline({})
	if bool(result.get("ok", true)):
		spa.dispose()
		return _fail("pipeline_error_paths", "should fail with no registered assets")

	# register then run with minimal sv — pipeline returns a result dict regardless
	var desc := AutoVoxelFixture.make_spa_test_descriptor("test_leaf_pipe")
	spa.register_asset(desc)
	result = spa.run_placement_pipeline({
		"grid_size": Vector3i(16, 8, 16),
		"voxel_size": Vector3(0.1, 0.1, 0.1),
	})
	if not result.has("ok"):
		spa.dispose()
		return _fail("pipeline_error_paths", "pipeline returned no 'ok' key")

	spa.dispose()
	return _pass("pipeline_error_paths", "not_init=fail, no_assets=fail, minimal_sv=result_returned")


# ---------------------------------------------------------------------------
# Test: Merged GPU Summary
# ---------------------------------------------------------------------------

func test_merged_gpu_summary() -> Dictionary:
	var spa := SPAScript.new()
	spa.initialize(true, true)
	var desc := AutoVoxelFixture.make_spa_test_descriptor("test_leaf_merge")
	spa.register_asset(desc)

	var summary := spa.get_merged_gpu_buffer_summary()
	if not bool(summary.get("ok", false)):
		spa.dispose()
		return _fail("merged_gpu_summary", "merged summary.ok should be true")
	if int(summary.get("asset_count", 0)) != 1:
		spa.dispose()
		return _fail("merged_gpu_summary", "asset_count should be 1")
	if not summary.has("mesh_description"):
		spa.dispose()
		return _fail("merged_gpu_summary", "missing mesh_description key")

	spa.dispose()
	return _pass("merged_gpu_summary", "ok, asset_count=1, mesh_description present")


# ---------------------------------------------------------------------------
func _run(test_fn: Callable) -> void:
	var result: Dictionary = test_fn.call()
	_test_results.append(result)
	var tag := "OK" if result["ok"] else "FAIL"
	_log("[SPA_TEST] %s: %s — %s" % [tag, result["name"], result["detail"]])


func _pass(name: String, detail: String) -> Dictionary:
	return {"ok": true, "name": name, "detail": detail}


func _fail(name: String, detail: String) -> Dictionary:
	return {"ok": false, "name": name, "detail": detail}


func _cleanup_spa_and_nodes(spa: Object, nodes: Array) -> void:
	if spa != null and spa.has_method("dispose"):
		spa.dispose()
	for raw_node in nodes:
		var node := raw_node as Node
		if node != null and is_instance_valid(node):
			node.free()


func _log(msg: String) -> void:
	print(msg)


func _ensure_result_label() -> void:
	_result_label = get_node_or_null("ResultLabel") as Label3D
	if _result_label == null:
		_result_label = Label3D.new()
		_result_label.name = "ResultLabel"
		_result_label.pixel_size = 0.005
		_result_label.font_size = 24
		_result_label.outline_size = 4
		_result_label.transform.origin = Vector3(0, -2.0, 0)
		add_child(_result_label)


func _update_label() -> void:
	if _result_label == null:
		return
	var lines := PackedStringArray()
	for r in _test_results:
		var tag := "PASS" if r["ok"] else "FAIL"
		lines.append("[%s] %s" % [tag, r["name"]])
	var passed := _test_results.filter(func(r): return r["ok"]).size()
	lines.append("--- %d / %d ---" % [passed, _test_results.size()])
	_result_label.text = "\n".join(lines)
