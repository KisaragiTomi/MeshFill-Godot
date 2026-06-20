@tool
extends Node3D

# TargetSV Brush Overlay demo.
#
# Loads the shared TargetSV guidance field and shows it as box voxels (via
# VoxelDisplay.build_colored). On top of that, the mouse paints brush voxels
# that are rendered as tetrahedra so they read as visually distinct from the box
# guidance voxels. Brush voxel instance transforms/colors are produced on the
# GPU by a compute pass that writes the MultiMesh instance buffer directly on the
# main RenderingDevice (VoxelDisplay.build_brush_tetra_gpu); there is no readback
# and no CPU-side voxel decode of the brush field.

const TargetSceneVoxelGeneratorScript := preload("res://scripts/target_scene_voxel_generator.gd")
const TargetSVLoader := preload("res://scripts/target_sv_loader.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")

const HEIGHT_PATH := "res://textures/scene_height_0_1.png"
const GENERATED_GROUP := "targetsv_brush_overlay_generated"
const GUIDANCE_NODE := "GuidanceVoxels"
const BRUSH_NODE := "BrushTetraVoxels"

@export var display_scale := 1.0
@export var occupancy_threshold := 0.001
@export var brush_color := Color(1.0, 0.35, 0.08, 0.95)
@export var brush_visible := true
@export var guidance_visible := true
@export var fresnel_enabled := true

@export_group("Brush Paint Values")
@export var brush_paint_color := Color(0.8, 0.4, 0.1)
@export_range(0.0, 1.0) var brush_paint_complexity := 0.5
@export_range(0.0, 1.0) var brush_paint_collision := 0.5

enum DisplayChannel { COLOR, COMPLEXITY, COLLISION }
const CHANNEL_NAMES := ["Color", "Complexity", "Collision"]
var _display_channel: int = DisplayChannel.COLOR

var _metadata: Dictionary = {}
var _visual_bytes := PackedByteArray()
var _collision_bytes := PackedByteArray()
var _height_image: Image
var _height_luma_bytes := PackedByteArray()
var _height_width := 0
var _height_height := 0

var _texture_size := 0
var _slice_count := 0
var _capture_size := 0.0
var _vertical_span := 0.0
var _height_span := 0.0
var _terrain_height_world := PackedFloat32Array()

var _decoded_occupancy := PackedFloat32Array()
var _decoded_color := PackedColorArray()
var _decoded_collision := PackedFloat32Array()

var _brush_width := 5
var _brush_length := 5
var _brush_height := 3
var _painting := false
var _brush_voxel_keys := {}
var _brush_voxels := PackedInt32Array()
var _brush_voxel_colors := PackedFloat32Array()
var _brush_voxel_paint_colors := PackedColorArray()
var _brush_voxel_paint_complexity := PackedFloat32Array()
var _brush_voxel_paint_collision := PackedFloat32Array()


func _ready() -> void:
	if not Engine.is_editor_hint():
		# Editor-only guard: @tool script runs only inside the Godot editor (-e).
		# F5/F6 game-mode launch is prohibited; crash to prevent misuse.
		var msg := "[TargetSVBrushOverlay] FATAL: F6/F5 runtime launch is prohibited. This demo must run in @tool editor mode (-e)."
		push_error(msg)
		printerr(msg)
		get_tree().quit(1)
		OS.crash(msg)
		return
	_rebuild_deferred.call_deferred()


func _rebuild_deferred() -> void:
	if not Engine.is_editor_hint():
		return
	_rebuild()


func ensure_test_terrain_initialized() -> Dictionary:
	if not is_inside_tree():
		return {"ok": true, "skipped": true, "reason": "not_in_tree"}
	return TerrainInitializerScript.ensure_shared_terrain(self, {"visible": true})


