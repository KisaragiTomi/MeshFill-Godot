class_name VoxelPlacementOutput

## GPU-capable placement output conversion plus CPU-only scene instantiation helpers.
extends "res://scripts/godot_compute_shader_base.gd"

const AutoObject := preload("res://scripts/auto_object.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const PlacementResultCodec := preload("res://scripts/utils/placement_result_codec.gd")

const RECORD_STRIDE := 4
const WORLD_RESULT_STRIDE := 4
const VEC4_BYTES := 16
const PLACEMENT_RESULT_STRIDE_BYTES := RECORD_STRIDE * VEC4_BYTES
const WORLD_RESULT_STRIDE_BYTES := WORLD_RESULT_STRIDE * VEC4_BYTES
const RESULTS_TO_WORLD_SHADER_PATH := "res://shaders/placement_results_to_world.glsl"
const RESULTS_TO_WORLD_LOCAL_SIZE := 64
const SCENE_PLACEMENT_ACTOR_CONFIG_KEYS := [
	"scene_placement_actor",
	"placement_actor",
	"spa",
]
const SCENE_VOXEL_COMMITTER_CONFIG_KEY := "scene_voxel_committer"
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
	"voxel_size",
	"volume_xz_resolution",
	AutoObject.INSTANCE_STAMP_WRITE_SPEC_META_KEY,
	"voxel_write_spec",
	"world_capture_size",
]


## 按候选 key 列表在配置字典中查找场景放置执行者(Scene Placement Actor)对象，找不到则返回 null。
static func _scene_placement_actor_from_config(config: Dictionary) -> Object:
	for key in SCENE_PLACEMENT_ACTOR_CONFIG_KEYS:
		if not config.has(key):
			continue
		var value = config.get(key)
		if value is Object:
			return value as Object
	return null



## --- 迁移自 generator 的 placement 输出/实例化函数 ---
## 依据单条 world_result 放置结果创建并配置一个 AutoObject 节点：设置位置/旋转/缩放/网格并挂载到父节点下，
## 按需生成并绑定 voxel write spec 记录、提交给场景体素委交器(committer)，
## 若配置中提供了场景放置执行者(SPA)则登记归属关系。返回创建好的节点。
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

	var record := AutoObject.voxel_write_spec_from_config(cfg)
	if not record.is_empty():
		record = attach_placement_voxel_write_spec(node, record)
	elif bool(cfg.get("create_voxel_write_spec", false)):
		record = make_placement_voxel_write_spec(node, world_result, node_class, cfg)
		if not record.is_empty():
			record = attach_placement_voxel_write_spec(node, record)

	var target = cfg.get(SCENE_VOXEL_COMMITTER_CONFIG_KEY, null)
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



## 批量调用 instantiate_placement，为每个 world_result 创建一个节点，返回节点数组。
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



## 为已放置的节点构造 voxel write spec 记录：解析捕获分辨率与基准像素坐标，
## 收集附加字段后调用 node.make_instance_stamp_write_spec 生成记录，并补充旋转与网格名信息。
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



## 将 voxel write spec 记录与节点绑定：刷新节点间距与实例 ID，补全 id/位置/缩放/旋转/auto_id/node_path
## 等字段后写回节点，返回节点上最终保存的记录。
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



## 委托 VoxelGeneral.world_to_texture_pixel：将世界坐标换算为纹理像素坐标。
static func world_to_texture_pixel(
	world_pos: Vector3,
	capture_size: float,
	resolution: int
) -> Vector2i:
	return VoxelGeneral.world_to_texture_pixel(world_pos, capture_size, resolution)



## 委托 VoxelGeneral.world_to_volume_pixel：将世界坐标换算为体积纹理像素坐标。
static func world_to_volume_pixel(
	world_pos: Vector3,
	resolution: int,
	p_grid_origin: Vector3,
	p_voxel_size: Vector3
) -> Vector2i:
	return VoxelGeneral.world_to_volume_pixel(world_pos, resolution, p_grid_origin, p_voxel_size)



## 解析放置记录的基准像素坐标：优先使用配置/结果中显式给出的 base_pixel，
## 否则询问 committer 目标，或按 grid_origin/voxel_size 换算，最后退回纹理像素换算。
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
	var target = record_config.get(SCENE_VOXEL_COMMITTER_CONFIG_KEY, null)
	if target != null and target.has_method("world_to_volume_pixel"):
		return target.call("world_to_volume_pixel", world_pos, resolution)
	if record_config.has("grid_origin") or record_config.has("voxel_size"):
		var fallback_voxel_size := VoxelGeneral.voxel_size_for_resolution(capture_size, resolution, 1.0)
		var fallback_grid_origin := VoxelGeneral.default_grid_origin(capture_size)
		return world_to_volume_pixel(
			world_pos,
			resolution,
			VariantUtils.vector3_from_value(record_config.get("grid_origin", fallback_grid_origin), fallback_grid_origin),
			VariantUtils.vector3_from_value(record_config.get("voxel_size", fallback_voxel_size), fallback_voxel_size)
		)
	return world_to_texture_pixel(world_pos, capture_size, resolution)



