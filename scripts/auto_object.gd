@tool
class_name AutoObject
extends MeshInstance3D

const AssetDescriptorScript := preload("res://scripts/asset_descriptor.gd")
const AutoVoxelProfile := preload("res://scripts/auto_voxel_profile.gd")
const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const ANCHOR_KIND := "anchor"
const INSTANCE_STAMP_WRITE_SPEC_META_KEY := "instance_stamp_write_spec"
const SELECTABLE_GROUP := "autoobject_selectable"
const SELECTABLE_META_KEY := "autoobject_selectable"

@export var auto_id: String = ""                              # 查询和调试身份
@export var instance_id: int = 0                              # MeshInstance3D instance id
@export var selectable: bool = true                           # editor/runtime ray-pick participation
@export_range(0.0, 64.0, 0.1) var selection_padding: float = 0.0 # selection AABB inflation in local units
@export var asset_descriptor: Resource                        # descriptor 持有入口，语义读取主路径
@export var voxel_color: Color = Color.WHITE                  # Inspector mirror，同步到 descriptor
@export_range(0.0, 1.0) var voxel_complexity: float = 1.0      # Inspector mirror，同步到 descriptor
@export var collision: Array = []                             # canonical input，同步到 descriptor
@export var min_spacing: float = 0.0                          # placement spacing；0 表示自动
@export var bound_min_length: float = 0.0                     # scaled bound 最小轴长
@export var source_mesh: Mesh                                 # source mesh，用于导入/重建
@export var source_mesh_path: String = ""                     # source mesh 资源路径
@export var pivot_variants: Array[Dictionary] = []            # pivot mirror，同步到 descriptor
# ⚠ auto_generate_vertical_pivots + middle/upper 阈值三个镜像已随三变体删除
# （见 AssetDescriptor.get_pivot_variants 的说明）。pivot 现在要么是作者显式写的
# pivot_variants，要么是单条零偏移 bottom。
@export var semantic_probe_generator: Resource                  # semantic probes mirror
@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0 # semantic probe 生成密度
@export_range(0.0, 8.0, 0.1) var context_sensing_radius: float = 0.0 # context probes 半径；0 禁用
@export var allowed_anchor_kinds: PackedStringArray = PackedStringArray()
@export var voxel_profile: AutoVoxelProfile                  # profile fallback，共享体素语义
@export var asset_id: String = ""                            # 资产 id，随实例配置传递
@export var mesh_height_texture: Texture2D                   # 高度图，顶视每像素高度（rock）
@export var mesh_size: float = 1.0                           # 纹理空间中尺寸（rock）
@export var random_rotate: Vector2 = Vector2(0.0, 0.0)       # 随机旋转范围（rock）
@export var random_scale: Vector2 = Vector2(1.0, 1.0)        # 随机缩放范围（rock）
@export var random_height_offset: Vector2 = Vector2(0.0, 0.0) # 随机高度偏移范围（rock）
@export var mesh_index: int = -1                             # placement result 资产索引
var instance_stamp_write_spec: Dictionary = {}                         # 当前实例写入场景体素系统的 record handle
var min_spacing_auto: bool = true                             # 是否按 bound_min_length 自动 spacing


func _ready() -> void:
	_sync_selectable_metadata()


static func create_voxel_profile(
	entry_color: Color,
	entry_complexity: float,
	default_radius: float = 0.0,
	collision: Array = []
) -> AutoVoxelProfile:
	var profile := AutoVoxelProfile.new()
	profile.color = entry_color
	profile.complexity = clampf(entry_complexity, 0.0, 1.0)
	profile.collision = VoxelGeneral.normalize_collision_samples(collision, default_radius)
	return profile


static func create_asset_descriptor(
	entry_color: Color,
	entry_complexity: float,
	default_radius: float = 0.0,
	collision: Array = [],
	pivot_variants: Array = [],
	semantic_probe_generator: Resource = null,
	semantic_probe_density: float = 1.0,
	context_sensing_radius: float = 0.0
) -> Resource:
	var profile := create_voxel_profile(entry_color, entry_complexity, default_radius, collision)
	var descriptor = AssetDescriptorScript.from_profile(profile, default_radius)
	if not pivot_variants.is_empty():
		descriptor.set_pivot_variants(pivot_variants)
	descriptor.semantic_probe_generator = semantic_probe_generator
	descriptor.semantic_probe_density = clampf(semantic_probe_density, 0.1, 8.0)
	descriptor.context_sensing_radius = maxf(context_sensing_radius, 0.0)
	return descriptor


func _ensure_asset_descriptor():
	if asset_descriptor == null:
		asset_descriptor = load("res://scripts/asset_descriptor.gd").new()
		_sync_descriptor_from_exported_fields()
	return asset_descriptor


