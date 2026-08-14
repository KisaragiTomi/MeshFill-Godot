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
const SAVE_METHOD := &"save_asset_params"
const PREVIEW_METHOD := &"preview_exclusion_radius_scale"


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

	var descriptor_path := str(payload.get("descriptor_path", ""))

	var spacing_row: Dictionary = payload.get("spacing", {})
	var spacing_spin := _build_spacing_row(root, spacing_row, descriptor_path)

	root.add_child(HSeparator.new())
	var hint := Label.new()
	hint.text = "Score params (per-asset — uncheck = inherit global config)"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(hint)

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
	save_btn.text = "Save asset params"
	root.add_child(save_btn)
	# 保存结果必须看得见：以前保存失败（如资产还没烘过 descriptor）只在控制台留一条
	# push_warning，面板上没有任何变化 —— 界面看起来"改好了"，盘上其实一个字没写。
	var status := Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override("font_size", 11)
	status.text = "unsaved edits preview live; Save writes the .tres"
	root.add_child(status)
	save_btn.pressed.connect(func() -> void:
		_on_save_pressed(descriptor_path, rows, spacing_row, spacing_spin, status))
	return root


# 互斥半径乘数行：标签 + SpinBox + 实时「= X.XXX m」读数。
#
# 与下面的 score 行不同，这里**没有** override 勾选框——这个乘数没有"继承全局"的对家，
# 默认就是 1.0。
#
# 改一下就即时生效：`value_changed` 直接把新值写进内存里的 descriptor 并重建互斥球
# （PREVIEW_METHOD），等价于 UE ConstructionScript 的即时反馈；Save 才落盘 .tres。
func _build_spacing_row(root: VBoxContainer, spacing: Dictionary, descriptor_path: String) -> SpinBox:
	if spacing.is_empty():
		return null
	var base_radius := float(spacing.get("base_radius", 0.0))
	root.add_child(HSeparator.new())
	var hint := Label.new()
	hint.text = "Exclusion radius (per-asset — drives the overview spheres + SPA placement spacing)"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(hint)

	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = str(spacing.get("label", "exclusion radius ×"))
	label.custom_minimum_size = Vector2(140, 0)
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = float(spacing.get("min", 0.0))
	spin.max_value = float(spacing.get("max", 8.0))
	spin.step = float(spacing.get("step", 0.05))
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.set_value_no_signal(clampf(float(spacing.get("value", 1.0)), spin.min_value, spin.max_value))
	# 没烘过 descriptor 就无处可写：留只读，Save 那边同样会 push_warning 说明原因。
	spin.editable = bool(spacing.get("has_descriptor", false))
	row.add_child(spin)
	var readout := Label.new()
	readout.custom_minimum_size = Vector2(90, 0)
	readout.text = "= %.3f m" % (base_radius * spin.value)
	row.add_child(readout)
	spin.value_changed.connect(func(value: float) -> void:
		readout.text = "= %.3f m" % (base_radius * value)
		_preview_spacing_scale(descriptor_path, value))
	root.add_child(row)
	return spin


# 即时预览：只改内存里的 descriptor + 重建互斥球，不写盘。
func _preview_spacing_scale(descriptor_path: String, scale: float) -> void:
	var host := _scene_host()
	if host == null or not host.has_method(PREVIEW_METHOD):
		return
	host.call(PREVIEW_METHOD, descriptor_path, scale)


# Gather each row's value (checked -> SpinBox value; unchecked -> -1 inherit) plus
# the exclusion radius multiplier, and hand them to the scene to write onto the
# descriptor .tres. 保存结果回填到 status 标签。
#
# ⚠ 每个 SpinBox 先 apply()：在输入框里敲了数字但没按回车时，`value` 仍是旧值，直接读会
# 静默保存**旧**参数——界面显示新数、盘上写的是老数，最难查的一种。
func _on_save_pressed(
	descriptor_path: String,
	rows: Dictionary,
	spacing: Dictionary,
	spacing_spin: SpinBox,
	status: Label
) -> void:
	var host := _scene_host()
	if host == null:
		return
	var values := {}
	for prop in rows:
		var chk: CheckBox = rows[prop]["chk"]
		var spin: SpinBox = rows[prop]["spin"]
		spin.apply()
		values[prop] = spin.value if chk.button_pressed else -1.0
	if spacing_spin != null and not spacing.is_empty():
		spacing_spin.apply()
		values[str(spacing.get("prop", "spacing_radius_scale"))] = spacing_spin.value
	var result = host.call(SAVE_METHOD, descriptor_path, values)
	if status == null:
		return
	if result is Dictionary and bool((result as Dictionary).get("ok", false)):
		status.text = "Saved → %s" % descriptor_path.get_file()
	else:
		var reason := str((result as Dictionary).get("reason", "unknown")) if result is Dictionary else "no_result"
		status.text = "SAVE FAILED (%s) — see Output" % reason
