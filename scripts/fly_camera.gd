@tool
extends Camera3D

@export var move_speed: float = 50.0
@export var fast_move_speed: float = 150.0
@export var mouse_sensitivity: float = 0.003
@export var scroll_speed: float = 20.0

@export_group("Initial Framing")
@export var auto_frame_on_ready: bool = true
@export_range(0, 12, 1) var auto_frame_delay_frames: int = 2
@export_range(1.0, 2.0, 0.05) var auto_frame_padding: float = 1.05
@export var auto_frame_min_radius: float = 2.0
@export var auto_frame_max_distance: float = 4000.0
@export var auto_frame_view_direction: Vector3 = Vector3(0.0, 0.6, 1.0)
@export var auto_frame_root_path: NodePath = NodePath("")

const CAMERA_IGNORE_GROUP := "meshfill_camera_ignore"

var _yaw: float = 0.0
var _pitch: float = 0.0
var _captured: bool = false


func _ready() -> void:
	if not Engine.is_editor_hint():
		set_process(false)
		set_process_unhandled_input(false)
		return
	current = true
	_yaw = rotation.y
	_pitch = rotation.x
	if auto_frame_on_ready:
		_auto_frame_when_scene_ready.call_deferred()


func frame_visible_content() -> bool:
	var collected := _collect_visible_content_bounds()
	if not bool(collected.get("found", false)):
		return false
	var bounds: AABB = collected["bounds"]
	_frame_bounds(bounds)
	return true


func _auto_frame_when_scene_ready() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for _i in range(maxi(auto_frame_delay_frames, 0)):
		await tree.process_frame
		if not is_inside_tree():
			return
	frame_visible_content()


func _collect_visible_content_bounds() -> Dictionary:
	var root := _auto_frame_root()
	var result := {"found": false, "bounds": AABB()}
	if root != null:
		_accumulate_visible_bounds(root, result)
	return result


func _auto_frame_root() -> Node:
	if auto_frame_root_path != NodePath(""):
		var explicit_root := get_node_or_null(auto_frame_root_path)
		if explicit_root != null:
			return explicit_root
	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		return tree.current_scene
	# Walk up to the topmost scene root so sibling content (terrain, voxels)
	# is included in the framing bounds.
	var node: Node = self
	while node.get_parent() != null and node.get_parent() != tree.root:
		node = node.get_parent()
	if node != self:
		return node
	if owner != null:
		return owner
	return get_parent()


func _accumulate_visible_bounds(node: Node, result: Dictionary) -> void:
	if node == null or _is_ignored_for_framing(node):
		return
	if node is Node3D:
		var spatial := node as Node3D
		if not spatial.is_visible_in_tree():
			return
		var node_bounds := _node_world_bounds(spatial)
		if bool(node_bounds.get("found", false)):
			_merge_bounds(result, node_bounds["bounds"])
	for child in node.get_children():
		_accumulate_visible_bounds(child, result)


func _is_ignored_for_framing(node: Node) -> bool:
	if node == self:
		return true
	if node.is_in_group(CAMERA_IGNORE_GROUP):
		return true
	return node is Camera3D or node is Light3D or node is WorldEnvironment


func _node_world_bounds(node: Node3D) -> Dictionary:
	if node is Label3D:
		return _label3d_world_bounds(node as Label3D)
	if not node.has_method("get_aabb"):
		return {"found": false}
	var local = node.call("get_aabb")
	if not (local is AABB):
		return {"found": false}
	var local_bounds: AABB = local
	var largest_axis := maxf(absf(local_bounds.size.x), maxf(absf(local_bounds.size.y), absf(local_bounds.size.z)))
	if not (largest_axis > 0.0001):
		return {"found": false}
	return {"found": true, "bounds": _transform_aabb(node.global_transform, local_bounds)}


func _label3d_world_bounds(label: Label3D) -> Dictionary:
	var lines := label.text.split("\n")
	var max_line := 1
	for line in lines:
		max_line = maxi(max_line, String(line).length())
	var line_count := maxi(lines.size(), 1)
	var width := maxf(float(max_line) * float(label.font_size) * label.pixel_size * 0.55, auto_frame_min_radius * 0.25)
	var height := maxf(float(line_count) * float(label.font_size) * label.pixel_size * 1.2, auto_frame_min_radius * 0.25)
	var local := AABB(Vector3(-width * 0.5, -height * 0.5, -0.05), Vector3(width, height, 0.1))
	return {"found": true, "bounds": _transform_aabb(label.global_transform, local)}


