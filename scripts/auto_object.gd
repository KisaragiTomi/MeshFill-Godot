class_name AutoObject
extends MeshInstance3D

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const AutoVoxelDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const ANCHOR_KIND := "anchor"
const INSTANCE_STAMP_WRITE_SPEC_META_KEY := "instance_stamp_write_spec"
const VOXEL_WRITE_SPEC_META_KEY := "voxel_write_spec"

@export var auto_id: String = ""                              # 查询和调试身份
@export var instance_id: int = 0                              # MeshInstance3D instance id
@export var voxel_descriptor: Resource                        # descriptor 持有入口，语义读取主路径
@export var voxel_color: Color = Color.WHITE                  # Inspector mirror，同步到 descriptor
@export_range(0.0, 1.0) var voxel_complexity: float = 1.0      # Inspector mirror，同步到 descriptor
@export var collision: Array[Dictionary] = []                 # canonical input，同步到 descriptor
@export var min_spacing: float = 0.0                          # placement spacing；0 表示自动
@export var bound_min_length: float = 0.0                     # scaled bound 最小轴长
@export var source_mesh: Mesh                                 # source mesh，用于导入/重建
@export var source_mesh_path: String = ""                     # source mesh 资源路径
@export var pivot_variants: Array[Dictionary] = []            # pivot mirror，同步到 descriptor
@export var auto_generate_vertical_pivots: bool = false       # 从 collision 高度生成 vertical pivots
@export_range(0.0, 16.0, 0.1) var vertical_pivot_middle_min_height: float = 1.5 # middle pivot 最小高度
@export_range(0.0, 16.0, 0.1) var vertical_pivot_upper_min_height: float = 3.0 # upper pivot 最小高度
@export var semantic_probe_profile: Resource                  # semantic probes mirror
@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0 # semantic probe 生成密度
@export_range(0.0, 8.0, 0.1) var context_sensing_radius: float = 0.0 # context probes 半径；0 禁用
@export var allowed_anchor_kinds: PackedStringArray = PackedStringArray()
@export var voxel_profile: AutoVoxelProfile                  # profile fallback，共享体素语义
var voxel_write_spec: Dictionary = {}                         # 当前实例写入场景体素系统的 record handle
var min_spacing_auto: bool = true                             # 是否按 bound_min_length 自动 spacing


static func voxel_write_spec_meta_keys() -> Array:
	return [INSTANCE_STAMP_WRITE_SPEC_META_KEY, VOXEL_WRITE_SPEC_META_KEY]


