@tool
extends "res://demos/core_demo_contract_fixture.gd"

## ScenePlacementActor (SPA) — Unified Interactive Demo
##
## Combines SPA lifecycle (initialize → register_asset → GPU profile) with
## AutoObject interactive manipulation (click-select, drag-move, delete, duplicate).
## Wireframe AABB bounds are drawn for every placed object.
##
## Controls:
##   LMB click — select / deselect object
##   LMB drag  — move selected object on XZ plane (terrain-snapped)
##   Delete    — remove selected object
##   Ctrl+D    — duplicate selected object at +10,+10 offset
##   1-4       — spawn new asset at viewport center
##   G         — print GPU readiness report
##   Space     — re-register all assets (force GPU re-upload)
##   Escape    — deselect

const AutoAssetFactory := preload("res://scripts/auto_asset_factory.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const AssetDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")

const GEO_PATHS := [
	"res://geo/SM_TestLeaf_Test2.FBX",
	"res://geo/cliff_01.FBX",
	"res://geo/cliff_02.FBX",
	"res://geo/SM_Cliff_06.FBX",
]
const ASSET_NAMES := ["Leaf", "Cliff01", "Cliff02", "Cliff06"]
const ASSET_COLORS := [
	Color(0.35, 0.58, 0.24, 0.45),
	Color(0.48, 0.42, 0.35, 0.75),
	Color(0.52, 0.46, 0.38, 0.70),
	Color(0.55, 0.50, 0.44, 0.80),
]
const WIRE_COLORS := [
	Color(0.2, 0.9, 0.3, 0.7),
	Color(0.9, 0.4, 0.2, 0.7),
	Color(0.2, 0.5, 1.0, 0.7),
	Color(1.0, 0.85, 0.1, 0.7),
]
const SELECT_COLOR := Color(1.0, 0.85, 0.0, 1.0)
const HOVER_COLOR := Color(0.6, 0.8, 1.0, 0.5)

# ---- SPA state ----
var _spa: ScenePlacementActor
var _initialized := false
var _init_time_ms := 0.0
var _register_time_ms := 0.0
var _descriptors: Array[AssetDescriptor] = []
var _profile_ids: Array[int] = []

# ---- object state ----
var _meshes: Array[Mesh] = []
var _objects_root: Node3D
var _selected: AutoObject = null
var _hovered: AutoObject = null
var _dragging := false
var _drag_offset := Vector3.ZERO
var _drag_plane_y := 0.0
var _spawn_counter := 0

# ---- visuals ----
var _select_outline: MeshInstance3D
var _hover_outline: MeshInstance3D
var _wireframe_root: Node3D
var _label_root: Node3D
var _hud_label: Label

# ---- terrain cache ----
var _terrain_field: PackedFloat32Array
var _terrain_field_res := 0

# ---- BrushSV tracking ----
var _brush_write_specs: Dictionary = {}
var _brush_dirty_keys: Array[String] = []
var _brush_event_counter := 0


func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		return
	if is_scene_startup_blocked():
		return
	_editor_init()


func _editor_init() -> void:
	_cleanup_editor_nodes()
	_objects_root = Node3D.new()
	_objects_root.name = "EditorAutoObjects"
	add_child(_objects_root)
	_wireframe_root = Node3D.new()
	_wireframe_root.name = "EditorWireframes"
	add_child(_wireframe_root)
	_label_root = Node3D.new()
	_label_root.name = "EditorLabels"
	add_child(_label_root)
	_load_meshes()
	_cache_terrain_field()
	_init_spa()
	_register_all_assets()
	_spawn_initial_objects()
	_rebuild_wireframes()
	if _initialized:
		print("[SPA Editor] SPA initialized: gpu_ready=%s, assets=%d" % [
			str(_spa.is_gpu_ready()), _descriptors.size()])


func _cleanup_editor_nodes() -> void:
	for name_str in ["EditorAutoObjects", "EditorWireframes", "EditorLabels"]:
		var old := get_node_or_null(NodePath(name_str))
		if old != null:
			old.queue_free()


