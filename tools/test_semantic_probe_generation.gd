extends SceneTree

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const AssetDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")

const TEST_LEAF_ASSET_PATH := "res://assets/vegetation/sm_test_leaf_test2_asset.tres"
const TEST_LEAF_COLOR := Color(0.35, 0.58, 0.24, 0.45)
const TEST_LEAF_COMPLEXITY := 0.45


func _init() -> void:
	var ok := true
	ok = ok and _test_leaf_asset_probe_generation()
	ok = ok and _test_probe_density_scaling()
	ok = ok and _test_convex_probe_generation()
	ok = ok and _test_collision_sample_probe_generation()
	ok = ok and _test_world_min_distance_constant()
	ok = ok and _test_asset_instance_probe_transfer()

	if ok:
		print("[SemanticProbeGeneration] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[SemanticProbeGeneration] SOME TESTS FAILED")
		quit(1)


func _test_leaf_asset_probe_generation() -> bool:
	print("[SemanticProbeGeneration] test_leaf_asset_probe_generation...")
	var asset = _load_test_leaf_asset()
	if asset == null:
		return false

	var probes: Array = asset.call("get_semantic_probes", 1.0)
	if probes.size() < 8:
		push_error("  FAIL: expected mesh probes at density 1.0, got only %d" % probes.size())
		return false

	for i in range(probes.size()):
		if not _validate_leaf_probe(asset, probes[i], i):
			return false

	print("  OK: %d probes %s" % [probes.size(), _probe_signature(probes)])
	return true


func _test_probe_density_scaling() -> bool:
	print("[SemanticProbeGeneration] test_probe_density_scaling...")
	var asset = _load_test_leaf_asset()
	if asset == null:
		return false

	var low: Array = asset.call("get_semantic_probes", 0.5)
	var base: Array = asset.call("get_semantic_probes", 1.0)
	var high: Array = asset.call("get_semantic_probes", 2.0)

	if low.size() < 4:
		push_error("  FAIL: expected at least 4 probes at density 0.5, got %d" % low.size())
		return false
	if base.size() <= low.size():
		push_error("  FAIL: density 1.0 should produce more probes than 0.5 (%d <= %d)" % [base.size(), low.size()])
		return false
	if high.size() <= base.size():
		push_error("  FAIL: density 2.0 should produce more probes than 1.0 (%d <= %d)" % [high.size(), base.size()])
		return false

	print("  OK: density counts low/base/high = %d/%d/%d" % [low.size(), base.size(), high.size()])
	return true


func _test_convex_probe_generation() -> bool:
	print("[SemanticProbeGeneration] test_convex_probe_generation...")
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.0, 4.0, 1.0)

	var probes := SemanticProbeProfileScript.generate_from_mesh(
		mesh,
		[],
		TEST_LEAF_COLOR,
		TEST_LEAF_COMPLEXITY,
		1.0,
		32
	)
	var convex_count := 0
	var convex_keys := {}
	for convex_point in SemanticProbeProfileScript.collect_mesh_convex_points(mesh):
		convex_keys[_point_key(convex_point)] = true
	var aabb := mesh.get_aabb()
	for i in range(probes.size()):
		var probe := probes[i] as Dictionary
		var offset := SemanticProbeProfileScript.vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
		if not _aabb_has_point(aabb, offset, 0.001):
			push_error("  FAIL: convex probe %d offset %s outside mesh aabb %s" % [i, str(offset), str(aabb)])
			return false
		if str(probe.get("shape_source", "")) == "convex":
			convex_count += 1

	if convex_count <= 0:
		push_error("  FAIL: expected at least one convex-sourced probe")
		return false
	var expected_convex_count = mini(convex_keys.size(), probes.size())
	if convex_count < expected_convex_count:
		push_error("  FAIL: expected convex probes to be retained first, got %d/%d" % [convex_count, expected_convex_count])
		return false

	print("  OK: convex probes=%d/%d" % [convex_count, probes.size()])
	return true


