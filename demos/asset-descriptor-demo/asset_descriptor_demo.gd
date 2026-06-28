@tool
extends "res://scripts/core_demo_contract_fixture.gd"

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const MeshVoxelizerGpuScript := preload("res://scripts/mesh_voxelizer_gpu.gd")
const VoxelDisplay := preload("res://scripts/voxel_display.gd")
const CommonDemoAssets := preload("res://scripts/common_demo_assets.gd")

const VOXEL_DEBUG_NODE := "VoxelDebugGroup"
const GEO_ASSET_ROOT := "Assets/Geo"
const GEO_SOURCE_META := "geo_source_path"
const GEO_MTIME_META := "geo_modified_time"
const GEO_BOUND_SIZE_META := "geo_bound_size"
const GEO_BOUND_LONGEST_META := "geo_bound_longest"
const GEO_KIND_META := "geo_asset_kind"
const GEO_SCAN_EXTENSIONS := ["fbx"]

# ---- Bake transform -> source FBX (editor tool) ---------------------------
const BAKE_SCRIPT_PATH := "res://tools/bake_fbx_transform.py"
const BAKE_BACKUP_DIR := "res://backup/geo"
const BAKE_PYTHON_SETTING := "meshfill_editor/bake_fbx_python"

var _bake_status_label: Label
var _bake_info_label: Label
var _bake_dialog: ConfirmationDialog
var _bake_output_dialog: AcceptDialog
var _bake_scale_check: CheckBox
var _bake_rotation_check: CheckBox
var _bake_target: Node3D

# Voxel channel display modes (one shortcut each).
const VOXEL_CHANNEL_NONE := ""
const VOXEL_CHANNEL_COLOR := "color"
const VOXEL_CHANNEL_COMPLEXITY := "complexity"
const VOXEL_CHANNEL_COLLISION := "collision"

const PROBE_DEBUG_NODE := "ProbeDebugGroup"
const BUFFER_INFO_NODE := "BufferInfoOverlay"

const EDITOR_ACTION_TREE_PROBES := &"tree_probes"
const EDITOR_ACTION_ROCK_PROBES := &"rock_probes"
const EDITOR_ACTION_ALL_PROBES := &"all_probes"
const EDITOR_ACTION_VOXEL_COLOR := &"voxel_color"
const EDITOR_ACTION_VOXEL_COMPLEXITY := &"voxel_complexity"
const EDITOR_ACTION_VOXEL_COLLISION := &"voxel_collision"
const EDITOR_ACTION_CLEAR_DEBUG := &"clear_debug"
const EDITOR_ACTION_BUFFER_INFO := &"buffer_info"

const TREE_COLOR := Color(0.35, 0.58, 0.24, 0.55)
const TREE_COMPLEXITY := 0.45

const ROCK_COLOR := Color(0.48, 0.42, 0.35, 0.7)
const ROCK_COMPLEXITY := 0.75

@export_range(0.1, 8.0, 0.1) var probe_density: float = 1.0
@export var max_probe_markers: int = 96
@export_range(8, 96, 1) var voxel_grid_count: int = 28
@export_range(0.0, 1.0, 0.05) var voxel_collision_strength: float = 0.9
@export var geo_layout_origin := Vector3(-7.0, 0.0, 5.0)
@export_range(4.0, 48.0, 0.5) var geo_layout_row_width: float = 14.0
@export_range(0.1, 4.0, 0.1) var geo_layout_gap: float = 0.8
# Collision erosion strictness per asset class. Rocks are bulky solids, so the
# strict full 6-neighbour erosion (rock core only) is correct. Trees have a thin,
# often 1-voxel trunk that strict erosion deletes entirely, so they use a looser
# threshold: a solid voxel earns collision when enough neighbours are solid to
# show it belongs to a connected structure rather than a drifting single leaf.
@export_range(1, 6, 1) var tree_collision_min_neighbors: int = 2
@export_range(1, 6, 1) var rock_collision_min_neighbors: int = 6

var _tree_nodes: Array[Node3D] = []
var _rock_nodes: Array[Node3D] = []
var _tree_probes: Array[Dictionary] = []
var _rock_probes: Array[Dictionary] = []
var _tree_probes_visible := false
var _rock_probes_visible := false
var _buffer_info_visible := false

# Voxelization cache: per asset node, the structured result from MeshVoxelizerGpu.
var _voxel_results: Array[Dictionary] = []
var _voxel_baked := false
var _voxel_channel := VOXEL_CHANNEL_NONE


func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	_connect_geo_scan_buttons()
	_ensure_bake_ui()
	_collect_static_assets()
	_update_instruction_labels()
	_update_geo_scan_status()