func _deferred_init() -> void:
	if not Engine.is_editor_hint():
		return
	_cache_terrain_field()
	_load_meshes()
	_init_spa()
	_register_all_assets()
	_spawn_initial_objects()
	_rebuild_wireframes()
	_frame_camera()
	_update_hud()


# ---- SPA lifecycle ---------------------------------------------------------

func _init_spa() -> void:
	var t0 := Time.get_ticks_msec()
	_spa = ScenePlacementActor.new()
	_spa.initialize(true, true)
	_initialized = _spa.is_initialized()
	_init_time_ms = float(Time.get_ticks_msec() - t0)
	print("[SPA Demo] %s (%.0f ms)" % ["OK" if _initialized else "FAILED", _init_time_ms])


func _register_all_assets() -> void:
	_descriptors.clear()
	_profile_ids.clear()
	if not _initialized:
		return
	var t0 := Time.get_ticks_msec()
	for i in range(_meshes.size()):
		var color: Color = ASSET_COLORS[i] if i < ASSET_COLORS.size() else Color.WHITE
		var descriptor := AutoObject.create_voxel_descriptor(
			color, color.a, 1.0,
			[{"shape": "cylinder", "radius": 1.0, "y_min": 0.0, "y_max": 2.0}])
		_descriptors.append(descriptor)
		var pid := _spa.register_asset(descriptor, _meshes[i])
		_profile_ids.append(pid)
		print("[SPA Demo] Registered [%d] %s → profile_id=%d" % [
			i, ASSET_NAMES[i] if i < ASSET_NAMES.size() else "?", pid])
	_register_time_ms = float(Time.get_ticks_msec() - t0)


# ---- mesh + terrain --------------------------------------------------------

func _load_meshes() -> void:
	for path in GEO_PATHS:
		var m := AutoAssetFactory.load_mesh(path)
		if m == null:
			m = BoxMesh.new()
		_meshes.append(m)


func _cache_terrain_field() -> void:
	var terrain := TerrainInitializerScript.find_edit_time_terrain(self) as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		_terrain_field_res = 0
		_terrain_field = PackedFloat32Array()
		return
	_terrain_field_res = 128
	_terrain_field = TerrainInitializerScript.terrain_height_field_from_mesh(
		terrain, _terrain_field_res, TerrainConfigScript.MAX_HEIGHT)


func _sample_height(wx: float, wz: float) -> float:
	if _terrain_field_res <= 0 or _terrain_field.is_empty():
		return 0.0
	var capture := TerrainConfigScript.CAPTURE_SIZE
	var u := clampf((wx / capture) + 0.5, 0.0, 1.0)
	var v := clampf((wz / capture) + 0.5, 0.0, 1.0)
	var px := clampi(int(u * float(_terrain_field_res - 1)), 0, _terrain_field_res - 1)
	var pz := clampi(int(v * float(_terrain_field_res - 1)), 0, _terrain_field_res - 1)
	var idx := pz * _terrain_field_res + px
	return _terrain_field[idx] if idx < _terrain_field.size() else 0.0


# ---- spawn / manage objects ------------------------------------------------

func _spawn_initial_objects() -> void:
	var half := TerrainConfigScript.CAPTURE_SIZE * 0.5
	var q := half * 0.5
	var positions := [
		Vector3(-q, 0, -q),    Vector3(q, 0, -q),
		Vector3(-q, 0, q),     Vector3(q, 0, q),
		Vector3(0, 0, -half * 0.7), Vector3(0, 0, half * 0.7),
		Vector3(-half * 0.7, 0, 0),  Vector3(half * 0.7, 0, 0),
	]
	for i in range(positions.size()):
		var asset_idx := i % _meshes.size()
		var obj := _create_autoobject(asset_idx, positions[i])
		_snap_to_terrain(obj)
		_commit_brush_write_spec(obj, "SPAWN_INITIAL")
	_print_brush_sv_summary()


