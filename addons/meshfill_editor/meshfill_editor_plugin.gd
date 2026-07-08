@tool
extends EditorPlugin

const SPAEditorContract := preload("res://scripts/spa_editor_contract.gd")
const MeshFillBrushScript := preload("res://addons/meshfill_editor/meshfill_brush.gd")
const TargetSVLookup := preload("res://scripts/utils/target_sv_lookup.gd")

var _last_viewport_camera: Camera3D

# ---- MeshFillBrush plugin integration ----
var _brush: MeshFillBrushScript = null
var _brush_btn: Button
# The brush toolbar button is only relevant for scenes that actually contain a
# MeshFillBrush (e.g. terrain/SPA scenes). Scenes like asset-descriptor-demo have
# no brush, so the button is hidden there. Recomputed on scene change.
var _scene_has_brush := false
var _selection_mode_option: OptionButton
var _geo_scan_btn: Button
var _geo_scan_status_label: Label
var _asset_descriptor_debug_menu: MenuButton
var _asset_descriptor_debug_status_label: Label
var _asset_descriptor_debug_host_instance_id := 0
var _asset_descriptor_debug_action_ids: Array[StringName] = []
var _bake_descriptor_btn: Button
var _bake_descriptor_status_label: Label
var _generate_anchor_btn: Button
var _voxel_score_btn: Button
var _anchor_score_status_label: Label
var _voxel_visibility_panel: PanelContainer
var _voxel_visibility_buttons: Dictionary = {}
var _is_painting: bool = false
var _brush_dirty: bool = false
var _last_flush_msec: int = 0
const BRUSH_FLUSH_INTERVAL_MS := 120
const SPA_SELECTION_MODE_NAMES := SPAEditorContract.SELECTION_MODE_NAMES
const VOXEL_VISIBILITY_PANEL_NAME := "MeshFillVoxelDisplayPanel"
const VOXEL_DISPLAY_DEFINITIONS := SPAEditorContract.VOXEL_DISPLAY_DEFINITIONS
const SPA_VOLUME_SCORE_ANCHOR_METHOD := SPAEditorContract.SPA_VOLUME_SCORE_ANCHOR_METHOD
const SPA_VOLUME_SCORE_METHOD := SPAEditorContract.SPA_VOLUME_SCORE_METHOD
const SPA_VOLUME_SCORE_PROVIDER_METHOD := SPAEditorContract.SPA_VOLUME_SCORE_PROVIDER_METHOD
const VOLUME_SCORE_STATUS_METHODS := SPAEditorContract.VOLUME_SCORE_STATUS_METHODS
const GEO_SCAN_METHOD := &"_scan_geo_assets"
const GEO_SCAN_STATUS_METHOD := &"_update_geo_scan_status"
const GEO_SCAN_FORMAT_METHOD := &"_format_geo_scan_result"
const ASSET_DESCRIPTOR_ACTION_METHOD := &"asset_descriptor_editor_action"
const ASSET_DESCRIPTOR_ACTIONS_METHOD := &"asset_descriptor_editor_actions"
const ASSET_DESCRIPTOR_STATE_METHOD := &"get_asset_descriptor_debug_state"
const ASSET_DESCRIPTOR_BAKE_METHOD := &"bake_scene_descriptors"
const ASSET_DESCRIPTOR_BAKE_STATE_METHOD := &"get_asset_descriptor_bake_state"

# ---- MCP TCP Server ----
var _tcp_server: TCPServer
var _tcp_peers: Array = []
var _peer_buffers: Dictionary = {}
const MCP_PORT := 6800

# ---- Single-instance guard ----
var _instance_server: TCPServer
const LOCK_FILE := "user://editor_instance.lock"
const SINGLE_INSTANCE_PORT := 6799
const HEARTBEAT_INTERVAL_SEC := 5.0
const HEARTBEAT_STALE_SEC := 15.0
var _lock_held := false
var _duplicate_instance := false
var _duplicate_reason := ""
var _heartbeat_timer: float = 0.0
var _instance_token := ""
var _project_key := ""


func _enter_tree() -> void:
	_ensure_instance_identity()
	if not _acquire_single_instance_lock():
		_mark_duplicate_and_quit(_duplicate_reason)
		return
	if not _try_bind_single_instance_port():
		_mark_duplicate_and_quit("Single-instance port %d is already in use." % SINGLE_INSTANCE_PORT)
		return
	if not _try_bind_tcp():
		_mark_duplicate_and_quit("MCP TCP port %d is already in use." % MCP_PORT)
		return
	set_input_event_forwarding_always_enabled()
	set_process(true)
	_cleanup_doc_import_files()
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_cleanup_doc_import_files)
	_connect_scene_signals()
	_validate_current_scene.call_deferred()
	_create_brush_toolbar_button()
	_create_selection_mode_toolbar()
	_create_geo_scan_toolbar()
	_create_asset_descriptor_debug_toolbar()
	_create_asset_descriptor_bake_toolbar()
	_create_volume_score_toolbar()
	_create_voxel_visibility_panel()
	print("[MeshFill Editor] Activated — MCP bridge on 127.0.0.1:%d" % MCP_PORT)


func _exit_tree() -> void:
	_remove_voxel_visibility_panel()
	_remove_volume_score_toolbar()
	_remove_asset_descriptor_bake_toolbar()
	_remove_asset_descriptor_debug_toolbar()
	_remove_geo_scan_toolbar()
	_remove_selection_mode_toolbar()
	_remove_brush_toolbar_button()
	_stop_tcp_server()
	_stop_single_instance_port()
	_release_lock()
	var fs := EditorInterface.get_resource_filesystem()
	if fs.filesystem_changed.is_connected(_cleanup_doc_import_files):
		fs.filesystem_changed.disconnect(_cleanup_doc_import_files)
	_disconnect_scene_signals()
	print("[MeshFill Editor] Deactivated")


func _process(delta: float) -> void:
	if _duplicate_instance:
		return
	_poll_single_instance_port()
	_poll_tcp()
	_sync_brush_btn_visibility()
	_sync_selection_mode_option_from_scene()
	_sync_geo_scan_toolbar_from_scene()
	_sync_asset_descriptor_debug_toolbar_from_scene()
	_sync_asset_descriptor_bake_toolbar_from_scene()
	_sync_volume_score_toolbar_from_scene()
	_sync_voxel_visibility_panel_from_scene()
	_heartbeat_timer += delta
	if _heartbeat_timer >= HEARTBEAT_INTERVAL_SEC:
		_heartbeat_timer = 0.0
		_write_heartbeat()


# ---- MeshFillBrush EditorPlugin integration --------------------------------

func _handles(object: Object) -> bool:
	return object is MeshFillBrushScript or object is Node3D


func _edit(object: Object) -> void:
	if object is MeshFillBrushScript:
		_brush = object as MeshFillBrushScript
		_sync_brush_btn(_brush.brush_visible)
	else:
		_brush = null
		_is_painting = false


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	_last_viewport_camera = viewport_camera
	_refresh_brush_from_selection()

	if _brush and _brush.is_data_loaded():
		if event is InputEventKey and event.pressed and not event.echo and event.shift_pressed:
			var handled := _handle_brush_shortcut(event.keycode)
			if handled:
				return AFTER_GUI_INPUT_STOP

	var result := _forward_to_scene_viewport_input(viewport_camera, event)
	if result != AFTER_GUI_INPUT_PASS:
		return result
	if _handle_brush_input(viewport_camera, event):
		return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS


func _refresh_brush_from_selection() -> void:
	var selected := get_editor_interface().get_selection().get_selected_nodes()
	for node in selected:
		if node is MeshFillBrushScript:
			if _brush != node:
				_brush = node as MeshFillBrushScript
				_sync_brush_btn(_brush.brush_visible)
			return
	if _brush != null:
		_brush = null
		_is_painting = false