# Debug shortcuts are driven by the editor 3D viewport, not runtime input. The
# MeshFill editor plugin forwards viewport key events here via _forward_3d_gui_input,
# so the 1..6 / C / B overlays respond while the cursor is over the editor viewport.
# Returning true tells the plugin to consume the event (AFTER_GUI_INPUT_STOP).
func _editor_viewport_input(_viewport_camera: Camera3D, event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return false

	# The 3D editor setting "emulate_numpad" rewrites number-row 1..9 to keypad
	# codes before the event reaches here, so fold KP_0..KP_9 back to 0..9 to keep
	# the digit shortcuts working regardless of that setting.
	var keycode := ke.keycode
	if keycode >= KEY_KP_0 and keycode <= KEY_KP_9:
		keycode = KEY_0 + (keycode - KEY_KP_0)

	match keycode:
		KEY_1:
			asset_descriptor_editor_action(EDITOR_ACTION_TREE_PROBES)
			return true
		KEY_2:
			asset_descriptor_editor_action(EDITOR_ACTION_ROCK_PROBES)
			return true
		KEY_3:
			asset_descriptor_editor_action(EDITOR_ACTION_ALL_PROBES)
			return true
		KEY_4:
			asset_descriptor_editor_action(EDITOR_ACTION_VOXEL_COLOR)
			return true
		KEY_5:
			asset_descriptor_editor_action(EDITOR_ACTION_VOXEL_COMPLEXITY)
			return true
		KEY_6:
			asset_descriptor_editor_action(EDITOR_ACTION_VOXEL_COLLISION)
			return true
		KEY_C:
			asset_descriptor_editor_action(EDITOR_ACTION_CLEAR_DEBUG)
			return true
		KEY_B:
			asset_descriptor_editor_action(EDITOR_ACTION_BUFFER_INFO)
			return true
	return false


func asset_descriptor_editor_actions() -> Array[Dictionary]:
	return [
		{"id": EDITOR_ACTION_TREE_PROBES, "label": "Tree probes", "shortcut": "1"},
		{"id": EDITOR_ACTION_ROCK_PROBES, "label": "Rock probes", "shortcut": "2"},
		{"id": EDITOR_ACTION_ALL_PROBES, "label": "All probes", "shortcut": "3"},
		{"id": EDITOR_ACTION_VOXEL_COLOR, "label": "Voxel color", "shortcut": "4"},
		{"id": EDITOR_ACTION_VOXEL_COMPLEXITY, "label": "Voxel complexity", "shortcut": "5"},
		{"id": EDITOR_ACTION_VOXEL_COLLISION, "label": "Voxel collision", "shortcut": "6"},
		{"id": EDITOR_ACTION_CLEAR_DEBUG, "label": "Clear debug", "shortcut": "C"},
		{"id": EDITOR_ACTION_BUFFER_INFO, "label": "Buffer info", "shortcut": "B"},
	]


func asset_descriptor_editor_action(action: StringName) -> Dictionary:
	match action:
		EDITOR_ACTION_TREE_PROBES:
			_toggle_tree_probes()
		EDITOR_ACTION_ROCK_PROBES:
			_toggle_rock_probes()
		EDITOR_ACTION_ALL_PROBES:
			_toggle_all_probes()
		EDITOR_ACTION_VOXEL_COLOR:
			_show_voxel_channel(VOXEL_CHANNEL_COLOR)
		EDITOR_ACTION_VOXEL_COMPLEXITY:
			_show_voxel_channel(VOXEL_CHANNEL_COMPLEXITY)
		EDITOR_ACTION_VOXEL_COLLISION:
			_show_voxel_channel(VOXEL_CHANNEL_COLLISION)
		EDITOR_ACTION_CLEAR_DEBUG:
			_clear_all_debug()
		EDITOR_ACTION_BUFFER_INFO:
			_toggle_buffer_info()
		_:
			return {"ok": false, "reason": "unknown_action", "action": str(action)}
	return _asset_descriptor_debug_state(action)


func get_asset_descriptor_debug_state() -> Dictionary:
	return _asset_descriptor_debug_state()


func _asset_descriptor_debug_state(action: StringName = &"") -> Dictionary:
	return {
		"ok": true,
		"action": str(action),
		"tree_probes_visible": _tree_probes_visible,
		"rock_probes_visible": _rock_probes_visible,
		"buffer_info_visible": _buffer_info_visible,
		"voxel_channel": _voxel_channel,
		"voxel_baked": _voxel_baked,
		"voxel_result_count": _voxel_results.size(),
		"tree_probe_count": _tree_probes.size(),
		"rock_probe_count": _rock_probes.size(),
		"has_probe_debug": get_node_or_null(PROBE_DEBUG_NODE) != null,
		"has_voxel_debug": get_node_or_null(VOXEL_DEBUG_NODE) != null,
		"has_buffer_info": get_node_or_null(BUFFER_INFO_NODE) != null,
	}


# Assets are now authored statically in the .tscn under Assets/Trees and
# Assets/Rocks. Each asset is a Node3D container holding a "Mesh" MeshInstance3D
# (baked ArrayMesh .res) and an "AssetLabel". This collector just wires the
# existing nodes into the probe/voxel pipelines; no nodes are created at runtime.
func _collect_static_assets() -> void:
	_tree_nodes.clear()
	_rock_nodes.clear()
	var trees_root := get_node_or_null("Assets/Trees")
	if trees_root:
		for child in trees_root.get_children():
			if child is Node3D:
				_tree_nodes.append(child)
	var rocks_root := get_node_or_null("Assets/Rocks")
	if rocks_root:
		for child in rocks_root.get_children():
			if child is Node3D:
				_rock_nodes.append(child)
	var geo_root := get_node_or_null(GEO_ASSET_ROOT)
	if geo_root:
		for child in geo_root.get_children():
			if not child is Node3D:
				continue
			var node := child as Node3D
			if _geo_asset_kind(node) == "tree":
				_tree_nodes.append(node)
			else:
				_rock_nodes.append(node)


# --- Geo scan tools --------------------------------------------------------

func _connect_geo_scan_buttons() -> void:
	var scan_button := get_node_or_null("GeoTools/Panel/VBox/ScanUpdatedGeo") as Button
	if scan_button != null:
		var scan_callable := Callable(self, "_on_scan_updated_geo_pressed")
		if not scan_button.pressed.is_connected(scan_callable):
			scan_button.pressed.connect(scan_callable)
	var rescan_button := get_node_or_null("GeoTools/Panel/VBox/FullRescanGeo") as Button
	if rescan_button != null:
		var rescan_callable := Callable(self, "_on_full_rescan_geo_pressed")
		if not rescan_button.pressed.is_connected(rescan_callable):
			rescan_button.pressed.connect(rescan_callable)


func _on_scan_updated_geo_pressed() -> void:
	var result := _scan_geo_assets(false)
	_update_geo_scan_status(_format_geo_scan_result(result))


func _on_full_rescan_geo_pressed() -> void:
	var result := _scan_geo_assets(true)
	_update_geo_scan_status(_format_geo_scan_result(result))


func _scan_geo_assets(full_rescan: bool) -> Dictionary:
	_refresh_editor_filesystem()
	var geo_root := _get_or_create_geo_asset_root()
	if full_rescan:
		for child in geo_root.get_children():
			if child is Node:
				(child as Node).free()

	var existing := _geo_nodes_by_source_path(geo_root)
	var files := CommonDemoAssets.discover_geo_files("res://geo", GEO_SCAN_EXTENSIONS)
	var added := 0
	var updated := 0
	var unchanged := 0
	var skipped := 0

	for path in files:
		var modified := _file_modified_time(path)
		var existing_node: Node3D = existing.get(path, null)
		if existing_node != null and int(existing_node.get_meta(GEO_MTIME_META, -1)) == modified:
			unchanged += 1
			continue
		var info := _load_geo_mesh_info(path)
		var mesh: Mesh = info.get("mesh", null)
		if mesh == null:
			skipped += 1
			continue
		if existing_node != null:
			_rebuild_geo_asset_node(existing_node, path, modified, info)
			_set_owned_by_scene(existing_node)
			updated += 1
		else:
			var node := _create_geo_asset_node(path, modified, info)
			geo_root.add_child(node)
			_set_owned_by_scene(node)
			added += 1

	_arrange_geo_asset_nodes()
	_collect_static_assets()
	_reset_voxel_cache()
	_mark_scene_unsaved()
	return {
		"full": full_rescan,
		"added": added,
		"updated": updated,
		"unchanged": unchanged,
		"skipped": skipped,
		"total": _geo_asset_nodes().size(),
	}


func _get_or_create_geo_asset_root() -> Node3D:
	var root := get_node_or_null(GEO_ASSET_ROOT) as Node3D
	if root != null:
		return root
	var assets := get_node_or_null("Assets") as Node3D
	if assets == null:
		assets = Node3D.new()
		assets.name = "Assets"
		add_child(assets)
		_set_owned_by_scene(assets)
	root = Node3D.new()
	root.name = "Geo"
	assets.add_child(root)
	_set_owned_by_scene(root)
	return root


func _load_geo_mesh_info(path: String) -> Dictionary:
	return CommonDemoAssets.load_mesh_info(path)


func _create_geo_asset_node(path: String, modified: int, info: Dictionary) -> Node3D:
	var node := Node3D.new()
	node.name = _geo_node_name_for_path(path)
	_rebuild_geo_asset_node(node, path, modified, info)
	return node


func _rebuild_geo_asset_node(node: Node3D, path: String, modified: int, info: Dictionary) -> void:
	for child in node.get_children():
		(child as Node).free()

	var mesh: Mesh = info.get("mesh", null)
	var mesh_transform: Transform3D = info.get("mesh_transform", Transform3D.IDENTITY)
	var bounds := CommonDemoAssets.transformed_aabb(mesh.get_aabb(), mesh_transform) if mesh != null else AABB()
	var kind := _classify_geo_asset(path)
	var color := TREE_COLOR if kind == "tree" else ROCK_COLOR

	node.name = _geo_node_name_for_path(path)
	node.scale = Vector3.ONE  # 1:1 — geo assets use their true imported FBX scale
	node.set_meta(GEO_SOURCE_META, path)
	node.set_meta(GEO_MTIME_META, modified)
	node.set_meta(GEO_BOUND_SIZE_META, bounds.size)
	node.set_meta(GEO_BOUND_LONGEST_META, CommonDemoAssets.aabb_longest_axis(bounds))
	node.set_meta(GEO_KIND_META, kind)

	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "Mesh"
	mesh_node.mesh = mesh
	mesh_node.transform = mesh_transform
	mesh_node.material_override = _make_geo_asset_material(color)
	node.add_child(mesh_node)

	var label := Label3D.new()
	label.name = "AssetLabel"
	label.pixel_size = 0.01
	label.font_size = 18
	label.outline_size = 3
	label.text = "%s\nbound %.2f" % [path.get_file().get_basename(), CommonDemoAssets.aabb_longest_axis(bounds)]
	label.position = Vector3(0.0, bounds.position.y + bounds.size.y + 0.6, 0.0)
	node.add_child(label)


func _arrange_geo_asset_nodes() -> void:
	var nodes := _geo_asset_nodes()
	nodes.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		var la := float(a.get_meta(GEO_BOUND_LONGEST_META, 0.0))
		var lb := float(b.get_meta(GEO_BOUND_LONGEST_META, 0.0))
		if not is_equal_approx(la, lb):
			return la > lb
		return str(a.get_meta(GEO_SOURCE_META, "")) < str(b.get_meta(GEO_SOURCE_META, ""))
	)
	var row_start_x := geo_layout_origin.x
	var row_limit_x := geo_layout_origin.x + geo_layout_row_width
	var cursor_x := row_start_x
	var row_z := geo_layout_origin.z
	var row_depth := 0.0

	for node in nodes:
		var bounds := _geo_node_local_aabb(node)
		var size := bounds.size
		if cursor_x > row_start_x and cursor_x + size.x > row_limit_x:
			cursor_x = row_start_x
			row_z += row_depth + geo_layout_gap
			row_depth = 0.0
		node.scale = Vector3.ONE
		node.position = Vector3(
			cursor_x - bounds.position.x,
			geo_layout_origin.y - bounds.position.y,
			row_z - (bounds.position.z + bounds.size.z * 0.5)
		)
		cursor_x += maxf(size.x, geo_layout_gap) + geo_layout_gap
		row_depth = maxf(row_depth, size.z)
		_set_owned_by_scene(node)


