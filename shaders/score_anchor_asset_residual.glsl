#[compute]
#version 450

// Anchor-origin residual-gain fine scorer (replaces the tile-based
// score_voxel_tile.glsl).
//
// One workgroup = one (anchor, topk-slot) candidate pair from the probe
// prefilter handoff:
//   anchor_id = gl_WorkGroupID.y * ANCHOR_GRID_X + gl_WorkGroupID.x
//   k         = gl_WorkGroupID.z            (per-anchor asset slot)
// Dispatched indirectly from fine_score_dispatch_finalize.glsl, so
// origin_count == anchor_count with no CPU readback of the count.
//
// Threads own (pivot, yaw) combos; AD voxel records stream through shared
// memory in fixed-size batches (any record count works — no per-asset cap),
// and every batch accumulates into the same per-combo registers.
//
// Candidate score = signed per-voxel match score against TargetSV.
// Each semantic AD voxel is composed with the stamp rule verbatim
// (@@GEN ad_voxel_compose, so the prediction equals what
// stamp_asset_voxels.glsl later writes) and judged by a CONJUNCTIVE test —
// exceeding ANY per-dimension budget disqualifies the voxel:
//   occupied      : max(tgt.a, tgt_col) > TARGET_OCCUPIED_MIN  (target wants content)
//   color_ok      : L1(pred.rgb, tgt.rgb)  <= match_limits.x   (0..3)
//   collision_ok  : |pred_col - tgt_col|   <= match_limits.y   (0..1)
//   complexity_ok : pred.a <= tgt.a * match_limits.z  (match_limits.z = 1 + N/100, overfill-only)
//   improved      : five-dim residual gain (loss_before - loss_after) > eps
//                   (already-satisfied voxels never re-count -> multi-round safe)
// The budgets come from res://score_match_config.cfg via the host (see
// voxel_placement_generator.gd _load_score_match_config).
// score = (pass_weight - off_target_collision_penalty_weight) / total_weight
// (+ a small mean-residual-gain tiebreak so equal-score yaw/pivot combos stay
// ordered). A matching occupied-target voxel contributes +weight; a voxel that
// lands on empty target contributes -ad_col_val*weight, so off-target content is
// penalised in proportion to the collision value the stamp would actually write.
// Collision-free overshoot contributes zero. The five-dim residual gain is still
// accumulated only over occupied-target voxels for the tiebreak and loss stats.
// Clearance ProfileSamples
// never enter the semantic compose; they only feed the physical clearance
// accumulator. "Place nothing" stays the implicit baseline: a candidate is valid
// only when match_fraction > min_match_fraction (voxel_size_threshold.w), where
// match_fraction is the signed, full-footprint score above.
// Targetless runs (has_target == 0) fall back to the legacy mean residual-gain
// score.
//
// Output: one 4-vec4 (64 B) record per (anchor, k) at
// fine_candidates[anchor_id * topk + k]:
//   [0] origin.xyz (anchor voxel position), score (match fraction + tiebreak)
//   [1] anchor_id, asset_index, yaw_slot, local_pivot_index (-1 = zero pivot；槽内局部)
//   [2] solid_collision, loss_before_mean, loss_after_mean, clearance_overlap
//   [3] profile_index, valid (0/1), coarse probe score, match_fraction
//       profile_index 同时是 Arena slot 索引，消费方靠它 + [1].w 定位 pivot。

layout(local_size_x = 16, local_size_y = 1, local_size_z = 1) in;

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

// Scorer-private fused read pairs (pack_fine_sample_pairs.glsl pre-pass):
// one uvec2 read per side replaces the former four scatter reads (complexity
// rgba8-u32 / collision u32 / target vec4 / target collision u32). cur words
// are verbatim copies of the original pair; the target rgba8 word is the
// quantized target_field vec4 (r<<24|g<<16|b<<8|a, a = complexity).
layout(set = 0, binding = 0, std430) restrict readonly buffer CurSamplePair {
    uvec2 cur_sample[];  // x = rgba8 word, y = collision word (low byte unorm8)
};

layout(set = 0, binding = 1, std430) restrict readonly buffer TgtSamplePair {
    uvec2 tgt_sample[];  // x = rgba8 word, y = collision word (low byte unorm8)
};

layout(set = 0, binding = 4, std430) restrict readonly buffer AnchorRecords {
    uvec4 anchors[];
};

