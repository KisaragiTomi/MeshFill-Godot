class_name AutoObject
extends MeshInstance3D

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const AutoVoxelDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")
const ANCHOR_KIND_GROUND := "ground"
const ANCHOR_KIND_TARGET_TOP := "target_top"

@export var auto_id: String = ""
@export var instance_id: int = 0
@export var auto_source: String = "generated"
@export var object_type: String = "object"
@export var object_subtype: String = ""
@export var visual_layer: int = 0
@export var voxel_descriptor: Resource
@export var voxel_color: Color = Color.WHITE
@export_range(0.0, 1.0) var voxel_complexity: float = 1.0
@export var min_spacing: float = 0.0
@export var bound_min_length: float = 0.0
@export var source_mesh: Mesh
@export var source_mesh_path: String = ""
@export var affected_bands: Array[Dictionary] = []
@export var collision_voxels: Array[Dictionary] = []
@export var pivot_variants: Array[Dictionary] = []
@export var auto_generate_vertical_pivots: bool = false
@export_range(0.0, 16.0, 0.1) var vertical_pivot_middle_min_height: float = 1.5
@export_range(0.0, 16.0, 0.1) var vertical_pivot_upper_min_height: float = 3.0
@export var semantic_probe_profile: Resource
@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0
@export_range(0.0, 8.0, 0.1) var context_sensing_radius: float = 0.0
@export var allowed_anchor_kinds: PackedStringArray = PackedStringArray()
var voxel_record: Dictionary = {}
var min_spacing_auto: bool = true


func _ensure_voxel_descriptor():
	if voxel_descriptor == null:
		voxel_descriptor = load("res://scripts/auto_voxel_descriptor.gd").new()
		_sync_descriptor_from_legacy_fields()
	return voxel_descriptor


func _sync_descriptor_from_legacy_fields() -> void:
	if voxel_descriptor == null:
		return
	voxel_descriptor.set_color_and_complexity(voxel_color, voxel_complexity)
	if not affected_bands.is_empty():
		voxel_descriptor.set_affected_bands(affected_bands)
	if not collision_voxels.is_empty():
		voxel_descriptor.set_collision_voxels(collision_voxels)
	if not pivot_variants.is_empty():
		voxel_descriptor.set_pivot_variants(pivot_variants)
	voxel_descriptor.auto_generate_vertical_pivots = auto_generate_vertical_pivots
	voxel_descriptor.vertical_pivot_middle_min_height = vertical_pivot_middle_min_height
	voxel_descriptor.vertical_pivot_upper_min_height = vertical_pivot_upper_min_height
	voxel_descriptor.semantic_probe_density = semantic_probe_density
	voxel_descriptor.context_sensing_radius = context_sensing_radius
	if semantic_probe_profile != null:
		voxel_descriptor.semantic_probe_profile = semantic_probe_profile


func _sync_legacy_fields_from_descriptor() -> void:
	if voxel_descriptor == null:
		return
	voxel_color = voxel_descriptor.get_color()
	voxel_complexity = voxel_descriptor.get_complexity()
	affected_bands = voxel_descriptor.affected_bands.duplicate(true)
	collision_voxels = voxel_descriptor.collision_voxels.duplicate(true)
	pivot_variants = voxel_descriptor.pivot_variants.duplicate(true)
	auto_generate_vertical_pivots = voxel_descriptor.auto_generate_vertical_pivots
	vertical_pivot_middle_min_height = voxel_descriptor.vertical_pivot_middle_min_height
	vertical_pivot_upper_min_height = voxel_descriptor.vertical_pivot_upper_min_height
	semantic_probe_density = voxel_descriptor.semantic_probe_density
	context_sensing_radius = voxel_descriptor.context_sensing_radius
	semantic_probe_profile = voxel_descriptor.semantic_probe_profile


func _vector3_from_config_value(value, fallback: Vector3) -> Vector3:
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


func _rotation_mode_from_config(config: Dictionary) -> String:
	var mode := str(config.get("rotation_mode", ""))
	if mode.is_empty():
		mode = "XYZ" if config.has("rotation_degrees") or config.has("rotation_xyz") else "Y"
	mode = mode.to_upper()
	return "XYZ" if mode == "XYZ" else "Y"