func _handle_brush_input(viewport_camera: Camera3D, event: InputEvent) -> bool:
	if not _is_brush_painting_active():
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_is_painting = true
				_brush_dirty = false
				var voxel := _brush.screen_to_voxel_xz(viewport_camera, mb.position)
				if voxel.x >= 0:
					_brush.paint_at_voxel(voxel)
					_brush_dirty = true
					_throttled_flush()
			else:
				_is_painting = false
				_flush_brush()
			return true
	if event is InputEventMouseMotion and _is_painting:
		var voxel := _brush.screen_to_voxel_xz(viewport_camera, (event as InputEventMouseMotion).position)
		if voxel.x >= 0:
			_brush.paint_at_voxel(voxel)
			_brush_dirty = true
			_throttled_flush()
		return true
	return false


func _forward_to_scene_viewport_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	var host := _scene_viewport_input_host()
	if host == null:
		return AFTER_GUI_INPUT_PASS
	if host._editor_viewport_input(viewport_camera, event):
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


# Any edited scene implementing the editor viewport input contract receives
# forwarded 3D viewport events. The SPA host takes priority (it owns selection
# mode), otherwise the edited scene root (e.g. AssetDescriptorDemo) is used so
# its debug shortcuts cover the editor viewport instead of relying on runtime
# _unhandled_input.
func _scene_viewport_input_host() -> Node:
	var spa := _scene_spa_host()
	if spa != null and spa.has_method(&"_editor_viewport_input"):
		return spa
	var root := get_editor_interface().get_edited_scene_root()
	if root != null and root.has_method(&"_editor_viewport_input"):
		return root
	return null


func _handle_brush_shortcut(keycode: int) -> bool:
	match keycode:
		KEY_B:
			_brush.brush_visible = not _brush.brush_visible
			_brush.set_brush_visible(_brush.brush_visible)
			_sync_brush_btn(_brush.brush_visible)
			return true
		KEY_G:
			var targetsv := _find_targetsv_setup()
			if targetsv != null and targetsv.has_method("set_display_visible"):
				var visible := true
				if targetsv.has_method("is_display_visible"):
					visible = not bool(targetsv.is_display_visible())
				targetsv.set_display_visible(visible)
			else:
				_brush.guidance_visible = not _brush.guidance_visible
				_brush.set_guidance_visible(_brush.guidance_visible)
			return true
		KEY_R:
			_set_targetsv_channel(MeshFillBrushScript.DisplayChannel.COLOR)
			_brush.switch_channel(MeshFillBrushScript.DisplayChannel.COLOR)
			return true
		KEY_T:
			_set_targetsv_channel(MeshFillBrushScript.DisplayChannel.COMPLEXITY)
			_brush.switch_channel(MeshFillBrushScript.DisplayChannel.COMPLEXITY)
			return true
		KEY_Y:
			_set_targetsv_channel(MeshFillBrushScript.DisplayChannel.COLLISION)
			_brush.switch_channel(MeshFillBrushScript.DisplayChannel.COLLISION)
			return true
		KEY_C:
			_brush.clear_brush()
			return true
		KEY_EQUAL, KEY_KP_ADD:
			_brush.brush_width = clampi(_brush.brush_width + 2, 1, 128)
			_brush.brush_length = clampi(_brush.brush_length + 2, 1, 128)
			return true
		KEY_MINUS, KEY_KP_SUBTRACT:
			_brush.brush_width = clampi(_brush.brush_width - 2, 1, 128)
			_brush.brush_length = clampi(_brush.brush_length - 2, 1, 128)
			return true
	return false


func _find_targetsv_setup() -> Node:
	if _brush == null:
		return null
	var root := get_editor_interface().get_edited_scene_root()
	return TargetSVLookup.find_setup(_brush, root, false, true, false)


func _set_targetsv_channel(channel: int) -> void:
	var targetsv := _find_targetsv_setup()
	if targetsv != null and targetsv.has_method("switch_display_channel"):
		targetsv.switch_display_channel(channel)


func _is_brush_painting_active() -> bool:
	return _brush != null and _brush.is_data_loaded() and _brush.brush_visible


func _flush_brush() -> void:
	if _brush_dirty and _brush:
		_brush.flush_brush()
		_brush_dirty = false
		_last_flush_msec = Time.get_ticks_msec()


func _throttled_flush() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_flush_msec >= BRUSH_FLUSH_INTERVAL_MS:
		_flush_brush()


# ---- Brush toolbar button --------------------------------------------------

func _create_brush_toolbar_button() -> void:
	_brush_btn = Button.new()
	_brush_btn.flat = true
	_brush_btn.toggle_mode = true
	_brush_btn.button_pressed = true
	_brush_btn.text = " Brush "
	_brush_btn.tooltip_text = "Toggle brush painting (Shift+B)"
	_brush_btn.add_theme_font_size_override("font_size", 13)
	_brush_btn.toggled.connect(_on_brush_btn_toggled)
	_sync_brush_btn(true)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _brush_btn)
	_scene_has_brush = _detect_scene_brush(get_editor_interface().get_edited_scene_root())
	_sync_brush_btn_visibility()


func _remove_brush_toolbar_button() -> void:
	if _brush_btn != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _brush_btn)
		_brush_btn.queue_free()
		_brush_btn = null


func _on_brush_btn_toggled(pressed: bool) -> void:
	_sync_brush_btn(pressed)
	if _brush:
		_brush.set_brush_visible(pressed)


func _sync_brush_btn(active: bool) -> void:
	if _brush_btn == null:
		return
	if _brush_btn.button_pressed != active:
		_brush_btn.set_pressed_no_signal(active)
	var style := StyleBoxFlat.new()
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	if active:
		style.bg_color = Color(0.15, 0.55, 0.25, 0.9)
		_brush_btn.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	else:
		style.bg_color = Color(0.35, 0.15, 0.1, 0.9)
		_brush_btn.add_theme_color_override("font_color", Color(0.85, 0.7, 0.65))
	_brush_btn.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = style.bg_color.lightened(0.15)
	_brush_btn.add_theme_stylebox_override("hover", hover)
	var pressed_style := style.duplicate() as StyleBoxFlat
	pressed_style.bg_color = style.bg_color.darkened(0.1)
	_brush_btn.add_theme_stylebox_override("pressed", pressed_style)


func _detect_scene_brush(root: Node) -> bool:
	if root == null:
		return false
	if root is MeshFillBrushScript:
		return true
	for child in root.get_children():
		if _detect_scene_brush(child):
			return true
	return false


func _sync_brush_btn_visibility() -> void:
	if _brush_btn == null:
		return
	var root := get_editor_interface().get_edited_scene_root()
	var show_btn := _brush != null or (root != null and _scene_has_brush)
	if _brush_btn.visible != show_btn:
		_brush_btn.visible = show_btn


# ---- SPA selection mode toolbar -------------------------------------------

func _create_selection_mode_toolbar() -> void:
	_selection_mode_option = OptionButton.new()
	_selection_mode_option.tooltip_text = "SPA selection mode (Shift+0..5)"
	_selection_mode_option.custom_minimum_size = Vector2(128, 0)
	_selection_mode_option.add_theme_font_size_override("font_size", 13)
	for i in range(SPA_SELECTION_MODE_NAMES.size()):
		_selection_mode_option.add_item(SPAEditorContract.selection_mode_name(i), i)
		_selection_mode_option.set_item_tooltip(i, _selection_mode_tooltip(i))
	_selection_mode_option.item_selected.connect(_on_selection_mode_selected)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _selection_mode_option)
	_sync_selection_mode_option_from_scene()


func _remove_selection_mode_toolbar() -> void:
	if _selection_mode_option != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _selection_mode_option)
		_selection_mode_option.queue_free()
		_selection_mode_option = null


func _on_selection_mode_selected(index: int) -> void:
	var host := _scene_selection_mode_host()
	if host != null and host.has_method("set_spa_selection_mode"):
		# UI -> SPA: the OptionButton index is the SelectionMode enum value.
		host.set_spa_selection_mode(index)


