class_name VoxelPlacementOutput

## placement 结果 → 世界坐标/节点/写规格 的纯静态转换与实例化(从 VoxelPlacementGenerator 抽出)。
extends RefCounted

const AutoObject := preload("res://scripts/auto_object.gd")

const TILE_SIZE := 8
const FOOTPRINT_CAPACITY := 128
const RECORD_STRIDE := 4
const DELTA_STRIDE := 2
const STAMP_BOUNDS_STRIDE := 2
const FLAG_SUPPORT := 1
const FLAG_CLEARANCE := 2
const NUM_DEBUG_CHANNELS := 8
const ACCEPTED_PLACEMENT_SOURCE_BUFFER_INCOMPLETE_REASON := "incomplete_source_candidate_handoff_missing_payload_and_group_index_buffers"
const SCORE_CONTRACT_DEBUG_WORDS := 48
const SCORE_CONTRACT_MAGIC := 0x4D465052 # MFPR: MeshFill placement runtime/profile.
const CANDIDATE_ROUTE_BINDING_DEBUG_WORDS := 16
const CANDIDATE_ROUTE_ADAPTER_COUNT_WORDS := 4
const CANDIDATE_ROUTE_INDIRECT_ARGS_BYTES := 12
const CANDIDATE_ROUTE_SPARSE_ADAPTER_LOCAL_SIZE := 64
const BOX_FOOTPRINT_BAKE_SHADER_PATH := "res://shaders/bake_box_footprint.glsl"
const BOX_FOOTPRINT_BAKE_LOCAL_SIZE := 64
const CYLINDER_FOOTPRINT_BAKE_SHADER_PATH := "res://shaders/bake_cylinder_footprint.glsl"
const CYLINDER_FOOTPRINT_BAKE_LOCAL_SIZE := 64
const ROTATE_FOOTPRINT_Y_SHADER_PATH := "res://shaders/rotate_footprint_y.glsl"
const ROTATE_FOOTPRINT_Y_LOCAL_SIZE := 64
const GPU_RUNTIME_PROVIDER_CONFIG_KEYS := [
	"gpu_autoobject_runtime",
	"autoobject_runtime",
	"runtime",
]
const GPU_PROFILE_CONTAINER_CONFIG_KEYS := [
	"auto_voxel_runtime_profile_container",
	"runtime_profile_container",
	"profile_container",
]
const SCENE_PLACEMENT_ACTOR_CONFIG_KEYS := [
	"scene_placement_actor",
	"placement_actor",
	"spa",
]
const CANDIDATE_REGION_BY_ASSET_CONFIG_KEYS := [
	"candidate_voxel_regions_by_asset",
	"candidate_voxel_sparses_by_asset",
]
const CANDIDATE_ROUTE_CONTRACT_SCHEMA_VERSION := 1
const CANDIDATE_ROUTE_RECORD_STRIDE_BYTES := 16
const CANDIDATE_ROUTE_RANGE_STRIDE_BYTES := 16
const ASSET_CANDIDATE_REGION_CONFIG_KEYS := [
	"candidate_voxel_regions",
	"candidate_voxel_sparses",
]
const REQUIRED_GPU_RUNTIME_BUFFERS := [
	"alive",
	"generation",
	"type",
	"profile",
	"bounds_min",
	"bounds_max",
	"previous_bounds_min",
	"previous_bounds_max",
	"transform",
]
const REQUIRED_GPU_PROFILE_BUFFERS := [
	"profile_table",
	"probe_records",
	"pivot_records",
]
const DEBUG_CHANNEL_NAMES: PackedStringArray = [
	"target_coverage",
	"target_complexity_fit",
	"target_color_fit",
	"target_density",
	"placement_score",
	"support_ratio",
	"solid_collision",
	"clearance_overlap",
]
const SCORE_CONTRACT_DEBUG_NAMES: PackedStringArray = [
	"magic",
	"contract_enabled",
	"runtime_object_capacity",
	"profile_count",
	"alive_object_reads",
	"profile_records_matched",
	"runtime_overlap_tests",
	"runtime_overlap_hits",
	"profile_table_reads",
	"asset_profile_id",
	"candidate_invocations",
	"profile_complexity_q1000",
	"runtime_profile_reads",
	"runtime_profile_matches",
	"probe_record_reads",
	"reserved_profile_side_read",
	"pivot_record_reads",
	"probe_weight_q1000",
	"reserved_profile_side_metric",
	"pivot_bias_q1000",
	"profile_probe_count",
	"reserved_profile_side_count",
	"profile_pivot_count",
	"debug_max_target_coverage_q1000",
	"debug_max_target_complexity_fit_q1000",
	"debug_max_target_color_fit_q1000",
	"debug_max_target_density_q1000",
	"debug_max_placement_score_q1000",
	"debug_max_support_ratio_q1000",
	"debug_max_solid_collision_q1000",
	"debug_max_clearance_overlap_q1000",
	"runtime_spacing_tests",
	"runtime_spacing_profile_matches",
	"runtime_spacing_rejections",
	"runtime_spacing_min_distance_q1000",
	"scene_voxel_tile_object_ref_enabled",
	"scene_voxel_tile_object_ref_tile_reads",
	"scene_voxel_tile_object_ref_slot_reads",
	"scene_voxel_tile_object_ref_object_reads",
	"scene_voxel_tile_object_ref_duplicate_reads",
	"reserved40",
	"reserved41",
	"reserved42",
	"reserved43",
	"reserved44",
	"reserved45",
	"reserved46",
	"reserved47",
]
const SCENE_VOXEL_COMMITTER_CONFIG_KEY := "scene_voxel_committer"
const SCENE_VOXEL_TILE_COMMITTER_CONFIG_KEYS := [
	SCENE_VOXEL_COMMITTER_CONFIG_KEY,
	"sv_committer",
	"scene_voxel_tile_committer",
]
const SCENE_VOXEL_TILE_OBJECT_REF_BUFFER_NAME := "scene_voxel_tile_object_refs"
const SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_NUMERIC := "u32_numeric_ref_key_v1"
const SCENE_VOXEL_TILE_OBJECT_REF_STRIDE_BYTES := 4
const SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT := 8
const PREVIOUS_SCENE_VOXEL_COMMITTER_CONFIG_KEY := "vegetation" + "_exclusion"
const STAGE_SCENE_VOXEL_SOURCE_CANDIDATES_CONFIG_KEY := "stage_scene_voxel_source_candidates_to_resident_buffers"
const VOXEL_WRITE_SPEC_CONFIG_KEYS := [
	"asset",
	"base_pixel",
	"capture_size",
	"create_voxel_write_spec",
	"defer_blend",
	"generation_tick",
	"grid_origin",
	"grid_size",
	"group",
	"groups",
	"material",
	"mesh",
	"name",
	"placement_mesh",
	"record_id",
	SCENE_VOXEL_COMMITTER_CONFIG_KEY,
	"texture_resolution",
	PREVIOUS_SCENE_VOXEL_COMMITTER_CONFIG_KEY,
	"voxel_size",
	"volume_xz_resolution",
	AutoObject.INSTANCE_STAMP_WRITE_SPEC_META_KEY,
	"voxel_write_spec",
	"world_capture_size",
]
const SCENE_VOXEL_SOURCE_WRITE_DIAGNOSTIC_KEYS := [
	"source_write_handoff_mode",
	"source_write_batch_api",
	"cpu_pending_source_candidate_bridge",
	"pending_source_candidate_flush_api",
	"source_candidate_resolve_api",
	"resident_source_write_buffer",
	"resident_source_write_buffer_owner",
	"resident_source_write_buffer_rid",
	"resident_source_write_buffer_lifetime",
	"resident_source_write_buffer_stride_bytes",
	"resident_source_write_buffer_range_count",
	"resident_source_candidate_buffer_rid",
	"resident_source_candidate_buffer_stride_bytes",
	"resident_source_candidate_buffer_capacity",
	"resident_source_candidate_buffer_count",
	"resident_source_range_buffer_rid",
	"resident_source_range_buffer_stride_bytes",
	"resident_source_range_buffer_capacity",
	"resident_source_range_buffer_count",
	"resident_source_candidate_staging_epoch",
	"runtime_read_source",
	"final_source_stream_resident",
	"final_source_stream_resident_source",
	"resident_gpu_allocator_writeback",
	"resident_gpu_allocator_writeback_mode",
]