static func vector2_from_value(value, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value as Vector2
	if value is Vector2i:
		var vi := value as Vector2i
		return Vector2(float(vi.x), float(vi.y))
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
	if value is Vector3i:
		var vi := value as Vector3i
		return Vector3(float(vi.x), float(vi.y), float(vi.z))
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


static func create_voxel_profile(
	entry_color: Color,
	entry_complexity: float,
	default_radius: float = 0.0,
	collision: Array = []
) -> AutoVoxelProfile:
	var profile := AutoVoxelProfile.new()
	profile.color = entry_color
	profile.complexity = clampf(entry_complexity, 0.0, 1.0)
	profile.collision = AutoVoxelDescriptorScript.normalize_collision(collision, default_radius)
	return profile


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
	var profile := create_voxel_profile(entry_color, entry_complexity, default_radius, collision)
	var descriptor = AutoVoxelDescriptorScript.from_profile(profile, default_radius)
	if not pivot_variants.is_empty():
		descriptor.set_pivot_variants(pivot_variants)
	descriptor.semantic_probe_profile = semantic_probe_profile
	descriptor.semantic_probe_density = clampf(semantic_probe_density, 0.1, 8.0)
	descriptor.context_sensing_radius = maxf(context_sensing_radius, 0.0)
	return descriptor


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
	var shared_fields := SharedPropertyTypeScript.from_profile(profile, default_radius, collision_override)
	var color: Color = shared_fields.color
	var complexity := float(shared_fields.complexity)

	var source_type := str(extra_fields.get("source_voxel_type", "AutoSceneVoxel"))

	var record := SharedPropertyTypeScript.apply_to_record(extra_fields, shared_fields)
	record["id"] = record_id                            # record id / debug handle
	record["type"] = object_type                        # runtime object type/group
	record["position"] = position                       # instance world position
	record["rotation_mode"] = "XYZ"                     # rotation_degrees interpretation
	record["rotation_degrees"] = rotation_degrees       # instance rotation
	record["scale"] = scale                             # instance scale
	record["base_pixel"] = base_pixel                   # placement base XZ pixel
	record["voxel_xz"] = base_pixel
	record["volume_xz_resolution"] = volume_xz_resolution # source volume XZ resolution
	if not record.has("channel") and object_type == "rock":
		record["channel"] = 0
	if record.has("channel"):
		record["channel"] = int(record.channel)
		if not record.has("radius"):
			record["radius"] = default_radius
		if not record.has("y_min"):
			record["y_min"] = y_min
		if not record.has("y_max"):
			record["y_max"] = y_max
	record["source_voxel_type"] = source_type           # AutoSceneVoxel / BrushSceneVoxel / TargetSceneVoxel
	return record


func _ensure_voxel_descriptor():
	if voxel_descriptor == null:
		voxel_descriptor = load("res://scripts/auto_voxel_descriptor.gd").new()
		_sync_descriptor_from_exported_fields()
	return voxel_descriptor


func _sync_descriptor_from_exported_fields() -> void:
	if voxel_descriptor == null:
		return
	voxel_descriptor.set_color_and_complexity(voxel_color, voxel_complexity)
	if not collision.is_empty():
		voxel_descriptor.set_collision(collision)
	if not pivot_variants.is_empty():
		voxel_descriptor.set_pivot_variants(pivot_variants)
	voxel_descriptor.auto_generate_vertical_pivots = auto_generate_vertical_pivots
	voxel_descriptor.vertical_pivot_middle_min_height = vertical_pivot_middle_min_height
	voxel_descriptor.vertical_pivot_upper_min_height = vertical_pivot_upper_min_height
	voxel_descriptor.semantic_probe_density = semantic_probe_density
	voxel_descriptor.context_sensing_radius = context_sensing_radius
	if semantic_probe_profile != null:
		voxel_descriptor.semantic_probe_profile = semantic_probe_profile


func _sync_exported_fields_from_descriptor() -> void:
	if voxel_descriptor == null:
		return
	var shared_fields := SharedPropertyTypeScript.from_descriptor(voxel_descriptor, bound_min_length)
	voxel_color = shared_fields.color
	voxel_complexity = float(shared_fields.complexity)
	collision = SharedPropertyTypeScript.duplicate_dictionary_array(shared_fields.get("collision", []))
	pivot_variants = voxel_descriptor.pivot_variants.duplicate(true)
	auto_generate_vertical_pivots = voxel_descriptor.auto_generate_vertical_pivots
	vertical_pivot_middle_min_height = voxel_descriptor.vertical_pivot_middle_min_height
	vertical_pivot_upper_min_height = voxel_descriptor.vertical_pivot_upper_min_height
	semantic_probe_density = voxel_descriptor.semantic_probe_density
	context_sensing_radius = voxel_descriptor.context_sensing_radius
	semantic_probe_profile = voxel_descriptor.semantic_probe_profile


func _vector3_from_config_value(value, fallback: Vector3) -> Vector3:
	return AutoObject.vector3_from_value(value, fallback)


func _rotation_mode_from_config(config: Dictionary) -> String:
	var mode := str(config.get("rotation_mode", ""))
	if mode.is_empty():
		mode = "XYZ" if config.has("rotation_degrees") else "Y"
	mode = mode.to_upper()
	return "XYZ" if mode == "XYZ" else "Y"


func _apply_config_rotation(config: Dictionary) -> void:
	if not config.has("rotation_mode") and not config.has("rotation_degrees"):
		return
	var mode := _rotation_mode_from_config(config)
	if mode == "XYZ":
		if config.has("rotation_degrees"):
			rotation_degrees = _vector3_from_config_value(config.rotation_degrees, rotation_degrees)
	else:
		var y_rotation := rotation_degrees.y
		if config.has("rotation_degrees"):
			y_rotation = _vector3_from_config_value(config.rotation_degrees, rotation_degrees).y
		rotation_degrees = Vector3(0.0, y_rotation, 0.0)


func configure_auto_object(config: Dictionary) -> void:
	refresh_instance_id()
	if config.has("id"):
		auto_id = str(config.id)
	_sync_record_identity_from_config(config)

	var configured_name := str(config.get("name", ""))
	if not configured_name.is_empty():
		name = configured_name
	elif not auto_id.is_empty():
		name = auto_id
	if auto_id.is_empty():
		auto_id = name

	var configured_mesh = config.get("mesh", null)
	if configured_mesh is Mesh:
		mesh = configured_mesh as Mesh
	var configured_source_mesh = config.get("source_mesh", null)
	if configured_source_mesh is Mesh:
		source_mesh = configured_source_mesh as Mesh
	var configured_source_mesh_path := str(config.get("source_mesh_path", ""))
	if not configured_source_mesh_path.is_empty():
		source_mesh_path = configured_source_mesh_path

	if config.has("position"):
		position = config.position
	scale = Vector3.ONE
	_apply_config_rotation(config)
	if config.has("min_spacing"):
		min_spacing = maxf(float(config.get("min_spacing", 0.0)), 0.0)
		min_spacing_auto = min_spacing <= 0.0

	if config.has("visual_layer"):
		var configured_visual_layer := int(config.visual_layer)
		if configured_visual_layer > 0:
			set_layer_mask_value(configured_visual_layer, true)

	var configured_material = config.get("material", null)
	if configured_material is Material:
		material_override = configured_material as Material

	var has_shared_config := (
		config.has("color")
		or config.has("complexity")
		or SharedPropertyTypeScript.has_collision_fields(config)
	)
	if config.has("voxel_descriptor") and config.voxel_descriptor is Resource:
		voxel_descriptor = config.voxel_descriptor
		_sync_exported_fields_from_descriptor()
	elif voxel_descriptor != null:
		_sync_exported_fields_from_descriptor()
	if has_shared_config:
		if config.has("color"):
			voxel_color = config.color
		if config.has("complexity"):
			voxel_complexity = clampf(float(config.complexity), 0.0, 1.0)
		var shared_fallback := {
			"color": voxel_color,
			"complexity": voxel_complexity,
			"collision": collision,
		}
		if voxel_descriptor != null:
			shared_fallback = SharedPropertyTypeScript.from_descriptor(voxel_descriptor, bound_min_length)
		var config_shared_fields := SharedPropertyTypeScript.normalize_shared_fields(config, shared_fallback)
		voxel_color = config_shared_fields.color
		voxel_complexity = float(config_shared_fields.complexity)
		_ensure_voxel_descriptor().set_color_and_complexity(voxel_color, voxel_complexity)
		if SharedPropertyTypeScript.has_collision_fields(config):
			set_collision(config_shared_fields.collision)
	elif voxel_descriptor == null:
		_ensure_voxel_descriptor()
	if config.has("pivot_variants"):
		set_pivot_variants(config.pivot_variants)
	if config.has("auto_generate_vertical_pivots"):
		auto_generate_vertical_pivots = bool(config.auto_generate_vertical_pivots)
		_ensure_voxel_descriptor().auto_generate_vertical_pivots = auto_generate_vertical_pivots
	if config.has("semantic_probe_density"):
		semantic_probe_density = clampf(float(config.semantic_probe_density), 0.1, 8.0)
		_ensure_voxel_descriptor().semantic_probe_density = semantic_probe_density
	if config.has("semantic_probe_profile"):
		var configured_probe_profile = config.get("semantic_probe_profile", null)
		if configured_probe_profile is Resource:
			set_semantic_probe_profile(configured_probe_profile as Resource)
	if config.has("semantic_probes"):
		set_semantic_probes(config.semantic_probes)
	if config.has("allowed_anchor_kinds"):
		set_allowed_anchor_kinds(config.allowed_anchor_kinds)
	_sync_descriptor_from_exported_fields()

	var configured_group := str(config.get("group", ""))
	if not configured_group.is_empty():
		add_to_group(configured_group)
	var configured_groups: Array = config.get("groups", [])
	for group_name in configured_groups:
		add_to_group(str(group_name))

	_sync_auto_metadata()


func configure_asset(config: Dictionary) -> void:
	configure_auto_object(config)


func _apply_voxel_profile_fallback(config: Dictionary, default_radius: float) -> void:
	if not config.has("voxel_profile"):
		return
	var has_descriptor := voxel_descriptor != null or config.get("voxel_descriptor", null) is Resource
	var configured_profile = config.get("voxel_profile", null)
	if configured_profile is AutoVoxelProfile:
		voxel_profile = configured_profile as AutoVoxelProfile
		if not config.has("color") and not has_descriptor:
			config["color"] = voxel_profile.get_color()
		if not config.has("complexity") and not has_descriptor:
			config["complexity"] = voxel_profile.get_complexity()
		if not config.has("collision") and not has_descriptor:
			config["collision"] = voxel_profile.get_collision(default_radius)
	else:
		voxel_profile = null


func _fill_config_shared_defaults(config: Dictionary, default_radius: float = 0.0) -> Dictionary:
	var has_descriptor := voxel_descriptor != null or config.get("voxel_descriptor", null) is Resource
	if not config.has("color") and not has_descriptor:
		config["color"] = get_voxel_color()
	if not config.has("complexity") and not has_descriptor:
		config["complexity"] = get_voxel_complexity()
	if not config.has("collision") and not has_descriptor:
		config["collision"] = get_collision(default_radius)
	if not config.has("pivot_variants") and not has_descriptor:
		config["pivot_variants"] = get_pivot_variants()
	if not config.has("semantic_probe_density") and not has_descriptor:
		config["semantic_probe_density"] = semantic_probe_density
	if not config.has("semantic_probe_profile") and semantic_probe_profile != null and not has_descriptor:
		config["semantic_probe_profile"] = semantic_probe_profile
	if not config.has("semantic_probes") and not has_descriptor:
		config["semantic_probes"] = get_semantic_probes(semantic_probe_density)
	return config


func _clear_subclass_state_mirror_metadata() -> void:
	pass


func make_instance_config(config: Dictionary = {}) -> Dictionary:
	var cfg := config.duplicate(true)
	if not cfg.has("mesh"):
		cfg["mesh"] = mesh
	if not cfg.has("source_mesh") and get_source_mesh() != null and get_source_mesh() != mesh:
		cfg["source_mesh"] = get_source_mesh()
	if not cfg.has("source_mesh_path") and not source_mesh_path.is_empty():
		cfg["source_mesh_path"] = source_mesh_path
	if not cfg.has("voxel_profile") and voxel_profile != null:
		cfg["voxel_profile"] = voxel_profile
	return _fill_config_shared_defaults(cfg, get_record_radius())


func get_world_bound_size() -> Vector3:
	if mesh == null:
		return Vector3.ZERO
	var aabb := mesh.get_aabb()
	return Vector3(
		absf(aabb.size.x * scale.x),
		absf(aabb.size.y * scale.y),
		absf(aabb.size.z * scale.z)
	)


func compute_bound_min_length() -> float:
	var world_size := get_world_bound_size()
	var result := INF
	for axis_length in [world_size.x, world_size.y, world_size.z]:
		var length_value := float(axis_length)
		if length_value > 0.0001:
			result = minf(result, length_value)
	return 0.0 if result == INF else result


func refresh_bound_spacing() -> void:
	bound_min_length = compute_bound_min_length()
	if min_spacing_auto:
		min_spacing = bound_min_length * 0.5


func get_source_mesh() -> Mesh:
	if not source_mesh_path.is_empty() and (source_mesh == null or source_mesh == mesh):
		var loaded_source_mesh := AutoAssetFactory.load_source_mesh(source_mesh_path)
		if loaded_source_mesh != null:
			source_mesh = loaded_source_mesh
			return source_mesh
	if source_mesh != null:
		return source_mesh
	return mesh


func get_axis_center_xz() -> Vector2:
	return Vector2(global_position.x, global_position.z)


func get_required_axis_center_distance_to(other: AutoObject) -> float:
	if other == null:
		return min_spacing
	return min_spacing + other.min_spacing


func is_axis_center_too_close_to(other: AutoObject) -> bool:
	if other == null:
		return false
	var required_distance := get_required_axis_center_distance_to(other)
	return get_axis_center_xz().distance_to(other.get_axis_center_xz()) < required_distance


func get_voxel_color() -> Color:
	return _ensure_voxel_descriptor().get_color()


func get_voxel_complexity() -> float:
	return _ensure_voxel_descriptor().get_complexity()


func get_collision(default_radius: float = 0.0) -> Array[Dictionary]:
	return _ensure_voxel_descriptor().get_collision(default_radius)


func get_record_object_type() -> String:
	var record_type := str(voxel_write_spec.get("type", voxel_write_spec.get("object_type", "")))
	return record_type if not record_type.is_empty() else "object"


func get_record_object_subtype() -> String:
	return str(voxel_write_spec.get("object_subtype", ""))


func get_record_auto_source(fallback: String = "generated") -> String:
	var source := str(voxel_write_spec.get("auto_source", voxel_write_spec.get("placement_source", voxel_write_spec.get("source", ""))))
	return source if not source.is_empty() else fallback


func get_record_radius() -> float:
	var mesh_radius := get_xz_radius()
	if min_spacing > 0.0:
		return maxf(min_spacing, mesh_radius)
	return mesh_radius


func get_xz_radius() -> float:
	if mesh == null:
		return 0.0
	var aabb := mesh.get_aabb()
	return maxf(absf(aabb.size.x * scale.x), absf(aabb.size.z * scale.z)) * 0.5


func get_record_y_bounds() -> Vector2:
	if mesh == null:
		return Vector2(position.y, position.y)
	var aabb := mesh.get_aabb()
	var y0 := position.y + aabb.position.y * scale.y
	var y1 := position.y + (aabb.position.y + aabb.size.y) * scale.y
	return Vector2(minf(y0, y1), maxf(y0, y1))


func make_voxel_profile(default_radius: float = -1.0) -> AutoVoxelProfile:
	var radius := get_record_radius() if default_radius < 0.0 else default_radius
	var color := get_voxel_color()
	var complexity := get_voxel_complexity()
	color.a = complexity
	return AutoObject.create_voxel_profile(
		color,
		complexity,
		radius,
		get_collision(radius)
	)


func get_voxel_write_spec_extra_fields(extra_fields: Dictionary = {}) -> Dictionary:
	return extra_fields.duplicate(true)


func make_voxel_write_spec(
	record_id: String,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	var radius := get_record_radius()
	var bounds_y := get_record_y_bounds()
	return AutoObject.make_profile_voxel_write_spec(
		record_id,
		get_record_object_type(),
		position,
		rotation_degrees,
		scale,
		base_pixel,
		volume_xz_resolution,
		make_voxel_profile(radius),
		radius,
		bounds_y.x,
		bounds_y.y,
		[],
		get_voxel_write_spec_extra_fields(extra_fields)
	)

func make_instance_stamp_write_spec(
	record_id: String,
	base_pixel: Vector2i,
	volume_xz_resolution: int,
	extra_fields: Dictionary = {}
) -> Dictionary:
	return make_voxel_write_spec(record_id, base_pixel, volume_xz_resolution, extra_fields)


func set_pivot_variants(variants: Array) -> void:
	pivot_variants = load("res://scripts/auto_voxel_descriptor.gd").normalize_pivot_variants(variants)
	var descriptor = _ensure_voxel_descriptor()
	descriptor.set_pivot_variants(pivot_variants)
	_sync_auto_metadata()


func get_pivot_variants() -> Array[Dictionary]:
	return _ensure_voxel_descriptor().get_pivot_variants()


func set_allowed_anchor_kinds(kinds) -> void:
	allowed_anchor_kinds = _normalize_anchor_kind_array(kinds)
	_sync_auto_metadata()


func get_allowed_anchor_kinds() -> PackedStringArray:
	var explicit := _normalize_anchor_kind_array(allowed_anchor_kinds)
	if not explicit.is_empty():
		return explicit
	var result := PackedStringArray()
	result.append(ANCHOR_KIND)
	return result


func accepts_anchor_kind(anchor_kind: String) -> bool:
	var normalized := _canonical_anchor_kind(anchor_kind)
	if normalized.is_empty():
		return false
	return normalized == ANCHOR_KIND


func get_anchor_pivot_variant(anchor_kind: String = ANCHOR_KIND) -> Dictionary:
	var pivots := get_pivot_variants()
	if pivots.is_empty():
		return {"name": "anchor", "offset": Vector3.ZERO, "score_bias": 0.0}
	var best: Dictionary = {}
	for raw_pivot in pivots:
		var pivot := raw_pivot as Dictionary
		var name := str(pivot.get("name", "")).to_lower()
		if ["anchor", "primary", "pivot", "bottom", "ground", "base", "foot", "root"].has(name):
			return pivot
	var best_y := INF
	for raw_pivot in pivots:
		var pivot := raw_pivot as Dictionary
		var offset := _vector3_from_config_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)
		if offset.y < best_y:
			best_y = offset.y
			best = pivot
	return best


func get_anchor_pivot_offset(anchor_kind: String = ANCHOR_KIND) -> Vector3:
	var pivot := get_anchor_pivot_variant(anchor_kind)
	return _vector3_from_config_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)