func _geo_asset_nodes() -> Array[Node3D]:
	var nodes: Array[Node3D] = []
	var root := get_node_or_null(GEO_ASSET_ROOT)
	if root == null:
		return nodes
	for child in root.get_children():
		if child is Node3D:
			nodes.append(child as Node3D)
	return nodes


func _geo_nodes_by_source_path(root: Node) -> Dictionary:
	var result := {}
	for child in root.get_children():
		if not child is Node3D:
			continue
		var node := child as Node3D
		var path := str(node.get_meta(GEO_SOURCE_META, ""))
		if path.is_empty():
			continue
		if result.has(path):
			node.free()
		else:
			result[path] = node
	return result


func _geo_node_local_aabb(node: Node3D) -> AABB:
	var mi := node.get_node_or_null("Mesh") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return AABB(Vector3.ZERO, Vector3.ONE)
	return CommonDemoAssets.transformed_aabb(mi.mesh.get_aabb(), mi.transform)


func _classify_geo_asset(path: String) -> String:
	var lower := path.get_file().to_lower()
	if lower.find("leaf") >= 0 or lower.find("tree") >= 0 or lower.find("foliage") >= 0:
		return "tree"
	return "rock"


func _geo_asset_kind(node: Node3D) -> String:
	return str(node.get_meta(GEO_KIND_META, _classify_geo_asset(str(node.get_meta(GEO_SOURCE_META, "")))))


