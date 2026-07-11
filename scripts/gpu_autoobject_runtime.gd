class_name GPUAutoObjectRuntime
extends "res://scripts/godot_compute_shader_base.gd"

const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")

const DEFAULT_DIRTY_FLAGS := {"auto": true, "object_refs": true}

const DIRTY_FLAG_AUTO := 1
const DIRTY_FLAG_OBJECT_REFS := 2
const DIRTY_FLAG_SCENE := 4
const DIRTY_FLAG_COLLISION := 8
const DIRTY_FLAG_TARGET := 16
const DIRTY_FLAG_ROUTING := 32
const DIRTY_FLAG_SCORING := 64
const DIRTY_FLAG_FEEDBACK := 128

const OBJECT_FLAG_VISIBLE := 1
const OBJECT_FLAG_SELECTED := 2
const OBJECT_FLAG_LOCKED := 4
const OBJECT_FLAG_DIRTY := 8
const OBJECT_FLAG_SOURCE := 16
const OBJECT_FLAG_COLLISION := 32

const OBJECT_SCALAR_STRIDE_BYTES := 4
const OBJECT_BOUNDS_STRIDE_BYTES := 16
const OBJECT_TRANSFORM_STRIDE_BYTES := 64
const DIRTY_DELTA_STRIDE_BYTES := 80
const DIRTY_DELTA_CAPACITY_MULTIPLIER := 4
const ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION := 1
const ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES := 128
const ACCEPTED_PLACEMENT_RECORD_OBJECT_ID_OFFSET := 0
const ACCEPTED_PLACEMENT_RECORD_PROFILE_ID_OFFSET := 4
const ACCEPTED_PLACEMENT_RECORD_OBJECT_TYPE_OFFSET := 8
const ACCEPTED_PLACEMENT_RECORD_OBJECT_FLAGS_OFFSET := 12
const ACCEPTED_PLACEMENT_RECORD_VOXEL_MIN_OFFSET := 16
const ACCEPTED_PLACEMENT_RECORD_VOXEL_MAX_OFFSET := 32
const ACCEPTED_PLACEMENT_RECORD_TRANSFORM_OFFSET := 48
const ACCEPTED_PLACEMENT_RECORD_DIRTY_FLAGS_OFFSET := 112
const ACCEPTED_PLACEMENT_RECORD_ASSET_INDEX_OFFSET := 116
const ACCEPTED_PLACEMENT_RECORD_RESULT_INDEX_OFFSET := 120
const ACCEPTED_PLACEMENT_RECORD_RESERVED_OFFSET := 124
const ACCEPTED_PLACEMENT_RECORD_SHADER_PATH := "res://shaders/autoobject_apply_accepted_placements.glsl"
const ACCEPTED_PLACEMENT_RECORD_SHADER_NAME := "autoobject_apply_accepted_placements.glsl"
const ACCEPTED_PLACEMENT_RESIDENT_SHADER_PATH := "res://shaders/autoobject_apply_accepted_placements_resident.glsl"
const ACCEPTED_PLACEMENT_RESIDENT_SHADER_NAME := "autoobject_apply_accepted_placements_resident.glsl"
const ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X := 64
const ACCEPTED_PLACEMENT_RECORD_SHADER_STATS_U32_COUNT := 8
const ACCEPTED_PLACEMENT_RECORD_STAT_APPLIED := 0
const ACCEPTED_PLACEMENT_RECORD_STAT_INVALID_OBJECT_ID := 1
const ACCEPTED_PLACEMENT_RECORD_STAT_DIRTY_OVERFLOW := 2
const ACCEPTED_PLACEMENT_RECORD_STAT_ALREADY_ALIVE := 3
const ACCEPTED_PLACEMENT_RECORD_STAT_SKIPPED := 4
const ACCEPTED_PLACEMENT_RECORD_STAT_RECORD_COUNT := 5
const ACCEPTED_PLACEMENT_RECORD_STAT_DIRTY_BASE := 6
const ACCEPTED_PLACEMENT_RECORD_STAT_DISPATCHED := 7
const GPU_BUFFER_ALIVE := "alive"
const GPU_BUFFER_GENERATION := "generation"
const GPU_BUFFER_TYPE := "object_type"
const GPU_BUFFER_PROFILE := "profile"
const GPU_BUFFER_FLAGS := "object_flags"
const GPU_BUFFER_BOUNDS_MIN := "bounds_min"
const GPU_BUFFER_BOUNDS_MAX := "bounds_max"
const GPU_BUFFER_PREVIOUS_BOUNDS_MIN := "previous_bounds_min"
const GPU_BUFFER_PREVIOUS_BOUNDS_MAX := "previous_bounds_max"
const GPU_BUFFER_TRANSFORM := "transform"
const GPU_BUFFER_DIRTY_DELTA := "dirty_delta"
const GPU_BUFFER_DIRTY_COUNT := "dirty_count"
const GPU_BUFFER_NAMES := [
	GPU_BUFFER_ALIVE,
	GPU_BUFFER_GENERATION,
	GPU_BUFFER_TYPE,
	GPU_BUFFER_PROFILE,
	GPU_BUFFER_FLAGS,
	GPU_BUFFER_BOUNDS_MIN,
	GPU_BUFFER_BOUNDS_MAX,
	GPU_BUFFER_PREVIOUS_BOUNDS_MIN,
	GPU_BUFFER_PREVIOUS_BOUNDS_MAX,
	GPU_BUFFER_TRANSFORM,
	GPU_BUFFER_DIRTY_DELTA,
	GPU_BUFFER_DIRTY_COUNT,
]

# std430 push-constant schemas (see scripts/utils/push_constant_layout.gd).
const RESIDENT_PLACEMENT_PUSH := [
	["record_count", "int"],
	["max_objects", "int"],
	["dirty_delta_capacity", "int"],
	["dirty_base", "int"],
	["profile_id", "int"],
	["object_type", "int"],
	["object_flags", "int"],
	["dirty_bits", "int"],
	["asset_index", "int"],
	["flush_epoch", "int"],
	["stats_u32_count", "int"],
	["_pad0", "int"],
	["grid_x", "int"],
	["grid_y", "int"],
	["grid_z", "int"],
	["_pad1", "int"],
]
const ACCEPTED_PLACEMENT_RECORD_PUSH := [
	["record_count", "int"],
	["runtime_capacity", "int"],
	["dirty_delta_capacity", "int"],
	["dirty_base", "int"],
	["flush_epoch", "int"],
	["options", "int"],
	["stats_u32_count", "int"],
	["_pad0", "int"],
]

var max_objects: int
var dirty_delta_capacity: int

var _gpu_enabled := true
var _gpu_ready := false
var _not_ready_reason := ""

var _free_ids: Array[int] = []
var _dirty_delta_count := 0
var _flush_epoch := 0
# P0 #5: The VPG always explicitly passes use_accepted_placement_record_shader=true
# when calling spawn_batch_from_accepted_placement_records. The legacy command-queue
# flush path that consumed this flag as its default was removed; the flag remains as
# an SPA-facing toggle (set/get_use_resident_accepted_placement_writeback).
var _use_resident_accepted_placement_writeback := false

var _alive_buffer: RID
var _generation_buffer: RID
var _type_buffer: RID
var _profile_buffer: RID
var _flags_buffer: RID
var _bounds_min_buffer: RID
var _bounds_max_buffer: RID
var _previous_bounds_min_buffer: RID
var _previous_bounds_max_buffer: RID
var _transform_buffer: RID
var _dirty_delta_buffer: RID
var _dirty_count_buffer: RID


## 初始化运行时，设置日志名并配置容量。
func _init(p_max_objects: int = 1024, p_enable_gpu: bool = true) -> void:
	log_name = "GPUAutoObjectRuntime"
	configure_capacity(p_max_objects, p_enable_gpu)


## 重置对象容量、dirty delta 容量及所有运行时状态，并重新分配 GPU 缓冲区。
func configure_capacity(p_max_objects: int, p_enable_gpu: bool = true) -> void:
	_gpu_enabled = p_enable_gpu
	max_objects = maxi(p_max_objects, 0)
	dirty_delta_capacity = maxi(max_objects * DIRTY_DELTA_CAPACITY_MULTIPLIER, 1)
	_dirty_delta_count = 0
	_flush_epoch = 0
	_free_ids.clear()
	for i in range(max_objects):
		_free_ids.append(max_objects - 1 - i)
	_create_gpu_buffers()


## 返回 GPU 运行时是否已就绪。
func is_ready() -> bool:
	return _gpu_ready


## 返回 GPU 运行时是否已就绪（同 is_ready）。
func is_gpu_ready() -> bool:
	return _gpu_ready


## 返回运行时未就绪的原因字符串。
func get_not_ready_reason() -> String:
	return _not_ready_reason


## 设置是否默认启用驻留放置记录 Shader 回写模式。
func set_use_resident_accepted_placement_writeback(enabled: bool) -> void:
	_use_resident_accepted_placement_writeback = enabled


## 返回当前是否启用驻留放置记录 Shader 回写模式。
func get_use_resident_accepted_placement_writeback() -> bool:
	return _use_resident_accepted_placement_writeback


## 通过 GPU Shader 批量生成对象（仅 GPU 路径），失败时原子回滚所有已分配 ID。
# P0 #5: Batch-spawn accepted placements via GPU shader writeback ONLY.
# GPU-only path — no CPU bulk write fallback.
# The shader writes alive=1, object_type, profile, object_flags, bounds,
# transforms, and dirty deltas — all in parallel on the GPU.
# When the shader fails, return failure directly.
func spawn_batch_from_accepted_placement_records(
	spawn_records: Array[Dictionary],
	options: Dictionary = {}
) -> Dictionary:
	if not _gpu_ready:
		return {
			"ok": false, "reason": "runtime_not_ready",
			"spawned_count": 0, "failed_count": spawn_records.size(),
			"object_ids": [],
			"accepted_placement_record_shader_consumed": false,
		}
	if spawn_records.is_empty():
		return {
			"ok": true, "reason": "empty_batch",
			"spawned_count": 0, "failed_count": 0,
			"object_ids": [],
			"accepted_placement_record_shader_consumed": false,
		}

	# Guard: ensure enough free IDs and dirty delta capacity.
	if _free_ids.size() < spawn_records.size():
		return {
			"ok": false, "reason": "capacity_full",
			"spawned_count": 0, "failed_count": spawn_records.size(),
			"object_ids": [],
			"accepted_placement_record_shader_consumed": false,
		}
	if _dirty_delta_count + spawn_records.size() > dirty_delta_capacity:
		return {
			"ok": false, "reason": "dirty_delta_capacity_full",
			"spawned_count": 0, "failed_count": spawn_records.size(),
			"object_ids": [],
			"accepted_placement_record_shader_consumed": false,
		}

	# Step 1: Allocate object IDs for all records atomically.
	var object_ids: Array[int] = []
	for _i in range(spawn_records.size()):
		var object_id := _allocate_id()
		if object_id < 0:
			# Rollback: release any IDs we already allocated.
			for free_id in object_ids:
				_free_ids.append(free_id)
			return {
				"ok": false, "reason": "capacity_full_mid_alloc",
				"spawned_count": 0, "failed_count": spawn_records.size(),
				"object_ids": [],
				"accepted_placement_record_shader_consumed": false,
			}
		object_ids.append(object_id)

	# Step 2: Build internal record format.
	# Read generation from GPU resident buffer to preserve recycled-ID state.
	var records: Array[Dictionary] = []
	for i in range(spawn_records.size()):
		var spawn_params: Dictionary = spawn_records[i]
		var object_id := object_ids[i]
		var voxel_min: Vector3i = spawn_params.get("voxel_min", Vector3i.ZERO)
		var voxel_max: Vector3i = spawn_params.get("voxel_max", Vector3i.ONE)
		var dirty_flags: Dictionary = spawn_params.get("dirty_flags", {})
		var generation := _read_generation(object_id)
		records.append({
			"object_id": object_id,
			"profile_id": int(spawn_params.get("profile_id", -1)),
			"object_type": int(spawn_params.get("object_type", 0)),
			"object_flags": _object_flags_from_value(spawn_params.get("object_flags", 0)),
			"generation": generation,
			"voxel_min": voxel_min,
			"voxel_max": voxel_max,
			"previous_voxel_min": voxel_min,
			"previous_voxel_max": voxel_max,
			"transform": spawn_params.get("transform", Transform3D.IDENTITY),
			"dirty_flags": _merge_dirty_flags(dirty_flags),
			"dirty_flag_bits": _dirty_flags_to_bits(dirty_flags),
			"asset_index": int(spawn_params.get("asset_index", -1)),
			"result_index": int(spawn_params.get("result_index", i)),
			"reserved": 0,
		})

	# Step 3: Pack records into the GPU-compatible byte buffer.
	var accepted_placement_record_bytes := _pack_accepted_placement_spawn_records(records)

	# Step 4: Dispatch the GPU shader for batched writeback.
	var shader_options := options.duplicate(true)
	shader_options["use_accepted_placement_record_shader"] = true
	var shader_result := _try_apply_accepted_placement_record_shader(
		records,
		accepted_placement_record_bytes,
		shader_options
	)

	# Step 5: GPU-only path — no CPU bulk write fallback.
	# When the shader fails, return failure directly.
	if not bool(shader_result.get("ok", false)):
		# Rollback: release all allocated IDs on failure.
		for free_id in object_ids:
			_free_ids.append(free_id)
		return {
			"ok": false,
			"reason": str(shader_result.get("reason", "shader_batch_spawn_failed")),
			"spawned_count": 0, "failed_count": spawn_records.size(),
			"object_ids": [],
			"accepted_placement_record_shader_consumed": bool(shader_result.get("accepted_placement_record_shader_consumed", false)),
			"accepted_placement_record_shader_stats": shader_result.get("accepted_placement_record_shader_stats", {}),
			"resident_gpu_allocator_writeback_blocked_reason": str(shader_result.get("resident_gpu_allocator_writeback_blocked_reason", "none")),
		}

	return {
		"ok": true, "reason": "ok",
		"spawned_count": records.size(), "failed_count": 0,
		"object_ids": object_ids,
		"accepted_placement_record_shader_consumed": bool(shader_result.get("accepted_placement_record_shader_consumed", false)),
		"accepted_placement_record_shader_stats": shader_result.get("accepted_placement_record_shader_stats", {}),
		"accepted_placement_record_shader_name": str(shader_result.get("accepted_placement_record_shader_name", "none")),
		"accepted_placement_record_shader_path": str(shader_result.get("accepted_placement_record_shader_path", "none")),
		"accepted_placement_record_shader_dispatch_count": int(shader_result.get("accepted_placement_record_shader_dispatch_count", 0)),
		"runtime_command_flush_mode": str(shader_result.get("runtime_command_flush_mode", "resident_accepted_placement_record_shader_writeback")),
	}