func get_anchor_relative_footprint_aabb(anchor_kind: String = ANCHOR_KIND) -> AABB:
	var local_aabb := _collision_local_aabb()
	if local_aabb.size.length_squared() <= 0.0001 and mesh != null:
		local_aabb = mesh.get_aabb()
	var pivot_offset := get_anchor_pivot_offset(anchor_kind)
	return AABB(local_aabb.position - pivot_offset, local_aabb.size)


func set_collision(voxels: Array) -> void:
	collision = AutoVoxelDescriptorScript.normalize_collision(voxels)
	var descriptor = _ensure_voxel_descriptor()
	descriptor.set_collision(collision)
	_sync_auto_metadata()


func set_semantic_probe_profile(profile: Resource) -> void:
	semantic_probe_profile = profile
	var descriptor = _ensure_voxel_descriptor()
	descriptor.semantic_probe_profile = profile
	_sync_auto_metadata()


func set_semantic_probes(probes: Array) -> void:
	var descriptor = _ensure_voxel_descriptor()
	descriptor.set_semantic_probes(probes)
	semantic_probe_profile = descriptor.semantic_probe_profile
	_sync_auto_metadata()


func rebuild_semantic_probes(density_override: float = -1.0) -> Array[Dictionary]:
	var descriptor = _ensure_voxel_descriptor()
	var profile = descriptor.ensure_semantic_probe_profile()
	var probes: Array[Dictionary] = profile.rebuild_from_mesh(
		mesh,
		descriptor.get_collision(),
		descriptor.get_color(),
		descriptor.get_complexity(),
		density_override,
		Vector3.ONE,
		descriptor.context_sensing_radius
	)
	semantic_probe_profile = descriptor.semantic_probe_profile
	_sync_auto_metadata()
	return probes


