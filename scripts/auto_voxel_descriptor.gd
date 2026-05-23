class_name AutoVoxelDescriptor
extends Resource

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")

@export var color: Color = Color.WHITE
@export_range(0.0, 1.0) var complexity: float = 1.0
@export var collision_voxels: Array[Dictionary] = []
@export var pivot_variants: Array[Dictionary] = []
@export var auto_generate_vertical_pivots: bool = false
@export_range(0.0, 16.0, 0.1) var vertical_pivot_middle_min_height: float = 1.5
@export_range(0.0, 16.0, 0.1) var vertical_pivot_upper_min_height: float = 3.0
@export var semantic_probe_profile: Resource
@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0
@export_range(0.0, 8.0, 0.1) var context_sensing_radius: float = 0.0
@export var asset_id: String = ""
@export var object_type: String = ""
@export var object_subtype: String = ""
@export_range(0, 3, 1) var vegetation_channel: int = 0
@export var vegetation_radius: float = 0.2
@export var voxel_profile: AutoVoxelProfile
@export var mesh: Mesh
@export var source_mesh: Mesh
@export var source_mesh_path: String = ""
@export var vegetation_script: Script
@export var mesh_create_method: String = ""
@export var scatter_min_distance: float = 1.0
@export var scatter_max_count: int = 500
@export var scatter_max_scale: float = 1.0
@export var visual_layer: int = 0
@export var group: String = ""
@export var material: Material


func get_color() -> Color:
	if _should_read_profile_average():
		return voxel_profile.get_color()
	var result := color
	result.a = get_complexity()
	return result


func get_complexity() -> float:
	if _should_read_profile_average():
		return voxel_profile.get_complexity()
	return clampf(complexity, 0.0, 1.0)


func set_color_and_complexity(next_color: Color, next_complexity: float) -> void:
	complexity = clampf(next_complexity, 0.0, 1.0)
	color = next_color
	color.a = complexity


func get_collision_voxels(default_radius: float = 0.0) -> Array[Dictionary]:
	var radius := default_radius
	if radius <= 0.0 and _is_vegetation_descriptor():
		radius = vegetation_radius
	if not collision_voxels.is_empty():
		return AutoVoxelProfile.normalize_collision_voxels(collision_voxels, radius)
	if voxel_profile != null:
		return voxel_profile.get_collision_voxels(radius)
	return []


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
	mesh_or_density = null,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	fallback_collision_voxels: Array = []
) -> Array[Dictionary]:
	var profile := ensure_semantic_probe_profile()
	var resolved_mesh: Mesh = null
	var resolved_density := density_override
	var resolved_world_scale := world_scale
	var resolved_fallback_collisions := fallback_collision_voxels
	if mesh_or_density is Mesh:
		resolved_mesh = mesh_or_density as Mesh
	elif mesh_or_density is float or mesh_or_density is int:
		resolved_mesh = get_mesh()
		resolved_density = float(mesh_or_density)
		resolved_world_scale = Vector3.ONE * scatter_max_scale
	else:
		resolved_mesh = get_mesh()
		resolved_world_scale = Vector3.ONE * scatter_max_scale
	if resolved_fallback_collisions.is_empty():
		resolved_fallback_collisions = get_collision_voxels()
	var d := semantic_probe_density if resolved_density <= 0.0 else resolved_density
	if not profile.probes.is_empty() and absf(float(profile.get("density")) - d) <= 0.001:
		return profile.get_probes()
	var collisions := get_collision_voxels()
	if collisions.is_empty():
		collisions = resolved_fallback_collisions
	return profile.rebuild_from_mesh(
		resolved_mesh,
		collisions,
		get_color(),
		get_complexity(),
		d,
		resolved_world_scale,
		context_sensing_radius
	)


func to_record_fields(default_radius: float = 0.0) -> Dictionary:
	var profile := ensure_semantic_probe_profile() if semantic_probe_profile != null else null
	var result := SharedPropertyTypeScript.from_descriptor(self, default_radius)
	result.merge({
		"pivot_variants": get_pivot_variants(),
		"auto_generate_vertical_pivots": auto_generate_vertical_pivots,
		"semantic_probe_density": semantic_probe_density,
	}, true)
	if profile != null:
		result["semantic_probes"] = profile.probes.duplicate(true)
	return result


func get_mesh() -> Mesh:
	if mesh != null:
		return mesh
	match mesh_create_method.strip_edges():
		"create_tree_mesh":
			return VegetationScatter.create_tree_mesh()
		"create_midstory_mesh":
			return VegetationScatter.create_midstory_mesh()
		"create_bush_mesh":
			return VegetationScatter.create_bush_mesh()
		"create_flower_mesh":
			return VegetationScatter.create_flower_mesh()
		_:
			return null


