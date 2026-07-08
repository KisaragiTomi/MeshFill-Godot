@tool
extends RefCounted

# 合成 InputEvent 构造器,供测试/截图脚本向 demo 节点注入模拟输入。
# 原 tools/shot_sv_anchor_collection / shot_targetsv_brush_overlay /
# test_target_sv_point_cloud_conversion 中重复的事件搭建样板。
# 注入方式由调用方决定(通常 `node.call("_unhandled_input", ev)`)。


## 构造按键事件:keycode 同时写入 physical_keycode(demo 热键两者都判)。
static func make_key(keycode: Key, shift: bool = false, pressed: bool = true) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.shift_pressed = shift
	ev.pressed = pressed
	return ev


## 构造鼠标按键事件:position 与 global_position 都设为 pos(demo 直读两者)。
static func make_mouse_button(pos: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT, pressed: bool = true) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	return ev
