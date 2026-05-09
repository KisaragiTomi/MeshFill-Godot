class_name AutoVegetation
extends AutoObject

@export var vegetation_band: String = ""
@export var voxel_profile: AutoVoxelProfile


func configure_vegetation(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_type"] = "vegetation"
	if not cfg.has("object_subtype"):
		cfg["object_subtype"] = str(cfg.get("type", "vegetation"))
	if cfg.has("band"):
		vegetation_band = str(cfg.band)
	if cfg.has("voxel_profile"):
		var configured_profile = cfg.get("voxel_profile", null)
		if configured_profile is AutoVoxelProfile:
			voxel_profile = configured_profile as AutoVoxelProfile
		else:
			voxel_profile = null
	if cfg.has("color"):
		voxel_color = cfg.color
	if cfg.has("complexity"):
		voxel_complexity = clampf(float(cfg.complexity), 0.0, 1.0)
	voxel_color.a = voxel_complexity
	if cfg.has("affected_bands"):
		set_affected_bands(cfg.affected_bands)
	if cfg.has("collision_voxels"):
		set_collision_voxels(cfg.collision_voxels)
	if cfg.has("semantic_probe_density"):
		semantic_probe_density = clampf(float(cfg.semantic_probe_density), 0.1, 8.0)
	if cfg.has("semantic_probe_profile"):
		var configured_probe_profile = cfg.get("semantic_probe_profile", null)
		if configured_probe_profile is Resource:
			semantic_probe_profile = configured_probe_profile as Resource
	if cfg.has("semantic_probes"):
		set_semantic_probes(cfg.semantic_probes)
	if not cfg.has("color"):
		cfg["color"] = get_voxel_color()
	if not cfg.has("complexity"):
		cfg["complexity"] = get_voxel_complexity()
	if not cfg.has("affected_bands"):
		cfg["affected_bands"] = get_affected_bands()
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
	configure_auto_object(cfg)
	_clear_vegetation_state_mirror_metadata()


func get_affected_bands(default_radius: float = 0.0) -> Array[Dictionary]:
	var radius := default_radius if default_radius > 0.0 else _band_radius(vegetation_band)
	var descriptor_bands := super.get_affected_bands(radius)
	if not descriptor_bands.is_empty():
		return descriptor_bands
	if voxel_profile != null:
		var bands := voxel_profile.get_affected_bands(radius)
		if not bands.is_empty():
			return bands
	if vegetation_band.is_empty():
		return []
	return [_make_default_band_entry(vegetation_band, radius, get_voxel_color(), get_voxel_complexity())]


func get_collision_voxels(default_radius: float = 0.0) -> Array[Dictionary]:
	var radius := default_radius if default_radius > 0.0 else _band_radius(vegetation_band)
	var descriptor_collisions := super.get_collision_voxels(radius)
	if not descriptor_collisions.is_empty():
		return descriptor_collisions
	if voxel_profile != null:
		return voxel_profile.get_collision_voxels(radius)
	return []


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


func _clear_vegetation_state_mirror_metadata() -> void:
	for key in [
		"veg_color",
		"veg_complexity",
		"veg_affected_bands",
		"veg_collision_voxels",
		"veg_band",
	]:
		if has_meta(key):
			remove_meta(key)