func _apply_config_rotation(config: Dictionary) -> void:
	if not config.has("rotation_mode") and not config.has("rotation_y") and not config.has("rotation_degrees") and not config.has("rotation_xyz"):
		return
	var mode := _rotation_mode_from_config(config)
	if mode == "XYZ":
		if config.has("rotation_degrees"):
			rotation_degrees = _vector3_from_config_value(config.rotation_degrees, rotation_degrees)
		elif config.has("rotation_xyz"):
			rotation_degrees = _vector3_from_config_value(config.rotation_xyz, rotation_degrees)
		elif config.has("rotation_y"):
			var next_rotation := rotation_degrees
			next_rotation.y = float(config.rotation_y)
			rotation_degrees = next_rotation
	else:
		var y_rotation := rotation_degrees.y
		if config.has("rotation_y"):
			y_rotation = float(config.rotation_y)
		elif config.has("rotation_degrees"):
			y_rotation = _vector3_from_config_value(config.rotation_degrees, rotation_degrees).y
		elif config.has("rotation_xyz"):
			y_rotation = _vector3_from_config_value(config.rotation_xyz, rotation_degrees).y
		rotation_degrees = Vector3(0.0, y_rotation, 0.0)


func configure_auto_object(config: Dictionary) -> void:
	refresh_instance_id()
	if config.has("id"):
		auto_id = str(config.id)
	if config.has("auto_source"):
		auto_source = str(config.auto_source)
	elif config.has("placement_source"):
		auto_source = str(config.placement_source)
	elif config.has("source"):
		auto_source = str(config.source)
	if config.has("object_type"):
		object_type = str(config.object_type)
	if config.has("object_subtype"):
		object_subtype = str(config.object_subtype)

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
	if config.has("min_spacing") or config.has("minimum_spacing"):
		min_spacing = maxf(float(config.get("min_spacing", config.get("minimum_spacing", 0.0))), 0.0)
		min_spacing_auto = min_spacing <= 0.0

	if config.has("visual_layer"):
		set_visual_layer(int(config.visual_layer))

	var configured_material = config.get("material", null)
	if configured_material is Material:
		material_override = configured_material as Material

	if config.has("voxel_descriptor") and config.voxel_descriptor is Resource:
		voxel_descriptor = config.voxel_descriptor
		_sync_legacy_fields_from_descriptor()
	if config.has("color"):
		voxel_color = config.color
	if config.has("complexity"):
		voxel_complexity = clampf(float(config.complexity), 0.0, 1.0)
	voxel_color.a = voxel_complexity
	_ensure_voxel_descriptor().set_color_and_complexity(voxel_color, voxel_complexity)

	if config.has("affected_bands"):
		set_affected_bands(config.affected_bands)
	if config.has("collision_voxels"):
		set_collision_voxels(config.collision_voxels)
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
	_sync_descriptor_from_legacy_fields()

	var configured_group := str(config.get("group", ""))
	if not configured_group.is_empty():
		add_to_group(configured_group)
	var configured_groups: Array = config.get("groups", [])
	for group_name in configured_groups:
		add_to_group(str(group_name))

	_sync_auto_metadata()


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


func set_visual_layer(layer_number: int) -> void:
	visual_layer = layer_number
	if visual_layer > 0:
		set_layer_mask_value(visual_layer, true)
	_sync_auto_metadata()


func get_voxel_color() -> Color:
	return _ensure_voxel_descriptor().get_color()


func get_voxel_complexity() -> float:
	return _ensure_voxel_descriptor().get_complexity()


func get_affected_bands(default_radius: float = 1.0) -> Array[Dictionary]:
	return _ensure_voxel_descriptor().get_affected_bands(default_radius)


func get_collision_voxels(default_radius: float = 0.0) -> Array[Dictionary]:
	return _ensure_voxel_descriptor().get_collision_voxels(default_radius)


func set_affected_bands(bands: Array) -> void:
	affected_bands.clear()
	for band in bands:
		if band is Dictionary:
			affected_bands.append((band as Dictionary).duplicate(true))
	var descriptor = _ensure_voxel_descriptor()
	descriptor.set_affected_bands(affected_bands)
	_sync_auto_metadata()


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
	return _derive_allowed_anchor_kinds_from_pivots()


func accepts_anchor_kind(anchor_kind: String) -> bool:
	var normalized := _canonical_anchor_kind(anchor_kind)
	if normalized.is_empty():
		return false
	return get_allowed_anchor_kinds().has(normalized)


