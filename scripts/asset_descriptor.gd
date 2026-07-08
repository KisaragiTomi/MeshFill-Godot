@tool
class_name AssetDescriptor
extends Resource
# @tool: descriptor accessor methods (get_mesh/get_collision/get_color/…) must run in
# the editor. @tool demos (placement-score-3d 等) load descriptors and call these at
# edit time; without @tool the editor gives a placeholder script instance whose methods
# don't execute, so get_mesh() 等在编辑器里返回空/失败。运行时行为不变。

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const AutoVoxelProfile := preload("res://scripts/auto_voxel_profile.gd")
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const VoxelGeneralScript := preload("res://scripts/utils/voxel_general.gd")

const FOOTPRINT_CAPACITY := 128     # footprint 体素上限，超出截断
const FLAG_SUPPORT := 1             # 保留位：支撑已在 anchor 阶段判定，当前不再烘焙 support 探针
const FLAG_CLEARANCE := 2           # 顶部净空体素标记

@export var color: Color = Color.WHITE                         # canonical 默认颜色；alpha 同步 complexity
@export_range(0.0, 1.0) var complexity: float = 1.0             # canonical 默认强度
@export var collision: Array[Dictionary] = []                   # canonical 局部 footprint sample 列表
@export var pivot_variants: Array[Dictionary] = []              # 显式 anchor/pivot 列表
@export var auto_generate_vertical_pivots: bool = false         # 从 collision 高度生成 vertical pivots
@export_range(0.0, 16.0, 0.1) var vertical_pivot_middle_min_height: float = 1.5 # middle pivot 最小高度
@export_range(0.0, 16.0, 0.1) var vertical_pivot_upper_min_height: float = 3.0 # upper pivot 最小高度
@export var semantic_probe_profile: Resource                    # 保存或生成 semantic_probes 的 profile
@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0 # 自动 probe 生成密度
@export_range(0.0, 8.0, 0.1) var context_sensing_radius: float = 0.0 # 外围 context probes 半径；0 禁用
@export var asset_id: String = ""                               # 植被资产 id / debug metadata
@export var object_type: String = ""                            # runtime grouping，不替代 descriptor 语义
@export var voxel_profile: AutoVoxelProfile                     # import-time profile source
@export var mesh: Mesh                                          # 显示 mesh
@export var source_mesh: Mesh                                   # source mesh，用于导入/重建
@export var source_mesh_path: String = ""                       # source mesh 资源路径
@export var mesh_create_method: String = ""                     # 程序化 mesh 创建方法名
@export var visual_layer: int = 0                               # 实例化时启用的显示层
@export var group: String = ""                                  # 实例化时加入的分组
@export var material: Material                                  # 实例化时应用的材质


func get_color() -> Color:
	if _should_read_profile_average():
		return voxel_profile.get_color()
	var result := color
	result.a = get_complexity()
	return result


func get_complexity() -> float:
	if _should_read_profile_average():
		return voxel_profile.get_complexity()
	return clampf(complexity, 0.0, 1.0)


func set_color_and_complexity(next_color: Color, next_complexity: float) -> void:
	complexity = clampf(next_complexity, 0.0, 1.0)
	color = next_color
	color.a = complexity


func get_collision(default_radius: float = 0.0) -> Array[Dictionary]:
	var radius := default_radius
	if not collision.is_empty():
		return VoxelGeneralScript.normalize_collision_samples(collision, radius)
	return []


func set_collision(source: Array) -> void:
	collision.clear()
	for raw in source:
		if raw is Dictionary:
			var entry := (raw as Dictionary).duplicate(true)
			collision.append(entry)


## 基于本 descriptor 的 collision 烘焙 placement/runtime footprint（get_* 派生家族的一员）。
func get_footprint(add_support: bool = true, clearance_slices: int = 1) -> Array[Dictionary]:
	return bake_footprint(get_collision(), add_support, clearance_slices)


