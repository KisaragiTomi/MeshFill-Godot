#[compute]
#version 450

// Scores candidate object origins inside 8x8x8 voxel tiles.
// One workgroup owns one origin tile; each invocation evaluates one candidate.
// Support is NOT scored here: the anchor/candidate stage guarantees ground contact,
// so the score is penalty-only (collision/complexity/clearance overlap). The
// support_ratio/support_hit/support_total record slots are retained for layout
// stability but are always 0.
// Output is the TileTopK buffer, encoded as 4 vec4 records per candidate:
//   0: vec4(voxel_origin.xyz, score)
//   1: vec4(tile_id, asset_index, rotation_index, scale_index)
//   2: vec4(support_ratio[=0], solid_collision, complexity_overlap, clearance_overlap)
//   3: vec4(ignored_sample, valid, support_hit[=0], support_total[=0])
//
// DebugVoxelOutput: NUM_DEBUG_CHANNELS floats per voxel for visualization.
// Channel layout:
//   0: target_coverage   — weighted fraction of footprint overlapping target
//   1: target_complexity_fit  — 1 − mean |target complexity - collision strength|, higher = better
//   2: target_color_fit  — 1 − mean RGB distance to asset_color, higher = better
//   3: target_density    — average target complexity under footprint
//   4: placement_score   — final candidate score (best over the yaw sweep at this voxel)
//   5: best_rotation_slot — winning yaw slot index (0..rotation_slots-1) at this voxel;
//                           reuses the retired support_ratio slot (support gone). CPU reads
//                           score (ch 4) + rotation (ch 5) straight from this buffer — the
//                           per-tile tile_topk record is no longer read back.
//   6: solid_collision
//   7: clearance_overlap

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ComplexityField {
    uint complexity_field_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionField {
    uint collision_field_r8_words[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer FootprintPos {
    ivec4 footprint_pos_strength[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer FootprintWeight {
    vec4 footprint_weight_flags[];
};

layout(set = 0, binding = 4, std430) restrict buffer TileTopK {
    vec4 tile_topk[];
};

layout(set = 0, binding = 5, std430) restrict readonly buffer CandidateVoxelRegions {
    uint candidate_tile_ids[];
};

layout(set = 0, binding = 6, std430) restrict readonly buffer TargetField {
    vec4 target_field[];
};

// @@GEN debug_set voxel_debug_channels decl
layout(set = 0, binding = 7, std430) restrict buffer DebugVoxelOutput {
    float debug_voxel[];  // 8 channels/element, index space: voxel_dense_xzy
};
// @@END debug_set voxel_debug_channels decl

// Phase-2 data-driven dimension scoring (see scoring-dimensions-design.md). Environment
// channels (collision/complexity/color...) laid out flat: env_channels[voxel*env_channel_count + ch].
layout(set = 0, binding = 8, std430) restrict readonly buffer EnvChannelField {
    float env_channels[];
};

struct DimRecord {
    ivec4 channel_mode_pad;   // x = env channel index, y = fit_mode (0 = MATCH), z/w = pad
    vec4 weight_min_max_pad;  // x = weight, y = constraint_min, z = constraint_max, w = pad
};
layout(set = 0, binding = 9, std430) restrict readonly buffer DimensionTable {
    DimRecord dims[];
};

// Config moved out of the push constant (Godot caps push constants at 128 bytes): penalty
// weights + env_channel_count + the per-asset dimension profile (8 slots).
layout(set = 0, binding = 10, std430) restrict readonly buffer ScoreConfig {
    vec4 cfg_score_weights;    // x reserved (support retired); y/z/w = collision/overlap/clearance penalty
    ivec4 cfg_dim_meta;        // x = env_channel_count, yzw = reserved
    vec4 cfg_asset_profile0;   // per-asset dimension profile values, dims 0..3
    vec4 cfg_asset_profile1;   // per-asset dimension profile values, dims 4..7
};

layout(set = 1, binding = 0, std430) restrict readonly buffer RuntimeAlive {
    int runtime_alive[];
};

layout(set = 1, binding = 1, std430) restrict readonly buffer RuntimeGeneration {
    int runtime_generation[];
};

layout(set = 1, binding = 2, std430) restrict readonly buffer RuntimeType {
    int runtime_type[];
};

layout(set = 1, binding = 3, std430) restrict readonly buffer RuntimeProfile {
    int runtime_profile[];
};

layout(set = 1, binding = 4, std430) restrict readonly buffer RuntimeBoundsMin {
    ivec4 runtime_bounds_min[];
};

layout(set = 1, binding = 5, std430) restrict readonly buffer RuntimeBoundsMax {
    ivec4 runtime_bounds_max[];
};

struct RuntimeProfileTableRecord {
    uvec4 ids;
    uvec4 ranges;
    vec4 color_complexity;
    vec4 density_radius_hash_pad;
};

struct RuntimeProbeRecord {
    vec4 offset_weight;
    uvec4 expected_flags_kind;
};

struct RuntimePivotRecord {
    vec4 offset_bias;
    uvec4 ids_pad;
};

layout(set = 1, binding = 6, std430) restrict readonly buffer RuntimeProfileTable {
    RuntimeProfileTableRecord runtime_profile_table[];
};

layout(set = 1, binding = 7, std430) restrict readonly buffer ScoreRuntimeProfileParams {
    ivec4 contract_counts; // enabled, runtime object capacity, profile count, asset profile id
    ivec4 contract_modes;  // runtime avoidance, profile complexity debug, object-ref spacing, debug full-scan spacing
    ivec4 profile_side_counts; // probe records, reserved, pivot records, reserved
    vec4 runtime_spacing_params; // min_distance_voxels, reserved, reserved, reserved
    ivec4 object_ref_counts; // enabled, tile_count, refs_per_tile, object_ref_capacity
    ivec4 object_ref_tile_grid; // tile_grid x/y/z, tile_size
    ivec4 object_ref_modes; // full-scan debug fallback, require object refs, numeric schema confirmed, reserved
};

// @@GEN debug_set score_contract_stats decl
layout(set = 1, binding = 8, std430) restrict buffer ScoreRuntimeProfileDebug {
    uint score_contract_debug[];
};
// @@END debug_set score_contract_stats decl

layout(set = 1, binding = 9, std430) restrict readonly buffer RuntimeProbeRecords {
    RuntimeProbeRecord runtime_probe_records[];
};

layout(set = 1, binding = 11, std430) restrict readonly buffer RuntimePivotRecords {
    RuntimePivotRecord runtime_pivot_records[];
};

layout(set = 1, binding = 12, std430) restrict readonly buffer SceneVoxelTileObjectRefs {
    uint scene_voxel_tile_object_refs[];
};

layout(set = 2, binding = 0, std430) restrict readonly buffer CandidateRouteRecords {
    uvec4 candidate_route_records[];
};

layout(set = 2, binding = 1, std430) restrict readonly buffer CandidateRouteRanges {
    uvec4 candidate_route_ranges[];
};

// @@GEN debug_set candidate_route_binding_stats
layout(set = 2, binding = 2, std430) restrict buffer CandidateRouteBindingDebug {
    uint candidate_route_binding_debug[];
};
const uint CANDIDATE_ROUTE_BINDING_ENABLED = 0u;
const uint CANDIDATE_ROUTE_BINDING_RANGE_COUNT = 1u;
const uint CANDIDATE_ROUTE_BINDING_RANGE_READS = 2u;
const uint CANDIDATE_ROUTE_BINDING_RECORD_READS = 3u;
const uint CANDIDATE_ROUTE_BINDING_FIRST_RANGE_START = 4u;
const uint CANDIDATE_ROUTE_BINDING_FIRST_RANGE_COUNT = 5u;
const uint CANDIDATE_ROUTE_BINDING_FIRST_RECORD_X = 6u;
const uint CANDIDATE_ROUTE_BINDING_FIRST_RECORD_Y = 7u;
const uint CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_CANDIDATE_COUNT = 8u;
const uint CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_RECORD_READS = 9u;
const uint CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_RANGE_INDEX = 10u;
const uint CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_OUTPUT_CAPACITY = 11u;
const uint CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_RANGE_START = 12u;
const uint CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_RANGE_COUNT = 13u;
const uint CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_RECORD_CAPACITY = 14u;
// @@END debug_set candidate_route_binding_stats

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_tile_count;    // x, y, z, total tile count
    ivec4 tile_counts_topk;        // tile_count_x, tile_count_y, tile_count_z, top_k
    ivec4 sample_min_pad;          // sample min xyz, .w = packed asset color (RGBA8)
    ivec4 sample_max_pad;          // sample max xyz exclusive, .w = has_target (0/1)
    ivec4 ids_counts;              // footprint_count, asset_index, rotation_index, scale_index
    vec4 thresholds;               // solid_threshold, collision_limit, .z reserved (support retired), clearance_limit
    ivec4 dispatch_search;         // candidate_tile_count, search radius xyz
    ivec4 footprint_pivot_pad;     // xyz = footprint pivot voxels (subtracted before yaw), w = dim_count (0 = penalty-only)
};  // 128 bytes exactly (8 x 16) = Godot push-constant limit. score_weights / env_channel_count /
    // asset_profile moved to the ScoreConfig SSBO (binding 10).

// bit 0 (value 1u) reserved — was FLAG_SUPPORT; support retired. FLAG_CLEARANCE stays 2u.
const uint FLAG_CLEARANCE = 2u;
const uint TILE_SIZE = 8u;
const uint LOCAL_COUNT = 512u;
const uint FOOTPRINT_CAPACITY = 128u;

// Sentinel score for "no valid candidate". Kept far below any real penalty-only
// score (now that the support positive term is retired, valid scores are <= 0) so a
// valid-but-penalized candidate still beats an invalid one in the per-tile max-select.
const float INVALID_SCORE = -1.0e18;
const uint RECORD_STRIDE = 4u;
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
const int RUNTIME_CONTRACT_SCAN_CAP = 4096;
const int PROFILE_CONTRACT_SCAN_CAP = 1024;

shared ivec4 s_footprint_pos_strength[128];
shared vec4 s_footprint_weight_flags[128];
shared float s_scores[512];
shared ivec4 s_candidate_origins[512];

struct VoxelSample {
    float complexity;
    float collision;
    bool ignored;
};

struct EvalResult {
    float score;
    float support_ratio;
    float solid_collision;
    float complexity_overlap;
    float clearance_overlap;
    float ignored_sample;
    float support_hit;
    float support_total;
    bool valid;
    float target_coverage;
    float target_complexity_fit;
    float target_color_dist;
    float target_density;
    float target_total_weight;
    float semantic_score;    // Phase-2 per-dimension weighted fit sum
    float semantic_weight;   // Phase-2 divisor (footprint weight summed per scored dimension)
};

vec4 unpack_rgba8(uint packed) {
    return vec4(
        float((packed >> 24u) & 0xFFu) / 255.0,
        float((packed >> 16u) & 0xFFu) / 255.0,
        float((packed >>  8u) & 0xFFu) / 255.0,
        float((packed >>  0u) & 0xFFu) / 255.0
    );
}

vec4 unpack_asset_color() {
    return unpack_rgba8(uint(sample_min_pad.w));
}

// Per-asset dimension profile value for dimension d, from the two push-constant vec4s (8 slots).
float asset_profile_value(int d) {
    if (d < 4) return cfg_asset_profile0[d];
    if (d < 8) return cfg_asset_profile1[d - 4];
    return 0.0;   // >8 dims would need a per-asset profile storage buffer (not built)
}

float load_collision_r8(uint index) {
    uint word = collision_field_r8_words[index >> 2u];
    uint shift = (index & 3u) * 8u;
    return float((word >> shift) & 0xFFu) / 255.0;
}

bool runtime_profile_contract_enabled() {
    return contract_counts.x != 0;
}

int runtime_contract_object_capacity() {
    return clamp(contract_counts.y, 0, RUNTIME_CONTRACT_SCAN_CAP);
}

int runtime_contract_profile_count() {
    return clamp(contract_counts.z, 0, PROFILE_CONTRACT_SCAN_CAP);
}

int asset_profile_id() {
    return contract_counts.w;
}

uint q1000(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * 1000.0));
}

uint q1000_nonnegative(float value) {
    return uint(round(clamp(value, 0.0, 4294967.0) * 1000.0));
}

float runtime_min_distance_voxels() {
    return max(runtime_spacing_params.x, 0.0);
}

bool scene_voxel_tile_object_ref_exclusion_enabled() {
    return object_ref_counts.x != 0 && object_ref_modes.z != 0;
}

bool runtime_spacing_full_scan_debug_fallback_enabled() {
    return object_ref_modes.x != 0;
}

int scene_voxel_tile_object_ref_tile_size() {
    return max(object_ref_tile_grid.w, 1);
}

ivec3 scene_voxel_tile_object_ref_grid() {
    return max(object_ref_tile_grid.xyz, ivec3(0));
}

int scene_voxel_tile_object_ref_tile_count() {
    return max(object_ref_counts.y, 0);
}

int scene_voxel_tile_object_ref_refs_per_tile() {
    return max(object_ref_counts.z, 0);
}

int scene_voxel_tile_object_ref_capacity() {
    return max(object_ref_counts.w, 0);
}

int scene_voxel_tile_object_ref_tile_index(ivec3 tile_coord) {
    ivec3 tile_grid = scene_voxel_tile_object_ref_grid();
    return tile_coord.x + tile_grid.x * (tile_coord.z + tile_grid.z * tile_coord.y);
}

void touch_profile_side_buffers(RuntimeProfileTableRecord record) {
    uint probe_start = record.ids.z;
    uint probe_count = record.ids.w;
    uint pivot_start = record.ranges.z;
    uint pivot_count = record.ranges.w;

    atomicMax(score_contract_debug[SCORE_DEBUG_PROFILE_PROBE_COUNT], probe_count);
    atomicMax(score_contract_debug[SCORE_DEBUG_PROFILE_PIVOT_COUNT], pivot_count);

    if (probe_count > 0u && profile_side_counts.x > 0) {
        uint probe_index = min(probe_start, uint(profile_side_counts.x - 1));
        RuntimeProbeRecord probe = runtime_probe_records[probe_index];
        atomicAdd(score_contract_debug[SCORE_DEBUG_PROBE_RECORD_READS], 1u);
        atomicMax(score_contract_debug[SCORE_DEBUG_PROBE_WEIGHT_Q1000], q1000(probe.offset_weight.w));
    }

    if (pivot_count > 0u && profile_side_counts.z > 0) {
        uint pivot_index = min(pivot_start, uint(profile_side_counts.z - 1));
        RuntimePivotRecord pivot = runtime_pivot_records[pivot_index];
        atomicAdd(score_contract_debug[SCORE_DEBUG_PIVOT_RECORD_READS], 1u);
        atomicMax(score_contract_debug[SCORE_DEBUG_PIVOT_BIAS_Q1000], q1000(abs(pivot.offset_bias.w)));
    }
}

float read_asset_profile_complexity() {
    if (!runtime_profile_contract_enabled()) {
        return 0.0;
    }

    int profile_count = runtime_contract_profile_count();
    int requested_profile_id = asset_profile_id();
    for (int i = 0; i < profile_count; i++) {
        atomicAdd(score_contract_debug[SCORE_DEBUG_PROFILE_TABLE_READS], 1u);
        RuntimeProfileTableRecord record = runtime_profile_table[i];
        if (requested_profile_id <= 0 || int(record.ids.x) == requested_profile_id) {
            atomicAdd(score_contract_debug[SCORE_DEBUG_PROFILE_RECORDS_MATCHED], 1u);
            touch_profile_side_buffers(record);
            return clamp(record.color_complexity.w, 0.0, 1.0);
        }
    }
    return 0.0;
}

bool runtime_bounds_overlap_origin(ivec3 origin) {
    if (!runtime_profile_contract_enabled() || contract_modes.x == 0) {
        return false;
    }

    int capacity = runtime_contract_object_capacity();
    bool hit = false;
    for (int i = 0; i < capacity; i++) {
        atomicAdd(score_contract_debug[SCORE_DEBUG_ALIVE_OBJECT_READS], 1u);
        if (runtime_alive[i] == 0) {
            continue;
        }
        int object_profile_id = runtime_profile[i];
        atomicAdd(score_contract_debug[SCORE_DEBUG_RUNTIME_PROFILE_READS], 1u);
        if (asset_profile_id() <= 0 || object_profile_id == asset_profile_id()) {
            atomicAdd(score_contract_debug[SCORE_DEBUG_RUNTIME_PROFILE_MATCHES], 1u);
        }
        ivec3 bmin = runtime_bounds_min[i].xyz;
        ivec3 bmax = runtime_bounds_max[i].xyz;
        atomicAdd(score_contract_debug[SCORE_DEBUG_RUNTIME_OVERLAP_TESTS], 1u);
        bool inside = origin.x >= bmin.x && origin.y >= bmin.y && origin.z >= bmin.z
            && origin.x < bmax.x && origin.y < bmax.y && origin.z < bmax.z;
        if (inside) {
            atomicAdd(score_contract_debug[SCORE_DEBUG_RUNTIME_OVERLAP_HITS], 1u);
            hit = true;
        }
    }
    return hit;
}

bool runtime_same_profile_min_spacing_hit_full_scan(ivec3 origin) {
    if (!runtime_profile_contract_enabled() || contract_modes.x == 0) {
        return false;
    }

    int requested_profile_id = asset_profile_id();
    float min_distance = runtime_min_distance_voxels();
    if (requested_profile_id <= 0 || min_distance <= 0.0) {
        return false;
    }

    atomicMax(score_contract_debug[SCORE_DEBUG_RUNTIME_SPACING_MIN_DISTANCE_Q1000], q1000_nonnegative(min_distance));

    int capacity = runtime_contract_object_capacity();
    vec2 candidate_center = vec2(float(origin.x), float(origin.z));
    float min_distance_sq = min_distance * min_distance;
    bool hit = false;
    for (int i = 0; i < capacity; i++) {
        if (runtime_alive[i] == 0) {
            continue;
        }

        atomicAdd(score_contract_debug[SCORE_DEBUG_RUNTIME_SPACING_TESTS], 1u);
        int object_profile_id = runtime_profile[i];
        if (object_profile_id != requested_profile_id) {
            continue;
        }

        atomicAdd(score_contract_debug[SCORE_DEBUG_RUNTIME_SPACING_PROFILE_MATCHES], 1u);
        ivec3 bmin = runtime_bounds_min[i].xyz;
        ivec3 bmax = runtime_bounds_max[i].xyz;
        vec2 runtime_center = (vec2(float(bmin.x), float(bmin.z)) + vec2(float(bmax.x), float(bmax.z))) * 0.5;
        vec2 delta = candidate_center - runtime_center;
        if (dot(delta, delta) < min_distance_sq) {
            atomicAdd(score_contract_debug[SCORE_DEBUG_RUNTIME_SPACING_REJECTIONS], 1u);
            hit = true;
        }
    }
    return hit;
}

bool runtime_same_profile_min_spacing_hit_object_refs(ivec3 origin) {
    if (!runtime_profile_contract_enabled() || contract_modes.x == 0) {
        return false;
    }

    int requested_profile_id = asset_profile_id();
    float min_distance = runtime_min_distance_voxels();
    if (requested_profile_id <= 0 || min_distance <= 0.0) {
        return false;
    }

    ivec3 tile_grid = scene_voxel_tile_object_ref_grid();
    int tile_count = scene_voxel_tile_object_ref_tile_count();
    int refs_per_tile = scene_voxel_tile_object_ref_refs_per_tile();
    int object_ref_capacity = scene_voxel_tile_object_ref_capacity();
    int tile_size = scene_voxel_tile_object_ref_tile_size();
    if (tile_grid.x <= 0 || tile_grid.y <= 0 || tile_grid.z <= 0
            || tile_count <= 0 || refs_per_tile <= 0 || object_ref_capacity <= 0) {
        return false;
    }

    atomicMax(score_contract_debug[SCORE_DEBUG_OBJECT_REF_ENABLED], 1u);
    atomicMax(score_contract_debug[SCORE_DEBUG_RUNTIME_SPACING_MIN_DISTANCE_Q1000], q1000_nonnegative(min_distance));

    int tile_min_x = clamp(int(floor((float(origin.x) - min_distance) / float(tile_size))), 0, tile_grid.x - 1);
    int tile_max_x = clamp(int(floor((float(origin.x) + min_distance) / float(tile_size))), 0, tile_grid.x - 1);
    int tile_min_z = clamp(int(floor((float(origin.z) - min_distance) / float(tile_size))), 0, tile_grid.z - 1);
    int tile_max_z = clamp(int(floor((float(origin.z) + min_distance) / float(tile_size))), 0, tile_grid.z - 1);
    int capacity = runtime_contract_object_capacity();
    vec2 candidate_center = vec2(float(origin.x), float(origin.z));
    float min_distance_sq = min_distance * min_distance;

    for (int ty = 0; ty < tile_grid.y; ty++) {
        for (int tz = tile_min_z; tz <= tile_max_z; tz++) {
            for (int tx = tile_min_x; tx <= tile_max_x; tx++) {
                int tile_index = scene_voxel_tile_object_ref_tile_index(ivec3(tx, ty, tz));
                if (tile_index < 0 || tile_index >= tile_count) {
                    continue;
                }
                int slot_base = tile_index * refs_per_tile;
                if (slot_base < 0 || slot_base >= object_ref_capacity) {
                    continue;
                }
                atomicAdd(score_contract_debug[SCORE_DEBUG_OBJECT_REF_TILE_READS], 1u);
                for (int slot = 0; slot < refs_per_tile; slot++) {
                    int ref_index = slot_base + slot;
                    if (ref_index < 0 || ref_index >= object_ref_capacity) {
                        continue;
                    }
                    uint ref_key = scene_voxel_tile_object_refs[ref_index];
                    atomicAdd(score_contract_debug[SCORE_DEBUG_OBJECT_REF_SLOT_READS], 1u);
                    if (ref_key == 0u) {
                        continue;
                    }

                    uint object_id_u = ref_key - 1u;
                    if (object_id_u >= uint(capacity)) {
                        continue;
                    }
                    int object_id = int(object_id_u);
                    atomicAdd(score_contract_debug[SCORE_DEBUG_OBJECT_REF_OBJECT_READS], 1u);
                    if (runtime_alive[object_id] == 0) {
                        continue;
                    }

                    atomicAdd(score_contract_debug[SCORE_DEBUG_RUNTIME_SPACING_TESTS], 1u);
                    int object_profile_id = runtime_profile[object_id];
                    if (object_profile_id != requested_profile_id) {
                        continue;
                    }

                    atomicAdd(score_contract_debug[SCORE_DEBUG_RUNTIME_SPACING_PROFILE_MATCHES], 1u);
                    ivec3 bmin = runtime_bounds_min[object_id].xyz;
                    ivec3 bmax = runtime_bounds_max[object_id].xyz;
                    if (bmax.x <= bmin.x || bmax.z <= bmin.z) {
                        continue;
                    }
                    vec2 runtime_center = (vec2(float(bmin.x), float(bmin.z)) + vec2(float(bmax.x), float(bmax.z))) * 0.5;
                    vec2 delta = candidate_center - runtime_center;
                    if (dot(delta, delta) < min_distance_sq) {
                        atomicAdd(score_contract_debug[SCORE_DEBUG_RUNTIME_SPACING_REJECTIONS], 1u);
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

bool runtime_same_profile_min_spacing_hit(ivec3 origin) {
    if (scene_voxel_tile_object_ref_exclusion_enabled()) {
        return runtime_same_profile_min_spacing_hit_object_refs(origin);
    }
    if (runtime_spacing_full_scan_debug_fallback_enabled()) {
        return runtime_same_profile_min_spacing_hit_full_scan(origin);
    }
    return false;
}

void write_runtime_profile_contract_header(float profile_complexity) {
    if (!runtime_profile_contract_enabled()) {
        score_contract_debug[SCORE_DEBUG_MAGIC] = SCORE_CONTRACT_MAGIC;
        score_contract_debug[SCORE_DEBUG_ENABLED] = 0u;
        return;
    }

    score_contract_debug[SCORE_DEBUG_MAGIC] = SCORE_CONTRACT_MAGIC;
    score_contract_debug[SCORE_DEBUG_ENABLED] = 1u;
    score_contract_debug[SCORE_DEBUG_RUNTIME_OBJECT_CAPACITY] = uint(runtime_contract_object_capacity());
    score_contract_debug[SCORE_DEBUG_PROFILE_COUNT] = uint(runtime_contract_profile_count());
    score_contract_debug[SCORE_DEBUG_ASSET_PROFILE_ID] = uint(max(asset_profile_id(), 0));
    score_contract_debug[SCORE_DEBUG_PROFILE_COMPLEXITY_Q1000] = uint(round(clamp(profile_complexity, 0.0, 1.0) * 1000.0));
}

void touch_candidate_route_binding(uint group_index) {
    if (candidate_route_binding_debug[CANDIDATE_ROUTE_BINDING_ENABLED] == 0u) {
        return;
    }

    uint range_count = candidate_route_binding_debug[CANDIDATE_ROUTE_BINDING_RANGE_COUNT];
    if (range_count == 0u) {
        return;
    }

    uint range_index = min(group_index, range_count - 1u);
    uvec4 route_range = candidate_route_ranges[range_index];
    atomicAdd(candidate_route_binding_debug[CANDIDATE_ROUTE_BINDING_RANGE_READS], 1u);
    candidate_route_binding_debug[CANDIDATE_ROUTE_BINDING_FIRST_RANGE_START] = route_range.x;
    candidate_route_binding_debug[CANDIDATE_ROUTE_BINDING_FIRST_RANGE_COUNT] = route_range.y;

    if (route_range.y == 0u) {
        return;
    }

    uvec4 route_record = candidate_route_records[route_range.x];
    atomicAdd(candidate_route_binding_debug[CANDIDATE_ROUTE_BINDING_RECORD_READS], 1u);
    candidate_route_binding_debug[CANDIDATE_ROUTE_BINDING_FIRST_RECORD_X] = route_record.x;
    candidate_route_binding_debug[CANDIDATE_ROUTE_BINDING_FIRST_RECORD_Y] = route_record.y;
}

bool in_grid_bounds(ivec3 p) {
    return p.x >= 0 && p.y >= 0 && p.z >= 0
        && p.x < grid_size_tile_count.x
        && p.y < grid_size_tile_count.y
        && p.z < grid_size_tile_count.z;
}

bool in_sample_bounds(ivec3 p) {
    return p.x >= sample_min_pad.x && p.y >= sample_min_pad.y && p.z >= sample_min_pad.z
        && p.x < sample_max_pad.x && p.y < sample_max_pad.y && p.z < sample_max_pad.z;
}

int voxel_index(ivec3 p) {
    return p.x + grid_size_tile_count.x * (p.z + grid_size_tile_count.z * p.y);
}

VoxelSample sample_voxel(ivec3 p) {
    VoxelSample s;
    s.complexity = 0.0;
    s.collision = 0.0;
    s.ignored = false;

    if (!in_grid_bounds(p) || !in_sample_bounds(p)) {
        s.ignored = true;
        return s;
    }

    int i = voxel_index(p);
    s.complexity = unpack_rgba8(complexity_field_rgba8[i]).a;
    s.collision = load_collision_r8(uint(i));
    return s;
}

// --- Trilinear scene-field sampling at a FLOAT footprint position ----------
struct FieldSample {
    float complexity;
    float collision;
    float coverage; // sum of in-bounds corner weights, 0..1 (0 => fully out of bounds)
};

// Trilinear read of complexity (RGBA8 low-byte .a) and collision (R8, 4-per-word)
// at a float voxel position. Out-of-bounds corners contribute value 0 AND weight 0,
// so the blend is the average of only the in-bounds corners (not biased toward zero,
// no voxel_index wrap on an out-of-range neighbor). Each corner unpacks its OWN word
// (the 4 voxels in an R8 word are adjacent X cells, not a 2x2x2 block).
FieldSample sample_field_trilinear(vec3 pf) {
    ivec3 p0 = ivec3(floor(pf));
    vec3 t = pf - vec3(p0);
    FieldSample s;
    s.complexity = 0.0;
    s.collision = 0.0;
    s.coverage = 0.0;
    float wsum = 0.0;
    float csum = 0.0;
    float xsum = 0.0;
    for (int c = 0; c < 8; c++) {
        ivec3 off = ivec3(c & 1, (c >> 1) & 1, (c >> 2) & 1);
        ivec3 pc = p0 + off;
        float wx = off.x == 1 ? t.x : (1.0 - t.x);
        float wy = off.y == 1 ? t.y : (1.0 - t.y);
        float wz = off.z == 1 ? t.z : (1.0 - t.z);
        float w = wx * wy * wz;
        if (w <= 0.0) continue;
        if (!in_grid_bounds(pc) || !in_sample_bounds(pc)) continue;
        int i = voxel_index(pc);
        csum += unpack_rgba8(complexity_field_rgba8[i]).a * w;
        xsum += load_collision_r8(uint(i)) * w;
        wsum += w;
    }
    if (wsum > 0.0) {
        s.complexity = csum / wsum;
        s.collision = xsum / wsum;
        s.coverage = wsum;
    }
    return s;
}

// @@GEN yaw_rotation_y — generated from scripts/utils/placement_shared_glsl.gd, do not edit
// Canonical Y-yaw rotation, matching Basis(Vector3.UP, yaw):
//   rx =  ca*x + sa*z ;  rz = -sa*x + ca*z ;  y unchanged.
vec3 rotate_yaw_y(vec3 v, float ca, float sa) {
    return vec3(ca * v.x + sa * v.z, v.y, -sa * v.x + ca * v.z);
}

// Float variant for footprint offsets: rigid yaw (NO round, NO scale) so the
// sample position stays a genuine float for trilinear sampling.
vec3 rotate_footprint_offset_y_f(ivec3 fp, float ca, float sa) {
    return rotate_yaw_y(vec3(fp), ca, sa);
}

// Voxel-snapped variant for integer footprint offsets (round x/z, keep y).
ivec3 rotate_footprint_offset_y(ivec3 fp, float ca, float sa) {
    vec3 r = rotate_yaw_y(vec3(fp), ca, sa);
    return ivec3(int(round(r.x)), fp.y, int(round(r.z)));
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

EvalResult evaluate_candidate(ivec3 candidate_origin, int rot_slot, int rot_count) {
    float rot_angle = rot_count > 1 ? float(rot_slot) * 6.28318530718 / float(rot_count) : 0.0;
    float rot_ca = cos(rot_angle);
    float rot_sa = sin(rot_angle);
    EvalResult r;
    r.score = INVALID_SCORE;
    r.support_ratio = 0.0;
    r.solid_collision = 0.0;
    r.complexity_overlap = 0.0;
    r.clearance_overlap = 0.0;
    r.ignored_sample = 0.0;
    r.support_hit = 0.0;
    r.support_total = 0.0;
    r.valid = false;
    r.target_coverage = 0.0;
    r.target_complexity_fit = 0.0;
    r.target_color_dist = 0.0;
    r.target_density = 0.0;
    r.target_total_weight = 0.0;
    r.semantic_score = 0.0;
    r.semantic_weight = 0.0;

    if (!in_grid_bounds(candidate_origin)) {
        return r;
    }
    if (runtime_profile_contract_enabled()) {
        atomicAdd(score_contract_debug[SCORE_DEBUG_CANDIDATE_INVOCATIONS], 1u);
        if (runtime_bounds_overlap_origin(candidate_origin)) {
            r.clearance_overlap = thresholds.w + 1.0;
            return r;
        }
        if (runtime_same_profile_min_spacing_hit(candidate_origin)) {
            r.clearance_overlap = thresholds.w + 1.0;
            return r;
        }
    }

    int has_target = sample_max_pad.w;
    int dim_count = footprint_pivot_pad.w;          // 0 = legacy penalty-only
    int env_channel_count = cfg_dim_meta.x;
    if (has_target != 0) {
        if (!in_sample_bounds(candidate_origin)) {
            return r;
        }
        // Legacy-only origin gate: in dims-mode the per-footprint semantic fit decides, so a
        // single low-completeness origin voxel must not reject the whole candidate.
        if (dim_count == 0 && target_field[voxel_index(candidate_origin)].a <= 0.01) {
            return r;
        }
    }
    vec4 asset_col = unpack_asset_color();

    int footprint_count = min(ids_counts.x, int(FOOTPRINT_CAPACITY));
    for (int i = 0; i < footprint_count; i++) {
        ivec4 fp = s_footprint_pos_strength[i];
        vec4 wf = s_footprint_weight_flags[i];
        float weight = max(wf.x, 0.0);
        uint flags = uint(max(wf.y, 0.0) + 0.5);
        float footprint_collision_strength = clamp(float(fp.w) / 255.0, 0.0, 1.0);
        // Pivot subtracted before yaw (shift-then-rotate order): translate the footprint
        // offset by -pivot first, then apply the yaw below.
        ivec3 base_fp = fp.xyz - footprint_pivot_pad.xyz;
        // Rigid transform (translate + yaw, NO scale) of the footprint offset to a
        // FLOAT position; the scene field is TRILINEAR-sampled there. There are NO
        // integer-offset neighbor reads anywhere below.
        vec3 rotated_fp = rot_count > 1 ? rotate_footprint_offset_y_f(base_fp, rot_ca, rot_sa) : vec3(base_fp);
        vec3 pf = vec3(candidate_origin) + rotated_fp;
        ivec3 pn = ivec3(round(pf)); // nearest voxel for membership/validity predicates

        // Support is no longer scored here. The anchor/candidate stage already guarantees
        // the object rests on solid ground, so a per-voxel support re-test is redundant —
        // no FLAG_SUPPORT probes are baked (see asset_descriptor.gd) and the old
        // below-neighbor read is gone. support_ratio/hit/total stay 0.

        // Object mass (and clearance probes): trilinear field read at the float position.
        FieldSample fs = sample_field_trilinear(pf);
        if (fs.coverage <= 0.0) {
            r.ignored_sample += weight;
            continue;
        }

        if (footprint_collision_strength >= thresholds.x) {
            r.solid_collision += fs.collision * weight;
        } else {
            r.complexity_overlap += fs.complexity * footprint_collision_strength * weight;
        }

        if ((flags & FLAG_CLEARANCE) != 0u) {
            r.clearance_overlap += max(fs.complexity, fs.collision) * weight;
        }

        // Target coverage stays a discrete nearest membership (feeds a hard validity gate
        // and the fit/color divisor); read the field VALUE at the same nearest voxel.
        if (has_target != 0 && in_grid_bounds(pn) && in_sample_bounds(pn)) {
            vec4 target = target_field[voxel_index(pn)];
            float target_complexity = target.a;
            r.target_total_weight += weight;
            r.target_density += target_complexity * weight;
            if (target_complexity > 0.01) {
                r.target_coverage += weight;
                r.target_complexity_fit += abs(target_complexity - footprint_collision_strength) * weight;
                r.target_color_dist += distance(target.rgb, asset_col.rgb) * weight;
            }
        }

        // Phase-2 data-driven per-dimension scoring: piggyback on the SAME nearest voxel pn and
        // membership gate. Each dimension reads its env channel and MATCH-fits the asset profile
        // value; accumulate weighted fit (dim_count == 0 skips this entirely).
        if (dim_count > 0 && env_channel_count > 0 && in_grid_bounds(pn) && in_sample_bounds(pn)) {
            int vidx = voxel_index(pn);
            for (int d = 0; d < dim_count; d++) {
                int ch = dims[d].channel_mode_pad.x;
                if (ch < 0 || ch >= env_channel_count) continue;
                float env = env_channels[vidx * env_channel_count + ch];
                float av = asset_profile_value(d);
                int mode = dims[d].channel_mode_pad.y;
                float fit = (mode == 0) ? (1.0 - abs(env - av)) : 0.0;   // 0 = MATCH; PENALTY/GATE reserved
                fit = clamp(fit, 0.0, 1.0);
                r.semantic_score += dims[d].weight_min_max_pad.x * fit * weight;
                r.semantic_weight += weight;
            }
        }
    }

    if (dim_count > 0) {
        // Data-driven semantic score (design Phase 2): weighted mean of per-dimension MATCH fit
        // over footprint voxels. MATCH dims are unconstrained, so validity is coverage-only (the
        // has_target coverage gate is retained). target_coverage here still holds the SUMMED
        // footprint weight — the normalization block below reassigns it to a ratio AFTER this.
        // semantic_score >= 0, so it still beats INVALID_SCORE in the per-tile max-select.
        r.valid = (has_target == 0 || r.target_coverage > 0.0);
        r.score = (r.valid && r.semantic_weight > 0.0)
            ? (r.semantic_score / r.semantic_weight)
            : INVALID_SCORE;
    } else {
        // dim_count == 0: EXACT current penalty-only behavior (support retired).
        // thresholds.z and cfg_score_weights.x are reserved/zero (support retired).
        r.valid = r.solid_collision <= thresholds.y
            && r.clearance_overlap <= thresholds.w
            && (has_target == 0 || r.target_coverage > 0.0);
        if (r.valid) {
            r.score =
                - r.solid_collision * cfg_score_weights.y
                - r.complexity_overlap * cfg_score_weights.z
                - r.clearance_overlap * cfg_score_weights.w;
        }
    }

    if (r.target_total_weight > 0.0) {
        float inv_w = 1.0 / r.target_total_weight;
        r.target_density *= inv_w;
        float coverage_ratio = r.target_coverage * inv_w;
        float mean_complexity_diff = r.target_coverage > 0.0
            ? r.target_complexity_fit / r.target_coverage : 1.0;
        float mean_color_dist = r.target_coverage > 0.0
            ? r.target_color_dist / r.target_coverage : 1.0;
        r.target_coverage = coverage_ratio;
        r.target_complexity_fit = clamp(1.0 - mean_complexity_diff, 0.0, 1.0);
        r.target_color_dist = clamp(1.0 - mean_color_dist / 1.732, 0.0, 1.0);
    }

    return r;
}

EvalResult evaluate_best_at(ivec3 origin, int rot_count, out int best_slot) {
    best_slot = 0;
    EvalResult best = evaluate_candidate(origin, 0, rot_count);
    for (int s = 1; s < rot_count; s++) {
        EvalResult r = evaluate_candidate(origin, s, rot_count);
        if (r.score > best.score) {
            best = r;
            best_slot = s;
        }
    }
    return best;
}

EvalResult evaluate_best_near(ivec3 base_candidate, int rot_count, out ivec3 best_origin, out int best_slot) {
    EvalResult best_result;
    best_result.score = INVALID_SCORE;
    best_result.support_ratio = 0.0;
    best_result.solid_collision = 0.0;
    best_result.complexity_overlap = 0.0;
    best_result.clearance_overlap = 0.0;
    best_result.ignored_sample = 0.0;
    best_result.support_hit = 0.0;
    best_result.support_total = 0.0;
    best_result.valid = false;
    best_result.target_coverage = 0.0;
    best_result.target_complexity_fit = 0.0;
    best_result.target_color_dist = 0.0;
    best_result.target_density = 0.0;
    best_result.target_total_weight = 0.0;
    best_result.semantic_score = 0.0;
    best_result.semantic_weight = 0.0;
    best_origin = base_candidate;
    best_slot = 0;

    int radius_x = clamp(dispatch_search.y, 0, 4);
    int radius_y = clamp(dispatch_search.z, 0, 4);
    int radius_z = clamp(dispatch_search.w, 0, 4);
    for (int dz = -radius_z; dz <= radius_z; dz++) {
        for (int dy = -radius_y; dy <= radius_y; dy++) {
            for (int dx = -radius_x; dx <= radius_x; dx++) {
                ivec3 candidate = base_candidate + ivec3(dx, dy, dz);
                int candidate_slot;
                EvalResult r = evaluate_best_at(candidate, rot_count, candidate_slot);
                if (r.score > best_result.score) {
                    best_result = r;
                    best_origin = candidate;
                    best_slot = candidate_slot;
                }
            }
        }
    }

    return best_result;
}

void write_record(uint slot, ivec3 origin, EvalResult r, uint tile_id, int best_rotation_slot) {
    uint base = slot * RECORD_STRIDE;
    tile_topk[base + 0u] = vec4(vec3(origin), r.score);
    tile_topk[base + 1u] = vec4(float(tile_id), float(ids_counts.y), float(best_rotation_slot), float(ids_counts.w));
    tile_topk[base + 2u] = vec4(r.support_ratio, r.solid_collision, r.complexity_overlap, r.clearance_overlap);
    tile_topk[base + 3u] = vec4(r.ignored_sample, r.valid ? 1.0 : 0.0, r.support_hit, r.support_total);
}

void write_debug_voxel(ivec3 origin, EvalResult r, int best_rotation_slot) {
    if (!in_grid_bounds(origin)) return;
    uint base = uint(voxel_index(origin)) * NUM_DEBUG_CHANNELS;
    debug_voxel[base + DEBUG_CH_TARGET_COVERAGE]   = r.target_coverage;
    debug_voxel[base + DEBUG_CH_TARGET_COMPLEXITY_FIT]   = r.target_complexity_fit;
    debug_voxel[base + DEBUG_CH_TARGET_COLOR_FIT]   = r.target_color_dist;
    debug_voxel[base + DEBUG_CH_TARGET_DENSITY]     = r.target_density;
    debug_voxel[base + DEBUG_CH_PLACEMENT_SCORE]    = r.score;
    // Winning yaw slot for this voxel (only meaningful when r.valid); reuses the retired
    // support_ratio channel so the CPU reads score + rotation from this one debug buffer.
    debug_voxel[base + DEBUG_CH_BEST_ROTATION_SLOT] = r.valid ? float(best_rotation_slot) : 0.0;
    debug_voxel[base + DEBUG_CH_SOLID_COLLISION]    = r.solid_collision;
    debug_voxel[base + DEBUG_CH_CLEARANCE_OVERLAP]  = r.clearance_overlap;

    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_TARGET_COVERAGE], q1000(r.target_coverage));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_TARGET_COMPLEXITY_FIT], q1000(r.target_complexity_fit));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_TARGET_COLOR_FIT], q1000(r.target_color_dist));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_TARGET_DENSITY], q1000(r.target_density));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_PLACEMENT_SCORE], q1000(r.score));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_BEST_ROTATION_SLOT], uint(max(best_rotation_slot, 0)));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_SOLID_COLLISION], q1000(r.solid_collision));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_CLEARANCE_OVERLAP], q1000(r.clearance_overlap));
}

