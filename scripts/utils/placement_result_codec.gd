@tool
extends RefCounted

# placement_results_to_world.glsl 的 CPU 侧共享契约:着色器路径、记录 stride 与 64 字节 push 布局。
# 原 VoxelPlacementOutput 与 VoxelPlacementWriteback 各持一份(路径 / stride 常量 / push 打包三重重复),
# 两端布局必须与 GLSL 中的 std430 push constant 逐字段一致,集中于此避免漂移。

const RESULTS_TO_WORLD_SHADER_PATH := "res://shaders/placement_results_to_world.glsl"
const RECORD_STRIDE_VEC4 := 4        # 每条 placement result 记录 = 4 × vec4
const WORLD_RESULT_STRIDE_VEC4 := 4  # 每条 world 结果 = 4 × vec4
const RESULTS_TO_WORLD_LOCAL_SIZE := 64

# ============================================================
# placement result 记录 ABI（单一真值源）
# ============================================================
# 4 × vec4 = 64 字节，全部 float32（小端，PackedByteArray.encode_float/decode_float）。
# 该布局由 GLSL 侧 placement 记录缓冲共享，改动即为 GPU ABI 变更。
#   [0]  +0 voxel_origin.x   +4 voxel_origin.y  +8 voxel_origin.z  +12 score
#   [1] +16 anchor_id       +20 asset_index    +24 rotation_index  +28 global_pivot_index
# ⚠ `global_pivot_index` 现在存的是 **Arena 槽内局部** pivot 下标（-1 = 零 pivot），
#   所属 slot 由同记录的 profile_index（[3].x）给出。固定槽位 Arena 化后每个 slot 的
#   pivot 都从 0 起算，不再有跨 profile 的全局累计下标。字段名是冻结契约键，未改。
#   [2] +32 solid_collision +36 loss_before    +40 loss_after      +44 clearance_overlap
#   [3] +48 profile_index   +52 valid(>0.5)    +56 coarse_score    +60 reserved(恒 0)
# 原本由 voxel_placement_output._pack_placement_result_records、
# voxel_placement_generator._decode_records、
# volume_score_fine_selection._decode_candidate_record 各自以硬编码偏移维护。
const PLACEMENT_RECORD_BYTES := RECORD_STRIDE_VEC4 * 16
const OFF_VOXEL_ORIGIN := 0
const OFF_SCORE := 12
const OFF_ANCHOR_ID := 16
const OFF_ASSET_INDEX := 20
const OFF_ROTATION_INDEX := 24
const OFF_GLOBAL_PIVOT_INDEX := 28
const OFF_SOLID_COLLISION := 32
const OFF_LOSS_BEFORE := 36
const OFF_LOSS_AFTER := 40
const OFF_CLEARANCE_OVERLAP := 44
const OFF_PROFILE_INDEX := 48
const OFF_VALID := 52
const OFF_COARSE_SCORE := 56
const OFF_RESERVED := 60


## 将一条 placement result 字典按上述 ABI 写入 bytes 的 base 偏移处。
## 缺省值与原 voxel_placement_output._pack_placement_result_records 逐字一致
## （global_pivot_index / profile_index 缺省 -1，其余数值缺省 0，valid 缺省 false）。
## 调用方负责保证 bytes.size() >= base + PLACEMENT_RECORD_BYTES。
static func encode_placement_record(bytes: PackedByteArray, base: int, record: Dictionary) -> void:
	var origin := VoxelGeneral.vector3i_from_value(record.get("voxel_origin", Vector3i.ZERO), Vector3i.ZERO)
	bytes.encode_float(base + OFF_VOXEL_ORIGIN + 0, float(origin.x))
	bytes.encode_float(base + OFF_VOXEL_ORIGIN + 4, float(origin.y))
	bytes.encode_float(base + OFF_VOXEL_ORIGIN + 8, float(origin.z))
	bytes.encode_float(base + OFF_SCORE, float(record.get("score", 0.0)))
	bytes.encode_float(base + OFF_ANCHOR_ID, float(record.get("anchor_id", 0)))
	bytes.encode_float(base + OFF_ASSET_INDEX, float(record.get("asset_index", 0)))
	bytes.encode_float(base + OFF_ROTATION_INDEX, float(record.get("rotation_index", 0)))
	bytes.encode_float(base + OFF_GLOBAL_PIVOT_INDEX, float(record.get("global_pivot_index", -1)))
	bytes.encode_float(base + OFF_SOLID_COLLISION, float(record.get("solid_collision", 0.0)))
	bytes.encode_float(base + OFF_LOSS_BEFORE, float(record.get("loss_before", 0.0)))
	bytes.encode_float(base + OFF_LOSS_AFTER, float(record.get("loss_after", 0.0)))
	bytes.encode_float(base + OFF_CLEARANCE_OVERLAP, float(record.get("clearance_overlap", 0.0)))
	bytes.encode_float(base + OFF_PROFILE_INDEX, float(record.get("profile_index", -1)))
	bytes.encode_float(base + OFF_VALID, 1.0 if bool(record.get("valid", false)) else 0.0)
	bytes.encode_float(base + OFF_COARSE_SCORE, float(record.get("coarse_score", 0.0)))
	bytes.encode_float(base + OFF_RESERVED, 0.0)