## GPU 常驻批量生成：直接消费 VPG 的 placement/world/stamp-bounds 存储缓冲区
## （无 CPU 回读、无 CPU spawn 记录打包）。对象 ID 在 CPU 端按块预留（数量 =
## result_count，dispatch 前已知），shader 按 reserved_object_ids[record_index]
## 位置消费；generation 由 shader 直接读常驻缓冲区，免除逐条回读。
func spawn_batch_from_accepted_placement_gpu_buffers(
	resident_inputs: Dictionary,
	record_count: int,
	asset_params: Dictionary,
	options: Dictionary = {}
) -> Dictionary:
	var report := {
		"ok": false,
		"reason": "runtime_not_ready",
		"spawned_count": 0,
		"failed_count": maxi(record_count, 0),
		"object_ids": [],
		"runtime_command_flush_mode": "none",
		"accepted_placement_record_source": "vpg_resident_placement_buffers",
		"accepted_placement_record_schema_version": ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION,
		"accepted_placement_record_stride_bytes": 0,
		"accepted_placement_record_count": 0,
		"accepted_placement_record_byte_count": 0,
		"accepted_placement_record_shader_consumed": false,
		"accepted_placement_record_shader_name": "none",
		"accepted_placement_record_shader_path": "none",
		"accepted_placement_record_shader_dispatch_count": 0,
		"accepted_placement_record_shader_local_size_x": ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X,
		"accepted_placement_record_shader_stats": {},
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"resident_gpu_allocator_writeback_blocked_reason": "runtime_not_ready",
		"pending_dirty_delta_count": _dirty_delta_count,
		"gpu_first": true,
		"cpu_fallback": false,
	}
	if not _gpu_ready:
		return report
	if record_count <= 0:
		report["ok"] = true
		report["reason"] = "empty_batch"
		report["failed_count"] = 0
		report["resident_gpu_allocator_writeback_blocked_reason"] = "empty_batch"
		return report
	var placement_results_rid: RID = resident_inputs.get("placement_results_rid", RID())
	var world_results_rid: RID = resident_inputs.get("world_results_rid", RID())
	var stamp_bounds_rid: RID = resident_inputs.get("stamp_bounds_rid", RID())
	if not placement_results_rid.is_valid() or not world_results_rid.is_valid() or not stamp_bounds_rid.is_valid():
		report["reason"] = "invalid_resident_input_rid"
		report["resident_gpu_allocator_writeback_blocked_reason"] = "invalid_resident_input_rid"
		return report
	if _free_ids.size() < record_count:
		report["reason"] = "capacity_full"
		report["resident_gpu_allocator_writeback_blocked_reason"] = "capacity_full"
		return report
	if _dirty_delta_count + record_count > dirty_delta_capacity:
		report["reason"] = "dirty_delta_capacity_full"
		report["resident_gpu_allocator_writeback_blocked_reason"] = "dirty_delta_capacity_full"
		return report

	# Block-reserve object IDs for positional consumption by the shader.
	# No per-id alive/generation readback: the shader guards already-alive
	# slots and reads generation from the resident buffer.
	var object_ids: Array[int] = []
	for _i in range(record_count):
		var object_id := _allocate_id()
		if object_id < 0:
			for free_id in object_ids:
				_free_ids.append(free_id)
			report["reason"] = "capacity_full_mid_alloc"
			report["resident_gpu_allocator_writeback_blocked_reason"] = "capacity_full_mid_alloc"
			return report
		object_ids.append(object_id)
	var reserved_bytes := PackedByteArray()
	reserved_bytes.resize(record_count * 4)
	for i in range(record_count):
		reserved_bytes.encode_s32(i * 4, object_ids[i])

	var dispatch_result := _dispatch_accepted_placement_resident_shader(
		placement_results_rid,
		world_results_rid,
		stamp_bounds_rid,
		reserved_bytes,
		record_count,
		asset_params,
		options
	)
	if not bool(dispatch_result.get("ok", false)):
		# Rollback only when the shader never ran; after a dispatch the IDs may
		# be alive on the GPU and returning them to the free list would corrupt it.
		if not bool(dispatch_result.get("applied_on_gpu", false)):
			for free_id in object_ids:
				_free_ids.append(free_id)
		report["reason"] = str(dispatch_result.get("reason", "resident_shader_dispatch_failed"))
		report["resident_gpu_allocator_writeback_blocked_reason"] = report["reason"]
		report["accepted_placement_record_shader_stats"] = dispatch_result.get("accepted_placement_record_shader_stats", {})
		report["pending_dirty_delta_count"] = _dirty_delta_count
		return report

	report["ok"] = true
	report["reason"] = "ok"
	report["spawned_count"] = record_count
	report["failed_count"] = 0
	report["object_ids"] = object_ids
	report["runtime_command_flush_mode"] = "resident_accepted_placement_record_shader_writeback"
	report["accepted_placement_record_count"] = record_count
	report["accepted_placement_record_shader_consumed"] = true
	report["accepted_placement_record_shader_name"] = ACCEPTED_PLACEMENT_RESIDENT_SHADER_NAME
	report["accepted_placement_record_shader_path"] = ACCEPTED_PLACEMENT_RESIDENT_SHADER_PATH
	report["accepted_placement_record_shader_dispatch_count"] = int(dispatch_result.get("dispatch_group_count", 0))
	report["accepted_placement_record_shader_stats"] = dispatch_result.get("accepted_placement_record_shader_stats", {})
	report["resident_gpu_allocator_writeback"] = true
	report["resident_gpu_allocator_writeback_mode"] = "resident_object_buffer_writeback"
	report["resident_gpu_allocator_writeback_blocked_reason"] = "none"
	report["resident_gpu_allocator_owner"] = "GPUAutoObjectRuntime"
	report["pending_dirty_delta_count"] = _dirty_delta_count
	return report


## 构建双 uniform set（set0=VPG 常驻输入，set1=运行时状态）并调度常驻放置 shader。
## 生产路径零回读：dirty 计数用算术镜像；debug_read_stats 仅调试用。
func _dispatch_accepted_placement_resident_shader(
	placement_results_rid: RID,
	world_results_rid: RID,
	stamp_bounds_rid: RID,
	reserved_id_bytes: PackedByteArray,
	record_count: int,
	asset_params: Dictionary,
	options: Dictionary
) -> Dictionary:
	if _rd == null or not _all_required_buffers_valid():
		return {"ok": false, "reason": "runtime_not_ready", "applied_on_gpu": false}
	var dirty_base := _dirty_delta_count
	var reserved_ids_buffer := storage_buffer_from_bytes(reserved_id_bytes, SCOPE_FRAME, "autoobject_resident_reserved_object_ids")
	var stats_buffer := storage_buffer_zero(ACCEPTED_PLACEMENT_RECORD_SHADER_STATS_U32_COUNT * 4, SCOPE_FRAME, "autoobject_resident_accepted_placement_stats")
	var shader := load_compute_shader(ACCEPTED_PLACEMENT_RESIDENT_SHADER_PATH, SCOPE_FRAME, ACCEPTED_PLACEMENT_RESIDENT_SHADER_NAME)
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "autoobject_apply_accepted_placements_resident")
	if not reserved_ids_buffer.is_valid() or not stats_buffer.is_valid() or not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		return {"ok": false, "reason": "resident_shader_setup_failed", "applied_on_gpu": false}
	var set0 := create_uniform_set([
		make_storage_uniform(0, placement_results_rid),
		make_storage_uniform(1, world_results_rid),
		make_storage_uniform(2, stamp_bounds_rid),
		make_storage_uniform(3, reserved_ids_buffer),
	], shader, 0, SCOPE_FRAME, "autoobject_resident_accepted_placement_set0")
	var set1 := create_uniform_set(
		_pack_accepted_placement_uniforms(0, stats_buffer),
		shader, 1, SCOPE_FRAME, "autoobject_resident_accepted_placement_set1"
	)
	if not set0.is_valid() or not set1.is_valid():
		gc_frame()
		return {"ok": false, "reason": "resident_shader_uniform_set_failed", "applied_on_gpu": false}

	var grid_value = asset_params.get("grid_size", Vector3i.ZERO)
	var grid_size: Vector3i = grid_value if grid_value is Vector3i else Vector3i.ZERO
	var dirty_bits := int(asset_params.get(
		"dirty_flag_bits",
		_dirty_flags_to_bits(asset_params.get("dirty_flags", {}) if asset_params.get("dirty_flags", {}) is Dictionary else {})
	))
	var push := PushConstantLayout.new(RESIDENT_PLACEMENT_PUSH).pack({
		record_count = record_count,
		max_objects = max_objects,
		dirty_delta_capacity = dirty_delta_capacity,
		dirty_base = dirty_base,
		profile_id = int(asset_params.get("profile_id", -1)),
		object_type = int(asset_params.get("object_type", 0)),
		object_flags = _object_flags_from_value(asset_params.get("object_flags", 0)),
		dirty_bits = dirty_bits,
		asset_index = int(asset_params.get("asset_index", -1)),
		flush_epoch = _flush_epoch,
		stats_u32_count = ACCEPTED_PLACEMENT_RECORD_SHADER_STATS_U32_COUNT,
		grid_x = grid_size.x,
		grid_y = grid_size.y,
		grid_z = grid_size.z,
	})

	var group_count := ceil_div(record_count, ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X)
	var cl := begin_compute_list()
	if cl < 0:
		gc_frame()
		return {"ok": false, "reason": "resident_shader_compute_list_failed", "applied_on_gpu": false}
	_gpu_dispatch_pipeline_sets(cl, pipeline, [set0, set1], push, Vector3i(group_count, 1, 1))
	end_compute_list()
	# include_global_device=true: when the runtime is attached to a shared
	# (committer-owned) device, the no-arg form would no-op and leave this
	# dispatch unsubmitted until the owner's next submit.
	submit_and_sync(true)

	var result := {
		"ok": true,
		"reason": "ok",
		"applied_on_gpu": true,
		"dispatch_group_count": group_count,
		"accepted_placement_record_shader_stats": {},
	}
	if bool(options.get("debug_read_stats", false)):
		var stats := _read_accepted_placement_record_shader_stats(stats_buffer)
		var count_result := _read_dirty_delta_count_result()
		gc_frame()
		result["accepted_placement_record_shader_stats"] = stats
		var stats_ok := int(stats.get("applied", 0)) == record_count \
			and int(stats.get("skipped", 0)) == 0
		if not bool(count_result.get("ok", false)):
			result["ok"] = false
			result["reason"] = str(count_result.get("reason", "dirty_count_readback_failed"))
			return result
		_dirty_delta_count = int(count_result.get("count", _dirty_delta_count))
		if not stats_ok:
			result["ok"] = false
			result["reason"] = "resident_shader_stats_failed"
			return result
	else:
		# Production path: no readback, trust GPU execution after submit+sync barrier.
		gc_frame()
		_dirty_delta_count = dirty_base + record_count
		result["accepted_placement_record_shader_stats"] = {
			"ok": true,
			"reason": "deferred_no_readback",
			"readback_source": "none",
		}
	return result


