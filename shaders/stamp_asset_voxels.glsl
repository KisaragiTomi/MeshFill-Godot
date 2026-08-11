#[compute]
#version 450

// Mixed-asset stamp (replaces the per-asset stamp_voxel_field.glsl).
//
// One workgroup = one accepted placement record; the 64 threads stride over
// that record's fine ProfileSample slice. Per-record asset metadata comes
// from the record itself (no per-asset dispatch, no per-asset push constants):
//   profile_index      = record[3].x  -> Arena slot index (fine sample + pivot ranges)
//   yaw_slot           = record[1].z
//   local_pivot_index  = record[1].w  (-1 = zero pivot; else 槽内局部 pivot 下标)
// Voxel color/complexity/collision come from each ProfileSampleRecord — the write
// values and the monotonic-max compose are the shared @@GEN ad_voxel_compose
// rules, i.e. exactly what score_anchor_asset_residual.glsl predicted.
// Only STAMP_WRITE samples write; SCORE_ONLY and CLEARANCE samples never write.
//
// Output VoxelStampDeltaBuffer uses 2 vec4 records per written voxel:
//   0: vec4(voxel.xyz, complexity)
//   1: vec4(collision_strength, result_index, sample_index, wrote)
// Output VoxelStampBounds uses 2 uvec4 records per accepted placement:
//   0: uvec4(min_xyz, written_count)
//   1: uvec4(max_xyz_exclusive, reserved)
//
// Dual-commit mode (params.w > 0.5): bindings 0/1 are a transient BlendSV
// working pair (read by same-batch scoring), bindings 10/11 are the committed
// auto-only SV resident pair. The stamp IS the SV commit, so every write also
// lands in the commit pair. With the flag off, 10/11 alias 0/1 and are skipped.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// @@GEN profile_sample_runtime
// Canonical 32-byte ProfileSample GPU record and decoded runtime values.
struct ProfileSampleRecord {
    vec4 offset_weight;
    uvec4 payload;
};

struct ProfileSample {
    vec3 local_offset_world;
    float sample_weight;
    vec4 color;
    float collision;
    vec3 semantic_weights;
    uint flags;
};

struct ProfileSampleFields {
    vec4 current_rgba;
    vec4 target_rgba;
    vec4 predicted_rgba;
    float current_collision;
    float target_collision;
    float predicted_collision;
};

struct ProfileSampleEvaluation {
    vec4 loss_before;
    vec4 loss_after;
    vec4 fits;
    float contribution;
};

const uint PROFILE_SAMPLE_FLAG_COARSE = 1u;
const uint PROFILE_SAMPLE_FLAG_FINE = 2u;
const uint PROFILE_SAMPLE_FLAG_CLEARANCE = 4u;
const uint PROFILE_SAMPLE_FLAG_STAMP_WRITE = 8u;
const uint PROFILE_SAMPLE_FLAG_SCORE_ONLY = 16u;
const uint PROFILE_SAMPLE_POLICY_COARSE_MATCH = 0u;
const uint PROFILE_SAMPLE_POLICY_FINE_RESIDUAL = 1u;
const float PROFILE_SAMPLE_SQRT3 = 1.73205080757;

float unpack_profile_sample_snorm8(uint bits) {
    int value = int(bits & 0xFFu);
    if (value >= 128) value -= 256;
    return clamp(float(value) / 127.0, -1.0, 1.0);
}

vec4 unpack_profile_sample_rgba8(uint packed) {
    return vec4(
        float((packed >> 24u) & 0xFFu),
        float((packed >> 16u) & 0xFFu),
        float((packed >> 8u) & 0xFFu),
        float(packed & 0xFFu)
    ) * (1.0 / 255.0);
}

vec4 unpack_profile_sample_metrics(uint packed) {
    return vec4(
        float(packed & 0xFFu) * (1.0 / 255.0),
        unpack_profile_sample_snorm8(packed >> 8u),
        unpack_profile_sample_snorm8(packed >> 16u),
        unpack_profile_sample_snorm8(packed >> 24u)
    );
}