func _test_collision_sample_probe_generation() -> bool:
	print("[SemanticProbeGeneration] test_collision_sample_probe_generation...")
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.0, 2.0, 2.0)
	var probes := SemanticProbeProfileScript.generate_from_mesh(
		mesh,
		[
			{
				"local_pos": Vector3(0.0, 0.0, 0.0),
				"color": TEST_LEAF_COLOR,
				"complexity": TEST_LEAF_COMPLEXITY,
				"collision": 0.8,
			},
			{
				"local_pos": Vector3(0.3, 0.2, -0.1),
				"color": TEST_LEAF_COLOR,
				"complexity": TEST_LEAF_COMPLEXITY,
				"collision": 0.8,
			},
		],
		TEST_LEAF_COLOR,
		TEST_LEAF_COMPLEXITY,
		1.0,
		32
	)
	var voxel_count := 0
	for raw_probe in probes:
		var probe := raw_probe as Dictionary
		if str(probe.get("shape_source", "")) != "voxel_interior":
			continue
		voxel_count += 1
		if float(probe.get("w_collision", 0.0)) <= 0.0:
			push_error("  FAIL: voxel probe w_collision should be > 0")
			return false
		if not _approx(float(probe.get("expected_collision", 0.0)), 0.8, 0.001):
			push_error("  FAIL: voxel probe expected_collision mismatch")
			return false
	if voxel_count <= 0:
		push_error("  FAIL: expected at least one voxel_interior probe")
		return false
	print("  OK: voxel_interior probes=%d/%d" % [voxel_count, probes.size()])
	return true


func _test_world_min_distance_constant() -> bool:
	print("[SemanticProbeGeneration] test_world_min_distance_constant...")
	var small := SemanticProbeProfileScript.probe_min_distance([], 1.0, SemanticProbeProfileScript.PROBE_WORLD_MIN_DISTANCE)
	var dense := SemanticProbeProfileScript.probe_min_distance([], 4.0, SemanticProbeProfileScript.PROBE_WORLD_MIN_DISTANCE)
	if not _approx(small, 0.35, 0.001):
		push_error("  FAIL: world min distance at density 1.0 should be 0.35, got %.3f" % small)
		return false
	if not _approx(dense, 0.175, 0.001):
		push_error("  FAIL: world min distance at density 4.0 should be 0.175, got %.3f" % dense)
		return false
	print("  OK: world min distance density 1/4 = %.3f/%.3f" % [small, dense])
	return true


func _test_asset_instance_probe_transfer() -> bool:
	print("[SemanticProbeGeneration] test_asset_instance_probe_transfer...")
	var asset = _load_test_leaf_asset()
	if asset == null:
		return false

	asset.set("semantic_probe_density", 2.0)
	var config: Dictionary = asset.call("make_instance_config")
	if not config.has("semantic_probes"):
		push_error("  FAIL: make_instance_config did not include semantic_probes")
		return false
	var config_probes: Array = config.semantic_probes
	if config_probes.size() < 16:
		push_error("  FAIL: expected mesh-derived config probes at asset density 2.0, got %d" % config_probes.size())
	print("  OK: descriptor-backed instance_config contains %d probes" % config_probes.size())
	return true


func _load_test_leaf_asset() -> Resource:
	var resource := load(TEST_LEAF_ASSET_PATH)
	if resource == null or resource.get_script() != AssetDescriptorScript:
		push_error("  FAIL: could not load AssetDescriptor at %s" % TEST_LEAF_ASSET_PATH)
		return null
	var asset := resource
	if asset.get("asset_id") != "sm_test_leaf_test2":
		push_error("  FAIL: unexpected asset_id %s" % asset.get("asset_id"))
		return null
	if asset.get("object_subtype") != "test_leaf":
		push_error("  FAIL: unexpected subtype %s" % asset.get("object_subtype"))
		return null
	if asset.call("get_mesh") == null:
		push_error("  FAIL: asset has no mesh")
		return null
	var collision: Array = asset.call("get_collision")
	if collision.size() != 0:
		push_error("  FAIL: test leaf should not generate collision samples")
		return null
	return asset


