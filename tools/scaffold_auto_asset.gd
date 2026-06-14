extends SceneTree

const AutoAssetFactoryScript := preload("res://scripts/auto_asset_factory.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or args.has("--help") or args.has("-h"):
		_print_help()
		return OK

	var config := _load_config_from_args(args)
	var asset_type := str(_get_value(args, config, "type", ""))
	match asset_type:
		"object":
			return _scaffold_object(args, config)
		"vegetation":
			return _scaffold_vegetation(args, config)
		_:
			push_error("Use --type object or --type vegetation")
			_print_help()
			return ERR_INVALID_PARAMETER


func _scaffold_object(args: Array, config: Dictionary) -> int:
	var asset_path := str(_get_value(args, config, "asset_path", ""))
	if asset_path.is_empty():
		push_error("Object config requires asset_path")
		return ERR_INVALID_PARAMETER

	var mesh_path := str(_get_value(args, config, "mesh", ""))
	var mesh_height_path := str(_get_value(args, config, "mesh_height_texture", ""))
	var raw_width := int(_get_value(args, config, "raw_width", 256))
	var raw_height := int(_get_value(args, config, "raw_height", 256))

	var asset: AutoObject = AutoAssetFactoryScript.load_or_new_object_asset(asset_path)
	var mesh := asset.mesh
	var source_mesh := asset.get_source_mesh()
	var source_mesh_path := asset.source_mesh_path
	if not mesh_path.is_empty():
		mesh = AutoAssetFactoryScript.load_mesh(mesh_path)
		source_mesh = AutoAssetFactoryScript.load_source_mesh(mesh_path)
		source_mesh_path = mesh_path
	var mesh_height_texture := asset.mesh_height_texture
	if not mesh_height_path.is_empty():
		mesh_height_texture = AutoAssetFactoryScript.load_texture_or_raw(mesh_height_path, raw_width, raw_height)

	if mesh == null:
		push_error("Object config requires a mesh path or an existing AutoObject.mesh")
		return ERR_FILE_NOT_FOUND
	if mesh_height_texture == null:
		push_error("Object config requires mesh_height_texture or an existing AutoObject.mesh_height_texture")
		return ERR_FILE_NOT_FOUND

	var color := AutoAssetFactoryScript.color_from_value(
		_get_value(args, config, "color", Color(0.55, 0.50, 0.45, 1.0)),
		Color(0.55, 0.50, 0.45, 1.0)
	)
	var complexity := clampf(float(_get_value(args, config, "complexity", 1.0)), 0.0, 1.0)
	var collision := _array_value(args, config, "collision", [])
	var preserve_descriptor_shared_fields := not (
		_has_arg_or_config(args, config, "color")
		or _has_arg_or_config(args, config, "complexity")
		or _has_arg_or_config(args, config, "collision")
	)

	var mesh_size := float(_get_value(args, config, "mesh_size", asset.mesh_size))
	var random_rotate := AutoAssetFactoryScript.vector2_from_value(
		_get_value(args, config, "random_rotate", asset.random_rotate),
		Vector2(0.0, 1.0)
	)
	var random_scale := AutoAssetFactoryScript.vector2_from_value(
		_get_value(args, config, "random_scale", asset.random_scale),
		Vector2(0.8, 1.2)
	)
	var random_height_offset := AutoAssetFactoryScript.vector2_from_value(
		_get_value(args, config, "random_height_offset", asset.random_height_offset),
		Vector2(-0.5, 0.5)
	)

	asset = AutoAssetFactoryScript.create_or_update_object_asset(
		asset,
		mesh,
		mesh_height_texture,
		mesh_size,
		null,
		color,
		complexity,
		collision,
		random_rotate,
		random_scale,
		random_height_offset,
		bool(_get_value(args, config, "sync_exported_fields", true)),
		source_mesh,
		source_mesh_path,
		preserve_descriptor_shared_fields
	)
	asset.asset_id = str(_get_value(args, config, "asset_id", asset_path.get_file().get_basename()))
	if asset.name.is_empty():
		asset.name = asset.asset_id
	var err := AutoAssetFactoryScript.save_object_asset(asset, asset_path)
	if err != OK:
		push_error("Failed to save AutoObject scene asset: %s" % asset_path)
		return err

	print("Object asset scaffolded:")
	print("  asset:   %s" % asset_path)
	return OK


func _scaffold_vegetation(args: Array, config: Dictionary) -> int:
	var subtype := str(_get_value(args, config, "subtype", "flower"))
	var group_name := str(_get_value(args, config, "group", "placed_%ss" % subtype))
	var asset_path := str(_get_value(args, config, "asset_path", _get_value(args, config, "descriptor_path", "res://assets/vegetation/%s_descriptor.tres" % _to_snake_case(subtype))))

	var color := AutoAssetFactoryScript.color_from_value(
		_get_value(args, config, "color", Color(0.9, 0.35, 0.5, 0.7)),
		Color(0.9, 0.35, 0.5, 0.7)
	)
	var complexity := clampf(float(_get_value(args, config, "complexity", color.a)), 0.0, 1.0)
	var radius := float(_get_value(args, config, "radius", 0.25))
	var collision := _array_value(args, config, "collision", [])
	var descriptor := AutoAssetFactoryScript.create_voxel_descriptor(color, complexity, radius, collision)

	descriptor.set("asset_id", str(_get_value(args, config, "asset_id", subtype)))
	descriptor.set("object_type", "vegetation")
	descriptor.set("object_subtype", subtype)
	descriptor.set("scatter_min_distance", float(_get_value(args, config, "scatter_min_distance", 0.5)))
	descriptor.set("scatter_max_count", int(_get_value(args, config, "scatter_max_count", 500)))
	descriptor.set("scatter_max_scale", float(_get_value(args, config, "scatter_max_scale", 1.0)))
	descriptor.set("visual_layer", int(_get_value(args, config, "visual_layer", 14)))
	descriptor.set("group", group_name)
	var mesh_create_method := str(_get_value(args, config, "mesh_create_method", "")).strip_edges()
	if not mesh_create_method.is_empty():
		if not AutoAssetFactoryScript.is_supported_vegetation_mesh_create_method(mesh_create_method):
			push_error("Unsupported vegetation mesh_create_method: %s" % mesh_create_method)
			return ERR_INVALID_PARAMETER
		descriptor.set("mesh_create_method", mesh_create_method)

	var mesh_path := str(_get_value(args, config, "mesh", ""))
	if not mesh_path.is_empty():
		var mesh := AutoAssetFactoryScript.load_mesh(mesh_path)
		if mesh == null:
			push_error("Vegetation mesh could not be loaded: %s" % mesh_path)
			return ERR_FILE_NOT_FOUND
		descriptor.set("mesh", mesh)
		var source_mesh := AutoAssetFactoryScript.load_source_mesh(mesh_path)
		if source_mesh != null:
			descriptor.set("source_mesh", source_mesh)
		descriptor.set("source_mesh_path", mesh_path)

	descriptor.take_over_path(asset_path)
	var err := AutoAssetFactoryScript.save_resource(descriptor, asset_path)
	if err != OK:
		push_error("Failed to save vegetation AssetDescriptor: %s" % asset_path)
		return err

	print("Vegetation asset scaffolded:")
	print("  descriptor asset: %s" % asset_path)
	return OK


func _load_config_from_args(args: Array) -> Dictionary:
	var config_path := str(_arg_value(args, "--config", ""))
	if config_path.is_empty():
		return {}
	var file := FileAccess.open(config_path, FileAccess.READ)
	if file == null:
		push_error("Cannot open config: %s" % config_path)
		return {}
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("Config parse failed at line %d: %s" % [json.get_error_line(), json.get_error_message()])
		return {}
	if json.data is Dictionary:
		return json.data as Dictionary
	push_error("Config root must be a JSON object")
	return {}


func _get_value(args: Array, config: Dictionary, key: String, fallback):
	var arg = _arg_value(args, "--" + key, null)
	if arg != null:
		return arg
	if config.has(key):
		return config[key]
	return fallback


func _has_arg_or_config(args: Array, config: Dictionary, key: String) -> bool:
	return _arg_value(args, "--" + key, null) != null or config.has(key)


func _array_value(args: Array, config: Dictionary, key: String, fallback: Array) -> Array:
	var value = _get_value(args, config, key, fallback)
	if value is Array:
		return value as Array
	if value is String:
		var result: Array = []
		for part in str(value).split(",", false):
			result.append(part.strip_edges())
		return result
	return fallback


func _arg_value(args: Array, flag: String, fallback):
	for i in range(args.size()):
		if str(args[i]) == flag and i + 1 < args.size():
			return args[i + 1]
	return fallback


func _to_snake_case(value: String) -> String:
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


func _to_pascal_case(value: String) -> String:
	var result := ""
	for part in _to_snake_case(value).split("_", false):
		if part.is_empty():
			continue
		result += part.substr(0, 1).to_upper()
		if part.length() > 1:
			result += part.substr(1, part.length() - 1)
	return result


func _print_help() -> void:
	print("""
Usage:
  godot --headless --path . --script tools/scaffold_auto_asset.gd -- --config res://path/to/asset.json

Object JSON:
  {
    "type": "object",
    "asset_path": "res://assets/objects/cliff_03_asset.tscn",
    "mesh": "res://geo/cliff_03.FBX",
    "mesh_height_texture": "res://geo/cliff_03_height.raw",
    "mesh_size": 4.2,
    "color": [0.55, 0.50, 0.45, 1.0],
    "complexity": 1.0,
    "collision": [],
    "random_rotate": [0.0, 1.0],
    "random_scale": [0.8, 1.2],
    "random_height_offset": [-0.5, 0.5]
  }

Vegetation JSON:
  {
    "type": "vegetation",
    "subtype": "flower",
    "asset_path": "res://assets/vegetation/flower_descriptor.tres",
    "channel": 0,
    "radius": 0.25,
    "color": [0.9, 0.35, 0.5, 0.7],
    "complexity": 0.7,
    "collision": [],
    "scatter_min_distance": 0.35,
    "scatter_max_count": 800,
    "scatter_max_scale": 0.7,
    "visual_layer": 14,
    "group": "placed_flowers",
    "mesh_create_method": "create_sample_autoobject_mesh"
  }
""")
