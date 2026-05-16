class_name SemanticProbeProfile
extends Resource

const FLAG_COLOR := 1
const FLAG_COMPLEXITY := 2
const FLAG_COLLISION := 4
const FLAG_EMPTY := 8
const FLAG_SUPPORT := 16
const PROBE_LAYER_COUNT := 5
const PROBE_WORLD_MIN_DISTANCE := 0.35

@export var probes: Array[Dictionary] = []
@export_range(0.1, 8.0, 0.1) var density: float = 1.0
@export var max_probe_count: int = 128


func rebuild_from_mesh(
	mesh: Mesh,
	collision_voxels: Array = [],
	fallback_color: Color = Color.WHITE,
	fallback_complexity: float = 1.0,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	context_sensing_radius: float = 0.0
) -> Array[Dictionary]:
	var d := density if density_override <= 0.0 else density_override
	density = clampf(d, 0.1, 8.0)
	probes = generate_from_mesh(mesh, collision_voxels, fallback_color, fallback_complexity, density, max_probe_count, world_scale, context_sensing_radius)
	return duplicate_probe_array(probes)


func get_probes() -> Array[Dictionary]:
	return duplicate_probe_array(probes)


static func duplicate_probe_array(source: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_probe in source:
		if raw_probe is Dictionary:
			result.append(normalize_probe(raw_probe as Dictionary))
	return result


static func generate_from_mesh(
	mesh: Mesh,
	collision_voxels: Array = [],
	fallback_color: Color = Color.WHITE,
	fallback_complexity: float = 1.0,
	density_value: float = 1.0,
	max_count: int = 128,
	world_scale: Vector3 = Vector3.ONE,
	context_sensing_radius: float = 0.0
) -> Array[Dictionary]:
	if mesh == null:
		return [make_probe(Vector3.ZERO, fallback_color, 0.0, 1.0, FLAG_COLOR | FLAG_COMPLEXITY, "positive", "fallback")]

	var aabb := mesh.get_aabb()
	if aabb.size.length_squared() < 0.0001:
		return [make_probe(Vector3.ZERO, fallback_color, 0.0, 1.0, FLAG_COLOR | FLAG_COMPLEXITY, "positive", "fallback")]

	var fallback := fallback_color
	fallback.a = clampf(fallback_complexity, 0.0, 1.0)
	var target_count := mesh_probe_target_count(mesh, density_value, max_count)
	if context_sensing_radius > 0.0:
		var context_extra := clampi(ceili(context_sensing_radius * density_value * 4.0), 4, 32)
		target_count = clampi(target_count + context_extra, target_count, max_count)
	var triangles := collect_mesh_triangles(mesh)
	var convex_points := collect_mesh_convex_points(mesh)

	var candidates: Array[Dictionary] = []

	# Priority 1 (highest): Convex hull surface points
	if not convex_points.is_empty():
		candidates.append_array(_make_convex_candidates(convex_points, fallback, fallback.a))

	# Priority 2: AutoObject collision voxel interior
	if not collision_voxels.is_empty():
		candidates.append_array(_make_voxel_interior_candidates(collision_voxels, fallback, fallback.a, density_value, world_scale))

	# Priority 3: Poisson disk surface sampling
	if not triangles.is_empty():
		candidates.append_array(_make_poisson_surface_candidates(triangles, fallback, fallback.a, density_value))

	# Priority 4 (lowest): Context sensing probes beyond mesh AABB
	if context_sensing_radius > 0.0:
		candidates.append_array(_make_context_sensing_candidates(aabb, context_sensing_radius, fallback, fallback.a, density_value))

	if candidates.is_empty():
		return [make_probe(aabb.get_center(), fallback, 0.0, 1.0, FLAG_COLOR | FLAG_COMPLEXITY, "positive", "fallback")]

	_apply_candidate_world_offsets(candidates, world_scale)
	var selected := select_layered_topk(candidates, target_count, max_count, density_value, PROBE_WORLD_MIN_DISTANCE)
	if selected.is_empty():
		return [make_probe(aabb.get_center(), fallback, 0.0, 1.0, FLAG_COLOR | FLAG_COMPLEXITY, "positive", "fallback")]
	return selected


static func collect_mesh_vertices(mesh: Mesh) -> PackedVector3Array:
	var result := PackedVector3Array()
	if mesh == null:
		return result
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		result.append_array(vertices)
	return result


static func collect_mesh_convex_points(mesh: Mesh) -> PackedVector3Array:
	var result := PackedVector3Array()
	if mesh == null:
		return result
	var shape := mesh.create_convex_shape(true, false)
	if shape == null:
		return result
	var raw_points = shape.get_points()
	for raw_point in raw_points:
		if raw_point is Vector3:
			result.append(raw_point)
	return result


static func mesh_probe_target_count(mesh: Mesh, density_value: float, max_count: int) -> int:
	var aabb := mesh.get_aabb()
	var max_axis := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	var d := clampf(density_value, 0.1, 8.0)
	var target := ceili((6.0 + sqrt(maxf(max_axis, 0.1)) * 2.5) * d)
	return clampi(target, 4, max_count)


static func collect_mesh_triangles(mesh: Mesh) -> Array[PackedVector3Array]:
	var result: Array[PackedVector3Array] = []
	if mesh == null:
		return result
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for i in range(0, verts.size() - 2, 3):
				var tri := PackedVector3Array()
				tri.append(verts[i])
				tri.append(verts[i + 1])
				tri.append(verts[i + 2])
				result.append(tri)
		else:
			for i in range(0, indices.size() - 2, 3):
				var tri := PackedVector3Array()
				tri.append(verts[indices[i]])
				tri.append(verts[indices[i + 1]])
				tri.append(verts[indices[i + 2]])
				result.append(tri)
	return result


# --- Priority 1: Convex hull surface candidates ---

static func _make_convex_candidates(
	convex_points: PackedVector3Array,
	fallback_color: Color,
	fallback_complexity: float
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if convex_points.is_empty():
		return result
	var hull_stride := maxi(1, int(convex_points.size() / 384))
	for point_index in range(0, convex_points.size(), hull_stride):
		var pos := convex_points[point_index]
		var color := fallback_color
		var complexity := clampf(fallback_complexity, 0.0, 1.0)
		color.a = complexity
		var weight := maxf(0.05, complexity)
		result.append(make_probe_candidate(
			pos, color, 0.0, weight, FLAG_COLOR | FLAG_COMPLEXITY,
			"positive", "mesh", weight * 1.6, "convex"
		))
	return result


# --- Priority 2: AutoObject collision voxel interior ---

static func _make_voxel_interior_candidates(
	collision_voxels: Array,
	fallback_color: Color,
	fallback_complexity: float,
	density_value: float,
	world_scale: Vector3
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if collision_voxels.is_empty():
		return result

	var world_spacing := maxf(PROBE_WORLD_MIN_DISTANCE / sqrt(maxf(density_value, 0.1)), 0.08)
	var local_sample_spacing := maxf(world_spacing / _world_scale_max_axis(world_scale), 0.02)
	for raw_collision in collision_voxels:
		if not raw_collision is Dictionary:
			continue
		var collision := raw_collision as Dictionary
		if not bool(collision.get("enabled", true)):
			continue
		var positions := _sample_collision_voxel_points(collision, local_sample_spacing)
		if positions.is_empty():
			continue
		var collision_value := clampf(float(collision.get("value", 1.0)), 0.0, 1.0)
		for point in positions:
			var color := fallback_color
			var complexity := clampf(fallback_complexity, 0.0, 1.0)
			color.a = complexity
			var weight := maxf(0.05, complexity)
			var importance := weight * lerpf(1.1, 1.4, collision_value)
			result.append(make_probe_candidate(
				point, color, collision_value, weight, FLAG_COLOR | FLAG_COMPLEXITY | FLAG_COLLISION,
				"positive", "mesh", importance, "voxel_interior"
			))
	return result


static func _sample_collision_voxel_points(collision: Dictionary, sample_spacing: float) -> PackedVector3Array:
	if collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset"):
		var point := vector3_from_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3.ZERO))), Vector3.ZERO)
		return PackedVector3Array([point])
	var shape := str(collision.get("shape", collision.get("collision_shape", "cylinder"))).to_lower()
	if shape == "box" or shape == "cube":
		return _sample_box_collision_points(collision, sample_spacing)
	return _sample_cylinder_collision_points(collision, sample_spacing)