## 将运行时绑定到 SceneVoxelCommitter 的 RenderingDevice，并按需重新配置容量。
func setup_for_scene_voxel_committer(
	committer,
	p_max_objects: int = -1,
	p_enable_gpu: bool = true
) -> Dictionary:
	var result := {
		"ok": false,
		"reason": "unknown",
		"runtime_ready": _gpu_ready,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "none",
		"rendering_device_source": "none",
		"same_rendering_device": false,
		"buffers_allocated_before_setup": _has_allocated_gpu_buffers(),
		"max_objects": max_objects,
		"dirty_delta_capacity": dirty_delta_capacity,
	}
	if committer == null or not committer.has_method("get_rendering_device"):
		result["reason"] = "committer_rendering_device_not_available"
		return result

	var committer_rd = rendering_device_of(committer)
	if committer_rd == null:
		result["reason"] = "committer_rendering_device_not_ready"
		return result

	if _rd != null and _rd != committer_rd and _has_allocated_gpu_buffers():
		result["reason"] = "runtime_buffers_already_allocated_on_different_rendering_device"
		result["runtime_rendering_device_ready"] = true
		result["committer_rendering_device_ready"] = true
		return result

	if _rd != null and _rd != committer_rd:
		dispose(false)

	if _rd == null:
		if not attach_rendering_device(committer_rd, false):
			result["reason"] = "attach_rendering_device_failed"
			return result
	elif _rd == committer_rd:
		_owns_rendering_device = false
		_disposed = false

	var resolved_capacity := p_max_objects if p_max_objects >= 0 else max_objects
	configure_capacity(resolved_capacity, p_enable_gpu)

	result["ok"] = _gpu_ready
	result["reason"] = "ok" if _gpu_ready else _not_ready_reason
	result["runtime_ready"] = _gpu_ready
	result["rendering_device_source"] = "SceneVoxelCommitter"
	result["same_rendering_device"] = _rd != null and _rd == committer_rd
	result["buffers_allocated_after_setup"] = _has_allocated_gpu_buffers()
	result["max_objects"] = max_objects
	result["dirty_delta_capacity"] = dirty_delta_capacity
	result["readback_source"] = "gpu_storage_buffers" if _gpu_ready else "none"
	return result


## 从空闲池分配对象 ID，写入初始状态并追加 dirty delta，返回新对象 ID（失败返回 -1）。
func spawn(
	profile_id: int,
	object_type: int,
	voxel_min: Vector3i,
	voxel_max: Vector3i,
	transform: Transform3D = Transform3D.IDENTITY,
	dirty_flags: Dictionary = {},
	object_flags: int = 0
) -> int:
	if not _can_accept_object_command():
		return -1
	if not _can_append_dirty_delta():
		return -1

	var object_id := _allocate_id()
	if object_id < 0:
		return -1
	var spawned_id := _spawn_with_reserved_id(
		object_id,
		profile_id,
		object_type,
		voxel_min,
		voxel_max,
		transform,
		dirty_flags,
		object_flags
	)
	if spawned_id < 0:
		_free_ids.append(object_id)
	return spawned_id


## 使用已分配的对象 ID 写入初始对象状态并追加 dirty delta。
func _spawn_with_reserved_id(
	object_id: int,
	profile_id: int,
	object_type: int,
	voxel_min: Vector3i,
	voxel_max: Vector3i,
	transform: Transform3D = Transform3D.IDENTITY,
	dirty_flags: Dictionary = {},
	object_flags: int = 0
) -> int:
	if not _can_accept_object_command():
		return -1
	if not _is_valid_id(object_id):
		return -1
	if not _can_append_dirty_delta():
		return -1
	var previous := _read_object_state(object_id)
	if bool(previous.get("alive", false)):
		return -1

	var bounds := _normalize_bounds(voxel_min, voxel_max)
	var generation := _read_generation(object_id)
	var ok := _write_object_state(
		object_id,
		true,
		generation,
		profile_id,
		object_type,
		bounds.voxel_min,
		bounds.voxel_max,
		bounds.voxel_min,
		bounds.voxel_max,
		transform,
		object_flags
	)
	if not ok:
		return -1

	if not _append_dirty_delta(
		object_id,
		object_type,
		profile_id,
		generation,
		bounds.voxel_min,
		bounds.voxel_max,
		bounds.voxel_min,
		bounds.voxel_max,
		_merge_dirty_flags(dirty_flags),
		false,
		true
	):
		return -1

	return object_id


## 从参数字典中解析边界后调用 spawn，便于字典驱动的生成接口。
func spawn_from_bounds(params: Dictionary) -> int:
	var bounds := _bounds_from_params(params)
	return spawn(
		int(params.get("profile_id", -1)),
		int(params.get("object_type", 0)),
		bounds.voxel_min,
		bounds.voxel_max,
		params.get("transform", Transform3D.IDENTITY),
		params.get("dirty_flags", {}),
		_object_flags_from_value(params.get("object_flags", 0))
	)


## 更新已存活对象的变换和边界，追加 dirty delta 记录。
func update_transform(
	object_id: int,
	transform: Transform3D,
	voxel_min: Vector3i,
	voxel_max: Vector3i,
	dirty_flags: Dictionary = {}
) -> bool:
	if not _can_accept_object_command():
		return false
	if not _is_valid_id(object_id):
		return false
	if not _can_append_dirty_delta():
		return false

	var previous := _read_object_state(object_id)
	if not bool(previous.get("alive", false)):
		return false

	var previous_min: Vector3i = previous.get("voxel_min", Vector3i.ZERO)
	var previous_max: Vector3i = previous.get("voxel_max", previous_min + Vector3i.ONE)
	var bounds := _normalize_bounds(voxel_min, voxel_max)
	var generation := int(previous.get("generation", 0))
	var profile_id := int(previous.get("profile_id", -1))
	var object_type := int(previous.get("object_type", 0))
	var object_flags := int(previous.get("object_flags", 0))

	if not _write_object_state(
		object_id,
		true,
		generation,
		profile_id,
		object_type,
		bounds.voxel_min,
		bounds.voxel_max,
		previous_min,
		previous_max,
		transform,
		object_flags
	):
		return false

	return _append_dirty_delta(
		object_id,
		object_type,
		profile_id,
		generation,
		previous_min,
		previous_max,
		bounds.voxel_min,
		bounds.voxel_max,
		_merge_dirty_flags(dirty_flags),
		false,
		true
	)


## 用新边界更新对象（保留当前变换），内部委托给 update_transform。
func update_bounds(object_id: int, voxel_min: Vector3i, voxel_max: Vector3i, dirty_flags: Dictionary = {}) -> bool:
	if not _is_valid_id(object_id):
		return false
	var snapshot := _read_object_state(object_id)
	var transform: Transform3D = snapshot.get("transform", Transform3D.IDENTITY)
	return update_transform(object_id, transform, voxel_min, voxel_max, dirty_flags)


## 更新对象的 profile_id，可选同时更新边界，追加 dirty delta。
func update_profile(object_id: int, profile_id: int, arg3 = {}, arg4 = null, arg5 = null) -> bool:
	if not _can_accept_object_command():
		return false
	if not _is_valid_id(object_id):
		return false
	if not _can_append_dirty_delta():
		return false

	var dirty_flags: Dictionary = {}
	var voxel_min = null
	var voxel_max = null
	if arg3 is Dictionary:
		dirty_flags = arg3 as Dictionary
		voxel_min = arg4
		voxel_max = arg5
	else:
		voxel_min = arg3
		voxel_max = arg4
		if arg5 is Dictionary:
			dirty_flags = arg5 as Dictionary

	var previous := _read_object_state(object_id)
	if not bool(previous.get("alive", false)):
		return false

	var previous_min: Vector3i = previous.get("voxel_min", Vector3i.ZERO)
	var previous_max: Vector3i = previous.get("voxel_max", previous_min + Vector3i.ONE)
	var new_min := VoxelGeneral.vector3i_from_value(voxel_min, previous_min)
	var new_max := VoxelGeneral.vector3i_from_value(voxel_max, previous_max)
	var bounds := _normalize_bounds(new_min, new_max)
	var generation := int(previous.get("generation", 0))
	var object_type := int(previous.get("object_type", 0))
	var object_flags := int(previous.get("object_flags", 0))
	var transform: Transform3D = previous.get("transform", Transform3D.IDENTITY)

	if not _write_object_state(
		object_id,
		true,
		generation,
		profile_id,
		object_type,
		bounds.voxel_min,
		bounds.voxel_max,
		previous_min,
		previous_max,
		transform,
		object_flags
	):
		return false

	return _append_dirty_delta(
		object_id,
		object_type,
		profile_id,
		generation,
		previous_min,
		previous_max,
		bounds.voxel_min,
		bounds.voxel_max,
		_merge_dirty_flags(dirty_flags),
		false,
		true
	)


## 更新对象的 object_flags 位掩码，追加 dirty delta。
func update_flags(object_id: int, object_flags, dirty_flags: Dictionary = {}) -> bool:
	if not _can_accept_object_command():
		return false
	if not _is_valid_id(object_id):
		return false
	if not _can_append_dirty_delta():
		return false

	var previous := _read_object_state(object_id)
	if not bool(previous.get("alive", false)):
		return false

	var previous_min: Vector3i = previous.get("voxel_min", Vector3i.ZERO)
	var previous_max: Vector3i = previous.get("voxel_max", previous_min + Vector3i.ONE)
	var generation := int(previous.get("generation", 0))
	var profile_id := int(previous.get("profile_id", -1))
	var object_type := int(previous.get("object_type", 0))
	var packed_flags := _object_flags_from_value(object_flags)
	var transform: Transform3D = previous.get("transform", Transform3D.IDENTITY)

	if not _write_object_state(
		object_id,
		true,
		generation,
		profile_id,
		object_type,
		previous_min,
		previous_max,
		previous_min,
		previous_max,
		transform,
		packed_flags
	):
		return false

	return _append_dirty_delta(
		object_id,
		object_type,
		profile_id,
		generation,
		previous_min,
		previous_max,
		previous_min,
		previous_max,
		_merge_dirty_flags(dirty_flags),
		false,
		true
	)


## 销毁对象：写入 alive=false、generation+1，并将 ID 归还空闲池，追加 dirty delta。
func kill(object_id: int, dirty_flags: Dictionary = {}) -> bool:
	if not _can_accept_object_command():
		return false
	if not _is_valid_id(object_id):
		return false
	if not _can_append_dirty_delta():
		return false

	var previous := _read_object_state(object_id)
	if not bool(previous.get("alive", false)):
		return false

	var previous_min: Vector3i = previous.get("voxel_min", Vector3i.ZERO)
	var previous_max: Vector3i = previous.get("voxel_max", previous_min + Vector3i.ONE)
	var generation := int(previous.get("generation", 0)) + 1
	var profile_id := int(previous.get("profile_id", -1))
	var object_type := int(previous.get("object_type", 0))
	var object_flags := int(previous.get("object_flags", 0))
	var transform: Transform3D = previous.get("transform", Transform3D.IDENTITY)

	if not _write_object_state(
		object_id,
		false,
		generation,
		profile_id,
		object_type,
		previous_min,
		previous_max,
		previous_min,
		previous_max,
		transform,
		object_flags
	):
		return false

	_free_ids.append(object_id)
	return _append_dirty_delta(
		object_id,
		object_type,
		profile_id,
		generation,
		previous_min,
		previous_max,
		previous_min,
		previous_max,
		_merge_dirty_flags(dirty_flags),
		true,
		false
	)


