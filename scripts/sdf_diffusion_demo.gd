extends Node3D

const GRID_SIZE := 48
const CELL_SIZE := 0.42
const ITERATIONS := 26
const BUDGET_COST_PER_CELL := 1.0
const ENERGY_DECAY := 0.82
const SCREENSHOT_ARG := "--meshfill-sdf-screenshot"
const SOURCE_ORIGIN := Vector3(-12.0, 0.0, 0.0)
const TARGET_ORIGIN := Vector3(12.0, 0.0, 0.0)

var _source_field: Array[Array] = []
var _seed_energy_field: Array[Array] = []
var _seed_budget_field: Array[Array] = []
var _energy_field: Array[Array] = []
var _budget_field: Array[Array] = []
var _final_image: Image
var _final_texture: ImageTexture
var _preview_mesh: MeshInstance3D
var _preview_material: StandardMaterial3D
var _rings_root: Node3D
var _budget_multiplier := 1.0
var _budget_label: Label
var _source_material: StandardMaterial3D
var _seed_markers_root: Node3D
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_apply_cmdline_budget_multiplier()
	_build_camera()
	_build_lighting()
	_build_fields()
	_recompute_diffusion()
	_build_scene()
	_build_overlay()
	if OS.get_cmdline_args().has(SCREENSHOT_ARG):
		_save_screenshot_and_quit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var grid_pos := _mouse_to_source_grid(mb.position)
			if grid_pos.x >= 0:
				_add_random_collision(grid_pos)
				get_viewport().set_input_as_handled()


func _apply_cmdline_budget_multiplier() -> void:
	var args := OS.get_cmdline_args()
	for i in range(args.size()):
		if args[i] == "--sdf-budget-multiplier" and i + 1 < args.size():
			_budget_multiplier = clampf(float(args[i + 1]), 0.0, 2.0)
			return


func _build_fields() -> void:
	_source_field = _new_float_grid(0.0)
	_seed_energy_field = _new_float_grid(0.0)
	_seed_budget_field = _new_float_grid(0.0)

	var seeds := [
		{"pos": Vector2i(12, 14), "radius": 1, "energy": 1.0, "budget": 5.0},
		{"pos": Vector2i(32, 12), "radius": 2, "energy": 0.9, "budget": 10.0},
		{"pos": Vector2i(24, 31), "radius": 2, "energy": 0.95, "budget": 7.0},
		{"pos": Vector2i(38, 36), "radius": 1, "energy": 0.75, "budget": 0.0},
	]

	for seed in seeds:
		_stamp_seed(seed.pos, int(seed.radius), float(seed.energy), float(seed.budget))


func _stamp_seed(center: Vector2i, radius: int, energy: float, budget: float) -> void:
	for z in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			if not _in_bounds(x, z):
				continue
			var d := Vector2(float(x - center.x), float(z - center.y)).length()
			if d > float(radius):
				continue
			var falloff := 1.0 - d / maxf(float(radius), 0.001)
			var v := energy * (0.65 + 0.35 * falloff)
			_source_field[z][x] = maxf(float(_source_field[z][x]), v)
			_seed_energy_field[z][x] = maxf(float(_seed_energy_field[z][x]), v)
			_seed_budget_field[z][x] = maxf(float(_seed_budget_field[z][x]), budget)


func _recompute_diffusion() -> void:
	_energy_field = _copy_grid(_seed_energy_field)
	_budget_field = _copy_grid(_seed_budget_field)
	for z in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			_budget_field[z][x] = float(_budget_field[z][x]) * _budget_multiplier
	_diffuse()


func _diffuse() -> void:
	for _i in range(ITERATIONS):
		var next_energy := _copy_grid(_energy_field)
		var next_budget := _copy_grid(_budget_field)

		for z in range(GRID_SIZE):
			for x in range(GRID_SIZE):
				var budget := float(_budget_field[z][x])
				var energy := float(_energy_field[z][x])
				if budget < BUDGET_COST_PER_CELL or energy <= 0.01:
					continue
				for n in _neighbors4(x, z):
					var nb := budget - BUDGET_COST_PER_CELL
					if nb < 0.0:
						continue
					var stop_fade := 0.35 + 0.65 * clampf(nb / BUDGET_COST_PER_CELL, 0.0, 1.0)
					var ne := energy * ENERGY_DECAY * stop_fade
					var nx := int(n.x)
					var nz := int(n.y)
					if ne > float(next_energy[nz][nx]):
						next_energy[nz][nx] = ne
						next_budget[nz][nx] = nb

		_energy_field = next_energy
		_budget_field = next_budget