func _geo_node_name_for_path(path: String) -> String:
	var base := path.get_file().get_basename()
	var safe := ""
	for i in range(base.length()):
		var c := base.substr(i, 1)
		if c.is_valid_identifier() or c.is_valid_int():
			safe += c
		else:
			safe += "_"
	if safe.is_empty():
		safe = "GeoAsset"
	return "Geo_%s" % safe


func _make_geo_asset_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 1.0)
	mat.roughness = 0.85
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _file_modified_time(path: String) -> int:
	var modified := FileAccess.get_modified_time(path)
	if modified <= 0:
		modified = FileAccess.get_modified_time(ProjectSettings.globalize_path(path))
	return int(modified)


func _refresh_editor_filesystem() -> void:
	if not Engine.is_editor_hint():
		return
	var fs = EditorInterface.get_resource_filesystem()
	if fs != null and fs.has_method("scan"):
		fs.scan()


func _reset_voxel_cache() -> void:
	_voxel_results.clear()
	_voxel_baked = false
	if _voxel_channel != VOXEL_CHANNEL_NONE:
		_clear_node(VOXEL_DEBUG_NODE)
		_voxel_channel = VOXEL_CHANNEL_NONE


func _set_owned_by_scene(node: Node) -> void:
	var scene_owner: Node = self
	var tree := get_tree()
	if tree != null and tree.edited_scene_root != null:
		scene_owner = tree.edited_scene_root
	for item in _node_and_descendants(node):
		item.owner = scene_owner


