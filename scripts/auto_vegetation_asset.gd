class_name AutoVegetationAsset
extends Resource

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const AutoVoxelDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")

@export var asset_id: String = ""
@export var object_subtype: String = "vegetation"
@export var vegetation_band: String = "ground"
@export var voxel_profile: AutoVoxelProfile
@export var voxel_descriptor: Resource
@export var voxel_color: Color = Color.WHITE
@export_range(0.0, 1.0) var voxel_complexity: float = 1.0
@export var affected_bands: Array[Dictionary] = []
@export var collision_voxels: Array[Dictionary] = []
@export var pivot_variants: Array[Dictionary] = []
@export var semantic_probe_profile: Resource
@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0
@export_range(0.0, 8.0, 0.1) var context_sensing_radius: float = 0.0
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


func _ensure_voxel_descriptor():
	if voxel_descriptor == null:
		voxel_descriptor = load("res://scripts/auto_voxel_descriptor.gd").new()
		voxel_descriptor.set_color_and_complexity(voxel_color, voxel_complexity)
		if not affected_bands.is_empty():
			voxel_descriptor.set_affected_bands(affected_bands)
		if not collision_voxels.is_empty():
			voxel_descriptor.set_collision_voxels(collision_voxels)
		voxel_descriptor.semantic_probe_profile = semantic_probe_profile
		voxel_descriptor.semantic_probe_density = semantic_probe_density
		voxel_descriptor.context_sensing_radius = context_sensing_radius
	return voxel_descriptor


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
	var radius := _band_radius(vegetation_band)
	if not affected_bands.is_empty():
		return AutoVoxelProfile.normalize_affected_bands(affected_bands, radius, get_voxel_color(), get_voxel_complexity())
	if voxel_profile != null:
		var bands := voxel_profile.get_affected_bands(radius)
		if not bands.is_empty():
			return bands
	if vegetation_band.is_empty():
		return []
	return [_make_default_band_entry(vegetation_band, radius, get_voxel_color(), get_voxel_complexity())]


func get_collision_voxels(default_radius: float = 0.0) -> Array[Dictionary]:
	var radius := default_radius if default_radius > 0.0 else _band_radius(vegetation_band)
	var descriptor = _ensure_voxel_descriptor()
	if descriptor != null and not descriptor.collision_voxels.is_empty():
		return descriptor.get_collision_voxels(radius)
	if not collision_voxels.is_empty():
		descriptor.set_collision_voxels(collision_voxels)
		return descriptor.get_collision_voxels(radius)
	if voxel_profile != null:
		var profile_collisions := voxel_profile.get_collision_voxels(radius)
		if not profile_collisions.is_empty():
			descriptor.set_collision_voxels(profile_collisions)
			return descriptor.get_collision_voxels(radius)
	return []


func get_pivot_variants() -> Array[Dictionary]:
	if not pivot_variants.is_empty():
		return load("res://scripts/auto_voxel_descriptor.gd").normalize_pivot_variants(pivot_variants)
	return [{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}]


func get_semantic_probes(density_override: float = -1.0) -> Array[Dictionary]:
	var descriptor = _ensure_voxel_descriptor()
	descriptor.set_color_and_complexity(get_voxel_color(), get_voxel_complexity())
	descriptor.set_affected_bands(get_scatter_profile())
	descriptor.set_collision_voxels(get_collision_voxels())
	descriptor.semantic_probe_density = semantic_probe_density
	descriptor.semantic_probe_profile = semantic_probe_profile
	var probes = descriptor.get_semantic_probes(
		get_mesh(),
		density_override,
		Vector3.ONE * scatter_max_scale,
		get_scatter_profile(),
		get_collision_voxels()
	)
	semantic_probe_profile = descriptor.semantic_probe_profile
	return probes


func get_voxel_color() -> Color:
	if _should_read_profile_average():
		return voxel_profile.get_color()
	var result := voxel_color
	result.a = get_voxel_complexity()
	return result


func get_voxel_complexity() -> float:
	if _should_read_profile_average():
		return voxel_profile.get_complexity()
	return clampf(voxel_complexity, 0.0, 1.0)


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
	if not cfg.has("color"):
		cfg["color"] = get_voxel_color()
	if not cfg.has("complexity"):
		cfg["complexity"] = get_voxel_complexity()
	if not cfg.has("affected_bands"):
		cfg["affected_bands"] = get_scatter_profile()
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

	if not cfg.has("object_subtype"):
		cfg["object_subtype"] = object_subtype
	if not cfg.has("band"):
		cfg["band"] = vegetation_band
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
			push_error("AutoVegetationAsset: vegetation_script must create an AutoVegetation")

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
		and voxel_color == Color.WHITE
		and is_equal_approx(voxel_complexity, 1.0)
	)


func _make_default_band_entry(band_name: String, radius: float, color: Color, complexity: float) -> Dictionary:
	var c := color
	c.a = clampf(complexity, 0.0, 1.0)
	return {
		"band": band_name,
		"channel": _band_channel(band_name),
		"radius": radius,
		"color": c,
		"complexity": c.a,
	}


func _band_channel(band_name: String) -> int:
	match band_name:
		"understory":
			return 1
		"midstory":
			return 2
		"canopy":
			return 3
		_:
			return 0


func _band_radius(band_name: String) -> float:
	match band_name:
		"understory":
			return 1.0
		"midstory":
			return 2.0
		"canopy":
			return 3.0
		_:
			return 0.2
