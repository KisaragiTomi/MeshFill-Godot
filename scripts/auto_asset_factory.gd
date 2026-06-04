class_name AutoAssetFactory
extends RefCounted

const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const SUPPORTED_VEGETATION_MESH_CREATE_METHODS := [
	"create_sample_autoobject_mesh",
]


static func color_from_value(value, fallback: Color = Color.WHITE) -> Color:
	return SharedPropertyTypeScript.color_from_value(value, fallback)


static func vector2_from_value(value, fallback: Vector2) -> Vector2:
	return AutoObject.vector2_from_value(value, fallback)


static func vector3_from_value(value, fallback: Vector3) -> Vector3:
	return AutoObject.vector3_from_value(value, fallback)


static func duplicate_dictionary_array(source: Array) -> Array[Dictionary]:
	return SharedPropertyTypeScript.duplicate_dictionary_array(source)


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


static func load_or_new_object_asset(asset_path: String) -> AutoRock:
	var existing = load(asset_path) if not asset_path.is_empty() else null
	if existing is PackedScene:
		var instance := (existing as PackedScene).instantiate()
		if instance is AutoRock:
			return instance as AutoRock
		if instance != null:
			instance.free()
	return AutoRock.new()


static func create_or_update_object_asset(
	asset: AutoRock,
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
) -> AutoRock:
	var result := asset if asset != null else AutoRock.new()
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
		direct_collision = duplicate_dictionary_array(descriptor_fields.get("collision", []))
	if not collision.is_empty():
		direct_collision = duplicate_dictionary_array(collision)
	direct_color.a = direct_complexity
	if not direct_collision.is_empty():
		direct_collision = AutoVoxelDescriptor.normalize_collision(direct_collision, 0.0)
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


static func configure_object_instance(obj: AutoRock, asset: AutoRock, config: Dictionary = {}) -> void:
	if obj == null or asset == null:
		return
	obj.configure_from_asset(asset, config)


static func save_object_asset(obj: AutoRock, resource_path: String) -> int:
	if obj == null or resource_path.is_empty():
		return ERR_INVALID_PARAMETER
	var err := _ensure_parent_dir(resource_path)
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
	asset: AutoRock,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	if obj == null or asset == null:
		return {}
	var fields := extra_fields.duplicate(true)
	fields["mesh_index"] = mesh_index
	if obj is AutoRock:
		return (obj as AutoRock).make_voxel_write_spec(record_id, base_pixel, volume_xz_resolution, fields)
	var record_obj: AutoRock = null
	var duplicate_node = asset.duplicate()
	if duplicate_node is AutoRock:
		record_obj = duplicate_node as AutoRock
	elif duplicate_node != null:
		duplicate_node.free()
	if record_obj == null:
		record_obj = AutoRock.new()
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
	asset: AutoRock,
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