func _node_and_descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = [node]
	for child in node.get_children():
		result.append_array(_node_and_descendants(child))
	return result


func _mark_scene_unsaved() -> void:
	if Engine.is_editor_hint() and EditorInterface.has_method("mark_scene_as_unsaved"):
		EditorInterface.mark_scene_as_unsaved()


func _format_geo_scan_result(result: Dictionary) -> String:
	return "Geo scan: added=%d updated=%d unchanged=%d skipped=%d total=%d" % [
		int(result.get("added", 0)),
		int(result.get("updated", 0)),
		int(result.get("unchanged", 0)),
		int(result.get("skipped", 0)),
		int(result.get("total", 0)),
	]


func _update_geo_scan_status(text: String = "") -> void:
	var label := get_node_or_null("GeoTools/Panel/VBox/GeoScanStatus") as Label
	if label == null:
		return
	if text.is_empty():
		label.text = "Geo assets: %d" % _geo_asset_nodes().size()
	else:
		label.text = text


# --- Bake transform -> source FBX ------------------------------------------
#
# Freezes the selected geo asset's scale + rotation into its source .FBX via the
# Autodesk FBX Python SDK (tools/bake_fbx_transform.py). Godot owns all the axis
# math: each FBX imports through a per-file conversion C (= the child "Mesh"
# node's transform), so the transform baked into the FBX's own control-point
# space is M = C^-1 * T * C, where T is the user's scale/rotation. Only M (three
# basis columns) crosses into Python.

func _ensure_bake_ui() -> void:
	if not Engine.is_editor_hint():
		return
	_ensure_bake_setting()
	var vbox := get_node_or_null("GeoTools/Panel/VBox") as VBoxContainer
	if vbox == null:
		return
	var btn := vbox.get_node_or_null("BakeSelectedFbx") as Button
	if btn == null:
		btn = Button.new()
		btn.name = "BakeSelectedFbx"
		btn.text = "Bake → FBX (selected)"
		btn.tooltip_text = "Freeze the selected geo asset's scale + rotation into its source .FBX. Overwrites the file (original copied to res://backup/geo). Requires the Autodesk FBX Python SDK — set the path in Project Settings: meshfill_editor/bake_fbx_python."
		vbox.add_child(btn)
		var rescan := vbox.get_node_or_null("FullRescanGeo")
		if rescan != null:
			vbox.move_child(btn, rescan.get_index() + 1)
		btn.pressed.connect(_on_bake_selected_to_fbx_pressed)
	var status := vbox.get_node_or_null("BakeStatus") as Label
	if status == null:
		status = Label.new()
		status.name = "BakeStatus"
		status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		status.custom_minimum_size = Vector2(240, 0)
		status.add_theme_font_size_override("font_size", 12)
		status.text = ""
		vbox.add_child(status)
	_bake_status_label = status
	var panel := get_node_or_null("GeoTools/Panel") as Control
	if panel != null:
		panel.reset_size()


func _ensure_bake_setting() -> void:
	if not Engine.is_editor_hint():
		return
	if not ProjectSettings.has_setting(BAKE_PYTHON_SETTING):
		ProjectSettings.set_setting(BAKE_PYTHON_SETTING, "python")
	ProjectSettings.set_initial_value(BAKE_PYTHON_SETTING, "python")
	ProjectSettings.add_property_info({
		"name": BAKE_PYTHON_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE,
		"hint_string": "*.exe,*",
	})


func _on_bake_selected_to_fbx_pressed() -> void:
	if not Engine.is_editor_hint():
		return
	var node := _resolve_selected_geo_node()
	if node == null:
		_set_bake_status("Select a geo asset (under Assets/Geo) first.")
		return
	_bake_target = node
	_show_bake_dialog(node)


func _resolve_selected_geo_node() -> Node3D:
	if not Engine.is_editor_hint():
		return null
	var selection := EditorInterface.get_selection()
	if selection == null:
		return null
	for n in selection.get_selected_nodes():
		var cur: Node = n
		while cur != null:
			if cur is Node3D and cur.has_meta(GEO_SOURCE_META):
				return cur as Node3D
			cur = cur.get_parent()
	return null