## 尝试通过 GPU 着色器批量写入接受放置记录；成功返回 ok=true，未启用则直接返回被阻塞结果。
func _try_apply_accepted_placement_record_shader(
	records: Array[Dictionary],
	accepted_placement_record_bytes: PackedByteArray,
	options: Dictionary
) -> Dictionary:
	var base_result := {
		"ok": false,
		"reason": "accepted_placement_record_shader_not_enabled",
		"attempted": false,
		"runtime_command_flush_mode": "cpu_bulk_spawn_buffer_update",
		"accepted_placement_record_shader_consumed": false,
		"accepted_placement_record_shader_name": "none",
		"accepted_placement_record_shader_path": "none",
		"accepted_placement_record_shader_dispatch_count": 0,
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"resident_gpu_allocator_writeback_blocked_reason": "no_resident_allocator_shader_dispatch",
		"pending_dirty_delta_count": _dirty_delta_count,
	}
	if not bool(options.get("use_accepted_placement_record_shader", false)):
		return base_result
	base_result["attempted"] = true
	base_result["runtime_command_flush_mode"] = "resident_accepted_placement_record_shader_writeback"
	base_result["accepted_placement_record_shader_name"] = ACCEPTED_PLACEMENT_RECORD_SHADER_NAME
	base_result["accepted_placement_record_shader_path"] = ACCEPTED_PLACEMENT_RECORD_SHADER_PATH
	if records.is_empty():
		base_result["ok"] = true
		base_result["reason"] = "ok"
		base_result["pending_dirty_delta_count"] = _dirty_delta_count
		return base_result
	if not _gpu_ready or _rd == null or not _all_required_buffers_valid():
		base_result["reason"] = "runtime_not_ready"
		base_result["resident_gpu_allocator_writeback_blocked_reason"] = "runtime_not_ready"
		return base_result
	if accepted_placement_record_bytes.size() != records.size() * ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES:
		base_result["reason"] = "accepted_placement_record_pack_failed"
		base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_pack_failed"
		return base_result

	var dirty_base := _dirty_delta_count
	var record_count := records.size()
	var accepted_buffer := storage_buffer_from_bytes(
		accepted_placement_record_bytes,
		SCOPE_FRAME,
		"autoobject_accepted_placement_records"
	)
	var stats_buffer := storage_buffer_zero(
		ACCEPTED_PLACEMENT_RECORD_SHADER_STATS_U32_COUNT * 4,
		SCOPE_FRAME,
		"autoobject_accepted_placement_record_stats"
	)
	var shader := load_compute_shader(
		ACCEPTED_PLACEMENT_RECORD_SHADER_PATH,
		SCOPE_FRAME,
		ACCEPTED_PLACEMENT_RECORD_SHADER_NAME
	)
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "autoobject_apply_accepted_placements")
	if not accepted_buffer.is_valid() or not stats_buffer.is_valid() or not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		base_result["reason"] = "accepted_placement_record_shader_setup_failed"
		base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_shader_setup_failed"
		return base_result

	var uniforms := [make_storage_uniform(0, accepted_buffer)]
	uniforms.append_array(_pack_accepted_placement_uniforms(1, stats_buffer))
	var uniform_set := create_uniform_set(uniforms, shader, 0, SCOPE_FRAME, "autoobject_apply_accepted_placements_set0")
	if not uniform_set.is_valid():
		gc_frame()
		base_result["reason"] = "accepted_placement_record_uniform_set_failed"
		base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_uniform_set_failed"
		return base_result

	var push := _pack_accepted_placement_record_shader_push(
		record_count,
		max_objects,
		dirty_delta_capacity,
		dirty_base,
		_flush_epoch,
		int(options.get("accepted_placement_record_shader_options", 0))
	)
	var group_count := ceil_div(record_count, ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X)
	var cl := begin_compute_list()
	if cl < 0:
		gc_frame()
		base_result["reason"] = "accepted_placement_record_compute_list_failed"
		base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_compute_list_failed"
		return base_result
	_gpu_dispatch_pipeline_sets(cl, pipeline, [uniform_set], push, Vector3i(group_count, 1, 1))
	end_compute_list()
	submit_and_sync()

	# P0 #9: Stats readback is debug-only. Production path uses fence+barrier without readback.
	var readback_stats := bool(options.get("debug_read_stats", false))
	if readback_stats:
		var stats := _read_accepted_placement_record_shader_stats(stats_buffer)
		var stats_ok := int(stats.get("applied", 0)) == record_count \
			and int(stats.get("invalid_object_id", 0)) == 0 \
			and int(stats.get("dirty_overflow", 0)) == 0 \
			and int(stats.get("already_alive", 0)) == 0 \
			and int(stats.get("skipped", 0)) == 0 \
			and int(stats.get("dispatched", 0)) == 1
		var count_result := _read_dirty_delta_count_result()
		base_result["accepted_placement_record_shader_stats"] = stats
		base_result["accepted_placement_record_shader_dispatch_count"] = group_count
		gc_frame()
		if not bool(count_result.get("ok", false)):
			base_result["reason"] = str(count_result.get("reason", "dirty_count_readback_failed"))
			base_result["failed_readback_source"] = str(count_result.get("failed_readback_source", "gpu_dirty_count_buffer"))
			base_result["resident_gpu_allocator_writeback_blocked_reason"] = "dirty_count_readback_failed"
			return base_result
		_dirty_delta_count = int(count_result.get("count", _dirty_delta_count))
		base_result["pending_dirty_delta_count"] = _dirty_delta_count
		if not stats_ok:
			base_result["reason"] = "accepted_placement_record_shader_stats_failed"
			base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_shader_stats_failed"
			return base_result
		if _dirty_delta_count != dirty_base + record_count:
			base_result["reason"] = "accepted_placement_record_dirty_count_mismatch"
			base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_dirty_count_mismatch"
			return base_result
	else:
		# Production path: no readback, trust GPU execution after submit+sync barrier.
		gc_frame()
		_dirty_delta_count = dirty_base + record_count
		base_result["pending_dirty_delta_count"] = _dirty_delta_count
		base_result["accepted_placement_record_shader_dispatch_count"] = group_count
		base_result["accepted_placement_record_shader_stats"] = {
			"ok": true,
			"reason": "deferred_no_readback",
			"readback_source": "none",
		}

	base_result["ok"] = true
	base_result["reason"] = "ok"
	base_result["accepted_placement_record_shader_consumed"] = true
	base_result["resident_gpu_allocator_writeback_mode"] = "resident_object_buffer_writeback"
	base_result["resident_gpu_allocator_writeback_blocked_reason"] = "none"
	return base_result


## 将内部记录字典数组打包为 GPU 着色器所需的字节缓冲区（每条记录 128 字节）。
func _pack_accepted_placement_spawn_records(records: Array[Dictionary]) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(records.size() * ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES)
	for i in range(records.size()):
		var record := records[i]
		var base := i * ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES
		var voxel_min: Vector3i = record.get("voxel_min", Vector3i.ZERO)
		var voxel_max: Vector3i = record.get("voxel_max", Vector3i.ONE)
		var transform: Transform3D = record.get("transform", Transform3D.IDENTITY)
		bytes.encode_s32(base + ACCEPTED_PLACEMENT_RECORD_OBJECT_ID_OFFSET, int(record.get("object_id", -1)))
		bytes.encode_s32(base + ACCEPTED_PLACEMENT_RECORD_PROFILE_ID_OFFSET, int(record.get("profile_id", -1)))
		bytes.encode_s32(base + ACCEPTED_PLACEMENT_RECORD_OBJECT_TYPE_OFFSET, int(record.get("object_type", 0)))
		bytes.encode_s32(base + ACCEPTED_PLACEMENT_RECORD_OBJECT_FLAGS_OFFSET, int(record.get("object_flags", 0)))
		BufferUtils.encode_vec3i4(bytes, base + ACCEPTED_PLACEMENT_RECORD_VOXEL_MIN_OFFSET, voxel_min)
		BufferUtils.encode_vec3i4(bytes, base + ACCEPTED_PLACEMENT_RECORD_VOXEL_MAX_OFFSET, voxel_max)
		BufferUtils.encode_transform_mat4(bytes, base + ACCEPTED_PLACEMENT_RECORD_TRANSFORM_OFFSET, transform)
		bytes.encode_s32(base + ACCEPTED_PLACEMENT_RECORD_DIRTY_FLAGS_OFFSET, int(record.get("dirty_flag_bits", _dirty_flags_to_bits(record.get("dirty_flags", {})))))
		bytes.encode_s32(base + ACCEPTED_PLACEMENT_RECORD_ASSET_INDEX_OFFSET, int(record.get("asset_index", -1)))
		bytes.encode_s32(base + ACCEPTED_PLACEMENT_RECORD_RESULT_INDEX_OFFSET, int(record.get("result_index", i)))
		bytes.encode_s32(base + ACCEPTED_PLACEMENT_RECORD_RESERVED_OFFSET, int(record.get("reserved", 0)))
	return bytes


## 构造接受放置记录着色器所需的 push constant 字节（32 字节）。
func _pack_accepted_placement_record_shader_push(
	record_count: int,
	runtime_capacity: int,
	p_dirty_delta_capacity: int,
	dirty_base: int,
	flush_epoch: int,
	options: int
) -> PackedByteArray:
	return PushConstantLayout.new(ACCEPTED_PLACEMENT_RECORD_PUSH).pack({
		record_count = record_count,
		runtime_capacity = runtime_capacity,
		dirty_delta_capacity = p_dirty_delta_capacity,
		dirty_base = dirty_base,
		flush_epoch = flush_epoch,
		options = options,
		stats_u32_count = ACCEPTED_PLACEMENT_RECORD_SHADER_STATS_U32_COUNT,
	})



## 组装接受放置 shader 共享的对象状态 uniform 块（alive..stats 共 13 个存储缓冲区，
## 按固定顺序绑定，起始 binding 由 base_binding 决定）。两条 dispatch 路径共用此块：
## 记录路径把它拼在 accepted_buffer(binding 0) 之后（base_binding=1，同一 set0），
## 驻留路径把它单独放到 set1（base_binding=0）。
func _pack_accepted_placement_uniforms(base_binding: int, stats_buffer: RID) -> Array:
	return [
		make_storage_uniform(base_binding + 0, _alive_buffer),
		make_storage_uniform(base_binding + 1, _generation_buffer),
		make_storage_uniform(base_binding + 2, _type_buffer),
		make_storage_uniform(base_binding + 3, _profile_buffer),
		make_storage_uniform(base_binding + 4, _flags_buffer),
		make_storage_uniform(base_binding + 5, _bounds_min_buffer),
		make_storage_uniform(base_binding + 6, _bounds_max_buffer),
		make_storage_uniform(base_binding + 7, _previous_bounds_min_buffer),
		make_storage_uniform(base_binding + 8, _previous_bounds_max_buffer),
		make_storage_uniform(base_binding + 9, _transform_buffer),
		make_storage_uniform(base_binding + 10, _dirty_delta_buffer),
		make_storage_uniform(base_binding + 11, _dirty_count_buffer),
		make_storage_uniform(base_binding + 12, stats_buffer),
	]