## 从 canonical collision samples 烘焙本地体素 footprint：加 clearance slices、
## 去重、capacity 截断。仅支持 per-voxel point sample（box/cylinder primitive 已移除）。
## voxel_size 不影响 footprint 拓扑，故不作参数。
static func bake_footprint(collision_layers: Array, add_support: bool = true, clearance_slices: int = 1) -> Array[Dictionary]:
	var point_samples: Array[Dictionary] = []
	for cv in collision_layers:
		if not cv is Dictionary:
			continue
		var collision_entry := cv as Dictionary
		if not VoxelGeneralScript.is_point_collision_sample(collision_entry):
			push_warning("AssetDescriptor.bake_footprint: ignoring non-point collision entry; box/cylinder primitives are no longer supported")
			continue
		point_samples.append(collision_entry)
	var combined: Array[Dictionary] = []
	if not point_samples.is_empty():
		combined = _bake_point_collision(point_samples, add_support, clearance_slices)
	var result := _deduplicate_footprint(combined)
	if result.size() > FOOTPRINT_CAPACITY:
		# Keep validity-critical probes: put flagged (clearance) entries first so truncation
		# drops object-mass detail, not a clearance probe — losing a clearance probe would
		# flip the hard clearance_overlap validity gate rather than merely trim detail.
		result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("flags", 0)) != 0 and int(b.get("flags", 0)) == 0)
		push_warning("AssetDescriptor.bake_footprint: footprint has %d voxels, truncating to %d" % [result.size(), FOOTPRINT_CAPACITY])
		result.resize(FOOTPRINT_CAPACITY)
	return result