func _sync_selection_mode_option_from_scene() -> void:
	if _selection_mode_option == null:
		return
	var host := _scene_selection_mode_host()
	_selection_mode_option.visible = host != null
	if host == null or not host.has_method("get_spa_selection_mode"):
		_selection_mode_option.disabled = true
		return
	_selection_mode_option.disabled = false
	var mode := clampi(int(host.get_spa_selection_mode()), 0, SPA_SELECTION_MODE_NAMES.size() - 1)
	if _selection_mode_option.selected != mode:
		_selection_mode_option.select(mode)


func _selection_mode_tooltip(mode: int) -> String:
	if mode == SPAEditorContract.MODE_MIXED:
		return "Mixed: GPU AutoObject, volume-score anchors, then bound data voxel domains"
	var binding := SPAEditorContract.binding_for_mode(mode)
	var label := str(binding.get("mode_label", SPAEditorContract.selection_mode_name(mode)))
	var display_key := str(binding.get("display_key", binding.get("key", "")))
	var domain := str(binding.get("domain", ""))
	var tooltip := str(binding.get("tooltip", ""))
	if tooltip.is_empty():
		return label
	return "%s (%s / %s): %s" % [label, domain, display_key, tooltip]


func _scene_selection_mode_host() -> Node:
	return _scene_spa_host()


func _scene_spa_host() -> Node:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return null
	if root.name == "CoreSPADemo" and root.has_method("set_spa_selection_mode"):
		return root
	var core := root.find_child("CoreSPADemo", true, false)
	if core != null and core.has_method("set_spa_selection_mode"):
		return core
	return null


# ---- Asset descriptor geo scan toolbar ------------------------------------

func _create_geo_scan_toolbar() -> void:
	_geo_scan_btn = _make_toolbar_action_button(
		" Geo FBX ",
		"Full rescan res://geo FBX files and arrange AssetDescriptorDemo geo assets by bounds"
	)
	_geo_scan_btn.name = "MeshFillGeoFbxScanButton"
	_geo_scan_btn.pressed.connect(_on_geo_scan_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _geo_scan_btn)

	_geo_scan_status_label = Label.new()
	_geo_scan_status_label.name = "MeshFillGeoFbxScanStatus"
	_geo_scan_status_label.custom_minimum_size = Vector2(190, 0)
	_geo_scan_status_label.clip_text = true
	_geo_scan_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_geo_scan_status_label.add_theme_font_size_override("font_size", 13)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _geo_scan_status_label)

	_sync_geo_scan_toolbar_from_scene()


func _remove_geo_scan_toolbar() -> void:
	if _geo_scan_btn != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _geo_scan_btn)
		_geo_scan_btn.queue_free()
		_geo_scan_btn = null
	if _geo_scan_status_label != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _geo_scan_status_label)
		_geo_scan_status_label.queue_free()
		_geo_scan_status_label = null


func _on_geo_scan_pressed() -> void:
	var host := _scene_geo_scan_host()
	if host == null:
		push_warning("[MeshFill Editor] Current scene has no AssetDescriptorDemo geo scan entry.")
		_sync_geo_scan_toolbar_from_scene()
		return
	var result = host.call(GEO_SCAN_METHOD, true)
	if result is Dictionary:
		var scene_summary := _format_geo_scan_toolbar_result(result)
		if host.has_method(GEO_SCAN_FORMAT_METHOD):
			scene_summary = str(host.call(GEO_SCAN_FORMAT_METHOD, result))
		if host.has_method(GEO_SCAN_STATUS_METHOD):
			host.call(GEO_SCAN_STATUS_METHOD, scene_summary)
		_set_geo_scan_status(_format_geo_scan_toolbar_result(result))
		print("[MeshFill Editor] Geo FBX scan -> %s" % scene_summary)
	else:
		_set_geo_scan_status("Geo: scan done")


func _sync_geo_scan_toolbar_from_scene() -> void:
	var host := _scene_geo_scan_host()
	var has_geo_scan := host != null
	if _geo_scan_btn != null:
		_geo_scan_btn.visible = has_geo_scan
		_geo_scan_btn.disabled = not has_geo_scan
	if _geo_scan_status_label == null:
		return
	_geo_scan_status_label.visible = has_geo_scan
	if not has_geo_scan:
		_set_geo_scan_status("")
		return
	var scene_status := host.get_node_or_null("GeoTools/Panel/VBox/GeoScanStatus") as Label
	if scene_status != null:
		_set_geo_scan_status(str(scene_status.text))
	elif _geo_scan_status_label.text.strip_edges().is_empty():
		_set_geo_scan_status("Geo: ready")


func _set_geo_scan_status(text: String) -> void:
	if _geo_scan_status_label == null:
		return
	_geo_scan_status_label.text = text
	_geo_scan_status_label.tooltip_text = text


func _format_geo_scan_toolbar_result(result: Dictionary) -> String:
	return "Geo: +%d upd%d skip%d total%d" % [
		int(result.get("added", 0)),
		int(result.get("updated", 0)),
		int(result.get("skipped", 0)),
		int(result.get("total", 0)),
	]


func _scene_geo_scan_host() -> Node:
	var root := get_editor_interface().get_edited_scene_root()
	if root != null and root.has_method(GEO_SCAN_METHOD):
		return root
	return null


# ---- Asset descriptor debug toolbar ---------------------------------------

func _create_asset_descriptor_debug_toolbar() -> void:
	_asset_descriptor_debug_menu = MenuButton.new()
	_asset_descriptor_debug_menu.name = "MeshFillAssetDescriptorDebugMenu"
	_asset_descriptor_debug_menu.flat = true
	_asset_descriptor_debug_menu.text = " AD Debug "
	_asset_descriptor_debug_menu.tooltip_text = "AssetDescriptorDemo debug overlays"
	_asset_descriptor_debug_menu.custom_minimum_size = Vector2(96, 0)
	_asset_descriptor_debug_menu.add_theme_font_size_override("font_size", 13)
	_asset_descriptor_debug_menu.get_popup().id_pressed.connect(_on_asset_descriptor_debug_action_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _asset_descriptor_debug_menu)

	_asset_descriptor_debug_status_label = Label.new()
	_asset_descriptor_debug_status_label.name = "MeshFillAssetDescriptorDebugStatus"
	_asset_descriptor_debug_status_label.custom_minimum_size = Vector2(260, 0)
	_asset_descriptor_debug_status_label.clip_text = true
	_asset_descriptor_debug_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_asset_descriptor_debug_status_label.add_theme_font_size_override("font_size", 13)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _asset_descriptor_debug_status_label)

	_sync_asset_descriptor_debug_toolbar_from_scene()


func _remove_asset_descriptor_debug_toolbar() -> void:
	if _asset_descriptor_debug_menu != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _asset_descriptor_debug_menu)
		_asset_descriptor_debug_menu.queue_free()
		_asset_descriptor_debug_menu = null
	if _asset_descriptor_debug_status_label != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _asset_descriptor_debug_status_label)
		_asset_descriptor_debug_status_label.queue_free()
		_asset_descriptor_debug_status_label = null
	_asset_descriptor_debug_action_ids.clear()
	_asset_descriptor_debug_host_instance_id = 0


func _on_asset_descriptor_debug_action_pressed(id: int) -> void:
	if id < 0 or id >= _asset_descriptor_debug_action_ids.size():
		return
	var host := _scene_asset_descriptor_debug_host()
	if host == null:
		push_warning("[MeshFill Editor] Current scene has no AssetDescriptor debug entry.")
		_sync_asset_descriptor_debug_toolbar_from_scene()
		return
	var action := _asset_descriptor_debug_action_ids[id]
	var result = host.call(ASSET_DESCRIPTOR_ACTION_METHOD, action)
	if result is Dictionary:
		if not bool(result.get("ok", false)):
			push_warning("[MeshFill Editor] AssetDescriptor debug action failed: %s" % str(result.get("reason", "unknown")))
		_set_asset_descriptor_debug_status(_format_asset_descriptor_debug_state(result))
	print("[MeshFill Editor] AssetDescriptor debug -> %s" % str(action))
	_sync_asset_descriptor_debug_toolbar_from_scene()


