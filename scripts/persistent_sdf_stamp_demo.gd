extends Node3D

const AutoObjectScript := preload("res://scripts/auto_object.gd")
const SdfStampScript := preload("res://scripts/autoobject_sdf_stamp.gd")

const GRID_SIZE := 64
const CELL_SIZE := 0.34
const SCREENSHOT_ARG := "--meshfill-persistent-sdf-screenshot"
const FIELD_ORIGIN := Vector3(0.0, 0.0, 0.0)
const RADIAL_STAMP_PATH := "res://assets/sdf/radial_soft_exclusion.tres"
const BOX_STAMP_PATH := "res://assets/sdf/box_soft_exclusion.tres"

var _field: Array[Array] = []
var _field_material: StandardMaterial3D
var _objects_root: Node3D
var _field_texture: ImageTexture
var _radial_stamp: Resource
var _box_stamp: Resource


func _ready() -> void:
	_build_camera()
	_build_lighting()
	_objects_root = Node3D.new()
	_objects_root.name = "AutoObjectsReferencingPersistentSdf"
	add_child(_objects_root)
	_ensure_persistent_stamps()
	_build_autoobjects()
	_build_total_sdf_from_autoobjects()
	_build_scene()
	_build_overlay()
	if OS.get_cmdline_args().has(SCREENSHOT_ARG):
		_save_screenshot_and_quit()


func _ensure_persistent_stamps() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/sdf"))
	_radial_stamp = load(RADIAL_STAMP_PATH) as Resource if FileAccess.file_exists(RADIAL_STAMP_PATH) else null
	if _radial_stamp == null:
		_radial_stamp = SdfStampScript.create_radial(
			"radial_soft_exclusion",
			Vector2i(41, 41),
			Vector2(5.2, 5.2),
			0.75,
			1.75,
			1.0
		)
		ResourceSaver.save(_radial_stamp, RADIAL_STAMP_PATH)

	_box_stamp = load(BOX_STAMP_PATH) as Resource if FileAccess.file_exists(BOX_STAMP_PATH) else null
	if _box_stamp == null:
		_box_stamp = SdfStampScript.create_box(
			"box_soft_exclusion",
			Vector2i(45, 35),
			Vector2(6.2, 4.6),
			Vector2(1.1, 0.55),
			1.45,
			0.92
		)
		ResourceSaver.save(_box_stamp, BOX_STAMP_PATH)


func _build_autoobjects() -> void:
	_make_autoobject("rock_a_refs_radial_sdf", _radial_stamp, Vector3(-4.3, 0.12, -3.8), 0.0, 1.0, Color(1.0, 0.74, 0.2))
	_make_autoobject("rock_b_refs_radial_sdf", _radial_stamp, Vector3(2.2, 0.12, -3.0), 0.0, 0.68, Color(0.92, 0.8, 0.4))
	_make_autoobject("fallen_log_refs_box_sdf", _box_stamp, Vector3(0.9, 0.12, 2.3), 32.0, 0.88, Color(0.75, 0.42, 0.18))
	_make_autoobject("small_block_refs_box_sdf", _box_stamp, Vector3(-4.8, 0.12, 2.9), -18.0, 0.52, Color(0.82, 0.5, 0.24))
	_make_autoobject("overlap_radial_refs_same_stamp", _radial_stamp, Vector3(-3.8, 0.12, 2.6), 0.0, 0.46, Color(0.56, 0.82, 1.0))


func _make_autoobject(
	object_id: String,
	stamp: Resource,
	pos: Vector3,
	yaw_degrees: float,
	opacity: float,
	color: Color
) -> AutoObject:
	var node := AutoObjectScript.new() as AutoObject
	node.name = object_id
	node.auto_id = object_id
	node.object_type = "test_obstacle"
	node.object_subtype = str(stamp.get("stamp_id"))
	node.position = pos
	node.rotation_degrees = Vector3(0.0, yaw_degrees, 0.0)
	node.set("sdf_stamp", stamp)
	node.set("sdf_opacity", opacity)
	node.mesh = _make_marker_mesh(stamp)
	node.material_override = _make_marker_material(color)
	node.set_meta("persistent_sdf_resource_path", stamp.resource_path)
	_objects_root.add_child(node)
	return node


func _build_total_sdf_from_autoobjects() -> void:
	_field = _new_float_grid(0.0)
	for node in _objects_root.get_children():
		var autoobject := node as AutoObject
		if autoobject != null:
			var stamp := autoobject.call("get_sdf_stamp") as Resource
			if stamp != null:
				_blit_stamp_max(autoobject, stamp)