## --- 复制自 generator 的辅助 ---


static func _get_config_voxel_write_spec(config: Dictionary) -> Dictionary:
	for key in AutoObject.voxel_write_spec_meta_keys():
		var raw_record = config.get(key, {})
		if raw_record is Dictionary:
			var record := raw_record as Dictionary
			if not record.is_empty():
				return record.duplicate(true)
	return {}





static func _vector3_from_value(value, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var d := value as Dictionary
		return Vector3(float(d.get("x", fallback.x)), float(d.get("y", fallback.y)), float(d.get("z", fallback.z)))
	return fallback





static func _scene_placement_actor_from_config(config: Dictionary) -> Object:
	for key in SCENE_PLACEMENT_ACTOR_CONFIG_KEYS:
		if not config.has(key):
			continue
		var value = config.get(key)
		if value is Object:
			return value as Object
	return null



## --- 迁移自 generator 的 placement 输出/实例化函数 ---
static func instantiate_placement(
	world_result: Dictionary,
	node_class: String,
	placement_mesh: Mesh,
	extra_config: Dictionary = {},
	parent: Node = null
) -> AutoObject:
	var node: AutoObject = _create_node_for_class(node_class)
	var cfg := extra_config.duplicate(true)

	cfg["position"] = world_result.get("position", Vector3.ZERO)
	cfg["rotation_mode"] = "Y"
	cfg["rotation_degrees"] = world_result.get("rotation_degrees", Vector3.ZERO)
	cfg["scale"] = world_result.get("scale", Vector3.ONE)
	cfg["mesh"] = placement_mesh
	if not cfg.has("auto_source"):
		cfg["auto_source"] = "voxel_placement"

	if not cfg.has("name"):
		cfg["name"] = "%s_%d" % [node_class, int(world_result.get("asset_index", 0))]

	var asset = cfg.get("asset", null)
	if node is AutoObject and asset is AutoObject:
		(node as AutoObject).configure_from_asset(asset as AutoObject, cfg)
	else:
		_configure_node(node, node_class, cfg)

	if parent != null and node.get_parent() == null:
		parent.add_child(node)

	var record := _get_config_voxel_write_spec(cfg)
	if not record.is_empty():
		record = attach_placement_voxel_write_spec(node, record)
	elif bool(cfg.get("create_voxel_write_spec", false)):
		record = make_placement_voxel_write_spec(node, world_result, node_class, cfg)
		if not record.is_empty():
			record = attach_placement_voxel_write_spec(node, record)

	var target = cfg.get(SCENE_VOXEL_COMMITTER_CONFIG_KEY, cfg.get(PREVIOUS_SCENE_VOXEL_COMMITTER_CONFIG_KEY, null))
	if not record.is_empty() and target != null and target.has_method("apply_voxel_write_spec"):
		var apply_method := "apply_voxel_write_spec"
		var applied: Dictionary = target.call(
			apply_method,
			record,
			bool(cfg.get("defer_blend", false)),
			int(cfg.get("generation_tick", -1))
		)
		if not applied.is_empty():
			attach_placement_voxel_write_spec(node, applied)
	var spa_owner := _scene_placement_actor_from_config(cfg)
	if spa_owner != null and spa_owner.has_method("own_autoobject"):
		var asset_id := int(world_result.get("asset_index", cfg.get("asset_index", -1)))
		spa_owner.call("own_autoobject", node, asset_id)
	return node



static func instantiate_placements(
	world_results: Array,
	node_class: String,
	placement_mesh: Mesh,
	extra_config: Dictionary = {},
	parent: Node = null
) -> Array[AutoObject]:
	var nodes: Array[AutoObject] = []
	for i in range(world_results.size()):
		var cfg := extra_config.duplicate(true)
		cfg["name"] = "%s_%d" % [node_class, i]
		var node := instantiate_placement(world_results[i], node_class, placement_mesh, cfg, parent)
		nodes.append(node)
	return nodes



static func make_placement_voxel_write_spec(
	node: AutoObject,
	world_result: Dictionary,
	node_class: String,
	record_config: Dictionary = {}
) -> Dictionary:
	if node == null:
		return {}

	var resolution := maxi(int(record_config.get("volume_xz_resolution", record_config.get("texture_resolution", 256))), 1)
	var capture := float(record_config.get("capture_size", record_config.get("world_capture_size", float(resolution))))
	if capture <= 0.0:
		capture = float(resolution)
	var base_px := _placement_base_pixel(world_result, record_config, capture, resolution)
	var record_id := str(record_config.get("record_id", record_config.get("id", node.name)))
	if record_id.is_empty():
		record_id = "%s_%d" % [node_class, int(world_result.get("asset_index", 0))]

	var fields := _placement_record_extra_fields(node, world_result, node_class, record_config)
	var record := node.make_instance_stamp_write_spec(
		record_id,
		base_px,
		resolution,
		fields
	)
	record["rotation_mode"] = str(world_result.get("rotation_mode", record_config.get("rotation_mode", "Y"))).to_upper()
	record["rotation_degrees"] = world_result.get("rotation_degrees", node.rotation_degrees)
	record["mesh_name"] = node.name
	return record



static func attach_placement_voxel_write_spec(node: AutoObject, record: Dictionary) -> Dictionary:
	if node == null or record.is_empty():
		return {}
	var rec := record.duplicate(true)
	node.refresh_bound_spacing()
	var instance_id := node.refresh_instance_id()
	var record_id := str(rec.get("id", node.name))
	if record_id.is_empty():
		record_id = node.name
	rec["id"] = record_id
	rec["mesh_name"] = node.name
	rec["position"] = node.position
	rec["scale"] = node.scale
	rec["rotation_degrees"] = rec.get("rotation_degrees", node.rotation_degrees)
	rec["instance_id"] = instance_id
	rec["auto_instance_id"] = instance_id
	if node.auto_id.is_empty():
		node.auto_id = record_id
	rec["auto_id"] = node.auto_id
	rec["auto_object_id"] = node.auto_id
	rec["instance_mesh_id"] = instance_id
	rec["mesh_instance_id"] = instance_id
	if not rec.has("auto_source"):
		rec["auto_source"] = node.get_record_auto_source("voxel_placement")
	if not rec.has("object_type"):
		rec["object_type"] = node.get_record_object_type()
	if node.is_inside_tree():
		rec["node_path"] = str(node.get_path())
	node.set_instance_stamp_write_spec(rec)
	return node.get_instance_stamp_write_spec()



static func world_to_texture_pixel(
	world_pos: Vector3,
	capture_size: float,
	resolution: int
) -> Vector2i:
	return VoxelGeneral.world_to_texture_pixel(world_pos, capture_size, resolution)



static func world_to_volume_pixel(
	world_pos: Vector3,
	resolution: int,
	p_grid_origin: Vector3,
	p_voxel_size: Vector3
) -> Vector2i:
	return VoxelGeneral.world_to_volume_pixel(world_pos, resolution, p_grid_origin, p_voxel_size)



static func _placement_base_pixel(
	world_result: Dictionary,
	record_config: Dictionary,
	capture_size: float,
	resolution: int
) -> Vector2i:
	var raw_base = record_config.get("base_pixel", world_result.get("base_pixel", null))
	if raw_base is Vector2i:
		return raw_base as Vector2i
	if raw_base is Vector2:
		var v := raw_base as Vector2
		return Vector2i(roundi(v.x), roundi(v.y))
	if raw_base is Array:
		var arr := raw_base as Array
		if arr.size() >= 2:
			return Vector2i(int(arr[0]), int(arr[1]))
	var world_pos: Vector3 = world_result.get("position", Vector3.ZERO)
	var target = record_config.get(SCENE_VOXEL_COMMITTER_CONFIG_KEY, record_config.get(PREVIOUS_SCENE_VOXEL_COMMITTER_CONFIG_KEY, null))
	if target != null and target.has_method("world_to_volume_pixel"):
		return target.call("world_to_volume_pixel", world_pos, resolution)
	if record_config.has("grid_origin") or record_config.has("voxel_size"):
		var fallback_voxel_size := VoxelGeneral.voxel_size_for_resolution(capture_size, resolution, 1.0)
		var fallback_grid_origin := VoxelGeneral.default_grid_origin(capture_size)
		return world_to_volume_pixel(
			world_pos,
			resolution,
			_vector3_from_value(record_config.get("grid_origin", fallback_grid_origin), fallback_grid_origin),
			_vector3_from_value(record_config.get("voxel_size", fallback_voxel_size), fallback_voxel_size)
		)
	return world_to_texture_pixel(world_pos, capture_size, resolution)



static func _placement_record_extra_fields(
	node: AutoObject,
	world_result: Dictionary,
	node_class: String,
	record_config: Dictionary
) -> Dictionary:
	var fields := {}
	for key in record_config.keys():
		if VOXEL_WRITE_SPEC_CONFIG_KEYS.has(key) or AutoObject.voxel_write_spec_meta_keys().has(key):
			continue
		fields[key] = record_config[key]

	fields["auto_source"] = str(record_config.get("auto_source", node.get_record_auto_source("voxel_placement")))
	fields["placement_source"] = "voxel_placement"
	fields["source_voxel_type"] = str(record_config.get("source_voxel_type", "AutoSceneVoxel"))
	fields["object_subtype"] = node_class
	fields["asset_index"] = int(world_result.get("asset_index", record_config.get("asset_index", 0)))
	fields["rotation_index"] = int(world_result.get("rotation_index", record_config.get("rotation_index", 0)))
	fields["scale_index"] = int(world_result.get("scale_index", record_config.get("scale_index", 0)))
	fields["voxel_origin"] = world_result.get("voxel_origin", Vector3i.ZERO)

	for debug_key in [
		"score",
		"support_ratio",
		"solid_collision",
		"complexity_overlap",
		"clearance_overlap",
		"ignored_sample",
	]:
		if world_result.has(debug_key):
			fields[debug_key] = world_result[debug_key]
	if node is AutoObject:
		fields["mesh_index"] = int((node as AutoObject).mesh_index)
	return fields



static func _create_node_for_class(node_class: String) -> AutoObject:
	match node_class:
		"rock", "cliff":
			return AutoObject.new()
		_:
			return AutoObject.new()



static func _configure_node(node: AutoObject, node_class: String, cfg: Dictionary) -> void:
	match node_class:
		"rock", "cliff":
			(node as AutoObject).configure_object(cfg)
		_:
			node.configure_auto_object(cfg)



static func results_to_world(
	results: Array[Dictionary],
	voxel_size: Vector3,
	grid_origin: Vector3,
	rotation_count: int = 24,
	pivot_variant: Dictionary = {}
) -> Array[Dictionary]:
	var world_results: Array[Dictionary] = []
	for r in results:
		if not bool(r.get("valid", false)):
			continue
		var origin: Vector3i = r.get("voxel_origin", Vector3i.ZERO)
		var rot_idx := int(r.get("rotation_index", 0))
		var scale_idx := int(r.get("scale_index", 0))
		var world_pos := VoxelGeneral.voxel_to_world(origin, grid_origin, voxel_size)
		var yaw := float(rot_idx) * 360.0 / float(maxi(rotation_count, 1))
		var pivot_offset := _vector3_from_value(pivot_variant.get("offset", Vector3.ZERO), Vector3.ZERO)
		var pivot_world_offset := pivot_offset.rotated(Vector3.UP, deg_to_rad(yaw))
		var instance_pos := world_pos - pivot_world_offset
		world_results.append({
			"position": instance_pos,
			"anchor_position": world_pos,
			"pivot_variant": str(pivot_variant.get("name", "bottom")),
			"pivot_offset": pivot_offset,
			"rotation_degrees": Vector3(0.0, yaw, 0.0),
			"rotation_mode": "Y",
			"scale": Vector3.ONE,
			"score": float(r.get("score", 0.0)),
			"voxel_origin": origin,
			"rotation_index": rot_idx,
			"scale_index": scale_idx,
			"asset_index": int(r.get("asset_index", 0)),
			"support_ratio": float(r.get("support_ratio", 0.0)),
			"solid_collision": float(r.get("solid_collision", 0.0)),
			"complexity_overlap": float(r.get("complexity_overlap", 0.0)),
			"clearance_overlap": float(r.get("clearance_overlap", 0.0)),
			"ignored_sample": float(r.get("ignored_sample", 0.0)),
		})
	return world_results


# ---------------------------------------------------------------------------
# voxel_write_spec creation
# ---------------------------------------------------------------------------


static func make_voxel_write_spec(
	world_result: Dictionary,
	node: AutoObject,
	config: Dictionary = {}
) -> Dictionary:
	if node != null:
		var node_record_id := str(config.get("id", node.name if not node.name.is_empty() else "voxel_placement_%d" % int(world_result.get("asset_index", 0))))
		var fields := config.duplicate(true)
		fields.erase("id")
		fields.erase("id_prefix")
		if not fields.has("auto_source"):
			fields["auto_source"] = "voxel_placement"
		if not fields.has("source_voxel_type"):
			fields["source_voxel_type"] = "AutoSceneVoxel"
		fields["score"] = float(world_result.get("score", 0.0))
		fields["voxel_origin"] = world_result.get("voxel_origin", Vector3i.ZERO)
		fields["rotation_index"] = int(world_result.get("rotation_index", 0))
		fields["asset_index"] = int(world_result.get("asset_index", 0))
		var node_record := node.make_instance_stamp_write_spec(node_record_id, Vector2i.ZERO, 0, fields)
		node_record["position"] = world_result.get("position", node.position)
		node_record["scale"] = world_result.get("scale", node.scale)
		if world_result.has("rotation_degrees"):
			node_record["rotation_degrees"] = world_result.rotation_degrees
		return node_record

	var color: Color = config.get("color", Color.WHITE)
	var complexity := clampf(float(config.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity
	var position: Vector3 = world_result.get("position", Vector3.ZERO)
	var scale_val: Vector3 = world_result.get("scale", Vector3.ONE)
	var record_id := str(config.get("id", "voxel_placement_%d" % int(world_result.get("asset_index", 0))))
	var collision_layers: Array = config.get("collision", [])

	var record := {
		"id": record_id,
		"type": config.get("type", "vegetation"),
		"auto_source": "voxel_placement",
		"source_voxel_type": "AutoSceneVoxel",
		"position": position,
		"scale": scale_val,
		"base_pixel": Vector2i.ZERO,
		"voxel_xz": Vector2i.ZERO,
		"volume_xz_resolution": 0,
		"color": color,
		"complexity": complexity,
		"collision": collision_layers,
		"score": float(world_result.get("score", 0.0)),
		"voxel_origin": world_result.get("voxel_origin", Vector3i.ZERO),
		"rotation_index": int(world_result.get("rotation_index", 0)),
		"rotation_mode": str(world_result.get("rotation_mode", "Y")).to_upper(),
		"rotation_degrees": world_result.get("rotation_degrees", Vector3.ZERO),
		"asset_index": int(world_result.get("asset_index", 0)),
	}
	if config.has("channel"):
		record["channel"] = int(config.channel)
		record["radius"] = float(config.get("radius", 0.0))
		if config.has("y_min"):
			record["y_min"] = float(config.y_min)
		if config.has("y_max"):
			record["y_max"] = float(config.y_max)
	return record



static func make_voxel_write_specs(
	world_results: Array,
	nodes: Array,
	config: Dictionary = {}
) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for i in range(world_results.size()):
		var node: AutoObject = nodes[i] if i < nodes.size() else null
		var cfg := config.duplicate(true)
		cfg["id"] = "%s_%d" % [str(config.get("id_prefix", "voxel_placement")), i]
		records.append(make_voxel_write_spec(world_results[i], node, cfg))
	return records


## ===== VoxelFootprintBaker 静态委托桩(抽出后保持外部/内部调用兼容) =====