func _sync_asset_descriptor_debug_toolbar_from_scene() -> void:
	var host := _scene_asset_descriptor_debug_host()
	var has_host := host != null
	if _asset_descriptor_debug_menu != null:
		_asset_descriptor_debug_menu.visible = has_host
		_asset_descriptor_debug_menu.disabled = not has_host
	if _asset_descriptor_debug_status_label != null:
		_asset_descriptor_debug_status_label.visible = has_host
	if not has_host:
		_asset_descriptor_debug_host_instance_id = 0
		_asset_descriptor_debug_action_ids.clear()
		_set_asset_descriptor_debug_status("")
		return
	_ensure_asset_descriptor_debug_menu_items(host)
	if host.has_method(ASSET_DESCRIPTOR_STATE_METHOD):
		var state = host.call(ASSET_DESCRIPTOR_STATE_METHOD)
		if state is Dictionary:
			_set_asset_descriptor_debug_status(_format_asset_descriptor_debug_state(state))


func _ensure_asset_descriptor_debug_menu_items(host: Node) -> void:
	if _asset_descriptor_debug_menu == null:
		return
	var host_id := host.get_instance_id()
	if _asset_descriptor_debug_host_instance_id == host_id and not _asset_descriptor_debug_action_ids.is_empty():
		return
	_asset_descriptor_debug_host_instance_id = host_id
	_asset_descriptor_debug_action_ids.clear()
	var popup := _asset_descriptor_debug_menu.get_popup()
	popup.clear()
	var actions: Array = []
	if host.has_method(ASSET_DESCRIPTOR_ACTIONS_METHOD):
		actions = host.call(ASSET_DESCRIPTOR_ACTIONS_METHOD)
	if actions.is_empty():
		actions = _default_asset_descriptor_debug_actions()
	for action_info in actions:
		if not action_info is Dictionary:
			continue
		var action_id := StringName(str(action_info.get("id", "")))
		if String(action_id).is_empty():
			continue
		var label := str(action_info.get("label", action_id))
		var shortcut := str(action_info.get("shortcut", ""))
		if not shortcut.is_empty():
			label = "%s (%s)" % [label, shortcut]
		var item_id := _asset_descriptor_debug_action_ids.size()
		popup.add_item(label, item_id)
		_asset_descriptor_debug_action_ids.append(action_id)


func _default_asset_descriptor_debug_actions() -> Array[Dictionary]:
	return [
		{"id": &"probes", "label": "Probes (selected)", "shortcut": "Ctrl+Alt+Shift+1"},
		{"id": &"voxel_color", "label": "Voxel color (selected)", "shortcut": "Ctrl+Alt+Shift+2"},
		{"id": &"voxel_complexity", "label": "Voxel complexity (selected)", "shortcut": "Ctrl+Alt+Shift+3"},
		{"id": &"voxel_collision", "label": "Voxel collision (selected)", "shortcut": "Ctrl+Alt+Shift+4"},
		{"id": &"clear_debug", "label": "Clear debug", "shortcut": "Ctrl+Alt+Shift+C"},
	]


func _scene_asset_descriptor_debug_host() -> Node:
	var root := get_editor_interface().get_edited_scene_root()
	if root != null and root.has_method(ASSET_DESCRIPTOR_ACTION_METHOD):
		return root
	return null


func _set_asset_descriptor_debug_status(text: String) -> void:
	if _asset_descriptor_debug_status_label == null:
		return
	_asset_descriptor_debug_status_label.text = text
	_asset_descriptor_debug_status_label.tooltip_text = text


func _format_asset_descriptor_debug_state(state: Dictionary) -> String:
	var probes := "on" if bool(state.get("probes_visible", false)) else "off"
	var voxel := str(state.get("voxel_channel", ""))
	if voxel.is_empty():
		voxel = "none"
	var sel := str(state.get("selected", ""))
	if sel.is_empty():
		sel = "none"
	return "AD: selected=%s  probes=%s  voxel=%s" % [sel, probes, voxel]


# ---- Asset descriptor bake toolbar ----------------------------------------
#
# One-click bake of the AssetDescriptor data for every mesh shown in the
# AssetDescriptorDemo scene. Only visible when the edited scene exposes the
# bake entry (bake_scene_descriptors).

func _create_asset_descriptor_bake_toolbar() -> void:
	_bake_descriptor_btn = _make_toolbar_action_button(
		" Bake AD ",
		"Bake an AssetDescriptor (.tres) for every mesh displayed in the scene"
	)
	_bake_descriptor_btn.name = "MeshFillAssetDescriptorBakeButton"
	_bake_descriptor_btn.custom_minimum_size = Vector2(84, 0)
	_bake_descriptor_btn.pressed.connect(_on_bake_descriptor_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _bake_descriptor_btn)

	_bake_descriptor_status_label = Label.new()
	_bake_descriptor_status_label.name = "MeshFillAssetDescriptorBakeStatus"
	_bake_descriptor_status_label.custom_minimum_size = Vector2(220, 0)
	_bake_descriptor_status_label.clip_text = true
	_bake_descriptor_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_bake_descriptor_status_label.add_theme_font_size_override("font_size", 13)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _bake_descriptor_status_label)

	_sync_asset_descriptor_bake_toolbar_from_scene()


func _remove_asset_descriptor_bake_toolbar() -> void:
	if _bake_descriptor_btn != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _bake_descriptor_btn)
		_bake_descriptor_btn.queue_free()
		_bake_descriptor_btn = null
	if _bake_descriptor_status_label != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _bake_descriptor_status_label)
		_bake_descriptor_status_label.queue_free()
		_bake_descriptor_status_label = null


func _on_bake_descriptor_pressed() -> void:
	var host := _scene_asset_descriptor_bake_host()
	if host == null:
		push_warning("[MeshFill Editor] Current scene has no AssetDescriptor bake entry.")
		_sync_asset_descriptor_bake_toolbar_from_scene()
		return
	_set_bake_descriptor_status("Baking…")
	var result = host.call(ASSET_DESCRIPTOR_BAKE_METHOD)
	if result is Dictionary:
		if not bool(result.get("ok", false)):
			push_warning("[MeshFill Editor] Bake AD: %s" % str(result.get("reason", "no descriptors baked")))
		_set_bake_descriptor_status(_format_asset_descriptor_bake_result(result))
		print("[MeshFill Editor] Bake AD -> %s" % _format_asset_descriptor_bake_result(result))
	else:
		_set_bake_descriptor_status("Bake done")


func _sync_asset_descriptor_bake_toolbar_from_scene() -> void:
	var host := _scene_asset_descriptor_bake_host()
	var has_host := host != null
	if _bake_descriptor_btn != null:
		_bake_descriptor_btn.visible = has_host
		_bake_descriptor_btn.disabled = not has_host
	if _bake_descriptor_status_label == null:
		return
	_bake_descriptor_status_label.visible = has_host
	if not has_host:
		_set_bake_descriptor_status("")
		return
	if _bake_descriptor_status_label.text.strip_edges().is_empty():
		var count := 0
		if host.has_method(ASSET_DESCRIPTOR_BAKE_STATE_METHOD):
			var state = host.call(ASSET_DESCRIPTOR_BAKE_STATE_METHOD)
			if state is Dictionary:
				count = int(state.get("asset_count", 0))
		_set_bake_descriptor_status("Bake AD: %d asset(s)" % count)


func _scene_asset_descriptor_bake_host() -> Node:
	var root := get_editor_interface().get_edited_scene_root()
	if root != null and root.has_method(ASSET_DESCRIPTOR_BAKE_METHOD):
		return root
	return null


func _set_bake_descriptor_status(text: String) -> void:
	if _bake_descriptor_status_label == null:
		return
	_bake_descriptor_status_label.text = text
	_bake_descriptor_status_label.tooltip_text = text


func _format_asset_descriptor_bake_result(result: Dictionary) -> String:
	return "Bake AD: baked=%d failed=%d total=%d" % [
		int(result.get("baked", 0)),
		int(result.get("failed", 0)),
		int(result.get("total", 0)),
	]


# ---- Volume score toolbar --------------------------------------------------