func _show_bake_dialog(node: Node3D) -> void:
	var src := str(node.get_meta(GEO_SOURCE_META, ""))
	var basis := node.transform.basis
	var rot_deg := basis.get_euler() * 57.2957795
	var scl := basis.get_scale()
	if _bake_dialog == null:
		_bake_dialog = ConfirmationDialog.new()
		_bake_dialog.title = "Bake transform → FBX"
		_bake_dialog.ok_button_text = "Bake"
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 8)
		_bake_info_label = Label.new()
		_bake_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_bake_info_label.custom_minimum_size = Vector2(420, 0)
		vb.add_child(_bake_info_label)
		_bake_rotation_check = CheckBox.new()
		_bake_rotation_check.text = "Bake rotation"
		_bake_rotation_check.button_pressed = true
		vb.add_child(_bake_rotation_check)
		_bake_scale_check = CheckBox.new()
		_bake_scale_check.text = "Bake scale (off = rotation only)"
		_bake_scale_check.button_pressed = true
		vb.add_child(_bake_scale_check)
		_bake_dialog.add_child(vb)
		_bake_dialog.confirmed.connect(_on_bake_confirmed)
		add_child(_bake_dialog)
	_bake_info_label.text = (
		"Source: %s\nScale: (%.3f, %.3f, %.3f)\nRotation°: (%.2f, %.2f, %.2f)\n\n"
		+ "This OVERWRITES the source .FBX. The original is copied to\nres://backup/geo first."
	) % [src, scl.x, scl.y, scl.z, rot_deg.x, rot_deg.y, rot_deg.z]
	_bake_dialog.popup_centered()


func _on_bake_confirmed() -> void:
	var bake_rotation := _bake_rotation_check != null and _bake_rotation_check.button_pressed
	var bake_scale := _bake_scale_check != null and _bake_scale_check.button_pressed
	_do_bake(_bake_target, bake_rotation, bake_scale)


func _do_bake(node: Node3D, bake_rotation: bool, bake_scale: bool) -> void:
	if node == null:
		return
	if not bake_rotation and not bake_scale:
		_set_bake_status("Nothing selected to bake (check rotation and/or scale).")
		return
	var src_res := str(node.get_meta(GEO_SOURCE_META, ""))
	if src_res.is_empty():
		_set_bake_status("Selected node has no geo_source_path.")
		return

	# C = the per-file import conversion (child Mesh node transform).
	var mesh_inst := node.get_node_or_null("Mesh") as Node3D
	var c_basis: Basis = mesh_inst.transform.basis if mesh_inst != null else Basis.IDENTITY

	# T = the user's transform, restricted to the chosen channels.
	var node_basis := node.transform.basis
	var rot_b := Basis(node_basis.get_rotation_quaternion())
	var scl := node_basis.get_scale()
	var t := Basis.IDENTITY
	if bake_rotation:
		t = rot_b
	if bake_scale:
		t = t * Basis.IDENTITY.scaled(scl)

	# M = C^-1 * T * C, expressed in the FBX's own control-point space.
	var m := c_basis.inverse() * t * c_basis
	var parts := PackedStringArray()
	for v in [m.x, m.y, m.z]:
		parts.append("%.10f" % v.x)
		parts.append("%.10f" % v.y)
		parts.append("%.10f" % v.z)
	var basis_arg := ",".join(parts)

	var python := str(ProjectSettings.get_setting(BAKE_PYTHON_SETTING, "python"))
	var script_abs := ProjectSettings.globalize_path(BAKE_SCRIPT_PATH)
	var src_abs := ProjectSettings.globalize_path(src_res)
	var backup_abs := ProjectSettings.globalize_path(BAKE_BACKUP_DIR)
	DirAccess.make_dir_recursive_absolute(backup_abs)

	if not FileAccess.file_exists(script_abs):
		_set_bake_status("Bake script missing: %s" % BAKE_SCRIPT_PATH)
		return

	var args := PackedStringArray([
		script_abs,
		"--fbx", src_abs,
		"--basis-cols", basis_arg,
		"--backup", backup_abs,
		"--label", str(node.name),
	])
	_set_bake_status("Baking %s …" % src_res.get_file())
	var out := []
	var code := OS.execute(python, args, out, true)
	var log_text := ""
	for chunk in out:
		log_text += str(chunk)

	if code == 0:
		# Geometry now carries the transform — clear the baked channels so the
		# look isn't applied twice after reimport.
		if bake_rotation:
			node.rotation = Vector3.ZERO
		if bake_scale:
			node.scale = Vector3.ONE
		_mark_scene_unsaved()
		_set_bake_status("Baked → %s. Reimporting…" % src_res.get_file())
		print("[AssetDescriptorDemo] Bake OK:\n%s" % log_text)
		_reimport_after_bake(src_res)
	else:
		_set_bake_status("Bake FAILED (exit %d) — see dialog." % code)
		_show_bake_output("Command:\n%s %s\n\n--- output ---\n%s" % [
			python, " ".join(args), log_text])
		push_error("[AssetDescriptorDemo] FBX bake failed (exit %d): %s" % [code, log_text])


