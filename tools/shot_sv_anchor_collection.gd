extends SceneTree

# SV anchor collection 截图门禁（编辑器桥客户端，当前架构版）。
#
# 旧版通过本地实例化场景、注入 `_unhandled_input`、数箭头节点（Shaft/Head）来验证
# —— 三者都已失效：demo 输入改经 CoreSPADemo 的 provider forwarding
# （forward_editor_viewport_input），锚点显示改为 AnchorDisplay 下的
# VoxelDisplay.build_colored MultiMesh 层（"Layer_anchor"），且
# core_demo_contract_fixture 禁止在编辑器外实例化 demo 场景（FATAL assert）。
#
# 现在改为驱动运行中的编辑器（meshfill 插件 TCP 桥 127.0.0.1:6800）：
#   1. 确保 core-sv-anchor-collection 场景已打开（打开即自动跑 GPU 采集）；
#   2. 轮询 has_volume_score_anchors == true（provider 契约面）；
#   3. 经热键派发目标 `_rerun()` 重跑采集（Shift+G/R 在
#      forward_editor_viewport_input 中的 dispatch 目标——桥的 JSON 参数无法构造
#      InputEventKey/Camera3D，故直接调用其派发目标），并再次断言锚点存在；
#   4. 断言显示产物: AnchorDisplay 下存在 MultiMeshInstance3D "Layer_anchor"，
#      且 get_anchor_world_positions 非空；
#   5. 编辑器视口截图必须成功且落盘非空。
# 任一断言失败 → exit 1。
#
# 运行方式（headless 即可，截图发生在编辑器进程内）：
#   godot --headless --path . --script res://tools/shot_sv_anchor_collection.gd
# 前置条件：一个已启动的编辑器（-e，vulkan）。

const HOST := "127.0.0.1"
const PORT := 6800
const SCENE_PATH := "res://demos/core-sv-anchor-collection/core-sv-anchor-collection.tscn"
const DEMO_NODE := "."  # demo 脚本挂在场景根 SVAnchorCollectionDemo
const DISPLAY_NODE := "AnchorDisplay"
const ANCHOR_LAYER_NAME := "Layer_anchor"
const SHOT_PATH := "res://tools/_shots/sv_anchor_collection_anchor_layer.png"
const ANCHOR_WAIT_MS := 60000

var _next_id := 0