func _create_autoobject(asset_idx: int, world_pos: Vector3) -> AutoObject:
	var obj := AutoObject.new()
	obj.name = "%s_%d" % [ASSET_NAMES[asset_idx], _spawn_counter]
	_spawn_counter += 1
	obj.mesh = _meshes[asset_idx]
	obj.position = world_pos
	var color: Color = ASSET_COLORS[asset_idx] if asset_idx < ASSET_COLORS.size() else Color.WHITE
	obj.configure_auto_object({
		"color": color,
		"complexity": color.a,
		"object_type": "object",
		"group": "spa_demo",
		"asset_id": ASSET_NAMES[asset_idx] if asset_idx < ASSET_NAMES.size() else "unknown",
	})
	obj.mesh_index = asset_idx
	_objects_root.add_child(obj)
	return obj


func _snap_to_terrain(obj: AutoObject) -> void:
	obj.position.y = _sample_height(obj.position.x, obj.position.z)


# ---- Wireframe AABB bounds -------------------------------------------------

func _rebuild_wireframes() -> void:
	for c in _wireframe_root.get_children():
		c.queue_free()
	for c in _label_root.get_children():
		c.queue_free()

	for child in _objects_root.get_children():
		if not child is AutoObject:
			continue
		var obj := child as AutoObject
		if obj.mesh == null:
			continue
		var idx := clampi(obj.mesh_index, 0, WIRE_COLORS.size() - 1)
		var wire_color: Color = WIRE_COLORS[idx]
		_add_wireframe_for(obj, wire_color)


func _add_wireframe_for(obj: AutoObject, color: Color) -> void:
	if obj.mesh == null:
		return
	var aabb := obj.mesh.get_aabb()
	var wire := _build_wire_box(aabb, color)
	wire.name = "Wire_%s" % obj.name
	wire.position = obj.position + aabb.get_center()
	wire.set_meta("tracked_obj", obj.get_instance_id())
	_wireframe_root.add_child(wire)

	var label := Label3D.new()
	label.name = "Lbl_%s" % obj.name
	var name_str: String = ASSET_NAMES[obj.mesh_index] if obj.mesh_index < ASSET_NAMES.size() else str(obj.mesh_index)
	var pid: int = _profile_ids[obj.mesh_index] if obj.mesh_index < _profile_ids.size() else -1
	label.text = "%s  [profile=%d]\n%.1f × %.1f × %.1f" % [
		name_str, pid, aabb.size.x, aabb.size.y, aabb.size.z]
	label.position = obj.position + Vector3(0, aabb.size.y + 3.0, 0)
	label.font_size = 24
	label.pixel_size = 0.04
	label.outline_size = 5
	label.modulate = color
	label.set_meta("tracked_obj", obj.get_instance_id())
	_label_root.add_child(label)