## 组装 voxel write spec 记录的附加字段：透传配置中未被保留 key 占用的自定义字段，
## 并补充来源类型/资产索引/调试分数等标准字段。
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



## 根据 node_class 创建对应的 AutoObject 节点实例(当前所有分支均返回 AutoObject.new())。
static func _create_node_for_class(node_class: String) -> AutoObject:
	match node_class:
		"rock", "cliff":
			return AutoObject.new()
		_:
			return AutoObject.new()



## 根据 node_class 选择合适的方法(configure_object 或 configure_auto_object)配置节点。
static func _configure_node(node: AutoObject, node_class: String, cfg: Dictionary) -> void:
	match node_class:
		"rock", "cliff":
			(node as AutoObject).configure_object(cfg)
		_:
			node.configure_auto_object(cfg)


static func results_to_world_gpu(
	results: Array[Dictionary],
	voxel_size: Vector3,
	grid_origin: Vector3,
	rotation_count: int = 24,
	pivot_variant: Dictionary = {},
	rendering_device: RenderingDevice = null
) -> Dictionary:
	var runner = load("res://scripts/voxel_placement_output.gd").new()
	if rendering_device != null:
		runner.attach_rendering_device(rendering_device, false)
	return runner._results_to_world_gpu(results, voxel_size, grid_origin, rotation_count, pivot_variant)


func _results_to_world_gpu(
	results: Array[Dictionary],
	voxel_size: Vector3,
	grid_origin: Vector3,
	rotation_count: int = 24,
	pivot_variant: Dictionary = {}
) -> Dictionary:
	var record_count := results.size()
	if record_count <= 0:
		return {
			"ok": true,
			"reason": "empty_results",
			"gpu_first": true,
			"cpu_fallback": false,
			"record_count": 0,
			"world_result_count": 0,
			"world_results": [],
			"readback_source": "none",
		}

	var input_bytes := _pack_placement_result_records(results)
	if input_bytes.size() != record_count * PLACEMENT_RESULT_STRIDE_BYTES:
		return _results_to_world_gpu_blocked("pack_failed", record_count)

	log_name = "VoxelPlacementOutputWorld"
	sync_global_device = false
	if _rd == null and not ensure_device(true, false):
		dispose()
		return _results_to_world_gpu_blocked("missing_rendering_device", record_count)

	var shader := load_compute_shader(RESULTS_TO_WORLD_SHADER_PATH)
	var pipeline := create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		dispose()
		return _results_to_world_gpu_blocked("placement_output_world_shader_not_ready", record_count)

	var input_buffer := storage_buffer_from_bytes(input_bytes, SCOPE_FRAME, "placement_results_in_vec4")
	var output_buffer := storage_buffer_zero(record_count * WORLD_RESULT_STRIDE_BYTES, SCOPE_FRAME, "placement_world_results_out_vec4")
	if not input_buffer.is_valid() or not output_buffer.is_valid():
		dispose()
		return _results_to_world_gpu_blocked("placement_output_world_buffer_create_failed", record_count)

	var set0 := create_uniform_set([
		make_storage_uniform(0, input_buffer),
		make_storage_uniform(1, output_buffer),
	], shader, 0, SCOPE_PASS, "placement_results_to_world_set0")
	if not set0.is_valid():
		dispose()
		return _results_to_world_gpu_blocked("placement_output_world_uniform_set_failed", record_count)

	var safe_voxel_size := VoxelGeneral.safe_voxel_size(voxel_size)
	var pivot_offset := VariantUtils.vector3_from_value(pivot_variant.get("offset", Vector3.ZERO), Vector3.ZERO)
	var push := _pack_results_to_world_push(record_count, rotation_count, grid_origin, safe_voxel_size, pivot_offset)
	var groups := dispatch_groups_1d(record_count, RESULTS_TO_WORLD_LOCAL_SIZE)
	var cl := begin_compute_list()
	if cl < 0:
		dispose()
		return _results_to_world_gpu_blocked("placement_output_world_compute_list_begin_failed", record_count)
	_gpu_dispatch_pipeline_sets(cl, pipeline, [set0], push, groups)
	end_compute_list()
	submit_and_sync(true)

	var out_bytes := _rd.buffer_get_data(output_buffer, 0, record_count * WORLD_RESULT_STRIDE_BYTES)
	dispose()
	if out_bytes.size() != record_count * WORLD_RESULT_STRIDE_BYTES:
		return _results_to_world_gpu_blocked("placement_output_world_readback_failed", record_count)

	var world_results := _decode_world_result_bytes(out_bytes, results, pivot_variant, record_count)
	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"record_count": record_count,
		"world_result_count": world_results.size(),
		"input_format": "placement_result_vec4x4",
		"output_format": "world_result_vec4x4",
		"input_stride_bytes": PLACEMENT_RESULT_STRIDE_BYTES,
		"output_stride_bytes": WORLD_RESULT_STRIDE_BYTES,
		"local_size_x": RESULTS_TO_WORLD_LOCAL_SIZE,
		"dispatch_groups": groups,
		"world_result_bytes": out_bytes,
		"world_results": world_results,
		"readback_source": "placement_results_to_world_compute",
	}