func _merge_bounds(result: Dictionary, bounds: AABB) -> void:
	if not bool(result.get("found", false)):
		result["found"] = true
		result["bounds"] = bounds
		return
	var existing: AABB = result["bounds"]
	result["bounds"] = existing.merge(bounds)


func _transform_aabb(transform: Transform3D, local: AABB) -> AABB:
	var min_v := Vector3(INF, INF, INF)
	var max_v := Vector3(-INF, -INF, -INF)
	var xs := [local.position.x, local.position.x + local.size.x]
	var ys := [local.position.y, local.position.y + local.size.y]
	var zs := [local.position.z, local.position.z + local.size.z]
	for x in xs:
		for y in ys:
			for z in zs:
				var p := transform * Vector3(x, y, z)
				min_v = Vector3(minf(min_v.x, p.x), minf(min_v.y, p.y), minf(min_v.z, p.z))
				max_v = Vector3(maxf(max_v.x, p.x), maxf(max_v.y, p.y), maxf(max_v.z, p.z))
	if (max_v - min_v).length_squared() <= 0.000001:
		var pad := maxf(auto_frame_min_radius * 0.05, 0.1)
		min_v -= Vector3.ONE * pad
		max_v += Vector3.ONE * pad
	return AABB(min_v, max_v - min_v)


func _frame_bounds(bounds: AABB) -> void:
	var bounds_size := bounds.size
	var center := bounds.position + bounds_size * 0.5
	var radius := maxf(bounds_size.length() * 0.5, auto_frame_min_radius) * maxf(auto_frame_padding, 1.0)
	var view_back := auto_frame_view_direction
	if view_back.length_squared() <= 0.0001:
		view_back = Vector3(0.0, 0.42, 1.0)
	view_back = view_back.normalized()

	var viewport := get_viewport()
	var aspect := 16.0 / 9.0
	if viewport != null:
		var rect := viewport.get_visible_rect()
		aspect = maxf(rect.size.x, 1.0) / maxf(rect.size.y, 1.0)

	if projection == PROJECTION_ORTHOGONAL:
		size = maxf(bounds_size.y, bounds_size.x / aspect) * maxf(auto_frame_padding, 1.0)
		global_position = center + view_back * maxf(radius * 2.0, auto_frame_min_radius)
	else:
		var vertical_fov := deg_to_rad(fov)
		var horizontal_fov := 2.0 * atan(tan(vertical_fov * 0.5) * aspect)
		var fit_fov := maxf(minf(vertical_fov, horizontal_fov), 0.1)
		var distance := radius / maxf(sin(fit_fov * 0.5), 0.05)
		distance = clampf(distance, radius * 1.2, auto_frame_max_distance)
		global_position = center + view_back * distance
		far = maxf(far, distance + radius * 4.0 + 10.0)
	look_at(center, Vector3.UP)
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if not Engine.is_editor_hint():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_captured = true
			else:
				_release_mouse_capture()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if _captured:
				move_speed = clampf(move_speed * 1.2, 5.0, 600.0)
				fast_move_speed = move_speed * 3.0
			else:
				position += -transform.basis.z * scroll_speed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if _captured:
				move_speed = clampf(move_speed / 1.2, 5.0, 600.0)
				fast_move_speed = move_speed * 3.0
			else:
				position += transform.basis.z * scroll_speed

	if event is InputEventMouseMotion and _captured:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * mouse_sensitivity
		_pitch -= mm.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)
		rotation = Vector3(_pitch, _yaw, 0.0)

	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
			_release_mouse_capture()


func _release_mouse_capture() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_captured = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_EXIT_TREE:
		_release_mouse_capture()


func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	var speed := fast_move_speed if Input.is_key_pressed(KEY_SHIFT) else move_speed
	var direction := Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		direction -= transform.basis.z
	if Input.is_key_pressed(KEY_S):
		direction += transform.basis.z
	if Input.is_key_pressed(KEY_A):
		direction -= transform.basis.x
	if Input.is_key_pressed(KEY_D):
		direction += transform.basis.x
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE):
		direction += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		direction += Vector3.DOWN

	if direction.length_squared() > 0.001:
		position += direction.normalized() * speed * delta
