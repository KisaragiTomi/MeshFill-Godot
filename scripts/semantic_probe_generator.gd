@tool
class_name SemanticProbeGenerator
extends Resource
# @tool: @tool demo（placement-score-3d 等）在编辑器内经 profile 容器 register_descriptor →
# normalize_descriptor → get_profile_samples →（descriptor 内）get_semantic_probes 调 get_probes()。
# 无 @tool 时编辑器给 placeholder
# 实例，方法调用报 "Attempt to call a method on a placeholder instance"（见 CLAUDE.md
# 「Editor gotcha — descriptor methods need @tool」）。运行时行为不变。

const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")

const PROBE_LAYER_COUNT := 5
const PROBE_WORLD_MIN_DISTANCE := 0.35

# --- Size-driven probe budget -------------------------------------------------
# Probe count scales with object size: an object whose largest AABB axis is
# PROBE_UNIT_MAX_AXIS metres collapses to a single probe (grass scale — a grass
# tuft is semantically uniform, so one sample suffices). Larger meshes grow by a
# sub-linear power (PROBE_SIZE_GROWTH < 1) so cliffs get proportionally more
# probes without exploding. Reference counts @ density 1.0:
#     max-axis  1.7 m (grass)  ->  1 probe
#     max-axis 20.3 m (leaf)   ->  9 probes
#     max-axis 61   m (cliff)  -> 25 probes
# Density multiplies the result linearly. Raise PROBE_SIZE_GROWTH toward 1.0 for
# strictly size-proportional counts; lower PROBE_UNIT_MAX_AXIS to give small
# props more probes.
const PROBE_UNIT_MAX_AXIS := 1.7   # object max-axis (m) that maps to a single probe
const PROBE_SIZE_GROWTH := 0.9     # <1 sub-linear; 1.0 = strictly proportional to size

@export var probes: Array[Dictionary] = []                 # descriptor-backed semantic probe records
@export_range(0.1, 8.0, 0.1) var density: float = 1.0       # automatic probe generation density
@export var max_probe_count: int = 128                      # cap for generated probes


func rebuild_from_mesh(
	mesh: Mesh,
	collision: Array = [],
	fallback_color: Color = Color.WHITE,
	fallback_complexity: float = 1.0,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	context_sensing_radius: float = 0.0
) -> Array[Dictionary]:
	var d := density if density_override <= 0.0 else density_override
	density = clampf(d, 0.1, 8.0)
	probes = generate_from_mesh(mesh, collision, fallback_color, fallback_complexity, density, max_probe_count, world_scale, context_sensing_radius)
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
	collision: Array = [],
	fallback_color: Color = Color.WHITE,
	fallback_complexity: float = 1.0,
	density_value: float = 1.0,
	max_count: int = 128,
	world_scale: Vector3 = Vector3.ONE,
	context_sensing_radius: float = 0.0
) -> Array[Dictionary]:
	if mesh == null:
		push_error("[SemanticProbeGenerator] generate_from_mesh(): mesh 为 null —— 原行为在原点顶一个 \"fallback\" 探针，那是假数据；改为不产出任何探针")
		assert(false, "SemanticProbeGenerator.generate_from_mesh: null mesh")
		return ([] as Array[Dictionary])

	var aabb := mesh.get_aabb()
	if aabb.size.length_squared() < 0.0001:
		push_error("[SemanticProbeGenerator] generate_from_mesh(): mesh AABB 退化（size=%s，surface_count=%d）—— 无法采样探针" % [
			str(aabb.size), mesh.get_surface_count()])
		assert(false, "SemanticProbeGenerator.generate_from_mesh: degenerate mesh AABB")
		return ([] as Array[Dictionary])

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

	# Priority 2: per-voxel interior samples from the generic voxel field
	if not collision.is_empty():
		candidates.append_array(_make_voxel_interior_candidates(collision, fallback, fallback.a))

	# Priority 3: Poisson disk surface sampling
	if not triangles.is_empty():
		candidates.append_array(_make_poisson_surface_candidates(triangles, fallback, fallback.a, density_value))

	# Priority 4: Context sensing probes beyond mesh AABB
	if context_sensing_radius > 0.0:
		candidates.append_array(_make_context_sensing_candidates(aabb, context_sensing_radius, fallback, fallback.a, density_value))

	# Priority 5 (lowest): Exclusion zone — negative collision probes around AABB boundary
	candidates.append_array(_make_exclusion_zone_candidates(aabb, density_value))

	if candidates.is_empty():
		push_error("[SemanticProbeGenerator] generate_from_mesh(): 五级候选源全空（convex=%d, collision=%d, triangles=%d）—— 原行为在 AABB 中心顶一个 \"fallback\" 探针，那是假数据" % [
			convex_points.size(), collision.size(), triangles.size()])
		assert(false, "SemanticProbeGenerator.generate_from_mesh: no probe candidates")
		return ([] as Array[Dictionary])

	_apply_candidate_world_offsets(candidates, world_scale)
	var selected := select_layered_topk(candidates, target_count, max_count, density_value, PROBE_WORLD_MIN_DISTANCE)
	if selected.is_empty():
		push_error("[SemanticProbeGenerator] generate_from_mesh(): %d 条候选经分层 top-k 后一条没选出来（target=%d, max=%d）—— 选点逻辑失效" % [
			candidates.size(), target_count, max_count])
		assert(false, "SemanticProbeGenerator.generate_from_mesh: layered top-k selected nothing")
		return ([] as Array[Dictionary])
	return selected


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
	# Number of probes tracks object size: a grass-scale mesh (~PROBE_UNIT_MAX_AXIS)
	# rounds to a single probe; larger meshes grow sub-linearly. Floor of 1 so every
	# asset keeps at least one scorable probe.
	var size_units := maxf(max_axis, 0.001) / PROBE_UNIT_MAX_AXIS
	var target := roundi(pow(size_units, PROBE_SIZE_GROWTH) * d)
	return clampi(target, 1, max_count)


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
		result.append(make_probe_candidate(
			pos, color, 0.0, 1.0, 1.0, 1.0, "mesh", 1.6, "convex"
		))
	return result