## 上式的逆：从 bytes 的 base 偏移读出一条 placement result 字典。
## 键与插入顺序同时是消费契约（报告/快照按插入序序列化），与原
## _decode_records / _decode_candidate_record 两处逐字一致，不得重排。
## 调用方负责保证 bytes.size() >= base + PLACEMENT_RECORD_BYTES。
static func decode_placement_record(bytes: PackedByteArray, base: int) -> Dictionary:
	return {
		"voxel_origin": Vector3i(
			int(roundf(bytes.decode_float(base + OFF_VOXEL_ORIGIN + 0))),
			int(roundf(bytes.decode_float(base + OFF_VOXEL_ORIGIN + 4))),
			int(roundf(bytes.decode_float(base + OFF_VOXEL_ORIGIN + 8)))
		),
		"score": bytes.decode_float(base + OFF_SCORE),
		"anchor_id": int(roundf(bytes.decode_float(base + OFF_ANCHOR_ID))),
		"asset_index": int(roundf(bytes.decode_float(base + OFF_ASSET_INDEX))),
		"rotation_index": int(roundf(bytes.decode_float(base + OFF_ROTATION_INDEX))),
		"global_pivot_index": int(roundf(bytes.decode_float(base + OFF_GLOBAL_PIVOT_INDEX))),
		"solid_collision": bytes.decode_float(base + OFF_SOLID_COLLISION),
		"loss_before": bytes.decode_float(base + OFF_LOSS_BEFORE),
		"loss_after": bytes.decode_float(base + OFF_LOSS_AFTER),
		"clearance_overlap": bytes.decode_float(base + OFF_CLEARANCE_OVERLAP),
		"profile_index": int(roundf(bytes.decode_float(base + OFF_PROFILE_INDEX))),
		"valid": bytes.decode_float(base + OFF_VALID) > 0.5,
		"coarse_score": bytes.decode_float(base + OFF_COARSE_SCORE),
	}


## results→world 的共享派发骨架（shader → pipeline → world 缓冲 → set0 → push →
## dispatch → submit）。owner 为 GodotComputeShaderBase 实例；world 缓冲固定
## SCOPE_FRAME（output 用后即 dispose，writeback 由 runtime 消费后 gc_frame 释放）。
## pivot 二选一：profile_arena_rid 有效 ⟹ per-record 模式（record[1].w = 槽内局部
## pivot 下标 + record[3].x = slot 索引，查容器常驻 Arena，push pivot 忽略）；无效 ⟹
## 绑 32 字节 dummy、退回共享 push pivot（遗留调用面；该分支 shader 完全不读该 buffer）。
## 失败返回 {"ok": false, "fail_step": shader|world_buffer|uniform_set|compute_list}，
## 由调用方映射为各自既有的 reason 诊断字符串；成功返回 world_results_rid 与 dispatch_groups。
## shader/pipeline 走 owner 的常驻 kernel 注册表（原先由调用方传 shader_scope 决定 FRAME/
## PERSISTENT，writeback 侧的 FRAME 意味着每次 writeback 重编译一遍）。
static func dispatch_results_to_world(
	owner,
	placement_results_rid: RID,
	record_count: int,
	rotation_count: int,
	grid_origin: Vector3,
	voxel_size: Vector3,
	pivot_offset: Vector3,
	world_buffer_label: String,
	set_label: String,
	profile_arena_rid: RID = RID(),
	kernel_host = null
) -> Dictionary:
	# shader/pipeline 可以挂在比 owner 更长命的宿主上：owner 是每次调用 new() 又 dispose()
	# 的 runner 时（VoxelPlacementOutput），挂它等于每次转换都重编译一遍。二者必须是同一个
	# RenderingDevice —— shader RID 跨设备无效，设备不符时退回 owner 自己承担编译。
	var host = owner
	if kernel_host != null and GodotComputeShaderBase.rendering_device_of(kernel_host) == owner.get_rendering_device():
		host = kernel_host
	var kernel: Dictionary = host.ensure_shader_kernel(RESULTS_TO_WORLD_SHADER_PATH, "placement_results_to_world")
	var shader: RID = kernel.get("shader", RID())
	var pipeline: RID = kernel.get("pipeline", RID())
	if not shader.is_valid() or not pipeline.is_valid():
		return {"ok": false, "fail_step": "shader"}
	var world_buffer: RID = owner.storage_buffer_zero(record_count * WORLD_RESULT_STRIDE_VEC4 * 16, owner.SCOPE_FRAME, world_buffer_label)
	if not world_buffer.is_valid():
		return {"ok": false, "fail_step": "world_buffer"}
	var use_arena_pivots := profile_arena_rid.is_valid()
	var pivot_buffer := profile_arena_rid
	if not use_arena_pivots:
		pivot_buffer = owner.storage_buffer_zero(32, owner.SCOPE_FRAME, "results_to_world_arena_dummy")
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
		record_count, rotation_count, grid_origin, voxel_size, pivot_offset, use_arena_pivots)
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
## pivot_offset.w = use_arena_pivots 标志（1 = per-record 查 Arena 的 slot pivot 区）。
## record_count 钳到 ≥0、rotation_count 钳到 ≥1(与 output 原版一致;负数记录数本身即调用方错误)。
static func pack_results_to_world_push(
	record_count: int,
	rotation_count: int,
	grid_origin: Vector3,
	voxel_size: Vector3,
	pivot_offset: Vector3,
	use_arena_pivots: bool = false
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
	bytes.encode_float(60, 1.0 if use_arena_pivots else 0.0)
	return bytes
