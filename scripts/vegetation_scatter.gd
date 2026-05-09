class_name VegetationScatter
extends RefCounted

const TREE_VISUAL_LAYER := 11
const BUSH_VISUAL_LAYER := 12
const MIDSTORY_VISUAL_LAYER := 13
const GRASS_VISUAL_LAYER := 14


static func create_tree_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.45, 0.30, 0.15)
	trunk_mat.roughness = 0.9

	var trunk_r := 0.15
	var trunk_h := 1.5
	var segments := 8
	_add_cylinder(st, Vector3.ZERO, trunk_r, trunk_h, segments)

	var crown_r := 0.8
	var crown_h := 2.0
	var crown_base := Vector3(0, trunk_h, 0)
	_add_cone(st, crown_base, crown_r, crown_h, segments)
	var crown_base2 := Vector3(0, trunk_h + crown_h * 0.4, 0)
	_add_cone(st, crown_base2, crown_r * 0.75, crown_h * 0.8, segments)

	st.generate_normals()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.50, 0.20)
	mat.roughness = 0.85
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh


static func create_midstory_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var trunk_r := 0.10
	var trunk_h := 1.0
	var segments := 8
	_add_cylinder(st, Vector3.ZERO, trunk_r, trunk_h, segments)

	var crown_r := 0.6
	var crown_h := 1.2
	var crown_base := Vector3(0, trunk_h, 0)
	_add_cone(st, crown_base, crown_r, crown_h, segments)

	st.generate_normals()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.45, 0.30)
	mat.roughness = 0.85
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh


static func create_bush_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var segments := 8
	_add_sphere(st, Vector3(0, 0.3, 0), 0.4, 0.35, segments)
	_add_sphere(st, Vector3(0.2, 0.25, 0.15), 0.3, 0.28, segments)
	_add_sphere(st, Vector3(-0.15, 0.2, -0.1), 0.35, 0.3, segments)

	st.generate_normals()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.55, 0.22)
	mat.roughness = 0.9
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh


static func create_flower_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var segments := 6
	_add_cylinder(st, Vector3.ZERO, 0.025, 0.35, segments)
	var bloom_center := Vector3(0.0, 0.38, 0.0)
	_add_sphere(st, bloom_center, 0.055, 0.045, segments)
	for i in range(6):
		_add_petal(st, bloom_center, float(i) / 6.0 * TAU, 0.18, 0.055)

	st.generate_normals()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.35, 0.5)
	mat.roughness = 0.75
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh


static func scatter_trees(
	nutrition_img: Image,
	rock_mask_img: Image,
	scene_depth_img: Image,
	max_height: float,
	capture_size: float,
	min_dist: float = 3.0,
	nutrition_threshold: float = 0.2,
	max_tree_height: float = 4.0,
	max_count: int = 500
) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var res := nutrition_img.get_width()
	var pixel_size := capture_size / float(res)
	var min_dist_px := min_dist / pixel_size
	var min_dist_sq := min_dist_px * min_dist_px

	var placed_positions: Array[Vector2] = []
	var candidates: Array[Dictionary] = []

	for y in range(res):
		for x in range(res):
			var px := Vector2i(x, y)
			var nut := nutrition_img.get_pixelv(px).r
			if nut < nutrition_threshold:
				continue
			if rock_mask_img != null and rock_mask_img.get_pixelv(px).r > 0.5:
				continue
			candidates.append({"x": x, "y": y, "nutrition": nut})

	candidates.shuffle()

	for cand in candidates:
		if results.size() >= max_count:
			break
		var cx: int = cand.x
		var cy: int = cand.y
		var pos2 := Vector2(float(cx), float(cy))

		var too_close := false
		for placed in placed_positions:
			if pos2.distance_squared_to(placed) < min_dist_sq:
				too_close = true
				break
		if too_close:
			continue

		placed_positions.append(pos2)

		var terrain_h := max_height - scene_depth_img.get_pixelv(Vector2i(cx, cy)).r
		var nut: float = cand.nutrition
		var tree_h := nut * max_tree_height
		var tree_scale := clampf(tree_h / 3.5, 0.3, 2.0)

		var half := capture_size / 2.0
		var world_pos := Vector3(
			float(cx) / float(res) * capture_size - half,
			terrain_h,
			float(cy) / float(res) * capture_size - half
		)

		var rotation_y := randf_range(0.0, 360.0)
		results.append({
			"position": world_pos,
			"rotation_mode": "Y",
			"rotation_degrees": Vector3(0.0, rotation_y, 0.0),
			"rotation_y": rotation_y,
			"scale": Vector3.ONE * tree_scale,
			"type": "tree",
			"nutrition": nut,
		})

	return results


