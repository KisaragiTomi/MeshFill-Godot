@tool
extends RefCounted

# placement_results_to_world.glsl 的 CPU 侧共享契约:着色器路径、记录 stride 与 64 字节 push 布局。
# 原 VoxelPlacementOutput 与 VoxelPlacementWriteback 各持一份(路径 / stride 常量 / push 打包三重重复),
# 两端布局必须与 GLSL 中的 std430 push constant 逐字段一致,集中于此避免漂移。

const RESULTS_TO_WORLD_SHADER_PATH := "res://shaders/placement_results_to_world.glsl"
const RECORD_STRIDE_VEC4 := 4        # 每条 placement result 记录 = 4 × vec4
const WORLD_RESULT_STRIDE_VEC4 := 4  # 每条 world 结果 = 4 × vec4
const RESULTS_TO_WORLD_LOCAL_SIZE := 64


## results→world 的共享派发骨架（shader → pipeline → world 缓冲 → set0 → push →
## dispatch → submit）。owner 为 GodotComputeShaderBase 实例；world 缓冲固定
## SCOPE_FRAME（output 用后即 dispose，writeback 由 runtime 消费后 gc_frame 释放）。
## pivot 二选一：pivot_records_rid 有效 ⟹ per-record 模式（record[1].w =
## global_pivot_index 查容器常驻 pivot_records，push pivot 忽略）；无效 ⟹
## 绑 4 字节 dummy、退回共享 push pivot（遗留调用面）。
## 失败返回 {"ok": false, "fail_step": shader|world_buffer|uniform_set|compute_list}，
## 由调用方映射为各自既有的 reason 诊断字符串；成功返回 world_results_rid 与 dispatch_groups。
static func dispatch_results_to_world(
	owner,
	placement_results_rid: RID,
	record_count: int,
	rotation_count: int,
	grid_origin: Vector3,
	voxel_size: Vector3,
	pivot_offset: Vector3,
	shader_scope: String,
	world_buffer_label: String,
	set_label: String,
	pivot_records_rid: RID = RID()
) -> Dictionary:
	var shader: RID = owner.load_compute_shader(RESULTS_TO_WORLD_SHADER_PATH, shader_scope, "placement_results_to_world")
	var pipeline: RID = owner.create_compute_pipeline(shader, shader_scope, "placement_results_to_world")
	if not shader.is_valid() or not pipeline.is_valid():
		return {"ok": false, "fail_step": "shader"}
	var world_buffer: RID = owner.storage_buffer_zero(record_count * WORLD_RESULT_STRIDE_VEC4 * 16, owner.SCOPE_FRAME, world_buffer_label)
	if not world_buffer.is_valid():
		return {"ok": false, "fail_step": "world_buffer"}
	var use_pivot_records := pivot_records_rid.is_valid()
	var pivot_buffer := pivot_records_rid
	if not use_pivot_records:
		pivot_buffer = owner.storage_buffer_zero(32, owner.SCOPE_FRAME, "results_to_world_pivot_dummy")
		if not pivot_buffer.is_valid():
			return {"ok": false, "fail_step": "world_buffer"}
	var set0: RID = owner.create_uniform_set([
		owner.make_storage_uniform(0, placement_results_rid),
		owner.make_storage_uniform(1, world_buffer),
		owner.make_storage_uniform(2, pivot_buffer),
	], shader, 0, owner.SCOPE_PASS, set_label)
	if not set0.is_valid():
		return {"ok": false, "fail_step": "uniform_set"}
	var push := pack_results_to_world_push(
		record_count, rotation_count, grid_origin, voxel_size, pivot_offset, use_pivot_records)
	var groups := Vector3i(owner.ceil_div(record_count, RESULTS_TO_WORLD_LOCAL_SIZE), 1, 1)
	var cl: int = owner.begin_compute_list()
	if cl < 0:
		return {"ok": false, "fail_step": "compute_list"}
	owner._gpu_dispatch_pipeline_sets(cl, pipeline, [set0], push, groups)
	owner.end_compute_list()
	owner.submit_and_sync(true)
	return {"ok": true, "world_results_rid": world_buffer, "dispatch_groups": groups}


## 打包 results→world pass 的 64 字节 push constant:
## [record_count, rotation_count, record_stride, world_stride] s32 ×4,
## 随后 grid_origin / voxel_size / pivot_offset 三个 padded vec4；
## pivot_offset.w = use_pivot_records 标志（1 = per-record 查 pivot_records）。
## record_count 钳到 ≥0、rotation_count 钳到 ≥1(与 output 原版一致;负数记录数本身即调用方错误)。
static func pack_results_to_world_push(
	record_count: int,
	rotation_count: int,
	grid_origin: Vector3,
	voxel_size: Vector3,
	pivot_offset: Vector3,
	use_pivot_records: bool = false
) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(64)
	bytes.encode_s32(0, maxi(record_count, 0))
	bytes.encode_s32(4, maxi(rotation_count, 1))
	bytes.encode_s32(8, RECORD_STRIDE_VEC4)
	bytes.encode_s32(12, WORLD_RESULT_STRIDE_VEC4)
	bytes.encode_float(16, grid_origin.x)
	bytes.encode_float(20, grid_origin.y)
	bytes.encode_float(24, grid_origin.z)
	bytes.encode_float(28, 0.0)
	bytes.encode_float(32, voxel_size.x)
	bytes.encode_float(36, voxel_size.y)
	bytes.encode_float(40, voxel_size.z)
	bytes.encode_float(44, 0.0)
	bytes.encode_float(48, pivot_offset.x)
	bytes.encode_float(52, pivot_offset.y)
	bytes.encode_float(56, pivot_offset.z)
	bytes.encode_float(60, 1.0 if use_pivot_records else 0.0)
	return bytes