func get_semantic_probes(density_override: float = -1.0, anchor_kind: String = ANCHOR_KIND) -> Array[Dictionary]:
	var probes = _ensure_voxel_descriptor().get_semantic_probes(
		mesh,
		density_override,
		Vector3.ONE,
		get_collision()
	)
	var pivot_offset := get_anchor_pivot_offset(anchor_kind)
	if pivot_offset.length_squared() <= 0.000001:
		return probes
	var remapped: Array[Dictionary] = []
	for raw_probe in probes:
		var probe = raw_probe.duplicate(true)
		var offset := SemanticProbeProfileScript.vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
		probe["offset"] = offset - pivot_offset
		remapped.append(SemanticProbeProfileScript.normalize_probe(probe))
	return remapped


func _ensure_semantic_probe_profile() -> Resource:
	var descriptor = _ensure_voxel_descriptor()
	descriptor.semantic_probe_density = semantic_probe_density
	semantic_probe_profile = descriptor.ensure_semantic_probe_profile()
	return semantic_probe_profile


func _get_default_semantic_probe_radius() -> float:
	var world_size := get_world_bound_size()
	var radius := maxf(world_size.x, world_size.z) * 0.5
	return maxf(radius, 0.5)


func set_voxel_write_spec(record: Dictionary) -> void:
	refresh_instance_id()
	voxel_write_spec = record.duplicate(true)
	voxel_write_spec["instance_id"] = instance_id
	if auto_id.is_empty():
		auto_id = str(voxel_write_spec.get("id", name))
	if name.is_empty():
		name = auto_id
	voxel_write_spec["auto_id"] = auto_id
	voxel_write_spec["auto_object_id"] = auto_id
	voxel_write_spec["auto_instance_id"] = instance_id
	var mesh_instance_id := int(voxel_write_spec.get("instance_mesh_id", voxel_write_spec.get("mesh_instance_id", instance_id)))
	voxel_write_spec["instance_mesh_id"] = mesh_instance_id
	voxel_write_spec["mesh_instance_id"] = mesh_instance_id
	if voxel_write_spec.has("min_spacing_auto"):
		min_spacing_auto = bool(voxel_write_spec.min_spacing_auto)
	if voxel_write_spec.has("min_spacing"):
		min_spacing = maxf(float(voxel_write_spec.min_spacing), 0.0)
		if not voxel_write_spec.has("min_spacing_auto"):
			min_spacing_auto = false
	if voxel_write_spec.has("bound_min_length"):
		bound_min_length = maxf(float(voxel_write_spec.bound_min_length), 0.0)
	refresh_bound_spacing()
	voxel_write_spec["bound_min_length"] = bound_min_length
	voxel_write_spec["min_spacing"] = min_spacing
	voxel_write_spec["min_spacing_auto"] = min_spacing_auto
	_sync_auto_metadata()
	set_meta(INSTANCE_STAMP_WRITE_SPEC_META_KEY, voxel_write_spec)
	set_meta(VOXEL_WRITE_SPEC_META_KEY, voxel_write_spec)