func _validate_leaf_probe(asset: Resource, probe: Dictionary, index: int) -> bool:
	for key in ["offset", "expected_color", "expected_complexity", "expected_rgba8", "expected_collision", "w_color", "w_complexity", "w_collision", "source"]:
		if not probe.has(key):
			push_error("  FAIL: probe %d missing key %s" % [index, key])
			return false

	var offset := SemanticProbeProfileScript.vector3_from_value(probe.offset, Vector3.ZERO)
	var mesh = asset.call("get_mesh")
	var aabb: AABB = mesh.get_aabb() if mesh is Mesh else AABB()
	if not _aabb_has_point(aabb, offset, 0.001):
		push_error("  FAIL: probe %d offset %s outside mesh aabb %s" % [index, str(offset), str(aabb)])
		return false

	var expected_color: Color = probe.expected_color
	if not _color_close(expected_color, TEST_LEAF_COLOR, 0.001):
		push_error("  FAIL: probe %d color %s != %s" % [index, expected_color, TEST_LEAF_COLOR])
		return false
	if not _approx(float(probe.expected_complexity), TEST_LEAF_COMPLEXITY, 0.001):
		push_error("  FAIL: probe %d complexity %.3f != %.3f" % [index, float(probe.expected_complexity), TEST_LEAF_COMPLEXITY])
		return false
	if int(probe.expected_rgba8) != SemanticProbeProfileScript.pack_rgba8(TEST_LEAF_COLOR):
		push_error("  FAIL: probe %d expected_rgba8 mismatch" % index)
		return false
	if not _approx(float(probe.expected_collision), 0.0, 0.001):
		push_error("  FAIL: probe %d expected_collision should be 0" % index)
		return false
	if not _approx(float(probe.get("w_color", 0.0)), 1.0, 0.01):
		push_error("  FAIL: probe %d w_color should be 1.0" % index)
		return false
	if not _approx(float(probe.get("w_complexity", 0.0)), 1.0, 0.01):
		push_error("  FAIL: probe %d w_complexity should be 1.0" % index)
		return false
	if not _approx(float(probe.get("w_collision", 0.0)), 1.0, 0.01):
		push_error("  FAIL: probe %d w_collision should be 1.0" % index)
		return false
	if str(probe.source) != "mesh":
		push_error("  FAIL: probe %d source should be mesh, got %s" % [index, str(probe.source)])
		return false

	return true


func _aabb_has_point(aabb: AABB, point: Vector3, eps: float) -> bool:
	var min_p := aabb.position - Vector3.ONE * eps
	var max_p := aabb.position + aabb.size + Vector3.ONE * eps
	return (
		point.x >= min_p.x and point.x <= max_p.x
		and point.y >= min_p.y and point.y <= max_p.y
		and point.z >= min_p.z and point.z <= max_p.z
	)


func _probe_signature(probes: Array) -> String:
	var parts: Array[String] = []
	for raw_probe in probes:
		if not raw_probe is Dictionary:
			continue
		var probe := raw_probe as Dictionary
		var offset := SemanticProbeProfileScript.vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
		parts.append("%d,%d,%d:%d:%.2f,%.2f,%.2f" % [
			roundi(offset.x * 1000.0),
			roundi(offset.y * 1000.0),
			roundi(offset.z * 1000.0),
			int(probe.get("expected_rgba8", 0)),
			float(probe.get("w_color", 0.0)),
			float(probe.get("w_complexity", 0.0)),
			float(probe.get("w_collision", 0.0)),
		])
	return "|".join(parts)


func _point_key(point: Vector3) -> String:
	return "%d,%d,%d" % [
		roundi(point.x * 1000.0),
		roundi(point.y * 1000.0),
		roundi(point.z * 1000.0),
	]


func _color_close(a: Color, b: Color, eps: float) -> bool:
	return (
		_approx(a.r, b.r, eps)
		and _approx(a.g, b.g, eps)
		and _approx(a.b, b.b, eps)
		and _approx(a.a, b.a, eps)
	)


func _approx(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps
