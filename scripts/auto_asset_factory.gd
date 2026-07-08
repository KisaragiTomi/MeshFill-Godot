class_name AutoAssetFactory
extends RefCounted

const AutoObject := preload("res://scripts/auto_object.gd")
const AutoVoxelProfile := preload("res://scripts/auto_voxel_profile.gd")
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const FsUtils := preload("res://scripts/utils/fs_utils.gd")
const DemoAssets := preload("res://scripts/utils/demo_assets.gd")
const SUPPORTED_VEGETATION_MESH_CREATE_METHODS := [
	"create_sample_autoobject_mesh",
]


static func is_supported_vegetation_mesh_create_method(method_name: String) -> bool:
	return SUPPORTED_VEGETATION_MESH_CREATE_METHODS.has(method_name.strip_edges())


static func create_voxel_profile(
	entry_color: Color,
	entry_complexity: float,
	default_radius: float = 0.0,
	collision: Array = []
) -> AutoVoxelProfile:
	return AutoObject.create_voxel_profile(entry_color, entry_complexity, default_radius, collision)


static func create_voxel_descriptor(
	entry_color: Color,
	entry_complexity: float,
	default_radius: float = 0.0,
	collision: Array = [],
	pivot_variants: Array = [],
	semantic_probe_profile: Resource = null,
	semantic_probe_density: float = 1.0,
	context_sensing_radius: float = 0.0
) -> Resource:
	return AutoObject.create_voxel_descriptor(
		entry_color,
		entry_complexity,
		default_radius,
		collision,
		pivot_variants,
		semantic_probe_profile,
		semantic_probe_density,
		context_sensing_radius
	)


static func load_or_new_object_asset(asset_path: String) -> AutoObject:
	var existing = load(asset_path) if not asset_path.is_empty() else null
	if existing is PackedScene:
		var instance := (existing as PackedScene).instantiate()
		if instance is AutoObject:
			return instance as AutoObject
		if instance != null:
			instance.free()
	return AutoObject.new()


static func create_or_update_object_asset(
	asset: AutoObject,
	mesh: Mesh,
	mesh_height_texture: Texture2D,
	mesh_size: float,
	profile: AutoVoxelProfile = null,
	entry_color: Color = Color(0.55, 0.50, 0.45, 1.0),
	entry_complexity: float = 1.0,
	collision: Array = [],
	random_rotate: Vector2 = Vector2(0.0, 1.0),
	random_scale: Vector2 = Vector2(0.8, 1.2),
	random_height_offset: Vector2 = Vector2(-0.5, 0.5),
	sync_exported_fields: bool = true,
	source_mesh: Mesh = null,
	source_mesh_path: String = "",
	preserve_descriptor_shared_fields: bool = true
) -> AutoObject:
	var result := asset if asset != null else AutoObject.new()
	var direct_color := entry_color
	var direct_complexity := clampf(entry_complexity, 0.0, 1.0)
	var direct_collision: Array[Dictionary] = []
	if profile != null:
		direct_color = profile.get_color()
		direct_complexity = profile.get_complexity()
		direct_collision = profile.get_collision(0.0)
	if preserve_descriptor_shared_fields and result.voxel_descriptor != null:
		var descriptor_fields := SharedPropertyTypeScript.from_descriptor(result.voxel_descriptor, mesh_size * 0.5)
		direct_color = descriptor_fields.color
		direct_complexity = float(descriptor_fields.complexity)
		direct_collision = SharedPropertyTypeScript.duplicate_dictionary_array(descriptor_fields.get("collision", []))
	if not collision.is_empty():
		direct_collision = SharedPropertyTypeScript.duplicate_dictionary_array(collision)
	direct_color.a = direct_complexity
	if not direct_collision.is_empty():
		direct_collision = SharedPropertyTypeScript.collision_from_fields({SharedPropertyTypeScript.COLLISION_KEY: direct_collision})
	var cfg := {
		"mesh": mesh,
		"source_mesh": source_mesh if source_mesh != null else mesh,
		"source_mesh_path": source_mesh_path,
		"mesh_height_texture": mesh_height_texture,
		"mesh_size": mesh_size,
		"voxel_profile": profile,
		"color": direct_color,
		"complexity": direct_complexity,
		"collision": direct_collision,
		"random_rotate": random_rotate,
		"random_scale": random_scale,
		"random_height_offset": random_height_offset,
	}
	if result.has_method("configure_asset"):
		result.call("configure_asset", cfg)
	else:
		result.configure_object(cfg)
	if sync_exported_fields:
		result.voxel_color = direct_color
		result.voxel_complexity = direct_complexity
		result.set_collision(direct_collision)
	return result


static func configure_object_instance(obj: AutoObject, asset: AutoObject, config: Dictionary = {}) -> void:
	if obj == null or asset == null:
		return
	obj.configure_from_asset(asset, config)


static func save_object_asset(obj: AutoObject, resource_path: String) -> int:
	if obj == null or resource_path.is_empty():
		return ERR_INVALID_PARAMETER
	var err := FsUtils.ensure_parent_dir(resource_path)
	if err != OK:
		return err
	var packed := PackedScene.new()
	err = packed.pack(obj)
	if err != OK:
		return err
	return ResourceSaver.save(packed, resource_path)


static func configure_vegetation_instance(
	vegetation: AutoObject,
	vegetation_asset: Resource,
	config: Dictionary = {}
) -> void:
	if vegetation == null or vegetation_asset == null:
		return
	var cfg := config.duplicate(true)
	if vegetation_asset.has_method("make_instance_config"):
		cfg = vegetation_asset.call("make_instance_config", cfg)
	if vegetation.has_method("configure_asset"):
		vegetation.call("configure_asset", cfg)
	else:
		vegetation.configure_auto_object(cfg)


static func make_profile_voxel_write_spec(
	record_id: String,
	object_type: String,
	position: Vector3,
	rotation_degrees: Vector3,
	scale: Vector3,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	profile: AutoVoxelProfile,
	default_radius: float,
	y_min: float = 0.0,
	y_max: float = 0.0,
	collision_override: Array = [],
	extra_fields: Dictionary = {}
) -> Dictionary:
	return AutoObject.make_profile_voxel_write_spec(
		record_id,
		object_type,
		position,
		rotation_degrees,
		scale,
		base_pixel,
		volume_xz_resolution,
		profile,
		default_radius,
		y_min,
		y_max,
		collision_override,
		extra_fields
	)


static func make_profile_instance_stamp_write_spec(
	record_id: String,
	object_type: String,
	position: Vector3,
	rotation_degrees: Vector3,
	scale: Vector3,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	profile: AutoVoxelProfile,
	default_radius: float,
	y_min: float = 0.0,
	y_max: float = 0.0,
	collision_override: Array = [],
	extra_fields: Dictionary = {}
) -> Dictionary:
	return make_profile_voxel_write_spec(
		record_id,
		object_type,
		position,
		rotation_degrees,
		scale,
		base_pixel,
		volume_xz_resolution,
		profile,
		default_radius,
		y_min,
		y_max,
		collision_override,
		extra_fields
	)