func get_anchor_pivot_variant(anchor_kind: String = ANCHOR_KIND_GROUND) -> Dictionary:
	var pivots := get_pivot_variants()
	if pivots.is_empty():
		return {"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}
	var normalized := _canonical_anchor_kind(anchor_kind)
	var best: Dictionary = {}
	if normalized == ANCHOR_KIND_TARGET_TOP:
		for raw_pivot in pivots:
			var pivot := raw_pivot as Dictionary
			var name := str(pivot.get("name", "")).to_lower()
			if ["upper", "top", "high"].has(name):
				return pivot
		for raw_pivot in pivots:
			var pivot := raw_pivot as Dictionary
			var name := str(pivot.get("name", "")).to_lower()
			if ["middle", "mid", "center", "centre"].has(name):
				return pivot
		var best_y := -INF
		for raw_pivot in pivots:
			var pivot := raw_pivot as Dictionary
			var offset := _vector3_from_config_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)
			if offset.y > best_y:
				best_y = offset.y
				best = pivot
		return best
	for raw_pivot in pivots:
		var pivot := raw_pivot as Dictionary
		var name := str(pivot.get("name", "")).to_lower()
		if ["bottom", "ground", "base", "foot", "root"].has(name):
			return pivot
	var best_y := INF
	for raw_pivot in pivots:
		var pivot := raw_pivot as Dictionary
		var offset := _vector3_from_config_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)
		if offset.y < best_y:
			best_y = offset.y
			best = pivot
	return best


func get_anchor_pivot_offset(anchor_kind: String = ANCHOR_KIND_GROUND) -> Vector3:
	var pivot := get_anchor_pivot_variant(anchor_kind)
	return _vector3_from_config_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)


func get_anchor_relative_footprint_aabb(anchor_kind: String = ANCHOR_KIND_GROUND) -> AABB:
	var local_aabb := _collision_local_aabb()
	if local_aabb.size.length_squared() <= 0.0001 and mesh != null:
		local_aabb = mesh.get_aabb()
	var pivot_offset := get_anchor_pivot_offset(anchor_kind)
	return AABB(local_aabb.position - pivot_offset, local_aabb.size)


func set_collision_voxels(voxels: Array) -> void:
	collision_voxels.clear()
	for voxel in voxels:
		if voxel is Dictionary:
			collision_voxels.append((voxel as Dictionary).duplicate(true))
	var descriptor = _ensure_voxel_descriptor()
	descriptor.set_collision_voxels(collision_voxels)
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
		descriptor.affected_bands,
		descriptor.collision_voxels,
		descriptor.get_color(),
		descriptor.get_complexity(),
		density_override,
		Vector3.ONE,
		descriptor.context_sensing_radius
	)
	semantic_probe_profile = descriptor.semantic_probe_profile
	_sync_auto_metadata()
	return probes