func _build_wire_box(aabb: AABB, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im
	var s := aabb.size
	var corners: Array[Vector3] = []
	for y in [0.0, s.y]:
		for z in [0.0, s.z]:
			for x in [0.0, s.x]:
				corners.append(aabb.position + Vector3(x, y, z))
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(color)
	var edges := [
		[0,1],[2,3],[4,5],[6,7],
		[0,2],[1,3],[4,6],[5,7],
		[0,4],[1,5],[2,6],[3,7],
	]
	for e in edges:
		im.surface_add_vertex(corners[e[0]])
		im.surface_add_vertex(corners[e[1]])
	im.surface_end()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# ---- Input -----------------------------------------------------------------

var _editor_camera: Camera3D


func _editor_viewport_input(viewport_camera: Camera3D, event: InputEvent) -> bool:
	_editor_camera = viewport_camera
	if event is InputEventMouseButton:
		return _handle_editor_mouse_button(viewport_camera, event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		return _handle_editor_mouse_motion(viewport_camera, event as InputEventMouseMotion)
	elif event is InputEventKey:
		return _handle_editor_key(event as InputEventKey)
	return false


func _handle_editor_mouse_button(cam: Camera3D, event: InputEventMouseButton) -> bool:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if event.pressed:
		var hit := _pick_object_with_camera(cam, event.position)
		if hit != null:
			_select(hit)
			_dragging = true
			_drag_plane_y = hit.position.y
			var world_hit := _ray_xz_plane_cam(cam, event.position, _drag_plane_y)
			_drag_offset = hit.position - world_hit
			return true
		else:
			if _selected != null:
				_deselect()
				return true
	else:
		if _dragging:
			_dragging = false
			if _selected != null:
				_snap_to_terrain(_selected)
				_commit_brush_write_spec(_selected, "MOVE")
			_rebuild_wireframes()
			return true
	return false


func _handle_editor_mouse_motion(cam: Camera3D, event: InputEventMouseMotion) -> bool:
	if _dragging and _selected != null:
		var world_pos := _ray_xz_plane_cam(cam, event.position, _drag_plane_y)
		_selected.position = world_pos + _drag_offset
		_update_outline_transform(_select_outline, _selected)
		return true
	return false


func _handle_editor_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	match event.keycode:
		KEY_DELETE:
			_delete_selected()
			return true
		KEY_D:
			if event.ctrl_pressed:
				_duplicate_selected()
				return true
		KEY_1, KEY_2, KEY_3, KEY_4:
			var idx := event.keycode - KEY_1
			if idx < _meshes.size():
				_spawn_at_cursor_editor(idx)
				return true
		KEY_G:
			_print_gpu_report()
			return true
		KEY_SPACE:
			_register_all_assets()
			return true
	return false


func _spawn_at_cursor_editor(asset_idx: int) -> void:
	if _editor_camera == null:
		return
	var center := Vector2(400, 300)
	var world := _ray_xz_plane_cam(_editor_camera, center, 0.0)
	world.y = _sample_height(world.x, world.z)
	var obj := _create_autoobject(asset_idx, world)
	_snap_to_terrain(obj)
	_commit_brush_write_spec(obj, "SPAWN_EDITOR")
	_rebuild_wireframes()
	_select(obj)
	print("[SPA Editor] Spawned %s at (%.1f, %.1f, %.1f)" % [obj.name, world.x, world.y, world.z])


func _pick_object_with_camera(cam: Camera3D, screen_pos: Vector2) -> AutoObject:
	if cam == null or _objects_root == null:
		return null
	var origin := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	var best_obj: AutoObject = null
	var best_dist := INF
	for child in _objects_root.get_children():
		if not child is AutoObject:
			continue
		var obj := child as AutoObject
		if obj.mesh == null:
			continue
		var aabb := obj.mesh.get_aabb()
		var world_aabb := obj.global_transform * aabb
		var hit := _ray_intersects_aabb(origin, dir, world_aabb)
		if hit >= 0.0 and hit < best_dist:
			best_dist = hit
			best_obj = obj
	return best_obj


func _ray_xz_plane_cam(cam: Camera3D, screen_pos: Vector2, plane_y: float) -> Vector3:
	var origin := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.00001:
		return origin
	var t := (plane_y - origin.y) / dir.y
	return origin + dir * t


func _unhandled_input(event: InputEvent) -> void:
	if not Engine.is_editor_hint():
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventKey:
		_handle_key(event as InputEventKey)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		var hit := _pick_object(event.position)
		if hit != null:
			_select(hit)
			_dragging = true
			_drag_plane_y = hit.position.y
			var cam := _get_camera()
			if cam != null:
				var world_hit := _ray_xz_plane(cam, event.position, _drag_plane_y)
				_drag_offset = hit.position - world_hit
			get_viewport().set_input_as_handled()
		else:
			if _selected != null:
				_deselect()
				get_viewport().set_input_as_handled()
	else:
		if _dragging:
			_dragging = false
			if _selected != null:
				_snap_to_terrain(_selected)
				_commit_brush_write_spec(_selected, "MOVE")
			_rebuild_wireframes()
			_update_hud()
			get_viewport().set_input_as_handled()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if _dragging and _selected != null:
		var cam := _get_camera()
		if cam == null:
			return
		var world_pos := _ray_xz_plane(cam, event.position, _drag_plane_y)
		_selected.position = world_pos + _drag_offset
		_update_outline_transform(_select_outline, _selected)
		get_viewport().set_input_as_handled()
	else:
		var hit := _pick_object(event.position)
		if hit != _hovered:
			_hovered = hit
			_update_hover_outline()


func _handle_key(event: InputEventKey) -> void:
	if not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_ESCAPE:
			_deselect()
		KEY_DELETE:
			_delete_selected()
		KEY_D:
			if event.ctrl_pressed:
				_duplicate_selected()
			else:
				return
		KEY_1, KEY_2, KEY_3, KEY_4:
			var idx := event.keycode - KEY_1
			if idx < _meshes.size():
				_spawn_at_cursor(idx)
		KEY_G:
			_print_gpu_report()
		KEY_SPACE:
			_register_all_assets()
			_update_hud()
		_:
			return
	get_viewport().set_input_as_handled()


# ---- Selection & Picking ---------------------------------------------------

func _pick_object(screen_pos: Vector2) -> AutoObject:
	var cam := _get_camera()
	if cam == null:
		return null
	var origin := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	var best_obj: AutoObject = null
	var best_dist := INF
	for child in _objects_root.get_children():
		if not child is AutoObject:
			continue
		var obj := child as AutoObject
		if obj.mesh == null:
			continue
		var aabb := obj.mesh.get_aabb()
		var world_aabb := obj.global_transform * aabb
		var hit := _ray_intersects_aabb(origin, dir, world_aabb)
		if hit >= 0.0 and hit < best_dist:
			best_dist = hit
			best_obj = obj
	return best_obj


func _ray_intersects_aabb(origin: Vector3, dir: Vector3, aabb: AABB) -> float:
	var inv_dir := Vector3(
		1.0 / dir.x if absf(dir.x) > 0.00001 else 1e10 * signf(dir.x + 0.00001),
		1.0 / dir.y if absf(dir.y) > 0.00001 else 1e10 * signf(dir.y + 0.00001),
		1.0 / dir.z if absf(dir.z) > 0.00001 else 1e10 * signf(dir.z + 0.00001),
	)
	var t1 := (aabb.position - origin) * inv_dir
	var t2 := (aabb.position + aabb.size - origin) * inv_dir
	var tmin := maxf(maxf(minf(t1.x, t2.x), minf(t1.y, t2.y)), minf(t1.z, t2.z))
	var tmax := minf(minf(maxf(t1.x, t2.x), maxf(t1.y, t2.y)), maxf(t1.z, t2.z))
	if tmax < 0.0 or tmin > tmax:
		return -1.0
	return tmin if tmin >= 0.0 else tmax


func _ray_xz_plane(cam: Camera3D, screen_pos: Vector2, plane_y: float) -> Vector3:
	var origin := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.00001:
		return origin
	var t := (plane_y - origin.y) / dir.y
	return origin + dir * t


func _select(obj: AutoObject) -> void:
	_selected = obj
	_update_outline_transform(_select_outline, obj)
	if _select_outline != null:
		_select_outline.visible = true
	if Engine.is_editor_hint():
		var sel := EditorInterface.get_selection()
		sel.clear()
		sel.add_node(obj)
	_update_hud()


func _deselect() -> void:
	_selected = null
	if _select_outline != null:
		_select_outline.visible = false
	_dragging = false
	if Engine.is_editor_hint():
		EditorInterface.get_selection().clear()
	_update_hud()


func _delete_selected() -> void:
	if _selected == null:
		return
	var name_str := _selected.name
	_revoke_brush_write_spec(name_str, "DELETE")
	_selected.queue_free()
	_deselect()
	_rebuild_wireframes.call_deferred()
	print("[SPA Demo] Deleted %s" % name_str)


func _duplicate_selected() -> void:
	if _selected == null:
		return
	var idx := clampi(_selected.mesh_index, 0, _meshes.size() - 1)
	var new_pos := _selected.position + Vector3(10, 0, 10)
	var obj := _create_autoobject(idx, new_pos)
	_snap_to_terrain(obj)
	_commit_brush_write_spec(obj, "DUPLICATE")
	_rebuild_wireframes()
	_select(obj)
	print("[SPA Demo] Duplicated as %s" % obj.name)


func _spawn_at_cursor(asset_idx: int) -> void:
	var cam := _get_camera()
	if cam == null:
		return
	var center := get_viewport().get_visible_rect().size * 0.5
	var world := _ray_xz_plane(cam, center, 0.0)
	world.y = _sample_height(world.x, world.z)
	var obj := _create_autoobject(asset_idx, world)
	_snap_to_terrain(obj)
	_commit_brush_write_spec(obj, "SPAWN_RUNTIME")
	_rebuild_wireframes()
	_select(obj)
	print("[SPA Demo] Spawned %s at (%.1f, %.1f, %.1f)" % [obj.name, world.x, world.y, world.z])


func _print_gpu_report() -> void:
	if _spa == null:
		print("[SPA Demo] No SPA instance")
		return
	var report := _spa.get_gpu_readiness_report()
	print("[SPA Demo] GPU Readiness Report:")
	for key in report.keys():
		print("  %s: %s" % [key, str(report[key])])
	_print_brush_sv_summary()


# ---- Outlines --------------------------------------------------------------

func _setup_outlines() -> void:
	_select_outline = _make_outline_box(SELECT_COLOR)
	_select_outline.visible = false
	add_child(_select_outline)
	_hover_outline = _make_outline_box(HOVER_COLOR)
	_hover_outline.visible = false
	add_child(_hover_outline)


func _make_outline_box(color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _update_outline_transform(outline: MeshInstance3D, obj: AutoObject) -> void:
	if outline == null or obj == null or obj.mesh == null:
		return
	var aabb := obj.mesh.get_aabb()
	outline.global_transform = obj.global_transform
	outline.scale = aabb.size * 1.05
	outline.position = obj.global_position + aabb.get_center()


func _update_hover_outline() -> void:
	if _hover_outline == null:
		return
	if _hovered != null and _hovered != _selected:
		_update_outline_transform(_hover_outline, _hovered)
		_hover_outline.visible = true
	else:
		_hover_outline.visible = false


# ---- HUD -------------------------------------------------------------------

func _setup_hud() -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)
	_hud_label = Label.new()
	_hud_label.name = "Info"
	_hud_label.position = Vector2(24, 24)
	_hud_label.add_theme_font_size_override("font_size", 16)
	hud.add_child(_hud_label)


func _update_hud() -> void:
	if _hud_label == null:
		return
	var gpu_ready := _spa.is_gpu_ready() if _spa != null else false
	var rd_ok := RenderingServer.get_rendering_device() != null
	var obj_count := _objects_root.get_child_count() if _objects_root != null else 0
	var lines: Array[String] = [
		"ScenePlacementActor (SPA) — Unified Interactive Demo",
		"",
		"RD: %s   SPA: %s (%.0f ms)   GPU ready: %s" % [
			"ready" if rd_ok else "NONE",
			"OK" if _initialized else "FAIL",
			_init_time_ms,
			"YES" if gpu_ready else "NO"],
		"Assets: %d registered (%.0f ms)   Objects: %d in scene" % [
			_descriptors.size(), _register_time_ms, obj_count],
		"",
		"LMB: select/drag   Del: delete   Ctrl+D: duplicate",
		"1-4: spawn asset   G: GPU report   Space: re-register   Esc: deselect",
	]
	if _selected != null:
		var idx := _selected.mesh_index
		var asset_name: String = ASSET_NAMES[idx] if idx >= 0 and idx < ASSET_NAMES.size() else "unknown"
		var pid: int = _profile_ids[idx] if idx >= 0 and idx < _profile_ids.size() else -1
		lines.append("")
		lines.append("Selected: %s [%s]  profile_id=%d" % [_selected.name, asset_name, pid])
		lines.append("  pos: (%.1f, %.1f, %.1f)" % [
			_selected.position.x, _selected.position.y, _selected.position.z])
		if _selected.mesh != null:
			var aabb := _selected.mesh.get_aabb()
			lines.append("  aabb: (%.1f, %.1f, %.1f)" % [aabb.size.x, aabb.size.y, aabb.size.z])
	_hud_label.text = "\n".join(lines)


# ---- Camera ----------------------------------------------------------------

func _frame_camera() -> void:
	var cam := find_child("FlyCamera", true, false) as Camera3D
	if cam == null:
		return
	var half := TerrainConfigScript.CAPTURE_SIZE * 0.5
	cam.global_position = Vector3(-half * 0.3, half * 0.6, half * 0.8)
	cam.look_at(Vector3(0.0, 20.0, 0.0), Vector3.UP)
	cam.fov = 60.0
	cam.far = 3000.0


func _get_camera() -> Camera3D:
	return get_viewport().get_camera_3d()


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	if _select_outline != null and _select_outline.visible and _selected != null:
		_update_outline_transform(_select_outline, _selected)


# ---- BrushSV write spec management -----------------------------------------

func _world_to_base_pixel(world_pos: Vector3) -> Vector2i:
	var capture := TerrainConfigScript.CAPTURE_SIZE
	var res := TerrainConfigScript.TEXTURE_SIZE
	var u := clampf((world_pos.x / capture) + 0.5, 0.0, 1.0)
	var v := clampf((world_pos.z / capture) + 0.5, 0.0, 1.0)
	return Vector2i(int(u * float(res)), int(v * float(res)))


func _commit_brush_write_spec(obj: AutoObject, event: String) -> void:
	if obj == null or obj.mesh == null:
		return
	_brush_event_counter += 1
	var record_id := obj.name
	var base_pixel := _world_to_base_pixel(obj.position)
	var res := TerrainConfigScript.TEXTURE_SIZE
	var write_spec := obj.make_voxel_write_spec(record_id, base_pixel, res, {
		"source_voxel_type": "BrushSceneVoxel",
		"auto_source": "brush",
		"auto_mix": 0.0,
	})
	obj.set_voxel_write_spec(write_spec)
	_brush_write_specs[record_id] = write_spec
	if not _brush_dirty_keys.has(record_id):
		_brush_dirty_keys.append(record_id)
	if _spa != null:
		_spa.update_brush_sv_lifecycle_state("dirty", true, _brush_dirty_keys)
	var color: Color = write_spec.get("color", Color.WHITE)
	print("[SPA BrushSV #%d] %s: %s at (%.1f, %.1f, %.1f) → pixel=(%d,%d) color=(%.2f,%.2f,%.2f) complexity=%.2f type=%s" % [
		_brush_event_counter, event, record_id,
		obj.position.x, obj.position.y, obj.position.z,
		base_pixel.x, base_pixel.y,
		color.r, color.g, color.b,
		float(write_spec.get("complexity", 0.0)),
		str(write_spec.get("source_voxel_type", "?"))])


func _revoke_brush_write_spec(record_id: String, event: String) -> void:
	_brush_event_counter += 1
	var had := _brush_write_specs.has(record_id)
	_brush_write_specs.erase(record_id)
	_brush_dirty_keys.erase(record_id)
	if _spa != null:
		var state := "dirty" if not _brush_write_specs.is_empty() else "idle"
		_spa.update_brush_sv_lifecycle_state(
			state, not _brush_write_specs.is_empty(), _brush_dirty_keys)
	print("[SPA BrushSV #%d] %s: %s (had_spec=%s, remaining=%d)" % [
		_brush_event_counter, event, record_id, str(had), _brush_write_specs.size()])


func _print_brush_sv_summary() -> void:
	print("[SPA BrushSV] --- State Summary ---")
	print("[SPA BrushSV]   Total specs: %d  Dirty keys: %s" % [
		_brush_write_specs.size(), str(_brush_dirty_keys)])
	for key in _brush_write_specs.keys():
		var spec: Dictionary = _brush_write_specs[key]
		var bp: Vector2i = spec.get("base_pixel", Vector2i.ZERO)
		print("[SPA BrushSV]   [%s] pixel=(%d,%d) type=%s source=%s" % [
			key, bp.x, bp.y,
			str(spec.get("type", "?")),
			str(spec.get("source_voxel_type", "?"))])
	if _spa != null:
		var metadata := _spa.get_brush_sv_persistence_metadata()
		if not metadata.is_empty():
			print("[SPA BrushSV]   SPA metadata: lifecycle=%s dirty=%s" % [
				str(metadata.get("lifecycle_state", "?")),
				str(metadata.get("dirty", false))])
	print("[SPA BrushSV] --- End Summary ---")


func _exit_tree() -> void:
	if _spa != null:
		_spa.dispose()
		_spa = null
