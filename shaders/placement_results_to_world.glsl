#[compute]
#version 450

// Converts compact voxel placement records to world-space placement records.
// Binding order must match PlacementResultCodec.dispatch_results_to_world:
//   set 0 binding 0: readonly placement_result_vec4x4 records.
//   set 0 binding 1: writeonly world_result_vec4x4 records.
//   set 0 binding 2: readonly profile_arena (container-resident 固定槽位 Arena；
//                    dummy when pivot_offset.w == 0 and the push pivot is used
//                    instead — that branch reads the buffer not at all).
// Pivot source (pivot_offset.w > 0.5 = per-record mode): each record carries a
// **slot-local** pivot index in record[1].w (-1 = zero pivot) and its slot index
// (= profile_index) in record[3].x; the pivot world offset is read from that
// slot's pivot region instead of one shared push value.
// Output layout:
//   0: vec4(instance_position.xyz, score)
//   1: vec4(anchor_position.xyz, yaw_degrees)
//   2: vec4 record[2] verbatim (solid_collision, loss_before, loss_after, clearance)
//   3: vec4(record[3].x, valid, asset_index, local_pivot_index)

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PlacementResults {
	vec4 placement_results[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer WorldResults {
	vec4 world_results[];
};

// @@GEN profile_record_layout pivot
// runtime pivot record (GLSL RuntimePivotRecord: vec4 offset_bias / uvec4 ids_pad) — stride 32 B
// SSOT: ProfileRecordSchema.RECORD_LAYOUTS["pivot"] — CPU pack/decode and this GLSL side must match.
// offset 0 f32 offset_x
// offset 4 f32 offset_y
// offset 8 f32 offset_z
// offset 12 f32 score_bias
// offset 16 u32 name_hash_u32
// offset 20 u32 reserved0
// offset 24 u32 reserved1
// offset 28 u32 reserved2
// @@END profile_record_layout pivot
struct RuntimePivotRecord {
	vec4 offset_bias;             // xyz = descriptor-local WORLD offset, w = score_bias
	uvec4 ids_pad;
};

// 固定槽位 Profile Arena：Header/Samples/Pivots/MeshDescription 的唯一 binding。
// pivot 由 (slot_index = profile_index, 槽内局部 pivot 下标) 定位——迁移前是跨
// profile 的全局累计下标，Arena 下每个 slot 的 pivot 都从 0 起算。
layout(set = 0, binding = 2, std430) restrict readonly buffer ProfileArena {
	uint words[];
} profile_arena;

// @@GEN profile_arena_layout constants
// SSOT: ProfileArenaLayout — 由 glsl_constants_block() 发射，勿手改。
// slot 寻址索引 = profile_index（稠密），不是 hash 派生的 profile_id。
const uint PROFILE_ARENA_MAGIC = 1347567942u;
const uint PROFILE_ARENA_LAYOUT_VERSION = 1u;
const uint PROFILE_CAPACITY = 64u;
const uint MAX_SAMPLES_PER_PROFILE = 16384u;
const uint MAX_PIVOTS_PER_PROFILE = 8u;
const uint PROFILE_HEADER_STRIDE_BYTES = 64u;
const uint PROFILE_SAMPLE_STRIDE_BYTES = 32u;
const uint PROFILE_PIVOT_STRIDE_BYTES = 32u;
const uint PROFILE_MESH_STRIDE_BYTES = 128u;
const uint PROFILE_ARENA_HEADER_STRIDE_BYTES = 32u;
const uint PROFILE_SLOTS_OFFSET_BYTES = 32u;
const uint PROFILE_HEADER_OFFSET_BYTES = 0u;
const uint PROFILE_SAMPLE_OFFSET_BYTES = 64u;
const uint PROFILE_PIVOT_OFFSET_BYTES = 524352u;
const uint PROFILE_MESH_OFFSET_BYTES = 524608u;
const uint PROFILE_SLOT_STRIDE_BYTES = 524736u;
const uint PROFILE_ARENA_BYTE_COUNT = 33583136u;
const uint PROFILE_ARENA_WORD_COUNT = 8395784u;
// @@END profile_arena_layout constants

// @@GEN profile_arena_layout accessors
// SSOT: ProfileArenaLayout — 由 glsl_accessors_block() 发射，勿手改。
// 依赖：绑定实例名 `profile_arena`，成员 `uint words[]`。

uint profile_arena_word_at(uint byte_offset) {
    uint word_index = byte_offset >> 2u;
    if (word_index >= PROFILE_ARENA_WORD_COUNT) return 0u;
    return profile_arena.words[word_index];
}

uint profile_slot_base_bytes(uint slot_index) {
    if (slot_index >= PROFILE_CAPACITY) return PROFILE_ARENA_BYTE_COUNT;
    return PROFILE_SLOTS_OFFSET_BYTES + slot_index * PROFILE_SLOT_STRIDE_BYTES;
}

uint profile_word(uint slot_index, uint local_byte_offset) {
    return profile_arena_word_at(profile_slot_base_bytes(slot_index) + local_byte_offset);
}

float profile_float(uint slot_index, uint local_byte_offset) {
    return uintBitsToFloat(profile_word(slot_index, local_byte_offset));
}

uint profile_arena_header_word(uint field_byte_offset) {
    return profile_arena_word_at(field_byte_offset);
}

uint profile_header_word(uint slot_index, uint field_byte_offset) {
    return profile_word(slot_index, PROFILE_HEADER_OFFSET_BYTES + field_byte_offset);
}

uint profile_sample_word(uint slot_index, uint sample_index, uint field_byte_offset) {
    if (sample_index >= MAX_SAMPLES_PER_PROFILE) return 0u;
    return profile_word(slot_index,
        PROFILE_SAMPLE_OFFSET_BYTES + sample_index * PROFILE_SAMPLE_STRIDE_BYTES + field_byte_offset);
}

uint profile_pivot_word(uint slot_index, uint pivot_index, uint field_byte_offset) {
    if (pivot_index >= MAX_PIVOTS_PER_PROFILE) return 0u;
    return profile_word(slot_index,
        PROFILE_PIVOT_OFFSET_BYTES + pivot_index * PROFILE_PIVOT_STRIDE_BYTES + field_byte_offset);
}

uint profile_mesh_word(uint slot_index, uint field_byte_offset) {
    return profile_word(slot_index, PROFILE_MESH_OFFSET_BYTES + field_byte_offset);
}
// @@END profile_arena_layout accessors

// @@GEN profile_arena_layout pivot_accessor
// SSOT: ProfileArenaLayout — 由 glsl_pivot_accessor_block() 发射，勿手改。
// 字段偏移取自 ProfileRecordSchema.RECORD_LAYOUTS["pivot"]（见本文件的
// `@@GEN profile_record_layout pivot` 锚块）。返回的结构体与迁移前同形，
// 下游解码代码不受影响。
RuntimePivotRecord profile_arena_pivot(uint slot_index, uint pivot_index) {
    RuntimePivotRecord record;
    record.offset_bias = vec4(
        uintBitsToFloat(profile_pivot_word(slot_index, pivot_index, 0u)),
        uintBitsToFloat(profile_pivot_word(slot_index, pivot_index, 4u)),
        uintBitsToFloat(profile_pivot_word(slot_index, pivot_index, 8u)),
        uintBitsToFloat(profile_pivot_word(slot_index, pivot_index, 12u)));
    record.ids_pad = uvec4(
        profile_pivot_word(slot_index, pivot_index, 16u),
        profile_pivot_word(slot_index, pivot_index, 20u),
        profile_pivot_word(slot_index, pivot_index, 24u),
        profile_pivot_word(slot_index, pivot_index, 28u));
    return record;
}
// @@END profile_arena_layout pivot_accessor

layout(push_constant, std430) uniform Params {
	ivec4 counts;       // record_count, rotation_count, input_stride, output_stride
	vec4 grid_origin;   // xyz, pad
	vec4 voxel_size;    // xyz, pad
	vec4 pivot_offset;  // xyz = shared push pivot, w = use per-record pivot_records (0/1)
} params;

const float MIN_VOXEL_SIZE = 0.0001;

// @@GEN yaw_rotation_y — generated from scripts/utils/placement_shared_glsl.gd, do not edit
// Canonical Y-yaw rotation, matching Basis(Vector3.UP, yaw):
//   rx =  ca*x + sa*z ;  rz = -sa*x + ca*z ;  y unchanged.
vec3 rotate_yaw_y(vec3 v, float ca, float sa) {
    return vec3(ca * v.x + sa * v.z, v.y, -sa * v.x + ca * v.z);
}

// Float variant for collision-sample offsets: rigid yaw (NO round, NO scale) so
// the sample position stays a genuine float for trilinear sampling.
vec3 rotate_sample_offset_y_f(ivec3 sample_offset, float ca, float sa) {
    return rotate_yaw_y(vec3(sample_offset), ca, sa);
}

// Voxel-snapped variant for integer collision-sample offsets (round x/z, keep y).
ivec3 rotate_sample_offset_y(ivec3 sample_offset, float ca, float sa) {
    vec3 r = rotate_yaw_y(vec3(sample_offset), ca, sa);
    return ivec3(int(round(r.x)), sample_offset.y, int(round(r.z)));
}

// Yaw-only world transform: Basis(Vector3.UP, yaw) columns + instance origin
// (column x = (cos, 0, -sin), column z = (sin, 0, cos)).
mat4 yaw_transform_y(float ca, float sa, vec3 origin) {
    return mat4(
        vec4(ca, 0.0, -sa, 0.0),
        vec4(0.0, 1.0, 0.0, 0.0),
        vec4(sa, 0.0, ca, 0.0),
        vec4(origin, 1.0)
    );
}
// @@END yaw_rotation_y

void main() {
	uint idx = gl_GlobalInvocationID.x;
	uint record_count = uint(max(params.counts.x, 0));
	if (idx >= record_count) {
		return;
	}

	uint input_stride = uint(max(params.counts.z, 1));
	uint output_stride = uint(max(params.counts.w, 1));
	uint input_base = idx * input_stride;
	uint output_base = idx * output_stride;

	vec4 origin_score = placement_results[input_base + 0u];
	vec4 ids = placement_results[input_base + 1u];
	vec4 debug0 = placement_results[input_base + 2u];
	vec4 debug1 = placement_results[input_base + 3u];

	float rotation_count = float(max(params.counts.y, 1));
	float rotation_index = round(ids.z);
	float yaw_degrees = rotation_index * 360.0 / rotation_count;
	float yaw = radians(yaw_degrees);
	float cos_y = cos(yaw);
	float sin_y = sin(yaw);

	vec3 safe_voxel_size = max(params.voxel_size.xyz, vec3(MIN_VOXEL_SIZE));
	// ⚠ `+ 0.5` 不能省：体素**中心**，与 VoxelGeneral.voxel_center_to_world 同式。
	// 这里曾经写成 `grid_origin + voxel * voxel_size`（体素**角**），是全仓唯一一处漏了
	// 半格的 voxel→world 映射——brush/field 显示、统一点选、anchor 标记全都是
	// `(voxel + 0.5) * voxel_size`。症状是放置实例相对 anchor 标记与胜出预览网格恒定偏移
	// 半个体素：当前 voxel_size (4,2,4) 下就是 (2,1,2) m 的 XZ 漂移 + 1 m 下沉。
	// 评分链本身全程在整数体素空间里做，对角/中心没有意见，所以只有这一处输出映射需要改。
	vec3 anchor_position = params.grid_origin.xyz + (origin_score.xyz + 0.5) * safe_voxel_size;
	vec3 pivot = params.pivot_offset.xyz;
	if (params.pivot_offset.w > 0.5) {
		// record[1].w = **槽内局部** pivot 下标（-1 = 零 pivot）；所属 slot 取
		// record[3].x = profile_index（debug1.x）。Arena 化后不再有全局累计下标。
		int local_pivot_index = int(round(ids.w));
		int slot_index = int(round(debug1.x));
		pivot = (local_pivot_index >= 0 && slot_index >= 0)
			? profile_arena_pivot(uint(slot_index), uint(local_pivot_index)).offset_bias.xyz
			: vec3(0.0);
	}
	vec3 pivot_world_offset = rotate_yaw_y(pivot, cos_y, sin_y);
	vec3 instance_position = anchor_position - pivot_world_offset;
	float valid = debug1.y > 0.5 ? 1.0 : 0.0;

	world_results[output_base + 0u] = vec4(instance_position, origin_score.w);
	world_results[output_base + 1u] = vec4(anchor_position, yaw_degrees);
	world_results[output_base + 2u] = debug0;
	world_results[output_base + 3u] = vec4(debug1.x, valid, ids.y, ids.w);
}