static func scatter_bushes(
	nutrition_img: Image,
	rock_mask_img: Image,
	tree_mask_img: Image,
	scene_depth_img: Image,
	max_height: float,
	capture_size: float,
	min_dist: float = 1.5,
	nutrition_threshold: float = 0.15,
	max_count: int = 1000
) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var res := nutrition_img.get_width()
	var pixel_size := capture_size / float(res)
	var min_dist_px := min_dist / pixel_size
	var min_dist_sq := min_dist_px * min_dist_px

	var placed_positions: Array[Vector2] = []
	var candidates: Array[Dictionary] = []

	for y in range(res):
		for x in range(res):
			var px := Vector2i(x, y)
			var nut := nutrition_img.get_pixelv(px).r
			if nut < nutrition_threshold:
				continue
			if rock_mask_img != null and rock_mask_img.get_pixelv(px).r > 0.5:
				continue
			if tree_mask_img != null and tree_mask_img.get_pixelv(px).r > 0.5:
				continue
			candidates.append({"x": x, "y": y, "nutrition": nut})

	candidates.shuffle()

	for cand in candidates:
		if results.size() >= max_count:
			break
		var cx: int = cand.x
		var cy: int = cand.y
		var pos2 := Vector2(float(cx), float(cy))

		var too_close := false
		for placed in placed_positions:
			if pos2.distance_squared_to(placed) < min_dist_sq:
				too_close = true
				break
		if too_close:
			continue

		placed_positions.append(pos2)

		var terrain_h := max_height - scene_depth_img.get_pixelv(Vector2i(cx, cy)).r
		var nut: float = cand.nutrition
		var bush_scale := clampf(nut * 1.5, 0.3, 1.5)

		var half := capture_size / 2.0
		var world_pos := Vector3(
			float(cx) / float(res) * capture_size - half,
			terrain_h,
			float(cy) / float(res) * capture_size - half
		)

		var rotation_y := randf_range(0.0, 360.0)
		results.append({
			"position": world_pos,
			"rotation_mode": "Y",
			"rotation_degrees": Vector3(0.0, rotation_y, 0.0),
			"rotation_y": rotation_y,
			"scale": Vector3.ONE * bush_scale,
			"type": "bush",
			"nutrition": nut,
		})

	return results


static func generate_tree_mask(
	tree_results: Array[Dictionary],
	texture_size: int,
	capture_size: float,
	tree_radius_px: int = 3
) -> Image:
	var mask := Image.create(texture_size, texture_size, false, Image.FORMAT_RF)
	mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	var half := capture_size / 2.0

	for tree in tree_results:
		var pos: Vector3 = tree.position
		var px_x := int((pos.x + half) / capture_size * float(texture_size))
		var px_y := int((pos.z + half) / capture_size * float(texture_size))

		for dy in range(-tree_radius_px, tree_radius_px + 1):
			for dx in range(-tree_radius_px, tree_radius_px + 1):
				if dx * dx + dy * dy > tree_radius_px * tree_radius_px:
					continue
				var tx := clampi(px_x + dx, 0, texture_size - 1)
				var ty := clampi(px_y + dy, 0, texture_size - 1)
				mask.set_pixelv(Vector2i(tx, ty), Color(1.0, 0.0, 0.0, 0.0))

	return mask


static func generate_bush_mask(
	bush_results: Array[Dictionary],
	texture_size: int,
	capture_size: float,
	bush_radius_px: int = 2
) -> Image:
	var mask := Image.create(texture_size, texture_size, false, Image.FORMAT_RF)
	mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	var half := capture_size / 2.0

	for bush in bush_results:
		var pos: Vector3 = bush.position
		var px_x := int((pos.x + half) / capture_size * float(texture_size))
		var px_y := int((pos.z + half) / capture_size * float(texture_size))

		for dy in range(-bush_radius_px, bush_radius_px + 1):
			for dx in range(-bush_radius_px, bush_radius_px + 1):
				if dx * dx + dy * dy > bush_radius_px * bush_radius_px:
					continue
				var tx := clampi(px_x + dx, 0, texture_size - 1)
				var ty := clampi(px_y + dy, 0, texture_size - 1)
				mask.set_pixelv(Vector2i(tx, ty), Color(1.0, 0.0, 0.0, 0.0))

	return mask