func _create_volume_score_toolbar() -> void:
	_generate_anchor_btn = _make_toolbar_action_button(
		" Anchors ",
		"Generate volume-score anchors for the current scene"
	)
	_generate_anchor_btn.pressed.connect(_on_generate_anchor_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _generate_anchor_btn)

	_voxel_score_btn = _make_toolbar_action_button(
		" Score ",
		"Run voxel volume-score calculation for the current scene"
	)
	_voxel_score_btn.pressed.connect(_on_voxel_score_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _voxel_score_btn)

	_anchor_score_status_label = Label.new()
	_anchor_score_status_label.tooltip_text = "Selected anchor top-k asset scores"
	_anchor_score_status_label.custom_minimum_size = Vector2(520, 0)
	_anchor_score_status_label.clip_text = true
	_anchor_score_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_anchor_score_status_label.add_theme_font_size_override("font_size", 13)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _anchor_score_status_label)

	_sync_volume_score_toolbar_from_scene()


func _remove_volume_score_toolbar() -> void:
	if _generate_anchor_btn != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _generate_anchor_btn)
		_generate_anchor_btn.queue_free()
		_generate_anchor_btn = null
	if _voxel_score_btn != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _voxel_score_btn)
		_voxel_score_btn.queue_free()
		_voxel_score_btn = null
	if _anchor_score_status_label != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _anchor_score_status_label)
		_anchor_score_status_label.queue_free()
		_anchor_score_status_label = null


func _make_toolbar_action_button(label: String, tooltip: String) -> Button:
	var btn := Button.new()
	btn.flat = true
	btn.text = label
	btn.tooltip_text = tooltip
	btn.add_theme_font_size_override("font_size", 13)
	btn.custom_minimum_size = Vector2(78, 0)
	return btn


func _on_generate_anchor_pressed() -> void:
	_call_spa_volume_score_method(SPA_VOLUME_SCORE_ANCHOR_METHOD, "Generate Anchors")
	_sync_volume_score_toolbar_from_scene()


func _on_voxel_score_pressed() -> void:
	_call_spa_volume_score_method(SPA_VOLUME_SCORE_METHOD, "Voxel Score")
	_sync_volume_score_toolbar_from_scene()


func _sync_volume_score_toolbar_from_scene() -> void:
	var host := _scene_spa_host()
	var has_spa := host != null
	var has_provider := _spa_has_volume_score_provider(host)
	if _generate_anchor_btn != null:
		_generate_anchor_btn.visible = has_spa
		_generate_anchor_btn.disabled = not has_spa or not has_provider or not host.has_method(SPA_VOLUME_SCORE_ANCHOR_METHOD)
	if _voxel_score_btn != null:
		_voxel_score_btn.visible = has_spa
		_voxel_score_btn.disabled = not has_spa or not has_provider or not host.has_method(SPA_VOLUME_SCORE_METHOD)
	if _anchor_score_status_label != null:
		_anchor_score_status_label.visible = has_spa
		if not has_spa:
			_anchor_score_status_label.text = ""
			_anchor_score_status_label.tooltip_text = ""
			return
		if not has_provider:
			_anchor_score_status_label.text = ""
			_anchor_score_status_label.tooltip_text = ""
		else:
			if host.has_method("get_selected_anchor_summary_text"):
				_anchor_score_status_label.text = str(host.call("get_selected_anchor_summary_text"))
			if host.has_method("get_selected_anchor_tooltip_text"):
				_anchor_score_status_label.tooltip_text = str(host.call("get_selected_anchor_tooltip_text"))


func _spa_has_volume_score_provider(host: Node) -> bool:
	if host == null or not host.has_method(SPA_VOLUME_SCORE_PROVIDER_METHOD):
		return false
	return bool(host.call(SPA_VOLUME_SCORE_PROVIDER_METHOD))


func _call_spa_volume_score_method(method_name: String, action_name: String) -> void:
	var host := _scene_spa_host()
	if not _spa_has_volume_score_provider(host):
		push_warning("[MeshFill Editor] No SPA volume-score provider in the current scene.")
		return
	if not host.has_method(method_name):
		push_warning("[MeshFill Editor] SPA has no callable %s entry." % method_name)
		return
	var result = host.call(method_name)
	if result is Dictionary and result.has("ok") and not bool(result.get("ok", false)):
		push_warning("[MeshFill Editor] %s returned: %s" % [
			action_name,
			str(result.get("reason", "not ok")),
		])
	print("[MeshFill Editor] %s -> %s.%s" % [action_name, host.name, method_name])


# ---- Voxel display visibility panel ---------------------------------------

func _create_voxel_visibility_panel() -> void:
	_remove_voxel_visibility_panel()
	_voxel_visibility_panel = PanelContainer.new()
	_voxel_visibility_panel.name = VOXEL_VISIBILITY_PANEL_NAME
	_voxel_visibility_panel.tooltip_text = "Voxel Display visibility"
	_voxel_visibility_panel.custom_minimum_size = Vector2(168.0, 34.0)
	_voxel_visibility_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.07, 0.09, 0.58)
	style.border_color = Color(0.28, 0.66, 0.95, 0.35)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	style.content_margin_left = 4.0
	style.content_margin_right = 4.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	_voxel_visibility_panel.add_theme_stylebox_override("panel", style)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _voxel_visibility_panel)

	var columns := HBoxContainer.new()
	columns.name = "VoxelVisibilityToolbar"
	columns.add_theme_constant_override("separation", 4)
	_voxel_visibility_panel.add_child(columns)

	var title := Label.new()
	title.text = "VD"
	title.tooltip_text = "Voxel Display"
	title.custom_minimum_size = Vector2(22.0, 30.0)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color(0.88, 0.94, 1.0, 1.0))
	columns.add_child(title)

	var rows := VBoxContainer.new()
	rows.name = "VoxelVisibilityRows"
	rows.add_theme_constant_override("separation", 1)
	columns.add_child(rows)

	var row_top := HBoxContainer.new()
	row_top.name = "VoxelVisibilityRowTop"
	row_top.add_theme_constant_override("separation", 2)
	rows.add_child(row_top)

	var row_bottom := HBoxContainer.new()
	row_bottom.name = "VoxelVisibilityRowBottom"
	row_bottom.add_theme_constant_override("separation", 2)
	rows.add_child(row_bottom)

	_voxel_visibility_buttons.clear()
	for i in range(VOXEL_DISPLAY_DEFINITIONS.size()):
		var definition: Dictionary = VOXEL_DISPLAY_DEFINITIONS[i]
		var key := str(definition.get("key", ""))
		var button := Button.new()
		button.name = "Toggle_%s" % key
		button.text = str(definition.get("label", key))
		button.tooltip_text = str(definition.get("tooltip", ""))
		button.toggle_mode = true
		button.flat = false
		button.custom_minimum_size = Vector2(30.0, 14.0)
		button.add_theme_font_size_override("font_size", 10)
		button.toggled.connect(_on_voxel_visibility_toggled.bind(key))
		if i < 3:
			row_top.add_child(button)
		else:
			row_bottom.add_child(button)
		_voxel_visibility_buttons[key] = button
	_sync_voxel_visibility_panel_from_scene()


func _remove_voxel_visibility_panel() -> void:
	var base := get_editor_interface().get_base_control()
	if base != null:
		var existing := base.get_node_or_null(NodePath(VOXEL_VISIBILITY_PANEL_NAME))
		if existing != null:
			base.remove_child(existing)
			existing.queue_free()
	if _voxel_visibility_panel != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _voxel_visibility_panel)
		_voxel_visibility_panel.queue_free()
	_voxel_visibility_panel = null
	_voxel_visibility_buttons.clear()


func _on_voxel_visibility_toggled(pressed: bool, key: String) -> void:
	var host := _scene_voxel_display_host()
	if host == null or not host.has_method("set_voxel_display_visible"):
		return
	host.call("set_voxel_display_visible", key, pressed)
	_sync_voxel_visibility_panel_from_scene()


