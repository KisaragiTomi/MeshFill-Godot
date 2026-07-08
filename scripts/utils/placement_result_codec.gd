@tool
extends RefCounted

# placement_results_to_world.glsl 的 CPU 侧共享契约:着色器路径、记录 stride 与 64 字节 push 布局。
# 原 VoxelPlacementOutput 与 VoxelPlacementWriteback 各持一份(路径 / stride 常量 / push 打包三重重复),
# 两端布局必须与 GLSL 中的 std430 push constant 逐字段一致,集中于此避免漂移。

const RESULTS_TO_WORLD_SHADER_PATH := "res://shaders/placement_results_to_world.glsl"
const RECORD_STRIDE_VEC4 := 4        # 每条 placement result 记录 = 4 × vec4
const WORLD_RESULT_STRIDE_VEC4 := 4  # 每条 world 结果 = 4 × vec4


## 打包 results→world pass 的 64 字节 push constant:
## [record_count, rotation_count, record_stride, world_stride] s32 ×4,
## 随后 grid_origin / voxel_size / pivot_offset 三个 padded vec4。
## record_count 钳到 ≥0、rotation_count 钳到 ≥1(与 output 原版一致;负数记录数本身即调用方错误)。
static func pack_results_to_world_push(
	record_count: int,
	rotation_count: int,
	grid_origin: Vector3,
	voxel_size: Vector3,
	pivot_offset: Vector3
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
	bytes.encode_float(60, 0.0)
	return bytes