func _rebuild() -> void:
	if not Engine.is_editor_hint():
		return
	var terrain_contract := ensure_test_terrain_initialized()
	if not bool(terrain_contract.get("ok", false)):
		push_error("[TargetSVBrushOverlay] Terrain init failed: %s" % str(terrain_contract.get("reason", "unknown")))
	_scale_terrain_to_display()
	_clear_generated()
	_brush_voxel_keys = {}
	_brush_voxels = PackedInt32Array()
	_brush_voxel_colors = PackedFloat32Array()
	_brush_voxel_paint_colors = PackedColorArray()
	_brush_voxel_paint_complexity = PackedFloat32Array()
	_brush_voxel_paint_collision = PackedFloat32Array()
	_load_fixture()
	if _metadata.is_empty():
		return
	_decode_channels()
	_build_guidance_voxels()
	_rebuild_brush_voxels()
	_build_labels()


func _scale_terrain_to_display() -> void:
	var terrain := find_child("Terrain", true, false) as MeshInstance3D
	if terrain != null:
		terrain.scale = Vector3.ONE * display_scale
		terrain.visible = true
		terrain.layers = 1
		terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	else:
		push_error("[TargetSVBrushOverlay] No terrain node found at all")


func _clear_generated() -> void:
	for child in get_children():
		if child.is_in_group(GENERATED_GROUP) and child.name != "BrushHUD":
			remove_child(child)
			child.free()


func _add_generated_child(node: Node) -> void:
	node.add_to_group(GENERATED_GROUP)
	add_child(node)


func _load_fixture() -> void:
	TargetSVLoader.reload()
	_metadata = TargetSVLoader.metadata()
	_visual_bytes = TargetSVLoader.visual_bytes()
	_collision_bytes = TargetSVLoader.collision_bytes()
	if _metadata.is_empty():
		push_error("[TargetSVBrushOverlay] TargetSVLoader metadata is empty")
		return

	_texture_size = int(_metadata.get("texture_size", 1))
	_slice_count = int(_metadata.get("slice_count", 1))
	_capture_size = float(_metadata.get("capture_size", 1.0))
	_vertical_span = float(_metadata.get("vertical_span", 16.0))
	_height_span = float(_metadata.get("max_height", 120.0))

	var tex := load(HEIGHT_PATH) as Texture2D
	_height_image = tex.get_image() if tex != null else Image.load_from_file(HEIGHT_PATH)
	if _height_image != null and _height_image.get_format() != Image.FORMAT_L8:
		_height_image.convert(Image.FORMAT_L8)
	if _height_image != null and not _height_image.is_empty():
		_height_width = _height_image.get_width()
		_height_height = _height_image.get_height()
		_height_luma_bytes = _height_image.get_data()
	_build_terrain_height_world()


func _build_terrain_height_world() -> void:
	_terrain_height_world = PackedFloat32Array()
	_terrain_height_world.resize(_texture_size * _texture_size)
	for z in range(_texture_size):
		for x in range(_texture_size):
			_terrain_height_world[z * _texture_size + x] = _height_at_pixel(x, z) * _height_span


func _decode_channels() -> void:
	_decoded_occupancy = PackedFloat32Array()
	_decoded_color = PackedColorArray()
	_decoded_collision = PackedFloat32Array()
	if _visual_bytes.is_empty() or _collision_bytes.is_empty():
		return
	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers_gpu(
		_visual_bytes, _collision_bytes, _texture_size, _slice_count
	)
	if not bool(decoded.get("valid", false)):
		decoded = TargetSceneVoxelGeneratorScript.decode_target_read_buffers(
			_visual_bytes, _collision_bytes, _texture_size, _slice_count
		)
	_decoded_occupancy = decoded.get("target_completely", PackedFloat32Array())
	_decoded_color = decoded.get("target_color", PackedColorArray())
	if _decoded_occupancy.is_empty() or _decoded_color.is_empty():
		push_error("[TargetSVBrushOverlay] TargetSV decode failed: %s" % str(decoded))
		return
	var voxel_count := _texture_size * _texture_size * _slice_count
	_decoded_collision.resize(voxel_count)
	for i in range(voxel_count):
		var offset := i * 4
		if offset + 4 <= _collision_bytes.size():
			_decoded_collision[i] = clampf(_collision_bytes.decode_float(offset), 0.0, 1.0)


