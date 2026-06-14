extends "res://demos/core_demo_contract_fixture.gd"

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const AutoAssetFactory := preload("res://scripts/auto_asset_factory.gd")

const LEAF_FBX_PATH := "res://geo/SM_TestLeaf_Test2.FBX"
const CLIFF1_FBX_PATH := "res://geo/cliff_01.FBX"
const CLIFF2_FBX_PATH := "res://geo/cliff_02.FBX"

const PROBE_DEBUG_NODE := "ProbeDebugGroup"
const COLLISION_DEBUG_NODE := "CollisionDebugGroup"
const BUFFER_INFO_NODE := "BufferInfoOverlay"

const TREE_COLOR := Color(0.35, 0.58, 0.24, 0.55)
const TREE_COMPLEXITY := 0.45
const TREE_COLLISION := [{
	"shape": "cylinder",
	"radius": 0.35,
	"y_min": -0.5,
	"y_max": 1.2,
	"collision_strength": 0.7,
}]

const ROCK_COLOR := Color(0.48, 0.42, 0.35, 0.7)
const ROCK_COMPLEXITY := 0.75
const ROCK_COLLISION := [{
	"shape": "cylinder",
	"radius": 0.55,
	"y_min": -0.4,
	"y_max": 0.8,
	"collision_strength": 0.9,
}]

@export_range(0.1, 8.0, 0.1) var probe_density: float = 1.0
@export var max_probe_markers: int = 96

var _tree_nodes: Array[Node3D] = []
var _rock_nodes: Array[Node3D] = []
var _tree_probes: Array[Dictionary] = []
var _rock_probes: Array[Dictionary] = []
var _tree_probes_visible := false
var _rock_probes_visible := false
var _collision_visible := false
var _buffer_info_visible := false


func _ready() -> void:
	super._ready()
	_place_assets()
	_update_instruction_labels()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return

	match ke.keycode:
		KEY_1:
			_toggle_tree_probes()
			_mark_handled()
		KEY_2:
			_toggle_rock_probes()
			_mark_handled()
		KEY_3:
			_toggle_all_probes()
			_mark_handled()
		KEY_C:
			_clear_all_debug()
			_mark_handled()
		KEY_V:
			_toggle_collision_volumes()
			_mark_handled()
		KEY_B:
			_toggle_buffer_info()
			_mark_handled()


# Trees use leaf FBX; rocks use two cliff FBX variants. Mesh comes from
# AutoAssetFactory.load_mesh() which bakes the FBX import rotation (-90° Z-up→Y-up)
# and UCX collision filtering into the vertices, so meshes arrive upright.
# Ground height and row spacing are derived from each baked mesh's real AABB,
# never hand-tuned constants.
const ROW_GAP := 0.6
const ASSET_BASE_LIFT := 0.0

