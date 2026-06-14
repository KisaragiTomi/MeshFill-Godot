extends SceneTree

const MainScript := preload("res://scripts/main.gd")
const AssetDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")

const TEST_LEAF_ASSET_PATH := "res://assets/vegetation/sm_test_leaf_test2_asset.tres"


func _init() -> void:
	var ok := _test_debug_anchor_includes_source_mesh()
	ok = ok and _test_debug_anchor_prefers_source_mesh()
	ok = ok and _test_debug_materials()
	if ok:
		print("[SemanticProbeDebugMesh] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[SemanticProbeDebugMesh] SOME TESTS FAILED")
		quit(1)


func _test_debug_anchor_includes_source_mesh() -> bool:
	print("[SemanticProbeDebugMesh] test_debug_anchor_includes_source_mesh...")
	var asset := load(TEST_LEAF_ASSET_PATH)
	if asset == null or asset.get_script() != AssetDescriptorScript:
		push_error("  FAIL: could not load test leaf asset")
		return false

	var main := MainScript.new()
	main.semantic_probe_density = 1.0
	var vegetation_assets: Array[Resource] = []
	vegetation_assets.append(asset)
	main.set("_vegetation_assets", vegetation_assets)

	var samples: Array = main.call("_collect_semantic_probe_debug_assets", 1)
	if samples.size() != 1:
		push_error("  FAIL: expected 1 debug sample, got %d" % samples.size())
		main.free()
		return false

	var sample: Dictionary = samples[0]
	if not sample.get("mesh", null) is Mesh:
		push_error("  FAIL: debug sample does not include probe mesh")
		main.free()
		return false
	if not sample.get("source_mesh", null) is Mesh:
		push_error("  FAIL: debug sample does not include source mesh")
		main.free()
		return false
	if not sample.get("mesh_scale", null) is Vector3:
		push_error("  FAIL: debug sample does not include mesh_scale")
		main.free()
		return false
	if not sample.get("source_mesh_scale", null) is Vector3:
		push_error("  FAIL: debug sample does not include source_mesh_scale")
		main.free()
		return false
	if not sample.get("color", null) is Color:
		push_error("  FAIL: debug sample does not include color")
		main.free()
		return false

	var anchor = main.call("_make_probe_debug_anchor", Vector3.ZERO, sample)
	if anchor == null or not anchor is Node3D:
		push_error("  FAIL: anchor was not created")
		main.free()
		return false

	var source_mesh := (anchor as Node3D).get_node_or_null("SourceMesh")
	if source_mesh == null:
		push_error("  FAIL: anchor does not include SourceMesh")
		anchor.free()
		main.free()
		return false
	if not source_mesh is MeshInstance3D:
		push_error("  FAIL: SourceMesh is not MeshInstance3D")
		anchor.free()
		main.free()
		return false

	var mesh_instance := source_mesh as MeshInstance3D
	if mesh_instance.mesh != sample.source_mesh:
		push_error("  FAIL: SourceMesh mesh does not match sample mesh")
		anchor.free()
		main.free()
		return false
	if mesh_instance.material_override == null:
		push_error("  FAIL: SourceMesh should have a debug material")
		anchor.free()
		main.free()
		return false
	if not mesh_instance.material_override is StandardMaterial3D:
		push_error("  FAIL: SourceMesh debug material should be StandardMaterial3D")
		anchor.free()
		main.free()
		return false
	var source_material := mesh_instance.material_override as StandardMaterial3D
	if source_material.albedo_color.a < 0.55:
		push_error("  FAIL: SourceMesh material should be more opaque")
		anchor.free()
		main.free()
		return false

	print("  OK: sample=%s scale=%s probes=%d" % [
		str(sample.get("name", "")),
		str(mesh_instance.scale),
		(sample.get("probes", []) as Array).size(),
	])
	anchor.free()
	main.free()
	return true


func _test_debug_anchor_prefers_source_mesh() -> bool:
	print("[SemanticProbeDebugMesh] test_debug_anchor_prefers_source_mesh...")
	var main := MainScript.new()
	var probe_mesh := BoxMesh.new()
	probe_mesh.size = Vector3.ONE
	var source_mesh := SphereMesh.new()
	source_mesh.radius = 1.0
	source_mesh.height = 2.0
	var sample := {
		"name": "SourceMeshPreference",
		"mesh": probe_mesh,
		"source_mesh": source_mesh,
		"mesh_scale": Vector3.ONE,
		"source_mesh_scale": Vector3.ONE * 2.0,
		"color": Color(0.4, 0.8, 0.4, 0.5),
		"probes": [],
	}
	var anchor = main.call("_make_probe_debug_anchor", Vector3.ZERO, sample)
	if anchor == null or not anchor is Node3D:
		push_error("  FAIL: anchor was not created")
		main.free()
		return false
	var source_mesh_node := (anchor as Node3D).get_node_or_null("SourceMesh")
	if source_mesh_node == null or not source_mesh_node is MeshInstance3D:
		push_error("  FAIL: anchor does not include SourceMesh")
		anchor.free()
		main.free()
		return false
	var mesh_instance := source_mesh_node as MeshInstance3D
	if mesh_instance.mesh != source_mesh:
		push_error("  FAIL: SourceMesh should use source_mesh, not probe mesh")
		anchor.free()
		main.free()
		return false
	if mesh_instance.scale != Vector3.ONE * 2.0:
		push_error("  FAIL: SourceMesh should use source_mesh_scale")
		anchor.free()
		main.free()
		return false
	print("  OK: SourceMesh prefers explicit source mesh")
	anchor.free()
	main.free()
	return true


func _test_debug_materials() -> bool:
	print("[SemanticProbeDebugMesh] test_debug_materials...")
	var main := MainScript.new()
	var convex_marker = main.call("_make_probe_debug_marker", {
		"offset": Vector3.ZERO,
		"expected_color": Color(0.4, 0.8, 0.4, 1.0),
		"shape_source": "convex",
	}, Vector3.ONE)
	if convex_marker == null or not convex_marker is MeshInstance3D:
		push_error("  FAIL: convex marker was not created")
		main.free()
		return false
	var convex_mesh_instance := convex_marker as MeshInstance3D
	if not convex_mesh_instance.material_override is StandardMaterial3D:
		push_error("  FAIL: convex marker material should be StandardMaterial3D")
		convex_mesh_instance.free()
		main.free()
		return false
	if convex_mesh_instance.mesh == null or convex_mesh_instance.mesh.get_surface_count() <= 0:
		push_error("  FAIL: convex marker should have a line mesh")
		convex_mesh_instance.free()
		main.free()
		return false
	if not convex_mesh_instance.mesh is ImmediateMesh:
		push_error("  FAIL: convex marker should use ImmediateMesh line geometry")
		convex_mesh_instance.free()
		main.free()
		return false
	if not bool(convex_mesh_instance.get_meta("semantic_probe_wireframe", false)):
		push_error("  FAIL: convex marker should be tagged as wireframe")
		convex_mesh_instance.free()
		main.free()
		return false
	print("  OK: convex marker uses ImmediateMesh line geometry, source alpha target>=0.55")
	convex_mesh_instance.free()
	main.free()
	return true
