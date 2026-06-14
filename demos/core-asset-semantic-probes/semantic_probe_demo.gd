extends "res://demos/core_demo_contract_fixture.gd"

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")

const LEAF_FBX_PATH := "res://geo/SM_TestLeaf_Test2.FBX"
const CLIFF_FBX_PATH := "res://geo/cliff_01.FBX"

const TEST_MODEL_NODE := "SemanticProbeTestModel"
const ROCK_MODEL_NODE := "SemanticProbeRockModel"
const TEST_MODEL_MESH_NODE := "SourceMesh"
const DEBUG_ROOT_NODE := "SemanticProbeDebug"
const DEBUG_MARKERS_NODE := "ProbeMarkers"
const DEBUG_SUMMARY_NODE := "DebugSummary"
const TEST_MODEL_COLOR := Color(0.35, 0.58, 0.24, 0.45)
const TEST_MODEL_COMPLEXITY := 0.45
const DEBUG_COLLISION := [{
	"shape": "cylinder",
	"radius": 0.9,
	"y_min": -0.5,
	"y_max": 6.5,
	"collision_strength": 0.8,
}]

@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0
@export var max_debug_probe_markers: int = 96

var _generated_probes: Array[Dictionary] = []
var _debug_snapshot: Dictionary = {}
var _debug_generation_count := 0


func _ready() -> void:
	super._ready()
	_ensure_test_model()
	_ensure_rock_model()
	_update_instruction_labels()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or not key_event.shift_pressed:
		return
	match key_event.keycode:
		KEY_P:
			build_semantic_probe_debug()
			_mark_input_as_handled()
		KEY_C:
			clear_semantic_probe_debug()
			_mark_input_as_handled()


func build_semantic_probe_debug() -> Dictionary:
	var model := _ensure_test_model()
	var mesh_instance := model.get_node_or_null(TEST_MODEL_MESH_NODE) as MeshInstance3D
	var mesh := mesh_instance.mesh if mesh_instance != null else null
	_generated_probes = SemanticProbeProfileScript.generate_from_mesh(
		mesh,
		DEBUG_COLLISION,
		TEST_MODEL_COLOR,
		TEST_MODEL_COMPLEXITY,
		semantic_probe_density,
		max_debug_probe_markers
	)

	_clear_node(DEBUG_ROOT_NODE)
	var debug_root := Node3D.new()
	debug_root.name = DEBUG_ROOT_NODE
	debug_root.position = model.position
	add_child(debug_root)

	debug_root.add_child(_make_collision_debug_mesh())
	var markers := Node3D.new()
	markers.name = DEBUG_MARKERS_NODE
	debug_root.add_child(markers)
	for i in range(mini(_generated_probes.size(), max_debug_probe_markers)):
		markers.add_child(_make_probe_marker(_generated_probes[i], i))

	var summary := _make_debug_summary()
	var label := _make_summary_label(summary)
	debug_root.add_child(label)
	_debug_generation_count += 1
	_debug_snapshot = summary
	return _debug_snapshot.duplicate(true)


func clear_semantic_probe_debug() -> void:
	_clear_node(DEBUG_ROOT_NODE)
	_generated_probes.clear()
	_debug_snapshot = {
		"debug_root_exists": false,
		"probe_count": 0,
		"debug_generation_count": _debug_generation_count,
	}


func get_semantic_probe_debug_snapshot() -> Dictionary:
	return _debug_snapshot.duplicate(true)


func get_generated_semantic_probes() -> Array[Dictionary]:
	return SemanticProbeProfileScript.duplicate_probe_array(_generated_probes)


func get_semantic_probe_shortcuts() -> Dictionary:
	return {
		"build_debug": "Shift+P",
		"clear_debug": "Shift+C",
	}


func _ensure_test_model() -> Node3D:
	var existing := get_node_or_null(TEST_MODEL_NODE) as Node3D
	if existing != null:
		return existing

	var root := Node3D.new()
	root.name = TEST_MODEL_NODE
	root.position = Vector3(-1.6, 0.0, 0.0)
	add_child(root)

	var mesh := _load_fbx_mesh(LEAF_FBX_PATH)
	if mesh == null:
		mesh = _make_fallback_box()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = TEST_MODEL_MESH_NODE
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _make_test_model_material()
	root.add_child(mesh_instance)

	var label := Label3D.new()
	label.name = "TestModelLabel"
	label.text = "Tree (Leaf FBX)\nShift+P: build probe debug\nShift+C: clear debug"
	label.position = Vector3(0.0, 1.6, 0.0)
	label.font_size = 24
	label.pixel_size = 0.01
	label.outline_size = 4
	root.add_child(label)
	return root


