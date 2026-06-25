@tool
extends RefCounted


static func setup_hud_label(
	owner: Node,
	layer_name: String = "HUD",
	label_name: String = "Info",
	position: Vector2 = Vector2(24, 24),
	font_size: int = 16
) -> Label:
	if owner == null:
		return null
	var hud := CanvasLayer.new()
	hud.name = layer_name
	owner.add_child(hud)
	var label := Label.new()
	label.name = label_name
	label.position = position
	label.add_theme_font_size_override("font_size", font_size)
	hud.add_child(label)
	return label


static func find_camera(
	owner: Node,
	camera_path: String = "DemoSetup/FlyCamera",
	camera_name: String = "FlyCamera",
	prefer_viewport: bool = true,
	search_parent: bool = true
) -> Camera3D:
	if owner == null:
		return null
	if prefer_viewport:
		var viewport := owner.get_viewport()
		if viewport != null:
			var viewport_camera := viewport.get_camera_3d()
			if viewport_camera != null:
				return viewport_camera
	if not camera_path.is_empty():
		var path_camera := owner.get_node_or_null(camera_path) as Camera3D
		if path_camera != null:
			return path_camera
	if camera_name.is_empty():
		return null
	if search_parent and owner.get_parent() != null:
		var parent_camera := owner.get_parent().find_child(camera_name, true, false) as Camera3D
		if parent_camera != null:
			return parent_camera
	return owner.find_child(camera_name, true, false) as Camera3D


static func find_any_camera(
	owner: Node,
	prefer_viewport: bool = true,
	search_parent: bool = true
) -> Camera3D:
	if owner == null:
		return null
	if prefer_viewport:
		var viewport := owner.get_viewport()
		if viewport != null:
			var viewport_camera := viewport.get_camera_3d()
			if viewport_camera != null:
				return viewport_camera
	if search_parent and owner.get_parent() != null:
		var parent_camera := _find_camera_recursive(owner.get_parent())
		if parent_camera != null:
			return parent_camera
	return _find_camera_recursive(owner)


static func _find_camera_recursive(root_node: Node) -> Camera3D:
	if root_node == null:
		return null
	if root_node is Camera3D:
		return root_node as Camera3D
	for child in root_node.get_children():
		var found := _find_camera_recursive(child)
		if found != null:
			return found
	return null
