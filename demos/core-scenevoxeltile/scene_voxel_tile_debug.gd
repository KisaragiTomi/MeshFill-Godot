@tool
extends "res://scripts/core_demo_contract_fixture.gd"

const SVC := preload("res://scripts/scene_voxel_committer.gd")

# Dirty flag bit constants (mirroring SceneVoxelCommitter)
const FLAG_SCENE := 1
const FLAG_COLLISION := 2
const FLAG_AUTO := 4
const FLAG_BRUSH := 8
const FLAG_TARGET := 16
const FLAG_ROUTING := 32
const FLAG_SCORING := 64
const FLAG_FEEDBACK := 128
const FLAG_OBJECT_REFS := 256

# Color mapping for dirty flags
const FLAG_COLORS := {
	FLAG_SCENE: Color(0.2, 0.9, 0.3, 0.6),        # Green
	FLAG_COLLISION: Color(0.95, 0.4, 0.2, 0.6),    # Red-orange
	FLAG_AUTO: Color(0.2, 0.4, 1.0, 0.6),          # Blue
	FLAG_BRUSH: Color(1.0, 0.9, 0.2, 0.6),         # Yellow
	FLAG_TARGET: Color(0.7, 0.2, 1.0, 0.6),        # Purple
	FLAG_ROUTING: Color(0.2, 1.0, 1.0, 0.6),       # Cyan
	FLAG_SCORING: Color(1.0, 0.2, 1.0, 0.6),       # Magenta
	FLAG_FEEDBACK: Color(1.0, 0.6, 0.7, 0.6),      # Pink
	FLAG_OBJECT_REFS: Color(0.95, 0.95, 0.95, 0.7),# White
}

const CLEAN_COLOR := Color(0.15, 0.15, 0.18, 0.35)
const CLEAN_WIRE := Color(0.25, 0.25, 0.30, 1.0)
const GRID_SIZE_VOXELS := 16
const CAPTURE_SIZE := 16.0

@export var show_wireframe := true
@export var highlight_dirty := true
@export var tile_padding := 0.04

var _committer: SceneVoxelCommitter
var _tile_multimesh_instance: MultiMeshInstance3D
var _wire_multimesh_instance: MultiMeshInstance3D
var _tile_instance_indices: Dictionary = {}  # tile_key -> instance_index
var _tile_aabbs: Dictionary = {}  # tile_key -> AABB (world space)
var _tile_container: Node3D
var _wire_container: Node3D
var _hud: Control
var _metric_labels: Dictionary = {}

var _demo_tick := 0
var _selected_tile_key: String = ""


func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	ensure_test_terrain_initialized()
	_setup_committer()
	_setup_visualization()
	_setup_hud()
	_add_bounding_grid()
	_build_tile_meshes()
	_full_refresh()


func _setup_committer() -> void:
	_committer = SVC.new(GRID_SIZE_VOXELS, CAPTURE_SIZE, false)
	_populate_test_data()


func _populate_test_data() -> void:
	# Scatter voxel records across the grid so tiles get created at various positions.
	# Each record maps to a different tile region with different dirty flags.
	var test_records := [
		# (record_id, voxel_xz, slice_index, color, complexity, collision_shape, extra_flags)
		["rock_A", Vector2i(3, 3), 0, Color(0.55, 0.5, 0.45, 1.0), 1.0, "cylinder", {}],
		["rock_B", Vector2i(10, 3), 0, Color(0.6, 0.55, 0.5, 1.0), 0.9, "cylinder", {"scene": true, "collision": true, "auto": true}],
		["rock_C", Vector2i(3, 10), 0, Color(0.5, 0.45, 0.4, 1.0), 0.8, "cylinder", {"scene": true, "collision": true}],
		["rock_D", Vector2i(10, 10), 0, Color(0.65, 0.6, 0.5, 1.0), 1.0, "cylinder", {"scene": true, "auto": true, "brush": true}],
		["rock_E", Vector2i(6, 6), 0, Color(0.7, 0.55, 0.4, 1.0), 1.0, "cylinder", {"scene": true, "collision": true, "object_refs": true}],
		["rock_F", Vector2i(13, 13), 0, Color(0.5, 0.6, 0.55, 0.7), 0.7, "cylinder", {"scene": true, "target": true, "routing": true}],
		["rock_G", Vector2i(1, 13), 0, Color(0.5, 0.5, 0.5, 0.5), 0.5, "cylinder", {"scene": true}],
		["rock_H", Vector2i(13, 1), 0, Color(0.8, 0.7, 0.6, 1.0), 1.0, "cylinder", {"scene": true, "collision": true, "auto": true, "scoring": true}],
	]

	for rec in test_records:
		var record := _make_voxel_record(rec[0], rec[1], rec[2], rec[3], rec[4], rec[5])
		_committer.apply_instance_stamp_write_spec(record)

		# Mark dirty tiles after each write, with specific flags
		var bounds := _compute_record_voxel_bounds(rec[1], rec[2], rec[5])
		var extra_flags: Dictionary = rec[6]
		_committer.mark_scene_voxel_tile_bounds_dirty(
			bounds.voxel_min, bounds.voxel_max,
			extra_flags,
			{"id": rec[0]}
		)

	_committer.commit_scene_voxels()