func _build_guidance_voxels() -> void:
	var existing := get_node_or_null(GUIDANCE_NODE)
	if existing != null:
		existing.free()
	if _decoded_occupancy.is_empty():
		return

	var slice_voxel_count := _texture_size * _texture_size
	var cell_size := _capture_size / maxf(float(_texture_size - 1), 1.0) * display_scale * 0.72
	var slice_height := _vertical_span / maxf(float(_slice_count), 1.0) * display_scale * 0.72
	var cell := Vector3(cell_size, maxf(slice_height, 0.02), cell_size)

	var centers := PackedVector3Array()
	var colors := PackedColorArray()
	for idx in range(_decoded_occupancy.size()):
		if _decoded_occupancy[idx] <= occupancy_threshold:
			continue
		var slice_index := idx / slice_voxel_count
		var rem := idx % slice_voxel_count
		var z := rem / _texture_size
		var x := rem % _texture_size
		centers.append(_voxel_to_world(x, slice_index, z))
		colors.append(_channel_color(idx))

	var instance := VoxelDisplay.build_colored(centers, cell, colors, {"name": GUIDANCE_NODE, "fill": 1.0})
	if instance != null:
		instance.visible = guidance_visible
		if fresnel_enabled:
			_apply_fresnel_material(instance)
		_add_generated_child(instance)


func _channel_color(idx: int) -> Color:
	match _display_channel:
		DisplayChannel.COLOR:
			var c: Color = _decoded_color[idx]
			c.a = clampf(maxf(_decoded_occupancy[idx], 0.35), 0.35, 1.0)
			return c
		DisplayChannel.COMPLEXITY:
			var complexity := _decoded_color[idx].a
			return Color(complexity, complexity * 0.7, 0.1, clampf(maxf(complexity, 0.35), 0.35, 1.0))
		DisplayChannel.COLLISION:
			var col := _decoded_collision[idx] if idx < _decoded_collision.size() else 0.0
			return Color(0.1, col * 0.8, col, clampf(maxf(col, 0.35), 0.35, 1.0))
	return Color.WHITE


# --- Brush input -----------------------------------------------------------

var _brush_dirty := false
var _last_flush_msec := 0
const BRUSH_FLUSH_INTERVAL_MS := 120
var _editor_camera: Camera3D


func _editor_viewport_input(viewport_camera: Camera3D, event: InputEvent) -> bool:
	if not Engine.is_editor_hint():
		return false
	_editor_camera = viewport_camera
	return _handle_input_event(event)


func _unhandled_input(event: InputEvent) -> void:
	if not Engine.is_editor_hint():
		return
	_handle_input_event(event)