# --- Priority 2: per-voxel interior samples ---
#
# `collision` is a flat list of per-voxel samples taken from the generic GPU
# voxel field. Each entry carries its own local position plus the same-level
# per-voxel channels color / complexity / collision, so the interior probe
# layer sources collision and complexity at the same level. There is no longer
# any cylinder / box shape rasterization here.

static func _make_voxel_interior_candidates(
	collision: Array,
	fallback_color: Color,
	fallback_complexity: float
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if collision.is_empty():
		return result

	var min_y := INF
	for raw_voxel in collision:
		if raw_voxel is Dictionary:
			var pos := VariantUtils.vector3_from_value(ProfileRecordSchemaScript.local_position_value(raw_voxel as Dictionary, Vector3.ZERO), Vector3.ZERO)
			min_y = minf(min_y, pos.y)

	for raw_voxel in collision:
		if not raw_voxel is Dictionary:
			continue
		var voxel_entry := raw_voxel as Dictionary
		if not bool(voxel_entry.get("enabled", true)):
			continue
		var point := VariantUtils.vector3_from_value(ProfileRecordSchemaScript.local_position_value(voxel_entry, Vector3.ZERO), Vector3.ZERO)
		var color := VariantUtils.color_from_value(voxel_entry.get("color", fallback_color), fallback_color) if voxel_entry.has("color") else fallback_color
		var complexity := clampf(float(voxel_entry.get("complexity", fallback_complexity)), 0.0, 1.0)
		color.a = complexity
		var collision_strength := ProfileRecordSchemaScript.collision_strength(voxel_entry)
		var is_support := absf(point.y - min_y) < 0.01
		var wc := 1.0
		var wcx := 1.0
		var wcl := 1.0
		if is_support:
			wc = 0.05
			wcx = 0.05
		var importance := lerpf(1.1, 1.4, collision_strength)
		result.append(make_probe_candidate(
			point, color, collision_strength, wc, wcx, wcl, "mesh", importance, "voxel_interior"
		))
	return result


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
				var importance := maxf(0.02, r_decay * y_decay * 0.35) * 0.5
				result.append(make_probe_candidate(
					pos, fallback_color, 0.0, 1.0, 1.0, 1.0, "context",
					importance, "context"
				))

	return result


# --- Priority 5: Exclusion zone probes (negative collision weight) ---
#
# Placed just outside the mesh AABB boundary. Penalizes placement when existing
# scene collision is already present nearby, preventing asset clustering.

static func _make_exclusion_zone_candidates(
	mesh_aabb: AABB,
	density_value: float
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var half := mesh_aabb.size * 0.5
	var center := mesh_aabb.get_center()
	var margin := maxf(maxf(half.x, half.z) * 0.15, 0.1)
	var y_base := mesh_aabb.position.y
	var y_top := y_base + mesh_aabb.size.y * 0.5
	var y_levels: PackedFloat32Array = [y_base, y_top]

	var ring_r := maxf(half.x, half.z) + margin
	var steps := clampi(ceili(density_value * 6.0), 4, 12)
	var empty_color := Color(0.0, 0.0, 0.0, 0.0)

	for y in y_levels:
		for i in range(steps):
			var angle := TAU * float(i) / float(steps)
			var pos := Vector3(
				center.x + cos(angle) * ring_r,
				y,
				center.z + sin(angle) * ring_r
			)
			result.append(make_probe_candidate(
				pos, empty_color, 1.0, 0.0, 0.0, -0.5, "exclusion",
				0.3, "exclusion"
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
		result.append(make_probe_candidate(
			pos, color, 0.0, 1.0, 1.0, 1.0, "mesh", 0.95, "surface"
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
		var offset := VariantUtils.vector3_from_value(candidate.get("offset", Vector3.ZERO), Vector3.ZERO)
		min_y = minf(min_y, offset.y)
		max_y = maxf(max_y, offset.y)
	var buckets: Array = []
	for i in range(PROBE_LAYER_COUNT):
		buckets.append([])
	for candidate in candidates:
		var offset := VariantUtils.vector3_from_value(candidate.get("offset", Vector3.ZERO), Vector3.ZERO)
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
	# Phase 2: collision sample interior
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
	var offset := VariantUtils.vector3_from_value(candidate.get("_world_offset", candidate.get("offset", Vector3.ZERO)), Vector3.ZERO)
	var nearest := INF
	for other in selected:
		var other_offset := VariantUtils.vector3_from_value(other.get("_world_offset", other.get("offset", Vector3.ZERO)), Vector3.ZERO)
		nearest = minf(nearest, offset.distance_to(other_offset))
	return nearest


static func candidate_too_close(candidate: Dictionary, selected: Array[Dictionary], min_distance: float) -> bool:
	if min_distance <= 0.0:
		return false
	var offset := VariantUtils.vector3_from_value(candidate.get("_world_offset", candidate.get("offset", Vector3.ZERO)), Vector3.ZERO)
	for other in selected:
		var other_offset := VariantUtils.vector3_from_value(other.get("_world_offset", other.get("offset", Vector3.ZERO)), Vector3.ZERO)
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
		var offset := VariantUtils.vector3_from_value(candidate.get("offset", Vector3.ZERO), Vector3.ZERO)
		candidate["_world_offset"] = Vector3(offset.x * scale_abs.x, offset.y * scale_abs.y, offset.z * scale_abs.z)


static func probe_candidate_key(candidate: Dictionary) -> String:
	var offset := VariantUtils.vector3_from_value(candidate.get("offset", Vector3.ZERO), Vector3.ZERO)
	return "%d,%d,%d" % [roundi(offset.x * 1000.0), roundi(offset.y * 1000.0), roundi(offset.z * 1000.0)]


static func make_probe_candidate(offset: Vector3, color: Color, collision: float, w_color: float, w_complexity: float, w_collision: float, source: String, importance: float, shape_source: String = "") -> Dictionary:
	var probe := make_probe(offset, color, collision, w_color, w_complexity, w_collision, source)
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
	var offset := VariantUtils.vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
	var color := VariantUtils.color_from_value(probe.get("expected_color", probe.get("color", Color.WHITE)), Color.WHITE)
	var complexity := clampf(float(probe.get("expected_complexity", probe.get("complexity", color.a))), 0.0, 1.0)
	color.a = complexity
	probe["offset"] = offset
	probe["expected_color"] = color
	probe["expected_complexity"] = complexity
	probe["expected_rgba8"] = int(probe.get("expected_rgba8", BufferUtils.pack_semantic_rgba8_word(color)))
	probe["expected_collision"] = ProfileRecordSchemaScript.probe_expected_collision(probe)
	probe["source"] = str(probe.get("source", "manual"))

	probe["w_color"] = float(probe.get("w_color", 1.0))
	probe["w_complexity"] = float(probe.get("w_complexity", 1.0))
	probe["w_collision"] = float(probe.get("w_collision", 1.0))
	return probe


static func make_probe(offset: Vector3, color: Color, collision: float, w_color: float, w_complexity: float, w_collision: float, source: String) -> Dictionary:
	var c := color
	c.a = clampf(c.a, 0.0, 1.0)
	return {
		"offset": offset,
		"expected_color": c,
		"expected_complexity": c.a,
		"expected_rgba8": BufferUtils.pack_semantic_rgba8_word(c),
		"expected_collision": clampf(collision, 0.0, 1.0),
		"w_color": w_color,
		"w_complexity": w_complexity,
		"w_collision": w_collision,
		"source": source,
	}


## 从探针字典取出度量权重，组成 Vector3(w_color, w_complexity, w_collision)，缺省均 1.0。
static func probe_metric_weights(p: Dictionary) -> Vector3:
	return Vector3(
		float(p.get("w_color", 1.0)),
		float(p.get("w_complexity", 1.0)),
		float(p.get("w_collision", 1.0)),
	)


