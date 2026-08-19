@tool
extends EditorInspectorPlugin

## SPA 的 Placement 操作区（固定槽位Profile共享Buffer实施计划 §11.1）。
##
##     [Reload]
##     [Anchors]  [Score]  [Place]
##
## 加载期间 Reload 禁用（防重复提交）；Arena 未就绪时 Anchors/Score/Place 禁用，
## 并用 Tooltip 说明原因。禁用只是防误触——真正的前置检查仍在 SPA 的 run_* 里。
##
## 曾有一个并列的 [Load Baked Assets]（force=false，吃"目录未变即已加载"短路）。已删除：
## 两个按钮的差别只在短路，而重新烘焙常同名覆盖、目录签名不变，Load 会静默复用旧 Arena
## ——留着只会让人点错。Reload 恒走 force 路径，是唯一入口。

const LOAD_PROPERTIES := [
	&"_reload_baked_assets_action",
]
const ACTION_PROPERTIES := [
	&"_generate_anchors_action",
	&"_score_action",
	&"_place_action",
	&"_clear_all_action",
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
		# 保持"挂在第一个属性上"的写法：将来若再加并列加载按钮，只需扩 LOAD_PROPERTIES
		# 与 _build_load_row，其余属性自动被吞掉、不会冒出原生按钮。
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
	row.add_child(_make_action_button(spa, LOAD_PROPERTIES[0], "Reload", "Reload"))
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
	# Clear All **不吃 blocked_reason**：Arena 未就绪恰恰是最想清场的时候之一
	# （比如资产表换代后想把旧放置结果一次抹掉），把它一起禁掉等于把出口锁上。
	row.add_child(_make_action_button(spa, ACTION_PROPERTIES[3], "Clear All", "Clear"))
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