func _compute_record_voxel_bounds(voxel_xz: Vector2i, slice_index: int, _shape: String) -> Dictionary:
	var radius_voxels := 2
	return {
		"voxel_min": Vector3i(voxel_xz.x - radius_voxels, slice_index, voxel_xz.y - radius_voxels),
		"voxel_max": Vector3i(voxel_xz.x + radius_voxels + 1, slice_index + 1, voxel_xz.y + radius_voxels + 1),
	}


func _make_voxel_record(id: String, voxel_xz: Vector2i, slice_index: int, c: Color, complexity: float, shape: String) -> Dictionary:
	return {
		"id": id,
		"type": "rock",
		"source_voxel_type": "AutoSceneVoxel",
		"position": Vector3.ZERO,
		"base_pixel": voxel_xz,
		"voxel_xz": voxel_xz,
		"volume_xz_resolution": GRID_SIZE_VOXELS,
		"slice_index": slice_index,
		"scale": Vector3.ONE,
		"color": c,
		"complexity": complexity,
		"collision": [],
		"channel": 0,
		"radius": 2.0,
		"auto_mix": 0,
	}


func _setup_visualization() -> void:
	_tile_container = Node3D.new()
	_tile_container.name = "TileContainer"
	add_child(_tile_container)

	_wire_container = Node3D.new()
	_wire_container.name = "WireContainer"
	add_child(_wire_container)


func _add_bounding_grid() -> void:
	var grid_world := VoxelGeneral.voxel_span_to_world_size(_committer.grid_size, _committer.voxel_size)
	var center := _committer.grid_origin + grid_world * 0.5

	var box := MeshInstance3D.new()
	box.name = "BoundingBox"
	box.mesh = BoxMesh.new()
	box.mesh.size = grid_world
	box.position = center

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.25, 0.35, 0.55, 0.12)
	mat.flags_unshaded = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	box.material_override = mat
	add_child(box)


func _setup_hud() -> void:
	_hud = Control.new()
	_hud.name = "HUD"
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_hud)

	# Stats panel (top-left)
	var panel := Panel.new()
	panel.name = "StatsPanel"
	panel.position = Vector2(20, 20)
	panel.size = Vector2(380, 360)
	panel.set("theme_override_styles/panel", _make_panel_stylebox(Color(0, 0, 0, 0.75)))
	_hud.add_child(panel)

	var label_parent := VBoxContainer.new()
	label_parent.name = "LabelParent"
	label_parent.position = Vector2(30, 30)
	label_parent.size = Vector2(360, 340)
	_hud.add_child(label_parent)

	_metric_labels["title"] = _make_metric_row(label_parent, "SceneVoxelTile Dirty Visualizer", Color.WHITE, 18)
	label_parent.add_child(HSeparator.new())

	_metric_labels["tile_count"] = _make_metric_row(label_parent, "Tiles", Color(0.8, 0.8, 0.8), 14)
	_metric_labels["dirty_count"] = _make_metric_row(label_parent, "Dirty", Color(1, 0.6, 0.3), 14)
	_metric_labels["clean_count"] = _make_metric_row(label_parent, "Clean", Color(0.5, 0.5, 0.5), 14)
	_metric_labels["tile_size"] = _make_metric_row(label_parent, "Tile Size", Color(0.7, 0.7, 0.7), 14)
	_metric_labels["grid_size"] = _make_metric_row(label_parent, "Grid", Color(0.7, 0.7, 0.7), 14)
	_metric_labels["voxel_size"] = _make_metric_row(label_parent, "Voxel Size", Color(0.7, 0.7, 0.7), 14)
	_metric_labels["sv_status"] = _make_metric_row(label_parent, "SV", Color(0.7, 0.9, 0.5), 14)
	_metric_labels["gpu_status"] = _make_metric_row(label_parent, "GPU", Color(0.5, 0.8, 0.9), 14)
	_metric_labels["selected"] = _make_metric_row(label_parent, "Selected", Color(1, 1, 0.5), 14)
	label_parent.add_child(HSeparator.new())
	_metric_labels["help"] = _make_metric_row(label_parent, "WASD/QE: move | R-click: look | T: toggle wire", Color(0.6, 0.6, 0.6), 11)

	# Legend panel (top-right)
	var legend_panel := Panel.new()
	legend_panel.name = "LegendPanel"
	legend_panel.position = Vector2(1420, 20)
	legend_panel.size = Vector2(380, 320)
	legend_panel.set("theme_override_styles/panel", _make_panel_stylebox(Color(0, 0, 0, 0.75)))
	_hud.add_child(legend_panel)

	var legend_parent := VBoxContainer.new()
	legend_parent.name = "LegendParent"
	legend_parent.position = Vector2(1430, 30)
	legend_parent.size = Vector2(360, 300)
	_hud.add_child(legend_parent)

	_add_legend_row(legend_parent, FLAG_SCENE, "Scene Voxel Write")
	_add_legend_row(legend_parent, FLAG_COLLISION, "Collision Changed")
	_add_legend_row(legend_parent, FLAG_AUTO, "Auto Placement Stamp")
	_add_legend_row(legend_parent, FLAG_BRUSH, "Brush Edit")
	_add_legend_row(legend_parent, FLAG_TARGET, "Target Guidance")
	_add_legend_row(legend_parent, FLAG_ROUTING, "Routing / Prefilter")
	_add_legend_row(legend_parent, FLAG_SCORING, "Physical Scoring")
	_add_legend_row(legend_parent, FLAG_FEEDBACK, "Result Feedback")
	_add_legend_row(legend_parent, FLAG_OBJECT_REFS, "Object References")