func _build_scene() -> void:
	_final_image = _field_to_image(_energy_field, true)
	_final_texture = ImageTexture.create_from_image(_final_image)
	_make_preview_plane("hard collision cores", _field_to_image(_source_field, false), SOURCE_ORIGIN)
	_preview_mesh = _make_preview_plane("soft exclusion field", _final_image, TARGET_ORIGIN)
	_seed_markers_root = Node3D.new()
	_seed_markers_root.name = "SeedMarkers"
	add_child(_seed_markers_root)
	_update_seed_markers()
	_rings_root = Node3D.new()
	_rings_root.name = "DiffusionRings"
	add_child(_rings_root)
	_update_diffusion_visuals()


func _make_preview_plane(label_text: String, image: Image, pos: Vector3) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(GRID_SIZE * CELL_SIZE, GRID_SIZE * CELL_SIZE)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(image)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var plane := MeshInstance3D.new()
	plane.name = label_text.capitalize().replace(" ", "")
	plane.mesh = mesh
	plane.material_override = mat
	plane.position = pos
	add_child(plane)
	if label_text == "soft exclusion field":
		_preview_material = mat
	elif label_text == "hard collision cores":
		_source_material = mat

	var label := Label3D.new()
	label.name = label_text.capitalize().replace(" ", "") + "Label"
	label.text = label_text
	label.font_size = 28
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = pos + Vector3(0.0, 0.15, -GRID_SIZE * CELL_SIZE * 0.58)
	add_child(label)
	return plane


func _make_seed_markers() -> void:
	if _seed_markers_root == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.35, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.08)
	mat.emission_energy_multiplier = 0.6

	for z in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			if float(_source_field[z][x]) < 0.65:
				continue
			if (x + z) % 3 != 0:
				continue
			var marker := MeshInstance3D.new()
			var sphere := SphereMesh.new()
			sphere.radius = 0.07 + float(_source_field[z][x]) * 0.04
			sphere.height = sphere.radius * 2.0
			marker.mesh = sphere
			marker.material_override = mat
			marker.position = _grid_to_world(x, z, SOURCE_ORIGIN + Vector3(0.0, 0.08, 0.0))
			_seed_markers_root.add_child(marker)


func _update_seed_markers() -> void:
	if _seed_markers_root == null:
		return
	for child in _seed_markers_root.get_children():
		child.queue_free()
	_make_seed_markers()


func _make_diffusion_rings() -> void:
	if _rings_root == null:
		return
	var thresholds := [0.72, 0.48, 0.28, 0.14]
	var colors := [
		Color(1.0, 0.2, 0.08, 1.0),
		Color(1.0, 0.7, 0.1, 1.0),
		Color(0.35, 0.95, 0.55, 1.0),
		Color(0.25, 0.75, 1.0, 1.0),
	]
	for i in range(thresholds.size()):
		var t := float(thresholds[i])
		var mat := StandardMaterial3D.new()
		mat.albedo_color = colors[i]
		mat.emission_enabled = true
		mat.emission = colors[i]
		mat.emission_energy_multiplier = 0.15
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.85
		for z in range(1, GRID_SIZE - 1):
			for x in range(1, GRID_SIZE - 1):
				var v := float(_energy_field[z][x])
				if absf(v - t) > 0.018:
					continue
				if (x + z + i) % 2 != 0:
					continue
				var cube := MeshInstance3D.new()
				var box := BoxMesh.new()
				box.size = Vector3(CELL_SIZE * 0.7, 0.045, CELL_SIZE * 0.7)
				cube.mesh = box
				cube.material_override = mat
				cube.position = _grid_to_world(x, z, TARGET_ORIGIN + Vector3(0.0, 0.08 + i * 0.025, 0.0))
				_rings_root.add_child(cube)


func _update_diffusion_visuals() -> void:
	_final_image = _field_to_image(_energy_field, true)
	_final_texture = ImageTexture.create_from_image(_final_image)
	if _preview_material != null:
		_preview_material.albedo_texture = _final_texture
	if _rings_root != null:
		for child in _rings_root.get_children():
			child.queue_free()
		_make_diffusion_rings()
	if _budget_label != null:
		_budget_label.text = "budget multiplier: %.2fx" % _budget_multiplier