func _place_assets() -> void:
	var rows := {
		"tree": {
			"z_base": 0.6,
			"items": [
				{"fbx": LEAF_FBX_PATH, "scale": 0.22, "rot_y": 0.0, "z_jit": 0.0},
				{"fbx": LEAF_FBX_PATH, "scale": 0.24, "rot_y": 0.0, "z_jit": 0.6},
				{"fbx": LEAF_FBX_PATH, "scale": 0.20, "rot_y": 0.0, "z_jit": 0.0},
				{"fbx": LEAF_FBX_PATH, "scale": 0.22, "rot_y": 0.0, "z_jit": 0.4},
			],
		},
		"rock": {
			"z_base": 2.7,
			"items": [
				{"fbx": CLIFF1_FBX_PATH, "scale": 0.42, "rot_y": 0.0, "z_jit": 0.0},
				{"fbx": CLIFF2_FBX_PATH, "scale": 0.40, "rot_y": 0.0, "z_jit": -0.2},
				{"fbx": CLIFF1_FBX_PATH, "scale": 0.38, "rot_y": 0.0, "z_jit": 0.3},
				{"fbx": CLIFF2_FBX_PATH, "scale": 0.40, "rot_y": 0.0, "z_jit": 0.0},
			],
		},
	}

	for asset_type in ["tree", "rock"]:
		var row: Dictionary = rows[asset_type]
		var items: Array = row["items"]
		var resolved := []
		for it in items:
			var mesh := _resolve_mesh(it["fbx"])
			var aabb := mesh.get_aabb()
			var scale := float(it["scale"])
			# Rotation-invariant horizontal footprint radius: circumscribed-circle
			# radius of the XZ extent (half the XZ diagonal). This is the true upper
			# bound of the horizontal envelope for any rot_y, so a max-extent estimate
			# would under-spread and let rotated assets overlap.
			var foot_radius := 0.5 * sqrt(aabb.size.x * aabb.size.x + aabb.size.z * aabb.size.z) * scale
			# Lift so the baked mesh bottom rests on y=0.
			var ground_y := -aabb.position.y * scale + ASSET_BASE_LIFT
			resolved.append({
				"mesh": mesh,
				"scale": scale,
				"rot_y": float(it["rot_y"]),
				"z": float(row["z_base"]) + float(it["z_jit"]),
				"ground_y": ground_y,
				"foot_radius": foot_radius,
				"type": asset_type,
			})

		var xs := _layout_row_x(resolved)
		for i in range(resolved.size()):
			var r: Dictionary = resolved[i]
			var pos := Vector3(xs[i], r["ground_y"], r["z"])
			var node := _spawn_asset(r["mesh"], pos, Vector3(r["scale"], r["scale"], r["scale"]), r["rot_y"], r["type"])
			if asset_type == "tree":
				_tree_nodes.append(node)
			else:
				_rock_nodes.append(node)


# Centered single-axis packing: adjacent centers spaced by the sum of footprint
# radii plus ROW_GAP, then the whole row is recentered on x=0.
func _layout_row_x(resolved: Array) -> Array:
	var xs := []
	xs.resize(resolved.size())
	if resolved.is_empty():
		return xs
	var cursor := 0.0
	xs[0] = 0.0
	for i in range(1, resolved.size()):
		cursor += float(resolved[i - 1]["foot_radius"]) + float(resolved[i]["foot_radius"]) + ROW_GAP
		xs[i] = cursor
	var span := float(xs[resolved.size() - 1])
	var center_shift := span * 0.5
	for i in range(xs.size()):
		xs[i] = float(xs[i]) - center_shift
	return xs


func _resolve_mesh(fbx_path: String) -> Mesh:
	var mesh := AutoAssetFactory.load_mesh(fbx_path)
	if mesh == null:
		mesh = _make_fallback_box()
	return mesh


func _spawn_asset(mesh: Mesh, position: Vector3, scale: Vector3, rot_y_deg: float, asset_type: String) -> Node3D:
	var container := Node3D.new()
	container.name = "%s_%d" % [asset_type, randi()]
	container.position = position
	container.scale = scale
	container.rotation_degrees.y = rot_y_deg
	add_child(container)

	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	if asset_type == "tree":
		mi.material_override = _make_tree_material()
	else:
		mi.material_override = _make_rock_material()
	container.add_child(mi)

	var mat_label := Label3D.new()
	mat_label.name = "AssetLabel"
	mat_label.text = "Tree" if asset_type == "tree" else "Rock"
	mat_label.position = Vector3(0.0, 1.8, 0.0)
	mat_label.font_size = 18
	mat_label.pixel_size = 0.01
	mat_label.outline_size = 3
	container.add_child(mat_label)

	return container


# ─── Probe Debug ──────────────────────────────────────────────

func _toggle_tree_probes() -> void:
	if _tree_probes_visible:
		_clear_probe_group("TreeProbes")
		_tree_probes.clear()
		_tree_probes_visible = false
	else:
		_build_probes(_tree_nodes, "TreeProbes", TREE_COLOR, TREE_COMPLEXITY, TREE_COLLISION, _tree_probes)
		_tree_probes_visible = true


func _toggle_rock_probes() -> void:
	if _rock_probes_visible:
		_clear_probe_group("RockProbes")
		_rock_probes.clear()
		_rock_probes_visible = false
	else:
		_build_probes(_rock_nodes, "RockProbes", ROCK_COLOR, ROCK_COMPLEXITY, ROCK_COLLISION, _rock_probes)
		_rock_probes_visible = true


