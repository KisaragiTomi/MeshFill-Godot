@tool
extends EditorInspectorPlugin

# Inline asset-info panel for the Inspector, replacing the old toolbar popup.
#
# When the editor-selected node resolves to an asset in the asset-overview scene,
# this plugin renders that asset's read-only properties plus its editable
# per-asset fine-score overrides directly in the Inspector (the right dock).
#
# Why this instead of an AcceptDialog: a dialog shown from a @tool scene living
# inside the editor 3D SubViewport silently fails to re-appear when a cached
# dialog instance is re-popped on the next object (the "switch object -> no
# popup" bug). The Inspector rebuilds its controls from scratch on every
# selection change, so there is no reused window state to break.
#
# Data stays in the scene (asset_overview.gd owns the embedded FBX sample view):
# this plugin only calls the scene's data + save methods and builds the UI.

const RESOLVE_METHOD := &"resolve_asset_node"
const PAYLOAD_METHOD := &"get_asset_inspector_payload"
const SAVE_METHOD := &"save_asset_score_params"


func _can_handle(object: Object) -> bool:
	return _resolve_asset(object) != null


func _parse_begin(object: Object) -> void:
	var asset := _resolve_asset(object)
	if asset == null:
		return
	var host := _scene_host()
	if host == null:
		return
	var payload: Dictionary = host.call(PAYLOAD_METHOD, asset)
	if not bool(payload.get("ok", false)):
		return
	add_custom_control(_build_panel(payload))


# The edited-scene root is the host iff it exposes the asset-info data method
# (only the asset-overview scene does), so this plugin is inert elsewhere.
func _scene_host() -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root != null and root.has_method(PAYLOAD_METHOD) and root.has_method(RESOLVE_METHOD):
		return root
	return null


# Resolve the inspected object (asset root OR a child like its Mesh) to the
# owning asset node, or null when it is not an asset in this scene.
func _resolve_asset(object: Object) -> Node3D:
	if not (object is Node):
		return null
	var host := _scene_host()
	if host == null:
		return null
	return host.call(RESOLVE_METHOD, object) as Node3D


func _build_panel(payload: Dictionary) -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)

	var header := Label.new()
	header.text = "Asset Info — %s" % str(payload.get("name", "?"))
	root.add_child(header)

	var info := TextEdit.new()
	info.editable = false
	info.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	info.custom_minimum_size = Vector2(0, 210)
	info.text = str(payload.get("text", ""))
	root.add_child(info)

	root.add_child(HSeparator.new())
	var hint := Label.new()
	hint.text = "Score params (per-asset — uncheck = inherit global config)"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(hint)

	var descriptor_path := str(payload.get("descriptor_path", ""))
	# prop -> {chk, spin}; read back on Save.
	var rows := {}
	for entry in payload.get("params", []):
		var prop := str(entry.get("prop", ""))
		var row := HBoxContainer.new()
		var chk := CheckBox.new()
		chk.text = "override"
		chk.button_pressed = bool(entry.get("overridden", false))
		row.add_child(chk)
		var label := Label.new()
		label.text = str(entry.get("label", prop))
		label.custom_minimum_size = Vector2(140, 0)
		row.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = float(entry.get("min", 0.0))
		spin.max_value = float(entry.get("max", 1.0))
		spin.step = float(entry.get("step", 0.01))
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.editable = chk.button_pressed
		spin.set_value_no_signal(clampf(float(entry.get("value", 0.0)), spin.min_value, spin.max_value))
		row.add_child(spin)
		# Checkbox gates the SpinBox: unchecked = inherit (SpinBox disabled).
		chk.toggled.connect(func(pressed: bool) -> void: spin.editable = pressed)
		rows[prop] = {"chk": chk, "spin": spin}
		root.add_child(row)

	var save_btn := Button.new()
	save_btn.text = "Save score params"
	save_btn.pressed.connect(func() -> void: _on_save_pressed(descriptor_path, rows))
	root.add_child(save_btn)
	return root


# Gather each row's value (checked -> SpinBox value; unchecked -> -1 inherit) and
# hand it to the scene to write onto the descriptor .tres.
func _on_save_pressed(descriptor_path: String, rows: Dictionary) -> void:
	var host := _scene_host()
	if host == null:
		return
	var values := {}
	for prop in rows:
		var chk: CheckBox = rows[prop]["chk"]
		var spin: SpinBox = rows[prop]["spin"]
		values[prop] = spin.value if chk.button_pressed else -1.0
	host.call(SAVE_METHOD, descriptor_path, values)