static func _sample_cylinder_collision_points(collision: Dictionary, sample_spacing: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	var radius := _collision_effective_radius(collision)
	if radius <= 0.0001:
		return result
	var center := _collision_center(collision)
	var y_min := float(collision.get("y_min", 0.0))
	var y_max := float(collision.get("y_max", 2.0))
	if y_max < y_min:
		var swap := y_min
		y_min = y_max
		y_max = swap
	var height := maxf(y_max - y_min, 0.0)
	var y_steps := clampi(ceili(maxf(height, sample_spacing) / sample_spacing), 1, 8)
	var r_steps := clampi(ceili(radius / sample_spacing), 1, 6)
	for yi in range(y_steps + 1):
		var y_t := float(yi) / float(y_steps)
		var y := lerpf(y_min, y_max, y_t)
		for xi in range(-r_steps, r_steps + 1):
			for zi in range(-r_steps, r_steps + 1):
				var x := float(xi) / float(r_steps) * radius
				var z := float(zi) / float(r_steps) * radius
				if Vector2(x, z).length() > radius + 0.0001:
					continue
				result.append(Vector3(center.x + x, y + center.y, center.z + z))
	return result


static func _sample_box_collision_points(collision: Dictionary, sample_spacing: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	var center := _collision_center(collision)
	var half_extents := vector3_from_value(collision.get("half_extents", Vector3.ZERO), Vector3.ZERO)
	if half_extents.length_squared() <= 0.0001:
		var size := vector3_from_value(collision.get("size", Vector3.ZERO), Vector3.ZERO)
		if size.length_squared() > 0.0001:
			half_extents = size * 0.5
	if half_extents.length_squared() <= 0.0001:
		var radius := _collision_effective_radius(collision)
		var y_min := float(collision.get("y_min", 0.0))
		var y_max := float(collision.get("y_max", 2.0))
		half_extents = Vector3(radius, maxf(y_max - y_min, sample_spacing) * 0.5, radius)
	var min_p := center - half_extents
	var max_p := center + half_extents
	if collision.has("y_min") or collision.has("y_max"):
		min_p.y = center.y + float(collision.get("y_min", min_p.y - center.y))
		max_p.y = center.y + float(collision.get("y_max", max_p.y - center.y))
	var x_steps := clampi(ceili(maxf(max_p.x - min_p.x, sample_spacing) / sample_spacing), 1, 6)
	var y_steps := clampi(ceili(maxf(max_p.y - min_p.y, sample_spacing) / sample_spacing), 1, 8)
	var z_steps := clampi(ceili(maxf(max_p.z - min_p.z, sample_spacing) / sample_spacing), 1, 6)
	for xi in range(x_steps + 1):
		var x := lerpf(min_p.x, max_p.x, float(xi) / float(x_steps))
		for yi in range(y_steps + 1):
			var y := lerpf(min_p.y, max_p.y, float(yi) / float(y_steps))
			for zi in range(z_steps + 1):
				var z := lerpf(min_p.z, max_p.z, float(zi) / float(z_steps))
				result.append(Vector3(x, y, z))
	return result


static func _collision_effective_radius(collision: Dictionary) -> float:
	var radius := maxf(float(collision.get("effective_radius", collision.get("radius", collision.get("collision_radius", 0.0)))), 0.0)
	var erosion := maxf(float(collision.get("erosion_radius", 0.0)), 0.0)
	var dilation := maxf(float(collision.get("dilation_radius", 0.0)), 0.0)
	if collision.has("effective_radius"):
		return radius
	if erosion > 0.0 and radius <= erosion:
		return 0.0
	return maxf(radius - erosion, 0.0) + dilation


static func _collision_center(collision: Dictionary) -> Vector3:
	var center := vector3_from_value(collision.get("offset", collision.get("center", collision.get("position", Vector3.ZERO))), Vector3.ZERO)
	if collision.has("x"):
		center.x = float(collision.get("x", center.x))
	if collision.has("y"):
		center.y = float(collision.get("y", center.y))
	if collision.has("z"):
		center.z = float(collision.get("z", center.z))
	return center


static func _world_scale_max_axis(world_scale: Vector3) -> float:
	return maxf(maxf(absf(world_scale.x), absf(world_scale.y)), maxf(absf(world_scale.z), 0.0001))


# --- Priority 4: Context sensing probes beyond mesh AABB ---

static func _make_context_sensing_candidates(
	mesh_aabb: AABB,
	sensing_radius: float,
	fallback_color: Color,
	fallback_complexity: float,
	density_value: float
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if sensing_radius <= 0.0:
		return result

	var center := mesh_aabb.get_center()
	var half_size := mesh_aabb.size * 0.5
	var inner_r := maxf(maxf(half_size.x, half_size.z), 0.05)
	var outer_r := inner_r + sensing_radius
	var y_base := mesh_aabb.position.y
	var y_top := mesh_aabb.position.y + mesh_aabb.size.y
	var y_mid := (y_base + y_top) * 0.5

	# Ring sample spacing based on density
	var spacing := maxf(PROBE_WORLD_MIN_DISTANCE / sqrt(maxf(density_value, 0.1)), 0.15)
	var ring_steps := clampi(ceili(TAU * outer_r / spacing), 6, 24)
	var radial_steps := clampi(ceili((outer_r - inner_r) / spacing), 1, 4)
	var y_levels: PackedFloat32Array = [y_base, y_mid]
	if y_top - y_base > spacing * 1.5:
		y_levels.append(y_top)

	for y in y_levels:
		var y_dist := absf(y - y_mid)
		var y_decay := 1.0 / (1.0 + y_dist * 0.5)
		for ri in range(1, radial_steps + 1):
			var r := lerpf(inner_r, outer_r, float(ri) / float(radial_steps))
			var r_decay := 1.0 / (1.0 + (r - inner_r) * 0.5)
			for ai in range(ring_steps):
				var angle := TAU * float(ai) / float(ring_steps)
				var x := center.x + cos(angle) * r
				var z := center.z + sin(angle) * r
				var pos := Vector3(x, y, z)
				var w := maxf(0.02, r_decay * y_decay * 0.35)
				result.append(make_probe_candidate(
					pos, fallback_color, 0.0, w,
					FLAG_COLLISION | FLAG_COLOR,
					"positive", "context",
					w * 0.5, "context"
				))

	return result


# --- Priority 3: Poisson disk surface sampling ---

static func _make_poisson_surface_candidates(
	triangles: Array[PackedVector3Array],
	fallback_color: Color,
	fallback_complexity: float,
	density_value: float
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if triangles.is_empty():
		return result

	var total_area := 0.0
	var areas := PackedFloat64Array()
	for tri in triangles:
		var area := (tri[1] - tri[0]).cross(tri[2] - tri[0]).length() * 0.5
		areas.append(area)
		total_area += area
	if total_area < 0.0001:
		return result

	var sample_count := clampi(ceili(total_area * density_value * 4.0), 8, 512)
	var min_dist := sqrt(total_area / maxf(float(sample_count), 1.0)) * 0.5
	var samples := PackedVector3Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 42

	for _attempt in range(sample_count * 4):
		if samples.size() >= sample_count:
			break
		var r := rng.randf() * total_area
		var accumulated := 0.0
		var tri_idx := 0
		for i in range(areas.size()):
			accumulated += areas[i]
			if accumulated >= r:
				tri_idx = i
				break
		var tri := triangles[tri_idx]
		var u := rng.randf()
		var v := rng.randf()
		if u + v > 1.0:
			u = 1.0 - u
			v = 1.0 - v
		var pos := tri[0] + (tri[1] - tri[0]) * u + (tri[2] - tri[0]) * v

		var too_close := false
		for existing in samples:
			if pos.distance_to(existing) < min_dist:
				too_close = true
				break
		if too_close:
			continue
		samples.append(pos)

	for pos in samples:
		var color := fallback_color
		var complexity := clampf(fallback_complexity, 0.0, 1.0)
		color.a = complexity
		var weight := maxf(0.05, complexity)
		result.append(make_probe_candidate(
			pos, color, 0.0, weight, FLAG_COLOR | FLAG_COMPLEXITY,
			"positive", "mesh", weight * 0.95, "surface"
		))
	return result


static func select_layered_topk(
	candidates: Array[Dictionary],
	target_count: int,
	max_count: int,
	density_value: float,
	default_radius: float
) -> Array[Dictionary]:
	if candidates.is_empty():
		return []
	var limit := clampi(target_count, 1, max_count)
	var min_y := INF
	var max_y := -INF
	for candidate in candidates:
		var offset := vector3_from_value(candidate.get("offset", Vector3.ZERO), Vector3.ZERO)
		min_y = minf(min_y, offset.y)
		max_y = maxf(max_y, offset.y)
	var buckets: Array = []
	for i in range(PROBE_LAYER_COUNT):
		buckets.append([])
	for candidate in candidates:
		var offset := vector3_from_value(candidate.get("offset", Vector3.ZERO), Vector3.ZERO)
		var layer_index := probe_layer_index(offset.y, min_y, max_y)
		candidate["_layer_index"] = layer_index
		var target_bucket := buckets[layer_index] as Array
		target_bucket.append(candidate)
	for raw_bucket in buckets:
		var bucket := raw_bucket as Array
		bucket.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_priority := probe_candidate_priority(a)
			var b_priority := probe_candidate_priority(b)
			if a_priority != b_priority:
				return a_priority > b_priority
			return float(a.get("_importance", 0.0)) > float(b.get("_importance", 0.0))
		)
	var min_distance := probe_min_distance(candidates, density_value, default_radius)
	# Phase 1: convex hull points (highest priority)
	var selected := select_with_min_distance(buckets, limit, min_distance, [], "convex")
	if selected.size() < limit:
		selected = select_with_min_distance(buckets, limit, min_distance * 0.5, selected, "convex")
	if selected.size() < limit:
		selected = select_with_min_distance(buckets, limit, 0.0, selected, "convex")
	# Phase 2: collision voxel interior
	if selected.size() < limit:
		selected = select_with_min_distance(buckets, limit, min_distance, selected, "voxel_interior")
	if selected.size() < limit:
		selected = select_with_min_distance(buckets, limit, min_distance * 0.5, selected, "voxel_interior")
	if selected.size() < limit:
		selected = select_with_min_distance(buckets, limit, 0.0, selected, "voxel_interior")
	# Phase 3: Poisson surface
	if selected.size() < limit:
		selected = select_with_min_distance(buckets, limit, min_distance, selected, "surface")
	if selected.size() < limit:
		selected = select_with_min_distance(buckets, limit, min_distance * 0.5, selected, "surface")
	# Phase 4 (lowest priority): Context sensing probes
	if selected.size() < limit:
		selected = select_with_min_distance(buckets, limit, min_distance, selected, "context")
	if selected.size() < limit:
		selected = select_with_min_distance(buckets, limit, min_distance * 0.5, selected, "context")
	# Final fallback: any remaining candidate
	if selected.size() < limit:
		selected = select_with_min_distance(buckets, limit, min_distance * 0.5, selected)
	var result: Array[Dictionary] = []
	for candidate in selected:
		result.append(probe_from_candidate(candidate))
	return result


static func select_with_min_distance(buckets: Array, limit: int, min_distance: float, seed: Array, required_shape_source: String = "") -> Array[Dictionary]:
	var selected: Array[Dictionary] = []
	var selected_keys := {}
	for raw_candidate in seed:
		if not raw_candidate is Dictionary:
			continue
		var candidate := raw_candidate as Dictionary
		selected.append(candidate)
		selected_keys[probe_candidate_key(candidate)] = true
	var active_layers: Array[int] = []
	for i in range(buckets.size()):
		var bucket := buckets[i] as Array
		if bucket.is_empty():
			continue
		active_layers.append(i)
	if active_layers.is_empty():
		return selected
	while selected.size() < limit:
		var made_progress := false
		for layer_index in active_layers:
			var bucket := buckets[layer_index] as Array
			var picked := pick_next_candidate(bucket, selected, selected_keys, min_distance, required_shape_source)
			if picked.is_empty():
				continue
			selected.append(picked)
			selected_keys[probe_candidate_key(picked)] = true
			made_progress = true
			if selected.size() >= limit:
				break
		if not made_progress:
			break
	return selected


static func pick_next_candidate(bucket: Array, selected: Array[Dictionary], selected_keys: Dictionary, min_distance: float, required_shape_source: String = "") -> Dictionary:
	var best: Dictionary = {}
	var best_score := -1.0
	for raw_candidate in bucket:
		if not raw_candidate is Dictionary:
			continue
		var candidate := raw_candidate as Dictionary
		if not required_shape_source.is_empty() and str(candidate.get("shape_source", "")) != required_shape_source:
			continue
		var key := probe_candidate_key(candidate)
		if selected_keys.has(key):
			continue
		if candidate_too_close(candidate, selected, min_distance):
			continue
		var nearest_dist := candidate_nearest_distance(candidate, selected)
		var priority_boost := 1.0
		var shape_source := str(candidate.get("shape_source", ""))
		if shape_source == "convex":
			priority_boost = 2.0
		elif shape_source == "voxel_interior":
			priority_boost = 1.5
		var score := nearest_dist * priority_boost
		if score > best_score:
			best_score = score
			best = candidate
	return best


static func candidate_nearest_distance(candidate: Dictionary, selected: Array[Dictionary]) -> float:
	if selected.is_empty():
		return INF
	var offset := candidate_distance_offset(candidate)
	var nearest := INF
	for other in selected:
		var other_offset := candidate_distance_offset(other)
		nearest = minf(nearest, offset.distance_to(other_offset))
	return nearest


static func candidate_too_close(candidate: Dictionary, selected: Array[Dictionary], min_distance: float) -> bool:
	if min_distance <= 0.0:
		return false
	var offset := candidate_distance_offset(candidate)
	for other in selected:
		var other_offset := candidate_distance_offset(other)
		if offset.distance_to(other_offset) < min_distance:
			return true
	return false


static func probe_candidate_priority(candidate: Dictionary) -> int:
	var shape_source := str(candidate.get("shape_source", ""))
	if shape_source == "convex":
		return 3
	if shape_source == "voxel_interior":
		return 2
	if shape_source == "surface":
		return 1
	if shape_source == "context":
		return 0
	return 0


static func probe_layer_index(y: float, min_y: float, max_y: float) -> int:
	if max_y <= min_y + 0.0001:
		return int(PROBE_LAYER_COUNT / 2)
	var t := clampf((y - min_y) / (max_y - min_y), 0.0, 0.9999)
	return clampi(floori(t * float(PROBE_LAYER_COUNT)), 0, PROBE_LAYER_COUNT - 1)


static func probe_min_distance(_candidates: Array[Dictionary], density_value: float, default_radius: float) -> float:
	return clampf(default_radius / sqrt(maxf(density_value, 0.1)), 0.08, default_radius)


static func _apply_candidate_world_offsets(candidates: Array[Dictionary], world_scale: Vector3) -> void:
	var scale_abs := Vector3(maxf(absf(world_scale.x), 0.0001), maxf(absf(world_scale.y), 0.0001), maxf(absf(world_scale.z), 0.0001))
	for candidate in candidates:
		var offset := vector3_from_value(candidate.get("offset", Vector3.ZERO), Vector3.ZERO)
		candidate["_world_offset"] = Vector3(offset.x * scale_abs.x, offset.y * scale_abs.y, offset.z * scale_abs.z)


static func candidate_distance_offset(candidate: Dictionary) -> Vector3:
	return vector3_from_value(candidate.get("_world_offset", candidate.get("offset", Vector3.ZERO)), Vector3.ZERO)


static func probe_candidate_key(candidate: Dictionary) -> String:
	var offset := vector3_from_value(candidate.get("offset", Vector3.ZERO), Vector3.ZERO)
	return "%d,%d,%d" % [roundi(offset.x * 1000.0), roundi(offset.y * 1000.0), roundi(offset.z * 1000.0)]


static func make_probe_candidate(offset: Vector3, color: Color, collision: float, weight: float, flags: int, kind: String, source: String, importance: float, shape_source: String = "") -> Dictionary:
	var probe := make_probe(offset, color, collision, weight, flags, kind, source)
	probe["_importance"] = maxf(importance, 0.0)
	if not shape_source.is_empty():
		probe["shape_source"] = shape_source
	return probe


static func probe_from_candidate(candidate: Dictionary) -> Dictionary:
	var probe := normalize_probe(candidate)
	probe.erase("_importance")
	probe.erase("_layer_index")
	probe.erase("_world_offset")
	return probe


static func normalize_probe(raw_probe: Dictionary) -> Dictionary:
	var probe := raw_probe.duplicate(true)
	var offset := vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
	var color := color_from_value(probe.get("expected_color", probe.get("color", Color.WHITE)), Color.WHITE)
	var complexity := clampf(float(probe.get("expected_complexity", probe.get("complexity", color.a))), 0.0, 1.0)
	color.a = complexity
	probe["offset"] = offset
	probe["expected_color"] = color
	probe["expected_complexity"] = complexity
	probe["expected_rgba8"] = int(probe.get("expected_rgba8", pack_rgba8(color)))
	probe["expected_collision"] = clampf(float(probe.get("expected_collision", probe.get("collision", 0.0))), 0.0, 1.0)
	probe["weight"] = maxf(float(probe.get("weight", 1.0)), 0.0)
	probe["flags"] = int(probe.get("flags", FLAG_COLOR | FLAG_COMPLEXITY))
	probe["kind"] = str(probe.get("kind", "positive"))
	probe["source"] = str(probe.get("source", "manual"))
	return probe


static func make_probe(offset: Vector3, color: Color, collision: float, weight: float, flags: int, kind: String, source: String) -> Dictionary:
	var c := color
	c.a = clampf(c.a, 0.0, 1.0)
	return {
		"offset": offset,
		"expected_color": c,
		"expected_complexity": c.a,
		"expected_rgba8": pack_rgba8(c),
		"expected_collision": clampf(collision, 0.0, 1.0),
		"weight": maxf(weight, 0.0),
		"flags": flags,
		"kind": kind,
		"source": source,
	}


static func pack_rgba8(color: Color) -> int:
	var r := clampi(roundi(color.r * 255.0), 0, 255)
	var g := clampi(roundi(color.g * 255.0), 0, 255)
	var b := clampi(roundi(color.b * 255.0), 0, 255)
	var a := clampi(roundi(color.a * 255.0), 0, 255)
	return r | (g << 8) | (b << 16) | (a << 24)


static func color_from_value(value, fallback: Color = Color.WHITE) -> Color:
	if value is Color:
		return value as Color
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			var alpha := float(arr[3]) if arr.size() >= 4 else fallback.a
			return Color(float(arr[0]), float(arr[1]), float(arr[2]), alpha)
	if value is Dictionary:
		var dict := value as Dictionary
		return Color(
			float(dict.get("r", fallback.r)),
			float(dict.get("g", fallback.g)),
			float(dict.get("b", fallback.b)),
			float(dict.get("a", fallback.a))
		)
	if value is String:
		return Color.from_string(str(value), fallback)
	return fallback


static func vector3_from_value(value, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Vector3i:
		var vi := value as Vector3i
		return Vector3(float(vi.x), float(vi.y), float(vi.z))
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3(
			float(dict.get("x", fallback.x)),
			float(dict.get("y", fallback.y)),
			float(dict.get("z", fallback.z))
		)
	return fallback