func _sync_descriptor_from_exported_fields() -> void:
	if asset_descriptor == null:
		return
	asset_descriptor.set_color_and_complexity(voxel_color, voxel_complexity)
	if not collision.is_empty():
		asset_descriptor.set_collision(collision)
	if not pivot_variants.is_empty():
		asset_descriptor.set_pivot_variants(pivot_variants)
	asset_descriptor.semantic_probe_density = semantic_probe_density
	asset_descriptor.context_sensing_radius = context_sensing_radius
	if semantic_probe_generator != null:
		asset_descriptor.semantic_probe_generator = semantic_probe_generator


func _sync_exported_fields_from_descriptor() -> void:
	if asset_descriptor == null:
		return
	var shared_fields := SharedPropertyTypeScript.from_descriptor(asset_descriptor, bound_min_length)
	voxel_color = shared_fields.color
	voxel_complexity = float(shared_fields.complexity)
	collision = SharedPropertyTypeScript.duplicate_dictionary_array(shared_fields.get("collision", []))
	pivot_variants = asset_descriptor.pivot_variants.duplicate(true)
	semantic_probe_density = asset_descriptor.semantic_probe_density
	context_sensing_radius = asset_descriptor.context_sensing_radius
	semantic_probe_generator = asset_descriptor.semantic_probe_generator


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
			rotation_degrees = VariantUtils.vector3_from_value(config.rotation_degrees, rotation_degrees)
	else:
		var y_rotation := rotation_degrees.y
		if config.has("rotation_degrees"):
			y_rotation = VariantUtils.vector3_from_value(config.rotation_degrees, rotation_degrees).y
		rotation_degrees = Vector3(0.0, y_rotation, 0.0)


