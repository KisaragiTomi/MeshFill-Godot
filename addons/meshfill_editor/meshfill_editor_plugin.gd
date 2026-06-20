@tool
extends EditorPlugin

var _last_viewport_camera: Camera3D

# ---- Brush toolbar button ----
var _brush_btn: Button

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
	set_process(true)
	_cleanup_doc_import_files()
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_cleanup_doc_import_files)
	_connect_scene_signals()
	_validate_current_scene.call_deferred()
	_create_brush_toolbar_button()
	print("[MeshFill Editor] Activated — MCP bridge on 127.0.0.1:%d" % MCP_PORT)


func _exit_tree() -> void:
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
	_heartbeat_timer += delta
	if _heartbeat_timer >= HEARTBEAT_INTERVAL_SEC:
		_heartbeat_timer = 0.0
		_write_heartbeat()


# ---- Viewport input forwarding (existing) ---------------------------------

func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	_last_viewport_camera = viewport_camera
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return AFTER_GUI_INPUT_PASS
	if not scene_root.has_method("_editor_viewport_input"):
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouse:
		var handled: bool = scene_root._editor_viewport_input(viewport_camera, event)
		if handled:
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	if not scene_root.has_method("_editor_viewport_input"):
		return
	var handled: bool = scene_root._editor_viewport_input(_last_viewport_camera, event)
	if handled:
		get_viewport().set_input_as_handled()
		_sync_brush_btn_from_scene(scene_root)


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
	_update_brush_btn_style(true)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _brush_btn)


func _remove_brush_toolbar_button() -> void:
	if _brush_btn != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _brush_btn)
		_brush_btn.queue_free()
		_brush_btn = null


func _on_brush_btn_toggled(pressed: bool) -> void:
	_update_brush_btn_style(pressed)
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return
	if "brush_visible" in root:
		root.brush_visible = pressed
		if root.has_method("_apply_brush_visibility"):
			root._apply_brush_visibility()
		if root.has_method("_update_brush_toggle_btn"):
			root._update_brush_toggle_btn()
		if root.has_method("_build_labels"):
			root._build_labels()


func _sync_brush_btn_from_scene(root: Node) -> void:
	if _brush_btn == null or root == null:
		return
	if "brush_visible" in root:
		var state: bool = root.brush_visible
		if _brush_btn.button_pressed != state:
			_brush_btn.set_pressed_no_signal(state)
			_update_brush_btn_style(state)


func _update_brush_btn_style(active: bool) -> void:
	if _brush_btn == null:
		return
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
			peer.put_utf8_string(JSON.stringify({
				"status": "owned",
				"pid": OS.get_process_id(),
				"project": _project_key,
				"mcp_port": MCP_PORT
			}) + "\n")
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
			peer.put_utf8_string(JSON.stringify(resp) + "\n")
		else:
			peer.put_utf8_string(JSON.stringify({
				"id": null, "error": json.get_error_message()}) + "\n")
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


func _cmd_select_node(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	if path.is_empty():
		return {"error": "missing 'path'"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node: Node
	if path.begins_with("/"):
		node = root.get_tree().root.get_node_or_null(NodePath(path))
	else:
		node = root.get_node_or_null(NodePath(path))
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
	var node := root.get_node_or_null(NodePath(path))
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
	if path.is_empty() or prop.is_empty():
		return {"error": "missing 'path' or 'property'"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := root.get_node_or_null(NodePath(path))
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
	if path.is_empty() or pos.size() < 3:
		return {"error": "missing 'path' or 'position' [x,y,z]"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := root.get_node_or_null(NodePath(path))
	if node == null or not node is Node3D:
		return {"error": "node not found or not Node3D"}
	(node as Node3D).position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	return {"ok": true, "position": pos}


func _cmd_get_children(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node: Node
	if path.is_empty() or path == ".":
		node = root
	else:
		node = root.get_node_or_null(NodePath(path))
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
	if path.is_empty() or method_name.is_empty():
		return {"error": "missing 'path' or 'method'"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := root.get_node_or_null(NodePath(path))
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

const _JUNK_IMPORT_EXTENSIONS := [".svg.import", ".md.import"]
const _JUNK_IMPORT_DIRS := ["res://demos", "res://docs", "res://_shots"]

func _cleanup_doc_import_files() -> void:
	var removed := 0
	for scan_dir in _JUNK_IMPORT_DIRS:
		removed += _remove_junk_imports_in(scan_dir)
	if removed > 0:
		print("[MeshFill Editor] Removed %d junk .import files (.svg/.md/screenshots)" % removed)


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
	if pid > 0 and _is_pid_alive(pid):
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


func _is_pid_alive(pid: int) -> bool:
	if OS.get_name() == "Windows":
		var output: Array = []
		OS.execute("tasklist", PackedStringArray(["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"]), output)
		if output.is_empty():
			return false
		var result := str(output[0])
		return result.find(str(pid)) >= 0 and result.find("INFO:") < 0
	var exit_code := OS.execute("kill", PackedStringArray(["-0", str(pid)]))
	return exit_code == 0


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