static func make_object_voxel_write_spec(
	record_id: String,
	obj: MeshInstance3D,
	mesh_index: int,
	asset: AutoObject,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	if obj == null or asset == null:
		return {}
	var fields := extra_fields.duplicate(true)
	fields["mesh_index"] = mesh_index
	if obj is AutoObject:
		return (obj as AutoObject).make_voxel_write_spec(record_id, base_pixel, volume_xz_resolution, fields)
	var record_obj: AutoObject = null
	var duplicate_node = asset.duplicate()
	if duplicate_node is AutoObject:
		record_obj = duplicate_node as AutoObject
	elif duplicate_node != null:
		duplicate_node.free()
	if record_obj == null:
		record_obj = AutoObject.new()
	record_obj.configure_from_asset(asset, {
		"mesh": obj.mesh,
		"position": obj.position,
		"rotation_mode": "XYZ",
		"rotation_degrees": obj.rotation_degrees,
		"mesh_index": mesh_index,
	})
	record_obj.scale = obj.scale
	var record := record_obj.make_voxel_write_spec(record_id, base_pixel, volume_xz_resolution, fields)
	record_obj.free()
	return record


static func make_object_instance_stamp_write_spec(
	record_id: String,
	obj: MeshInstance3D,
	mesh_index: int,
	asset: AutoObject,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	return make_object_voxel_write_spec(
		record_id,
		obj,
		mesh_index,
		asset,
		base_pixel,
		volume_xz_resolution,
		extra_fields
	)


static func make_vegetation_voxel_write_spec(
	record_id: String,
	vegetation: AutoObject,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	if vegetation == null:
		return {}
	return vegetation.make_voxel_write_spec(record_id, base_pixel, volume_xz_resolution, extra_fields)


static func make_vegetation_instance_stamp_write_spec(
	record_id: String,
	vegetation: AutoObject,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	return make_vegetation_voxel_write_spec(record_id, vegetation, base_pixel, volume_xz_resolution, extra_fields)


static func load_mesh(mesh_path: String) -> Mesh:
	if mesh_path.is_empty():
		return null
	var resource = load(mesh_path)
	if resource is Mesh:
		return resource as Mesh
	if resource is PackedScene:
		var instance := (resource as PackedScene).instantiate()
		var mesh_info := _find_mesh_info_in_tree(instance)
		if mesh_info.is_empty():
			mesh_info = _find_mesh_info_in_tree(instance, Transform3D.IDENTITY, true)
		var mesh: Mesh = mesh_info.get("mesh", null)
		var mesh_transform: Transform3D = mesh_info.get("transform", Transform3D.IDENTITY)
		instance.free()
		if mesh == null:
			return null
		return _bake_mesh_transform(mesh, mesh_transform)
	return null


static func load_source_mesh(mesh_path: String) -> Mesh:
	if mesh_path.is_empty():
		return null
	var resource = load(mesh_path)
	if resource is Mesh:
		return resource as Mesh
	if resource is PackedScene:
		var instance := (resource as PackedScene).instantiate()
		var mesh_info := _find_mesh_info_in_tree(instance)
		if mesh_info.is_empty():
			mesh_info = _find_mesh_info_in_tree(instance, Transform3D.IDENTITY, true)
		var mesh: Mesh = mesh_info.get("mesh", null)
		instance.free()
		return mesh
	return null


## 网格树查找 / UE 碰撞辅助体过滤 / 变换烘焙已与 DemoAssets 合并(原三份近逐字重复)。
## 委托版差异均为更安全方向:identity 变换直接返回源网格、空 surface 跳过、法线尺寸校验更严。
static func _find_mesh_info_in_tree(
	node: Node,
	parent_transform: Transform3D = Transform3D.IDENTITY,
	allow_collision_helpers: bool = false
) -> Dictionary:
	return DemoAssets.find_mesh_info_in_tree(node, parent_transform, allow_collision_helpers)


static func _is_ue_collision_helper(node: Node) -> bool:
	return DemoAssets.is_collision_helper_node(node)


static func _bake_mesh_transform(src_mesh: Mesh, mesh_transform: Transform3D) -> Mesh:
	return DemoAssets.bake_mesh_xform(src_mesh, mesh_transform, true)


static func load_texture_or_raw(texture_path: String, raw_width: int = 256, raw_height: int = 256) -> Texture2D:
	if texture_path.is_empty():
		return null
	var resource = load(texture_path)
	if resource is Texture2D:
		return resource as Texture2D
	if texture_path.get_extension().to_lower() == "raw":
		return FsUtils.load_raw_rgbaf_texture(texture_path, raw_width, raw_height, "AutoAssetFactory")
	return null


static func save_resource(resource: Resource, resource_path: String) -> int:
	if resource == null or resource_path.is_empty():
		return ERR_INVALID_PARAMETER
	var err := FsUtils.ensure_parent_dir(resource_path)
	if err != OK:
		return err
	return ResourceSaver.save(resource, resource_path)


static func write_text_file(path: String, content: String) -> int:
	var err := FsUtils.ensure_parent_dir(path)
	if err != OK:
		return err
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.close()
	return OK


static func _to_snake_case(value: String) -> String:
	var output := ""
	for i in range(value.length()):
		var ch := value.substr(i, 1)
		var lower := ch.to_lower()
		var is_upper := ch != lower and ch.to_upper() == ch
		if i > 0 and is_upper and not output.ends_with("_"):
			output += "_"
		elif ch == "-" or ch == " ":
			if not output.ends_with("_"):
				output += "_"
			continue
		output += lower
	output = output.strip_edges()
	while output.ends_with("_"):
		output = output.substr(0, output.length() - 1)
	return output
