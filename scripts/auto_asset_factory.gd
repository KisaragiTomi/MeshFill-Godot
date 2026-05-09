class_name AutoAssetFactory
extends RefCounted

const BAND_CHANNELS := {
	"ground": 0,
	"understory": 1,
	"midstory": 2,
	"canopy": 3,
}
const DEFAULT_ROCK_BANDS := ["ground", "understory", "midstory", "canopy"]


static func band_channel(band_name: String, fallback: int = 0) -> int:
	return int(BAND_CHANNELS.get(band_name, fallback))


static func color_from_value(value, fallback: Color = Color.WHITE) -> Color:
	if value is Color:
		return value as Color
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			var alpha := float(arr[3]) if arr.size() >= 4 else fallback.a
			return Color(float(arr[0]), float(arr[1]), float(arr[2]), alpha)
	if value is Dictionary:
		var dict := value as Dictionary
		return Color(
			float(dict.get("r", fallback.r)),
			float(dict.get("g", fallback.g)),
			float(dict.get("b", fallback.b)),
			float(dict.get("a", fallback.a))
		)
	if value is String:
		return Color.from_string(str(value), fallback)
	return fallback


static func vector2_from_value(value, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value as Vector2
	if value is Array:
		var arr := value as Array
		if arr.size() >= 2:
			return Vector2(float(arr[0]), float(arr[1]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector2(
			float(dict.get("x", fallback.x)),
			float(dict.get("y", fallback.y))
		)
	return fallback


static func vector3_from_value(value, fallback: Vector3) -> Vector3:
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


static func duplicate_dictionary_array(source: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_entry in source:
		if raw_entry is Dictionary:
			result.append((raw_entry as Dictionary).duplicate(true))
	return result


static func make_band_entries(
	bands: Array,
	entry_color: Color,
	entry_complexity: float,
	default_radius: float = 0.0
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var complexity := clampf(entry_complexity, 0.0, 1.0)
	for raw_band in bands:
		var band_name := ""
		var channel := result.size()
		var radius := default_radius
		var color := entry_color
		var band_complexity := complexity

		if raw_band is Dictionary:
			var dict := raw_band as Dictionary
			band_name = str(dict.get("band", dict.get("name", "")))
			channel = int(dict.get("channel", band_channel(band_name, channel)))
			radius = float(dict.get("radius", default_radius))
			color = color_from_value(dict.get("color", entry_color), entry_color)
			band_complexity = clampf(float(dict.get("complexity", complexity)), 0.0, 1.0)
		else:
			band_name = str(raw_band)
			channel = band_channel(band_name, channel)

		if band_name.is_empty():
			continue
		color.a = band_complexity
		result.append({
			"band": band_name,
			"channel": channel,
			"radius": radius,
			"color": color,
			"complexity": band_complexity,
		})
	return result


static func create_voxel_profile(
	entry_color: Color,
	entry_complexity: float,
	affected_bands: Array = [],
	default_radius: float = 0.0,
	collision_voxels: Array = []
) -> AutoVoxelProfile:
	var profile := AutoVoxelProfile.new()
	profile.color = entry_color
	profile.complexity = clampf(entry_complexity, 0.0, 1.0)
	var bands := affected_bands
	if bands.is_empty():
		bands = DEFAULT_ROCK_BANDS
	profile.affected_bands = make_band_entries(bands, entry_color, profile.complexity, default_radius)
	profile.collision_voxels = duplicate_dictionary_array(collision_voxels)
	return profile


static func create_voxel_descriptor(
	entry_color: Color,
	entry_complexity: float,
	affected_bands: Array = [],
	default_radius: float = 0.0,
	collision_voxels: Array = [],
	pivot_variants: Array = [],
	semantic_probe_profile: Resource = null,
	semantic_probe_density: float = 1.0
) -> Resource:
	var profile := create_voxel_profile(entry_color, entry_complexity, affected_bands, default_radius, collision_voxels)
	var descriptor = load("res://scripts/auto_voxel_descriptor.gd").from_profile(profile, default_radius)
	if not pivot_variants.is_empty():
		descriptor.set_pivot_variants(pivot_variants)
	descriptor.semantic_probe_profile = semantic_probe_profile
	descriptor.semantic_probe_density = clampf(semantic_probe_density, 0.1, 8.0)
	return descriptor


static func create_single_band_profile(
	band_name: String,
	radius: float,
	entry_color: Color,
	entry_complexity: float,
	collision_voxels: Array = []
) -> AutoVoxelProfile:
	var profile := create_voxel_profile(
		entry_color,
		entry_complexity,
		[{"band": band_name, "channel": band_channel(band_name), "radius": radius}],
		radius,
		collision_voxels
	)
	return profile


static func load_or_new_mesh_data_asset(asset_path: String) -> MeshDataAsset:
	var existing = load(asset_path) if not asset_path.is_empty() else null
	if existing is MeshDataAsset:
		return existing as MeshDataAsset
	return MeshDataAsset.new()


static func load_or_new_rock_asset(asset_path: String) -> AutoRock:
	var existing = load(asset_path) if not asset_path.is_empty() else null
	if existing is PackedScene:
		var instance := (existing as PackedScene).instantiate()
		if instance is AutoRock:
			return instance as AutoRock
		if instance != null:
			instance.free()
	if existing is MeshDataAsset:
		return rock_from_mesh_data_asset(existing as MeshDataAsset)
	return AutoCliffRock.new()


static func rock_from_mesh_data_asset(asset: MeshDataAsset, subtype: String = "cliff") -> AutoRock:
	var rock := AutoCliffRock.new()
	if asset == null:
		return rock
	rock.configure_rock({
		"asset_id": asset.resource_path.get_file().get_basename() if not asset.resource_path.is_empty() else "",
		"object_subtype": subtype,
		"mesh": asset.mesh,
		"source_mesh": asset.get_source_mesh(),
		"source_mesh_path": asset.source_mesh_path,
		"mesh_height_texture": asset.mesh_height_texture,
		"mesh_size": asset.mesh_size,
		"voxel_profile": asset.voxel_profile,
		"color": asset.get_voxel_color(),
		"complexity": asset.get_voxel_complexity(),
		"affected_bands": asset.get_affected_bands(asset.mesh_size * 0.5),
		"collision_voxels": asset.get_collision_voxels(asset.mesh_size * 0.5),
		"random_rotate": asset.random_rotate,
		"random_scale": asset.random_scale,
		"random_height_offset": asset.random_height_offset,
	})
	return rock


static func create_or_update_rock_asset(
	asset: AutoRock,
	mesh: Mesh,
	mesh_height_texture: Texture2D,
	mesh_size: float,
	profile: AutoVoxelProfile = null,
	entry_color: Color = Color(0.55, 0.50, 0.45, 1.0),
	entry_complexity: float = 1.0,
	affected_bands: Array = [],
	collision_voxels: Array = [],
	random_rotate: Vector2 = Vector2(0.0, 1.0),
	random_scale: Vector2 = Vector2(0.8, 1.2),
	random_height_offset: Vector2 = Vector2(-0.5, 0.5),
	sync_legacy_fields: bool = true,
	source_mesh: Mesh = null,
	source_mesh_path: String = ""
) -> AutoRock:
	var result := asset if asset != null else AutoCliffRock.new()
	var direct_color := entry_color
	var direct_complexity := clampf(entry_complexity, 0.0, 1.0)
	var direct_bands: Array[Dictionary] = []
	var direct_collision_voxels: Array[Dictionary] = []
	if profile != null:
		direct_color = profile.get_color()
		direct_complexity = profile.get_complexity()
		direct_bands = profile.get_affected_bands(0.0)
		direct_collision_voxels = profile.get_collision_voxels(0.0)
	if not affected_bands.is_empty() or direct_bands.is_empty():
		direct_bands = make_band_entries(
			affected_bands if not affected_bands.is_empty() else DEFAULT_ROCK_BANDS,
			direct_color,
			direct_complexity,
			0.0
		)
	if not collision_voxels.is_empty():
		direct_collision_voxels = duplicate_dictionary_array(collision_voxels)
	direct_color.a = direct_complexity
	if not direct_bands.is_empty():
		direct_bands = AutoVoxelProfile.normalize_affected_bands(direct_bands, 0.0, direct_color, direct_complexity)
	if not direct_collision_voxels.is_empty():
		direct_collision_voxels = AutoVoxelProfile.normalize_collision_voxels(direct_collision_voxels, 0.0)
	var cfg := {
		"mesh": mesh,
		"source_mesh": source_mesh if source_mesh != null else mesh,
		"source_mesh_path": source_mesh_path,
		"mesh_height_texture": mesh_height_texture,
		"mesh_size": mesh_size,
		"voxel_profile": profile,
		"color": direct_color,
		"complexity": direct_complexity,
		"affected_bands": direct_bands,
		"collision_voxels": direct_collision_voxels,
		"random_rotate": random_rotate,
		"random_scale": random_scale,
		"random_height_offset": random_height_offset,
	}
	if result.has_method("configure_cliff"):
		result.call("configure_cliff", cfg)
	elif result.has_method("configure_asset"):
		result.call("configure_asset", cfg)
	else:
		result.configure_rock(cfg)
	if sync_legacy_fields:
		result.voxel_color = direct_color
		result.voxel_complexity = direct_complexity
		result.set_affected_bands(direct_bands)
		result.set_collision_voxels(direct_collision_voxels)
	return result


static func configure_rock_instance(rock: AutoRock, asset: AutoRock, config: Dictionary = {}) -> void:
	if rock == null or asset == null:
		return
	var cfg := asset.make_instance_config(config)
	var radius := float(cfg.get("profile_radius", asset.mesh_size * 0.5))
	if not cfg.has("color"):
		cfg["color"] = asset.get_voxel_color()
	if not cfg.has("complexity"):
		cfg["complexity"] = asset.get_voxel_complexity()
	if not cfg.has("affected_bands"):
		cfg["affected_bands"] = asset.get_affected_bands(radius)
	if not cfg.has("collision_voxels"):
		cfg["collision_voxels"] = asset.get_collision_voxels(radius)
	if rock.has_method("configure_asset"):
		rock.call("configure_asset", cfg)
	elif rock.has_method("configure_cliff"):
		rock.call("configure_cliff", cfg)
	else:
		rock.configure_rock(cfg)


static func save_rock_asset(rock: AutoRock, resource_path: String) -> int:
	if rock == null or resource_path.is_empty():
		return ERR_INVALID_PARAMETER
	var err := _ensure_parent_dir(resource_path)
	if err != OK:
		return err
	var packed := PackedScene.new()
	err = packed.pack(rock)
	if err != OK:
		return err
	return ResourceSaver.save(packed, resource_path)


static func configure_vegetation_instance(
	vegetation: AutoVegetation,
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
		vegetation.configure_vegetation(cfg)


static func make_profile_scene_voxel_record(
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
	collision_voxels_override: Array = [],
	extra_fields: Dictionary = {}
) -> Dictionary:
	var color := Color.WHITE
	var complexity := 1.0
	var affected_bands: Array[Dictionary] = []
	var collision_voxels: Array[Dictionary] = []
	if profile != null:
		color = profile.get_color()
		complexity = profile.get_complexity()
		affected_bands = profile.get_affected_bands(default_radius)
		collision_voxels = profile.get_collision_voxels(default_radius)
	if not collision_voxels_override.is_empty():
		collision_voxels = duplicate_dictionary_array(collision_voxels_override)
	color.a = complexity

	var scene_layers: Array[Dictionary] = []
	for raw_band in affected_bands:
		var layer := raw_band.duplicate(true)
		layer["base_pixel"] = base_pixel
		layer["voxel_xz"] = base_pixel
		layer["volume_xz_resolution"] = volume_xz_resolution
		layer["y_min"] = y_min
		layer["y_max"] = y_max
		if not layer.has("color"):
			layer["color"] = color
		if not layer.has("complexity"):
			layer["complexity"] = complexity
		if not layer.has("slice_indices"):
			layer["slice_indices"] = []
		scene_layers.append(layer)

	var source_kind := str(extra_fields.get("source_kind", "")).to_lower()
	if source_kind.is_empty():
		match object_type:
			"rock":
				source_kind = "rock_placement"
			"vegetation":
				source_kind = "scatter"
			_:
				source_kind = "auto"
	var source_type := str(extra_fields.get("source_voxel_type", ""))
	if source_type != "AutoSceneVoxel" and source_type != "BrushSceneVoxel" and source_type != "TargetSceneVoxel":
		if ["brush", "manual_edit", "erase", "lock"].has(source_kind):
			source_type = "BrushSceneVoxel"
		elif ["target", "heightfield_target", "flood_target", "guidance"].has(source_kind):
			source_type = "TargetSceneVoxel"
		else:
			source_type = "AutoSceneVoxel"

	var record := extra_fields.duplicate(true)
	record["id"] = record_id
	record["type"] = object_type
	record["position"] = position
	record["rotation_mode"] = "XYZ"
	record["rotation_degrees"] = rotation_degrees
	record["scale"] = scale
	record["base_pixel"] = base_pixel
	record["voxel_xz"] = base_pixel
	record["volume_xz_resolution"] = volume_xz_resolution
	record["color"] = color
	record["complexity"] = complexity
	record["affected_bands"] = affected_bands
	record["collision_voxels"] = collision_voxels
	record["SenceLayerVoxel"] = scene_layers
	record["source_voxel_type"] = source_type
	record["source_kind"] = source_kind
	record["producer_stage"] = str(extra_fields.get("producer_stage", source_kind))
	return record


static func make_rock_scene_voxel_record(
	record_id: String,
	rock: MeshInstance3D,
	mesh_index: int,
	asset: AutoRock,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	if rock == null or asset == null:
		return {}
	var aabb := rock.mesh.get_aabb() if rock.mesh != null else AABB()
	var y_min := rock.position.y + aabb.position.y * rock.scale.y
	var y_max := rock.position.y + (aabb.position.y + aabb.size.y) * rock.scale.y
	if y_max < y_min:
		var tmp := y_min
		y_min = y_max
		y_max = tmp
	var radius := maxf(aabb.size.x * absf(rock.scale.x), aabb.size.z * absf(rock.scale.z)) * 0.5
	radius = maxf(radius, asset.mesh_size * 0.5)
	var fields := extra_fields.duplicate(true)
	fields["mesh_index"] = mesh_index
	var profile := create_voxel_profile(
		asset.get_voxel_color(),
		asset.get_voxel_complexity(),
		asset.get_affected_bands(radius),
		radius,
		asset.get_collision_voxels(radius)
	)
	return make_profile_scene_voxel_record(
		record_id,
		"rock",
		rock.position,
		rock.rotation_degrees,
		rock.scale,
		base_pixel,
		volume_xz_resolution,
		profile,
		radius,
		y_min,
		y_max,
		[],
		fields
	)


static func make_vegetation_scene_voxel_record(
	record_id: String,
	vegetation: AutoVegetation,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	if vegetation == null:
		return {}
	var radius := vegetation.min_spacing if vegetation.min_spacing > 0.0 else 0.0
	var profile := create_voxel_profile(
		vegetation.get_voxel_color(),
		vegetation.get_voxel_complexity(),
		vegetation.get_affected_bands(radius),
		radius,
		vegetation.get_collision_voxels(radius)
	)
	var fields := extra_fields.duplicate(true)
	fields["object_subtype"] = vegetation.object_subtype
	fields["band"] = vegetation.vegetation_band
	return make_profile_scene_voxel_record(
		record_id,
		"vegetation",
		vegetation.position,
		vegetation.rotation_degrees,
		vegetation.scale,
		base_pixel,
		volume_xz_resolution,
		profile,
		radius,
		0.0,
		0.0,
		[],
		fields
	)


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
	band_name: String,
	group_name: String,
	script_path: String
) -> int:
	var method_name := "configure_%s" % _to_snake_case(object_subtype)
	var content := (
		"class_name %s\n"
		+ "extends AutoVegetation\n\n"
		+ "const DEFAULT_SUBTYPE := \"%s\"\n"
		+ "const DEFAULT_BAND := \"%s\"\n"
		+ "const DEFAULT_GROUP := \"%s\"\n\n\n"
		+ "func %s(config: Dictionary) -> void:\n"
		+ "\tconfigure_asset(config)\n\n\n"
		+ "func configure_asset(config: Dictionary) -> void:\n"
		+ "\tvar cfg := config.duplicate(true)\n"
		+ "\tcfg[\"object_subtype\"] = DEFAULT_SUBTYPE\n"
		+ "\tcfg[\"band\"] = DEFAULT_BAND\n"
		+ "\tif not cfg.has(\"group\") and not DEFAULT_GROUP.is_empty():\n"
		+ "\t\tcfg[\"group\"] = DEFAULT_GROUP\n"
		+ "\tconfigure_vegetation(cfg)\n"
	) % [class_name_value, object_subtype, band_name, group_name, method_name]
	return write_text_file(script_path, content)


static func write_rock_subclass(
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
		+ "\tconfigure_rock(cfg)\n"
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