func _toggle_all_probes() -> void:
	if _tree_probes_visible or _rock_probes_visible:
		_clear_all_debug()
	else:
		_build_probes(_tree_nodes, "TreeProbes", TREE_COLOR, TREE_COMPLEXITY, TREE_COLLISION, _tree_probes)
		_build_probes(_rock_nodes, "RockProbes", ROCK_COLOR, ROCK_COMPLEXITY, ROCK_COLLISION, _rock_probes)
		_tree_probes_visible = true
		_rock_probes_visible = true


func _build_probes(nodes: Array[Node3D], group_name: String, color: Color, complexity: float, collision: Array, out_probes: Array) -> void:
	var debug_root := _get_or_create_debug_root()

	var group := Node3D.new()
	group.name = group_name
	debug_root.add_child(group)

	for i in range(nodes.size()):
		var node := nodes[i]
		var mi := node.get_node_or_null("Mesh") as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue

		var probes := SemanticProbeProfileScript.generate_from_mesh(
			mi.mesh, collision, color, complexity, probe_density, max_probe_markers
		)
		out_probes.append_array(probes)

		# Per-asset debug sub-node at world origin (no inherited scale)
		var asset_debug := Node3D.new()
		asset_debug.name = "%s_%d" % [group_name, i]
		group.add_child(asset_debug)

		for j in range(mini(probes.size(), max_probe_markers)):
			var marker := _make_probe_marker(probes[j], j)
			var local_offset := SemanticProbeProfileScript.vector3_from_value(
				probes[j].get("offset", Vector3.ZERO), Vector3.ZERO
			)
			# Convert mesh-local offset to world position via container transform
			marker.position = node.to_global(local_offset)
			asset_debug.add_child(marker)

		# Summary label above asset in world space
		var sum_label := Label3D.new()
		sum_label.name = "ProbeCount"
		sum_label.text = "probes=%d" % mini(probes.size(), max_probe_markers)
		sum_label.position = node.position + Vector3(0.0, 2.5, 0.0)
		sum_label.font_size = 20
		sum_label.pixel_size = 0.01
		sum_label.outline_size = 4
		asset_debug.add_child(sum_label)


# ─── Collision Volumes ────────────────────────────────────────

func _toggle_collision_volumes() -> void:
	if _collision_visible:
		_clear_node(COLLISION_DEBUG_NODE)
		_collision_visible = false
	else:
		_build_collision_volumes()
		_collision_visible = true


func _build_collision_volumes() -> void:
	var root := Node3D.new()
	root.name = COLLISION_DEBUG_NODE
	add_child(root)

	for node in _tree_nodes:
		var cyl := _make_collision_cylinder(TREE_COLLISION[0], Color(0.1, 0.65, 1.0, 0.25))
		cyl.position = node.position
		root.add_child(cyl)

	for node in _rock_nodes:
		var cyl := _make_collision_cylinder(ROCK_COLLISION[0], Color(1.0, 0.4, 0.1, 0.25))
		cyl.position = node.position
		root.add_child(cyl)


# ─── Buffer Info Overlay ──────────────────────────────────────

func _toggle_buffer_info() -> void:
	if _buffer_info_visible:
		_clear_node(BUFFER_INFO_NODE)
		_buffer_info_visible = false
	else:
		_build_buffer_info()
		_buffer_info_visible = true


func _build_buffer_info() -> void:
	var root := Node3D.new()
	root.name = BUFFER_INFO_NODE
	# Place to the right of scene, slightly elevated, facing camera
	root.position = Vector3(4.0, 1.5, 2.0)
	add_child(root)

	var info := Label3D.new()
	info.name = "BufferInfoText"
	info.text = _format_buffer_info()
	info.font_size = 32
	info.pixel_size = 0.01
	info.outline_size = 6
	root.add_child(info)