func get_voxel_write_spec() -> Dictionary:
	if voxel_write_spec.is_empty():
		var meta_record := _get_voxel_write_spec_metadata()
		if not meta_record.is_empty():
			set_voxel_write_spec(meta_record)
	return voxel_write_spec.duplicate(true)

func set_instance_stamp_write_spec(record: Dictionary) -> void:
	set_voxel_write_spec(record)

func get_instance_stamp_write_spec() -> Dictionary:
	return get_voxel_write_spec()


func _get_voxel_write_spec_metadata() -> Dictionary:
	for key in voxel_write_spec_meta_keys():
		if not has_meta(key):
			continue
		var raw_record = get_meta(key)
		if raw_record is Dictionary:
			return (raw_record as Dictionary).duplicate(true)
	return {}


func refresh_instance_id() -> int:
	instance_id = int(get_instance_id())
	set_meta("instance_id", instance_id)
	return instance_id


func _sync_auto_metadata() -> void:
	refresh_instance_id()
	refresh_bound_spacing()
	_clear_state_mirror_metadata()
	set_meta("auto_id", auto_id)
	set_meta("auto_instance_id", instance_id)
	set_meta("instance_mesh_id", int(voxel_write_spec.get("instance_mesh_id", instance_id)))


func _clear_state_mirror_metadata() -> void:
	for key in [
		"bound_min_length",
		"min_spacing",
		"min_spacing_auto",
		"voxel_color",
		"voxel_complexity",
		"auto_collision",
		"pivot_variant_count",
		"allowed_anchor_kinds",
		"semantic_probe_profile",
		"semantic_probe_count",
		"semantic_probe_density",
		"auto_source",
	]:
		if has_meta(key):
			remove_meta(key)
	_clear_subclass_state_mirror_metadata()