func _ensure_rock_model() -> Node3D:
	var existing := get_node_or_null(ROCK_MODEL_NODE) as Node3D
	if existing != null:
		return existing

	var root := Node3D.new()
	root.name = ROCK_MODEL_NODE
	root.position = Vector3(2.5, 0.0, 0.0)
	add_child(root)

	var mesh := _load_fbx_mesh(CLIFF_FBX_PATH)
	if mesh == null:
		mesh = _make_fallback_box()

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "RockMesh"
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _make_rock_material()
	root.add_child(mesh_instance)

	var label := Label3D.new()
	label.name = "RockModelLabel"
	label.text = "Cliff (Rock FBX)"
	label.position = Vector3(0.0, 1.6, 0.0)
	label.font_size = 24
	label.pixel_size = 0.01
	label.outline_size = 4
	root.add_child(label)
	return root


func _load_fbx_mesh(path: String) -> Mesh:
	var scene := load(path) as PackedScene
	if scene == null:
		push_warning("[SemanticProbeDemo] failed to load FBX scene: %s" % path)
		return null
	var instance := scene.instantiate()
	if instance == null:
		push_warning("[SemanticProbeDemo] failed to instantiate FBX scene: %s" % path)
		return null
	var mesh := _find_first_mesh(instance)
	if mesh == null:
		push_warning("[SemanticProbeDemo] no MeshInstance3D found in: %s" % path)
		instance.free()
		return null
	var result := mesh.duplicate(true)
	instance.free()
	return result


func _find_first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh
	for child in node.get_children():
		var result := _find_first_mesh(child)
		if result != null:
			return result
	return null


func _make_fallback_box() -> BoxMesh:
	var box := BoxMesh.new()
	box.size = Vector3(1.4, 2.2, 0.9)
	return box


func _make_rock_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.48, 0.42, 0.35, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return mat


func _make_debug_summary() -> Dictionary:
	var convex_count := 0
	var surface_count := 0
	var collision_count := 0
	for probe in _generated_probes:
		match str(probe.get("shape_source", "")):
			"convex":
				convex_count += 1
			"surface":
				surface_count += 1
			"voxel_interior":
				collision_count += 1
	return {
		"debug_root_exists": true,
		"probe_count": _generated_probes.size(),
		"marker_count": mini(_generated_probes.size(), max_debug_probe_markers),
		"convex_probe_count": convex_count,
		"surface_probe_count": surface_count,
		"collision_probe_count": collision_count,
		"density": semantic_probe_density,
		"debug_generation_count": _debug_generation_count + 1,
	}


func _make_test_model_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = TEST_MODEL_COLOR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(TEST_MODEL_COLOR.r, TEST_MODEL_COLOR.g, TEST_MODEL_COLOR.b, 1.0)
	mat.emission_energy_multiplier = 0.25
	return mat


func _make_collision_debug_mesh() -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.9
	mesh.bottom_radius = 0.9
	mesh.height = 7.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.1, 0.65, 1.0, 0.22)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var node := MeshInstance3D.new()
	node.name = "CollisionDebugVolume"
	node.mesh = mesh
	node.position = Vector3(0.0, 3.0, 0.0)
	node.material_override = mat
	return node


func _make_probe_marker(probe: Dictionary, index: int) -> MeshInstance3D:
	var shape_source := str(probe.get("shape_source", "unknown"))
	var mesh := SphereMesh.new()
	mesh.radius = 0.08
	mesh.height = 0.16
	var color := Color(0.4, 1.0, 0.4, 0.95)
	if shape_source == "convex":
		color = Color(1.0, 0.85, 0.1, 0.95)
	elif shape_source == "voxel_interior":
		color = Color(0.15, 0.75, 1.0, 0.95)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.7
	var marker := MeshInstance3D.new()
	marker.name = "Probe_%03d_%s" % [index, shape_source]
	marker.mesh = mesh
	marker.position = SemanticProbeProfileScript.vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
	marker.material_override = mat
	marker.set_meta("semantic_probe_debug", true)
	marker.set_meta("shape_source", shape_source)
	return marker


func _make_summary_label(summary: Dictionary) -> Label3D:
	var label := Label3D.new()
	label.name = DEBUG_SUMMARY_NODE
	label.position = Vector3(1.8, 1.25, 0.0)
	label.text = "Debug Probes\ncount=%d\nconvex=%d surface=%d collision=%d" % [
		int(summary.get("probe_count", 0)),
		int(summary.get("convex_probe_count", 0)),
		int(summary.get("surface_probe_count", 0)),
		int(summary.get("collision_probe_count", 0)),
	]
	label.font_size = 26
	label.pixel_size = 0.01
	label.outline_size = 5
	return label


func _update_instruction_labels() -> void:
	var method_label := get_node_or_null("TestMethod") as Label3D
	if method_label != null:
		method_label.text = "Method\n- inspect built-in test model\n- Shift+P builds semantic probe debug\n- Shift+C clears generated debug nodes"
	var acceptance_label := get_node_or_null("Acceptance") as Label3D
	if acceptance_label != null:
		acceptance_label.text = "Acceptance\n- test model is visible in scene\n- shortcut creates SemanticProbeDebug nodes\n- debug summary reports generated probes"


func _mark_input_as_handled() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func _clear_node(node_name: String) -> void:
	var existing := get_node_or_null(node_name)
	if existing != null:
		existing.free()