func _format_buffer_info() -> String:
	var tree_count := _tree_nodes.size()
	var rock_count := _rock_nodes.size()
	var tree_probes_total := 0
	var rock_probes_total := 0
	for probes in _tree_probes:
		tree_probes_total += probes.size()
	for probes in _rock_probes:
		rock_probes_total += probes.size()

	return ("BUFFER/PROBE INFO\n" +
		"Trees: %d  Rocks: %d\n" +
		"Tree probes: %d  Rock probes: %d\n" +
		"Tree color: %.2f/%.2f/%.2f complexity: %.2f\n" +
		"Rock color: %.2f/%.2f/%.2f complexity: %.2f\n" +
		"Density: %.1f  Max markers: %d"
	) % [
		tree_count, rock_count,
		tree_probes_total, rock_probes_total,
		TREE_COLOR.r, TREE_COLOR.g, TREE_COLOR.b, TREE_COMPLEXITY,
		ROCK_COLOR.r, ROCK_COLOR.g, ROCK_COLOR.b, ROCK_COMPLEXITY,
		probe_density, max_probe_markers,
	]


# ─── Clear ────────────────────────────────────────────────────

func _clear_all_debug() -> void:
	_clear_probe_group("TreeProbes")
	_clear_probe_group("RockProbes")
	_clear_node(COLLISION_DEBUG_NODE)
	_clear_node(BUFFER_INFO_NODE)
	_tree_probes.clear()
	_rock_probes.clear()
	_tree_probes_visible = false
	_rock_probes_visible = false
	_collision_visible = false
	_buffer_info_visible = false


func _clear_probe_group(group_name: String) -> void:
	var debug_root := get_node_or_null(PROBE_DEBUG_NODE)
	if debug_root == null:
		return
	var group := debug_root.get_node_or_null(group_name)
	if group != null:
		group.free()


# ─── Helpers ──────────────────────────────────────────────────

func _get_or_create_debug_root() -> Node3D:
	var existing := get_node_or_null(PROBE_DEBUG_NODE) as Node3D
	if existing != null:
		return existing
	var root := Node3D.new()
	root.name = PROBE_DEBUG_NODE
	add_child(root)
	return root


func _clear_node(node_name: String) -> void:
	var existing := get_node_or_null(node_name)
	if existing != null:
		existing.free()


func _make_fallback_box() -> BoxMesh:
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 1.5, 0.8)
	return box


func _make_tree_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.55, 0.2, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.metallic = 0.0
	mat.roughness = 0.85
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _make_rock_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.44, 0.38, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.metallic = 0.05
	mat.roughness = 0.9
	return mat


func _make_probe_marker(probe: Dictionary, index: int) -> MeshInstance3D:
	var shape_source := str(probe.get("shape_source", "unknown"))
	var mesh := SphereMesh.new()
	mesh.radius = 0.06
	mesh.height = 0.12
	var color := Color(0.4, 1.0, 0.4, 0.9)
	if shape_source == "convex":
		color = Color(1.0, 0.85, 0.1, 0.9)
	elif shape_source == "voxel_interior":
		color = Color(0.15, 0.75, 1.0, 0.9)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5

	var marker := MeshInstance3D.new()
	marker.name = "Probe_%03d_%s" % [index, shape_source]
	marker.mesh = mesh
	marker.material_override = mat
	return marker


func _make_collision_cylinder(cfg: Dictionary, color: Color) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = float(cfg.get("radius", 0.4))
	mesh.bottom_radius = float(cfg.get("radius", 0.4))
	mesh.height = float(cfg.get("y_max", 1.0)) - float(cfg.get("y_min", -0.5))

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var node := MeshInstance3D.new()
	node.name = "CollisionVolume"
	node.mesh = mesh
	node.position.y = (float(cfg.get("y_min", -0.5)) + float(cfg.get("y_max", 1.0))) * 0.5
	node.material_override = mat
	return node


func _update_instruction_labels() -> void:
	var method_label := get_node_or_null("TestMethod") as Label3D
	if method_label != null:
		method_label.text = ("Shortcuts\n" +
			"1: Tree probes    2: Rock probes    3: All probes\n" +
			"C: Clear debug    V: Collision volumes    B: Buffer info")
	var acceptance_label := get_node_or_null("Acceptance") as Label3D
	if acceptance_label != null:
		acceptance_label.text = ("Acceptance\n" +
			"- AssetDescriptor is semantic authority\n" +
			"- color/complexity/collision are shared fields\n" +
			"- probes & buffers display correctly")


func _mark_handled() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.set_input_as_handled()