## 从 stats 缓冲区读回接受放置着色器的统计信息（调试路径）。
# Debug-only: reads GPU stats buffer via buffer_get_data after accepted placement shader dispatch.
# Production path (debug_read_stats=false) skips this readback entirely.
func _read_accepted_placement_record_shader_stats(stats_buffer: RID) -> Dictionary:
	var bytes := _read_buffer_bytes(stats_buffer, 0, ACCEPTED_PLACEMENT_RECORD_SHADER_STATS_U32_COUNT * 4)
	if bytes.size() < ACCEPTED_PLACEMENT_RECORD_SHADER_STATS_U32_COUNT * 4:
		return {
			"ok": false,
			"reason": "accepted_placement_record_stats_readback_failed",
			"readback_source": "none",
			"failed_readback_source": "accepted_placement_record_stats_buffer",
		}
	return {
		"ok": true,
		"reason": "ok",
		"applied": bytes.decode_u32(ACCEPTED_PLACEMENT_RECORD_STAT_APPLIED * 4),
		"invalid_object_id": bytes.decode_u32(ACCEPTED_PLACEMENT_RECORD_STAT_INVALID_OBJECT_ID * 4),
		"dirty_overflow": bytes.decode_u32(ACCEPTED_PLACEMENT_RECORD_STAT_DIRTY_OVERFLOW * 4),
		"already_alive": bytes.decode_u32(ACCEPTED_PLACEMENT_RECORD_STAT_ALREADY_ALIVE * 4),
		"skipped": bytes.decode_u32(ACCEPTED_PLACEMENT_RECORD_STAT_SKIPPED * 4),
		"record_count": bytes.decode_u32(ACCEPTED_PLACEMENT_RECORD_STAT_RECORD_COUNT * 4),
		"dirty_base": bytes.decode_u32(ACCEPTED_PLACEMENT_RECORD_STAT_DIRTY_BASE * 4),
		"dispatched": bytes.decode_u32(ACCEPTED_PLACEMENT_RECORD_STAT_DISPATCHED * 4),
		"readback_source": "accepted_placement_record_stats_buffer",
	}


# P0 Task #2: Resident GPU dirty delta → SceneVoxelTile update pass.
# 此方法现在是默认路径：dirty delta 从 GPU→GPU 常驻，CPU 不再逐 delta 更新字典。
# 仅在 resident path 阻塞（无 RD、buffer 未上传等）时回退到 CPU bridge。
## 尝试通过 GPU 驻留 dirty delta 缓冲区直接触发 SceneVoxelCommitter 的对象引用更新 Pass。
func _try_flush_resident_dirty_delta_buffer_to_scene_voxel_committer(committer, options: Dictionary) -> Dictionary:
	var result := {
		"ok": false,
		"reason": "resident_dirty_delta_update_pass_not_enabled",
		"blocked": true,
		"dirty_delta_count": 0,
		"pending_dirty_delta_count": get_pending_dirty_delta_count(),
		"runtime_ready": _gpu_ready,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "none",
		"failed_readback_source": "none",
		"dirty_delta_bridge_mode": "none",
		"dirty_delta_apply_api": "none",
		"resident_gpu_dirty_delta_update_pass": false,
		"resident_gpu_dirty_delta_update_pass_owner": "none",
		"resident_gpu_dirty_delta_update_pass_shader": "none",
		"resident_gpu_dirty_delta_update_pass_dispatch_count": 0,
		"object_ref_update_result": {},
	}
	# P0: 默认启用 resident GPU update pass，不再需要 opt-in flag。
	# 若调用方需要强制 CPU fallback，应直接调用 committer.apply_gpu_autoobject_dirty_deltas()。
	if committer == null or not committer.has_method("try_apply_gpu_autoobject_object_ref_update_pass_from_buffer"):
		result["reason"] = "missing_resident_dirty_delta_buffer_api"
		return result
	if not _gpu_ready or _rd == null:
		result["reason"] = "runtime_not_ready"
		return result
	if not _dirty_delta_buffer.is_valid():
		result["reason"] = "dirty_delta_buffer_not_ready"
		return result
	if not committer.has_method("get_rendering_device"):
		result["reason"] = "committer_rendering_device_not_available"
		return result

	var committer_rd = rendering_device_of(committer)
	if committer_rd == null and bool(options.get("attach_committer_rendering_device", false)) and committer.has_method("attach_rendering_device"):
		if bool(committer.call("attach_rendering_device", _rd, false)):
			committer_rd = rendering_device_of(committer)
	if committer_rd == null:
		result["reason"] = "committer_rendering_device_not_ready"
		return result
	if committer_rd != _rd:
		result["reason"] = "rendering_device_mismatch"
		return result

	var count_result := _read_dirty_delta_count_result()
	if not bool(count_result.get("ok", false)):
		result["reason"] = str(count_result.get("reason", "dirty_count_readback_failed"))
		result["pending_dirty_delta_count"] = int(count_result.get("count", _dirty_delta_count))
		result["failed_readback_source"] = str(count_result.get("failed_readback_source", "gpu_dirty_count_buffer"))
		return result
	var dirty_delta_count := int(count_result.get("count", 0))
	result["dirty_delta_count"] = dirty_delta_count
	result["pending_dirty_delta_count"] = dirty_delta_count
	if dirty_delta_count <= 0:
		result["reason"] = "empty_dirty_delta_batch"
		return result

	var update_result: Dictionary = committer.call(
		"try_apply_gpu_autoobject_object_ref_update_pass_from_buffer",
		_dirty_delta_buffer,
		dirty_delta_count,
		dirty_delta_capacity,
		"gpu_autoobject_runtime_autoobject_dirty_delta"
	)
	var dispatched := bool(update_result.get("resident_gpu_dirty_delta_update_pass", false))
	if not dispatched:
		result.merge(update_result, true)
		result["blocked"] = true
		result["pending_dirty_delta_count"] = dirty_delta_count
		return result

	result.merge(update_result, true)
	result["blocked"] = false
	result["dirty_delta_count"] = dirty_delta_count
	result["pending_dirty_delta_count"] = dirty_delta_count
	result["dirty_deltas"] = []
	result["results"] = [update_result]
	result["commit_result_count"] = 1
	result["failed_commit_result_count"] = 0 if bool(update_result.get("ok", false)) else 1
	result["runtime_ready"] = _gpu_ready
	result["gpu_first"] = true
	result["cpu_fallback"] = false
	result["readback_source"] = "borrowed_gpu_dirty_delta_buffer"
	result["failed_readback_source"] = "none"
	if bool(update_result.get("ok", false)):
		if _write_dirty_count(0):
			_flush_epoch += 1
			result["pending_dirty_delta_count"] = get_pending_dirty_delta_count()
		else:
			result["ok"] = false
			result["reason"] = "dirty_count_write_failed"
			result["failed_readback_source"] = "gpu_dirty_count_buffer"
	return result


## 将所有 dirty delta 提交给 SceneVoxelCommitter：优先走 GPU 驻留路径，阻塞时直接返回失败。
func flush_to_scene_voxel_committer(committer, options: Dictionary = {}) -> Dictionary:
	if not _gpu_ready:
		return {
			"ok": false,
			"reason": "runtime_not_ready",
			"dirty_deltas": [],
			"dirty_delta_count": 0,
			"results": [],
			"commit_result_count": 0,
			"failed_commit_result_count": 0,
			"runtime_ready": false,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
			"dirty_delta_bridge_mode": "none",
			"dirty_delta_apply_api": "none",
			"resident_gpu_dirty_delta_update_pass": false,
			"resident_gpu_dirty_delta_update_pass_owner": "none",
			"resident_gpu_dirty_delta_update_pass_shader": "none",
			"resident_gpu_dirty_delta_update_pass_dispatch_count": 0,
	}
	var results: Array[Dictionary] = []
	var has_batch_api: bool = committer != null and committer.has_method("apply_gpu_autoobject_dirty_deltas")
	var has_single_api: bool = committer != null and committer.has_method("apply_gpu_autoobject_dirty_delta")
	var has_resident_buffer_api: bool = committer != null and committer.has_method("try_apply_gpu_autoobject_object_ref_update_pass_from_buffer")
	if committer == null or (not has_batch_api and not has_single_api and not has_resident_buffer_api):
		return {
			"ok": false,
			"reason": "missing_committer",
			"dirty_deltas": [],
			"dirty_delta_count": 0,
			"results": results,
			"commit_result_count": 0,
			"failed_commit_result_count": 0,
			"pending_dirty_delta_count": get_pending_dirty_delta_count(),
			"runtime_ready": _gpu_ready,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
			"dirty_delta_bridge_mode": "none",
			"dirty_delta_apply_api": "none",
			"resident_gpu_dirty_delta_update_pass": false,
			"resident_gpu_dirty_delta_update_pass_owner": "none",
			"resident_gpu_dirty_delta_update_pass_shader": "none",
			"resident_gpu_dirty_delta_update_pass_dispatch_count": 0,
		}

	# P0 #4: Resident GPU dirty delta pass ONLY — no CPU bridge fallback.
	# When resident GPU path fails/blocked, return failure directly.
	# Callers that need CPU fallback should call committer.apply_gpu_autoobject_dirty_deltas() directly.
	var resident_result := _try_flush_resident_dirty_delta_buffer_to_scene_voxel_committer(committer, options)
	if bool(resident_result.get("resident_gpu_dirty_delta_update_pass", false)):
		var resident_dirty_tiles := {}
		if committer.has_method("get_dirty_scene_voxel_tiles"):
			resident_dirty_tiles = committer.call("get_dirty_scene_voxel_tiles")
		resident_result["dirty_scene_voxel_tiles"] = resident_dirty_tiles
		resident_result["dirty_scene_voxel_tile_count"] = resident_dirty_tiles.size()
		return resident_result

	# Resident GPU pass blocked/failed — no CPU readback or bridge.
	var blocked_reason := str(resident_result.get("reason", "resident_dirty_delta_update_pass_blocked"))
	var dirty_tiles := {}
	if committer.has_method("get_dirty_scene_voxel_tiles"):
		dirty_tiles = committer.call("get_dirty_scene_voxel_tiles")
	return {
		"ok": false,
		"reason": blocked_reason,
		"dirty_deltas": [],
		"dirty_delta_count": 0,
		"results": [],
		"commit_result_count": 0,
		"failed_commit_result_count": 0,
		"pending_dirty_delta_count": int(resident_result.get("pending_dirty_delta_count", get_pending_dirty_delta_count())),
		"dirty_scene_voxel_tiles": dirty_tiles,
		"dirty_scene_voxel_tile_count": dirty_tiles.size(),
		"runtime_ready": _gpu_ready,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "none",
		"failed_readback_source": "none",
		"dirty_delta_bridge_mode": "none",
		"dirty_delta_apply_api": "none",
		"resident_gpu_dirty_delta_update_pass": false,
		"resident_gpu_dirty_delta_update_pass_owner": "none",
		"resident_gpu_dirty_delta_update_pass_shader": "none",
		"resident_gpu_dirty_delta_update_pass_dispatch_count": 0,
		"resident_gpu_dirty_delta_update_pass_blocked_reason": blocked_reason,
	}


## 返回所有当前存活且匹配指定 profile_id 的对象 ID 列表。
func get_object_ids_for_profile(profile_ids) -> Dictionary:
	var profile_lookup := _profile_id_lookup_from_value(profile_ids)
	if profile_lookup.is_empty():
		return {
			"ok": false,
			"reason": "missing_profile_ids",
			"profile_ids": [],
			"object_ids": [],
			"objects": [],
			"runtime_ready": _gpu_ready,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
		}
	if not _gpu_ready:
		return {
			"ok": false,
			"reason": "runtime_not_ready",
			"profile_ids": profile_lookup.keys(),
			"object_ids": [],
			"objects": [],
			"runtime_ready": false,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
		}

	var refs := _collect_live_object_refs_for_profiles(profile_lookup)
	var object_ids: Array[int] = []
	for ref in refs:
		object_ids.append(int(ref.get("object_id", -1)))
	return {
		"ok": true,
		"reason": "ok",
		"profile_ids": profile_lookup.keys(),
		"object_ids": object_ids,
		"objects": refs,
		"object_count": object_ids.size(),
		"runtime_ready": _gpu_ready,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "gpu_storage_buffers",
	}