ProfileSample decode_profile_sample(ProfileSampleRecord record) {
    vec4 metrics = unpack_profile_sample_metrics(record.payload.y);
    ProfileSample decoded;
    decoded.local_offset_world = record.offset_weight.xyz;
    decoded.sample_weight = max(record.offset_weight.w, 0.0);
    decoded.color = unpack_profile_sample_rgba8(record.payload.x);
    decoded.collision = metrics.x;
    decoded.semantic_weights = metrics.yzw;
    decoded.flags = record.payload.z;
    return decoded;
}

ivec3 resolve_profile_sample_voxel(ProfileSample profile_sample, ivec3 anchor_voxel,
        vec3 pivot_world, float yaw_cos, float yaw_sin, vec3 voxel_size) {
    vec3 local_world = profile_sample.local_offset_world - pivot_world;
    vec3 rotated_world = vec3(
        yaw_cos * local_world.x + yaw_sin * local_world.z,
        local_world.y,
        -yaw_sin * local_world.x + yaw_cos * local_world.z
    );
    vec3 safe_voxel_size = max(abs(voxel_size), vec3(1.0e-6));
    return anchor_voxel + ivec3(round(rotated_world / safe_voxel_size));
}

bool profile_sample_in_bounds(ivec3 voxel, ivec3 grid_size) {
    return all(greaterThanEqual(voxel, ivec3(0))) && all(lessThan(voxel, grid_size));
}

ProfileSampleFields load_profile_sample_fields(vec4 current_rgba, float current_collision,
        vec4 target_rgba, float target_collision, vec4 predicted_rgba, float predicted_collision) {
    ProfileSampleFields fields;
    fields.current_rgba = current_rgba;
    fields.target_rgba = target_rgba;
    fields.predicted_rgba = predicted_rgba;
    fields.current_collision = current_collision;
    fields.target_collision = target_collision;
    fields.predicted_collision = predicted_collision;
    return fields;
}

ProfileSampleEvaluation evaluate_profile_sample(ProfileSample profile_sample,
        ProfileSampleFields fields, uint policy) {
    ProfileSampleEvaluation result;
    result.loss_before = vec4(
        abs(fields.current_collision - fields.target_collision),
        abs(fields.current_rgba.a - fields.target_rgba.a),
        dot(abs(fields.current_rgba.rgb - fields.target_rgba.rgb), vec3(1.0)),
        0.0
    );
    result.loss_after = vec4(
        abs(fields.predicted_collision - fields.target_collision),
        abs(fields.predicted_rgba.a - fields.target_rgba.a),
        dot(abs(fields.predicted_rgba.rgb - fields.target_rgba.rgb), vec3(1.0)),
        0.0
    );
    float color_fit = 2.0 * (1.0 - distance(fields.target_rgba.rgb, profile_sample.color.rgb)
        / PROFILE_SAMPLE_SQRT3) - 1.0;
    float complexity_fit = 2.0 * (1.0 - abs(fields.target_rgba.a - profile_sample.color.a)) - 1.0;
    float collision_fit = 1.0 - abs(
        max(fields.target_collision, fields.current_collision) - profile_sample.collision);
    result.fits = vec4(color_fit, complexity_fit, collision_fit, 0.0);
    result.contribution = policy == PROFILE_SAMPLE_POLICY_COARSE_MATCH
        ? profile_sample.sample_weight * dot(profile_sample.semantic_weights, result.fits.xyz)
        : 0.0;
    return result;
}

float profile_sample_weighted_loss(vec4 loss, ProfileSample profile_sample, vec3 dimension_weights) {
    return dimension_weights.x * profile_sample.semantic_weights.z * loss.x
        + dimension_weights.y * profile_sample.semantic_weights.y * loss.y
        + dimension_weights.z * profile_sample.semantic_weights.x * loss.z;
}
// @@END profile_sample_runtime