layout(set = 0, binding = 5, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(set = 0, binding = 6, std430) restrict readonly buffer AnchorTopK {
    uvec2 anchor_topk[];
};

// @@GEN debug_set voxel_debug_channels decl
layout(set = 0, binding = 7, std430) restrict buffer DebugVoxelOutput {
    float debug_voxel[];  // 8 channels/element, index space: voxel_dense_xzy
};
// @@END debug_set voxel_debug_channels decl

layout(set = 0, binding = 8, std430) restrict buffer FineCandidates {
    vec4 fine_candidates[];
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
// 迁移前这里是三个独立 buffer（profile_table @6 / pivot_records @11 /
// profile_sample_records @13），各带一份 host 传入的元素容量；Arena 定长，容量守卫
// 全部收敛成下面发射的编译期常量。
layout(set = 1, binding = 6, std430) restrict readonly buffer ProfileArena {
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

// @@GEN debug_set score_contract_stats decl
layout(set = 1, binding = 8, std430) restrict buffer ScoreRuntimeProfileDebug {
    uint score_contract_debug[];
};
// @@END debug_set score_contract_stats decl

// asset_index -> (profile_id, profile_index, quota, object_type). Shared with
// the reduce pass (quota) and the runtime writeback (object_type).
layout(set = 1, binding = 14, std430) restrict readonly buffer AssetLookup {
    ivec4 asset_lookup[];
};

// Per-asset fine-score param overrides (voxel_placement_generator _build_asset_lookup).
// 8 floats/asset: [0]min_match_fraction [1]dim_w_collision [2]dim_w_complexity
// [3]dim_w_color [4]color_max_l1 [5]collision_max [6]complexity_overfill_percent [7]pad.
// Each value -1 = inherit the global push-constant default. Indexed by asset_id.
layout(set = 1, binding = 15, std430) restrict readonly buffer AssetScoreParams {
    float asset_score_params[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_has_target;   // grid xyz, w = has_target (0/1)
    vec4 voxel_size_threshold;    // voxel size xyz (world units), w = min_match_fraction
    ivec4 counts;                 // rotation_slots, topk, asset_count, anchor_capacity
    vec4 limits;                  // solid_threshold, collision_limit, clearance_limit, complexity_write_scale
    vec4 scales_weights;          // collision_write_scale, dim_w_collision, dim_w_complexity, dim_w_color (per channel)
    ivec4 meta;                   // contract_enabled, profile_count, debug_write_mask, reserved
    // Host-passed element capacities for the capacity gates below (the host
    // packs each bound buffer's element count at its allocation point; GLSL
    // .length()/OpArrayLength is unsupported by Godot's SPIR-V path).
    ivec4 capacities;             // x=asset_lookup；yzw 已随扁平 profile buffer 退役（Arena
                                  // 的容量守卫用编译期常量），字段保留只为不动 push 布局
    // Per-dimension match budgets (score_match_config.cfg): x = color max L1
    // (0..3), y = collision max |diff| (0..1), z = complexity max |diff| (0..1),
    // w = reserved.
    vec4 match_limits;
};

const uint ANCHOR_GRID_X = 256u;   // must match prefilter/finalize dispatch width
const uint EMPTY_ASSET_ID = 0xFFFFFFFFu;
const uint RECORD_STRIDE = 4u;
const uint AD_BATCH_CAPACITY = 128u;
const uint WORKGROUP_SIZE = 16u;
const float INVALID_SCORE = -1.0e18;
// Occupied floor sits above bake-smear noise (was 0.01): faint target residue
// no longer counts as "target wants content" for the match test.
const float TARGET_OCCUPIED_MIN = 0.05;
// A voxel only counts as matched when the compose strictly improves it.
const float MATCH_GAIN_EPS = 1.0e-5;
// Complexity match is ASYMMETRIC and overfill-only: a candidate fails the complexity
// dimension only when its post-compose (stamp+SV) complexity OVERFILLS the target by
// more than N% — pred.a > tgt.a * (1 + N/100). Underfill / exact / ≤N%-over all pass;
// a thin asset on a denser target is fine, only a denser-than-wanted asset is rejected.
// The ratio (1 + N/100) arrives as match_limits.z, tuned via score_match_config.cfg
// `complexity_overfill_percent` (default 20 → ratio 1.2). No absolute slack term.
// Mean residual gain (~[-1,1]) contributes at most +-this much on top of the
// signed match score — orders equal-score combos without overpowering a
// material score difference.
const float TIEBREAK_GAIN_SCALE = 0.05;
// @@GEN debug_set voxel_debug_channels consts
const uint NUM_DEBUG_CHANNELS = 8u;
const uint DEBUG_CH_TARGET_COVERAGE = 0u;
const uint DEBUG_CH_TARGET_COMPLEXITY_FIT = 1u;
const uint DEBUG_CH_TARGET_COLOR_FIT = 2u;
const uint DEBUG_CH_TARGET_DENSITY = 3u;
const uint DEBUG_CH_PLACEMENT_SCORE = 4u;
const uint DEBUG_CH_BEST_ROTATION_SLOT = 5u;
const uint DEBUG_CH_SOLID_COLLISION = 6u;
const uint DEBUG_CH_CLEARANCE_OVERLAP = 7u;
// @@END debug_set voxel_debug_channels consts
// @@GEN debug_set score_contract_stats consts
const uint SCORE_CONTRACT_MAGIC = 0x4D465052u;
const uint SCORE_DEBUG_MAGIC = 0u;
const uint SCORE_DEBUG_ENABLED = 1u;
const uint SCORE_DEBUG_RUNTIME_OBJECT_CAPACITY = 2u;
const uint SCORE_DEBUG_PROFILE_COUNT = 3u;
const uint SCORE_DEBUG_PROFILE_RECORDS_MATCHED = 5u;
const uint SCORE_DEBUG_RUNTIME_OVERLAP_TESTS = 6u;
const uint SCORE_DEBUG_RUNTIME_OVERLAP_HITS = 7u;
const uint SCORE_DEBUG_PROFILE_TABLE_READS = 8u;
const uint SCORE_DEBUG_ASSET_PROFILE_ID = 9u;
const uint SCORE_DEBUG_CANDIDATE_INVOCATIONS = 10u;
const uint SCORE_DEBUG_PROFILE_COMPLEXITY_Q1000 = 11u;
const uint SCORE_DEBUG_RUNTIME_PROFILE_READS = 12u;
const uint SCORE_DEBUG_RUNTIME_PROFILE_MATCHES = 13u;
const uint SCORE_DEBUG_PIVOT_RECORD_READS = 16u;
const uint SCORE_DEBUG_PIVOT_BIAS_Q1000 = 19u;
const uint SCORE_DEBUG_PROFILE_PROBE_COUNT = 20u;
const uint SCORE_DEBUG_PROFILE_PIVOT_COUNT = 22u;
const uint SCORE_DEBUG_DEBUG_MAX_BASE = 23u;
const uint SCORE_DEBUG_RUNTIME_SPACING_TESTS = 31u;
const uint SCORE_DEBUG_RUNTIME_SPACING_PROFILE_MATCHES = 32u;
const uint SCORE_DEBUG_RUNTIME_SPACING_REJECTIONS = 33u;
const uint SCORE_DEBUG_RUNTIME_SPACING_MIN_DISTANCE_Q1000 = 34u;
const uint SCORE_DEBUG_OBJECT_REF_ENABLED = 35u;
const uint SCORE_DEBUG_OBJECT_REF_TILE_READS = 36u;
const uint SCORE_DEBUG_OBJECT_REF_SLOT_READS = 37u;
const uint SCORE_DEBUG_OBJECT_REF_OBJECT_READS = 38u;
const uint SCORE_DEBUG_OBJECT_REF_DUPLICATE_READS = 39u;
// @@END debug_set score_contract_stats consts

shared vec4 s_sample_offset_weight[AD_BATCH_CAPACITY];
shared uvec4 s_sample_payload[AD_BATCH_CAPACITY];
// Per-thread combo results for the workgroup argmax.
shared float s_combo_score[WORKGROUP_SIZE];
shared float s_combo_valid[WORKGROUP_SIZE];
shared vec4 s_combo_stats0[WORKGROUP_SIZE];   // solid_collision, loss_before_mean, loss_after_mean, clearance
shared float s_combo_coverage[WORKGROUP_SIZE];
shared float s_combo_fraction[WORKGROUP_SIZE];

// Candidate accumulators — one per thread (= one per (pivot, yaw) combo in the
// current chunk); ALL AD batches of the asset accumulate into the same struct.
struct FineAccum {
    float gain_sum;
    float weight_sum;
    float loss_before_sum;
    float loss_after_sum;
    float solid_collision;
    float clearance_overlap;
    float coverage_weight;
    float total_weight;
    // Weight of voxels passing the strict conjunctive match test
    // (occupied && color_ok && improved) — the score numerator.
    float pass_weight;
    // Empty-target penalty numerator. Uses the collision value after the same
    // threshold/scale transform as stamping, so non-collision voxels cost zero.
    float off_target_collision_penalty_weight;
};

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

int voxel_index(ivec3 p) {
    return p.x + grid_size_has_target.x * (p.z + grid_size_has_target.z * p.y);
}

float load_r8(uint value) {
    // caller passes the per-voxel collision word (pair .y); shared by both sides
    return float(value & 0xFFu) * (1.0 / 255.0);
}

void write_record(uint slot, ivec3 origin, float score, uint anchor_id, uint asset_id,
        int yaw_slot, int global_pivot_index, vec4 stats0, int profile_index,
        bool valid, float coarse_score, float match_fraction) {
    uint base = slot * RECORD_STRIDE;
    fine_candidates[base + 0u] = vec4(vec3(origin), score);
    fine_candidates[base + 1u] = vec4(float(anchor_id), float(asset_id), float(yaw_slot), float(global_pivot_index));
    fine_candidates[base + 2u] = stats0;
    fine_candidates[base + 3u] = vec4(float(profile_index), valid ? 1.0 : 0.0, coarse_score, match_fraction);
}

void write_invalid_record(uint slot, ivec3 origin, uint anchor_id, uint asset_id) {
    write_record(slot, origin, INVALID_SCORE, anchor_id, asset_id, 0, -1, vec4(0.0), -1, false, -1.0, 0.0);
}

void write_debug_voxel_channels(ivec3 origin, float coverage, float loss_before,
        float loss_after, float gain, float best_slot, float solid_collision, float clearance) {
    if ((uint(meta.z) & 1u) == 0u) {
        return;
    }
    if (!profile_sample_in_bounds(origin, grid_size_has_target.xyz)) {
        return;
    }
    uint base = uint(voxel_index(origin)) * NUM_DEBUG_CHANNELS;
    debug_voxel[base + DEBUG_CH_TARGET_COVERAGE] = coverage;
    debug_voxel[base + DEBUG_CH_TARGET_COMPLEXITY_FIT] = loss_before;
    debug_voxel[base + DEBUG_CH_TARGET_COLOR_FIT] = loss_after;
    debug_voxel[base + DEBUG_CH_TARGET_DENSITY] = 0.0;
    debug_voxel[base + DEBUG_CH_PLACEMENT_SCORE] = gain;
    debug_voxel[base + DEBUG_CH_BEST_ROTATION_SLOT] = best_slot;
    debug_voxel[base + DEBUG_CH_SOLID_COLLISION] = solid_collision;
    debug_voxel[base + DEBUG_CH_CLEARANCE_OVERLAP] = clearance;
}

void main() {
    uint anchor_id = gl_WorkGroupID.y * ANCHOR_GRID_X + gl_WorkGroupID.x;
    uint k = gl_WorkGroupID.z;
    uint tid = gl_LocalInvocationID.x;
    uint topk = uint(max(counts.y, 1));
    uint anchor_count = min(anchor_count_dyn[0], uint(max(counts.w, 0)));
    if (anchor_id >= anchor_count || k >= topk) {
        return;
    }
    uint slot = anchor_id * topk + k;
    ivec3 origin = ivec3(anchors[anchor_id].xyz);

    // Workgroup-uniform debug header write; occurs before any shared-memory
    // barrier. Every anchor is rescored each pass (always-dirty semantics).
    if (tid == 0u && anchor_id == 0u && k == 0u) {
        score_contract_debug[SCORE_DEBUG_ENABLED] = uint(max(meta.x, 0));
        score_contract_debug[SCORE_DEBUG_PROFILE_COUNT] = uint(max(meta.y, 0));
    }

    uvec2 topk_entry = anchor_topk[slot];
    uint asset_id = topk_entry.x;
    float coarse_score = uintBitsToFloat(topk_entry.y);
    if (asset_id == EMPTY_ASSET_ID || asset_id >= uint(max(counts.z, 0))
            || asset_id >= uint(max(capacities.x, 0))) {
        if (tid == 0u) {
            write_invalid_record(slot, origin, anchor_id, asset_id);
        }
        return;
    }

    ivec4 lookup = asset_lookup[asset_id];
    int profile_index = lookup.y;
    // Arena 是定长的：slot 上界是编译期常量 PROFILE_CAPACITY，不再需要 host 传
    // 扁平 profile 表的元素数（capacities.y 已随该 buffer 一起退役）。
    if (profile_index < 0 || profile_index >= max(meta.y, 0)
            || uint(profile_index) >= PROFILE_CAPACITY) {
        if (tid == 0u) {
            write_invalid_record(slot, origin, anchor_id, asset_id);
        }
        return;
    }

    RuntimeProfileTableRecord profile = profile_arena_table_record(uint(profile_index));
    uint sample_start = profile.ranges.x;
    uint sample_count = profile.ranges.y;
    uint pivot_start = profile.ranges.z;
    uint pivot_count = profile.ranges.w;
    if (sample_count == 0u) {
        if (tid == 0u) {
            write_invalid_record(slot, origin, anchor_id, asset_id);
        }
        return;
    }
    // Capacity gates: refuse corrupt profile ranges instead of reading past this
    // slot's sample/pivot regions. Arena 化后容量是**每槽固定**的编译期常量，不再
    // 是 host 传入的整表元素数（capacities.zw 已随旧 buffer 一起退役）；range 也
    // 已是槽内局部下标，所以这里比的是"本槽装不装得下"。
    // Workgroup-uniform, so the early return stays barrier-safe.
    uint sample_capacity = MAX_SAMPLES_PER_PROFILE;
    uint pivot_capacity = MAX_PIVOTS_PER_PROFILE;
    if (sample_start > sample_capacity || sample_count > sample_capacity - sample_start
            || (pivot_count > 0u
                && (pivot_start > pivot_capacity || pivot_count > pivot_capacity - pivot_start))) {
        if (tid == 0u) {
            write_invalid_record(slot, origin, anchor_id, asset_id);
        }
        return;
    }

    // Contract observability (always-on): one bump per candidate workgroup.
    if (tid == 0u) {
        atomicAdd(score_contract_debug[SCORE_DEBUG_PROFILE_TABLE_READS], 1u);
        if (pivot_count > 0u) {
            atomicAdd(score_contract_debug[SCORE_DEBUG_PIVOT_RECORD_READS], 1u);
        }
        if (anchor_id == 0u && k == 0u) {
            score_contract_debug[SCORE_DEBUG_ENABLED] = uint(max(meta.x, 0));
            score_contract_debug[SCORE_DEBUG_PROFILE_COUNT] = uint(max(meta.y, 0));
            score_contract_debug[SCORE_DEBUG_ASSET_PROFILE_ID] = uint(max(lookup.x, 0));
            atomicMax(score_contract_debug[SCORE_DEBUG_PROFILE_PIVOT_COUNT], pivot_count);
        }
    }

    float rot_count = float(max(counts.x, 1));
    uint yaw_slots = uint(max(counts.x, 1));
    // pivot_count == 0 -> single implicit zero pivot (global_pivot_index = -1).
    uint pivot_slots = max(pivot_count, 1u);
    uint combo_count = pivot_slots * yaw_slots;
    if (tid == 0u) {
        atomicAdd(score_contract_debug[SCORE_DEBUG_CANDIDATE_INVOCATIONS], combo_count);
    }

    vec3 voxel_size = max(voxel_size_threshold.xyz, vec3(1.0e-6));
    float solid_threshold = limits.x;
    float complexity_write_scale = limits.w;
    float collision_write_scale = scales_weights.x;
    // Per-asset score-param overrides (asset_score_params[asset_id*8 + k]; -1 = inherit
    // the global push default). asset_id is validated above; buffer is sized asset_count.
    uint sp_base = asset_id * 8u;
    float sp_min_match = asset_score_params[sp_base + 0u];
    float sp_dw_coll   = asset_score_params[sp_base + 1u];
    float sp_dw_cplx   = asset_score_params[sp_base + 2u];
    float sp_dw_color  = asset_score_params[sp_base + 3u];
    float sp_color_max = asset_score_params[sp_base + 4u];
    float sp_coll_max  = asset_score_params[sp_base + 5u];
    float sp_cplx_pct  = asset_score_params[sp_base + 6u];
    float dim_w_collision  = sp_dw_coll  >= 0.0 ? sp_dw_coll  : scales_weights.y;
    float dim_w_complexity = sp_dw_cplx  >= 0.0 ? sp_dw_cplx  : scales_weights.z;
    float dim_w_color      = sp_dw_color >= 0.0 ? sp_dw_color : scales_weights.w;
    bool has_target = grid_size_has_target.w != 0;
    // Per-dimension match budgets (global match_limits; per-asset override wins).
    float color_match_max = sp_color_max >= 0.0 ? clamp(sp_color_max, 0.0, 3.0) : clamp(match_limits.x, 0.0, 3.0);
    float collision_match_max = sp_coll_max >= 0.0 ? clamp(sp_coll_max, 0.0, 1.0) : clamp(match_limits.y, 0.0, 1.0);
    // complexity per-asset stores percent N → ratio 1 + N/100; global match_limits.z is already a ratio.
    float complexity_overfill_ratio = sp_cplx_pct >= 0.0 ? max(1.0 + sp_cplx_pct * 0.01, 0.0) : max(match_limits.z, 0.0);
    float min_match_fraction = sp_min_match >= 0.0 ? sp_min_match : voxel_size_threshold.w;

    // Workgroup-best, tracked by thread 0 across combo chunks.
    float best_score = INVALID_SCORE;
    bool best_valid = false;
    int best_combo = -1;
    vec4 best_stats0 = vec4(0.0);
    float best_coverage = 0.0;
    float best_fraction = 0.0;

    for (uint combo_base = 0u; combo_base < combo_count; combo_base += WORKGROUP_SIZE) {
        uint combo = combo_base + tid;
        bool combo_active = combo < combo_count;
        uint pivot_slot = combo / yaw_slots;
        uint yaw_slot = combo - pivot_slot * yaw_slots;

        vec3 pivot_world = vec3(0.0);
        if (combo_active && pivot_count > 0u) {
            pivot_world = profile_arena_pivot(
                uint(profile_index), pivot_start + pivot_slot).offset_bias.xyz;
        }
        float rot_angle = yaw_slots > 1u ? float(yaw_slot) * 6.28318530718 / rot_count : 0.0;
        float rot_ca = cos(rot_angle);
        float rot_sa = sin(rot_angle);

        FineAccum acc;
        acc.gain_sum = 0.0;
        acc.weight_sum = 0.0;
        acc.loss_before_sum = 0.0;
        acc.loss_after_sum = 0.0;
        acc.solid_collision = 0.0;
        acc.clearance_overlap = 0.0;
        acc.coverage_weight = 0.0;
        acc.total_weight = 0.0;
        acc.pass_weight = 0.0;
        acc.off_target_collision_penalty_weight = 0.0;

        // Profile samples stream through shared memory in fixed-size batches.
        for (uint batch_start = 0u; batch_start < sample_count; batch_start += AD_BATCH_CAPACITY) {
            uint batch_len = min(sample_count - batch_start, AD_BATCH_CAPACITY);
            for (uint load = tid; load < batch_len; load += WORKGROUP_SIZE) {
                ProfileSampleRecord rec = profile_arena_sample(
                    uint(profile_index), sample_start + batch_start + load);
                s_sample_offset_weight[load] = rec.offset_weight;
                s_sample_payload[load] = rec.payload;
            }
            barrier();

            if (combo_active) {
                for (uint i = 0u; i < batch_len; i++) {
                    ProfileSampleRecord record;
                    record.offset_weight = s_sample_offset_weight[i];
                    record.payload = s_sample_payload[i];
                    ProfileSample decoded_sample = decode_profile_sample(record);
                    if ((decoded_sample.flags & PROFILE_SAMPLE_FLAG_FINE) == 0u) continue;
                    float weight = decoded_sample.sample_weight;
                    if (weight <= 0.0) {
                        continue;
                    }
                    ivec3 p = resolve_profile_sample_voxel(
                        decoded_sample, origin, pivot_world, rot_ca, rot_sa, voxel_size);
                    // 地下（height-relative p.y<0 = 地形体内）一律不打分：与"出网格 /
                    // 超出网格顶"一样纯跳过——既不计分，也不计入 solid_collision /
                    // clearance_overlap（地下一律不打分策略；不再对埋地候选做物理判死）。
                    // profile_sample_in_bounds covers p.y < 0, so no separate branch is needed.
                    // 故无需单独的 p.y<0 分支。
                    if (!profile_sample_in_bounds(p, grid_size_has_target.xyz)) {
                        continue;
                    }
                    uint idx = uint(voxel_index(p));

                    uvec2 cs = cur_sample[idx];
                    vec4 cur_rgba = unpack_profile_sample_rgba8(cs.x);
                    float cur_col = load_r8(cs.y);

                    if ((decoded_sample.flags & PROFILE_SAMPLE_FLAG_CLEARANCE) != 0u) {
                        // Clearance probes: physical constraint only — never
                        // part of the semantic compose.
                        acc.clearance_overlap += max(cur_rgba.a, cur_col) * weight;
                        continue;
                    }

                    uvec2 ts = tgt_sample[idx];
                    vec4 tgt = unpack_profile_sample_rgba8(ts.x);
                    float tgt_col = load_r8(ts.y);

                    float ad_col_raw = decoded_sample.collision;
                    vec4 ad_rgba = decoded_sample.color;
                    float ad_cplx_val = ad_complexity_write_value(ad_rgba.a, complexity_write_scale);
                    float ad_col_val = ad_collision_write_value(ad_col_raw, solid_threshold, collision_write_scale);

                    vec4 pred_rgba = ad_compose_rgba(cur_rgba, ad_rgba.rgb, ad_cplx_val);
                    float pred_col = ad_compose_collision(cur_col, ad_col_val);

                    ProfileSampleFields fields = load_profile_sample_fields(
                        cur_rgba, cur_col, tgt, tgt_col, pred_rgba, pred_col);
                    ProfileSampleEvaluation evaluation = evaluate_profile_sample(
                        decoded_sample, fields, PROFILE_SAMPLE_POLICY_FINE_RESIDUAL);
                    vec3 dimension_weights = vec3(dim_w_collision, dim_w_complexity, dim_w_color);
                    float lb = profile_sample_weighted_loss(
                        evaluation.loss_before, decoded_sample, dimension_weights);
                    float la = profile_sample_weighted_loss(
                        evaluation.loss_after, decoded_sample, dimension_weights);
                    float voxel_gain = lb - la;
                    float sample_dim_weight_total = dim_w_collision * abs(decoded_sample.semantic_weights.z)
                        + dim_w_complexity * abs(decoded_sample.semantic_weights.y)
                        + 3.0 * dim_w_color * abs(decoded_sample.semantic_weights.x);
                    float dw = sample_dim_weight_total * weight;
                    // Physical accumulators stay separate from the semantic score:
                    // feasibility (overlap with existing scene collision) does not
                    // depend on whether the target wants content here.
                    if (ad_col_raw >= solid_threshold) {
                        acc.solid_collision += cur_col * weight;
                    }
                    // total_weight = the full in-grid body; it normalizes the signed
                    // score and also serves as the coverage-diagnostic denominator.
                    acc.total_weight += weight;

                    // Targetless runs (has_target == 0) have no meaningful "empty",
                    // so every voxel still feeds the legacy mean-gain score. With a
                    // TargetSV, occupied voxels can earn +weight through the strict
                    // match below; empty-target voxels instead earn a negative vote
                    // proportional to the collision value this asset would stamp.
                    bool target_wants_content = !has_target
                        || max(tgt.a, tgt_col) > TARGET_OCCUPIED_MIN;
                    if (target_wants_content) {
                        acc.loss_before_sum += lb * weight;
                        acc.loss_after_sum += la * weight;
                        acc.gain_sum += voxel_gain * weight;
                        acc.weight_sum += dw;
                        if (has_target) {
                            // coverage_weight is the on-target body weight used by
                            // the target-coverage diagnostic.
                            acc.coverage_weight += weight;
                            // Strict conjunctive match: the voxel counts only when
                            // EVERY dimension's post-compose value lands within its
                            // budget (exceeding any one of color / collision /
                            // complexity disqualifies), AND the write is a genuine
                            // improvement (already-satisfied voxels stay excluded, so
                            // later rounds cannot re-score filled space).
                            float color_l1 = evaluation.loss_after.z;
                            // Complexity: only overfill beyond +N% disqualifies (asymmetric,
                            // pure ratio); color / collision stay symmetric |pred-tgt| gates.
                            bool dims_ok = color_l1 <= color_match_max
                                && evaluation.loss_after.x <= collision_match_max
                                && pred_rgba.a <= tgt.a * complexity_overfill_ratio;
                            if (dims_ok && voxel_gain > MATCH_GAIN_EPS) {
                                acc.pass_weight += weight;
                            }
                        }
                    } else {
                        acc.off_target_collision_penalty_weight += ad_col_val * weight;
                    }
                }
            }
            barrier();
        }

        float combo_score = INVALID_SCORE;
        float loss_before_mean = 0.0;
        float loss_after_mean = 0.0;
        float match_fraction = 0.0;
        bool combo_valid = false;
        bool has_score_samples = has_target ? acc.total_weight > 0.0 : acc.weight_sum > 0.0;
        if (combo_active && has_score_samples) {
            float mean_gain = acc.weight_sum > 0.0
                ? acc.gain_sum / acc.weight_sum
                : 0.0;  // ~[-1, 1], occupied-target samples only
            loss_before_mean = acc.weight_sum > 0.0
                ? acc.loss_before_sum / acc.weight_sum
                : 0.0;
            loss_after_mean = acc.weight_sum > 0.0
                ? acc.loss_after_sum / acc.weight_sum
                : 0.0;
            // Physical feasibility gate (solid collision / clearance overlap) is
            // bypassed when its limit is negative: collision_limit / clearance_limit
            // < 0 means "unlimited", so a candidate is NOT rejected merely for
            // overlapping existing scene collision/occupancy. This lets placement
            // (e.g. grass) proceed in cells that already carry collision. Pass a
            // non-negative limit in settings to re-enable the hard gate per case.
            // solid_collision / clearance_overlap are still accumulated and written
            // to the record + debug channels either way.
            bool collision_ok = limits.y < 0.0 || acc.solid_collision <= limits.y;
            bool clearance_ok = limits.z < 0.0 || acc.clearance_overlap <= limits.z;
            if (has_target) {
                // Signed full-footprint score: strict occupied-target matches vote
                // +weight, while empty-target samples vote -stamp_collision*weight.
                // Dividing by total_weight makes every sampled body voxel take part
                // in the decision and yields a real negative score for a candidate
                // that only writes collision outside TargetSV.
                match_fraction = acc.total_weight > 0.0
                    ? (acc.pass_weight - acc.off_target_collision_penalty_weight)
                        / acc.total_weight
                    : 0.0;
                combo_score = match_fraction
                    + TIEBREAK_GAIN_SCALE * clamp(mean_gain, -1.0, 1.0);
                combo_valid = collision_ok && clearance_ok
                    && match_fraction > min_match_fraction;
            } else {
                // Targetless runs: a match fraction is undefined without TargetSV;
                // keep the legacy mean residual-gain score against the same
                // threshold slot.
                combo_score = mean_gain;
                combo_valid = collision_ok && clearance_ok
                    && combo_score > min_match_fraction;
            }
        }
        s_combo_score[tid] = combo_score;
        s_combo_valid[tid] = combo_valid ? 1.0 : 0.0;
        s_combo_stats0[tid] = vec4(acc.solid_collision, loss_before_mean, loss_after_mean, acc.clearance_overlap);
        s_combo_coverage[tid] = acc.total_weight > 0.0 ? acc.coverage_weight / acc.total_weight : 0.0;
        s_combo_fraction[tid] = match_fraction;
        barrier();

        if (tid == 0u) {
            for (uint t = 0u; t < WORKGROUP_SIZE; t++) {
                uint t_combo = combo_base + t;
                if (t_combo >= combo_count) {
                    break;
                }
                bool t_valid = s_combo_valid[t] > 0.5;
                float t_score = s_combo_score[t];
                bool better = (t_valid && !best_valid)
                    || (t_valid == best_valid && t_score > best_score);
                if (better) {
                    best_valid = t_valid;
                    best_score = t_score;
                    best_combo = int(t_combo);
                    best_stats0 = s_combo_stats0[t];
                    best_coverage = s_combo_coverage[t];
                    best_fraction = s_combo_fraction[t];
                }
            }
        }
        barrier();
    }

    if (tid == 0u) {
        if (best_combo < 0) {
            write_invalid_record(slot, origin, anchor_id, asset_id);
            return;
        }
        uint best_pivot_slot = uint(best_combo) / yaw_slots;
        int best_yaw_slot = int(uint(best_combo) - best_pivot_slot * yaw_slots);
        // Arena 下 pivot_start 恒为 0（槽内局部），所以这就是**槽内局部** pivot 下标；
        // 消费方（stamp / results_to_world）用同记录的 profile_index 定位所属 slot。
        int global_pivot_index = pivot_count > 0u ? int(pivot_start + best_pivot_slot) : -1;
        write_record(slot, origin, best_score, anchor_id, asset_id, best_yaw_slot,
            global_pivot_index, best_stats0, profile_index, best_valid, coarse_score,
            best_fraction);
        write_debug_voxel_channels(origin, best_coverage, best_stats0.y, best_stats0.z,
            best_valid ? best_score : 0.0, best_valid ? float(best_yaw_slot) : 0.0,
            best_stats0.x, best_stats0.w);
    }
}