func _initialize() -> void:
	var failures: Array[String] = []

	var ping := _result(_request("ping", {}, 5000))
	if str(ping.get("status", "")) != "ok":
		print("[ANCHOR_SHOT] FAIL editor bridge unreachable at %s:%d (launch the editor: -e, vulkan)" % [HOST, PORT])
		quit(1)
		return

	if not _ensure_scene_open():
		print("[ANCHOR_SHOT] FAIL scene did not open in the editor: ", SCENE_PATH)
		quit(1)
		return
	print("[ANCHOR_SHOT] scene open: ", SCENE_PATH)

	# 1) 场景打开时 _deferred_init 自动采集；等它出锚点。
	if not _wait_anchors(ANCHOR_WAIT_MS):
		failures.append("no anchors after scene open (has_volume_score_anchors stayed false)")
	else:
		print("[ANCHOR_SHOT] anchors collected on open")
		# 2) 经热键派发目标重跑采集（forward_editor_viewport_input 的 Shift+G/R 路径）。
		var rerun := _result(_request("call_method", {"path": DEMO_NODE, "method": "_rerun"}, 120000))
		if not bool(rerun.get("ok", false)):
			failures.append("_rerun via bridge failed: %s" % _brief(str(rerun)))
		elif not _wait_anchors(ANCHOR_WAIT_MS):
			failures.append("anchors missing after _rerun")
		else:
			print("[ANCHOR_SHOT] anchors present after _rerun")

	# 3) provider 数据面: 锚点世界坐标非空。
	var pos := _result(_request(
		"call_method", {"path": DEMO_NODE, "method": "get_anchor_world_positions"}, 30000))
	var pos_return := str(pos.get("return", ""))
	if not bool(pos.get("ok", false)) or pos_return.is_empty() or pos_return == "[]":
		failures.append("get_anchor_world_positions empty: %s" % _brief(str(pos)))
	else:
		print("[ANCHOR_SHOT] anchor world positions non-empty")

	# 4) 显示产物: AnchorDisplay 下的 anchor 层 MultiMesh 节点。
	var children := _result(_request("get_children", {"path": DISPLAY_NODE}, 10000))
	var layer_found := false
	var names: Array[String] = []
	for child in children.get("children", []):
		if not child is Dictionary:
			continue
		var c := child as Dictionary
		names.append("%s(%s)" % [str(c.get("name", "")), str(c.get("type", ""))])
		if str(c.get("name", "")) == ANCHOR_LAYER_NAME and str(c.get("type", "")) == "MultiMeshInstance3D":
			layer_found = true
	print("[ANCHOR_SHOT] AnchorDisplay children=", names)
	if not layer_found:
		failures.append("AnchorDisplay/%s (MultiMeshInstance3D) missing" % ANCHOR_LAYER_NAME)

	# 5) 截图非空（编辑器 3D 视口）。
	var shot := _result(_request("screenshot", {"path": SHOT_PATH}, 60000))
	var width := int(shot.get("width", 0))
	var height := int(shot.get("height", 0))
	var abs_path := str(shot.get("path", ""))
	var shot_ok := bool(shot.get("ok", false)) and width > 0 and height > 0
	if shot_ok:
		shot_ok = FileAccess.file_exists(abs_path) \
			and FileAccess.get_file_as_bytes(abs_path).size() > 0
	if shot_ok:
		print("[ANCHOR_SHOT] saved ", abs_path, " (", width, "x", height, ")")
	else:
		failures.append("screenshot failed or empty: %s" % _brief(str(shot)))

	for f in failures:
		print("[ANCHOR_SHOT] FAIL ", f)
	print("[ANCHOR_SHOT] RESULT ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


func _ensure_scene_open() -> bool:
	var scene := _result(_request("get_open_scene", {}, 10000))
	if str(scene.get("scene", "")) == SCENE_PATH:
		return true
	_request("open_scene", {"path": SCENE_PATH}, 120000)
	for i in range(60):
		OS.delay_msec(500)
		scene = _result(_request("get_open_scene", {}, 10000))
		if str(scene.get("scene", "")) == SCENE_PATH:
			return true
	return false


func _wait_anchors(timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var r := _result(_request(
			"call_method", {"path": DEMO_NODE, "method": "has_volume_score_anchors"}, 15000))
		if bool(r.get("ok", false)) and str(r.get("return", "")) == "true":
			return true
		OS.delay_msec(500)
	return false


static func _brief(text: String, limit: int = 200) -> String:
	return text if text.length() <= limit else text.substr(0, limit) + "..."


func _result(resp: Dictionary) -> Dictionary:
	var r = resp.get("result")
	return r if r is Dictionary else {}


## 每请求一条新连接（与 tools/spa_click_test.py / golden_snapshot_check.js 的
## 桥客户端行为一致）；返回顶层响应字典，失败/超时返回 {}。
func _request(method: String, params: Dictionary, timeout_ms: int) -> Dictionary:
	_next_id += 1
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(HOST, PORT) != OK:
		return {}
	var deadline := Time.get_ticks_msec() + timeout_ms
	while true:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			break
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			return {}
		if Time.get_ticks_msec() > deadline:
			peer.disconnect_from_host()
			return {}
		OS.delay_msec(20)
	var line := JSON.stringify({"id": _next_id, "method": method, "params": params}) + "\n"
	if peer.put_data(line.to_utf8_buffer()) != OK:
		peer.disconnect_from_host()
		return {}
	var buf := PackedByteArray()
	while Time.get_ticks_msec() <= deadline:
		peer.poll()
		var avail := peer.get_available_bytes()
		if avail > 0:
			var chunk: Array = peer.get_partial_data(avail)
			if int(chunk[0]) == OK:
				buf.append_array(chunk[1])
			if buf.has(0x0A):
				break
		elif peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		else:
			OS.delay_msec(20)
	peer.disconnect_from_host()
	if buf.is_empty():
		return {}
	var text := buf.get_string_from_utf8()
	var nl := text.find("\n")
	var parsed = JSON.parse_string(text.substr(0, nl) if nl >= 0 else text)
	return parsed if parsed is Dictionary else {}