static func _bake_point_collision(collision_layers: Array[Dictionary], _add_support: bool, clearance_slices: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var top_by_xz := {}
	for collision_entry in collision_layers:
		if not bool(collision_entry.get("enabled", true)):
			continue
		var local_pos := VoxelGeneralScript.collision_local_voxel(collision_entry)
		var collision_strength := clampf(float(collision_entry.get("collision_strength", 1.0)), 0.0, 1.0)
		var flags := int(collision_entry.get("flags", 0))
		var weight := maxf(float(collision_entry.get("weight", 1.0)), 0.0)
		result.append({
			"local_pos": local_pos,
			"collision_strength": collision_strength,
			"flags": flags,
			"weight": weight,
		})
		if collision_strength <= 0.0:
			continue
		var key := "%d,%d" % [local_pos.x, local_pos.z]
		if not top_by_xz.has(key) or local_pos.y > int(top_by_xz[key].y):
			top_by_xz[key] = local_pos
	# Support baking is retired: the anchor/candidate stage already guarantees the object
	# rests on solid ground, so the scorer no longer re-tests support and NO FLAG_SUPPORT
	# ground probes are emitted here. `_add_support` is kept in the signature as a reserved
	# hook (the dimension design may reintroduce a support/physical mode later) but is inert.
	if clearance_slices > 0:
		for top in top_by_xz.values():
			var pos := top as Vector3i
			for cy in range(pos.y + 1, pos.y + 1 + clearance_slices):
				result.append({
					"local_pos": Vector3i(pos.x, cy, pos.z),
					"collision_strength": 0.0,
					"flags": FLAG_CLEARANCE,
					"weight": 0.5,
				})
	return result


static func _deduplicate_footprint(entries: Array[Dictionary]) -> Array[Dictionary]:
	var by_pos := {}
	for entry in entries:
		var pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var key := "%d,%d,%d" % [pos.x, pos.y, pos.z]
		if by_pos.has(key):
			var existing: Dictionary = by_pos[key]
			existing["collision_strength"] = maxf(
				float(existing.get("collision_strength", 0.0)), float(entry.get("collision_strength", 0.0)))
			existing["flags"] = int(existing.flags) | int(entry.flags)
			existing["weight"] = maxf(float(existing.weight), float(entry.weight))
		else:
			by_pos[key] = entry.duplicate()
	var result: Array[Dictionary] = []
	for entry in by_pos.values():
		result.append(entry)
	return result


func set_pivot_variants(variants: Array) -> void:
	pivot_variants = normalize_pivot_variants(variants)


func get_pivot_variants() -> Array[Dictionary]:
	if not pivot_variants.is_empty():
		return normalize_pivot_variants(pivot_variants)
	if auto_generate_vertical_pivots:
		return make_vertical_pivot_variants_from_collision(get_collision(), vertical_pivot_middle_min_height, vertical_pivot_upper_min_height)
	return [{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}]


func ensure_semantic_probe_profile() -> Resource:
	if semantic_probe_profile == null:
		semantic_probe_profile = SemanticProbeProfileScript.new()
		semantic_probe_profile.density = semantic_probe_density
	return semantic_probe_profile


func set_semantic_probes(probes: Array) -> void:
	var profile := ensure_semantic_probe_profile()
	profile.probes = SemanticProbeProfileScript.duplicate_probe_array(probes)


func get_semantic_probes(
	mesh_or_density = null,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	fallback_collision: Array = []
) -> Array[Dictionary]:
	var profile := ensure_semantic_probe_profile()
	var resolved_mesh: Mesh = null
	var resolved_density := density_override
	var resolved_world_scale := world_scale
	var resolved_fallback_collisions := fallback_collision
	if mesh_or_density is Mesh:
		resolved_mesh = mesh_or_density as Mesh
	elif mesh_or_density is float or mesh_or_density is int:
		resolved_mesh = get_mesh()
		resolved_density = float(mesh_or_density)
		resolved_world_scale = Vector3.ONE
	else:
		resolved_mesh = get_mesh()
		resolved_world_scale = Vector3.ONE
	if resolved_fallback_collisions.is_empty():
		resolved_fallback_collisions = get_collision()
	var d := semantic_probe_density if resolved_density <= 0.0 else resolved_density
	if not profile.probes.is_empty() and absf(float(profile.get("density")) - d) <= 0.001:
		return profile.get_probes()
	var collisions := get_collision()
	if collisions.is_empty():
		collisions = resolved_fallback_collisions
	return profile.rebuild_from_mesh(
		resolved_mesh,
		collisions,
		get_color(),
		get_complexity(),
		d,
		resolved_world_scale,
		context_sensing_radius
	)


func to_record_fields(default_radius: float = 0.0) -> Dictionary:
	var profile := ensure_semantic_probe_profile() if semantic_probe_profile != null else null
	var result := SharedPropertyTypeScript.from_descriptor(self, default_radius)
	result.merge({
		"pivot_variants": get_pivot_variants(),                           # runtime anchor/pivot variants
		"auto_generate_vertical_pivots": auto_generate_vertical_pivots,   # vertical pivot generation flag
		"semantic_probe_density": semantic_probe_density,                 # probe generation density
	}, true)
	if profile != null:
		result["semantic_probes"] = profile.probes.duplicate(true)        # descriptor-backed semantic probes
	return result


func get_mesh() -> Mesh:
	if mesh != null:
		return mesh
	match mesh_create_method.strip_edges():
		"create_sample_autoobject_mesh":
			return create_sample_autoobject_mesh()
		_:
			return null


static func create_sample_autoobject_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.35, 0.6, 0.35)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.70, 0.45)
	mat.roughness = 0.85
	mesh.material = mat
	return mesh


func get_source_mesh() -> Mesh:
	if not source_mesh_path.is_empty() and (source_mesh == null or source_mesh == mesh):
		var factory_script = load("res://scripts/auto_asset_factory.gd")
		var loaded_source_mesh = factory_script.load_source_mesh(source_mesh_path) if factory_script != null else null
		if loaded_source_mesh != null:
			source_mesh = loaded_source_mesh
			return source_mesh
	if source_mesh != null:
		return source_mesh
	return get_mesh()