static func _find_mesh_in_tree(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh
	if node is ImporterMeshInstance3D:
		var importer_mesh = node.get("mesh")
		if importer_mesh != null and importer_mesh.has_method("get_mesh"):
			return importer_mesh.get_mesh()
	for child in node.get_children():
		var mesh := _find_mesh_in_tree(child)
		if mesh != null:
			return mesh
	return null


static func _find_mesh_info_in_tree(
	node: Node,
	parent_transform: Transform3D = Transform3D.IDENTITY,
	allow_collision_helpers: bool = false
) -> Dictionary:
	var node_transform := parent_transform
	if node is Node3D:
		node_transform = parent_transform * (node as Node3D).transform

	if allow_collision_helpers or not _is_ue_collision_helper(node):
		if node is MeshInstance3D:
			var mesh := (node as MeshInstance3D).mesh
			if mesh != null:
				return {
					"mesh": mesh,
					"transform": node_transform,
				}
		if node is ImporterMeshInstance3D:
			var importer_mesh = node.get("mesh")
			if importer_mesh != null and importer_mesh.has_method("get_mesh"):
				var converted = importer_mesh.get_mesh()
				if converted is Mesh:
					return {
						"mesh": converted,
						"transform": node_transform,
					}

	for child in node.get_children():
		var mesh_info := _find_mesh_info_in_tree(child, node_transform, allow_collision_helpers)
		if not mesh_info.is_empty():
			return mesh_info
	return {}


static func _is_ue_collision_helper(node: Node) -> bool:
	var node_name := str(node.name).to_upper()
	return (
		node_name.begins_with("UCX_")
		or node_name.begins_with("UBX_")
		or node_name.begins_with("UCP_")
		or node_name.begins_with("USP_")
		or node_name.begins_with("MCDCX_")
	)


static func _bake_mesh_transform(src_mesh: Mesh, mesh_transform: Transform3D) -> ArrayMesh:
	var normal_basis := mesh_transform.basis.inverse().transposed()
	var new_mesh := ArrayMesh.new()
	for surface_index in range(src_mesh.get_surface_count()):
		var arrays := src_mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT] if arrays[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()

		var baked_vertices := PackedVector3Array()
		baked_vertices.resize(vertices.size())
		for vertex_index in range(vertices.size()):
			baked_vertices[vertex_index] = mesh_transform * vertices[vertex_index]
		arrays[Mesh.ARRAY_VERTEX] = baked_vertices

		if normals.size() > 0:
			var baked_normals := PackedVector3Array()
			baked_normals.resize(normals.size())
			for normal_index in range(normals.size()):
				baked_normals[normal_index] = (normal_basis * normals[normal_index]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = baked_normals

		if tangents.size() > 0:
			var baked_tangents := tangents.duplicate()
			for tangent_index in range(0, tangents.size(), 4):
				var tangent := Vector3(
					tangents[tangent_index],
					tangents[tangent_index + 1],
					tangents[tangent_index + 2]
				)
				tangent = (normal_basis * tangent).normalized()
				baked_tangents[tangent_index] = tangent.x
				baked_tangents[tangent_index + 1] = tangent.y
				baked_tangents[tangent_index + 2] = tangent.z
			arrays[Mesh.ARRAY_TANGENT] = baked_tangents

		var primitive: int = src_mesh.surface_get_primitive_type(surface_index)
		new_mesh.add_surface_from_arrays(primitive, arrays)
		var material := src_mesh.surface_get_material(surface_index)
		if material != null:
			new_mesh.surface_set_material(surface_index, material)
	return new_mesh


static func load_texture_or_raw(texture_path: String, raw_width: int = 256, raw_height: int = 256) -> Texture2D:
	if texture_path.is_empty():
		return null
	var resource = load(texture_path)
	if resource is Texture2D:
		return resource as Texture2D
	if texture_path.get_extension().to_lower() == "raw":
		return load_raw_texture(texture_path, raw_width, raw_height)
	return null


static func load_raw_texture(path: String, width: int, height: int) -> ImageTexture:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var expected_size := width * height * 4 * 4
	var data := file.get_buffer(expected_size)
	file.close()
	if data.size() != expected_size:
		push_error("AutoAssetFactory: raw texture size mismatch for %s" % path)
		return null
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, data)
	return ImageTexture.create_from_image(image)


static func save_resource(resource: Resource, resource_path: String) -> int:
	if resource == null or resource_path.is_empty():
		return ERR_INVALID_PARAMETER
	var err := _ensure_parent_dir(resource_path)
	if err != OK:
		return err
	return ResourceSaver.save(resource, resource_path)


static func write_vegetation_subclass(
	class_name_value: String,
	object_subtype: String,
	channel: int,
	radius: float,
	group_name: String,
	script_path: String
) -> int:
	var method_name := "configure_%s" % _to_snake_case(object_subtype)
	var content := (
		"class_name %s\n"
		+ "extends AutoObject\n\n"
		+ "const DEFAULT_SUBTYPE := \"%s\"\n"
		+ "const DEFAULT_CHANNEL := %d\n"
		+ "const DEFAULT_RADIUS := %.6f\n"
		+ "const DEFAULT_GROUP := \"%s\"\n\n\n"
		+ "func %s(config: Dictionary) -> void:\n"
		+ "\tconfigure_asset(config)\n\n\n"
		+ "func configure_asset(config: Dictionary) -> void:\n"
		+ "\tvar cfg := config.duplicate(true)\n"
		+ "\tcfg[\"object_subtype\"] = DEFAULT_SUBTYPE\n"
		+ "\tcfg[\"object_type\"] = \"vegetation\"\n"
		+ "\tif not cfg.has(\"group\") and not DEFAULT_GROUP.is_empty():\n"
		+ "\t\tcfg[\"group\"] = DEFAULT_GROUP\n"
		+ "\tconfigure_auto_object(cfg)\n"
	) % [class_name_value, object_subtype, channel, radius, group_name, method_name]
	return write_text_file(script_path, content)


static func write_object_subclass(
	class_name_value: String,
	object_subtype: String,
	group_name: String,
	script_path: String
) -> int:
	var method_name := "configure_%s" % _to_snake_case(object_subtype)
	var content := (
		"class_name %s\n"
		+ "extends AutoRock\n\n"
		+ "const DEFAULT_SUBTYPE := \"%s\"\n"
		+ "const DEFAULT_GROUP := \"%s\"\n\n\n"
		+ "func %s(config: Dictionary) -> void:\n"
		+ "\tconfigure_asset(config)\n\n\n"
		+ "func configure_asset(config: Dictionary) -> void:\n"
		+ "\tvar cfg := config.duplicate(true)\n"
		+ "\tcfg[\"object_subtype\"] = DEFAULT_SUBTYPE\n"
		+ "\tif not cfg.has(\"group\") and not DEFAULT_GROUP.is_empty():\n"
		+ "\t\tcfg[\"group\"] = DEFAULT_GROUP\n"
		+ "\tconfigure_object(cfg)\n"
	) % [class_name_value, object_subtype, group_name, method_name]
	return write_text_file(script_path, content)


static func write_text_file(path: String, content: String) -> int:
	var err := _ensure_parent_dir(path)
	if err != OK:
		return err
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.close()
	return OK


static func _ensure_parent_dir(path: String) -> int:
	var dir := path.get_base_dir()
	if dir.is_empty() or dir == ".":
		return OK
	var abs_dir := ProjectSettings.globalize_path(dir) if dir.begins_with("res://") or dir.begins_with("user://") else dir
	return DirAccess.make_dir_recursive_absolute(abs_dir)


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