func _sync_record_identity_from_config(config: Dictionary) -> void:
	if config.has("auto_source"):
		voxel_write_spec["auto_source"] = str(config.auto_source)
	elif config.has("placement_source"):
		voxel_write_spec["auto_source"] = str(config.placement_source)
	elif config.has("source"):
		voxel_write_spec["auto_source"] = str(config.source)
	if config.has("object_type"):
		var configured_type := str(config.object_type)
		voxel_write_spec["type"] = configured_type
		voxel_write_spec["object_type"] = configured_type
	elif config.has("type") and not voxel_write_spec.has("type"):
		var configured_record_type := str(config.type)
		voxel_write_spec["type"] = configured_record_type
		voxel_write_spec["object_type"] = configured_record_type
	if config.has("object_subtype"):
		voxel_write_spec["object_subtype"] = str(config.object_subtype)


func _normalize_anchor_kind_array(kinds) -> PackedStringArray:
	var result := PackedStringArray()
	var source: Array = []
	if kinds is PackedStringArray:
		for kind in kinds:
			source.append(kind)
	elif kinds is Array:
		source = kinds
	elif kinds is String:
		source = [kinds]
	for raw_kind in source:
		var normalized := _canonical_anchor_kind(str(raw_kind))
		if normalized.is_empty():
			continue
		if result.find(normalized) < 0:
			result.append(normalized)
	return result