static func _results_to_world_gpu_blocked(reason: String, record_count: int = 0) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"record_count": record_count,
		"world_result_count": 0,
		"world_results": [],
		"readback_source": "none",
	}


static func _pack_placement_result_records(results: Array[Dictionary]) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(results.size() * PLACEMENT_RESULT_STRIDE_BYTES)
	for i in range(results.size()):
		var r: Dictionary = results[i]
		var base := i * PLACEMENT_RESULT_STRIDE_BYTES
		var origin := VoxelGeneral.vector3i_from_value(r.get("voxel_origin", Vector3i.ZERO), Vector3i.ZERO)
		bytes.encode_float(base + 0, float(origin.x))
		bytes.encode_float(base + 4, float(origin.y))
		bytes.encode_float(base + 8, float(origin.z))
		bytes.encode_float(base + 12, float(r.get("score", 0.0)))
		bytes.encode_float(base + 16, float(r.get("tile_id", 0)))
		bytes.encode_float(base + 20, float(r.get("asset_index", 0)))
		bytes.encode_float(base + 24, float(r.get("rotation_index", 0)))
		bytes.encode_float(base + 28, float(r.get("scale_index", 0)))
		bytes.encode_float(base + 32, float(r.get("support_ratio", 0.0)))
		bytes.encode_float(base + 36, float(r.get("solid_collision", 0.0)))
		bytes.encode_float(base + 40, float(r.get("complexity_overlap", 0.0)))
		bytes.encode_float(base + 44, float(r.get("clearance_overlap", 0.0)))
		bytes.encode_float(base + 48, float(r.get("ignored_sample", 0.0)))
		bytes.encode_float(base + 52, 1.0 if bool(r.get("valid", false)) else 0.0)
		bytes.encode_float(base + 56, float(r.get("support_hit", 0.0)))
		bytes.encode_float(base + 60, float(r.get("support_total", 0.0)))
	return bytes


## 委托给 PlacementResultCodec（与 writeback 共享的 results→world push 布局）。
static func _pack_results_to_world_push(
	record_count: int,
	rotation_count: int,
	grid_origin: Vector3,
	voxel_size: Vector3,
	pivot_offset: Vector3
) -> PackedByteArray:
	return PlacementResultCodec.pack_results_to_world_push(record_count, rotation_count, grid_origin, voxel_size, pivot_offset)


static func _decode_world_result_bytes(
	bytes: PackedByteArray,
	source_results: Array[Dictionary],
	pivot_variant: Dictionary,
	record_count: int
) -> Array[Dictionary]:
	var world_results: Array[Dictionary] = []
	var available_bytes := mini(bytes.size(), record_count * WORLD_RESULT_STRIDE_BYTES)
	available_bytes -= available_bytes % WORLD_RESULT_STRIDE_BYTES
	var available := mini(record_count, int(available_bytes / WORLD_RESULT_STRIDE_BYTES))
	var pivot_offset := VariantUtils.vector3_from_value(pivot_variant.get("offset", Vector3.ZERO), Vector3.ZERO)
	for i in range(available):
		var base := i * WORLD_RESULT_STRIDE_BYTES
		var valid := bytes.decode_float(base + 52) > 0.5
		if not valid:
			continue
		var source: Dictionary = source_results[i]
		var yaw := bytes.decode_float(base + 28)
		world_results.append({
			"position": Vector3(
				bytes.decode_float(base + 0),
				bytes.decode_float(base + 4),
				bytes.decode_float(base + 8)
			),
			"anchor_position": Vector3(
				bytes.decode_float(base + 16),
				bytes.decode_float(base + 20),
				bytes.decode_float(base + 24)
			),
			"pivot_variant": str(pivot_variant.get("name", "bottom")),
			"pivot_offset": pivot_offset,
			"rotation_degrees": Vector3(0.0, yaw, 0.0),
			"rotation_mode": "Y",
			"scale": Vector3.ONE,
			"score": bytes.decode_float(base + 12),
			"voxel_origin": VoxelGeneral.vector3i_from_value(source.get("voxel_origin", Vector3i.ZERO), Vector3i.ZERO),
			"rotation_index": int(source.get("rotation_index", 0)),
			"scale_index": int(roundf(bytes.decode_float(base + 60))),
			"asset_index": int(roundf(bytes.decode_float(base + 56))),
			"support_ratio": bytes.decode_float(base + 32),
			"solid_collision": bytes.decode_float(base + 36),
			"complexity_overlap": bytes.decode_float(base + 40),
			"clearance_overlap": bytes.decode_float(base + 44),
			"ignored_sample": bytes.decode_float(base + 48),
		})
	return world_results


# ---------------------------------------------------------------------------
# voxel_write_spec creation
# ---------------------------------------------------------------------------


## 构造单条 voxel write spec 记录：若提供了节点，则通过 node.make_instance_stamp_write_spec 生成；
## 否则直接拼装一个不依赖节点的记录字典(可含 channel/radius/y_min/y_max 等可选字段)。
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



## 批量调用 make_voxel_write_spec，为每个 world_result/node 对生成 write spec 记录并返回数组。
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