func make_instance_config(config: Dictionary = {}) -> Dictionary:
	var cfg := config.duplicate(true)
	if not cfg.has("mesh"):
		var resolved_mesh := get_mesh()
		if resolved_mesh != null:
			cfg["mesh"] = resolved_mesh
	if not cfg.has("source_mesh"):
		var resolved_source_mesh := get_source_mesh()
		if resolved_source_mesh != null:
			cfg["source_mesh"] = resolved_source_mesh
	if not cfg.has("source_mesh_path") and not source_mesh_path.is_empty():
		cfg["source_mesh_path"] = source_mesh_path

	if not cfg.has("voxel_profile") and voxel_profile != null:
		cfg["voxel_profile"] = voxel_profile
	if not cfg.has("voxel_descriptor"):
		cfg["voxel_descriptor"] = self
	if not cfg.has("color"):
		cfg["color"] = get_color()
	if not cfg.has("complexity"):
		cfg["complexity"] = get_complexity()
	if not cfg.has("collision"):
		cfg["collision"] = get_collision()
	if not cfg.has("pivot_variants"):
		cfg["pivot_variants"] = get_pivot_variants()
	if not cfg.has("semantic_probe_density"):
		cfg["semantic_probe_density"] = semantic_probe_density
	if not cfg.has("semantic_probe_profile") and semantic_probe_profile != null:
		cfg["semantic_probe_profile"] = semantic_probe_profile
	if not cfg.has("semantic_probes"):
		cfg["semantic_probes"] = get_semantic_probes(semantic_probe_density)

	if not cfg.has("asset_id") and not asset_id.is_empty():
		cfg["asset_id"] = asset_id
	if not cfg.has("object_type"):
		cfg["object_type"] = "vegetation" if object_type.is_empty() else object_type
	if not cfg.has("visual_layer") and visual_layer > 0:
		cfg["visual_layer"] = visual_layer
	if not cfg.has("group") and not group.is_empty():
		cfg["group"] = group
	if not cfg.has("material") and material != null:
		cfg["material"] = material
	return cfg


func _should_read_profile_average() -> bool:
	return (
		voxel_profile != null
		and color == Color.WHITE
		and is_equal_approx(complexity, 1.0)
	)


static func from_profile(profile: AutoVoxelProfile, default_radius: float = 0.0) -> Resource:
	var descriptor = load("res://scripts/asset_descriptor.gd").new()
	if profile == null:
		return descriptor
	descriptor.color = profile.get_color()
	descriptor.complexity = profile.get_complexity()
	descriptor.set_collision(profile.get_collision(default_radius))
	return descriptor


static func normalize_pivot_variants(raw_variants: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i in range(raw_variants.size()):
		var raw = raw_variants[i]
		if raw is Dictionary:
			var d := (raw as Dictionary).duplicate(true)
			d["name"] = str(d.get("name", "pivot_%d" % i))
			d["offset"] = VariantUtils.vector3_from_value(d.get("offset", Vector3.ZERO), Vector3.ZERO)
			d["score_bias"] = float(d.get("score_bias", 0.0))
			result.append(d)
		elif raw is Vector3:
			result.append({"name": "pivot_%d" % i, "offset": raw as Vector3, "score_bias": 0.0})
	if result.is_empty():
		result.append({"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0})
	return result


static func make_vertical_pivot_variants_from_collision(collision: Array, middle_min_height: float = 1.5, upper_min_height: float = 3.0) -> Array[Dictionary]:
	var y_min := INF
	var y_max := -INF
	for raw_cv in collision:
		if not raw_cv is Dictionary:
			continue
		var cv := raw_cv as Dictionary
		var center := VariantUtils.vector3_from_value(cv.get("offset", cv.get("center", cv.get("position", Vector3.ZERO))), Vector3.ZERO)
		var local_min := center.y + float(cv.get("y_min", 0.0))
		var local_max := center.y + float(cv.get("y_max", local_min + 0.01))
		y_min = minf(y_min, local_min)
		y_max = maxf(y_max, local_max)
	if y_min == INF or y_max <= y_min + 0.001:
		return [{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}]
	var h := y_max - y_min
	if h < middle_min_height:
		return [{"name": "bottom", "offset": Vector3(0.0, y_min, 0.0), "score_bias": 0.0}]
	var variants: Array[Dictionary] = [
		{"name": "bottom", "offset": Vector3(0.0, y_min, 0.0), "score_bias": 0.05},
		{"name": "middle", "offset": Vector3(0.0, y_min + h * 0.5, 0.0), "score_bias": 0.0},
	]
	if h >= upper_min_height:
		variants.append({"name": "upper", "offset": Vector3(0.0, y_min + h * 0.8, 0.0), "score_bias": -0.05})
	return variants