func _add_legend_row(parent: VBoxContainer, flag_bit: int, label_text: String) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(row)

	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(18, 18)
	swatch.color = FLAG_COLORS[flag_bit]
	row.add_child(swatch)

	var label := Label.new()
	label.text = "  %d  %s" % [flag_bit, label_text]
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	row.add_child(label)


func _make_panel_stylebox(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


func _make_metric_row(parent: VBoxContainer, label_text: String, color: Color, font_size: int) -> Label:
	var label := Label.new()
	label.text = "%s: --" % label_text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


# GPU-driven MultiMesh renderer with manual ray-AABB picking.
# Each tile is one instance in a shared MultiMesh; tile colors are updated
# per-instance via the MultiMesh buffer. Ray picking uses GDScript-side
# ray-vs-AABB intersection against the known tile bounds -- no per-tile
# collision bodies needed.
func _build_tile_meshes() -> void:
	var tiles: Dictionary = _committer.get_scene_voxel_tiles()
	if tiles.is_empty():
		return

	var tile_size: Vector3 = Vector3(_committer._scene_voxel_tile_size()) * _committer.voxel_size
	var half_size := tile_size * 0.5
	var box_size := tile_size - Vector3.ONE * tile_padding
	var tile_count := tiles.size()

	# --- Solid MultiMesh (per-instance color) ---
	var box := BoxMesh.new()
	box.size = box_size
	var solid_mat := StandardMaterial3D.new()
	solid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	solid_mat.cull_mode = BaseMaterial3D.CULL_BACK
	solid_mat.vertex_color_use_as_albedo = true
	box.material = solid_mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = box
	mm.instance_count = tile_count

	_tile_multimesh_instance = MultiMeshInstance3D.new()
	_tile_multimesh_instance.name = "TileMultiMesh"
	_tile_multimesh_instance.multimesh = mm
	_tile_container.add_child(_tile_multimesh_instance)

	# --- Wire MultiMesh (single color, unshaded) ---
	var wire_box := BoxMesh.new()
	wire_box.size = box_size
	var wire_mat := StandardMaterial3D.new()
	wire_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wire_mat.albedo_color = CLEAN_WIRE
	wire_mat.flags_unshaded = true
	wire_box.material = wire_mat

	var wm := MultiMesh.new()
	wm.transform_format = MultiMesh.TRANSFORM_3D
	wm.use_colors = false
	wm.mesh = wire_box
	wm.instance_count = tile_count

	_wire_multimesh_instance = MultiMeshInstance3D.new()
	_wire_multimesh_instance.name = "WireMultiMesh"
	_wire_multimesh_instance.multimesh = wm
	_wire_multimesh_instance.visible = show_wireframe
	_wire_container.add_child(_wire_multimesh_instance)

	# --- Fill transforms + build AABB lookup ---
	_tile_instance_indices.clear()
	_tile_aabbs.clear()
	var i := 0
	for tile_key in tiles.keys():
		var tile: Dictionary = tiles[tile_key]
		var vm: Vector3i = tile["voxel_min"]
		var world_pos := _voxel_to_world(vm) + half_size

		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, world_pos))
		wm.set_instance_transform(i, Transform3D(Basis.IDENTITY, world_pos))
		mm.set_instance_color(i, CLEAN_COLOR)

		_tile_instance_indices[tile_key] = i
		_tile_aabbs[tile_key] = AABB(world_pos - box_size * 0.5, box_size)
		i += 1