func _sync_voxel_visibility_panel_from_scene() -> void:
	if _voxel_visibility_panel == null:
		return
	var host := _scene_voxel_display_host()
	_voxel_visibility_panel.visible = host != null
	if host == null:
		return
	var state := {}
	if host.has_method("get_voxel_display_state"):
		var value = host.call("get_voxel_display_state")
		if value is Dictionary:
			state = value
	for key in _voxel_visibility_buttons.keys():
		var button := _voxel_visibility_buttons[key] as BaseButton
		if button == null:
			continue
		button.disabled = not host.has_method("set_voxel_display_visible")
		var visible := bool(state.get(str(key), true))
		if button.button_pressed != visible:
			button.set_pressed_no_signal(visible)
		_apply_voxel_visibility_button_style(button, visible, button.disabled)


func _apply_voxel_visibility_button_style(button: BaseButton, active: bool, disabled: bool) -> void:
	var bg := Color(0.17, 0.46, 0.70, 0.95) if active else Color(0.10, 0.12, 0.15, 0.92)
	var border := Color(0.48, 0.78, 1.0, 0.85) if active else Color(0.24, 0.32, 0.40, 0.82)
	if disabled:
		bg = Color(0.09, 0.10, 0.11, 0.45)
		border = Color(0.20, 0.22, 0.24, 0.45)
	var normal := StyleBoxFlat.new()
	normal.bg_color = bg
	normal.border_color = border
	normal.border_width_left = 1
	normal.border_width_top = 1
	normal.border_width_right = 1
	normal.border_width_bottom = 1
	normal.corner_radius_top_left = 2
	normal.corner_radius_top_right = 2
	normal.corner_radius_bottom_left = 2
	normal.corner_radius_bottom_right = 2
	normal.content_margin_left = 3.0
	normal.content_margin_right = 3.0
	normal.content_margin_top = 0.0
	normal.content_margin_bottom = 0.0
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = bg.lightened(0.14)
	button.add_theme_stylebox_override("hover", hover)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = bg.lightened(0.22) if active else Color(0.15, 0.22, 0.28, 0.95)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("hover_pressed", pressed)
	button.add_theme_stylebox_override("disabled", normal)
	button.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0, 1.0) if active else Color(0.62, 0.76, 0.88, 1.0))
	button.add_theme_color_override("font_disabled_color", Color(0.46, 0.50, 0.54, 1.0))


func _scene_voxel_display_host() -> Node:
	return _scene_spa_host()


# ---- TCP Server ------------------------------------------------------------

func _try_bind_tcp() -> bool:
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(MCP_PORT, "127.0.0.1")
	if err == OK:
		print("[MeshFill MCP] TCP listening on 127.0.0.1:%d" % MCP_PORT)
		return true
	_tcp_server.stop()
	_tcp_server = null
	return false


func _stop_tcp_server() -> void:
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null
	for p in _tcp_peers:
		(p as StreamPeerTCP).disconnect_from_host()
	_tcp_peers.clear()
	_peer_buffers.clear()


func _try_bind_single_instance_port() -> bool:
	_instance_server = TCPServer.new()
	var err := _instance_server.listen(SINGLE_INSTANCE_PORT, "127.0.0.1")
	if err == OK:
		print("[SingleInstance] Guard listening on 127.0.0.1:%d" % SINGLE_INSTANCE_PORT)
		return true
	_instance_server.stop()
	_instance_server = null
	return false


func _stop_single_instance_port() -> void:
	if _instance_server:
		_instance_server.stop()
		_instance_server = null


func _poll_single_instance_port() -> void:
	if _instance_server == null:
		return
	while _instance_server.is_connection_available():
		var peer := _instance_server.take_connection()
		if peer != null:
			peer.put_data((JSON.stringify({
				"status": "owned",
				"pid": OS.get_process_id(),
				"project": _project_key,
				"mcp_port": MCP_PORT
			}) + "\n").to_utf8_buffer())
			peer.disconnect_from_host()


func _poll_tcp() -> void:
	if _tcp_server == null:
		return
	while _tcp_server.is_connection_available():
		var peer := _tcp_server.take_connection()
		_tcp_peers.append(peer)
		_peer_buffers[peer.get_instance_id()] = ""
		print("[MeshFill MCP] Client connected")

	var to_remove: Array[int] = []
	for i in range(_tcp_peers.size()):
		var peer: StreamPeerTCP = _tcp_peers[i]
		peer.poll()
		match peer.get_status():
			StreamPeerTCP.STATUS_CONNECTED:
				var avail := peer.get_available_bytes()
				if avail > 0:
					var data := peer.get_utf8_string(avail)
					var pid := peer.get_instance_id()
					_peer_buffers[pid] = _peer_buffers.get(pid, "") + data
					_drain_buffer(peer)
			StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR:
				to_remove.append(i)

	for idx in range(to_remove.size() - 1, -1, -1):
		var peer: StreamPeerTCP = _tcp_peers[to_remove[idx]]
		_peer_buffers.erase(peer.get_instance_id())
		_tcp_peers.remove_at(to_remove[idx])


func _drain_buffer(peer: StreamPeerTCP) -> void:
	var pid := peer.get_instance_id()
	var buf: String = _peer_buffers.get(pid, "")
	while true:
		var nl := buf.find("\n")
		if nl < 0:
			break
		var line := buf.substr(0, nl).strip_edges()
		buf = buf.substr(nl + 1)
		if line.is_empty():
			continue
		var json := JSON.new()
		if json.parse(line) == OK:
			var resp := _dispatch(json.data as Dictionary)
			peer.put_data((JSON.stringify(resp) + "\n").to_utf8_buffer())
		else:
			peer.put_data((JSON.stringify({
				"id": null, "error": json.get_error_message()}) + "\n").to_utf8_buffer())
	_peer_buffers[pid] = buf


# ---- Command dispatch ------------------------------------------------------

func _dispatch(req: Dictionary) -> Dictionary:
	var rid = req.get("id")
	var method: String = str(req.get("method", ""))
	var params: Dictionary = req.get("params", {}) if req.has("params") else {}

	var result: Dictionary
	match method:
		"ping":
			result = {"status": "ok", "engine": "godot",
				"version": Engine.get_version_info().get("string", "?")}
		"get_scene_tree":
			result = _cmd_get_scene_tree(params)
		"select_node":
			result = _cmd_select_node(params)
		"deselect_all":
			result = _cmd_deselect_all()
		"get_selection":
			result = _cmd_get_selection()
		"get_node_info":
			result = _cmd_get_node_info(params)
		"set_node_property":
			result = _cmd_set_node_property(params)
		"move_node":
			result = _cmd_move_node(params)
		"get_children":
			result = _cmd_get_children(params)
		"call_method":
			result = _cmd_call_method(params)
		"get_open_scene":
			result = _cmd_get_open_scene()
		"open_scene":
			result = _cmd_open_scene(params)
		"screenshot":
			result = _cmd_screenshot(params)
		_:
			return {"id": rid, "error": "unknown method: %s" % method}

	return {"id": rid, "result": result}


# ---- Commands --------------------------------------------------------------

func _cmd_get_scene_tree(params: Dictionary) -> Dictionary:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var max_depth: int = int(params.get("max_depth", 4))
	return {"tree": _node_tree(root, 0, max_depth)}


func _node_tree(node: Node, depth: int, max_depth: int) -> Dictionary:
	var d: Dictionary = {
		"name": node.name,
		"type": node.get_class(),
		"path": str(node.get_path()),
	}
	if node is Node3D:
		var p: Vector3 = (node as Node3D).position
		d["pos"] = [roundf(p.x * 100.0) * 0.01, roundf(p.y * 100.0) * 0.01, roundf(p.z * 100.0) * 0.01]
	if node.get_script():
		d["script"] = str(node.get_script().resource_path)
	if depth < max_depth:
		var ch: Array = []
		for c in node.get_children():
			ch.append(_node_tree(c, depth + 1, max_depth))
		if ch.size() > 0:
			d["children"] = ch
	return d