func get_source_mesh() -> Mesh:
	if not source_mesh_path.is_empty() and (source_mesh == null or source_mesh == mesh):
		var loaded_source_mesh := AutoAssetFactory.load_mesh(source_mesh_path)
		if loaded_source_mesh != null:
			source_mesh = loaded_source_mesh
			return source_mesh
	if source_mesh != null:
		return source_mesh
	return get_mesh()


func get_scatter_profile() -> Array[Dictionary]:
	var result_color := get_color()
	var result_complexity := get_complexity()
	result_color.a = result_complexity
	return [{
		"channel": vegetation_channel,
		"radius": vegetation_radius,
		"color": result_color,
		"complexity": result_complexity,
	}]


func make_instance_config(config: Dictionary = {}) -> Dictionary:
	var cfg := config.duplicate(true)
	if not cfg.has("mesh"):
		var resolved_mesh := get_mesh()
		if resolved_mesh != null:
			cfg["mesh"] = resolved_mesh
	if not cfg.has("source_mesh"):
		var resolved_source_mesh := get_source_mesh()
		if resolved_source_mesh != null:
			cfg["source_mesh"] = resolved_source_mesh
	if not cfg.has("source_mesh_path") and not source_mesh_path.is_empty():
		cfg["source_mesh_path"] = source_mesh_path

	if not cfg.has("voxel_profile") and voxel_profile != null:
		cfg["voxel_profile"] = voxel_profile
	if not cfg.has("voxel_descriptor"):
		cfg["voxel_descriptor"] = self
	if not cfg.has("color"):
		cfg["color"] = get_color()
	if not cfg.has("complexity"):
		cfg["complexity"] = get_complexity()
	if not cfg.has("collision_voxels"):
		cfg["collision_voxels"] = get_collision_voxels()
	if not cfg.has("pivot_variants"):
		cfg["pivot_variants"] = get_pivot_variants()
	if not cfg.has("semantic_probe_density"):
		cfg["semantic_probe_density"] = semantic_probe_density
	if not cfg.has("semantic_probe_profile") and semantic_probe_profile != null:
		cfg["semantic_probe_profile"] = semantic_probe_profile
	if not cfg.has("semantic_probes"):
		cfg["semantic_probes"] = get_semantic_probes(semantic_probe_density)

	if not cfg.has("asset_id") and not asset_id.is_empty():
		cfg["asset_id"] = asset_id
	if not cfg.has("object_type"):
		cfg["object_type"] = "vegetation" if object_type.is_empty() else object_type
	if not cfg.has("object_subtype"):
		cfg["object_subtype"] = object_subtype
	if not cfg.has("channel"):
		cfg["channel"] = vegetation_channel
	if not cfg.has("vegetation_channel"):
		cfg["vegetation_channel"] = vegetation_channel
	if not cfg.has("radius"):
		cfg["radius"] = vegetation_radius
	if not cfg.has("vegetation_radius"):
		cfg["vegetation_radius"] = vegetation_radius
	if not cfg.has("visual_layer") and visual_layer > 0:
		cfg["visual_layer"] = visual_layer
	if not cfg.has("group") and not group.is_empty():
		cfg["group"] = group
	if not cfg.has("material") and material != null:
		cfg["material"] = material
	return cfg


func instantiate_vegetation(config: Dictionary = {}) -> AutoVegetation:
	var node: AutoVegetation = null
	if vegetation_script != null:
		var instance = vegetation_script.new()
		if instance is AutoVegetation:
			node = instance as AutoVegetation
		else:
			push_error("AutoVoxelDescriptor: vegetation_script must create an AutoVegetation")
	if node == null:
		node = AutoVegetation.new()
	var cfg := make_instance_config(config)
	if node.has_method("configure_asset"):
		node.call("configure_asset", cfg)
	else:
		node.configure_vegetation(cfg)
	return node


func _should_read_profile_average() -> bool:
	return (
		voxel_profile != null
		and color == Color.WHITE
		and is_equal_approx(complexity, 1.0)
	)


func _is_vegetation_descriptor() -> bool:
	return (
		object_type.strip_edges().to_lower() == "vegetation"
		or vegetation_script != null
		or mesh != null
		or not mesh_create_method.strip_edges().is_empty()
		or not asset_id.strip_edges().is_empty()
	)


static func from_profile(profile: AutoVoxelProfile, default_radius: float = 0.0) -> Resource:
	var descriptor = load("res://scripts/auto_voxel_descriptor.gd").new()
	if profile == null:
		return descriptor
	descriptor.color = profile.get_color()
	descriptor.complexity = profile.get_complexity()
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
