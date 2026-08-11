class_name GPUAutoObjectRuntime
extends "res://scripts/godot_compute_shader_base.gd"

const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const AutoObjectInstanceRendererScript := preload("res://scripts/auto_object_instance_renderer.gd")

const DEFAULT_DIRTY_FLAGS := {"auto": true, "object_refs": true}

const DIRTY_FLAG_AUTO := 1
const DIRTY_FLAG_OBJECT_REFS := 2
const DIRTY_FLAG_SCENE := 4
const DIRTY_FLAG_COLLISION := 8
const DIRTY_FLAG_TARGET := 16
const DIRTY_FLAG_ROUTING := 32
const DIRTY_FLAG_SCORING := 64
const DIRTY_FLAG_FEEDBACK := 128

## object_flags 位定义 —— **ABI 文档**：GLSL 侧按字面位掩码使用并在注释中引用这些名字
## （如 autoobject_emit_instances.glsl 的 `& 2  // OBJECT_FLAG_SELECTED`）；GDScript 侧当前
## 无读者，保留为位语义的单一命名源，改位值必须同步 shader 字面量。
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
## 第 13 块常驻 SoA（《AutoObject实例GPU直提与点选交接计划.md》阶段 2）。
## 为什么必须常驻而不是用 profile_id 顶替：profile 容器按 descriptor hash 去重，
## profile_id → asset_index 是一对多；而渲染批次必须按 asset_index 分（每个 asset 一个
## descriptor.get_mesh()）。按 profile_id 分批会在两个资产共用 profile 时给其中一个画错网格，
## 且静默画错。object_type 同样不行——它是 asset_lookup[].w 的粗分组键，语义上就不唯一。
const GPU_BUFFER_ASSET_INDEX := "asset_index"
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
	GPU_BUFFER_ASSET_INDEX,
]
const RESET_RUNTIME_SHADER_PATH := "res://shaders/reset_gpu_autoobject_runtime.glsl"
const RESET_RUNTIME_PUSH := [
	["object_capacity", "int"],
	["dirty_delta_capacity", "int"],
	["transform_uint_stride", "int"],
	["dirty_delta_uint_stride", "int"],
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
	["use_asset_lookup", "int"],  # mixed-asset mode: per-record profile/object_type via asset_lookup
	["grid_x", "int"],
	["grid_y", "int"],
	["grid_z", "int"],
	# asset_lookup element capacity (grid.w) — host-passed value for the
	# shader's mixed-asset capacity gate (replaces GLSL .length()/OpArrayLength,
	# unsupported by Godot's SPIR-V path).
	["asset_lookup_capacity", "int"],
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

## 对象集合的内容代号（《AutoObject实例GPU直提与点选交接计划.md》阶段 1）。
## spawn 成功 / reset_state / configure_capacity 时自增，供下游（实例 emit、点选交接）
## 判断"对象集合变没变"。存在的理由：不这样就只能靠 get_live_count() 那种整块回读来判等，
## 而那是 O(max_objects) 的阻塞往返，绝不能出现在渲染或点选路径上。
var _object_revision := 0

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
var _asset_index_buffer: RID
var _reset_runtime_shader: RID
var _reset_runtime_pipeline: RID

## 实例 emit / 直提渲染宿主（惰性自持，见交接计划 §5.1 的所有权偏离说明）。
var _instance_renderer: RefCounted


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
	# 容量变更会重建全部常驻 buffer，renderer 缓存的 uniform set 会指向已释放的 RID：
	# 必须先释放 renderer，再重建 buffer。反过来做会让 renderer 在下一次 sync 时用一组
	# 悬空句柄建 uniform set —— 驱动层不一定报错，可能直接读到垃圾变换。
	_dispose_instance_renderer()
	_create_gpu_buffers()
	_bump_object_revision()


## Clears every runtime record on the GPU while preserving the runtime object,
## RenderingDevice, and all fixed-capacity buffer RIDs.
func reset_state() -> Dictionary:
	_repair_soft_reloaded_members()
	if not _gpu_ready or _rd == null:
		return {"ok": false, "reason": "runtime_not_ready"}
	if not _reset_runtime_pipeline.is_valid():
		_reset_runtime_shader = load_compute_shader(
			RESET_RUNTIME_SHADER_PATH, SCOPE_PERSISTENT, "reset_gpu_autoobject_runtime")
		if _reset_runtime_shader.is_valid():
			_reset_runtime_pipeline = create_compute_pipeline(
				_reset_runtime_shader, SCOPE_PERSISTENT, "reset_gpu_autoobject_runtime")
	if not _reset_runtime_shader.is_valid() or not _reset_runtime_pipeline.is_valid():
		push_error("[GPUAutoObjectRuntime] reset_state(): shader/pipeline 创建失败（shader_valid=%s, pipeline_valid=%s, path=%s）—— 不继续 dispatch。" % [
			_reset_runtime_shader.is_valid(), _reset_runtime_pipeline.is_valid(), RESET_RUNTIME_SHADER_PATH])
		assert(false, "GPUAutoObjectRuntime.reset_state: reset runtime pipeline not ready")
		return {"ok": false, "reason": "reset_runtime_pipeline_not_ready"}
	var set0 := create_uniform_set([
		make_storage_uniform(0, _alive_buffer),
		make_storage_uniform(1, _generation_buffer),
		make_storage_uniform(2, _type_buffer),
		make_storage_uniform(3, _profile_buffer),
		make_storage_uniform(4, _flags_buffer),
		make_storage_uniform(5, _bounds_min_buffer),
		make_storage_uniform(6, _bounds_max_buffer),
		make_storage_uniform(7, _previous_bounds_min_buffer),
		make_storage_uniform(8, _previous_bounds_max_buffer),
		make_storage_uniform(9, _transform_buffer),
		make_storage_uniform(10, _dirty_delta_buffer),
		make_storage_uniform(11, _dirty_count_buffer),
		make_storage_uniform(12, _asset_index_buffer),
	], _reset_runtime_shader, 0, SCOPE_PASS, "reset_gpu_autoobject_runtime")
	if not set0.is_valid():
		gc_scope(SCOPE_PASS)
		push_error("[GPUAutoObjectRuntime] reset_state(): uniform set 创建失败（set=0，13 个常驻对象缓冲）—— 不继续 dispatch。")
		assert(false, "GPUAutoObjectRuntime.reset_state: uniform set create failed")
		return {"ok": false, "reason": "reset_runtime_uniform_set_failed"}
	var push := PushConstantLayout.new(RESET_RUNTIME_PUSH).pack({
		object_capacity = max_objects,
		dirty_delta_capacity = dirty_delta_capacity,
		transform_uint_stride = int(OBJECT_TRANSFORM_STRIDE_BYTES / 4),
		dirty_delta_uint_stride = int(DIRTY_DELTA_STRIDE_BYTES / 4),
	})
	var cl := begin_compute_list()
	if cl < 0:
		gc_scope(SCOPE_PASS)
		push_error("[GPUAutoObjectRuntime] reset_state(): compute_list_begin 失败 (cl=%d)。" % cl)
		assert(false, "GPUAutoObjectRuntime.reset_state: compute list begin failed")
		return {"ok": false, "reason": "reset_runtime_compute_list_begin_failed"}
	_gpu_dispatch_pipeline_sets(
		cl,
		_reset_runtime_pipeline,
		[set0],
		push,
		dispatch_groups_1d(maxi(max_objects, dirty_delta_capacity), 64)
	)
	end_compute_list()
	submit_and_sync(true)
	gc_scope(SCOPE_PASS)
	_dirty_delta_count = 0
	_flush_epoch = 0
	_free_ids.clear()
	for i in range(max_objects):
		_free_ids.append(max_objects - 1 - i)
	_bump_object_revision()
	return {
		"ok": true,
		"reason": "ok",
		"mode": "gpu_in_place",
		"object_capacity": max_objects,
		"dirty_delta_capacity": dirty_delta_capacity,
		"buffer_rids_preserved": true,
		"object_revision": _object_revision,
	}


## ⚠ 编辑器软重载后的成员修复，别当成冗余判空删掉。事实依据（gdscript.cpp
## GDScriptInstance::reload_members）：软重载只把**重载前已存在**的成员按名字搬进新槽位；
## 本次重载**新增**的成员槽是默认构造的 Variant = nil，声明里的初始化器不会重跑，静态类型
## 也拦不住（实例槽本身是 Variant）。重载后第一次碰这些句柄会当场炸在 `.is_valid()`
## （在 Nil 上找不到方法）。
## ⚠ 必须用 `is` 而不是 `== null`：Variant 给 (RID, NIL) 注册的是 OperatorEvaluatorAlwaysFalse
## （variant_op.cpp），静态类型已知时 `== null` 会被编成恒 false，判空形同虚设。
## 语义：RID 归零 = "还没创建过"，既有分支照常重新创建，不会朝设备 free 一个假句柄。
func _repair_soft_reloaded_members() -> void:
	if not (_reset_runtime_shader is RID): _reset_runtime_shader = RID()
	if not (_reset_runtime_pipeline is RID): _reset_runtime_pipeline = RID()
	if not (_asset_index_buffer is RID): _asset_index_buffer = RID()
	if not (_object_revision is int): _object_revision = 0


## 对象集合发生变化时自增内容代号。放在 spawn 成功路径与 reset/容量变更处，
## 不放在 dirty delta flush 处——后者不改变对象集合本身。
func _bump_object_revision() -> void:
	if not (_object_revision is int):
		_object_revision = 0
	_object_revision += 1


## 返回对象集合的内容代号；下游用它做"无变化即空转"的守卫，避免整块 alive 回读。
func get_object_revision() -> int:
	if not (_object_revision is int):
		_object_revision = 0
	return _object_revision


# --------------------------------------------------------------------------
# 实例 emit / 直提渲染（《AutoObject实例GPU直提与点选交接计划.md》阶段 4）
# --------------------------------------------------------------------------

## 返回惰性自持的 AutoObjectInstanceRuntime 未就绪或 RD 缺失时返回 null。
##
## 所有权说明（交接计划 §5.1 记录的对 R3 §6.3 的刻意偏离）：R3 把 renderer 挂在
## ScenePlacementRuntime 下。这里挂在本类下，因为 emit 的全部热输入（alive / transform /
## profile / object_flags / bounds / asset_index）都是本类自己的 buffer 且同一个 RD，
## 热路径零跨对象借用；唯一的外部输入 mesh_description 逐次调用传入。
func get_instance_renderer() -> RefCounted:
	_repair_soft_reloaded_members()
	if not (_instance_renderer is RefCounted):
		_instance_renderer = null
	if not _gpu_ready or _rd == null:
		return null
	if _instance_renderer == null:
		_instance_renderer = AutoObjectInstanceRendererScript.new()
		if not _instance_renderer.attach_to_runtime(self):
			_instance_renderer = null
			return null
	return _instance_renderer


## 释放自持的 renderer（容量变更与 dispose 两处调用）。
func _dispose_instance_renderer() -> void:
	if not (_instance_renderer is RefCounted):
		_instance_renderer = null
		return
	if _instance_renderer != null:
		_instance_renderer.dispose()
		_instance_renderer = null


func _on_before_dispose() -> void:
	# renderer 的 uniform set 引用本类的常驻 buffer，必须先于它们释放。
	_dispose_instance_renderer()


## 统一点选 pass 的 AutoObject 域只读借用口（契约见交接计划 §4.5）。
## renderer 不可用时返回 {"ok": false, ...} 而不是抛错：干净会话里"还没 emit 过"
## 是正常状态，消费者据此把该域标成 NOT_TESTED。
func get_instance_pick_handoff() -> Dictionary:
	var renderer := get_instance_renderer()
	if renderer == null:
		return {
			"ok": false,
			"resident": false,
			"reason": "runtime_not_ready" if not _gpu_ready else "instance_renderer_unavailable",
		}
	return renderer.get_instance_pick_handoff()


## 返回 GPU 运行时是否已就绪。
func is_ready() -> bool:
	return _gpu_ready


## 返回 GPU 运行时是否已就绪（同 is_ready）。
func is_gpu_ready() -> bool:
	return _gpu_ready


## 返回运行时未就绪的原因字符串。
func get_not_ready_reason() -> String:
	return _not_ready_reason


## spawn-batch 共享容量守卫（records / gpu_buffers 两入口 reason 字符串逐字同）。
## 返回 "" 表示可分配；empty_batch 判定与失败报告组装留调用方。
func _spawn_batch_capacity_reason(record_count: int) -> String:
	if not _gpu_ready:
		return "runtime_not_ready"
	if _free_ids.size() < record_count:
		return "capacity_full"
	if _dirty_delta_count + record_count > dirty_delta_capacity:
		return "dirty_delta_capacity_full"
	return ""


## 按块预留 object ID；任一次分配失败即回滚整块并返回空数组
## （调用方以 is_empty 判 capacity_full_mid_alloc；仅在 record_count > 0 时调用）。
func _allocate_id_block(record_count: int) -> Array[int]:
	var object_ids: Array[int] = []
	for _i in range(record_count):
		var object_id := _allocate_id()
		if object_id < 0:
			for free_id in object_ids:
				_free_ids.append(free_id)
			return []
		object_ids.append(object_id)
	return object_ids


## records 入口的同形失败报告（4 处失败出口共用；shader 失败出口另有扩展键，不走这里）。
func _spawn_batch_records_failure(reason: String, failed_count: int) -> Dictionary:
	return {
		"ok": false, "reason": reason,
		"spawned_count": 0, "failed_count": failed_count,
		"object_ids": [],
		"accepted_placement_record_shader_consumed": false,
	}


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
	# Guard: runtime readiness, free IDs and dirty delta capacity（empty_batch 优先级在 not_ready 之后、容量之前）.
	var capacity_reason := _spawn_batch_capacity_reason(spawn_records.size())
	if capacity_reason == "runtime_not_ready":
		return _spawn_batch_records_failure("runtime_not_ready", spawn_records.size())
	if spawn_records.is_empty():
		return {
			"ok": true, "reason": "empty_batch",
			"spawned_count": 0, "failed_count": 0,
			"object_ids": [],
			"accepted_placement_record_shader_consumed": false,
		}
	if not capacity_reason.is_empty():
		return _spawn_batch_records_failure(capacity_reason, spawn_records.size())

	# Step 1: Allocate object IDs for all records atomically.
	var object_ids := _allocate_id_block(spawn_records.size())
	if object_ids.is_empty():
		return _spawn_batch_records_failure("capacity_full_mid_alloc", spawn_records.size())

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
		if generation < 0:
			# generation 回读失败：旧行为用 0 顶替，会把回收 ID 的代际写坏。整批回滚。
			for free_id in object_ids:
				_free_ids.append(free_id)
			push_error("[GPUAutoObjectRuntime] spawn_batch_from_accepted_placement_records(): object_id=%d 的 generation 回读失败 —— 整批放弃，不用 0 顶替。" % object_id)
			assert(false, "GPUAutoObjectRuntime.spawn_batch_from_accepted_placement_records: generation readback failed")
			return _spawn_batch_records_failure("generation_readback_failed", spawn_records.size())
		records.append({
			"object_id": object_id,
			"profile_id": int(spawn_params.get("profile_id", -1)),
			"object_type": int(spawn_params.get("object_type", 0)),
			"object_flags": int(spawn_params.get("object_flags", 0)),
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
	var shader_result := _try_apply_accepted_placement_record_shader(
		records,
		accepted_placement_record_bytes,
		options
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

	_bump_object_revision()
	return {
		"ok": true, "reason": "ok",
		"spawned_count": records.size(), "failed_count": 0,
		"object_ids": object_ids,
		"object_revision": _object_revision,
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
	# 守卫优先级与原实现逐一保持：not_ready → empty → invalid_rid → 容量。
	var capacity_reason := _spawn_batch_capacity_reason(record_count)
	if capacity_reason == "runtime_not_ready":
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
	# Mixed-asset mode: a valid asset_lookup RID makes the shader resolve
	# profile_id/object_type per record (world_meta.z -> asset_lookup). The
	# element capacity travels with the RID (from its allocation point) for the
	# shader's capacity gate.
	var asset_lookup_rid: RID = resident_inputs.get("asset_lookup_rid", RID())
	var asset_lookup_capacity := int(resident_inputs.get("asset_lookup_capacity", 0))
	if not capacity_reason.is_empty():
		report["reason"] = capacity_reason
		report["resident_gpu_allocator_writeback_blocked_reason"] = capacity_reason
		return report

	# Block-reserve object IDs for positional consumption by the shader.
	# No per-id alive/generation readback: the shader guards already-alive
	# slots and reads generation from the resident buffer.
	var object_ids := _allocate_id_block(record_count)
	if object_ids.is_empty():
		report["reason"] = "capacity_full_mid_alloc"
		report["resident_gpu_allocator_writeback_blocked_reason"] = "capacity_full_mid_alloc"
		return report
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
		options,
		asset_lookup_rid,
		asset_lookup_capacity
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
	_bump_object_revision()
	report["object_revision"] = _object_revision
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
	options: Dictionary,
	asset_lookup_rid: RID = RID(),
	asset_lookup_capacity: int = 0
) -> Dictionary:
	if _rd == null or not _all_required_buffers_valid():
		push_error("[GPUAutoObjectRuntime] _dispatch_accepted_placement_resident_shader(): 运行时缓冲不可用（rd=%s, buffers_valid=%s, record_count=%d）。" % [
			_rd != null, _all_required_buffers_valid(), record_count])
		assert(false, "GPUAutoObjectRuntime._dispatch_accepted_placement_resident_shader: runtime buffers not ready")
		return {"ok": false, "reason": "runtime_not_ready", "applied_on_gpu": false}
	var dirty_base := _dirty_delta_count
	var reserved_ids_buffer := storage_buffer_from_bytes(reserved_id_bytes, SCOPE_FRAME, "autoobject_resident_reserved_object_ids")
	var stats_buffer := storage_buffer_zero(ACCEPTED_PLACEMENT_RECORD_SHADER_STATS_U32_COUNT * 4, SCOPE_FRAME, "autoobject_resident_accepted_placement_stats")
	var kernel := ensure_shader_kernel(ACCEPTED_PLACEMENT_RESIDENT_SHADER_PATH, ACCEPTED_PLACEMENT_RESIDENT_SHADER_NAME)
	var shader: RID = kernel.get("shader", RID())
	var pipeline: RID = kernel.get("pipeline", RID())
	if not reserved_ids_buffer.is_valid() or not stats_buffer.is_valid() or not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		push_error("[GPUAutoObjectRuntime] _dispatch_accepted_placement_resident_shader(): setup 失败（reserved_ids=%s, stats=%s, shader=%s, pipeline=%s, path=%s）—— 不继续 dispatch。" % [
			reserved_ids_buffer.is_valid(), stats_buffer.is_valid(), shader.is_valid(), pipeline.is_valid(),
			ACCEPTED_PLACEMENT_RESIDENT_SHADER_PATH])
		assert(false, "GPUAutoObjectRuntime._dispatch_accepted_placement_resident_shader: setup failed")
		return {"ok": false, "reason": "resident_shader_setup_failed", "applied_on_gpu": false}
	var use_asset_lookup := asset_lookup_rid.is_valid()
	var asset_lookup_buffer := asset_lookup_rid
	if use_asset_lookup:
		track_borrowed_rid(asset_lookup_buffer, KIND_BUFFER, SCOPE_FRAME, "vpg:asset_lookup")
	else:
		asset_lookup_buffer = storage_buffer_zero(16, SCOPE_FRAME, "autoobject_resident_asset_lookup_dummy")
		if not asset_lookup_buffer.is_valid():
			gc_frame()
			push_error("[GPUAutoObjectRuntime] _dispatch_accepted_placement_resident_shader(): asset_lookup 占位缓冲创建失败。")
			assert(false, "GPUAutoObjectRuntime._dispatch_accepted_placement_resident_shader: dummy asset_lookup buffer failed")
			return {"ok": false, "reason": "resident_shader_setup_failed", "applied_on_gpu": false}
		# Dummy is one ivec4; the gate is unreachable in legacy mode (meta.w==0)
		# but keep the capacity value consistent with the bound buffer.
		asset_lookup_capacity = 1
	var set0 := create_uniform_set([
		make_storage_uniform(0, placement_results_rid),
		make_storage_uniform(1, world_results_rid),
		make_storage_uniform(2, stamp_bounds_rid),
		make_storage_uniform(3, reserved_ids_buffer),
		make_storage_uniform(4, asset_lookup_buffer),
	], shader, 0, SCOPE_FRAME, "autoobject_resident_accepted_placement_set0")
	var set1 := create_uniform_set(
		_pack_accepted_placement_uniforms(0, stats_buffer),
		shader, 1, SCOPE_FRAME, "autoobject_resident_accepted_placement_set1"
	)
	if not set0.is_valid() or not set1.is_valid():
		gc_frame()
		push_error("[GPUAutoObjectRuntime] _dispatch_accepted_placement_resident_shader(): uniform set 创建失败（set0=%s, set1=%s）—— 不继续 dispatch。" % [
			set0.is_valid(), set1.is_valid()])
		assert(false, "GPUAutoObjectRuntime._dispatch_accepted_placement_resident_shader: uniform set create failed")
		return {"ok": false, "reason": "resident_shader_uniform_set_failed", "applied_on_gpu": false}

	var grid_value = asset_params.get("grid_size", Vector3i.ZERO)
	var grid_size: Vector3i = grid_value if grid_value is Vector3i else Vector3i.ZERO
	# 混合资产模式下 shader 用 grid 反解 world_meta.z → asset_lookup；grid 缺失时补 0
	# 会让每条记录都解到错误的 asset，必须硬失败而不是带着 (0,0,0) 进 dispatch。
	if use_asset_lookup and (grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0):
		gc_frame()
		push_error("[GPUAutoObjectRuntime] _dispatch_accepted_placement_resident_shader(): 混合资产模式缺少合法 asset_params.grid_size（实得 %s）—— push constant 不补默认值。" % [grid_value])
		assert(false, "GPUAutoObjectRuntime._dispatch_accepted_placement_resident_shader: missing grid_size for asset lookup")
		return {"ok": false, "reason": "resident_shader_missing_grid_size", "applied_on_gpu": false}
	var dirty_bits := _dirty_flags_to_bits(asset_params.get("dirty_flags", {}))
	var push := PushConstantLayout.new(RESIDENT_PLACEMENT_PUSH).pack({
		record_count = record_count,
		max_objects = max_objects,
		dirty_delta_capacity = dirty_delta_capacity,
		dirty_base = dirty_base,
		profile_id = int(asset_params.get("profile_id", -1)),
		object_type = int(asset_params.get("object_type", 0)),
		object_flags = int(asset_params.get("object_flags", 0)),
		dirty_bits = dirty_bits,
		asset_index = int(asset_params.get("asset_index", -1)),
		flush_epoch = _flush_epoch,
		stats_u32_count = ACCEPTED_PLACEMENT_RECORD_SHADER_STATS_U32_COUNT,
		use_asset_lookup = 1 if use_asset_lookup else 0,
		grid_x = grid_size.x,
		grid_y = grid_size.y,
		grid_z = grid_size.z,
		asset_lookup_capacity = maxi(asset_lookup_capacity, 0),
	})

	var group_count := ceil_div(record_count, ACCEPTED_PLACEMENT_RECORD_SHADER_LOCAL_SIZE_X)
	var cl := begin_compute_list()
	if cl < 0:
		gc_frame()
		push_error("[GPUAutoObjectRuntime] _dispatch_accepted_placement_resident_shader(): compute_list_begin 失败 (cl=%d, record_count=%d)。" % [
			cl, record_count])
		assert(false, "GPUAutoObjectRuntime._dispatch_accepted_placement_resident_shader: compute list begin failed")
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
			push_error("[GPUAutoObjectRuntime] _dispatch_accepted_placement_resident_shader(): dirty count 回读失败 (%s)。" % result["reason"])
			assert(false, "GPUAutoObjectRuntime._dispatch_accepted_placement_resident_shader: dirty count readback failed")
			return result
		_dirty_delta_count = int(count_result["count"])
		if not stats_ok:
			result["ok"] = false
			result["reason"] = "resident_shader_stats_failed"
			push_error("[GPUAutoObjectRuntime] _dispatch_accepted_placement_resident_shader(): shader 统计不符（applied=%d/期望 %d, skipped=%d/期望 0）。" % [
				int(stats.get("applied", -1)), record_count, int(stats.get("skipped", -1))])
			assert(false, "GPUAutoObjectRuntime._dispatch_accepted_placement_resident_shader: shader stats mismatch")
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


## 通过 GPU 着色器批量写入接受放置记录；成功返回 ok=true。
## （曾有 use_accepted_placement_record_shader 开关门；唯一调用方恒置 true，守卫已删。）
func _try_apply_accepted_placement_record_shader(
	records: Array[Dictionary],
	accepted_placement_record_bytes: PackedByteArray,
	options: Dictionary
) -> Dictionary:
	var base_result := {
		"ok": false,
		"reason": "accepted_placement_record_shader_pending",
		"attempted": true,
		"runtime_command_flush_mode": "resident_accepted_placement_record_shader_writeback",
		"accepted_placement_record_shader_consumed": false,
		"accepted_placement_record_shader_name": ACCEPTED_PLACEMENT_RECORD_SHADER_NAME,
		"accepted_placement_record_shader_path": ACCEPTED_PLACEMENT_RECORD_SHADER_PATH,
		"accepted_placement_record_shader_dispatch_count": 0,
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
		"resident_gpu_allocator_writeback_blocked_reason": "no_resident_allocator_shader_dispatch",
		"pending_dirty_delta_count": _dirty_delta_count,
	}
	if records.is_empty():
		base_result["ok"] = true
		base_result["reason"] = "ok"
		base_result["pending_dirty_delta_count"] = _dirty_delta_count
		return base_result
	if not _gpu_ready or _rd == null or not _all_required_buffers_valid():
		base_result["reason"] = "runtime_not_ready"
		base_result["resident_gpu_allocator_writeback_blocked_reason"] = "runtime_not_ready"
		push_error("[GPUAutoObjectRuntime] _try_apply_accepted_placement_record_shader(): 运行时缓冲不可用（gpu_ready=%s, rd=%s, buffers_valid=%s, records=%d）。" % [
			_gpu_ready, _rd != null, _all_required_buffers_valid(), records.size()])
		assert(false, "GPUAutoObjectRuntime._try_apply_accepted_placement_record_shader: runtime buffers not ready")
		return base_result
	if accepted_placement_record_bytes.size() != records.size() * ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES:
		base_result["reason"] = "accepted_placement_record_pack_failed"
		base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_pack_failed"
		push_error("[GPUAutoObjectRuntime] _try_apply_accepted_placement_record_shader(): 记录打包字节数不符（期望 %d = %d 条 × %d 字节，实得 %d）。" % [
			records.size() * ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES, records.size(),
			ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES, accepted_placement_record_bytes.size()])
		assert(false, "GPUAutoObjectRuntime._try_apply_accepted_placement_record_shader: record pack byte count mismatch")
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
	var kernel := ensure_shader_kernel(
		ACCEPTED_PLACEMENT_RECORD_SHADER_PATH,
		ACCEPTED_PLACEMENT_RECORD_SHADER_NAME
	)
	var shader: RID = kernel.get("shader", RID())
	var pipeline: RID = kernel.get("pipeline", RID())
	if not accepted_buffer.is_valid() or not stats_buffer.is_valid() or not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		base_result["reason"] = "accepted_placement_record_shader_setup_failed"
		base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_shader_setup_failed"
		push_error("[GPUAutoObjectRuntime] _try_apply_accepted_placement_record_shader(): setup 失败（records_buffer=%s, stats=%s, shader=%s, pipeline=%s, path=%s）—— 不继续 dispatch。" % [
			accepted_buffer.is_valid(), stats_buffer.is_valid(), shader.is_valid(), pipeline.is_valid(),
			ACCEPTED_PLACEMENT_RECORD_SHADER_PATH])
		assert(false, "GPUAutoObjectRuntime._try_apply_accepted_placement_record_shader: setup failed")
		return base_result

	var uniforms := [make_storage_uniform(0, accepted_buffer)]
	uniforms.append_array(_pack_accepted_placement_uniforms(1, stats_buffer))
	var uniform_set := create_uniform_set(uniforms, shader, 0, SCOPE_FRAME, "autoobject_apply_accepted_placements_set0")
	if not uniform_set.is_valid():
		gc_frame()
		base_result["reason"] = "accepted_placement_record_uniform_set_failed"
		base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_uniform_set_failed"
		push_error("[GPUAutoObjectRuntime] _try_apply_accepted_placement_record_shader(): uniform set 创建失败（set=0，%d 个 uniform）—— 不继续 dispatch。" % uniforms.size())
		assert(false, "GPUAutoObjectRuntime._try_apply_accepted_placement_record_shader: uniform set create failed")
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
		push_error("[GPUAutoObjectRuntime] _try_apply_accepted_placement_record_shader(): compute_list_begin 失败 (cl=%d, record_count=%d)。" % [
			cl, record_count])
		assert(false, "GPUAutoObjectRuntime._try_apply_accepted_placement_record_shader: compute list begin failed")
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
			push_error("[GPUAutoObjectRuntime] _try_apply_accepted_placement_record_shader(): dirty count 回读失败 (%s)。" % base_result["reason"])
			assert(false, "GPUAutoObjectRuntime._try_apply_accepted_placement_record_shader: dirty count readback failed")
			return base_result
		_dirty_delta_count = int(count_result["count"])
		base_result["pending_dirty_delta_count"] = _dirty_delta_count
		if not stats_ok:
			base_result["reason"] = "accepted_placement_record_shader_stats_failed"
			base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_shader_stats_failed"
			push_error("[GPUAutoObjectRuntime] _try_apply_accepted_placement_record_shader(): shader 统计不符 %s（期望 applied=%d 且其余为 0、dispatched=1）。" % [
				stats, record_count])
			assert(false, "GPUAutoObjectRuntime._try_apply_accepted_placement_record_shader: shader stats mismatch")
			return base_result
		if _dirty_delta_count != dirty_base + record_count:
			base_result["reason"] = "accepted_placement_record_dirty_count_mismatch"
			base_result["resident_gpu_allocator_writeback_blocked_reason"] = "accepted_placement_record_dirty_count_mismatch"
			push_error("[GPUAutoObjectRuntime] _try_apply_accepted_placement_record_shader(): dirty delta 计数不符（GPU=%d，期望 %d = base %d + %d 条）。" % [
				_dirty_delta_count, dirty_base + record_count, dirty_base, record_count])
			assert(false, "GPUAutoObjectRuntime._try_apply_accepted_placement_record_shader: dirty count mismatch")
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



## 组装接受放置 shader 共享的对象状态 uniform 块（alive..stats..asset_index 共 14 个存储缓冲区，
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
		# asset_index 追加在末尾而不是插在中间：两条 spawn 路径共用本组装器，插中间会
		# 静默平移记录路径 set0 里 accepted_buffer 之后的每一个 binding。
		make_storage_uniform(base_binding + 13, _asset_index_buffer),
	]


## 从 stats 缓冲区读回接受放置着色器的统计信息（调试路径）。
# Debug-only: reads GPU stats buffer via buffer_get_data after accepted placement shader dispatch.
# Production path (debug_read_stats=false) skips this readback entirely.
func _read_accepted_placement_record_shader_stats(stats_buffer: RID) -> Dictionary:
	var bytes := read_buffer_bytes(stats_buffer, 0, ACCEPTED_PLACEMENT_RECORD_SHADER_STATS_U32_COUNT * 4)
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


# Resident GPU dirty delta → SPA-owned SceneVoxelTileStore update pass.
## 通过 GPU 驻留 dirty delta 缓冲区直接触发 SceneVoxelTileStore 的对象引用更新 Pass。
func _try_flush_resident_dirty_delta_buffer_to_scene_voxel_committer(tile_store, options: Dictionary) -> Dictionary:
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
	if tile_store == null or not tile_store.has_method("try_apply_gpu_autoobject_object_ref_update_pass_from_buffer"):
		result["reason"] = "missing_resident_dirty_delta_buffer_api"
		return result
	if not _gpu_ready or _rd == null:
		result["reason"] = "runtime_not_ready"
		return result
	if not _dirty_delta_buffer.is_valid():
		result["reason"] = "dirty_delta_buffer_not_ready"
		return result
	if not tile_store.has_method("get_rendering_device"):
		result["reason"] = "tile_store_rendering_device_not_available"
		return result

	var tile_store_rd = rendering_device_of(tile_store)
	if tile_store_rd == null:
		result["reason"] = "tile_store_rendering_device_not_ready"
		return result
	if tile_store_rd != _rd:
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

	var update_result: Dictionary = tile_store.call(
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


## 将所有 dirty delta 提交给 SPA-owned SceneVoxelTileStore；不提供 CPU bridge。
func flush_to_scene_voxel_committer(tile_store, options: Dictionary = {}) -> Dictionary:
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
	var has_resident_buffer_api: bool = tile_store != null and tile_store.has_method("try_apply_gpu_autoobject_object_ref_update_pass_from_buffer")
	if tile_store == null or not has_resident_buffer_api:
		return {
			"ok": false,
			"reason": "missing_tile_store",
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

	var resident_result := _try_flush_resident_dirty_delta_buffer_to_scene_voxel_committer(tile_store, options)
	if bool(resident_result.get("resident_gpu_dirty_delta_update_pass", false)):
		resident_result["dirty_scene_voxel_tile_count"] = int(resident_result.get("dirty_tile_worklist_count", 0))
		return resident_result

	var blocked_reason := str(resident_result.get("reason", "resident_dirty_delta_update_pass_blocked"))
	return {
		"ok": false,
		"reason": blocked_reason,
		"dirty_deltas": [],
		"dirty_delta_count": 0,
		"results": [],
		"commit_result_count": 0,
		"failed_commit_result_count": 0,
		"pending_dirty_delta_count": int(resident_result.get("pending_dirty_delta_count", get_pending_dirty_delta_count())),
		"dirty_scene_voxel_tile_count": 0,
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


## 批量回读对象状态（渲染/pick 消费面：object_id/alive/profile_id/bounds/transform）。
## 每个缓冲整读一次（5 次 buffer_get_data），数千对象仍在几十 ms 内——放置累积渲染的
## 规模化读口，也是本类唯一的对象状态回读口。
## 2026-08-07：逐 id 的调试口 get_object_summary / get_selected_debug_summary /
## get_debug_summary 及其共用的 _read_object_state 已删除（每个对象 10 次同步回读，
## 调用方归零）。
func readback_object_states_bulk(object_ids: Array) -> Array:
	var out: Array = []
	if object_ids.is_empty():
		return out
	if not _gpu_ready:
		push_error("[GPUAutoObjectRuntime] readback_object_states_bulk(): 运行时未就绪 (%s) —— 请求 %d 个对象，不返回空数组顶替。" % [
			_not_ready_reason, object_ids.size()])
		assert(false, "GPUAutoObjectRuntime.readback_object_states_bulk: runtime not ready")
		return out
	var alive_bytes := read_buffer_bytes(_alive_buffer, 0, max_objects * OBJECT_SCALAR_STRIDE_BYTES)
	var profile_bytes := read_buffer_bytes(_profile_buffer, 0, max_objects * OBJECT_SCALAR_STRIDE_BYTES)
	var bounds_min_bytes := read_buffer_bytes(_bounds_min_buffer, 0, max_objects * OBJECT_BOUNDS_STRIDE_BYTES)
	var bounds_max_bytes := read_buffer_bytes(_bounds_max_buffer, 0, max_objects * OBJECT_BOUNDS_STRIDE_BYTES)
	var transform_bytes := read_buffer_bytes(_transform_buffer, 0, max_objects * OBJECT_TRANSFORM_STRIDE_BYTES)
	for raw_id in object_ids:
		var object_id := int(raw_id)
		if not _is_valid_id(object_id):
			continue
		var scalar_offset := object_id * OBJECT_SCALAR_STRIDE_BYTES
		var bounds_offset := object_id * OBJECT_BOUNDS_STRIDE_BYTES
		var transform_offset := object_id * OBJECT_TRANSFORM_STRIDE_BYTES
		if scalar_offset + OBJECT_SCALAR_STRIDE_BYTES > alive_bytes.size() \
				or bounds_offset + OBJECT_BOUNDS_STRIDE_BYTES > bounds_min_bytes.size() \
				or transform_offset + OBJECT_TRANSFORM_STRIDE_BYTES > transform_bytes.size():
			# 旧行为 continue 静默丢条目：整读的缓冲短了就是回读失败，不能只吐一半对象。
			push_error("[GPUAutoObjectRuntime] readback_object_states_bulk(): 回读缓冲长度不足（object_id=%d，alive=%d/%d, bounds=%d/%d, transform=%d/%d 字节）—— 放弃整批。" % [
				object_id,
				alive_bytes.size(), max_objects * OBJECT_SCALAR_STRIDE_BYTES,
				bounds_min_bytes.size(), max_objects * OBJECT_BOUNDS_STRIDE_BYTES,
				transform_bytes.size(), max_objects * OBJECT_TRANSFORM_STRIDE_BYTES])
			assert(false, "GPUAutoObjectRuntime.readback_object_states_bulk: short buffer readback")
			return []
		out.append({
			"object_id": object_id,
			"alive": alive_bytes.decode_s32(scalar_offset) != 0,
			"profile_id": profile_bytes.decode_s32(scalar_offset),
			"voxel_min": BufferUtils.decode_vec3i4(bounds_min_bytes.slice(bounds_offset, bounds_offset + OBJECT_BOUNDS_STRIDE_BYTES)),
			"voxel_max": BufferUtils.decode_vec3i4(bounds_max_bytes.slice(bounds_offset, bounds_offset + OBJECT_BOUNDS_STRIDE_BYTES)),
			"transform": BufferUtils.decode_transform_mat4(transform_bytes.slice(transform_offset, transform_offset + OBJECT_TRANSFORM_STRIDE_BYTES)),
		})
	return out


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
	if name == GPU_BUFFER_ASSET_INDEX or name == "autoobject_asset_index":
		return _asset_index_buffer
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
		"object_revision": get_object_revision(),
		"free_count": _free_ids.size() if _gpu_ready else 0,
		"dirty_delta_capacity": dirty_delta_capacity,
		"alive_buffer": _alive_buffer.is_valid(),
		"generation_buffer": _generation_buffer.is_valid(),
		"type_buffer": _type_buffer.is_valid(),
		"profile_buffer": _profile_buffer.is_valid(),
		"flags_buffer": _flags_buffer.is_valid(),
		"bounds_min_buffer": _bounds_min_buffer.is_valid(),
		"bounds_max_buffer": _bounds_max_buffer.is_valid(),
		"asset_index_buffer": _asset_index_buffer.is_valid(),
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
	var bytes := read_buffer_bytes(_alive_buffer, 0, max_objects * OBJECT_SCALAR_STRIDE_BYTES)
	if bytes.size() < max_objects * OBJECT_SCALAR_STRIDE_BYTES:
		push_error("[GPUAutoObjectRuntime] get_live_count(): alive 缓冲回读不足（期望 %d，实得 %d）—— 不返回 0 顶替。" % [
			max_objects * OBJECT_SCALAR_STRIDE_BYTES, bytes.size()])
		assert(false, "GPUAutoObjectRuntime.get_live_count: short alive buffer readback")
		return -1
	var live_count := 0
	for object_id in range(max_objects):
		var offset := object_id * OBJECT_SCALAR_STRIDE_BYTES
		if bytes.decode_s32(offset) != 0:
			live_count += 1
	return live_count


## 返回指定 GPU 缓冲区名称对应的每条记录字节步长。
func _gpu_buffer_stride_bytes(buffer_name: String) -> int:
	match buffer_name:
		GPU_BUFFER_ALIVE, GPU_BUFFER_GENERATION, GPU_BUFFER_TYPE, GPU_BUFFER_PROFILE, GPU_BUFFER_FLAGS, GPU_BUFFER_DIRTY_COUNT, GPU_BUFFER_ASSET_INDEX:
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
		GPU_BUFFER_ALIVE, GPU_BUFFER_GENERATION, GPU_BUFFER_TYPE, GPU_BUFFER_PROFILE, GPU_BUFFER_FLAGS, GPU_BUFFER_BOUNDS_MIN, GPU_BUFFER_BOUNDS_MAX, GPU_BUFFER_PREVIOUS_BOUNDS_MIN, GPU_BUFFER_PREVIOUS_BOUNDS_MAX, GPU_BUFFER_TRANSFORM, GPU_BUFFER_ASSET_INDEX:
			return max_objects
		GPU_BUFFER_DIRTY_DELTA:
			return dirty_delta_capacity
		GPU_BUFFER_DIRTY_COUNT:
			return 1
	return 0


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
	# asset_index：spawn 未写过的槽位必须是"无资产"而不是 asset 0，否则 emit 会把死槽位
	# 算进 0 号资产的批里。0 填充在这里是安全的（配套的 alive 也是 0，emit 只看 alive），
	# 但 reset shader 与两条 spawn shader 仍显式写它，避免依赖分配期的隐式零值。
	_asset_index_buffer = storage_buffer_zero(max_objects * OBJECT_SCALAR_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_asset_index")

	_gpu_ready = _all_required_buffers_valid()
	if not _gpu_ready:
		_not_ready_reason = "buffer_create_failed"
		push_error("[GPUAutoObjectRuntime] _create_gpu_buffers(): 常驻对象缓冲分配失败（max_objects=%d, dirty_delta_capacity=%d）—— 运行时不可用。" % [
			max_objects, dirty_delta_capacity])
		assert(false, "GPUAutoObjectRuntime._create_gpu_buffers: buffer create failed")
		return

	if not _write_dirty_count(0):
		_gpu_ready = false
		_not_ready_reason = "dirty_count_write_failed"
		push_error("[GPUAutoObjectRuntime] _create_gpu_buffers(): dirty count 初始化写入失败 —— 运行时不可用。")
		assert(false, "GPUAutoObjectRuntime._create_gpu_buffers: dirty count write failed")


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
	_asset_index_buffer = RID()


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
		or _asset_index_buffer.is_valid()
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
		and _asset_index_buffer.is_valid()
	)


## 从空闲 ID 栈弹出一个可用对象 ID，空闲池为空时返回 -1。
func _allocate_id() -> int:
	if _free_ids.is_empty():
		return -1
	return int(_free_ids.pop_back())


## 将 dirty delta 计数写入 GPU 计数缓冲区并同步 CPU 侧缓存。
func _write_dirty_count(count: int, sync_after: bool = true) -> bool:
	if count < 0 or count > dirty_delta_capacity:
		# 旧行为静默 clamp，会把越界写掩盖成一次"看起来成功"的写入。
		push_error("[GPUAutoObjectRuntime] _write_dirty_count(): 计数越界 (count=%d, capacity=%d) —— 不 clamp。" % [
			count, dirty_delta_capacity])
		assert(false, "GPUAutoObjectRuntime._write_dirty_count: count out of range")
		return false
	if not _write_buffer(_dirty_count_buffer, 0, BufferUtils.pack_s32(count), sync_after):
		return false
	_dirty_delta_count = count
	return true


## 从 GPU 读取当前 dirty delta 计数；回读失败返回 -1（不再用 CPU 缓存值顶替）。
func _read_dirty_delta_count() -> int:
	var result := _read_dirty_delta_count_result()
	if bool(result.get("ok", false)):
		return int(result["count"])
	push_error("[GPUAutoObjectRuntime] _read_dirty_delta_count(): dirty count 回读失败 (%s) —— 不返回 CPU 缓存值 %d。" % [
		str(result.get("reason", "unknown")), _dirty_delta_count])
	assert(false, "GPUAutoObjectRuntime._read_dirty_delta_count: readback failed")
	return -1


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
	var bytes := read_buffer_bytes(_dirty_count_buffer, 0, OBJECT_SCALAR_STRIDE_BYTES)
	if bytes.size() < OBJECT_SCALAR_STRIDE_BYTES:
		push_error("[GPUAutoObjectRuntime] _read_dirty_delta_count_result(): 回读字节不足（期望 %d，实得 %d）。" % [
			OBJECT_SCALAR_STRIDE_BYTES, bytes.size()])
		assert(false, "GPUAutoObjectRuntime._read_dirty_delta_count_result: short readback")
		return {
			"ok": false,
			"reason": "dirty_count_readback_failed",
			"count": -1,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
			"failed_readback_source": "gpu_dirty_count_buffer",
		}
	var count := bytes.decode_s32(0)
	if count < 0 or count > dirty_delta_capacity:
		# 旧行为静默 clamp 到容量，会把 shader 侧的 dirty delta 溢出伪装成"刚好写满"。
		push_error("[GPUAutoObjectRuntime] _read_dirty_delta_count_result(): GPU 报告的 dirty count 越界 (count=%d, capacity=%d) —— 不 clamp。" % [
			count, dirty_delta_capacity])
		assert(false, "GPUAutoObjectRuntime._read_dirty_delta_count_result: count out of range")
		return {
			"ok": false,
			"reason": "dirty_count_out_of_range",
			"count": count,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "gpu_dirty_count_buffer",
			"failed_readback_source": "gpu_dirty_count_buffer",
		}
	_dirty_delta_count = count
	return {
		"ok": true,
		"reason": "ok",
		"count": count,
		"readback_source": "gpu_dirty_count_buffer",
	}


## 从 GPU generation 缓冲区读取指定对象 ID 的世代号；失败返回 -1（调用方必须整批放弃）。
func _read_generation(object_id: int) -> int:
	if not _gpu_ready or not _is_valid_id(object_id):
		push_error("[GPUAutoObjectRuntime] _read_generation(): 运行时未就绪或 object_id 越界 (gpu_ready=%s, object_id=%d, max_objects=%d)。" % [
			_gpu_ready, object_id, max_objects])
		assert(false, "GPUAutoObjectRuntime._read_generation: runtime not ready or invalid object_id")
		return -1
	return _read_s32(_generation_buffer, object_id * OBJECT_SCALAR_STRIDE_BYTES)


## 调用 RenderingDevice.buffer_update 将字节写入指定 GPU 缓冲区偏移处。
func _write_buffer(buffer: RID, offset: int, bytes: PackedByteArray, sync_after: bool = true) -> bool:
	if _rd == null:
		push_error("[GPUAutoObjectRuntime] _write_buffer(): RenderingDevice 为 null（offset=%d, %d 字节）。" % [offset, bytes.size()])
		assert(false, "GPUAutoObjectRuntime._write_buffer: no RenderingDevice")
		return false
	if not buffer.is_valid():
		push_error("[GPUAutoObjectRuntime] _write_buffer(): 目标 buffer RID 无效（offset=%d, %d 字节）—— 不静默跳过写入。" % [
			offset, bytes.size()])
		assert(false, "GPUAutoObjectRuntime._write_buffer: invalid buffer RID")
		return false
	if bytes.is_empty():
		push_error("[GPUAutoObjectRuntime] _write_buffer(): 写入载荷为空（offset=%d）。" % offset)
		assert(false, "GPUAutoObjectRuntime._write_buffer: empty payload")
		return false
	var err := _rd.buffer_update(buffer, offset, bytes.size(), bytes)
	if err != OK:
		push_error("[GPUAutoObjectRuntime] _write_buffer(): buffer_update 失败 err=%d（offset=%d, %d 字节）。" % [
			err, offset, bytes.size()])
		assert(false, "GPUAutoObjectRuntime._write_buffer: buffer_update failed")
		return false
	if sync_after:
		submit_and_sync()
	return true


## 从 GPU 缓冲区读取单个 int32 值；回读不足时返回 -1（不再用 0 顶替，0 与合法值不可区分）。
func _read_s32(buffer: RID, offset: int) -> int:
	var bytes := read_buffer_bytes(buffer, offset, OBJECT_SCALAR_STRIDE_BYTES)
	if bytes.size() < OBJECT_SCALAR_STRIDE_BYTES:
		push_error("[GPUAutoObjectRuntime] _read_s32(): 回读字节不足（offset=%d，期望 %d，实得 %d）。" % [
			offset, OBJECT_SCALAR_STRIDE_BYTES, bytes.size()])
		assert(false, "GPUAutoObjectRuntime._read_s32: short readback")
		return -1
	return bytes.decode_s32(0)


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


## 将传入的 dirty flags 与默认标志（auto+object_refs）合并后返回。
func _merge_dirty_flags(dirty_flags: Dictionary) -> Dictionary:
	var result := DEFAULT_DIRTY_FLAGS.duplicate()
	for key in dirty_flags.keys():
		result[key] = bool(dirty_flags[key])
	return result


## 检查 object_id 是否在 [0, max_objects) 范围内。
func _is_valid_id(object_id: int) -> bool:
	return object_id >= 0 and object_id < max_objects
