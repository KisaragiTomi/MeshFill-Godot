#[compute]
#version 450

// Pass A — Score anchor × asset probe groups.
//
// Workgroup layout (16, 16, 1):
//   local_x = asset_lane  (0..15), covers 16 assets per block
//   local_y = probe_lane  (0..15), each asset's probes stride by 16
//
// Dispatch: (anchor_grid_x, anchor_grid_y, ceil(asset_count / 16))
//   WorkGroupID.xy → anchor_id
//   WorkGroupID.z  → asset_block
//
// Output: asset_scores[anchor_id * asset_stride + asset_id]

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

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

// --- Buffers ---

layout(set = 0, binding = 0, std430) restrict readonly buffer AnchorBuf {
    uvec4 anchors[];    // (x, y, z, .w = floatBitsToUint(离地表垂直距离))；本 pass 只用 .xyz
};

// Per-asset probe range: asset_probe_range[asset_id] = (start, count)
layout(set = 0, binding = 1, std430) restrict readonly buffer ProbeRange {
    uvec2 asset_probe_range[];
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
// 迁移前这里是扁平的 profile_sample_records，asset_probe_range 存的是**全局累计**起点；
// Arena 化后 range.x 改存 slot_index（= profile_index），coarse 段恒从槽内 0 起算。
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


layout(set = 0, binding = 3, std430) restrict readonly buffer SceneComplexity {
    uint scene_complexity_rgba8[]; // packed RGBA8; complexity is alpha in the low byte
};

layout(set = 0, binding = 4, std430) restrict readonly buffer SceneCollision {
    uint scene_collision_u32[]; // quantized 0..255 in the low byte
};

layout(set = 0, binding = 5, std430) restrict readonly buffer TargetField {
    uint target_field_rgba8[];  // packed r<<24|g<<16|b<<8|a；alpha 字节 = completeness = max(complexity, collision)，表示体素完全度
};

layout(set = 0, binding = 6, std430) restrict readonly buffer TargetCollision {
    uint target_collision_u32[];  // one uint per voxel, quantized 0..255 in the low byte
};

layout(set = 0, binding = 7, std430) restrict writeonly buffer ScoresOut {
    float asset_scores[];
};

// GPU-resident anchor count (written by collect_sv_anchors, no CPU readback).
// Replaces the former push-constant anchor_count so dispatch can be indirect.
layout(set = 0, binding = 8, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_asset_count;  // xyz = grid dims, w = asset_count
    vec4  voxel_size_inv;         // xyz = 1.0 / voxel_size, w = runtime asset_scores stride
    // Host-passed element capacities for the capacity gates below (the host
    // packs each bound buffer's element count at its allocation point; GLSL
    // .length()/OpArrayLength is unsupported by Godot's SPIR-V path). The
    // anchor COUNT is still read from AnchorCountBuf; this is the anchors
    // buffer CAPACITY. Pass A writes raw signed probe sums unthresholded;
    // min_prefilter_score gates only in Pass B (select_anchor_topk).
    uint  anchor_buf_capacity;      // anchors[] element capacity
    uint  anchor_grid_x;
    uint  probe_range_capacity;     // asset_probe_range[] element capacity
    uint  profile_sample_record_capacity; // 未使用：容量守卫已改用编译期常量
                                          // MAX_SAMPLES_PER_PROFILE；字段保留只为不动
                                          // push 布局的冻结字节位置
};

// --- Constants ---

const uint ASSET_LANES      = 16u;
const uint PROBE_LANES      = 16u;

// --- Shared memory ---

shared float shared_score[16][16];
// 归一化分母（与 shared_score 逐项配对）：粗筛分必须除以它才与细筛同口径，见 main() 末尾。
shared float shared_weight[16][16];

// --- Helpers ---

int voxel_index(ivec3 p) {
    return p.x + grid_size_asset_count.x * (p.z + grid_size_asset_count.z * p.y);
}


// --- Main ---

void main() {
    uint anchor_id   = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x;
    uint asset_block = gl_WorkGroupID.z;
    uint asset_lane  = gl_LocalInvocationID.x;  // 0..15
    uint probe_lane  = gl_LocalInvocationID.y;  // 0..15
    uint asset_stride = max(uint(voxel_size_inv.w), 1u);
    uint asset_count = min(uint(grid_size_asset_count.w), asset_stride);
    uint asset_id    = asset_block * ASSET_LANES + asset_lane;
    // collect_sv_anchors bumps the count with an unbounded atomicAdd and only
    // caps the writes, so the dynamic count can exceed the anchor buffer
    // capacity — clamp to the host-passed buffer capacity before indexing.
    uint anchor_count = min(anchor_count_dyn[0], anchor_buf_capacity);

    float lane_score  = 0.0;
    float lane_weight = 0.0;

    if (anchor_id < anchor_count && asset_id < asset_count
            && asset_id < probe_range_capacity) {
        uvec4 anchor = anchors[anchor_id];
        ivec3 anchor_pos = ivec3(anchor.xyz);

        // asset_probe_range[asset_id] = (slot_index, coarse_count)。coarse 段在每个
        // Arena slot 内恒从局部下标 0 起算，所以不再需要一个"起点"字段。
        uvec2 range = asset_probe_range[asset_id];
        uint slot_index = range.x;
        uint probe_count = range.y;
        // Capacity gate: a corrupt range contributes nothing instead of reading past
        // this slot's sample region. Arena 定长 ⇒ 上界是编译期常量，不用 host 传。
        if (slot_index >= PROFILE_CAPACITY || probe_count > MAX_SAMPLES_PER_PROFILE) {
            probe_count = 0u;
        }

        for (uint i = probe_lane; i < probe_count; i += PROBE_LANES) {
            ProfileSample decoded_sample = decode_profile_sample(
                profile_arena_sample(slot_index, i));
            if ((decoded_sample.flags & PROFILE_SAMPLE_FLAG_COARSE) == 0u || decoded_sample.sample_weight <= 0.0) continue;
            vec3 voxel_size = 1.0 / max(voxel_size_inv.xyz, vec3(1.0e-6));
            ivec3 p = resolve_profile_sample_voxel(
                decoded_sample, anchor_pos, vec3(0.0), 1.0, 0.0, voxel_size);
            if (!profile_sample_in_bounds(p, grid_size_asset_count.xyz)) continue;
            uint idx = uint(voxel_index(p));
            vec4 current_rgba = unpack_profile_sample_rgba8(scene_complexity_rgba8[idx]);
            float current_collision = float(scene_collision_u32[idx] & 0xFFu) * (1.0 / 255.0);
            // Phase 2：目标场与 profile sample 用同一个 @@GEN 共享 unpack（`* (1.0/255.0)`）。
            vec4 target_rgba = unpack_profile_sample_rgba8(target_field_rgba8[idx]);
            float target_collision = float(target_collision_u32[idx] & 0xFFu) * (1.0 / 255.0);
            ProfileSampleFields fields = load_profile_sample_fields(
                current_rgba, current_collision, target_rgba, target_collision,
                current_rgba, current_collision);
            ProfileSampleEvaluation evaluation = evaluate_profile_sample(
                decoded_sample, fields, PROFILE_SAMPLE_POLICY_COARSE_MATCH);
            lane_score += evaluation.contribution;
            // 归一化分母：contribution = sample_weight * dot(semantic_weights, fits)，
            // 三个 fit 各约 [-1,1] ⇒ 除以 sample_weight * Σ|semantic_weights| 后落回 ~[-1,1]。
            // 与细筛 `dw = sample_dim_weight_total * weight` 是同一形状（那边多乘一层
            // dim_w_*，是维度权重；粗筛没有那一层）。
            lane_weight += decoded_sample.sample_weight * (
                abs(decoded_sample.semantic_weights.x)
                + abs(decoded_sample.semantic_weights.y)
                + abs(decoded_sample.semantic_weights.z));
        }
    }

    // Write per-lane results to shared memory
    shared_score[asset_lane][probe_lane]  = lane_score;
    shared_weight[asset_lane][probe_lane] = lane_weight;
    barrier();

    // Reduce across probe lanes (probe_lane == 0 accumulates)
    if (probe_lane == 0u && anchor_id < anchor_count && asset_id < asset_count) {
        float sum_score  = 0.0;
        float sum_weight = 0.0;
        for (uint py = 0u; py < PROBE_LANES; py++) {
            sum_score  += shared_score[asset_lane][py];
            sum_weight += shared_weight[asset_lane][py];
        }
        // ⚠ 写出的是**加权平均 fit**（~[-1,1]），不是裸和。
        //
        // 曾经写裸和：`min_prefilter_score` 于是在拿一个绝对阈值去比一个随「样本数 ×
        // sample_weight 量级」自由缩放的量 —— 探针多/权重大的资产恒过门，与它在这个
        // 锚点上是否真的匹配无关。实测 geo_cliff_02 在 45598/45598 个锚点全部过门、
        // geo_cliff_01 在多个不同锚点上恒为同一个 31.2，而两者细筛 valid 恒为 0。
        // 门形同虚设，还占着 top-K 槽位把真正可能有效的候选挤掉。
        //
        // 细筛早就是归一化的（score_anchor_asset_residual 的
        // `mean_gain = gain_sum / weight_sum`，注释标注 ~[-1,1]）。这里补上同一步，
        // 两级的分数从此在同一量纲上，`min_prefilter_score` 才是一个可解释的门。
        // 无有效样本（权重和为 0）时写 0.0：中性，不是"匹配"也不是"排斥"。
        asset_scores[anchor_id * asset_stride + asset_id] =
            sum_weight > 0.0 ? sum_score / sum_weight : 0.0;
    }
}