func _canonical_anchor_kind(anchor_kind: String) -> String:
	var k := anchor_kind.strip_edges().to_lower()
	if k.is_empty():
		return ""
	if ["anchor", "default", "position", "position_only", "ground", "bottom", "base", "foot", "root", "target_top", "top", "upper", "high", "middle", "mid", "center", "centre"].has(k):
		return ANCHOR_KIND
	return ""


func _collision_local_aabb() -> AABB:
	var collisions := get_collision(bound_min_length)
	var has_bounds := false
	var min_p := Vector3(INF, INF, INF)
	var max_p := Vector3(-INF, -INF, -INF)
	for raw_collision in collisions:
		if not raw_collision is Dictionary:
			continue
		var collision := raw_collision as Dictionary
		var bounds := _collision_bounds(collision)
		if bounds.size.length_squared() <= 0.000001:
			continue
		min_p.x = minf(min_p.x, bounds.position.x)
		min_p.y = minf(min_p.y, bounds.position.y)
		min_p.z = minf(min_p.z, bounds.position.z)
		max_p.x = maxf(max_p.x, bounds.position.x + bounds.size.x)
		max_p.y = maxf(max_p.y, bounds.position.y + bounds.size.y)
		max_p.z = maxf(max_p.z, bounds.position.z + bounds.size.z)
		has_bounds = true
	if not has_bounds:
		return AABB()
	return AABB(min_p, max_p - min_p)