func configure_object(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_type"] = "object"
	if not cfg.has("group"):
		cfg["group"] = "placed_objects"

	if cfg.has("asset_id"):
		asset_id = str(cfg.asset_id)
	var configured_height_texture = cfg.get("mesh_height_texture", null)
	if configured_height_texture is Texture2D:
		mesh_height_texture = configured_height_texture as Texture2D
	if cfg.has("mesh_size"):
		mesh_size = maxf(float(cfg.mesh_size), 0.0)
	if cfg.has("random_rotate"):
		random_rotate = VariantUtils.vector2_from_value(cfg.random_rotate, random_rotate)
	if cfg.has("random_scale"):
		random_scale = VariantUtils.vector2_from_value(cfg.random_scale, random_scale)
	if cfg.has("random_height_offset"):
		random_height_offset = VariantUtils.vector2_from_value(cfg.random_height_offset, random_height_offset)

	var radius := mesh_size * 0.5
	_apply_voxel_profile_fallback(cfg, radius)
	_fill_config_shared_defaults(cfg, radius)

	configure_auto_object(cfg)

	if cfg.has("mesh_index"):
		mesh_index = int(cfg.mesh_index)


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
	if config.has("selectable"):
		selectable = bool(config.selectable)
	if config.has("selection_padding"):
		selection_padding = maxf(float(config.selection_padding), 0.0)

	var configured_material = config.get("material", null)
	if configured_material is Material:
		material_override = configured_material as Material

	var has_shared_config := (
		config.has("color")
		or config.has("complexity")
		or SharedPropertyTypeScript.has_collision_fields(config)
	)
	if config.has("asset_descriptor") and config.asset_descriptor is Resource:
		asset_descriptor = config.asset_descriptor
		_sync_exported_fields_from_descriptor()
	elif asset_descriptor != null:
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
		if asset_descriptor != null:
			shared_fallback = SharedPropertyTypeScript.from_descriptor(asset_descriptor, bound_min_length)
		var config_shared_fields := SharedPropertyTypeScript.normalize_shared_fields(config, shared_fallback)
		voxel_color = config_shared_fields.color
		voxel_complexity = float(config_shared_fields.complexity)
		_ensure_asset_descriptor().set_color_and_complexity(voxel_color, voxel_complexity)
		if SharedPropertyTypeScript.has_collision_fields(config):
			set_collision(config_shared_fields.collision)
	elif asset_descriptor == null:
		_ensure_asset_descriptor()
	if config.has("pivot_variants"):
		set_pivot_variants(config.pivot_variants)
	if config.has("semantic_probe_density"):
		semantic_probe_density = clampf(float(config.semantic_probe_density), 0.1, 8.0)
		_ensure_asset_descriptor().semantic_probe_density = semantic_probe_density
	if config.has("semantic_probe_generator"):
		var configured_probe_profile = config.get("semantic_probe_generator", null)
		if configured_probe_profile is Resource:
			set_semantic_probe_generator(configured_probe_profile as Resource)
	if config.has("profile_samples"):
		set_profile_samples(config.profile_samples)
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


func _apply_voxel_profile_fallback(config: Dictionary, default_radius: float) -> void:
	if not config.has("voxel_profile"):
		return
	var has_descriptor := asset_descriptor != null or config.get("asset_descriptor", null) is Resource
	var configured_profile = config.get("voxel_profile", null)
	if configured_profile is AutoVoxelProfile:
		voxel_profile = configured_profile as AutoVoxelProfile
		if not config.has("color") and not has_descriptor:
			config["color"] = voxel_profile.get_color()
		if not config.has("complexity") and not has_descriptor:
			config["complexity"] = voxel_profile.get_complexity()
		if not config.has("collision") and not has_descriptor:
			config["collision"] = voxel_profile.get_collision(default_radius)
	elif configured_profile == null:
		# 显式传 voxel_profile=null —— 合法的“清空 profile”语义。
		voxel_profile = null
	else:
		push_error("[AutoObject] %s: config.voxel_profile 类型非法（typeof=%d，期望 AutoVoxelProfile）—— 原行为把它当没配并静默清空 profile" % [name, typeof(configured_profile)])
		assert(false, "AutoObject._apply_voxel_profile_fallback: config.voxel_profile is not an AutoVoxelProfile")
		voxel_profile = null


func _fill_config_shared_defaults(config: Dictionary, default_radius: float = 0.0) -> Dictionary:
	var has_descriptor := asset_descriptor != null or config.get("asset_descriptor", null) is Resource
	var specs: Array = [
		{"key": "color", "get": func(): return get_voxel_color() if not has_descriptor else null},
		{"key": "complexity", "get": func(): return get_voxel_complexity() if not has_descriptor else null},
		{"key": "collision", "get": func(): return get_collision(default_radius) if not has_descriptor else null},
		{"key": "pivot_variants", "get": func(): return get_pivot_variants() if not has_descriptor else null},
		{"key": "semantic_probe_density", "get": func(): return semantic_probe_density if not has_descriptor else null},
		{"key": "semantic_probe_generator", "get": func(): return semantic_probe_generator if semantic_probe_generator != null and not has_descriptor else null},
		{"key": "profile_samples", "get": func(): return get_profile_samples(semantic_probe_density) if not has_descriptor else null},
	]
	return ProfileRecordSchemaScript.merge_instance_config(config, specs)


func _clear_subclass_state_mirror_metadata() -> void:
	for key in [
		"object_mesh_index",
		"object_asset_id",
		"object_mesh_size",
		"object_random_rotate",
		"object_random_scale",
		"object_random_height_offset",
	]:
		if has_meta(key):
			remove_meta(key)


func get_world_bound_size() -> Vector3:
	if mesh == null:
		return Vector3.ZERO
	var aabb := mesh.get_aabb()
	return Vector3(
		absf(aabb.size.x * scale.x),
		absf(aabb.size.y * scale.y),
		absf(aabb.size.z * scale.z)
	)


func _sync_selectable_metadata() -> void:
	set_meta(SELECTABLE_META_KEY, selectable)
	if selectable:
		add_to_group(SELECTABLE_GROUP)
	else:
		remove_from_group(SELECTABLE_GROUP)


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
	var factory_script = load("res://scripts/auto_asset_factory.gd")
	if factory_script == null:
		push_error("[AutoObject] %s: 无法加载 res://scripts/auto_asset_factory.gd —— source mesh 解析链不可用" % name)
		assert(false, "AutoObject.get_source_mesh: auto_asset_factory.gd load failed")
		return null
	return factory_script.resolve_cached_source_mesh(self, mesh, mesh)


func get_voxel_color() -> Color:
	return _ensure_asset_descriptor().get_color()


func get_voxel_complexity() -> float:
	return _ensure_asset_descriptor().get_complexity()


func get_collision(default_radius: float = 0.0) -> Array[Dictionary]:
	var radius := default_radius
	if radius <= 0.0 and mesh_size > 0.0:
		radius = mesh_size * 0.5
	return _ensure_asset_descriptor().get_collision(radius)


func get_record_object_type() -> String:
	var record_type := str(instance_stamp_write_spec.get("object_type", instance_stamp_write_spec.get("type", "")))
	return record_type if not record_type.is_empty() else "object"


func get_record_radius() -> float:
	var mesh_radius := get_xz_radius()
	if min_spacing > 0.0:
		return maxf(min_spacing, mesh_radius)
	return maxf(mesh_radius, mesh_size * 0.5)


func get_xz_radius() -> float:
	if mesh == null:
		return 0.0
	var aabb := mesh.get_aabb()
	return maxf(absf(aabb.size.x * scale.x), absf(aabb.size.z * scale.z)) * 0.5


func set_pivot_variants(variants: Array) -> void:
	pivot_variants = load("res://scripts/asset_descriptor.gd").normalize_pivot_variants(variants)
	var descriptor = _ensure_asset_descriptor()
	descriptor.set_pivot_variants(pivot_variants)
	_sync_auto_metadata()


func get_pivot_variants() -> Array[Dictionary]:
	return _ensure_asset_descriptor().get_pivot_variants()


func set_allowed_anchor_kinds(kinds) -> void:
	allowed_anchor_kinds = _normalize_anchor_kind_array(kinds)
	_sync_auto_metadata()


func set_collision(voxels: Array) -> void:
	collision = VoxelGeneral.normalize_collision_samples(voxels)
	var descriptor = _ensure_asset_descriptor()
	descriptor.set_collision(collision)
	_sync_auto_metadata()


func set_semantic_probe_generator(profile: Resource) -> void:
	semantic_probe_generator = profile
	var descriptor = _ensure_asset_descriptor()
	descriptor.semantic_probe_generator = profile
	_sync_auto_metadata()


func set_semantic_probes(probes: Array) -> void:
	var descriptor = _ensure_asset_descriptor()
	descriptor.set_semantic_probes(probes)
	semantic_probe_generator = descriptor.semantic_probe_generator
	_sync_auto_metadata()


func set_profile_samples(samples: Array) -> void:
	var descriptor = _ensure_asset_descriptor()
	descriptor.set_profile_samples(samples)
	_sync_auto_metadata()


func get_profile_samples(density_override: float = -1.0) -> Array[Dictionary]:
	return _ensure_asset_descriptor().get_profile_samples(
		mesh,
		density_override,
		Vector3.ONE,
		get_collision()
	)


func set_instance_stamp_write_spec(record: Dictionary) -> void:
	refresh_instance_id()
	instance_stamp_write_spec = record.duplicate(true)
	instance_stamp_write_spec["instance_id"] = instance_id
	if auto_id.is_empty():
		auto_id = str(instance_stamp_write_spec.get("id", name))
	if name.is_empty():
		name = auto_id
	if instance_stamp_write_spec.has("min_spacing_auto"):
		min_spacing_auto = bool(instance_stamp_write_spec.min_spacing_auto)
	if instance_stamp_write_spec.has("min_spacing"):
		min_spacing = maxf(float(instance_stamp_write_spec.min_spacing), 0.0)
		if not instance_stamp_write_spec.has("min_spacing_auto"):
			min_spacing_auto = false
	if instance_stamp_write_spec.has("bound_min_length"):
		bound_min_length = maxf(float(instance_stamp_write_spec.bound_min_length), 0.0)
	refresh_bound_spacing()
	instance_stamp_write_spec["bound_min_length"] = bound_min_length
	instance_stamp_write_spec["min_spacing"] = min_spacing
	instance_stamp_write_spec["min_spacing_auto"] = min_spacing_auto
	_sync_auto_metadata()
	set_meta(INSTANCE_STAMP_WRITE_SPEC_META_KEY, instance_stamp_write_spec)


func get_instance_stamp_write_spec() -> Dictionary:
	if instance_stamp_write_spec.is_empty():
		var meta_record := _get_instance_stamp_write_spec_metadata()
		if not meta_record.is_empty():
			set_instance_stamp_write_spec(meta_record)
	return instance_stamp_write_spec.duplicate(true)


func _get_instance_stamp_write_spec_metadata() -> Dictionary:
	if has_meta(INSTANCE_STAMP_WRITE_SPEC_META_KEY):
		var raw_record = get_meta(INSTANCE_STAMP_WRITE_SPEC_META_KEY)
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
	_sync_selectable_metadata()


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
		"semantic_probe_generator",
		"semantic_probe_count",
		"semantic_probe_density",
		"auto_source",
	]:
		if has_meta(key):
			remove_meta(key)
	_clear_subclass_state_mirror_metadata()


func _sync_record_identity_from_config(config: Dictionary) -> void:
	if config.has("auto_source"):
		instance_stamp_write_spec["auto_source"] = str(config.auto_source)
	elif config.has("placement_source"):
		instance_stamp_write_spec["auto_source"] = str(config.placement_source)
	elif config.has("source"):
		instance_stamp_write_spec["auto_source"] = str(config.source)
	if config.has("object_type"):
		instance_stamp_write_spec["object_type"] = str(config.object_type)
	elif config.has("type") and not instance_stamp_write_spec.has("object_type"):
		instance_stamp_write_spec["object_type"] = str(config.type)


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