func _handle_input_event(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and not event.echo and event.shift_pressed:
		match event.keycode:
			KEY_B:
				brush_visible = not brush_visible
				_apply_brush_visibility()
				_update_brush_toggle_btn()
				_build_labels()
				return true
			KEY_G:
				guidance_visible = not guidance_visible
				_apply_guidance_visibility()
				_build_labels()
				return true
			KEY_R:
				_switch_channel(DisplayChannel.COLOR)
				return true
			KEY_T:
				_switch_channel(DisplayChannel.COMPLEXITY)
				return true
			KEY_Y:
				_switch_channel(DisplayChannel.COLLISION)
				return true
			KEY_C:
				_clear_brush()
				return true
			KEY_EQUAL, KEY_KP_ADD:
				_nudge_brush_size(2)
				return true
			KEY_MINUS, KEY_KP_SUBTRACT:
				_nudge_brush_size(-2)
				return true
		return false

	if _is_mouse_captured():
		if _painting:
			_painting = false
			_flush_brush()
		return false

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_painting = true
				_brush_dirty = false
				_paint_at_screen(mb.position)
			else:
				_painting = false
				_flush_brush()
			return true
	elif event is InputEventMouseMotion and _painting:
		_paint_at_screen((event as InputEventMouseMotion).position)
		return true
	return false


func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_WM_MOUSE_EXIT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		if _painting:
			_painting = false
			_flush_brush()


func _is_mouse_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _flush_brush() -> void:
	if _brush_dirty:
		_rebuild_brush_voxels()
		_build_labels()
		_brush_dirty = false
		_last_flush_msec = Time.get_ticks_msec()


func _throttled_flush() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_flush_msec >= BRUSH_FLUSH_INTERVAL_MS:
		_flush_brush()


func _mark_handled() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.set_input_as_handled()


func _paint_at_screen(screen_pos: Vector2) -> void:
	var center := _screen_to_voxel_xz(screen_pos)
	if center.x < 0:
		return
	var added := _accumulate_footprint(center)
	if added:
		_brush_dirty = true
		_throttled_flush()


func _accumulate_footprint(center: Vector2i) -> bool:
	var half_w := int((maxi(_brush_width, 1) - 1) / 2)
	var half_l := int((maxi(_brush_length, 1) - 1) / 2)
	var slice_max := clampi(_brush_height, 1, _slice_count)
	var changed := false
	for dz in range(-half_l, half_l + 1):
		for dx in range(-half_w, half_w + 1):
			var x := center.x + dx
			var z := center.y + dz
			if x < 0 or x >= _texture_size or z < 0 or z >= _texture_size:
				continue
			for slice in range(slice_max):
				var key := slice * _texture_size * _texture_size + z * _texture_size + x
				if _brush_voxel_keys.has(key):
					continue
				_brush_voxel_keys[key] = true
				_brush_voxels.append(x)
				_brush_voxels.append(slice)
				_brush_voxels.append(z)
				_brush_voxels.append(0)
				_brush_voxel_paint_colors.append(brush_paint_color)
				_brush_voxel_paint_complexity.append(brush_paint_complexity)
				_brush_voxel_paint_collision.append(brush_paint_collision)
				changed = true
	return changed


func _clear_brush() -> void:
	_brush_voxel_keys = {}
	_brush_voxels = PackedInt32Array()
	_brush_voxel_colors = PackedFloat32Array()
	_brush_voxel_paint_colors = PackedColorArray()
	_brush_voxel_paint_complexity = PackedFloat32Array()
	_brush_voxel_paint_collision = PackedFloat32Array()
	_rebuild_brush_voxels()
	_build_labels()


func _nudge_brush_size(delta: int) -> void:
	_brush_width = clampi(_brush_width + delta, 1, _texture_size)
	_brush_length = clampi(_brush_length + delta, 1, _texture_size)
	_sync_config_to_ui()
	_build_labels()


# --- Brush voxel GPU build + upload ----------------------------------------

func _rebuild_brush_voxels() -> void:
	var existing := get_node_or_null(BRUSH_NODE)
	if existing != null:
		existing.free()
	var instance_count := _brush_voxels.size() / 4
	if instance_count <= 0:
		return

	_compute_brush_render_colors()

	var cell_size := _capture_size / maxf(float(_texture_size - 1), 1.0) * display_scale * 0.9
	var slice_height := _vertical_span / maxf(float(_slice_count), 1.0) * display_scale * 0.9
	var cell := Vector3(cell_size, maxf(slice_height, 0.03), cell_size)

	var node := VoxelDisplay.build_brush_tetra_gpu(
		_brush_voxels,
		cell,
		_brush_grid_aabb(cell_size),
		{
			"xz_res": _texture_size,
			"slice_count": _slice_count,
			"capture_size": _capture_size,
			"display_scale": display_scale,
			"vertical_span": _vertical_span,
			"height_span": _height_span,
			"brush_color": brush_paint_color,
			"brush_colors": _brush_voxel_colors,
			"terrain_height": _terrain_height_world,
		},
		{"name": BRUSH_NODE, "fill": 1.0}
	)
	if node == null:
		return
	node.visible = brush_visible
	_add_generated_child(node)


func _compute_brush_render_colors() -> void:
	var count := _brush_voxel_paint_colors.size()
	_brush_voxel_colors = PackedFloat32Array()
	_brush_voxel_colors.resize(count * 4)
	for i in range(count):
		var c := _brush_voxel_paint_colors[i]
		var complexity := _brush_voxel_paint_complexity[i] if i < _brush_voxel_paint_complexity.size() else 0.0
		var collision := _brush_voxel_paint_collision[i] if i < _brush_voxel_paint_collision.size() else 0.0
		var render_color := Color.WHITE
		match _display_channel:
			DisplayChannel.COLOR:
				render_color = Color(c.r, c.g, c.b, clampf(maxf(complexity, 0.35), 0.35, 1.0))
			DisplayChannel.COMPLEXITY:
				render_color = Color(complexity, complexity * 0.7, 0.1, clampf(maxf(complexity, 0.35), 0.35, 1.0))
			DisplayChannel.COLLISION:
				render_color = Color(0.1, collision * 0.8, collision, clampf(maxf(collision, 0.35), 0.35, 1.0))
		_brush_voxel_colors[i * 4 + 0] = render_color.r
		_brush_voxel_colors[i * 4 + 1] = render_color.g
		_brush_voxel_colors[i * 4 + 2] = render_color.b
		_brush_voxel_colors[i * 4 + 3] = render_color.a


# Local-space bounds of the full brush grid, so the GPU-written MultiMesh is not
# frustum-culled before its instance buffer is filled (no CPU readback to derive
# a tight AABB).
func _brush_grid_aabb(cell: float) -> AABB:
	var half := _capture_size * display_scale * 0.5 + cell
	var y_max := (_height_span + _vertical_span) * display_scale + cell
	return AABB(Vector3(-half, -cell, -half), Vector3(2.0 * half, y_max + 2.0 * cell, 2.0 * half))


func _apply_fresnel_material(instance: MultiMeshInstance3D) -> void:
	if instance == null or instance.multimesh == null:
		return
	var mesh := instance.multimesh.mesh
	if mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.vertex_color_use_as_albedo = true
	mat.rim_enabled = true
	mat.rim = 0.65
	mat.rim_tint = 0.25
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	instance.material_override = mat


func _apply_brush_visibility() -> void:
	var node := get_node_or_null(BRUSH_NODE)
	if node != null:
		node.visible = brush_visible


func _apply_guidance_visibility() -> void:
	var node := get_node_or_null(GUIDANCE_NODE)
	if node != null:
		node.visible = guidance_visible


func _switch_channel(channel: int) -> void:
	if _display_channel == channel:
		return
	_display_channel = channel
	_build_guidance_voxels()
	_rebuild_brush_voxels()
	_build_labels()


var _hud_status_label: Label
var _config_panel: PanelContainer
var _brush_toggle_btn: Button
var _width_spin: SpinBox
var _length_spin: SpinBox
var _height_spin: SpinBox
var _color_r_slider: HSlider
var _color_g_slider: HSlider
var _color_b_slider: HSlider
var _complexity_slider: HSlider
var _collision_slider: HSlider
var _color_preview: ColorRect
var _syncing_ui := false


func _build_labels() -> void:
	_ensure_ui_created()
	_update_status_label()
	_sync_config_to_ui()


func _update_status_label() -> void:
	if _hud_status_label == null:
		return
	var guidance := get_node_or_null(GUIDANCE_NODE) as MultiMeshInstance3D
	var guidance_count := 0
	if guidance != null and guidance.multimesh != null:
		guidance_count = guidance.multimesh.instance_count
	var ch_name: String = str(CHANNEL_NAMES[_display_channel]) if _display_channel < CHANNEL_NAMES.size() else "?"
	_hud_status_label.text = "\n".join([
		"TargetSV Brush Overlay",
		"channel: %s   guidance: %d (%s)   brush: %d (%s)" % [
			ch_name, guidance_count,
			"ON" if guidance_visible else "OFF",
			_brush_voxels.size() / 4,
			"ON" if brush_visible else "OFF",
		],
		"",
		"[LMB] paint  [RMB] camera  [Shift+C] clear",
		"[Shift+R/T/Y] channel  [Shift+G/B] visibility",
	])


func _ensure_ui_created() -> void:
	if get_node_or_null("BrushHUD") != null:
		return
	var canvas := CanvasLayer.new()
	canvas.name = "BrushHUD"
	canvas.layer = 100
	canvas.add_to_group(GENERATED_GROUP)
	add_child(canvas)

	_create_status_panel(canvas)
	_create_config_panel(canvas)


func _create_status_panel(canvas: CanvasLayer) -> void:
	var panel := PanelContainer.new()
	panel.name = "StatusPanel"
	panel.offset_left = 12.0
	panel.offset_top = 12.0
	panel.add_theme_stylebox_override("panel", _make_panel_style())
	canvas.add_child(panel)

	_hud_status_label = Label.new()
	_hud_status_label.add_theme_font_size_override("font_size", 13)
	_hud_status_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	panel.add_child(_hud_status_label)


func _create_config_panel(canvas: CanvasLayer) -> void:
	_config_panel = PanelContainer.new()
	_config_panel.name = "ConfigPanel"
	_config_panel.add_theme_stylebox_override("panel", _make_panel_style())
	canvas.add_child(_config_panel)
	call_deferred("_position_config_panel")

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_config_panel.add_child(vbox)

	var title := Label.new()
	title.text = "Brush Config"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	vbox.add_child(title)

	_brush_toggle_btn = Button.new()
	_brush_toggle_btn.custom_minimum_size = Vector2(0, 32)
	_brush_toggle_btn.pressed.connect(_on_brush_toggle_pressed)
	_update_brush_toggle_btn()
	vbox.add_child(_brush_toggle_btn)

	vbox.add_child(HSeparator.new())

	var size_label := Label.new()
	size_label.text = "Size"
	size_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(size_label)

	var size_grid := GridContainer.new()
	size_grid.columns = 2
	vbox.add_child(size_grid)
	_width_spin = _add_spin_row(size_grid, "Width X", _brush_width, 1, _texture_size)
	_width_spin.value_changed.connect(func(v: float) -> void:
		if _syncing_ui: return
		_brush_width = clampi(roundi(v), 1, _texture_size); _update_status_label())
	_length_spin = _add_spin_row(size_grid, "Length Z", _brush_length, 1, _texture_size)
	_length_spin.value_changed.connect(func(v: float) -> void:
		if _syncing_ui: return
		_brush_length = clampi(roundi(v), 1, _texture_size); _update_status_label())
	_height_spin = _add_spin_row(size_grid, "Height Y", _brush_height, 1, _slice_count)
	_height_spin.value_changed.connect(func(v: float) -> void:
		if _syncing_ui: return
		_brush_height = clampi(roundi(v), 1, _slice_count); _update_status_label())

	vbox.add_child(HSeparator.new())

	var color_label := Label.new()
	color_label.text = "Paint Color"
	color_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(color_label)

	_color_preview = ColorRect.new()
	_color_preview.custom_minimum_size = Vector2(0, 16)
	_color_preview.color = brush_paint_color
	vbox.add_child(_color_preview)

	_color_r_slider = _add_slider_row(vbox, "R", brush_paint_color.r)
	_color_r_slider.value_changed.connect(func(v: float) -> void: brush_paint_color.r = v; _on_paint_color_changed())
	_color_g_slider = _add_slider_row(vbox, "G", brush_paint_color.g)
	_color_g_slider.value_changed.connect(func(v: float) -> void: brush_paint_color.g = v; _on_paint_color_changed())
	_color_b_slider = _add_slider_row(vbox, "B", brush_paint_color.b)
	_color_b_slider.value_changed.connect(func(v: float) -> void: brush_paint_color.b = v; _on_paint_color_changed())

	vbox.add_child(HSeparator.new())

	_complexity_slider = _add_slider_row(vbox, "Complexity", brush_paint_complexity)
	_complexity_slider.value_changed.connect(func(v: float) -> void: brush_paint_complexity = v)
	_collision_slider = _add_slider_row(vbox, "Collision", brush_paint_collision)
	_collision_slider.value_changed.connect(func(v: float) -> void: brush_paint_collision = v)


func _position_config_panel() -> void:
	if _config_panel == null:
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var vp_size := viewport.get_visible_rect().size
	_config_panel.offset_left = maxf(vp_size.x - 230.0, 10.0)
	_config_panel.offset_top = 12.0


func _sync_config_to_ui() -> void:
	_syncing_ui = true
	if _width_spin != null and roundi(_width_spin.value) != _brush_width:
		_width_spin.value = _brush_width
	if _length_spin != null and roundi(_length_spin.value) != _brush_length:
		_length_spin.value = _brush_length
	if _height_spin != null and roundi(_height_spin.value) != _brush_height:
		_height_spin.value = _brush_height
	_syncing_ui = false


func _on_brush_toggle_pressed() -> void:
	brush_visible = not brush_visible
	_apply_brush_visibility()
	_update_brush_toggle_btn()
	_build_labels()


func _update_brush_toggle_btn() -> void:
	if _brush_toggle_btn == null:
		return
	if brush_visible:
		_brush_toggle_btn.text = "Brush ON  (Shift+B)"
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.15, 0.55, 0.25, 0.9)
		style.corner_radius_top_left = 4
		style.corner_radius_top_right = 4
		style.corner_radius_bottom_left = 4
		style.corner_radius_bottom_right = 4
		_brush_toggle_btn.add_theme_stylebox_override("normal", style)
		var hover := StyleBoxFlat.new()
		hover.bg_color = Color(0.2, 0.65, 0.3, 0.95)
		hover.corner_radius_top_left = 4
		hover.corner_radius_top_right = 4
		hover.corner_radius_bottom_left = 4
		hover.corner_radius_bottom_right = 4
		_brush_toggle_btn.add_theme_stylebox_override("hover", hover)
	else:
		_brush_toggle_btn.text = "Brush OFF  (Shift+B)"
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.35, 0.15, 0.1, 0.9)
		style.corner_radius_top_left = 4
		style.corner_radius_top_right = 4
		style.corner_radius_bottom_left = 4
		style.corner_radius_bottom_right = 4
		_brush_toggle_btn.add_theme_stylebox_override("normal", style)
		var hover := StyleBoxFlat.new()
		hover.bg_color = Color(0.45, 0.2, 0.15, 0.95)
		hover.corner_radius_top_left = 4
		hover.corner_radius_top_right = 4
		hover.corner_radius_bottom_left = 4
		hover.corner_radius_bottom_right = 4
		_brush_toggle_btn.add_theme_stylebox_override("hover", hover)
	_brush_toggle_btn.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	_brush_toggle_btn.add_theme_font_size_override("font_size", 13)