## 对所有匹配 profile_id 的存活对象追加 dirty delta，触发场景重新评分/路由。
func mark_profile_objects_dirty(profile_ids, dirty_flags: Dictionary = {}) -> Dictionary:
	var profile_lookup := _profile_id_lookup_from_value(profile_ids)
	if profile_lookup.is_empty():
		return {
			"ok": false,
			"reason": "missing_profile_ids",
			"profile_ids": [],
			"matched_object_count": 0,
			"object_ids": [],
			"appended_dirty_delta_count": 0,
			"pending_dirty_delta_count": get_pending_dirty_delta_count(),
			"runtime_ready": _gpu_ready,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
		}
	if not _gpu_ready:
		return {
			"ok": false,
			"reason": "runtime_not_ready",
			"profile_ids": profile_lookup.keys(),
			"matched_object_count": 0,
			"object_ids": [],
			"appended_dirty_delta_count": 0,
			"pending_dirty_delta_count": 0,
			"runtime_ready": false,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
		}

	var refs := _collect_live_object_refs_for_profiles(profile_lookup)
	if refs.size() > dirty_delta_capacity - _dirty_delta_count:
		return {
			"ok": false,
			"reason": "dirty_delta_capacity_full",
			"profile_ids": profile_lookup.keys(),
			"matched_object_count": refs.size(),
			"object_ids": _object_ids_from_refs(refs),
			"appended_dirty_delta_count": 0,
			"pending_dirty_delta_count": get_pending_dirty_delta_count(),
			"runtime_ready": _gpu_ready,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
		}

	var flags := _profile_hot_update_dirty_flags(dirty_flags)
	var appended := 0
	for ref in refs:
		var object_id := int(ref.get("object_id", -1))
		var object_type := int(ref.get("object_type", 0))
		var profile_id := int(ref.get("profile_id", -1))
		var generation := int(ref.get("generation", 0))
		var voxel_min: Vector3i = ref.get("voxel_min", Vector3i.ZERO)
		var voxel_max: Vector3i = ref.get("voxel_max", voxel_min + Vector3i.ONE)
		if _append_dirty_delta(
			object_id,
			object_type,
			profile_id,
			generation,
			voxel_min,
			voxel_max,
			voxel_min,
			voxel_max,
			flags,
			false,
			true
		):
			appended += 1

	var mark_ok := appended == refs.size()
	return {
		"ok": mark_ok,
		"reason": "ok" if mark_ok else "append_dirty_delta_failed",
		"profile_ids": profile_lookup.keys(),
		"matched_object_count": refs.size(),
		"object_ids": _object_ids_from_refs(refs),
		"appended_dirty_delta_count": appended,
		"pending_dirty_delta_count": get_pending_dirty_delta_count(),
		"dirty_flags": flags,
		"runtime_ready": _gpu_ready,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "gpu_storage_buffers" if mark_ok else "none",
	}


## 返回单个对象的 GPU 状态快照字典（alive/bounds/transform 等）。
func get_object_summary(object_id: int) -> Dictionary:
	if not _is_valid_id(object_id):
		return {}
	if not _gpu_ready:
		return {
			"object_id": object_id,
			"runtime_ready": false,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_snapshot": false,
			"readback_source": "none",
			"reason": _not_ready_reason,
		}
	return _read_object_state(object_id)


## 返回指定对象（或全部存活对象）的调试状态摘要及运行时统计。
func get_selected_debug_summary(object_ids: Array = []) -> Dictionary:
	var summaries: Array[Dictionary] = []
	if _gpu_ready:
		if object_ids.is_empty():
			for object_id in range(max_objects):
				var summary := _read_object_state(object_id)
				if bool(summary.get("alive", false)):
					summaries.append(summary)
		else:
			for raw_id in object_ids:
				var object_id := int(raw_id)
				if _is_valid_id(object_id):
					summaries.append(_read_object_state(object_id))

	return {
		"max_objects": max_objects,
		"live_count": get_live_count(),
		"free_count": _free_ids.size() if _gpu_ready else 0,
		"pending_delta_count": get_pending_dirty_delta_count(),
		"dirty_delta_capacity": dirty_delta_capacity,
		"runtime_ready": _gpu_ready,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_snapshot": _gpu_ready,
		"readback_source": "gpu_storage_buffers" if _gpu_ready else "none",
		"accepted_placement_record_contract": get_accepted_placement_record_contract(),
		"accepted_placement_record_schema_version": ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION,
		"accepted_placement_record_stride_bytes": ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"reason": _not_ready_reason,
		"objects": summaries,
	}


## 返回所有存活对象的调试摘要（同 get_selected_debug_summary 无参版）。
func get_debug_summary() -> Dictionary:
	return get_selected_debug_summary()


## 按名称返回对应的 GPU 存储缓冲区 RID。
func get_gpu_buffer(buffer_name: String) -> RID:
	var name := buffer_name.to_lower()
	if name == GPU_BUFFER_ALIVE or name == "autoobject_alive":
		return _alive_buffer
	if name == GPU_BUFFER_GENERATION or name == "autoobject_generation":
		return _generation_buffer
	if name == GPU_BUFFER_TYPE:
		return _type_buffer
	if name == GPU_BUFFER_PROFILE or name == "autoobject_profile":
		return _profile_buffer
	if name == GPU_BUFFER_FLAGS:
		return _flags_buffer
	if name == GPU_BUFFER_BOUNDS_MIN or name == "autoobject_bounds_min":
		return _bounds_min_buffer
	if name == GPU_BUFFER_BOUNDS_MAX or name == "autoobject_bounds_max":
		return _bounds_max_buffer
	if name == GPU_BUFFER_PREVIOUS_BOUNDS_MIN or name == "autoobject_previous_bounds_min":
		return _previous_bounds_min_buffer
	if name == GPU_BUFFER_PREVIOUS_BOUNDS_MAX or name == "autoobject_previous_bounds_max":
		return _previous_bounds_max_buffer
	if name == GPU_BUFFER_TRANSFORM or name == "autoobject_transform":
		return _transform_buffer
	if name == GPU_BUFFER_DIRTY_DELTA or name == "autoobject_dirty_delta":
		return _dirty_delta_buffer
	if name == GPU_BUFFER_DIRTY_COUNT or name == "autoobject_dirty_count" or name == "autoobject_dirty_delta_count":
		return _dirty_count_buffer
	return RID()


## 返回所有 GPU 缓冲区的 RID 有效性、记录数、步长等摘要字典。
func get_gpu_buffer_summary() -> Dictionary:
	var buffers := {}
	for buffer_name in GPU_BUFFER_NAMES:
		var rid := get_gpu_buffer(buffer_name)
		buffers[buffer_name] = {
			"rid_valid": rid.is_valid(),
			"record_count": _gpu_buffer_record_count(buffer_name),
			"stride_bytes": _gpu_buffer_stride_bytes(buffer_name),
			"logical_byte_count": _gpu_buffer_record_count(buffer_name) * _gpu_buffer_stride_bytes(buffer_name),
		}
	return {
		"runtime_ready": _gpu_ready,
		"reason": _not_ready_reason,
		"read_source": "gpu_storage_buffers",
		"runtime_read_source": "gpu_storage_buffers" if _gpu_ready else "none",
		"readback_source": "gpu_storage_buffers" if _gpu_ready else "none",
		"gpu_first": true,
		"cpu_fallback": false,
		"max_objects": max_objects,
		"live_count": get_live_count(),
		"free_count": _free_ids.size() if _gpu_ready else 0,
		"dirty_delta_capacity": dirty_delta_capacity,
		"alive_buffer": _alive_buffer.is_valid(),
		"generation_buffer": _generation_buffer.is_valid(),
		"type_buffer": _type_buffer.is_valid(),
		"profile_buffer": _profile_buffer.is_valid(),
		"flags_buffer": _flags_buffer.is_valid(),
		"bounds_min_buffer": _bounds_min_buffer.is_valid(),
		"bounds_max_buffer": _bounds_max_buffer.is_valid(),
		"dirty_delta_buffer": _dirty_delta_buffer.is_valid(),
		"accepted_placement_record_contract": get_accepted_placement_record_contract(),
		"accepted_placement_record_schema_version": ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION,
		"accepted_placement_record_stride_bytes": ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"buffers": buffers,
	}


## 返回当前 GPU dirty delta 缓冲区中待处理的增量条数。
func get_pending_dirty_delta_count() -> int:
	return _read_dirty_delta_count() if _gpu_ready else 0


## 通过读回 alive 缓冲区统计当前存活对象数。
func get_live_count() -> int:
	if not _gpu_ready or max_objects <= 0:
		return 0
	var bytes := _read_buffer_bytes(_alive_buffer, 0, max_objects * OBJECT_SCALAR_STRIDE_BYTES)
	if bytes.size() < max_objects * OBJECT_SCALAR_STRIDE_BYTES:
		return 0
	var live_count := 0
	for object_id in range(max_objects):
		var offset := object_id * OBJECT_SCALAR_STRIDE_BYTES
		if bytes.decode_s32(offset) != 0:
			live_count += 1
	return live_count


## 批量读取所有存活对象状态，筛选出匹配指定 profile_id 集合的对象引用列表。
func _collect_live_object_refs_for_profiles(profile_lookup: Dictionary) -> Array[Dictionary]:
	var refs: Array[Dictionary] = []
	if not _gpu_ready or max_objects <= 0 or profile_lookup.is_empty():
		return refs

	var scalar_bytes := max_objects * OBJECT_SCALAR_STRIDE_BYTES
	var bounds_bytes := max_objects * OBJECT_BOUNDS_STRIDE_BYTES
	var alive_bytes := _read_buffer_bytes(_alive_buffer, 0, scalar_bytes)
	var generation_bytes := _read_buffer_bytes(_generation_buffer, 0, scalar_bytes)
	var type_bytes := _read_buffer_bytes(_type_buffer, 0, scalar_bytes)
	var profile_bytes := _read_buffer_bytes(_profile_buffer, 0, scalar_bytes)
	var bounds_min_bytes := _read_buffer_bytes(_bounds_min_buffer, 0, bounds_bytes)
	var bounds_max_bytes := _read_buffer_bytes(_bounds_max_buffer, 0, bounds_bytes)
	if alive_bytes.size() < scalar_bytes \
		or generation_bytes.size() < scalar_bytes \
		or type_bytes.size() < scalar_bytes \
		or profile_bytes.size() < scalar_bytes \
		or bounds_min_bytes.size() < bounds_bytes \
		or bounds_max_bytes.size() < bounds_bytes:
		return refs

	for object_id in range(max_objects):
		var scalar_offset := object_id * OBJECT_SCALAR_STRIDE_BYTES
		if alive_bytes.decode_s32(scalar_offset) == 0:
			continue
		var profile_id := profile_bytes.decode_s32(scalar_offset)
		if not profile_lookup.has(profile_id):
			continue
		var bounds_offset := object_id * OBJECT_BOUNDS_STRIDE_BYTES
		refs.append({
			"object_id": object_id,
			"profile_id": profile_id,
			"object_type": type_bytes.decode_s32(scalar_offset),
			"generation": generation_bytes.decode_s32(scalar_offset),
			"voxel_min": BufferUtils.decode_vec3i4(bounds_min_bytes, bounds_offset),
			"voxel_max": BufferUtils.decode_vec3i4(bounds_max_bytes, bounds_offset),
			"runtime_ready": true,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "gpu_storage_buffers",
		})
	return refs


## 从对象引用字典数组中提取 object_id 列表。
func _object_ids_from_refs(refs: Array[Dictionary]) -> Array[int]:
	var object_ids: Array[int] = []
	for ref in refs:
		object_ids.append(int(ref.get("object_id", -1)))
	return object_ids


## 返回指定 GPU 缓冲区名称对应的每条记录字节步长。
func _gpu_buffer_stride_bytes(buffer_name: String) -> int:
	match buffer_name:
		GPU_BUFFER_ALIVE, GPU_BUFFER_GENERATION, GPU_BUFFER_TYPE, GPU_BUFFER_PROFILE, GPU_BUFFER_FLAGS, GPU_BUFFER_DIRTY_COUNT:
			return OBJECT_SCALAR_STRIDE_BYTES
		GPU_BUFFER_BOUNDS_MIN, GPU_BUFFER_BOUNDS_MAX, GPU_BUFFER_PREVIOUS_BOUNDS_MIN, GPU_BUFFER_PREVIOUS_BOUNDS_MAX:
			return OBJECT_BOUNDS_STRIDE_BYTES
		GPU_BUFFER_TRANSFORM:
			return OBJECT_TRANSFORM_STRIDE_BYTES
		GPU_BUFFER_DIRTY_DELTA:
			return DIRTY_DELTA_STRIDE_BYTES
	return 0


## 返回指定 GPU 缓冲区名称对应的记录总容量。
func _gpu_buffer_record_count(buffer_name: String) -> int:
	match buffer_name:
		GPU_BUFFER_ALIVE, GPU_BUFFER_GENERATION, GPU_BUFFER_TYPE, GPU_BUFFER_PROFILE, GPU_BUFFER_FLAGS, GPU_BUFFER_BOUNDS_MIN, GPU_BUFFER_BOUNDS_MAX, GPU_BUFFER_PREVIOUS_BOUNDS_MIN, GPU_BUFFER_PREVIOUS_BOUNDS_MAX, GPU_BUFFER_TRANSFORM:
			return max_objects
		GPU_BUFFER_DIRTY_DELTA:
			return dirty_delta_capacity
		GPU_BUFFER_DIRTY_COUNT:
			return 1
	return 0


