class_name AutoVegetation
extends AutoObject

@export_range(0, 3, 1) var vegetation_channel: int = 0
@export var vegetation_radius: float = 0.2
@export var voxel_profile: AutoVoxelProfile


func configure_vegetation(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_type"] = "vegetation"
	if not cfg.has("object_subtype"):
		cfg["object_subtype"] = str(cfg.get("type", "vegetation"))
	if cfg.has("channel"):
		vegetation_channel = clampi(int(cfg.channel), 0, 3)
	if cfg.has("vegetation_channel"):
		vegetation_channel = clampi(int(cfg.vegetation_channel), 0, 3)
	if cfg.has("radius"):
		vegetation_radius = maxf(float(cfg.radius), 0.0)
	if cfg.has("vegetation_radius"):
		vegetation_radius = maxf(float(cfg.vegetation_radius), 0.0)
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


func get_collision_voxels(default_radius: float = 0.0) -> Array[Dictionary]:
	var radius := default_radius if default_radius > 0.0 else vegetation_radius
	var descriptor_collisions := super.get_collision_voxels(radius)
	if not descriptor_collisions.is_empty():
		return descriptor_collisions
	if voxel_profile != null:
		return voxel_profile.get_collision_voxels(radius)
	return []


func get_record_object_type() -> String:
	return "vegetation"


func get_record_radius() -> float:
	var mesh_radius := get_xz_radius()
	if min_spacing > 0.0:
		return maxf(min_spacing, mesh_radius)
	return mesh_radius


func get_asset_voxel_record_extra_fields(extra_fields: Dictionary = {}) -> Dictionary:
	var fields := super.get_asset_voxel_record_extra_fields(extra_fields)
	if not fields.has("object_subtype"):
		fields["object_subtype"] = object_subtype
	if not fields.has("channel"):
		fields["channel"] = vegetation_channel
	if not fields.has("radius"):
		fields["radius"] = vegetation_radius
	return fields


func make_asset_voxel_record(
	record_id: String,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	return super.make_asset_voxel_record(record_id, base_pixel, volume_xz_resolution, extra_fields)


func _clear_vegetation_state_mirror_metadata() -> void:
	for key in [
		"veg_color",
		"veg_complexity",
		"veg_collision_voxels",
		"veg_channel",
		"veg_radius",
	]:
		if has_meta(key):
			remove_meta(key)