func _update_source_visuals() -> void:
	if _source_material != null:
		_source_material.albedo_texture = ImageTexture.create_from_image(_field_to_image(_source_field, false))


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(24, 12)
	panel.custom_minimum_size = Vector2(1080, 92)
	layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var text := Label.new()
	text.text = "SDF diffusion demo | click left map to add collision | budget controls radius | iterations: %d   decay: %.2f   cell cost: %.1f" % [ITERATIONS, ENERGY_DECAY, BUDGET_COST_PER_CELL]
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var box := VBoxContainer.new()
	margin.add_child(box)
	box.add_child(text)

	_budget_label = Label.new()
	_budget_label.text = "budget multiplier: %.2fx" % _budget_multiplier
	box.add_child(_budget_label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 2.0
	slider.step = 0.05
	slider.value = _budget_multiplier
	slider.custom_minimum_size = Vector2(1050, 24)
	slider.value_changed.connect(_on_budget_multiplier_changed)
	box.add_child(slider)


func _on_budget_multiplier_changed(value: float) -> void:
	_budget_multiplier = float(value)
	_recompute_diffusion()
	_update_diffusion_visuals()


func _add_random_collision(grid_pos: Vector2i) -> void:
	var radius := _rng.randi_range(1, 4)
	var energy := _rng.randf_range(0.75, 1.0)
	var budget_options := [0.0, 2.0, 4.0, 7.0, 10.0, 13.0]
	var budget := float(budget_options[_rng.randi_range(0, budget_options.size() - 1)])
	_stamp_seed(grid_pos, radius, energy, budget)
	_recompute_diffusion()
	_update_source_visuals()
	_update_seed_markers()
	_update_diffusion_visuals()


func _mouse_to_source_grid(screen_pos: Vector2) -> Vector2i:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector2i(-1, -1)
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	if absf(ray_dir.y) < 0.0001:
		return Vector2i(-1, -1)
	var t := -ray_origin.y / ray_dir.y
	if t < 0.0:
		return Vector2i(-1, -1)
	var world_pos := ray_origin + ray_dir * t
	var local := world_pos - SOURCE_ORIGIN
	var half := GRID_SIZE * CELL_SIZE * 0.5
	if local.x < -half or local.x > half or local.z < -half or local.z > half:
		return Vector2i(-1, -1)
	var x := int(floor((local.x + half) / CELL_SIZE))
	var z := int(floor((local.z + half) / CELL_SIZE))
	return Vector2i(clampi(x, 0, GRID_SIZE - 1), clampi(z, 0, GRID_SIZE - 1))


func _build_camera() -> void:
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 31.5
	camera.position = Vector3(0.0, 36.0, 0.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.far = 200.0
	camera.current = true
	add_child(camera)


func _build_lighting() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.095, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.62, 0.7)
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.ssao_enabled = true

	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)

	var sun := DirectionalLight3D.new()
	sun.name = "SunLight"
	sun.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	sun.light_color = Color(1.0, 0.94, 0.82)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.rotation_degrees = Vector3(-35.0, 145.0, 0.0)
	fill.light_color = Color(0.55, 0.7, 1.0)
	fill.light_energy = 0.45
	add_child(fill)


func _field_to_image(field: Array[Array], show_falloff: bool) -> Image:
	var img := Image.create(GRID_SIZE, GRID_SIZE, false, Image.FORMAT_RGBA8)
	for z in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			var v := clampf(float(field[z][x]), 0.0, 1.0)
			var c := _heat_color(v) if show_falloff else Color(v, v * 0.75, 0.05, 1.0)
			img.set_pixel(x, z, c)
	return img


func _heat_color(v: float) -> Color:
	if v <= 0.0:
		return Color(0.04, 0.05, 0.065, 1.0)
	var cold := Color(0.08, 0.18, 0.32, 1.0)
	var mid := Color(0.2, 0.85, 0.55, 1.0)
	var hot := Color(1.0, 0.22, 0.05, 1.0)
	if v < 0.45:
		return cold.lerp(mid, v / 0.45)
	return mid.lerp(hot, (v - 0.45) / 0.55)


func _new_float_grid(value: float) -> Array[Array]:
	var grid: Array[Array] = []
	for _z in range(GRID_SIZE):
		var row: Array[float] = []
		for _x in range(GRID_SIZE):
			row.append(value)
		grid.append(row)
	return grid


func _copy_grid(src: Array[Array]) -> Array[Array]:
	var out: Array[Array] = []
	for z in range(GRID_SIZE):
		var row: Array[float] = []
		for x in range(GRID_SIZE):
			row.append(float(src[z][x]))
		out.append(row)
	return out


func _neighbors4(x: int, z: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if x > 0:
		out.append(Vector2i(x - 1, z))
	if x < GRID_SIZE - 1:
		out.append(Vector2i(x + 1, z))
	if z > 0:
		out.append(Vector2i(x, z - 1))
	if z < GRID_SIZE - 1:
		out.append(Vector2i(x, z + 1))
	return out


func _grid_to_world(x: int, z: int, origin: Vector3) -> Vector3:
	var half := GRID_SIZE * CELL_SIZE * 0.5
	return origin + Vector3((float(x) + 0.5) * CELL_SIZE - half, 0.0, (float(z) + 0.5) * CELL_SIZE - half)


func _in_bounds(x: int, z: int) -> bool:
	return x >= 0 and x < GRID_SIZE and z >= 0 and z < GRID_SIZE


func _save_screenshot_and_quit() -> void:
	await get_tree().create_timer(1.0).timeout
	RenderingServer.force_draw(true)
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var out_dir := "user://sdf_diffusion_demo"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var suffix := str(_budget_multiplier).replace(".", "_")
	var path := out_dir + "/sdf_diffusion_demo_%sx.png" % suffix
	img.save_png(path)
	print("[SDFDemo] Screenshot saved: %s" % ProjectSettings.globalize_path(path))
	get_tree().quit()
