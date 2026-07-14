extends SceneTree

# SPA demo 截图门禁（编辑器桥客户端，真实断言版）。
#
# demo 场景被 core_demo_contract_fixture 强制为 editor-only（F5/F6/SceneTree
# 实例化直接 FATAL assert），所以本工具不在本地实例化任何 SPA 场景，而是驱动
# 运行中的编辑器（meshfill 插件 TCP 桥 127.0.0.1:6800）：
#   1. 确保 SPA demo 场景已在编辑器中打开（必要时 open_scene 并轮询）；
#   2. CoreSPADemo 必须真实应答 get_spa_selection_mode（有效模式 0..5）；
#   3. 编辑器 3D 视口截图必须成功、尺寸非零、落盘文件非空 —— 截图结果参与判定。
# 任一步失败 → exit 1（不再固定成功）。仅当以用户参数显式传入 --smoke
# （`godot ... --script res://tools/shot_spa_demo.gd -- --smoke`）时，
# 桥不可达 / 截图不可用才降级为 SKIP（exit 0）；场景与节点断言不受 smoke 豁免。
#
# 运行方式：headless 即可（工具自身不渲染，截图发生在编辑器进程内）：
#   godot --headless --path . --script res://tools/shot_spa_demo.gd
# 前置条件：一个已启动的编辑器（-e，vulkan）。旧版"三机位 FlyCamera 截图"依赖
# 本地实例化场景，且编辑器视口相机不受场景内 FlyCamera 控制，已随架构一并移除。

const HOST := "127.0.0.1"
const PORT := 6800
const SPA_SCENE := "res://demos/core-SPA-scene-placement-actor/core-scene-placement-actor.tscn"
const SPA_NODE := "CoreSPADemo"
const SHOT_PATH := "res://_shots/spa_demo_editor.png"
const VALID_MODES := ["0", "1", "2", "3", "4", "5"]

var _next_id := 0


func _initialize() -> void:
	var user_args := OS.get_cmdline_user_args()
	var smoke := user_args.has("--smoke") or user_args.has("smoke")
	var failures: Array[String] = []

	var ping := _result(_request("ping", {}, 5000))
	if str(ping.get("status", "")) != "ok":
		if smoke:
			print("[SHOT] SKIP (smoke): editor bridge unreachable at %s:%d" % [HOST, PORT])
			quit(0)
			return
		print("[SHOT] FAIL editor bridge unreachable at %s:%d (launch the editor: -e, vulkan)" % [HOST, PORT])
		quit(1)
		return

	if not _ensure_scene_open():
		print("[SHOT] FAIL SPA demo scene did not open in the editor: ", SPA_SCENE)
		quit(1)
		return
	print("[SHOT] SPA demo scene open: ", SPA_SCENE)

	# 真实断言 1: CoreSPADemo 在编辑器内跑起来并应答。
	var mode := _result(_request(
		"call_method", {"path": SPA_NODE, "method": "get_spa_selection_mode"}, 30000))
	var mode_return := str(mode.get("return", ""))
	if not bool(mode.get("ok", false)) or not VALID_MODES.has(mode_return):
		failures.append("CoreSPADemo get_spa_selection_mode invalid: %s" % _brief(str(mode)))
	else:
		print("[SHOT] CoreSPADemo alive, selection_mode=", mode_return)

	# 真实断言 2: 截图结果参与判定（不可用 → FAIL，除非 --smoke）。
	var shot := _result(_request("screenshot", {"path": SHOT_PATH}, 60000))
	var width := int(shot.get("width", 0))
	var height := int(shot.get("height", 0))
	var abs_path := str(shot.get("path", ""))
	var shot_ok := bool(shot.get("ok", false)) and width > 0 and height > 0
	if shot_ok:
		shot_ok = FileAccess.file_exists(abs_path) \
			and FileAccess.get_file_as_bytes(abs_path).size() > 0
	if shot_ok:
		print("[SHOT] saved ", abs_path, " (", width, "x", height, ")")
	elif smoke:
		print("[SHOT] SKIP (smoke): screenshot unavailable: ", _brief(str(shot)))
	else:
		failures.append("screenshot failed or empty: %s" % _brief(str(shot)))

	for f in failures:
		print("[SHOT] FAIL ", f)
	print("[SHOT] RESULT ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


func _ensure_scene_open() -> bool:
	var scene := _result(_request("get_open_scene", {}, 10000))
	if str(scene.get("scene", "")) == SPA_SCENE:
		return true
	_request("open_scene", {"path": SPA_SCENE}, 120000)
	for i in range(60):
		OS.delay_msec(500)
		scene = _result(_request("get_open_scene", {}, 10000))
		if str(scene.get("scene", "")) == SPA_SCENE:
			return true
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
