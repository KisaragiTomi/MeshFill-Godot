@tool
extends EditorInspectorPlugin

## SPA 的 Placement 操作区（固定槽位Profile共享Buffer实施计划 §11.1）。
##
##     [Load Baked Assets]  [Reload]
##     [Anchors]  [Score]  [Place]
##
## 加载期间两个加载按钮禁用（防重复提交）；Arena 未就绪时 Anchors/Score/Place 禁用，
## 并用 Tooltip 说明原因。禁用只是防误触——真正的前置检查仍在 SPA 的 run_* 里。

const LOAD_PROPERTIES := [
	&"_load_baked_assets_action",
	&"_reload_baked_assets_action",
]
const ACTION_PROPERTIES := [
	&"_generate_anchors_action",
	&"_score_action",
	&"_place_action",
]


func _can_handle(object: Object) -> bool:
	return object is ScenePlacementActor


func _parse_property(
	object: Object,
	_type: Variant.Type,
	name: String,
	_hint_type: PropertyHint,
	_hint_string: String,
	_usage_flags: int,
	_wide: bool
) -> bool:
	var property := StringName(name)
	if LOAD_PROPERTIES.has(property):
		# 两个加载按钮合成一行，挂在第一个属性上；第二个只负责把原生按钮吞掉。
		if property == LOAD_PROPERTIES[0]:
			add_custom_control(_build_load_row(object))
		return true
	if ACTION_PROPERTIES.has(property):
		if property == ACTION_PROPERTIES[0]:
			add_custom_control(_build_action_row(object))
		return true
	return false


func _build_load_row(spa: Object) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	# 没有 Bake 产物时按钮**仍可点击**（§11.1）——由 load_baked_assets() 返回明确提示，
	# 而不是把入口藏起来让人猜为什么点不动。
	row.add_child(_make_action_button(spa, LOAD_PROPERTIES[0], "Load Baked Assets", "Load"))
	row.add_child(_make_action_button(spa, LOAD_PROPERTIES[1], "Reload", "Reload"))
	return row


func _build_action_row(spa: Object) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var blocked_reason := ""
	if spa.has_method("get_placement_blocked_reason"):
		blocked_reason = str(spa.call("get_placement_blocked_reason"))
	row.add_child(_make_action_button(spa, ACTION_PROPERTIES[0], "Anchors", "Add", blocked_reason))
	row.add_child(_make_action_button(spa, ACTION_PROPERTIES[1], "Score", "Play", blocked_reason))
	row.add_child(_make_action_button(spa, ACTION_PROPERTIES[2], "Place", "MeshInstance3D", blocked_reason))
	return row


## blocked_reason 非空 ⟹ 按钮禁用并把原因挂进 Tooltip（§11.1 要求说明原因）。
func _make_action_button(
	spa: Object,
	property: StringName,
	label: String,
	icon_name: String,
	blocked_reason: String = ""
) -> Button:
	var button := Button.new()
	button.text = label
	button.icon = EditorInterface.get_editor_theme().get_icon(icon_name, "EditorIcons")
	button.expand_icon = false
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.disabled = not blocked_reason.is_empty()
	button.tooltip_text = blocked_reason
	button.pressed.connect(func() -> void:
		# 加载/重载期间禁用整行，避免重复提交（§11.1）。
		var siblings := button.get_parent().get_children() if button.get_parent() != null else []
		for sibling in siblings:
			if sibling is Button:
				(sibling as Button).disabled = true
		# 恢复用帧末兜底（call_deferred）：action.call() 同步执行完才到帧末，防连击窗口不变；
		# 但 call 中途运行期报错时恢复仍会执行，按钮行不会永久锁死（曾因双实例冲突实际发生）。
		var restore := func() -> void:
			for sibling in siblings:
				if is_instance_valid(sibling) and sibling is Button:
					(sibling as Button).disabled = false
		restore.call_deferred()
		var action: Callable = spa.get(property)
		if action.is_valid(): action.call()
	)
	return button
