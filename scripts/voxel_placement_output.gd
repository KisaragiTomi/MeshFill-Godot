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