func _reimport_after_bake(src_res: String) -> void:
	if not Engine.is_editor_hint():
		return
	var fs = EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	fs.update_file(src_res)
	fs.reimport_files(PackedStringArray([src_res]))
	await get_tree().process_frame
	await get_tree().process_frame
	_scan_geo_assets(false)
	_update_geo_scan_status()
	_set_bake_status("Baked → %s (reimported)." % src_res.get_file())


func _show_bake_output(text: String) -> void:
	if _bake_output_dialog == null:
		_bake_output_dialog = AcceptDialog.new()
		_bake_output_dialog.title = "Bake → FBX output"
		_bake_output_dialog.min_size = Vector2(680, 380)
		var edit := TextEdit.new()
		edit.name = "Output"
		edit.editable = false
		edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		edit.custom_minimum_size = Vector2(660, 340)
		_bake_output_dialog.add_child(edit)
		add_child(_bake_output_dialog)
	(_bake_output_dialog.get_node("Output") as TextEdit).text = text
	_bake_output_dialog.popup_centered()


func _set_bake_status(text: String) -> void:
	if _bake_status_label != null:
		_bake_status_label.text = text
	print("[AssetDescriptorDemo] %s" % text)


# ─── Probe Debug ──────────────────────────────────────────────

func _toggle_tree_probes() -> void:
	if _tree_probes_visible:
		_clear_probe_group("TreeProbes")
		_tree_probes.clear()
		_tree_probes_visible = false
	else:
		_build_probes(_tree_nodes, "TreeProbes", TREE_COLOR, TREE_COMPLEXITY, _tree_probes)
		_tree_probes_visible = true


func _toggle_rock_probes() -> void:
	if _rock_probes_visible:
		_clear_probe_group("RockProbes")
		_rock_probes.clear()
		_rock_probes_visible = false
	else:
		_build_probes(_rock_nodes, "RockProbes", ROCK_COLOR, ROCK_COMPLEXITY, _rock_probes)
		_rock_probes_visible = true


func _toggle_all_probes() -> void:
	if _tree_probes_visible or _rock_probes_visible:
		_clear_all_debug()
	else:
		_build_probes(_tree_nodes, "TreeProbes", TREE_COLOR, TREE_COMPLEXITY, _tree_probes)
		_build_probes(_rock_nodes, "RockProbes", ROCK_COLOR, ROCK_COMPLEXITY, _rock_probes)
		_tree_probes_visible = true
		_rock_probes_visible = true