func _voxel_to_world(voxel_coord: Vector3i) -> Vector3:
	return VoxelGeneral.voxel_to_world(voxel_coord, _committer.grid_origin, _committer.voxel_size)


func _full_refresh() -> void:
	var sv := _committer.get_sv()

	# Update tile count stats
	var tile_count := int(sv.get("scene_voxel_tile_count", 0))
	var dirty_count := int(sv.get("dirty_scene_voxel_tile_count", 0))
	var clean_count := tile_count - dirty_count
	var ts: Vector3i = _committer._scene_voxel_tile_size()

	_metric_labels["tile_count"].text = "Tiles: %d total" % tile_count
	_metric_labels["dirty_count"].text = "Dirty: %d" % dirty_count
	_metric_labels["clean_count"].text = "Clean: %d" % clean_count
	_metric_labels["tile_size"].text = "Tile Size: %d x %d x %d voxels" % [ts.x, ts.y, ts.z]
	_metric_labels["grid_size"].text = "Grid: %s voxels" % str(sv.get("grid_size", Vector3i.ZERO))
	_metric_labels["voxel_size"].text = "Voxel Size: %.2f x %.2f x %.2f world" % [_committer.voxel_size.x, _committer.voxel_size.y, _committer.voxel_size.z]
	_metric_labels["sv_status"].text = "SV: committed tick=%d  gen=%d" % [
		int(sv.get("commit_tick", -1)),
		int(sv.get("generation_tick", 0)),
	]

	var gpu_summary: Dictionary = _committer.get_scene_voxel_tile_gpu_buffer_status()
	_metric_labels["gpu_status"].text = "GPU: %s  stale=%s  rev=%d/%d" % [
		"ready" if gpu_summary.get("runtime_ready", false) else "not ready",
		"Y" if gpu_summary.get("buffers_stale", false) else "N",
		int(gpu_summary.get("uploaded_revision", -1)),
		int(gpu_summary.get("staging_revision", 0)),
	]

	_update_tile_colors()


func _compute_tile_color(tile: Dictionary) -> Color:
	var flags: Dictionary = tile.get("dirty_flags", {})
	var is_dirty := bool(tile.get("dirty", false))
	if not is_dirty or not highlight_dirty:
		return CLEAN_COLOR

	var blend := Color(0.1, 0.1, 0.1, 0.4)
	var contrib := 0
	for flag_name in flags.keys():
		var bit := _flag_name_to_bit(flag_name)
		if bit >= 0 and FLAG_COLORS.has(bit):
			blend += FLAG_COLORS[bit]
			contrib += 1
	if contrib > 0:
		blend.r /= contrib
		blend.g /= contrib
		blend.b /= contrib
	blend.a = clampf(blend.a, 0.3, 0.8)
	return blend


func _update_tile_colors() -> void:
	if _tile_multimesh_instance == null:
		return
	var mm: MultiMesh = _tile_multimesh_instance.multimesh
	var sv := _committer.get_sv()
	var tiles: Dictionary = sv.get("scene_voxel_tiles", {})

	for tile_key in tiles.keys():
		var idx: int = _tile_instance_indices.get(tile_key, -1)
		if idx < 0:
			continue
		var tile: Dictionary = tiles[tile_key]
		var color := _compute_tile_color(tile)
		var is_dirty := bool(tile.get("dirty", false))
		# Emission hint for selected tile: blend yellow into albedo
		if tile_key == _selected_tile_key:
			color = Color(1.0, 1.0, 0.5, maxf(color.a, 0.5))
		elif is_dirty:
			color.a = color.a  # keep alpha from blend
		mm.set_instance_color(idx, color)