func _collision_bounds(collision: Dictionary) -> AABB:
	if collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset"):
		var voxel_pos := _vector3_from_config_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3.ZERO))), Vector3.ZERO)
		return AABB(voxel_pos - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
	var shape := str(collision.get("shape", collision.get("collision_shape", "cylinder"))).to_lower()
	var center := _vector3_from_config_value(collision.get("offset", collision.get("center", collision.get("position", Vector3.ZERO))), Vector3.ZERO)
	if shape == "box" or shape == "cube":
		var half_extents := _vector3_from_config_value(collision.get("half_extents", Vector3.ZERO), Vector3.ZERO)
		if half_extents.length_squared() <= 0.0001:
			var size := _vector3_from_config_value(collision.get("size", Vector3.ZERO), Vector3.ZERO)
			if size.length_squared() > 0.0001:
				half_extents = size * 0.5
		if half_extents.length_squared() <= 0.0001:
			var radius := maxf(float(collision.get("radius", 0.0)), 0.0)
			var y_min := float(collision.get("y_min", 0.0))
			var y_max := float(collision.get("y_max", 0.0))
			half_extents = Vector3(radius, maxf(y_max - y_min, 0.0) * 0.5, radius)
		var min_p := center - half_extents
		var max_p := center + half_extents
		if collision.has("y_min") or collision.has("y_max"):
			min_p.y = center.y + float(collision.get("y_min", min_p.y - center.y))
			max_p.y = center.y + float(collision.get("y_max", max_p.y - center.y))
		return AABB(min_p, max_p - min_p)
	var r := maxf(float(collision.get("radius", 0.0)), 0.0)
	var ymin := float(collision.get("y_min", 0.0))
	var ymax := float(collision.get("y_max", 0.0))
	var cyl_min := center + Vector3(-r, ymin, -r)
	var cyl_max := center + Vector3(r, ymax, r)
	return AABB(cyl_min, cyl_max - cyl_min)