func _blit_stamp_max(autoobject: AutoObject, stamp: Resource) -> void:
	var stamp_world_size: Vector2 = stamp.call("get_world_size")
	var max_extent := maxf(stamp_world_size.x, stamp_world_size.y) * 0.75
	var center_grid := _world_to_grid(autoobject.global_position)
	var radius_cells := int(ceil(max_extent / CELL_SIZE)) + 2
	var yaw := deg_to_rad(autoobject.rotation_degrees.y)
	var cos_y := cos(-yaw)
	var sin_y := sin(-yaw)
	var opacity: float = autoobject.call("get_sdf_opacity")

	for z in range(center_grid.y - radius_cells, center_grid.y + radius_cells + 1):
		for x in range(center_grid.x - radius_cells, center_grid.x + radius_cells + 1):
			if not _in_bounds(x, z):
				continue
			var world := _grid_to_world_xz(x, z)
			var delta := world - Vector2(autoobject.global_position.x, autoobject.global_position.z)
			var local := Vector2(delta.x * cos_y - delta.y * sin_y, delta.x * sin_y + delta.y * cos_y)
			var uv := Vector2(
				local.x / stamp_world_size.x + 0.5,
				local.y / stamp_world_size.y + 0.5
			)
			var sample: Vector2 = stamp.call("sample_uv", uv)
			var painted := sample.x * sample.y * opacity
			if painted <= 0.0:
				continue
			_field[z][x] = maxf(float(_field[z][x]), painted)


func _build_scene() -> void:
	var image := _field_to_image(_field)
	_field_texture = ImageTexture.create_from_image(image)
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(GRID_SIZE * CELL_SIZE, GRID_SIZE * CELL_SIZE)
	_field_material = StandardMaterial3D.new()
	_field_material.albedo_texture = _field_texture
	_field_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_field_material.roughness = 0.85
	_field_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var plane := MeshInstance3D.new()
	plane.name = "TotalSdfBuiltByPersistentStampMaxBlend"
	plane.mesh = mesh
	plane.material_override = _field_material
	plane.position = FIELD_ORIGIN
	add_child(plane)


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(24, 16)
	panel.custom_minimum_size = Vector2(1060, 86)
	layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var text := Label.new()
	text.text = "Persistent SDF stamp demo | AutoObject references .tres stamps | total field uses transparent-image style blit + max(dst, src * alpha)"
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	margin.add_child(text)


func _make_marker_mesh(stamp: Resource) -> Mesh:
	var mesh := BoxMesh.new()
	var size: Vector2 = stamp.call("get_world_size")
	mesh.size = Vector3(size.x * 0.26, 0.24, size.y * 0.26)
	return mesh


func _make_marker_material(color: Color) -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color * 0.35
	mat.emission_energy_multiplier = 0.35
	return mat


func _build_camera() -> void:
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 27.5
	camera.position = Vector3(0.0, 34.0, 0.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.far = 200.0
	camera.current = true
	add_child(camera)


func _build_lighting() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.075, 0.085, 0.095)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.63, 0.7)
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_ACES

	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)

	var sun := DirectionalLight3D.new()
	sun.name = "SunLight"
	sun.rotation_degrees = Vector3(-52.0, -35.0, 0.0)
	sun.light_color = Color(1.0, 0.94, 0.84)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	add_child(sun)


func _field_to_image(field: Array[Array]) -> Image:
	var img := Image.create(GRID_SIZE, GRID_SIZE, false, Image.FORMAT_RGBA8)
	for z in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			var v := clampf(float(field[z][x]), 0.0, 1.0)
			img.set_pixel(x, z, _heat_color(v))
	return img


func _heat_color(v: float) -> Color:
	if v <= 0.0:
		return Color(0.035, 0.04, 0.052, 1.0)
	var cold := Color(0.08, 0.2, 0.36, 1.0)
	var mid := Color(0.25, 0.9, 0.58, 1.0)
	var hot := Color(1.0, 0.22, 0.05, 1.0)
	if v < 0.5:
		return cold.lerp(mid, v / 0.5)
	return mid.lerp(hot, (v - 0.5) / 0.5)


func _new_float_grid(value: float) -> Array[Array]:
	var grid: Array[Array] = []
	for _z in range(GRID_SIZE):
		var row: Array[float] = []
		for _x in range(GRID_SIZE):
			row.append(value)
		grid.append(row)
	return grid


func _grid_to_world_xz(x: int, z: int) -> Vector2:
	var half := GRID_SIZE * CELL_SIZE * 0.5
	return Vector2(
		(float(x) + 0.5) * CELL_SIZE - half + FIELD_ORIGIN.x,
		(float(z) + 0.5) * CELL_SIZE - half + FIELD_ORIGIN.z
	)


func _world_to_grid(pos: Vector3) -> Vector2i:
	var half := GRID_SIZE * CELL_SIZE * 0.5
	return Vector2i(
		int(floor((pos.x - FIELD_ORIGIN.x + half) / CELL_SIZE)),
		int(floor((pos.z - FIELD_ORIGIN.z + half) / CELL_SIZE))
	)


func _in_bounds(x: int, z: int) -> bool:
	return x >= 0 and x < GRID_SIZE and z >= 0 and z < GRID_SIZE


func _save_screenshot_and_quit() -> void:
	await get_tree().create_timer(1.0).timeout
	RenderingServer.force_draw(true)
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var out_dir := "user://persistent_sdf_stamp_demo"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var path := out_dir + "/persistent_sdf_stamp_demo.png"
	img.save_png(path)
	print("[PersistentSDFDemo] Screenshot saved: %s" % ProjectSettings.globalize_path(path))
	get_tree().quit()