func _sync_color_preview() -> void:
	if _color_preview != null:
		_color_preview.color = brush_paint_color


func _on_paint_color_changed() -> void:
	_sync_color_preview()


func _add_spin_row(grid: GridContainer, label_text: String, value: int, min_val: int, max_val: int) -> SpinBox:
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 12)
	label.custom_minimum_size = Vector2(70, 0)
	grid.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = min_val
	spin.max_value = maxi(max_val, 1)
	spin.step = 1
	spin.value = value
	spin.custom_minimum_size = Vector2(90, 26)
	grid.add_child(spin)
	return spin


func _add_slider_row(parent: Control, label_text: String, value: float) -> HSlider:
	var hbox := HBoxContainer.new()
	parent.add_child(hbox)
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 12)
	label.custom_minimum_size = Vector2(70, 0)
	hbox.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = value
	slider.custom_minimum_size = Vector2(110, 20)
	hbox.add_child(slider)
	return slider


func _make_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.05, 0.7)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	return style


# --- Coordinate helpers ----------------------------------------------------

func _voxel_to_world(x: int, slice_index: int, z: int) -> Vector3:
	var local_y := (float(slice_index) + 0.5) / maxf(float(_slice_count), 1.0) * _vertical_span
	var terrain_y := _height_at_pixel(x, z) * _height_span
	var fx := (float(x) / maxf(float(_texture_size - 1), 1.0) - 0.5) * _capture_size * display_scale
	var fz := (float(z) / maxf(float(_texture_size - 1), 1.0) - 0.5) * _capture_size * display_scale
	return Vector3(fx, (terrain_y + local_y) * display_scale, fz)


