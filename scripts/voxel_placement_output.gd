class_name VoxelPlacementOutput

## GPU placement output conversion (placement result records → world-space results).
extends "res://scripts/godot_compute_shader_base.gd"

const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const PlacementResultCodec := preload("res://scripts/utils/placement_result_codec.gd")

const RECORD_STRIDE := 4
const WORLD_RESULT_STRIDE := 4
const VEC4_BYTES := 16
## 必须等于 PlacementResultCodec.PLACEMENT_RECORD_BYTES（同一 GPU ABI，64 B）。
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
	profile_arena_rid: RID = RID(),
	kernel_host = null
) -> Dictionary:
	# runner 每次调用新建、末尾 dispose()，自身不可能缓存 shader/pipeline。kernel_host 传一个
	# 同设备的长命宿主（调用方 VPG），转换 shader 就只在该宿主生命周期内编译一次。
	var runner = load("res://scripts/voxel_placement_output.gd").new()
	if rendering_device != null:
		runner.attach_rendering_device(rendering_device, false)
	return runner._results_to_world_gpu(results, voxel_size, grid_origin, rotation_count, pivot_variant, profile_arena_rid, kernel_host)


## pivot 二选一：profile_arena_rid 有效 ⟹ per-record 模式（record 的槽内局部 pivot
## 下标 + profile_index 查容器常驻 Arena；pivot_variant 仅作报告标签）；
## 无效 ⟹ 共享 push pivot（pivot_variant.offset，遗留调用面）。
func _results_to_world_gpu(
	results: Array[Dictionary],
	voxel_size: Vector3,
	grid_origin: Vector3,
	rotation_count: int = 24,
	pivot_variant: Dictionary = {},
	profile_arena_rid: RID = RID(),
	kernel_host = null
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
	if profile_arena_rid.is_valid():
		track_borrowed_rid(profile_arena_rid, KIND_BUFFER, SCOPE_FRAME, "auto_voxel_runtime_profile_container:profile_arena")
	var dispatched := PlacementResultCodec.dispatch_results_to_world(
		self, input_buffer, record_count, rotation_count,
		grid_origin, safe_voxel_size, pivot_offset,
		"placement_world_results_out_vec4", "placement_results_to_world_set0",
		profile_arena_rid, kernel_host
	)
	if not bool(dispatched.get("ok", false)):
		dispose()
		# fail_step 未登记时不再兜底成 "shader_not_ready"：那会把一个未知失败伪装
		# 成已知失败，诊断从第一条就走错方向。
		var fail_step := str(dispatched.get("fail_step", ""))
		if not WORLD_DISPATCH_FAIL_REASONS.has(fail_step):
			push_error("VoxelPlacementOutput: dispatch_results_to_world 返回未登记的 fail_step='%s'（已知：%s）record_count=%d" % [
				fail_step, str(WORLD_DISPATCH_FAIL_REASONS.keys()), record_count])
			assert(false, "VoxelPlacementOutput: unmapped world dispatch fail_step")
			return _results_to_world_gpu_blocked(
				"placement_output_world_unknown_fail_step:%s" % fail_step, record_count)
		return _results_to_world_gpu_blocked(str(WORLD_DISPATCH_FAIL_REASONS[fail_step]), record_count)
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


## 逐条记录的 64 字节 ABI 已收敛到 PlacementResultCodec（单一真值源），本处只负责成批分配与遍历。
static func _pack_placement_result_records(results: Array[Dictionary]) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(results.size() * PLACEMENT_RESULT_STRIDE_BYTES)
	for i in range(results.size()):
		PlacementResultCodec.encode_placement_record(bytes, i * PLACEMENT_RESULT_STRIDE_BYTES, results[i])
	return bytes


static func _decode_world_result_bytes(
	bytes: PackedByteArray,
	source_results: Array[Dictionary],
	pivot_variant: Dictionary,
	record_count: int
) -> Array[Dictionary]:
	var world_results: Array[Dictionary] = []
	# 字节数必须恰好覆盖 record_count 条记录：原来的 mini()/取模截断会在回读短了
	# 的时候只解出前几条，调用方看到的是"部分放置"而不是"回读坏了"。
	var expected_bytes := record_count * WORLD_RESULT_STRIDE_BYTES
	if bytes.size() != expected_bytes:
		push_error("VoxelPlacementOutput: world 结果字节数不匹配 期望 %d 实际 %d（record_count=%d stride=%d）—— 拒绝按截断条数解码" % [
			expected_bytes, bytes.size(), record_count, WORLD_RESULT_STRIDE_BYTES])
		assert(false, "VoxelPlacementOutput: world result byte count mismatch")
		return world_results
	var pivot_offset := VariantUtils.vector3_from_value(pivot_variant.get("offset", Vector3.ZERO), Vector3.ZERO)
	for i in range(record_count):
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