## 规范化并返回体素边界字典（静态工具方法）。
static func make_voxel_bounds(voxel_min: Vector3i, voxel_max: Vector3i) -> Dictionary:
	var bounds := _normalize_bounds_static(voxel_min, voxel_max)
	return {
		"voxel_min": bounds.voxel_min,
		"voxel_max": bounds.voxel_max,
	}


## 返回接受放置记录的 schema 协议字典（字段布局、步长等元数据）。
static func get_accepted_placement_record_contract() -> Dictionary:
	return {
		"schema_version": ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION,
		"stride_bytes": ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES,
		"layout": "std430",
		"fields": [
			{"name": "object_id", "type": "int", "offset": ACCEPTED_PLACEMENT_RECORD_OBJECT_ID_OFFSET},
			{"name": "profile_id", "type": "int", "offset": ACCEPTED_PLACEMENT_RECORD_PROFILE_ID_OFFSET},
			{"name": "object_type", "type": "int", "offset": ACCEPTED_PLACEMENT_RECORD_OBJECT_TYPE_OFFSET},
			{"name": "object_flags", "type": "int", "offset": ACCEPTED_PLACEMENT_RECORD_OBJECT_FLAGS_OFFSET},
			{"name": "voxel_min", "type": "ivec4", "offset": ACCEPTED_PLACEMENT_RECORD_VOXEL_MIN_OFFSET},
			{"name": "voxel_max", "type": "ivec4", "offset": ACCEPTED_PLACEMENT_RECORD_VOXEL_MAX_OFFSET},
			{"name": "transform", "type": "mat4", "offset": ACCEPTED_PLACEMENT_RECORD_TRANSFORM_OFFSET},
			{"name": "dirty_flags", "type": "int", "offset": ACCEPTED_PLACEMENT_RECORD_DIRTY_FLAGS_OFFSET},
			{"name": "asset_index", "type": "int", "offset": ACCEPTED_PLACEMENT_RECORD_ASSET_INDEX_OFFSET},
			{"name": "result_index", "type": "int", "offset": ACCEPTED_PLACEMENT_RECORD_RESULT_INDEX_OFFSET},
			{"name": "reserved", "type": "int", "offset": ACCEPTED_PLACEMENT_RECORD_RESERVED_OFFSET},
		],
		"runtime_command_flush_mode": "cpu_bulk_spawn_buffer_update",
		"debug_pack_source": "cpu_bulk_spawn_command_staging_debug_buffer",
		"shader_consumed": false,
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
	}