func _screen_to_voxel_xz(screen_pos: Vector2) -> Vector2i:
	var camera: Camera3D = _editor_camera if _editor_camera != null else get_viewport().get_camera_3d()
	if camera == null:
		return Vector2i(-1, -1)
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-6:
		return Vector2i(-1, -1)

	var half := _capture_size * display_scale * 0.5
	var best_px := -1
	var best_pz := -1

	# Iterative refinement: intersect at estimated terrain height,
	# then refine based on actual height at that XZ position.
	var est_y := _height_span * 0.5 * display_scale
	for _iter in range(3):
		var t := (est_y - from.y) / dir.y
		if t <= 0.0:
			break
		var hit := from + dir * t
		var u := (hit.x + half) / (_capture_size * display_scale)
		var v := (hit.z + half) / (_capture_size * display_scale)
		var px := int(u * float(_texture_size))
		var pz := int(v * float(_texture_size))
		if px < 0 or px >= _texture_size or pz < 0 or pz >= _texture_size:
			break
		best_px = px
		best_pz = pz
		est_y = _height_at_pixel(px, pz) * _height_span * display_scale

	if best_px < 0 or best_pz < 0:
		# Fallback: intersect y=0
		var t := -from.y / dir.y
		if t <= 0.0:
			return Vector2i(-1, -1)
		var hit := from + dir * t
		var u := (hit.x + half) / (_capture_size * display_scale)
		var v := (hit.z + half) / (_capture_size * display_scale)
		best_px = clampi(int(u * float(_texture_size)), 0, _texture_size - 1)
		best_pz = clampi(int(v * float(_texture_size)), 0, _texture_size - 1)
		if best_px < 0 or best_px >= _texture_size or best_pz < 0 or best_pz >= _texture_size:
			return Vector2i(-1, -1)

	return Vector2i(best_px, best_pz)


func _height_at_pixel(x: int, z: int) -> float:
	if _height_width <= 0 or _height_height <= 0 or _height_luma_bytes.is_empty():
		return 0.0
	var sx := clampi(roundi(float(x) / maxf(float(_texture_size - 1), 1.0) * float(_height_width - 1)), 0, _height_width - 1)
	var sz := clampi(roundi(float(z) / maxf(float(_texture_size - 1), 1.0) * float(_height_height - 1)), 0, _height_height - 1)
	var byte_index := sz * _height_width + sx
	return float(_height_luma_bytes[byte_index]) / 255.0 if byte_index < _height_luma_bytes.size() else 0.0


# Test/automation hook: returns brush voxel + instance buffer state for asserts.
func get_brush_state() -> Dictionary:
	return {
		"brush_voxel_count": _brush_voxels.size() / 4,
		"brush_voxels": _brush_voxels.duplicate(),
		"texture_size": _texture_size,
		"slice_count": _slice_count,
	}


func paint_voxel_footprint_for_test(center: Vector2i) -> bool:
	return _accumulate_footprint(center)
