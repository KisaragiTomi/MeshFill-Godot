class_name AutoRock
extends AutoObject

@export var asset_id: String = ""
@export var mesh_height_texture: Texture2D
@export var mesh_size: float = 1.0
@export var voxel_profile: AutoVoxelProfile
@export var random_rotate: Vector2 = Vector2(0.0, 0.0)
@export var random_scale: Vector2 = Vector2(1.0, 1.0)
@export var random_height_offset: Vector2 = Vector2(0.0, 0.0)
@export var mesh_index: int = -1


func configure_asset(config: Dictionary) -> void:
	configure_rock(config)


func configure_rock(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_type"] = "rock"
	if not cfg.has("group"):
		cfg["group"] = "placed_rocks"

	if cfg.has("asset_id"):
		asset_id = str(cfg.asset_id)

	var configured_height_texture = cfg.get("mesh_height_texture", null)
	if configured_height_texture is Texture2D:
		mesh_height_texture = configured_height_texture as Texture2D
	if cfg.has("mesh_size"):
		mesh_size = maxf(float(cfg.mesh_size), 0.0)
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
	if cfg.has("pivot_variants"):
		set_pivot_variants(cfg.pivot_variants)
	if cfg.has("auto_generate_vertical_pivots"):
		auto_generate_vertical_pivots = bool(cfg.auto_generate_vertical_pivots)
	elif not cfg.has("pivot_variants"):
		auto_generate_vertical_pivots = true
	if cfg.has("semantic_probe_density"):
		semantic_probe_density = clampf(float(cfg.semantic_probe_density), 0.1, 8.0)
	if cfg.has("semantic_probe_profile"):
		var configured_probe_profile = cfg.get("semantic_probe_profile", null)
		if configured_probe_profile is Resource:
			semantic_probe_profile = configured_probe_profile as Resource
	if cfg.has("semantic_probes"):
		set_semantic_probes(cfg.semantic_probes)
	if cfg.has("random_rotate"):
		random_rotate = _vector2_from_config_value(cfg.random_rotate, random_rotate)
	if cfg.has("random_scale"):
		random_scale = _vector2_from_config_value(cfg.random_scale, random_scale)
	if cfg.has("random_height_offset"):
		random_height_offset = _vector2_from_config_value(cfg.random_height_offset, random_height_offset)

	if not cfg.has("color"):
		cfg["color"] = get_voxel_color()
	if not cfg.has("complexity"):
		cfg["complexity"] = get_voxel_complexity()
	var radius := float(cfg.get("profile_radius", mesh_size * 0.5))
	if not cfg.has("collision_voxels"):
		cfg["collision_voxels"] = get_collision_voxels(radius)
	if not cfg.has("pivot_variants"):
		cfg["pivot_variants"] = get_pivot_variants()

	configure_auto_object(cfg)
	if cfg.has("mesh_index"):
		mesh_index = int(cfg.mesh_index)
	_clear_rock_state_mirror_metadata()


func get_collision_voxels(default_radius: float = 0.0) -> Array[Dictionary]:
	var radius := default_radius
	if radius <= 0.0:
		radius = mesh_size * 0.5
	var descriptor_collisions := super.get_collision_voxels(radius)
	if not descriptor_collisions.is_empty():
		return descriptor_collisions
	if voxel_profile != null:
		return voxel_profile.get_collision_voxels(radius)
	return []


func get_record_object_type() -> String:
	return "rock"


func get_record_radius() -> float:
	return maxf(get_xz_radius(), mesh_size * 0.5)


func get_asset_voxel_record_extra_fields(extra_fields: Dictionary = {}) -> Dictionary:
	var fields := super.get_asset_voxel_record_extra_fields(extra_fields)
	if not fields.has("mesh_index"):
		fields["mesh_index"] = mesh_index
	return fields


func is_valid_rock_asset() -> bool:
	return mesh != null and mesh_height_texture != null and mesh_size > 0.0


func make_instance_config(config: Dictionary = {}) -> Dictionary:
	var cfg := config.duplicate(true)
	if not cfg.has("asset_id") and not asset_id.is_empty():
		cfg["asset_id"] = asset_id
	if not cfg.has("object_subtype") and not object_subtype.is_empty():
		cfg["object_subtype"] = object_subtype
	if not cfg.has("visual_layer") and visual_layer > 0:
		cfg["visual_layer"] = visual_layer
	if not cfg.has("mesh"):
		cfg["mesh"] = mesh
	if not cfg.has("source_mesh_path") and not source_mesh_path.is_empty():
		cfg["source_mesh_path"] = source_mesh_path
	if not cfg.has("source_mesh") and get_source_mesh() != null:
		cfg["source_mesh"] = get_source_mesh()
	if not cfg.has("mesh_height_texture"):
		cfg["mesh_height_texture"] = mesh_height_texture
	if not cfg.has("mesh_size"):
		cfg["mesh_size"] = mesh_size
	if not cfg.has("voxel_profile") and voxel_profile != null:
		cfg["voxel_profile"] = voxel_profile
	if not cfg.has("color"):
		cfg["color"] = get_voxel_color()
	if not cfg.has("complexity"):
		cfg["complexity"] = get_voxel_complexity()
	var radius := float(cfg.get("profile_radius", mesh_size * 0.5))
	if not cfg.has("collision_voxels"):
		cfg["collision_voxels"] = get_collision_voxels(radius)
	if not cfg.has("pivot_variants"):
		cfg["pivot_variants"] = get_pivot_variants()
	if not cfg.has("semantic_probe_density"):
		cfg["semantic_probe_density"] = semantic_probe_density
	if not cfg.has("semantic_probe_profile") and semantic_probe_profile != null:
		cfg["semantic_probe_profile"] = semantic_probe_profile
	if not cfg.has("semantic_probes"):
		cfg["semantic_probes"] = get_semantic_probes(semantic_probe_density)
	if not cfg.has("random_rotate"):
		cfg["random_rotate"] = random_rotate
	if not cfg.has("random_scale"):
		cfg["random_scale"] = random_scale
	if not cfg.has("random_height_offset"):
		cfg["random_height_offset"] = random_height_offset
	return cfg


func configure_from_rock_asset(asset: AutoRock, config: Dictionary = {}) -> void:
	if asset == null:
		return
	var cfg := asset.make_instance_config(config)
	var radius := float(cfg.get("profile_radius", asset.mesh_size * 0.5))
	if not cfg.has("color"):
		cfg["color"] = asset.get_voxel_color()
	if not cfg.has("complexity"):
		cfg["complexity"] = asset.get_voxel_complexity()
	if not cfg.has("collision_voxels"):
		cfg["collision_voxels"] = asset.get_collision_voxels(radius)
	if has_method("configure_asset"):
		call("configure_asset", cfg)
	elif has_method("configure_cliff"):
		call("configure_cliff", cfg)
	else:
		configure_rock(cfg)


func make_asset_voxel_record(
	record_id: String,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	return super.make_asset_voxel_record(record_id, base_pixel, volume_xz_resolution, extra_fields)


func _vector2_from_config_value(value, fallback: Vector2) -> Vector2:
	return AutoObject.vector2_from_value(value, fallback)


func _clear_rock_state_mirror_metadata() -> void:
	for key in [
		"rock_mesh_index",
		"rock_asset_id",
		"rock_mesh_size",
		"rock_random_rotate",
		"rock_random_scale",
		"rock_random_height_offset",
	]:
		if has_meta(key):
			remove_meta(key)
