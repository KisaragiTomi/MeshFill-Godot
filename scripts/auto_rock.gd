class_name AutoRock
extends AutoObject

@export var asset_id: String = ""                            # 资产 id，随实例配置传递
@export var mesh_height_texture: Texture2D                   # 石头高度图，顶视每像素高度
@export var mesh_size: float = 1.0                           # 石头在纹理空间中的尺寸
@export var random_rotate: Vector2 = Vector2(0.0, 0.0)       # 随机旋转范围
@export var random_scale: Vector2 = Vector2(1.0, 1.0)        # 随机缩放范围
@export var random_height_offset: Vector2 = Vector2(0.0, 0.0) # 随机高度偏移范围
@export var mesh_index: int = -1                             # placement result 的资产索引


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
	if cfg.has("random_rotate"):
		random_rotate = AutoObject.vector2_from_value(cfg.random_rotate, random_rotate)
	if cfg.has("random_scale"):
		random_scale = AutoObject.vector2_from_value(cfg.random_scale, random_scale)
	if cfg.has("random_height_offset"):
		random_height_offset = AutoObject.vector2_from_value(cfg.random_height_offset, random_height_offset)

	if not cfg.has("auto_generate_vertical_pivots") and not cfg.has("pivot_variants"):
		cfg["auto_generate_vertical_pivots"] = true

	var radius := mesh_size * 0.5
	_apply_voxel_profile_fallback(cfg, radius)
	_fill_config_shared_defaults(cfg, radius)

	configure_auto_object(cfg)

	if cfg.has("mesh_index"):
		mesh_index = int(cfg.mesh_index)


func configure_from_rock_asset(asset: AutoRock, config: Dictionary = {}) -> void:
	if asset == null:
		return
	configure_rock(asset.make_instance_config(config))


func get_collision(default_radius: float = 0.0) -> Array[Dictionary]:
	var radius := default_radius
	if radius <= 0.0:
		radius = mesh_size * 0.5
	return super.get_collision(radius)


func get_record_object_type() -> String:
	return "rock"


func get_record_radius() -> float:
	return maxf(get_xz_radius(), mesh_size * 0.5)


func get_voxel_write_spec_extra_fields(extra_fields: Dictionary = {}) -> Dictionary:
	var fields := super.get_voxel_write_spec_extra_fields(extra_fields)
	if not fields.has("mesh_index"):
		fields["mesh_index"] = mesh_index
	return fields


func is_valid_rock_asset() -> bool:
	return mesh != null and mesh_height_texture != null and mesh_size > 0.0


func make_instance_config(config: Dictionary = {}) -> Dictionary:
	var cfg := super.make_instance_config(config)
	if not cfg.has("asset_id") and not asset_id.is_empty():
		cfg["asset_id"] = asset_id
	if not cfg.has("object_subtype") and not get_record_object_subtype().is_empty():
		cfg["object_subtype"] = get_record_object_subtype()
	if not cfg.has("mesh_height_texture"):
		cfg["mesh_height_texture"] = mesh_height_texture
	if not cfg.has("mesh_size"):
		cfg["mesh_size"] = mesh_size
	if not cfg.has("random_rotate"):
		cfg["random_rotate"] = random_rotate
	if not cfg.has("random_scale"):
		cfg["random_scale"] = random_scale
	if not cfg.has("random_height_offset"):
		cfg["random_height_offset"] = random_height_offset
	return cfg


func _clear_subclass_state_mirror_metadata() -> void:
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
