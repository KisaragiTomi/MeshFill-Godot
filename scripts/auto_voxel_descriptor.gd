class_name AutoVoxelDescriptor
extends Resource

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")

@export var color: Color = Color.WHITE
@export_range(0.0, 1.0) var complexity: float = 1.0
@export var affected_bands: Array[Dictionary] = []
@export var collision_voxels: Array[Dictionary] = []
@export var pivot_variants: Array[Dictionary] = []
@export var auto_generate_vertical_pivots: bool = false
@export_range(0.0, 16.0, 0.1) var vertical_pivot_middle_min_height: float = 1.5
@export_range(0.0, 16.0, 0.1) var vertical_pivot_upper_min_height: float = 3.0
@export var semantic_probe_profile: Resource
@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0


func get_color() -> Color:
	var result := color
	result.a = get_complexity()
	return result


func get_complexity() -> float:
	return clampf(complexity, 0.0, 1.0)


func set_color_and_complexity(next_color: Color, next_complexity: float) -> void:
	complexity = clampf(next_complexity, 0.0, 1.0)
	color = next_color
	color.a = complexity


func get_affected_bands(default_radius: float = 1.0) -> Array[Dictionary]:
	return AutoVoxelProfile.normalize_affected_bands(affected_bands, default_radius, get_color(), get_complexity())


func get_collision_voxels(default_radius: float = 0.0) -> Array[Dictionary]:
	return AutoVoxelProfile.normalize_collision_voxels(collision_voxels, default_radius)


func set_affected_bands(source: Array) -> void:
	affected_bands.clear()
	for raw in source:
		if raw is Dictionary:
			affected_bands.append((raw as Dictionary).duplicate(true))


func set_collision_voxels(source: Array) -> void:
	collision_voxels.clear()
	for raw in source:
		if raw is Dictionary:
			collision_voxels.append((raw as Dictionary).duplicate(true))


func set_pivot_variants(variants: Array) -> void:
	pivot_variants = normalize_pivot_variants(variants)


func get_pivot_variants() -> Array[Dictionary]:
	if not pivot_variants.is_empty():
		return normalize_pivot_variants(pivot_variants)
	if auto_generate_vertical_pivots:
		return make_vertical_pivot_variants_from_collision(collision_voxels, vertical_pivot_middle_min_height, vertical_pivot_upper_min_height)
	return [{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}]


func ensure_semantic_probe_profile() -> Resource:
	if semantic_probe_profile == null:
		semantic_probe_profile = SemanticProbeProfileScript.new()
		semantic_probe_profile.density = semantic_probe_density
	return semantic_probe_profile


func set_semantic_probes(probes: Array) -> void:
	var profile := ensure_semantic_probe_profile()
	profile.probes = SemanticProbeProfileScript.duplicate_probe_array(probes)


func get_semantic_probes(
	mesh: Mesh,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	fallback_bands: Array = [],
	fallback_collision_voxels: Array = []
) -> Array[Dictionary]:
	var profile := ensure_semantic_probe_profile()
	var d := semantic_probe_density if density_override <= 0.0 else density_override
	if not profile.probes.is_empty() and absf(float(profile.get("density")) - d) <= 0.001:
		return profile.get_probes()
	var bands := affected_bands if not affected_bands.is_empty() else fallback_bands
	var collisions := collision_voxels if not collision_voxels.is_empty() else fallback_collision_voxels
	return profile.rebuild_from_mesh(
		mesh,
		bands,
		collisions,
		get_color(),
		get_complexity(),
		d,
		world_scale
	)


func to_record_fields(default_radius: float = 0.0) -> Dictionary:
	var profile := ensure_semantic_probe_profile() if semantic_probe_profile != null else null
	var result := {
		"color": get_color(),
		"complexity": get_complexity(),
		"affected_bands": get_affected_bands(default_radius),
		"collision_voxels": get_collision_voxels(default_radius),
		"pivot_variants": get_pivot_variants(),
		"auto_generate_vertical_pivots": auto_generate_vertical_pivots,
		"semantic_probe_density": semantic_probe_density,
	}
	if profile != null:
		result["semantic_probes"] = profile.probes.duplicate(true)
	return result


static func from_profile(profile: AutoVoxelProfile, default_radius: float = 0.0) -> Resource:
	var descriptor = load("res://scripts/auto_voxel_descriptor.gd").new()
	if profile == null:
		return descriptor
	descriptor.color = profile.get_color()
	descriptor.complexity = profile.get_complexity()
	descriptor.affected_bands = profile.get_affected_bands(default_radius)
	descriptor.collision_voxels = profile.get_collision_voxels(default_radius)
	return descriptor


static func normalize_pivot_variants(raw_variants: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i in range(raw_variants.size()):
		var raw = raw_variants[i]
		if raw is Dictionary:
			var d := (raw as Dictionary).duplicate(true)
			d["name"] = str(d.get("name", "pivot_%d" % i))
			d["offset"] = vector3_from_value(d.get("offset", Vector3.ZERO), Vector3.ZERO)
			d["score_bias"] = float(d.get("score_bias", 0.0))
			result.append(d)
		elif raw is Vector3:
			result.append({"name": "pivot_%d" % i, "offset": raw as Vector3, "score_bias": 0.0})
	if result.is_empty():
		result.append({"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0})
	return result


static func make_vertical_pivot_variants_from_collision(collision_voxels: Array, middle_min_height: float = 1.5, upper_min_height: float = 3.0) -> Array[Dictionary]:
	var y_min := INF
	var y_max := -INF
	for raw_cv in collision_voxels:
		if not raw_cv is Dictionary:
			continue
		var cv := raw_cv as Dictionary
		var center := vector3_from_value(cv.get("offset", cv.get("center", cv.get("position", Vector3.ZERO))), Vector3.ZERO)
		var local_min := center.y + float(cv.get("y_min", 0.0))
		var local_max := center.y + float(cv.get("y_max", local_min + 0.01))
		y_min = minf(y_min, local_min)
		y_max = maxf(y_max, local_max)
	if y_min == INF or y_max <= y_min + 0.001:
		return [{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}]
	var h := y_max - y_min
	if h < middle_min_height:
		return [{"name": "bottom", "offset": Vector3(0.0, y_min, 0.0), "score_bias": 0.0}]
	var variants: Array[Dictionary] = [
		{"name": "bottom", "offset": Vector3(0.0, y_min, 0.0), "score_bias": 0.05},
		{"name": "middle", "offset": Vector3(0.0, y_min + h * 0.5, 0.0), "score_bias": 0.0},
	]
	if h >= upper_min_height:
		variants.append({"name": "upper", "offset": Vector3(0.0, y_min + h * 0.8, 0.0), "score_bias": -0.05})
	return variants


static func vector3_from_value(value, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value as Vector3
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
