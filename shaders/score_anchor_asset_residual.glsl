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
// Candidate score = residual gain against TargetSV over five dimensions
// (collision, complexity, R, G, B) in ONE record traversal:
//   loss_before = D(CurrentSV, TargetSV)
//   loss_after  = D(compose(CurrentSV, AD), TargetSV)
//   score       = sum(dim_w * (loss_before - loss_after) * sample_w)
//               / sum(dim_w * sample_w)
// compose() is the stamp rule verbatim (@@GEN ad_voxel_compose), so the
// score-time prediction equals what stamp_asset_voxels.glsl later writes.
// Clearance records (FLAG_CLEARANCE) never enter the semantic compose; they
// only feed the physical clearance accumulator. Physical collision/clearance
// use accumulators separate from the semantic gain. "Place nothing" is the
// implicit baseline: a candidate is valid only when score > gain_threshold.
//
// Output: one 4-vec4 (64 B) record per (anchor, k) at
// fine_candidates[anchor_id * topk + k]:
//   [0] origin.xyz (anchor voxel position), residual gain
//   [1] anchor_id, asset_index, yaw_slot, global_pivot_index (-1 = zero pivot)
//   [2] solid_collision, loss_before_mean, loss_after_mean, clearance_overlap
//   [3] profile_index, valid (0/1), coarse probe score, reserved

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ComplexityField {
    uint complexity_field_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionField {
    uint collision_field_u32[];  // one uint per voxel, quantized 0..255 in the low byte
};

layout(set = 0, binding = 2, std430) restrict readonly buffer TargetField {
    vec4 target_field[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer TargetCollision {
    uint target_collision_u32[];  // one uint per voxel, quantized 0..255 in the low byte
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

layout(set = 0, binding = 8, std430) restrict writeonly buffer FineCandidates {
    vec4 fine_candidates[];
};

struct RuntimeProfileTableRecord {
    uvec4 ids;                    // x=profile_id, y=profile_index, z=probe_start, w=probe_count
    uvec4 ranges;                 // x=asset_voxel_start, y=asset_voxel_count, z=pivot_start, w=pivot_count
    vec4 color_complexity;
    vec4 density_radius_hash_pad;
};

struct RuntimePivotRecord {
    vec4 offset_bias;             // xyz = descriptor-local WORLD offset, w = score_bias
    uvec4 ids_pad;
};

// Container-resident descriptor voxels (AutoVoxelRuntimeProfileContainer
// asset_voxel_records, 32 B stride).
struct AssetVoxelRecord {
    ivec4 pos_strength;           // xyz = local voxel offset, w = collision_strength_q8 (0..255)
    uint color_rgba8;             // shader rgba8 word, alpha = complexity
    float weight;                 // sample weight (>= 0)
    uint flags;                   // FLAG_CLEARANCE bit
    uint reserved;
};

layout(set = 1, binding = 6, std430) restrict readonly buffer RuntimeProfileTable {
    RuntimeProfileTableRecord runtime_profile_table[];
};

// @@GEN debug_set score_contract_stats decl
layout(set = 1, binding = 8, std430) restrict buffer ScoreRuntimeProfileDebug {
    uint score_contract_debug[];
};
// @@END debug_set score_contract_stats decl

layout(set = 1, binding = 11, std430) restrict readonly buffer RuntimePivotRecords {
    RuntimePivotRecord runtime_pivot_records[];
};

layout(set = 1, binding = 13, std430) restrict readonly buffer AssetVoxelRecords {
    AssetVoxelRecord asset_voxel_records[];
};

// asset_index -> (profile_id, profile_index, quota, object_type). Shared with
// the reduce pass (quota) and the runtime writeback (object_type).
layout(set = 1, binding = 14, std430) restrict readonly buffer AssetLookup {
    ivec4 asset_lookup[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_has_target;   // grid xyz, w = has_target (0/1)
    vec4 voxel_size_threshold;    // voxel size xyz (world units), w = gain_threshold
    ivec4 counts;                 // rotation_slots, topk, asset_count, anchor_capacity
    vec4 limits;                  // solid_threshold, collision_limit, clearance_limit, complexity_write_scale
    vec4 scales_weights;          // collision_write_scale, dim_w_collision, dim_w_complexity, dim_w_color (per channel)
    ivec4 meta;                   // contract_enabled, profile_count, debug_write_mask, reserved
    // Host-passed element capacities for the capacity gates below (the host
    // packs each bound buffer's element count at its allocation point; GLSL
    // .length()/OpArrayLength is unsupported by Godot's SPIR-V path).
    ivec4 capacities;             // x=asset_lookup, y=runtime_profile_table, z=asset_voxel_records, w=runtime_pivot_records
};

const uint FLAG_CLEARANCE = 2u;
const uint ANCHOR_GRID_X = 256u;   // must match prefilter/finalize dispatch width
const uint EMPTY_ASSET_ID = 0xFFFFFFFFu;
const uint RECORD_STRIDE = 4u;
const uint AD_BATCH_CAPACITY = 128u;
const uint WORKGROUP_SIZE = 64u;
const float INVALID_SCORE = -1.0e18;
const float TARGET_OCCUPIED_MIN = 0.01;
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
const uint SCORE_DEBUG_ALIVE_OBJECT_READS = 4u;
const uint SCORE_DEBUG_PROFILE_RECORDS_MATCHED = 5u;
const uint SCORE_DEBUG_RUNTIME_OVERLAP_TESTS = 6u;
const uint SCORE_DEBUG_RUNTIME_OVERLAP_HITS = 7u;
const uint SCORE_DEBUG_PROFILE_TABLE_READS = 8u;
const uint SCORE_DEBUG_ASSET_PROFILE_ID = 9u;
const uint SCORE_DEBUG_CANDIDATE_INVOCATIONS = 10u;
const uint SCORE_DEBUG_PROFILE_COMPLEXITY_Q1000 = 11u;
const uint SCORE_DEBUG_RUNTIME_PROFILE_READS = 12u;
const uint SCORE_DEBUG_RUNTIME_PROFILE_MATCHES = 13u;
const uint SCORE_DEBUG_PROBE_RECORD_READS = 14u;
const uint SCORE_DEBUG_PIVOT_RECORD_READS = 16u;
const uint SCORE_DEBUG_PROBE_WEIGHT_Q1000 = 17u;
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

shared ivec4 s_ad_pos_strength[AD_BATCH_CAPACITY];
shared uvec4 s_ad_payload[AD_BATCH_CAPACITY]; // x=rgba8, y=weight bits, z=flags, w=reserved
// Per-thread combo results for the workgroup argmax.
shared float s_combo_score[WORKGROUP_SIZE];
shared float s_combo_valid[WORKGROUP_SIZE];
shared vec4 s_combo_stats0[WORKGROUP_SIZE];   // solid_collision, loss_before_mean, loss_after_mean, clearance
shared float s_combo_coverage[WORKGROUP_SIZE];

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

bool in_grid_bounds(ivec3 p) {
    return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, grid_size_has_target.xyz));
}

vec4 unpack_rgba8(uint packed_value) {
    return vec4(
        float((packed_value >> 24u) & 0xFFu),
        float((packed_value >> 16u) & 0xFFu),
        float((packed_value >> 8u) & 0xFFu),
        float(packed_value & 0xFFu)
    ) / 255.0;
}

float load_r8(uint value) {
    // caller passes the per-voxel u32; helper kept so both collision fields share the decode
    return float(value & 0xFFu) * (1.0 / 255.0);
}

float load_current_collision(uint index) {
    return load_r8(collision_field_u32[index]);
}

float load_target_collision(uint index) {
    return load_r8(target_collision_u32[index]);
}

void write_record(uint slot, ivec3 origin, float gain, uint anchor_id, uint asset_id,
        int yaw_slot, int global_pivot_index, vec4 stats0, int profile_index,
        bool valid, float coarse_score) {
    uint base = slot * RECORD_STRIDE;
    fine_candidates[base + 0u] = vec4(vec3(origin), gain);
    fine_candidates[base + 1u] = vec4(float(anchor_id), float(asset_id), float(yaw_slot), float(global_pivot_index));
    fine_candidates[base + 2u] = stats0;
    fine_candidates[base + 3u] = vec4(float(profile_index), valid ? 1.0 : 0.0, coarse_score, 0.0);
}

void write_invalid_record(uint slot, ivec3 origin, uint anchor_id, uint asset_id) {
    write_record(slot, origin, INVALID_SCORE, anchor_id, asset_id, 0, -1, vec4(0.0), -1, false, -1.0);
}

void write_debug_voxel_channels(ivec3 origin, float coverage, float loss_before,
        float loss_after, float gain, float best_slot, float solid_collision, float clearance) {
    if ((uint(meta.z) & 1u) == 0u) {
        return;
    }
    if (!in_grid_bounds(origin)) {
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
    if (profile_index < 0 || profile_index >= max(meta.y, 0)
            || profile_index >= max(capacities.y, 0)) {
        if (tid == 0u) {
            write_invalid_record(slot, origin, anchor_id, asset_id);
        }
        return;
    }

    RuntimeProfileTableRecord profile = runtime_profile_table[profile_index];
    uint ad_start = profile.ranges.x;
    uint ad_count = profile.ranges.y;
    uint pivot_start = profile.ranges.z;
    uint pivot_count = profile.ranges.w;
    if (ad_count == 0u) {
        if (tid == 0u) {
            write_invalid_record(slot, origin, anchor_id, asset_id);
        }
        return;
    }
    // Capacity gates: refuse corrupt profile ranges instead of reading past the
    // AD/pivot record buffers (capacity is the host-passed element count of
    // each buffer). Workgroup-uniform, so the early return stays barrier-safe.
    uint ad_capacity = uint(max(capacities.z, 0));
    uint pivot_capacity = uint(max(capacities.w, 0));
    if (ad_start > ad_capacity || ad_count > ad_capacity - ad_start
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
    float dim_w_collision = scales_weights.y;
    float dim_w_complexity = scales_weights.z;
    float dim_w_color = scales_weights.w;
    float dim_w_total = dim_w_collision + dim_w_complexity + 3.0 * dim_w_color;
    bool has_target = grid_size_has_target.w != 0;

    // Workgroup-best, tracked by thread 0 across combo chunks.
    float best_score = INVALID_SCORE;
    bool best_valid = false;
    int best_combo = -1;
    vec4 best_stats0 = vec4(0.0);
    float best_coverage = 0.0;

    for (uint combo_base = 0u; combo_base < combo_count; combo_base += WORKGROUP_SIZE) {
        uint combo = combo_base + tid;
        bool combo_active = combo < combo_count;
        uint pivot_slot = combo / yaw_slots;
        uint yaw_slot = combo - pivot_slot * yaw_slots;

        ivec3 pivot_voxels = ivec3(0);
        if (combo_active && pivot_count > 0u) {
            vec3 pivot_world = runtime_pivot_records[pivot_start + pivot_slot].offset_bias.xyz;
            pivot_voxels = ivec3(round(pivot_world / voxel_size));
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

        // AD voxels stream through shared memory in fixed-size batches; every
        // batch folds into the same accumulator, so any ad_count works.
        for (uint batch_start = 0u; batch_start < ad_count; batch_start += AD_BATCH_CAPACITY) {
            uint batch_len = min(ad_count - batch_start, AD_BATCH_CAPACITY);
            for (uint load = tid; load < batch_len; load += WORKGROUP_SIZE) {
                AssetVoxelRecord rec = asset_voxel_records[ad_start + batch_start + load];
                s_ad_pos_strength[load] = rec.pos_strength;
                s_ad_payload[load] = uvec4(rec.color_rgba8, floatBitsToUint(rec.weight), rec.flags, rec.reserved);
            }
            barrier();

            if (combo_active) {
                for (uint i = 0u; i < batch_len; i++) {
                    ivec4 fp = s_ad_pos_strength[i];
                    uvec4 payload = s_ad_payload[i];
                    float weight = max(uintBitsToFloat(payload.y), 0.0);
                    if (weight <= 0.0) {
                        continue;
                    }
                    // Pivot subtracted before yaw; integer voxel snap — the same
                    // mapping the stamp uses, so the prediction is exact.
                    ivec3 base_fp = fp.xyz - pivot_voxels;
                    ivec3 rotated_fp = yaw_slots > 1u ? rotate_sample_offset_y(base_fp, rot_ca, rot_sa) : base_fp;
                    ivec3 p = origin + rotated_fp;
                    if (!in_grid_bounds(p)) {
                        continue;
                    }
                    uint idx = uint(voxel_index(p));

                    vec4 cur_rgba = unpack_rgba8(complexity_field_rgba8[idx]);
                    float cur_col = load_current_collision(idx);

                    if ((payload.z & FLAG_CLEARANCE) != 0u) {
                        // Clearance probes: physical constraint only — never
                        // part of the semantic compose.
                        acc.clearance_overlap += max(cur_rgba.a, cur_col) * weight;
                        continue;
                    }

                    vec4 tgt = target_field[idx];
                    float tgt_col = load_target_collision(idx);

                    float ad_col_raw = clamp(float(fp.w) / 255.0, 0.0, 1.0);
                    vec4 ad_rgba = unpack_rgba8(payload.x);
                    float ad_cplx_val = ad_complexity_write_value(ad_rgba.a, complexity_write_scale);
                    float ad_col_val = ad_collision_write_value(ad_col_raw, solid_threshold, collision_write_scale);

                    vec4 pred_rgba = ad_compose_rgba(cur_rgba, ad_rgba.rgb, ad_cplx_val);
                    float pred_col = ad_compose_collision(cur_col, ad_col_val);

                    // Five dimensions, one traversal: per-channel |value - target|.
                    float lb = dim_w_collision * abs(cur_col - tgt_col)
                        + dim_w_complexity * abs(cur_rgba.a - tgt.a)
                        + dim_w_color * (abs(cur_rgba.r - tgt.r) + abs(cur_rgba.g - tgt.g) + abs(cur_rgba.b - tgt.b));
                    float la = dim_w_collision * abs(pred_col - tgt_col)
                        + dim_w_complexity * abs(pred_rgba.a - tgt.a)
                        + dim_w_color * (abs(pred_rgba.r - tgt.r) + abs(pred_rgba.g - tgt.g) + abs(pred_rgba.b - tgt.b));
                    acc.loss_before_sum += lb * weight;
                    acc.loss_after_sum += la * weight;
                    acc.gain_sum += (lb - la) * weight;
                    acc.weight_sum += dim_w_total * weight;

                    // Physical accumulators stay separate from the semantic gain.
                    if (ad_col_raw >= solid_threshold) {
                        acc.solid_collision += cur_col * weight;
                    }
                    acc.total_weight += weight;
                    if (max(tgt.a, tgt_col) > TARGET_OCCUPIED_MIN) {
                        acc.coverage_weight += weight;
                    }
                }
            }
            barrier();
        }

        float combo_score = INVALID_SCORE;
        float loss_before_mean = 0.0;
        float loss_after_mean = 0.0;
        bool combo_valid = false;
        if (combo_active && acc.weight_sum > 0.0) {
            combo_score = acc.gain_sum / acc.weight_sum;
            loss_before_mean = acc.loss_before_sum / acc.weight_sum;
            loss_after_mean = acc.loss_after_sum / acc.weight_sum;
            combo_valid = acc.solid_collision <= limits.y
                && acc.clearance_overlap <= limits.z
                && (!has_target || acc.coverage_weight > 0.0)
                && combo_score > voxel_size_threshold.w;
        }
        s_combo_score[tid] = combo_score;
        s_combo_valid[tid] = combo_valid ? 1.0 : 0.0;
        s_combo_stats0[tid] = vec4(acc.solid_collision, loss_before_mean, loss_after_mean, acc.clearance_overlap);
        s_combo_coverage[tid] = acc.total_weight > 0.0 ? acc.coverage_weight / acc.total_weight : 0.0;
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
        int global_pivot_index = pivot_count > 0u ? int(pivot_start + best_pivot_slot) : -1;
        write_record(slot, origin, best_score, anchor_id, asset_id, best_yaw_slot,
            global_pivot_index, best_stats0, profile_index, best_valid, coarse_score);
        write_debug_voxel_channels(origin, best_coverage, best_stats0.y, best_stats0.z,
            best_valid ? best_score : 0.0, best_valid ? float(best_yaw_slot) : 0.0,
            best_stats0.x, best_stats0.w);
    }
}