layout(set = 0, binding = 0, std430) restrict buffer ComplexityField {
    uint complexity_field_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict buffer CollisionField {
    uint collision_field_u32[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer ResultCount {
    uint result_count;
};

// @@GEN profile_record_layout profile_table
// runtime profile_table record (GLSL RuntimeProfileTableRecord: uvec4 ids / uvec4 ranges / vec4 color_complexity / vec4 density_radius_hash_pad) — stride 64 B
// SSOT: ProfileRecordSchema.RECORD_LAYOUTS["profile_table"] — CPU pack/decode and this GLSL side must match.
// offset 0 u32 profile_id
// offset 4 u32 profile_index
// offset 8 u32 coarse_sample_start
// offset 12 u32 coarse_sample_count
// offset 16 u32 fine_sample_start
// offset 20 u32 fine_sample_count
// offset 24 u32 pivot_start
// offset 28 u32 pivot_count
// offset 32 f32 color_r
// offset 36 f32 color_g
// offset 40 f32 color_b
// offset 44 f32 complexity
// offset 48 f32 semantic_probe_density
// offset 52 f32 context_sensing_radius
// offset 56 u32 profile_hash_u32
// offset 60 u32 reserved
// @@END profile_record_layout profile_table
struct RuntimeProfileTableRecord {
    uvec4 ids;                    // x=profile_id, y=profile_index, z=coarse start, w=coarse count
    uvec4 ranges;                 // x=fine start, y=fine count, z=pivot start, w=pivot count
    vec4 color_complexity;
    vec4 density_radius_hash_pad;
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

// @@GEN profile_record_layout profile_sample
// runtime profile sample record (GLSL ProfileSampleRecord: vec4 offset_weight / uvec4 payload) — stride 32 B
// SSOT: ProfileRecordSchema.RECORD_LAYOUTS["profile_sample"] — CPU pack/decode and this GLSL side must match.
// offset 0 f32 offset_x
// offset 4 f32 offset_y
// offset 8 f32 offset_z
// offset 12 f32 sample_weight
// offset 16 u32 rgba8
// offset 20 u32 packed_metrics
// offset 24 u32 flags
// offset 28 u32 reserved
// @@END profile_record_layout profile_sample

// 固定槽位 Profile Arena：Header/Samples/Pivots/MeshDescription 的**唯一** binding。
// 迁移前这里是三个独立 buffer（profile_table @4 / pivot_records @5 /
// profile_sample_records @6），各带一份 host 传入的元素容量；Arena 定长，容量守卫
// 全部收敛成下面发射的编译期常量。
layout(set = 0, binding = 4, std430) restrict readonly buffer ProfileArena {
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

// @@GEN profile_arena_layout table_accessor
// SSOT: ProfileArenaLayout — 由 glsl_profile_table_accessor_block() 发射，勿手改。
// 字段偏移取自 ProfileRecordSchema.RECORD_LAYOUTS["profile_table"]（见本文件的
// `@@GEN profile_record_layout profile_table` 锚块）。返回的结构体与迁移前同形，
// 下游解码代码不受影响。
// ⚠ ids.zw / ranges.xy / ranges.zw 是**槽内局部**下标（迁移前是全局累计下标）：
//   coarse 恒从 0 起，fine 紧随 coarse，pivot 恒从 0 起。
RuntimeProfileTableRecord profile_arena_table_record(uint slot_index) {
    RuntimeProfileTableRecord record;
    record.ids = uvec4(
        profile_header_word(slot_index, 0u),
        profile_header_word(slot_index, 4u),
        profile_header_word(slot_index, 8u),
        profile_header_word(slot_index, 12u));
    record.ranges = uvec4(
        profile_header_word(slot_index, 16u),
        profile_header_word(slot_index, 20u),
        profile_header_word(slot_index, 24u),
        profile_header_word(slot_index, 28u));
    record.color_complexity = vec4(
        uintBitsToFloat(profile_header_word(slot_index, 32u)),
        uintBitsToFloat(profile_header_word(slot_index, 36u)),
        uintBitsToFloat(profile_header_word(slot_index, 40u)),
        uintBitsToFloat(profile_header_word(slot_index, 44u)));
    record.density_radius_hash_pad = vec4(
        uintBitsToFloat(profile_header_word(slot_index, 48u)),
        uintBitsToFloat(profile_header_word(slot_index, 52u)),
        uintBitsToFloat(profile_header_word(slot_index, 56u)),
        uintBitsToFloat(profile_header_word(slot_index, 60u)));
    return record;
}
// @@END profile_arena_layout table_accessor

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

// @@GEN profile_arena_layout sample_accessor
// SSOT: ProfileArenaLayout — 由 glsl_profile_sample_accessor_block() 发射，勿手改。
// 字段偏移取自 ProfileRecordSchema.RECORD_LAYOUTS["profile_sample"]（见本文件的
// `@@GEN profile_record_layout profile_sample` 锚块）。返回的结构体与迁移前同形，
// 下游解码代码不受影响。
ProfileSampleRecord profile_arena_sample(uint slot_index, uint sample_index) {
    ProfileSampleRecord record;
    record.offset_weight = vec4(
        uintBitsToFloat(profile_sample_word(slot_index, sample_index, 0u)),
        uintBitsToFloat(profile_sample_word(slot_index, sample_index, 4u)),
        uintBitsToFloat(profile_sample_word(slot_index, sample_index, 8u)),
        uintBitsToFloat(profile_sample_word(slot_index, sample_index, 12u)));
    record.payload = uvec4(
        profile_sample_word(slot_index, sample_index, 16u),
        profile_sample_word(slot_index, sample_index, 20u),
        profile_sample_word(slot_index, sample_index, 24u),
        profile_sample_word(slot_index, sample_index, 28u));
    return record;
}
// @@END profile_arena_layout sample_accessor


layout(set = 0, binding = 7, std430) restrict buffer VoxelStampDelta {
    vec4 stamp_delta[];
};

layout(set = 0, binding = 8, std430) restrict buffer VoxelStampDeltaCount {
    uint stamp_delta_count;
};

layout(set = 0, binding = 9, std430) restrict buffer VoxelStampBounds {
    uvec4 stamp_bounds[];
};

layout(set = 0, binding = 10, std430) restrict buffer CommitComplexityField {
    uint commit_complexity_rgba8[];
};

layout(set = 0, binding = 11, std430) restrict buffer CommitCollisionField {
    uint commit_collision_u32[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_rotation;  // grid xyz, w = rotation_slots (yaw sweep width, matches the scorer)
    ivec4 write_min_pad;       // write-window min xyz, w = profile_count
    ivec4 write_max_pad;       // write-window max xyz exclusive, w = stamp_delta_capacity
    vec4 params;               // solid_threshold, complexity_write_scale, collision_write_scale, dual_commit flag
    vec4 voxel_size_pad;       // voxel size xyz (world units, pivot world->voxel), w reserved
    // Host-passed element capacities for the capacity gates below (the host
    // packs each bound buffer's element count at its allocation point; GLSL
    // .length()/OpArrayLength is unsupported by Godot's SPIR-V path).
    ivec4 capacities;          // 全字段已随扁平 profile buffer 退役（Arena 的容量
                               // 守卫用编译期常量），保留只为不动 push 布局
};

const uint RECORD_STRIDE = 4u;
const uint DELTA_STRIDE = 2u;
const uint WORKGROUP_SIZE = 64u;

uint quantize_unorm8(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * 255.0));
}

uint pack_rgba8(vec4 value) {
    uvec4 q = uvec4(
        quantize_unorm8(value.r),
        quantize_unorm8(value.g),
        quantize_unorm8(value.b),
        quantize_unorm8(value.a)
    );
    return (q.r << 24u) | (q.g << 16u) | (q.b << 8u) | q.a;
}

bool in_write_bounds(ivec3 p) {
    return p.x >= write_min_pad.x && p.y >= write_min_pad.y && p.z >= write_min_pad.z
        && p.x < write_max_pad.x && p.y < write_max_pad.y && p.z < write_max_pad.z;
}

int voxel_index(ivec3 p) {
    return p.x + grid_size_rotation.x * (p.z + grid_size_rotation.z * p.y);
}

// Collision stores one quantized 0..255 value per uint32; unorm8 quantization
// preserves ordering, so a plain atomicMax is the monotonic merge.
void atomic_max_collision_r8(uint index, float value) {
    atomicMax(collision_field_u32[index], quantize_unorm8(value));
}

void atomic_max_commit_collision_r8(uint index, float value) {
    atomicMax(commit_collision_u32[index], quantize_unorm8(value));
}

// Complexity merges are monotonic max-by-alpha: overlapping samples and
// same-dispatch races must never downgrade a committed voxel. pack_rgba8 keeps
// alpha in the low byte, so a plain atomicMax would order by red — CAS the
// whole word. Same tie rule as ad_compose_rgba: current >= new keeps current.
void atomic_max_complexity_rgba8(uint index, uint packed_value) {
    uint q = packed_value & 0xFFu;
    uint old_word = complexity_field_rgba8[index];
    for (int attempt = 0; attempt < 32; attempt++) {
        if ((old_word & 0xFFu) >= q) {
            return;
        }
        uint previous = atomicCompSwap(complexity_field_rgba8[index], old_word, packed_value);
        if (previous == old_word) {
            return;
        }
        old_word = previous;
    }
}

void atomic_max_commit_complexity_rgba8(uint index, uint packed_value) {
    uint q = packed_value & 0xFFu;
    uint old_word = commit_complexity_rgba8[index];
    for (int attempt = 0; attempt < 32; attempt++) {
        if ((old_word & 0xFFu) >= q) {
            return;
        }
        uint previous = atomicCompSwap(commit_complexity_rgba8[index], old_word, packed_value);
        if (previous == old_word) {
            return;
        }
        old_word = previous;
    }
}

void write_stamp_bounds(uint result_index, ivec3 p) {
    uint base = result_index * 2u;
    atomicMin(stamp_bounds[base + 0u].x, uint(p.x));
    atomicMin(stamp_bounds[base + 0u].y, uint(p.y));
    atomicMin(stamp_bounds[base + 0u].z, uint(p.z));
    atomicAdd(stamp_bounds[base + 0u].w, 1u);
    atomicMax(stamp_bounds[base + 1u].x, uint(p.x + 1));
    atomicMax(stamp_bounds[base + 1u].y, uint(p.y + 1));
    atomicMax(stamp_bounds[base + 1u].z, uint(p.z + 1));
}

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

// @@GEN ad_voxel_compose — generated from scripts/utils/placement_shared_glsl.gd, do not edit
// Stamp-equivalent AD voxel write values + monotonic-max compose.
// Ties keep the current value, matching the stamp CAS loops which return
// without writing when current >= new (both complexity-alpha and collision).
float ad_complexity_write_value(float ad_complexity, float complexity_write_scale) {
    return clamp(ad_complexity * complexity_write_scale, 0.0, 1.0);
}

float ad_collision_write_value(float ad_collision, float solid_threshold, float collision_write_scale) {
    return ad_collision >= solid_threshold ? clamp(ad_collision * collision_write_scale, 0.0, 1.0) : 0.0;
}

// Complexity/color merge is max-by-alpha over the WHOLE rgba value: the higher
// complexity wins and brings its color along; equal alpha keeps the current rgba.
vec4 ad_compose_rgba(vec4 current_rgba, vec3 ad_rgb, float ad_complexity_value) {
    return ad_complexity_value > current_rgba.a ? vec4(ad_rgb, ad_complexity_value) : current_rgba;
}

float ad_compose_collision(float current_collision, float ad_collision_value) {
    return max(current_collision, ad_collision_value);
}
// @@END ad_voxel_compose

void main() {
    uint record_index = gl_WorkGroupID.x;
    if (record_index >= result_count) {
        return;
    }
    uint base = record_index * RECORD_STRIDE;
    // Valid-flag gate: empty slots carry valid == 0 in record[3].y.
    if (placement_results[base + 3u].y < 0.5) {
        return;
    }

    int profile_index = int(round(placement_results[base + 3u].x));
    // Arena 定长：slot 上界是编译期常量 PROFILE_CAPACITY，不再需要 host 传
    // 扁平 profile 表的元素数（capacities.x 已随该 buffer 一起退役）。
    if (profile_index < 0 || profile_index >= max(write_min_pad.w, 0)
            || uint(profile_index) >= PROFILE_CAPACITY) {
        return;
    }
    RuntimeProfileTableRecord profile = profile_arena_table_record(uint(profile_index));
    uint sample_start = profile.ranges.x;
    uint sample_count = profile.ranges.y;
    // Capacity gate: refuse a corrupt profile range instead of reading past this
    // slot's sample region. range 已是槽内局部下标，容量是每槽固定的编译期常量。
    uint sample_capacity = MAX_SAMPLES_PER_PROFILE;
    if (sample_start > sample_capacity || sample_count > sample_capacity - sample_start) {
        return;
    }

    vec4 origin_score = placement_results[base + 0u];
    vec4 record_ids = placement_results[base + 1u];
    ivec3 origin = ivec3(round(origin_score.xyz));

    int rot_slot = int(round(record_ids.z));
    int rot_count = max(grid_size_rotation.w, 1);
    float rot_angle = rot_count > 1 ? float(rot_slot) * 6.28318530718 / float(rot_count) : 0.0;
    float rot_ca = cos(rot_angle);
    float rot_sa = sin(rot_angle);

    // record[1].w = **槽内局部** pivot 下标（-1 = 零 pivot）；所属 slot 就是上面的
    // profile_index。Arena 化后不再有跨 profile 的全局累计 pivot 下标。
    int local_pivot_index = int(round(record_ids.w));
    vec3 pivot_world = vec3(0.0);
    if (local_pivot_index >= 0) {
        if (uint(local_pivot_index) >= MAX_PIVOTS_PER_PROFILE) {
            return; // out-of-range pivot record — refuse the whole placement
        }
        pivot_world = profile_arena_pivot(
            uint(profile_index), uint(local_pivot_index)).offset_bias.xyz;
    }

    for (uint sample_index = gl_LocalInvocationID.x; sample_index < sample_count; sample_index += WORKGROUP_SIZE) {
        ProfileSample decoded_sample = decode_profile_sample(
            profile_arena_sample(uint(profile_index), sample_start + sample_index));
        bool can_stamp = (decoded_sample.flags & PROFILE_SAMPLE_FLAG_STAMP_WRITE) != 0u
            && (decoded_sample.flags & (PROFILE_SAMPLE_FLAG_SCORE_ONLY | PROFILE_SAMPLE_FLAG_CLEARANCE)) == 0u;
        if (!can_stamp) continue;
        ivec3 p = resolve_profile_sample_voxel(
            decoded_sample, origin, pivot_world, rot_ca, rot_sa, voxel_size_pad.xyz);
        if (!profile_sample_in_bounds(p, grid_size_rotation.xyz) || !in_write_bounds(p)) {
            continue;
        }

        vec4 ad_rgba = decoded_sample.color;
        float ad_col_raw = decoded_sample.collision;
        float complexity = ad_complexity_write_value(ad_rgba.a, params.y);
        float collision_strength = ad_collision_write_value(ad_col_raw, params.x, params.z);
        if (complexity <= 0.0 && collision_strength <= 0.0) {
            continue;
        }

        int index = voxel_index(p);
        uint packed_complexity = pack_rgba8(vec4(ad_rgba.rgb, complexity));
        if (complexity > 0.0) {
            atomic_max_complexity_rgba8(uint(index), packed_complexity);
        }
        if (collision_strength > 0.0) {
            atomic_max_collision_r8(uint(index), collision_strength);
        }
        if (params.w > 0.5) {
            if (complexity > 0.0) {
                atomic_max_commit_complexity_rgba8(uint(index), packed_complexity);
            }
            if (collision_strength > 0.0) {
                atomic_max_commit_collision_r8(uint(index), collision_strength);
            }
        }

        if (write_max_pad.w > 0) {
            uint compact_index = atomicAdd(stamp_delta_count, 1u);
            if (compact_index < uint(write_max_pad.w)) {
                uint delta_base = compact_index * DELTA_STRIDE;
                stamp_delta[delta_base + 0u] = vec4(vec3(p), complexity);
                stamp_delta[delta_base + 1u] = vec4(collision_strength, float(record_index), float(sample_index), 1.0);
            }
        }
        write_stamp_bounds(record_index, p);
    }
}