void main() {
    uint local_index = gl_LocalInvocationIndex;
    uint group_index = gl_WorkGroupID.x;
    uint tile_count = uint(grid_size_tile_count.w);
    bool direct_all_tiles = dispatch_search.x < 0;
    uint candidate_tile_count = direct_all_tiles
        ? uint(-dispatch_search.x)
        : uint(max(dispatch_search.x, 0));
    uint top_k = uint(tile_counts_topk.w);

    if (group_index >= candidate_tile_count) {
        return;
    }

    uint tile_id = direct_all_tiles ? group_index : candidate_tile_ids[group_index];
    if (tile_id >= tile_count) {
        return;
    }

    int footprint_count = min(ids_counts.x, int(FOOTPRINT_CAPACITY));
    if (local_index < uint(footprint_count)) {
        s_footprint_pos_strength[local_index] = footprint_pos_strength[local_index];
        s_footprint_weight_flags[local_index] = footprint_weight_flags[local_index];
    }
    if (local_index == 0u) {
        float profile_complexity = read_asset_profile_complexity();
        write_runtime_profile_contract_header(profile_complexity);
        touch_candidate_route_binding(group_index);
    }
    s_scores[local_index] = INVALID_SCORE;
    s_candidate_origins[local_index] = ivec4(0);
    barrier();

    int tile_count_x = tile_counts_topk.x;
    int tile_count_y = tile_counts_topk.y;
    int tile_x = int(tile_id % uint(tile_count_x));
    int tile_y = int((tile_id / uint(tile_count_x)) % uint(tile_count_y));
    int tile_z = int(tile_id / uint(tile_count_x * tile_count_y));

    int rot_count = max(ids_counts.z, 1);
    ivec3 tile_origin = ivec3(tile_x, tile_y, tile_z) * int(TILE_SIZE);
    ivec3 base_candidate = tile_origin + ivec3(gl_LocalInvocationID.xyz);
    ivec3 candidate_origin = base_candidate;
    int local_best_slot;
    EvalResult local_result = evaluate_best_near(base_candidate, rot_count, candidate_origin, local_best_slot);
    s_scores[local_index] = local_result.score;
    s_candidate_origins[local_index] = ivec4(candidate_origin, local_best_slot);

    int debug_slot;
    EvalResult debug_result = evaluate_best_at(base_candidate, rot_count, debug_slot);
    write_debug_voxel(base_candidate, debug_result, debug_slot);

    barrier();

    if (local_index != 0u) {
        return;
    }

    uint base_slot = group_index * top_k;
    uint selected[8];
    uint selected_count = min(top_k, 8u);

    for (uint rank = 0u; rank < selected_count; rank++) {
        float best_score = INVALID_SCORE;
        uint best_index = LOCAL_COUNT;

        for (uint i = 0u; i < LOCAL_COUNT; i++) {
            bool already_selected = false;
            ivec3 origin_i = s_candidate_origins[i].xyz;
            for (uint j = 0u; j < rank; j++) {
                if (selected[j] >= LOCAL_COUNT) {
                    continue;
                }
                already_selected = already_selected
                    || selected[j] == i
                    || s_candidate_origins[selected[j]].xyz == origin_i;
            }
            if (already_selected) {
                continue;
            }
            float candidate_score = s_scores[i];
            if (candidate_score > best_score) {
                best_score = candidate_score;
                best_index = i;
            }
        }

        // Invalid candidates carry INVALID_SCORE and never beat the best_score baseline,
        // so best_index staying unset means "no valid candidate". A valid-but-negative
        // (penalty-only) candidate is still a real winner and must NOT be rejected here.
        if (best_index >= LOCAL_COUNT) {
            EvalResult empty_result;
            empty_result.score = INVALID_SCORE;
            empty_result.support_ratio = 0.0;
            empty_result.solid_collision = 0.0;
            empty_result.complexity_overlap = 0.0;
            empty_result.clearance_overlap = 0.0;
            empty_result.ignored_sample = 0.0;
            empty_result.support_hit = 0.0;
            empty_result.support_total = 0.0;
            empty_result.valid = false;
            empty_result.target_coverage = 0.0;
            empty_result.target_complexity_fit = 0.0;
            empty_result.target_color_dist = 0.0;
            empty_result.target_density = 0.0;
            empty_result.target_total_weight = 0.0;
            empty_result.semantic_score = 0.0;
            empty_result.semantic_weight = 0.0;
            write_record(base_slot + rank, ivec3(0), empty_result, tile_id, 0);
            selected[rank] = LOCAL_COUNT;
            continue;
        }

        selected[rank] = best_index;
        ivec3 best_origin = s_candidate_origins[best_index].xyz;
        int best_rotation_slot = s_candidate_origins[best_index].w;
        EvalResult best_result = evaluate_candidate(best_origin, best_rotation_slot, rot_count);
        write_record(base_slot + rank, best_origin, best_result, tile_id, best_rotation_slot);
    }
}