func _build_probes(nodes: Array[Node3D], group_name: String, color: Color, complexity: float, out_probes: Array) -> void:
	# Probe interior sampling reads the generic GPU voxel field so each probe's
	# collision sits at the same per-voxel level as color / complexity, instead of
	# a separate hand-authored cylinder strength.
	_ensure_voxels_baked()
	var debug_root := _get_or_create_debug_root()

	var group := Node3D.new()
	group.name = group_name
	debug_root.add_child(group)

	for i in range(nodes.size()):
		var node := nodes[i]
		var mi := node.get_node_or_null("Mesh") as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue

		var voxel_samples := _voxel_field_samples(node)
		var probes := SemanticProbeProfileScript.generate_from_mesh(
			mi.mesh, voxel_samples, color, complexity, probe_density, max_probe_markers
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


# ─── Voxelization (GPU solid voxelize + per-channel display) ──

func _show_voxel_channel(channel: String) -> void:
	# Re-pressing the active channel key toggles it off.
	if _voxel_channel == channel:
		_clear_node(VOXEL_DEBUG_NODE)
		_voxel_channel = VOXEL_CHANNEL_NONE
		return
	_ensure_voxels_baked()
	_clear_node(VOXEL_DEBUG_NODE)
	_voxel_channel = channel
	_build_voxel_channel_display(channel)


func _ensure_voxels_baked() -> void:
	if _voxel_baked:
		return
	_voxel_baked = true
	_voxel_results.clear()
	var voxelizer = MeshVoxelizerGpuScript.new()
	for entry in _voxel_bake_targets():
		var node: Node3D = entry["node"]
		var mi := node.get_node_or_null("Mesh") as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var result := voxelizer.voxelize(mi.mesh, voxel_grid_count, entry["color"], voxel_collision_strength, int(entry["min_neighbors"]))
		if not bool(result.get("ok", false)):
			push_warning("[AssetDescriptorDemo] voxelize failed for %s: %s" % [node.name, str(result.get("reason", "unknown"))])
			continue
		result["node"] = node
		_voxel_results.append(result)


func _voxel_bake_targets() -> Array:
	var targets := []
	for node in _tree_nodes:
		targets.append({"node": node, "color": TREE_COLOR, "min_neighbors": tree_collision_min_neighbors})
	for node in _rock_nodes:
		targets.append({"node": node, "color": ROCK_COLOR, "min_neighbors": rock_collision_min_neighbors})
	return targets


# Turn this asset's baked voxel field into per-voxel collision samples for the
# probe pipeline. Each solid-core voxel (collision > 0) becomes one sample entry
# carrying its own color / complexity / collision read from the same voxel, so
# the probe interior layer sources collision and complexity at the same level.
func _voxel_field_samples(node: Node3D) -> Array:
	var samples := []
	for result in _voxel_results:
		if result.get("node") != node:
			continue
		for v in result["voxels"]:
			if float(v["collision"]) <= 0.0:
				continue
			samples.append({
				"local_pos": v["local_center"],
				"color": v["color"],
				"complexity": v["complexity"],
				"collision": v["collision"],
			})
		break
	return samples


func _build_voxel_channel_display(channel: String) -> void:
	var root := Node3D.new()
	root.name = VOXEL_DEBUG_NODE
	add_child(root)

	var total_voxels := 0
	var shown_voxels := 0
	for result in _voxel_results:
		var node: Node3D = result["node"]
		var cell_size: float = result["cell_size"]
		var voxels: Array = result["voxels"]
		total_voxels += voxels.size()

		var centers := PackedVector3Array()
		var colors := PackedColorArray()
		for v in voxels:
			var channel_color := _voxel_channel_color(v, channel)
			if channel_color.a <= 0.0:
				continue
			# Mesh-local center -> world via the asset container transform.
			centers.append(node.to_global(v["local_center"]))
			colors.append(channel_color)
		shown_voxels += centers.size()

		# Cell size is in mesh-local units; the container scale maps it to world.
		var world_cell := cell_size * node.scale.x
		var cell := Vector3(world_cell, world_cell, world_cell)
		var display := VoxelDisplay.build_colored(centers, cell, colors, {
			"name": "%s_%s" % [node.name, channel],
			"unshaded": true,
		})
		if display != null:
			root.add_child(display)

	var label := Label3D.new()
	label.name = "VoxelChannelLabel"
	label.text = "Voxel channel: %s\nvoxels shown=%d / solid=%d  grid_count=%d" % [
		channel, shown_voxels, total_voxels, voxel_grid_count
	]
	label.position = Vector3(0.0, 3.2, 2.0)
	label.font_size = 28
	label.pixel_size = 0.01
	label.outline_size = 5
	root.add_child(label)


# Map a voxel's stored channels to a display color for the requested channel.
#  - color:      raw RGBA8 color, alpha forced opaque so the cell is visible.
#  - complexity: grayscale ramp of the visual-strength channel.
#  - collision:  red ramp of the rigid-occupancy channel; empty where 0.
func _voxel_channel_color(voxel: Dictionary, channel: String) -> Color:
	match channel:
		VOXEL_CHANNEL_COLOR:
			var c: Color = voxel["color"]
			return Color(c.r, c.g, c.b, 0.92)
		VOXEL_CHANNEL_COMPLEXITY:
			var x := clampf(float(voxel["complexity"]), 0.0, 1.0)
			return Color(x, x, x, 0.92)
		VOXEL_CHANNEL_COLLISION:
			var s := clampf(float(voxel["collision"]), 0.0, 1.0)
			if s <= 0.0:
				return Color(0, 0, 0, 0.0)
			return Color(1.0, 1.0 - s * 0.7, 0.15, 0.92)
		_:
			return Color(0, 0, 0, 0.0)


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
	_clear_node(BUFFER_INFO_NODE)
	_clear_node(VOXEL_DEBUG_NODE)
	_tree_probes.clear()
	_rock_probes.clear()
	_tree_probes_visible = false
	_rock_probes_visible = false
	_buffer_info_visible = false
	_voxel_channel = VOXEL_CHANNEL_NONE


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


func _update_instruction_labels() -> void:
	var method_label := get_node_or_null("TestMethod") as Label3D
	if method_label != null:
		method_label.text = ("Editor: AD Debug toolbar or viewport shortcuts\n" +
			"1: Tree probes    2: Rock probes    3: All probes\n" +
			"4: Voxel color    5: Voxel complexity    6: Voxel collision\n" +
			"C: Clear debug    B: Buffer info")
	var acceptance_label := get_node_or_null("Acceptance") as Label3D
	if acceptance_label != null:
		acceptance_label.text = ("Acceptance\n" +
			"- AssetDescriptor is semantic authority\n" +
			"- color/complexity/collision are shared fields\n" +
			"- probes & buffers display correctly")