static func _add_cylinder(st: SurfaceTool, base: Vector3, radius: float, height: float, segments: int) -> void:
	var top := base + Vector3(0, height, 0)
	for i in range(segments):
		var angle_a := float(i) / float(segments) * TAU
		var angle_b := float(i + 1) / float(segments) * TAU
		var ba := base + Vector3(cos(angle_a) * radius, 0, sin(angle_a) * radius)
		var bb := base + Vector3(cos(angle_b) * radius, 0, sin(angle_b) * radius)
		var ta := top + Vector3(cos(angle_a) * radius * 0.6, 0, sin(angle_a) * radius * 0.6)
		var tb := top + Vector3(cos(angle_b) * radius * 0.6, 0, sin(angle_b) * radius * 0.6)

		st.set_color(Color(0.45, 0.30, 0.15, 1.0))
		st.add_vertex(ba)
		st.add_vertex(bb)
		st.add_vertex(ta)
		st.add_vertex(ta)
		st.add_vertex(bb)
		st.add_vertex(tb)


static func _add_cone(st: SurfaceTool, base: Vector3, radius: float, height: float, segments: int) -> void:
	var tip := base + Vector3(0, height, 0)
	for i in range(segments):
		var angle_a := float(i) / float(segments) * TAU
		var angle_b := float(i + 1) / float(segments) * TAU
		var va := base + Vector3(cos(angle_a) * radius, 0, sin(angle_a) * radius)
		var vb := base + Vector3(cos(angle_b) * radius, 0, sin(angle_b) * radius)

		st.set_color(Color(0.25, 0.50, 0.20, 1.0))
		st.add_vertex(va)
		st.add_vertex(vb)
		st.add_vertex(tip)


static func _add_sphere(st: SurfaceTool, center: Vector3, radius_h: float, radius_v: float, segments: int) -> void:
	var rings := segments / 2
	for j in range(rings):
		var phi_a := float(j) / float(rings) * PI
		var phi_b := float(j + 1) / float(rings) * PI
		for i in range(segments):
			var theta_a := float(i) / float(segments) * TAU
			var theta_b := float(i + 1) / float(segments) * TAU

			var v00 := center + Vector3(
				sin(phi_a) * cos(theta_a) * radius_h,
				cos(phi_a) * radius_v,
				sin(phi_a) * sin(theta_a) * radius_h
			)
			var v10 := center + Vector3(
				sin(phi_b) * cos(theta_a) * radius_h,
				cos(phi_b) * radius_v,
				sin(phi_b) * sin(theta_a) * radius_h
			)
			var v01 := center + Vector3(
				sin(phi_a) * cos(theta_b) * radius_h,
				cos(phi_a) * radius_v,
				sin(phi_a) * sin(theta_b) * radius_h
			)
			var v11 := center + Vector3(
				sin(phi_b) * cos(theta_b) * radius_h,
				cos(phi_b) * radius_v,
				sin(phi_b) * sin(theta_b) * radius_h
			)

			st.set_color(Color(0.30, 0.55, 0.22, 1.0))
			st.add_vertex(v00)
			st.add_vertex(v10)
			st.add_vertex(v01)
			st.add_vertex(v01)
			st.add_vertex(v10)
			st.add_vertex(v11)


static func _add_petal(st: SurfaceTool, center: Vector3, angle: float, length: float, width: float) -> void:
	var dir := Vector3(cos(angle), 0.0, sin(angle))
	var side := Vector3(-sin(angle), 0.0, cos(angle))
	var base := center + dir * 0.035
	var tip := center + dir * length + Vector3(0.0, 0.025, 0.0)
	var left := base + side * width
	var right := base - side * width

	st.set_color(Color(0.9, 0.35, 0.5, 1.0))
	st.add_vertex(center)
	st.add_vertex(left)
	st.add_vertex(tip)
	st.add_vertex(center)
	st.add_vertex(tip)
	st.add_vertex(right)