## 分配所有 GPU 存储缓冲区（alive/generation/bounds/transform/dirty_delta 等），并初始化 dirty count。
func _create_gpu_buffers() -> void:
	_gpu_ready = false
	_not_ready_reason = ""
	if _rd != null:
		gc_all(false)
	_clear_buffer_rids()

	if not _gpu_enabled:
		_not_ready_reason = "gpu_disabled"
		return
	if max_objects <= 0:
		_not_ready_reason = "capacity_zero"
		return
	if not ensure_device(true, false):
		_not_ready_reason = "no_rendering_device"
		return

	_alive_buffer = storage_buffer_zero(max_objects * OBJECT_SCALAR_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_alive")
	_generation_buffer = storage_buffer_zero(max_objects * OBJECT_SCALAR_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_generation")
	_type_buffer = storage_buffer_zero(max_objects * OBJECT_SCALAR_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_type")
	_profile_buffer = storage_buffer_zero(max_objects * OBJECT_SCALAR_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_profile")
	_flags_buffer = storage_buffer_zero(max_objects * OBJECT_SCALAR_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_flags")
	_bounds_min_buffer = storage_buffer_zero(max_objects * OBJECT_BOUNDS_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_bounds_min")
	_bounds_max_buffer = storage_buffer_zero(max_objects * OBJECT_BOUNDS_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_bounds_max")
	_previous_bounds_min_buffer = storage_buffer_zero(max_objects * OBJECT_BOUNDS_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_previous_bounds_min")
	_previous_bounds_max_buffer = storage_buffer_zero(max_objects * OBJECT_BOUNDS_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_previous_bounds_max")
	_transform_buffer = storage_buffer_zero(max_objects * OBJECT_TRANSFORM_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_transform")
	_dirty_delta_buffer = storage_buffer_zero(dirty_delta_capacity * DIRTY_DELTA_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_dirty_delta")
	_dirty_count_buffer = storage_buffer_zero(OBJECT_SCALAR_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_dirty_delta_count")

	_gpu_ready = _all_required_buffers_valid()
	if not _gpu_ready:
		_not_ready_reason = "buffer_create_failed"
		return

	if not _write_dirty_count(0):
		_gpu_ready = false
		_not_ready_reason = "dirty_count_write_failed"


## 将所有 GPU 缓冲区 RID 成员变量重置为无效 RID。
func _clear_buffer_rids() -> void:
	_alive_buffer = RID()
	_generation_buffer = RID()
	_type_buffer = RID()
	_profile_buffer = RID()
	_flags_buffer = RID()
	_bounds_min_buffer = RID()
	_bounds_max_buffer = RID()
	_previous_bounds_min_buffer = RID()
	_previous_bounds_max_buffer = RID()
	_transform_buffer = RID()
	_dirty_delta_buffer = RID()
	_dirty_count_buffer = RID()


## 检查是否存在任何已分配的 GPU 缓冲区 RID（用于设备切换安全判断）。
func _has_allocated_gpu_buffers() -> bool:
	return (
		_alive_buffer.is_valid()
		or _generation_buffer.is_valid()
		or _type_buffer.is_valid()
		or _profile_buffer.is_valid()
		or _flags_buffer.is_valid()
		or _bounds_min_buffer.is_valid()
		or _bounds_max_buffer.is_valid()
		or _previous_bounds_min_buffer.is_valid()
		or _previous_bounds_max_buffer.is_valid()
		or _transform_buffer.is_valid()
		or _dirty_delta_buffer.is_valid()
		or _dirty_count_buffer.is_valid()
	)


## 检查所有必需 GPU 缓冲区 RID 是否均有效。
func _all_required_buffers_valid() -> bool:
	return (
		_alive_buffer.is_valid()
		and _generation_buffer.is_valid()
		and _type_buffer.is_valid()
		and _profile_buffer.is_valid()
		and _flags_buffer.is_valid()
		and _bounds_min_buffer.is_valid()
		and _bounds_max_buffer.is_valid()
		and _previous_bounds_min_buffer.is_valid()
		and _previous_bounds_max_buffer.is_valid()
		and _transform_buffer.is_valid()
		and _dirty_delta_buffer.is_valid()
		and _dirty_count_buffer.is_valid()
	)


## 检查运行时是否已就绪可接受对象命令。
func _can_accept_object_command() -> bool:
	return _gpu_ready


## 检查运行时是否就绪且 dirty delta 容量未满。
func _can_append_dirty_delta() -> bool:
	return _gpu_ready and _dirty_delta_count < dirty_delta_capacity


## 从空闲 ID 栈弹出一个可用对象 ID，空闲池为空时返回 -1。
func _allocate_id() -> int:
	if _free_ids.is_empty():
		return -1
	return int(_free_ids.pop_back())


## 将对象的所有状态字段（alive/generation/bounds/transform/flags）逐一写入对应 GPU 缓冲区。
func _write_object_state(
	object_id: int,
	alive: bool,
	generation: int,
	profile_id: int,
	object_type: int,
	voxel_min: Vector3i,
	voxel_max: Vector3i,
	previous_voxel_min: Vector3i,
	previous_voxel_max: Vector3i,
	transform: Transform3D,
	object_flags: int = 0
) -> bool:
	if not _gpu_ready or not _is_valid_id(object_id):
		return false

	var scalar_offset := object_id * OBJECT_SCALAR_STRIDE_BYTES
	var bounds_offset := object_id * OBJECT_BOUNDS_STRIDE_BYTES
	var transform_offset := object_id * OBJECT_TRANSFORM_STRIDE_BYTES
	var ok := true
	ok = _write_buffer(_alive_buffer, scalar_offset, BufferUtils.pack_s32(1 if alive else 0), false) and ok
	ok = _write_buffer(_generation_buffer, scalar_offset, BufferUtils.pack_s32(generation), false) and ok
	ok = _write_buffer(_type_buffer, scalar_offset, BufferUtils.pack_s32(object_type), false) and ok
	ok = _write_buffer(_profile_buffer, scalar_offset, BufferUtils.pack_s32(profile_id), false) and ok
	ok = _write_buffer(_flags_buffer, scalar_offset, BufferUtils.pack_s32(object_flags), false) and ok
	ok = _write_buffer(_bounds_min_buffer, bounds_offset, BufferUtils.pack_vec3i4(voxel_min), false) and ok
	ok = _write_buffer(_bounds_max_buffer, bounds_offset, BufferUtils.pack_vec3i4(voxel_max), false) and ok
	ok = _write_buffer(_previous_bounds_min_buffer, bounds_offset, BufferUtils.pack_vec3i4(previous_voxel_min), false) and ok
	ok = _write_buffer(_previous_bounds_max_buffer, bounds_offset, BufferUtils.pack_vec3i4(previous_voxel_max), false) and ok
	ok = _write_buffer(_transform_buffer, transform_offset, BufferUtils.pack_transform_mat4(transform), false) and ok
	submit_and_sync()
	return ok


## 将单条 dirty delta 记录打包写入 dirty delta 缓冲区并递增计数。
func _append_dirty_delta(
	object_id: int,
	object_type: int,
	profile_id: int,
	generation: int,
	old_min: Vector3i,
	old_max: Vector3i,
	new_min: Vector3i,
	new_max: Vector3i,
	dirty_flags: Dictionary,
	removed: bool,
	alive_after: bool
) -> bool:
	if not _can_append_dirty_delta():
		return false

	var bytes := PackedByteArray()
	bytes.resize(DIRTY_DELTA_STRIDE_BYTES)
	bytes.encode_s32(0, object_id)
	bytes.encode_s32(4, object_type)
	bytes.encode_s32(8, profile_id)
	bytes.encode_s32(12, generation)
	BufferUtils.encode_vec3i4_with_w(bytes, 16, old_min, 1 if removed else 0)
	BufferUtils.encode_vec3i4_with_w(bytes, 32, old_max, 1 if alive_after else 0)
	BufferUtils.encode_vec3i4_with_w(bytes, 48, new_min, _dirty_flags_to_bits(dirty_flags))
	BufferUtils.encode_vec3i4_with_w(bytes, 64, new_max, _flush_epoch)

	var offset := _dirty_delta_count * DIRTY_DELTA_STRIDE_BYTES
	if not _write_buffer(_dirty_delta_buffer, offset, bytes, false):
		return false
	var next_count := _dirty_delta_count + 1
	if not _write_dirty_count(next_count, false):
		return false
	submit_and_sync()
	return true


## 从 GPU 缓冲区读回单个对象的完整状态字段，返回状态快照字典。
func _read_object_state(object_id: int) -> Dictionary:
	if not _gpu_ready or not _is_valid_id(object_id):
		return {}

	var scalar_offset := object_id * OBJECT_SCALAR_STRIDE_BYTES
	var bounds_offset := object_id * OBJECT_BOUNDS_STRIDE_BYTES
	var transform_offset := object_id * OBJECT_TRANSFORM_STRIDE_BYTES
	var alive := _read_s32(_alive_buffer, scalar_offset) != 0
	var generation := _read_s32(_generation_buffer, scalar_offset)
	var object_type := _read_s32(_type_buffer, scalar_offset)
	var profile_id := _read_s32(_profile_buffer, scalar_offset)
	var object_flags := _read_s32(_flags_buffer, scalar_offset)
	var voxel_min := _read_vec3i4(_bounds_min_buffer, bounds_offset)
	var voxel_max := _read_vec3i4(_bounds_max_buffer, bounds_offset)
	var previous_voxel_min := _read_vec3i4(_previous_bounds_min_buffer, bounds_offset)
	var previous_voxel_max := _read_vec3i4(_previous_bounds_max_buffer, bounds_offset)
	var transform := BufferUtils.decode_transform_mat4(_read_buffer_bytes(_transform_buffer, transform_offset, OBJECT_TRANSFORM_STRIDE_BYTES))

	return {
		"object_id": object_id,
		"alive": alive,
		"generation": generation,
		"profile_id": profile_id,
		"object_type": object_type,
		"object_flags": object_flags,
		"voxel_min": voxel_min,
		"voxel_max": voxel_max,
		"previous_voxel_min": previous_voxel_min,
		"previous_voxel_max": previous_voxel_max,
		"transform": transform,
		"dirty": _dirty_delta_count > 0,
		"runtime_ready": true,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_snapshot": true,
		"readback_source": "gpu_storage_buffers",
	}


## 将 dirty delta 计数写入 GPU 计数缓冲区并同步 CPU 侧缓存。
func _write_dirty_count(count: int, sync_after: bool = true) -> bool:
	var clamped_count := clampi(count, 0, dirty_delta_capacity)
	if not _write_buffer(_dirty_count_buffer, 0, BufferUtils.pack_s32(clamped_count), sync_after):
		return false
	_dirty_delta_count = clamped_count
	return true


## 从 GPU 读取当前 dirty delta 计数，读取失败时返回 CPU 缓存值。
func _read_dirty_delta_count() -> int:
	var result := _read_dirty_delta_count_result()
	if bool(result.get("ok", false)):
		return int(result.get("count", 0))
	return _dirty_delta_count


## 从 GPU dirty count 缓冲区读回计数值，返回包含 ok/count 的结果字典。
func _read_dirty_delta_count_result() -> Dictionary:
	if not _gpu_ready or not _dirty_count_buffer.is_valid():
		return {
			"ok": false,
			"reason": "runtime_not_ready" if not _gpu_ready else "dirty_count_buffer_invalid",
			"count": _dirty_delta_count,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
			"failed_readback_source": "none" if not _gpu_ready else "gpu_dirty_count_buffer",
		}
	var bytes := _read_buffer_bytes(_dirty_count_buffer, 0, OBJECT_SCALAR_STRIDE_BYTES)
	if bytes.size() < OBJECT_SCALAR_STRIDE_BYTES:
		return {
			"ok": false,
			"reason": "dirty_count_readback_failed",
			"count": _dirty_delta_count,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
			"failed_readback_source": "gpu_dirty_count_buffer",
		}
	var count := clampi(bytes.decode_s32(0), 0, dirty_delta_capacity)
	_dirty_delta_count = count
	return {
		"ok": true,
		"reason": "ok",
		"count": count,
		"readback_source": "gpu_dirty_count_buffer",
	}


## 从 GPU generation 缓冲区读取指定对象 ID 的世代号。
func _read_generation(object_id: int) -> int:
	if not _gpu_ready or not _is_valid_id(object_id):
		return 0
	return _read_s32(_generation_buffer, object_id * OBJECT_SCALAR_STRIDE_BYTES)


## 调用 RenderingDevice.buffer_update 将字节写入指定 GPU 缓冲区偏移处。
func _write_buffer(buffer: RID, offset: int, bytes: PackedByteArray, sync_after: bool = true) -> bool:
	if _rd == null or not buffer.is_valid() or bytes.is_empty():
		return false
	var err := _rd.buffer_update(buffer, offset, bytes.size(), bytes)
	if err != OK:
		return false
	if sync_after:
		submit_and_sync()
	return true


# Low-level GPU readback via rd.buffer_get_data. Debug/test-only in production runtime paths.
# All production paths use resident GPU-to-GPU handoff instead of readback.
## 通过 buffer_get_data 从 GPU 缓冲区读取指定字节范围（调试/测试路径）。
func _read_buffer_bytes(buffer: RID, offset: int, byte_count: int) -> PackedByteArray:
	return read_buffer_bytes(buffer, offset, byte_count)


## 从 GPU 缓冲区读取单个 int32 值。
func _read_s32(buffer: RID, offset: int) -> int:
	var bytes := _read_buffer_bytes(buffer, offset, OBJECT_SCALAR_STRIDE_BYTES)
	if bytes.size() < OBJECT_SCALAR_STRIDE_BYTES:
		return 0
	return bytes.decode_s32(0)


## 从 GPU 缓冲区读取 ivec4 前三分量，返回 Vector3i。
func _read_vec3i4(buffer: RID, offset: int) -> Vector3i:
	var bytes := _read_buffer_bytes(buffer, offset, OBJECT_BOUNDS_STRIDE_BYTES)
	return BufferUtils.decode_vec3i4(bytes)


## 从 GPU 变换缓冲区读取 mat4 并还原为 Transform3D。
## 将 int32 值打包为 4 字节 PackedByteArray。
## 将 Transform3D 打包为 64 字节 mat4 格式的 PackedByteArray。
## 将 Vector3 + w 分量编码为 4 个 float 写入字节数组指定偏移处。
## 将 dirty flags 字典转换为位掩码整数（AUTO/OBJECT_REFS/SCENE 等各占一位）。
func _dirty_flags_to_bits(dirty_flags: Dictionary) -> int:
	var flags := _merge_dirty_flags(dirty_flags)
	var bits := 0
	if bool(flags.get("auto", false)):
		bits |= DIRTY_FLAG_AUTO
	if bool(flags.get("object_refs", false)):
		bits |= DIRTY_FLAG_OBJECT_REFS
	if bool(flags.get("scene", false)):
		bits |= DIRTY_FLAG_SCENE
	if bool(flags.get("collision", false)):
		bits |= DIRTY_FLAG_COLLISION
	if bool(flags.get("target", false)):
		bits |= DIRTY_FLAG_TARGET
	if bool(flags.get("routing", false)):
		bits |= DIRTY_FLAG_ROUTING
	if bool(flags.get("scoring", false)):
		bits |= DIRTY_FLAG_SCORING
	if bool(flags.get("feedback", false)):
		bits |= DIRTY_FLAG_FEEDBACK
	return bits


## 合并 dirty flags 并强制启用 scene/collision/routing/scoring/auto/object_refs，用于 profile 热更新。
func _profile_hot_update_dirty_flags(dirty_flags: Dictionary) -> Dictionary:
	var flags := _merge_dirty_flags(dirty_flags)
	if not dirty_flags.has("scene"):
		flags["scene"] = true
	if not dirty_flags.has("collision"):
		flags["collision"] = true
	if not dirty_flags.has("routing"):
		flags["routing"] = true
	if not dirty_flags.has("scoring"):
		flags["scoring"] = true
	flags["auto"] = true
	flags["object_refs"] = true
	return flags


## 将多种形式的 profile_id 输入（int/Array/Dictionary/Object）统一转换为查找字典。
func _profile_id_lookup_from_value(value) -> Dictionary:
	var lookup := {}
	if value is int or value is float:
		_add_profile_id_to_lookup(lookup, value)
	elif value is String:
		if not str(value).is_empty():
			_add_profile_id_to_lookup(lookup, value)
	elif value is Array:
		for raw_id in value:
			_add_profile_id_to_lookup(lookup, raw_id)
	elif value is PackedInt32Array:
		for raw_id in value:
			_add_profile_id_to_lookup(lookup, raw_id)
	elif value is Dictionary:
		var dict := value as Dictionary
		if dict.has("dirty_profile_ids"):
			return _profile_id_lookup_from_value(dict["dirty_profile_ids"])
		if dict.has("profile_ids"):
			return _profile_id_lookup_from_value(dict["profile_ids"])
		if dict.has("profile_id"):
			return _profile_id_lookup_from_value(dict["profile_id"])
		for key in dict.keys():
			if bool(dict[key]):
				_add_profile_id_to_lookup(lookup, key)
	elif value is Object:
		var object := value as Object
		if object.has_method("get_dirty_profile_ids"):
			return _profile_id_lookup_from_value(object.call("get_dirty_profile_ids"))
		if VariantUtils.has_property(object, "dirty_profile_ids"):
			return _profile_id_lookup_from_value(object.get("dirty_profile_ids"))
	return lookup


## 将单个 profile_id（≥0）加入查找字典。
func _add_profile_id_to_lookup(lookup: Dictionary, value) -> void:
	var profile_id := int(value)
	if profile_id >= 0:
		lookup[profile_id] = true


## 将 int/String/Dictionary/Array 等形式的 flags 输入转换为位掩码整数。
func _object_flags_from_value(value) -> int:
	if value is int:
		return int(value)
	if value is float:
		return int(value)
	if value is String:
		return int(value)
	if value is Dictionary:
		var flags := value as Dictionary
		var bits := int(flags.get("bits", flags.get("mask", flags.get("value", 0))))
		if bool(flags.get("visible", false)):
			bits |= OBJECT_FLAG_VISIBLE
		if bool(flags.get("selected", false)):
			bits |= OBJECT_FLAG_SELECTED
		if bool(flags.get("locked", false)):
			bits |= OBJECT_FLAG_LOCKED
		if bool(flags.get("dirty", false)):
			bits |= OBJECT_FLAG_DIRTY
		if bool(flags.get("source", false)):
			bits |= OBJECT_FLAG_SOURCE
		if bool(flags.get("collision", false)):
			bits |= OBJECT_FLAG_COLLISION
		return bits
	if value is Array:
		var array_bits := 0
		for raw_flag in value:
			match str(raw_flag).to_lower():
				"visible":
					array_bits |= OBJECT_FLAG_VISIBLE
				"selected":
					array_bits |= OBJECT_FLAG_SELECTED
				"locked":
					array_bits |= OBJECT_FLAG_LOCKED
				"dirty":
					array_bits |= OBJECT_FLAG_DIRTY
				"source":
					array_bits |= OBJECT_FLAG_SOURCE
				"collision":
					array_bits |= OBJECT_FLAG_COLLISION
		return array_bits
	return 0


## 将传入的 dirty flags 与默认标志（auto+object_refs）合并后返回。
func _merge_dirty_flags(dirty_flags: Dictionary) -> Dictionary:
	var result := DEFAULT_DIRTY_FLAGS.duplicate()
	for key in dirty_flags.keys():
		result[key] = bool(dirty_flags[key])
	return result


## 从参数字典中解析 voxel_min/voxel_max（含嵌套 voxel_bounds），返回规范化边界字典。
func _bounds_from_params(params: Dictionary) -> Dictionary:
	var fallback_min := Vector3i.ZERO
	var fallback_max := Vector3i.ONE
	if params.has("voxel_bounds") and params["voxel_bounds"] is Dictionary:
		var nested: Dictionary = params["voxel_bounds"]
		fallback_min = VoxelGeneral.vector3i_from_value(nested.get("voxel_min", nested.get("min", fallback_min)), fallback_min)
		fallback_max = VoxelGeneral.vector3i_from_value(nested.get("voxel_max", nested.get("max", fallback_max)), fallback_max)
	var min_v := VoxelGeneral.vector3i_from_value(params.get("voxel_min", params.get("bounds_min", params.get("new_voxel_min", fallback_min))), fallback_min)
	var max_v := VoxelGeneral.vector3i_from_value(params.get("voxel_max", params.get("bounds_max", params.get("new_voxel_max", fallback_max))), fallback_max)
	return _normalize_bounds(min_v, max_v)


## 规范化边界（委托给静态方法），确保 max > min。
func _normalize_bounds(voxel_min: Vector3i, voxel_max: Vector3i) -> Dictionary:
	return _normalize_bounds_static(voxel_min, voxel_max)


## 静态规范化体素边界：交换越界的 min/max，保证各轴 max > min。
static func _normalize_bounds_static(voxel_min: Vector3i, voxel_max: Vector3i) -> Dictionary:
	var min_v := Vector3i(
		mini(voxel_min.x, voxel_max.x),
		mini(voxel_min.y, voxel_max.y),
		mini(voxel_min.z, voxel_max.z)
	)
	var max_v := Vector3i(
		maxi(voxel_min.x, voxel_max.x),
		maxi(voxel_min.y, voxel_max.y),
		maxi(voxel_min.z, voxel_max.z)
	)
	if max_v.x <= min_v.x:
		max_v.x = min_v.x + 1
	if max_v.y <= min_v.y:
		max_v.y = min_v.y + 1
	if max_v.z <= min_v.z:
		max_v.z = min_v.z + 1
	return {
		"voxel_min": min_v,
		"voxel_max": max_v,
	}


## 检查 object_id 是否在 [0, max_objects) 范围内。
func _is_valid_id(object_id: int) -> bool:
	return object_id >= 0 and object_id < max_objects