func _flag_name_to_bit(flag_name: String) -> int:
	match flag_name:
		"scene": return FLAG_SCENE
		"collision": return FLAG_COLLISION
		"auto": return FLAG_AUTO
		"brush": return FLAG_BRUSH
		"target": return FLAG_TARGET
		"routing": return FLAG_ROUTING
		"scoring": return FLAG_SCORING
		"feedback": return FLAG_FEEDBACK
		"object_refs": return FLAG_OBJECT_REFS
	return -1


## MeshFill 插件通过 _forward_3d_gui_input 把编辑器视口事件转发到这里。
## viewport_camera 是用户实际点击所用的视口相机；不能用 find_any_camera / get_camera_3d，
## 那拿到的是运行时相机，编辑器里射线会和光标对不上。返回 true 表示已消费该事件。
## （旧实现用 _input，但编辑场景里的 @tool 节点根本收不到 _input，导致点击一直是死的。）
func _editor_viewport_input(viewport_camera: Camera3D, event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_T:
				show_wireframe = not show_wireframe
				if _wire_multimesh_instance != null:
					_wire_multimesh_instance.visible = show_wireframe
				return true
			KEY_R:
				# Refresh: mark some tiles dirty with random flags
				_demo_tick += 1
				_apply_demo_update()
				_full_refresh()
				return true
			KEY_C:
				# Clear all dirty
				_committer.clear_sv_dirty()
				_selected_tile_key = ""
				_full_refresh()
				return true
			KEY_D:
				# Toggle highlight_dirty
				highlight_dirty = not highlight_dirty
				_full_refresh()
				return true
		return false
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_ray_pick_tile(viewport_camera, (event as InputEventMouseButton).position)
		return true
	return false


func _ray_pick_tile(camera: Camera3D, screen_pos: Vector2) -> void:
	if camera == null:
		return

	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var ray_length := 1000.0

	var best_tile_key := ""
	var best_dist := ray_length

	for tile_key in _tile_aabbs.keys():
		var aabb: AABB = _tile_aabbs[tile_key]
		var hit = aabb.intersects_ray(from, dir)
		if hit is Vector3:
			var dist := from.distance_to(hit)
			if dist < best_dist:
				best_dist = dist
				best_tile_key = str(tile_key)

	_selected_tile_key = best_tile_key
	_update_selection_display()
	_full_refresh()


func _update_selection_display() -> void:
	if _selected_tile_key.is_empty():
		_metric_labels["selected"].text = "Selected: none"
		return

	var tile: Dictionary = _committer.get_scene_voxel_tiles().get(_selected_tile_key, {})
	if tile.is_empty():
		_metric_labels["selected"].text = "Selected: --"
		return

	var coord: Vector3i = tile.get("tile_coord", Vector3i.ZERO)
	var flags: Dictionary = tile.get("dirty_flags", {})
	var flag_names := ""
	for fn in flags.keys():
		if flag_names.length() > 0:
			flag_names += ","
		flag_names += fn

	_metric_labels["selected"].text = "Selected: tile(%d,%d,%d)  epoch=%d  flags=[%s]" % [
		coord.x, coord.y, coord.z,
		int(tile.get("epoch", 0)),
		flag_names if not flag_names.is_empty() else "clean",
	]

	_full_refresh()


func _apply_demo_update() -> void:
	# Cycle through different dirty flag combinations each time R is pressed
	var combos := [
		{"scene": true, "auto": true},
		{"scene": true, "collision": true, "brush": true},
		{"scene": true, "target": true, "routing": true},
		{"scene": true, "auto": true, "scoring": true, "object_refs": true},
		{"collision": true, "auto": true, "feedback": true},
		{},  # add clean entry to reset partial dirty
	]
	var flags: Dictionary = combos[_demo_tick % combos.size()]

	# Apply to a random subset of tiles
	var tile_keys := _committer.get_scene_voxel_tiles().keys()
	tile_keys.sort()
	var count := maxi(1, int(ceil(float(tile_keys.size()) / 3.0)))
	for i in range(count):
		var tile_key: String = tile_keys[(i * 7 + _demo_tick * 3) % tile_keys.size()]
		var tile: Dictionary = _committer.get_scene_voxel_tiles().get(tile_key, {})
		if tile.is_empty():
			continue
		var coord: Vector3i = tile["tile_coord"]
		if not flags.is_empty():
			_committer.mark_scene_voxel_tile_dirty(coord, flags, {"id": "demo_%d" % _demo_tick})
		else:
			# To reset dirty, mark with minimal "auto" then clear in next cycle
			_committer.mark_scene_voxel_tile_dirty(coord, {"scene": true, "auto": true}, {"id": "demo_%d" % _demo_tick})

	_committer.commit_scene_voxels()


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	pass