func get_semantic_probes(density_override: float = -1.0, anchor_kind: String = ANCHOR_KIND_GROUND) -> Array[Dictionary]:
	var probes = _ensure_voxel_descriptor().get_semantic_probes(
		mesh,
		density_override,
		Vector3.ONE,
		affected_bands,
		collision_voxels
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


func set_voxel_record(record: Dictionary) -> void:
	refresh_instance_id()
	voxel_record = record.duplicate(true)
	if voxel_record.has("voxel_layers") and not voxel_record.has("SenceLayerVoxel"):
		voxel_record["SenceLayerVoxel"] = voxel_record.voxel_layers
	voxel_record.erase("voxel_layers")
	if voxel_record.has("rotation_y") and not voxel_record.has("rotation_degrees"):
		voxel_record["rotation_mode"] = str(voxel_record.get("rotation_mode", "Y")).to_upper()
		voxel_record["rotation_degrees"] = Vector3(0.0, float(voxel_record.rotation_y), 0.0)
	voxel_record.erase("rotation_y")
	voxel_record.erase("rotation_xyz")
	voxel_record["instance_id"] = instance_id
	if auto_id.is_empty():
		auto_id = str(voxel_record.get("id", name))
	if name.is_empty():
		name = auto_id
	voxel_record["auto_id"] = auto_id
	voxel_record["auto_object_id"] = auto_id
	voxel_record["auto_instance_id"] = instance_id
	var mesh_instance_id := int(voxel_record.get("instance_mesh_id", voxel_record.get("mesh_instance_id", instance_id)))
	voxel_record["instance_mesh_id"] = mesh_instance_id
	voxel_record["mesh_instance_id"] = mesh_instance_id
	if voxel_record.has("type"):
		object_type = str(voxel_record.type)
	if voxel_record.has("auto_source"):
		auto_source = str(voxel_record.auto_source)
	elif voxel_record.has("placement_source"):
		auto_source = str(voxel_record.placement_source)
	if voxel_record.has("color"):
		voxel_color = voxel_record.color
	if voxel_record.has("complexity"):
		voxel_complexity = clampf(float(voxel_record.complexity), 0.0, 1.0)
	voxel_color.a = voxel_complexity
	_ensure_voxel_descriptor().set_color_and_complexity(voxel_color, voxel_complexity)
	if voxel_record.has("min_spacing_auto"):
		min_spacing_auto = bool(voxel_record.min_spacing_auto)
	if voxel_record.has("min_spacing"):
		min_spacing = maxf(float(voxel_record.min_spacing), 0.0)
		if not voxel_record.has("min_spacing_auto"):
			min_spacing_auto = false
	if voxel_record.has("bound_min_length"):
		bound_min_length = maxf(float(voxel_record.bound_min_length), 0.0)
	if voxel_record.has("affected_bands"):
		set_affected_bands(voxel_record.affected_bands)
	if voxel_record.has("collision_voxels"):
		set_collision_voxels(voxel_record.collision_voxels)
	if voxel_record.has("pivot_variants"):
		set_pivot_variants(voxel_record.pivot_variants)
	if voxel_record.has("auto_generate_vertical_pivots"):
		auto_generate_vertical_pivots = bool(voxel_record.auto_generate_vertical_pivots)
		_ensure_voxel_descriptor().auto_generate_vertical_pivots = auto_generate_vertical_pivots
	if voxel_record.has("semantic_probe_density"):
		semantic_probe_density = clampf(float(voxel_record.semantic_probe_density), 0.1, 8.0)
		_ensure_voxel_descriptor().semantic_probe_density = semantic_probe_density
	if voxel_record.has("semantic_probes"):
		set_semantic_probes(voxel_record.semantic_probes)
	if voxel_record.has("allowed_anchor_kinds"):
		set_allowed_anchor_kinds(voxel_record.allowed_anchor_kinds)
	_sync_descriptor_from_legacy_fields()
	refresh_bound_spacing()
	voxel_record["bound_min_length"] = bound_min_length
	voxel_record["min_spacing"] = min_spacing
	voxel_record["min_spacing_auto"] = min_spacing_auto
	var descriptor_fields = _ensure_voxel_descriptor().to_record_fields(bound_min_length)
	for key in descriptor_fields:
		voxel_record[key] = descriptor_fields[key]
	_sync_auto_metadata()
	set_meta("voxel_record", voxel_record)


func get_voxel_record() -> Dictionary:
	return voxel_record.duplicate(true)


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
	set_meta("instance_mesh_id", int(voxel_record.get("instance_mesh_id", instance_id)))
	set_meta("auto_source", auto_source)
	set_meta("auto_object_type", object_type)
	set_meta("auto_object_subtype", object_subtype)
	if semantic_probe_profile != null:
		set_meta("semantic_probe_profile", semantic_probe_profile)
		set_meta("semantic_probe_count", semantic_probe_profile.probes.size())
		set_meta("semantic_probe_density", semantic_probe_density)
	set_meta("pivot_variant_count", get_pivot_variants().size())
	set_meta("allowed_anchor_kinds", get_allowed_anchor_kinds())


func _clear_state_mirror_metadata() -> void:
	for key in [
		"bound_min_length",
		"min_spacing",
		"min_spacing_auto",
		"voxel_color",
		"voxel_complexity",
		"auto_affected_bands",
		"auto_collision_voxels",
		"pivot_variant_count",
		"allowed_anchor_kinds",
		"semantic_probe_profile",
		"semantic_probe_count",
		"semantic_probe_density",
	]:
		if has_meta(key):
			remove_meta(key)


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
	if ["ground", "bottom", "base", "foot", "root"].has(k):
		return ANCHOR_KIND_GROUND
	if ["target_top", "top", "upper", "high", "middle", "mid", "center", "centre"].has(k):
		return ANCHOR_KIND_TARGET_TOP
	return ""


func _derive_allowed_anchor_kinds_from_pivots() -> PackedStringArray:
	var result := PackedStringArray()
	var pivots := get_pivot_variants()
	if pivots.is_empty():
		result.append(ANCHOR_KIND_GROUND)
		return result
	var y_min := INF
	var y_max := -INF
	for raw_pivot in pivots:
		var pivot := raw_pivot as Dictionary
		var offset := _vector3_from_config_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)
		y_min = minf(y_min, offset.y)
		y_max = maxf(y_max, offset.y)
	for raw_pivot in pivots:
		var pivot := raw_pivot as Dictionary
		var kind := _anchor_kind_from_pivot(pivot, y_min, y_max)
		if not kind.is_empty() and result.find(kind) < 0:
			result.append(kind)
	if result.is_empty():
		result.append(ANCHOR_KIND_GROUND)
	return result


func _anchor_kind_from_pivot(pivot: Dictionary, y_min: float, y_max: float) -> String:
	var name_kind := _canonical_anchor_kind(str(pivot.get("name", "")))
	if not name_kind.is_empty():
		return name_kind
	var offset := _vector3_from_config_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)
	if y_max > y_min + 0.0001 and offset.y >= lerpf(y_min, y_max, 0.45):
		return ANCHOR_KIND_TARGET_TOP
	return ANCHOR_KIND_GROUND


func _collision_local_aabb() -> AABB:
	var collisions := get_collision_voxels(bound_min_length)
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
