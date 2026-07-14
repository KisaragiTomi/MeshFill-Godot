class_name VoxelPlacementOutput

## GPU placement output conversion (placement result records → world-space results).
extends "res://scripts/godot_compute_shader_base.gd"

const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const PlacementResultCodec := preload("res://scripts/utils/placement_result_codec.gd")

const RECORD_STRIDE := 4
const WORLD_RESULT_STRIDE := 4
const VEC4_BYTES := 16
const PLACEMENT_RESULT_STRIDE_BYTES := RECORD_STRIDE * VEC4_BYTES
const WORLD_RESULT_STRIDE_BYTES := WORLD_RESULT_STRIDE * VEC4_BYTES
const RESULTS_TO_WORLD_LOCAL_SIZE := 64
## 共享派发骨架的 fail_step → 本文件既有 reason 诊断字符串（逐字保持）。
const WORLD_DISPATCH_FAIL_REASONS := {
	"shader": "placement_output_world_shader_not_ready",
	"world_buffer": "placement_output_world_buffer_create_failed",
	"uniform_set": "placement_output_world_uniform_set_failed",
	"compute_list": "placement_output_world_compute_list_begin_failed",
}


static func results_to_world_gpu(
	results: Array[Dictionary],
	voxel_size: Vector3,
	grid_origin: Vector3,
	rotation_count: int = 24,
	pivot_variant: Dictionary = {},
	rendering_device: RenderingDevice = null,
	pivot_records_rid: RID = RID()
) -> Dictionary:
	var runner = load("res://scripts/voxel_placement_output.gd").new()
	if rendering_device != null:
		runner.attach_rendering_device(rendering_device, false)
	return runner._results_to_world_gpu(results, voxel_size, grid_origin, rotation_count, pivot_variant, pivot_records_rid)


## pivot 二选一：pivot_records_rid 有效 ⟹ per-record 模式（record 的
## global_pivot_index 查容器常驻 pivot_records；pivot_variant 仅作报告标签）；
## 无效 ⟹ 共享 push pivot（pivot_variant.offset，遗留调用面）。
func _results_to_world_gpu(
	results: Array[Dictionary],
	voxel_size: Vector3,
	grid_origin: Vector3,
	rotation_count: int = 24,
	pivot_variant: Dictionary = {},
	pivot_records_rid: RID = RID()
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

	var input_buffer := storage_buffer_from_bytes(input_bytes, SCOPE_FRAME, "placement_results_in_vec4")
	if not input_buffer.is_valid():
		dispose()
		return _results_to_world_gpu_blocked("placement_output_world_buffer_create_failed", record_count)

	var safe_voxel_size := VoxelGeneral.safe_voxel_size(voxel_size)
	var pivot_offset := VariantUtils.vector3_from_value(pivot_variant.get("offset", Vector3.ZERO), Vector3.ZERO)
	if pivot_records_rid.is_valid():
		track_borrowed_rid(pivot_records_rid, KIND_BUFFER, SCOPE_FRAME, "auto_voxel_runtime_profile_container:pivot_records")
	var dispatched := PlacementResultCodec.dispatch_results_to_world(
		self, input_buffer, record_count, rotation_count,
		grid_origin, safe_voxel_size, pivot_offset,
		SCOPE_PERSISTENT, "placement_world_results_out_vec4", "placement_results_to_world_set0",
		pivot_records_rid
	)
	if not bool(dispatched.get("ok", false)):
		dispose()
		return _results_to_world_gpu_blocked(
			str(WORLD_DISPATCH_FAIL_REASONS.get(str(dispatched.get("fail_step", "")), "placement_output_world_shader_not_ready")),
			record_count
		)
	var output_buffer: RID = dispatched.get("world_results_rid", RID())
	var groups: Vector3i = dispatched.get("dispatch_groups", Vector3i.ONE)

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
		bytes.encode_float(base + 16, float(r.get("anchor_id", 0)))
		bytes.encode_float(base + 20, float(r.get("asset_index", 0)))
		bytes.encode_float(base + 24, float(r.get("rotation_index", 0)))
		bytes.encode_float(base + 28, float(r.get("global_pivot_index", -1)))
		bytes.encode_float(base + 32, float(r.get("solid_collision", 0.0)))
		bytes.encode_float(base + 36, float(r.get("loss_before", 0.0)))
		bytes.encode_float(base + 40, float(r.get("loss_after", 0.0)))
		bytes.encode_float(base + 44, float(r.get("clearance_overlap", 0.0)))
		bytes.encode_float(base + 48, float(r.get("profile_index", -1)))
		bytes.encode_float(base + 52, 1.0 if bool(r.get("valid", false)) else 0.0)
		bytes.encode_float(base + 56, float(r.get("coarse_score", 0.0)))
		bytes.encode_float(base + 60, 0.0)
	return bytes


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
			"global_pivot_index": int(roundf(bytes.decode_float(base + 60))),
			"asset_index": int(roundf(bytes.decode_float(base + 56))),
			"solid_collision": bytes.decode_float(base + 32),
			"loss_before": bytes.decode_float(base + 36),
			"loss_after": bytes.decode_float(base + 40),
			"clearance_overlap": bytes.decode_float(base + 44),
			"profile_index": int(roundf(bytes.decode_float(base + 48))),
		})
	return world_results