func _resolve_edited_scene_node(path: String) -> Node:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return null
	var root_name := str(root.name)
	var normalized := path.strip_edges()
	if normalized.is_empty() or normalized == ".":
		return root
	if normalized == root_name:
		return root
	if normalized.begins_with("%s/" % root_name):
		normalized = normalized.substr(root_name.length() + 1)
		if normalized.is_empty():
			return root
	if normalized.begins_with("./"):
		normalized = normalized.substr(2)
		if normalized.is_empty():
			return root
	var node: Node
	if normalized.begins_with("/"):
		node = root.get_tree().root.get_node_or_null(NodePath(normalized))
	else:
		node = root.get_node_or_null(NodePath(normalized))
	if node == root:
		return node
	if node != null and root.is_ancestor_of(node):
		return node
	return null


func _cmd_select_node(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	if path.is_empty():
		return {"error": "missing 'path'"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null:
		return {"error": "node not found: %s" % path}
	var sel := get_editor_interface().get_selection()
	sel.clear()
	sel.add_node(node)
	return {"ok": true, "selected": str(node.get_path())}


func _cmd_deselect_all() -> Dictionary:
	get_editor_interface().get_selection().clear()
	return {"ok": true}


func _cmd_get_selection() -> Dictionary:
	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	var paths: Array = []
	for n in nodes:
		paths.append(str(n.get_path()))
	return {"selected": paths, "count": paths.size()}


func _cmd_get_node_info(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null:
		return {"error": "node not found"}
	var info: Dictionary = {
		"name": node.name, "type": node.get_class(),
		"path": str(node.get_path()),
		"child_count": node.get_child_count(),
	}
	if node is Node3D:
		var n3 := node as Node3D
		info["position"] = [n3.position.x, n3.position.y, n3.position.z]
		info["rotation_deg"] = [rad_to_deg(n3.rotation.x),
			rad_to_deg(n3.rotation.y), rad_to_deg(n3.rotation.z)]
		info["scale"] = [n3.scale.x, n3.scale.y, n3.scale.z]
	if node is MeshInstance3D:
		info["has_mesh"] = (node as MeshInstance3D).mesh != null
	if node.get_script():
		info["script"] = str(node.get_script().resource_path)
	var meta_keys := node.get_meta_list()
	if meta_keys.size() > 0:
		var md: Dictionary = {}
		for k in meta_keys:
			md[k] = str(node.get_meta(k))
		info["metadata"] = md
	return info


func _cmd_set_node_property(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var prop: String = str(params.get("property", ""))
	var value = params.get("value")
	if prop.is_empty():
		return {"error": "missing 'property'"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null:
		return {"error": "node not found"}
	if prop == "position" and node is Node3D and value is Array:
		(node as Node3D).position = Vector3(value[0], value[1], value[2])
	elif prop == "rotation" and node is Node3D and value is Array:
		(node as Node3D).rotation = Vector3(value[0], value[1], value[2])
	elif prop == "scale" and node is Node3D and value is Array:
		(node as Node3D).scale = Vector3(value[0], value[1], value[2])
	else:
		node.set(prop, value)
	return {"ok": true}


func _cmd_move_node(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var pos: Array = params.get("position", []) if params.has("position") else []
	if pos.size() < 3:
		return {"error": "missing 'position' [x,y,z]"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null or not node is Node3D:
		return {"error": "node not found or not Node3D"}
	(node as Node3D).position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	return {"ok": true, "position": pos}


func _cmd_get_children(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null:
		return {"error": "node not found"}
	var ch: Array = []
	for c in node.get_children():
		var info: Dictionary = {"name": c.name, "type": c.get_class()}
		if c is Node3D:
			var p: Vector3 = (c as Node3D).position
			info["pos"] = [roundf(p.x * 100.0) * 0.01, roundf(p.y * 100.0) * 0.01, roundf(p.z * 100.0) * 0.01]
		ch.append(info)
	return {"children": ch, "count": ch.size()}


func _cmd_call_method(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var method_name: String = str(params.get("method", ""))
	var args: Array = params.get("args", []) if params.has("args") else []
	if method_name.is_empty():
		return {"error": "missing 'method'"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null:
		return {"error": "node not found"}
	if not node.has_method(method_name):
		return {"error": "method not found: %s" % method_name}
	var result = node.callv(method_name, args)
	return {"ok": true, "return": str(result) if result != null else null}


func _cmd_get_open_scene() -> Dictionary:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"scene": null}
	return {
		"scene": root.scene_file_path,
		"root_name": root.name,
		"root_type": root.get_class(),
	}


func _cmd_open_scene(params: Dictionary) -> Dictionary:
	var scene_path: String = str(params.get("path", ""))
	if scene_path.is_empty():
		return {"error": "missing 'path' param"}
	get_editor_interface().open_scene_from_path(scene_path)
	var root := get_editor_interface().get_edited_scene_root()
	return {
		"ok": true,
		"scene": root.scene_file_path if root else null,
		"root_name": root.name if root else null,
	}


## Capture the editor 3D viewport (the edited scene's viewport) to a PNG file and
## return its absolute path so external tooling can read the image directly.
func _cmd_screenshot(params: Dictionary) -> Dictionary:
	var ei := get_editor_interface()
	# 必须用 3D 编辑器视口；edited_scene_root.get_viewport() 是 2x2 占位视口。
	ei.set_main_screen_editor("3D")
	var viewport: Viewport = ei.get_editor_viewport_3d(0)
	if viewport == null:
		var root := ei.get_edited_scene_root()
		viewport = root.get_viewport() if root != null else null
	if viewport == null or viewport.get_texture() == null:
		return {"error": "no viewport texture"}
	var img: Image = viewport.get_texture().get_image()
	if img == null:
		return {"error": "no viewport image"}
	var req_path: String = str(params.get("path", "res://_shots/mcp_screenshot.png"))
	var abs_path := req_path
	if req_path.begins_with("res://") or req_path.begins_with("user://"):
		abs_path = ProjectSettings.globalize_path(req_path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var err := img.save_png(abs_path)
	if err != OK:
		return {"error": "save_png failed: %d" % err}
	return {
		"ok": true,
		"path": abs_path,
		"width": img.get_width(),
		"height": img.get_height(),
	}


# ---- Single-instance guard ----

func _mark_duplicate_and_quit(reason: String) -> void:
	_duplicate_instance = true
	_duplicate_reason = reason
	set_process(false)
	_stop_tcp_server()
	_stop_single_instance_port()
	_release_lock()
	push_error("[SingleInstance] Duplicate editor blocked: %s" % reason)
	call_deferred("_force_quit_duplicate", reason)


func _force_quit_duplicate(reason: String = "") -> void:
	var msg := "[SingleInstance] FATAL: Another Godot editor is already running this project. This instance will now terminate."
	if not reason.strip_edges().is_empty():
		msg += "\n\nReason: %s" % reason
	push_error(msg)
	printerr(msg)
	OS.alert(msg, "MeshFill: Duplicate Editor Blocked")
	get_tree().quit(1)


# ---- Documentation file import cleanup (.svg / .md) ----

const _JUNK_IMPORT_EXTENSIONS := [".svg.import", ".md.import", ".png.import"]
const _JUNK_IMPORT_DIRS := ["res://demos", "res://_shots"]

func _cleanup_doc_import_files() -> void:
	var removed := 0
	for scan_dir in _JUNK_IMPORT_DIRS:
		removed += _remove_junk_imports_in(scan_dir)
	if removed > 0:
		print("[MeshFill Editor] Removed %d junk .import files (.svg/.md/.png/screenshots)" % removed)


func _remove_junk_imports_in(scan_path: String) -> int:
	var removed := 0
	var dir := DirAccess.open(scan_path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := scan_path.path_join(entry)
		if dir.current_is_dir():
			if entry != "." and entry != "..":
				removed += _remove_junk_imports_in(full)
		else:
			var dominated := false
			for ext in _JUNK_IMPORT_EXTENSIONS:
				if entry.ends_with(ext):
					dominated = true
					break
			if not dominated and scan_path == "res://_shots" and entry.ends_with(".import"):
				dominated = true
			if dominated:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
				removed += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return removed


func _acquire_single_instance_lock() -> bool:
	var my_pid := OS.get_process_id()
	var existing := _read_lock()
	if _lock_represents_live_editor(existing):
		_duplicate_reason = _format_existing_lock_reason(existing)
		print("[SingleInstance] Blocked: %s" % _duplicate_reason)
		return false
	if not existing.is_empty():
		print("[SingleInstance] Reclaiming stale lock: %s" % _format_existing_lock_reason(existing))
	if not _write_lock(my_pid):
		_duplicate_reason = "Could not write lock file: %s" % LOCK_FILE
		return false
	var verify := _read_lock()
	if not _lock_matches_current_instance(verify):
		_duplicate_reason = "Lock ownership verification failed after write."
		return false
	_lock_held = true
	print("[SingleInstance] Lock acquired (PID %d, token %s)" % [my_pid, _instance_token])
	return true


func _write_lock(pid: int) -> bool:
	var file := FileAccess.open(LOCK_FILE, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(_make_lock_payload(pid), "\t"))
	file.close()
	return true


func _write_heartbeat() -> void:
	if not _lock_held:
		return
	var current := _read_lock()
	if not _lock_matches_current_instance(current):
		_lock_held = false
		_mark_duplicate_and_quit("Single-instance lock ownership was lost.")
		return
	if not _write_lock(OS.get_process_id()):
		_lock_held = false
		_mark_duplicate_and_quit("Could not update single-instance heartbeat.")


func _release_lock() -> void:
	if not _lock_held:
		return
	var lock_path := ProjectSettings.globalize_path(LOCK_FILE)
	var current := _read_lock()
	if FileAccess.file_exists(LOCK_FILE) and _lock_matches_current_instance(current):
		DirAccess.remove_absolute(lock_path)
		print("[SingleInstance] Lock released (PID %d)" % OS.get_process_id())
	elif FileAccess.file_exists(LOCK_FILE):
		print("[SingleInstance] Lock not released because ownership no longer matches this instance.")
	_lock_held = false


func _ensure_instance_identity() -> void:
	if not _project_key.is_empty() and not _instance_token.is_empty():
		return
	_project_key = ProjectSettings.globalize_path("res://").simplify_path()
	_instance_token = "%d:%d:%d" % [OS.get_process_id(), Time.get_ticks_msec(), _project_key.hash()]


func _make_lock_payload(pid: int) -> Dictionary:
	return {
		"format": 2,
		"pid": pid,
		"heartbeat": Time.get_unix_time_from_system(),
		"project": _project_key,
		"token": _instance_token,
		"single_instance_port": SINGLE_INSTANCE_PORT,
		"mcp_port": MCP_PORT,
		"engine": str(Engine.get_version_info().get("string", "?"))
	}


func _read_lock() -> Dictionary:
	if not FileAccess.file_exists(LOCK_FILE):
		return {}
	var file := FileAccess.open(LOCK_FILE, FileAccess.READ)
	if file == null:
		return {"read_error": true}
	var content := file.get_as_text().strip_edges()
	file.close()
	if content.is_empty():
		return {}
	var parsed = JSON.parse_string(content)
	if parsed is Dictionary:
		return parsed
	return _read_legacy_lock(content)


func _read_legacy_lock(content: String) -> Dictionary:
	var parts := content.split("\n")
	return {
		"format": 1,
		"pid": parts[0].to_int() if parts.size() > 0 else 0,
		"heartbeat": parts[1].to_float() if parts.size() > 1 else 0.0,
		"project": "",
		"token": "",
		"legacy": true
	}


func _lock_represents_live_editor(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	if data.has("read_error"):
		return true
	var pid := int(data.get("pid", 0))
	var token := str(data.get("token", ""))
	if pid == OS.get_process_id():
		return false
	var heartbeat := float(data.get("heartbeat", 0.0))
	var age := Time.get_unix_time_from_system() - heartbeat
	if heartbeat > 0.0 and age >= 0.0 and age < HEARTBEAT_STALE_SEC and token != _instance_token:
		return true
	# Heartbeat is stale. The PID fallback exists for an editor whose main
	# thread is blocked >15s (long import/GPU work), but the OS recycles dead
	# PIDs onto unrelated processes — only a PID that is still a *Godot*
	# process may keep the lock, else launches stay blocked forever.
	if pid > 0 and _is_godot_pid_alive(pid):
		return true
	return false


func _lock_matches_current_instance(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	return int(data.get("pid", 0)) == OS.get_process_id() \
		and str(data.get("token", "")) == _instance_token \
		and str(data.get("project", "")) == _project_key


func _format_existing_lock_reason(data: Dictionary) -> String:
	if data.is_empty():
		return "empty lock"
	if data.has("read_error"):
		return "existing lock file could not be read"
	var heartbeat := float(data.get("heartbeat", 0.0))
	var age := Time.get_unix_time_from_system() - heartbeat if heartbeat > 0.0 else -1.0
	var age_text := "%.1fs ago" % age if age >= 0.0 else "unknown age"
	var project := str(data.get("project", "unknown project"))
	if project.is_empty():
		project = "legacy lock"
	return "PID %d, heartbeat %s, project %s" % [int(data.get("pid", 0)), age_text, project]


func _is_godot_pid_alive(pid: int) -> bool:
	return _process_image_name(pid).to_lower().begins_with("godot")


## 返回 pid 对应进程的镜像名；进程不存在返回 ""。PID 必须整字段精确匹配，
## 避免旧版 find(str(pid)) 把内存数值/其他字段里的数字串误判为存活。
func _process_image_name(pid: int) -> String:
	var output: Array = []
	if OS.get_name() == "Windows":
		OS.execute("tasklist", PackedStringArray(["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"]), output)
		if output.is_empty():
			return ""
		for raw_line in str(output[0]).split("\n"):
			var line := raw_line.strip_edges()
			# 匹配行形如 "image.exe","1234",...；无匹配时 tasklist 输出 INFO: 提示行
			if not line.begins_with("\""):
				continue
			var fields := line.split("\",\"")
			if fields.size() < 2:
				continue
			if fields[1].strip_edges() == str(pid):
				return fields[0].trim_prefix("\"")
		return ""
	OS.execute("ps", PackedStringArray(["-p", str(pid), "-o", "comm="]), output)
	if output.is_empty():
		return ""
	return str(output[0]).strip_edges().get_file()


# ---- Scene validation (terrain + TargetSV) ---------------------------------

func _connect_scene_signals() -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		scene_changed.connect(_on_scene_changed)


func _disconnect_scene_signals() -> void:
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)


func _on_scene_changed(scene_root: Node) -> void:
	_validate_scene(scene_root)


func _validate_current_scene() -> void:
	var root := get_editor_interface().get_edited_scene_root()
	if root != null:
		_validate_scene(root)


func _validate_scene(root: Node) -> void:
	_scene_has_brush = _detect_scene_brush(root)
	if root == null:
		return
	_validate_terrain(root)
	_validate_targetsv(root)
	_enforce_headless_guard()


func _validate_terrain(root: Node) -> void:
	var terrain := root.find_child("Terrain", true, false) as MeshInstance3D
	if terrain == null:
		return
	if terrain.mesh == null:
		push_warning("[MeshFill Plugin] Scene '%s' Terrain node has no mesh" % root.name)
		return
	var capture := float(terrain.get_meta("terrain_capture_size", 0))
	if capture <= 0.0:
		push_warning("[MeshFill Plugin] Scene '%s' Terrain missing capture_size metadata" % root.name)


func _validate_targetsv(root: Node) -> void:
	var tsv := root.find_child("TargetSVSetup", true, false)
	if tsv == null:
		return
	if tsv.has_method("is_targetsv_ready"):
		if not tsv.is_targetsv_ready():
			push_warning("[MeshFill Plugin] Scene '%s' TargetSVSetup failed to load data" % root.name)


func _enforce_headless_guard() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("[MeshFill Plugin] Editor should not run in headless mode for this project")
