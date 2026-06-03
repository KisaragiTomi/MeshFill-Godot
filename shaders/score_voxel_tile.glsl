#[compute]
#version 450

// Scores candidate object origins inside 8x8x8 voxel tiles.
// One workgroup owns one origin tile; each invocation evaluates one candidate.
// Output is TileTopKBuffer, encoded as 4 vec4 records per candidate:
//   0: vec4(voxel_origin.xyz, score)
//   1: vec4(tile_id, asset_index, rotation_index, scale_index)
//   2: vec4(support_ratio, solid_collision, scene_overlap, clearance_overlap)
//   3: vec4(ignored_sample, valid, support_hit, support_total)
//
// DebugVoxelOutput: NUM_DEBUG_CHANNELS floats per voxel for visualization.
// Channel layout:
//   0: target_coverage   — weighted fraction of footprint overlapping target
//   1: target_complexity_fit  — 1 − mean |target complexity - collision strength|, higher = better
//   2: target_color_fit  — 1 − mean RGB distance to asset_color, higher = better
//   3: target_density    — average target complexity under footprint
//   4: placement_score   — final candidate score
//   5: support_ratio
//   6: solid_collision
//   7: clearance_overlap

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SceneField {
    float scene_field[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionField {
    float collision_field[];
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
    uint candidate_voxel_sparse_ids[];
};

layout(set = 0, binding = 6, std430) restrict readonly buffer TargetOccupancy {
    float target_occupancy[];
};

layout(set = 0, binding = 7, std430) restrict readonly buffer TargetColor {
    uint target_color[];
};

layout(set = 0, binding = 8, std430) restrict buffer DebugVoxelOutput {
    float debug_voxel[];
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

struct RuntimeCollisionRecord {
    uvec4 meta;
    vec4 center_radius;
    vec4 size_y_min;
    vec4 y_max_erosion_dilation_strength;
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
    ivec4 contract_modes;  // runtime avoidance, profile complexity debug, reserved, reserved
    ivec4 profile_side_counts; // probe records, collision records, pivot records, reserved
    vec4 runtime_spacing_params; // min_distance_voxels, reserved, reserved, reserved
};

layout(set = 1, binding = 8, std430) restrict buffer ScoreRuntimeProfileDebug {
    uint score_contract_debug[];
};

layout(set = 1, binding = 9, std430) restrict readonly buffer RuntimeProbeRecords {
    RuntimeProbeRecord runtime_probe_records[];
};

layout(set = 1, binding = 10, std430) restrict readonly buffer RuntimeCollisionRecords {
    RuntimeCollisionRecord runtime_collision_records[];
};

layout(set = 1, binding = 11, std430) restrict readonly buffer RuntimePivotRecords {
    RuntimePivotRecord runtime_pivot_records[];
};

layout(set = 2, binding = 0, std430) restrict readonly buffer CandidateRouteRecords {
    uvec4 candidate_route_records[];
};

layout(set = 2, binding = 1, std430) restrict readonly buffer CandidateRouteRanges {
    uvec4 candidate_route_ranges[];
};

layout(set = 2, binding = 2, std430) restrict buffer CandidateRouteBindingDebug {
    uint candidate_route_binding_debug[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_tile_count;    // x, y, z, total tile count
    ivec4 tile_counts_topk;        // tile_count_x, tile_count_y, tile_count_z, top_k
    ivec4 sample_min_pad;          // sample min xyz, .w = packed asset color (RGBA8)
    ivec4 sample_max_pad;          // sample max xyz exclusive, .w = has_target (0/1)
    ivec4 ids_counts;              // footprint_count, asset_index, rotation_index, scale_index
    vec4 thresholds;               // solid_threshold, collision_limit, min_support_ratio, clearance_limit
    vec4 score_weights;            // support_weight, collision_penalty, overlap_penalty, clearance_penalty
    ivec4 dispatch_search;         // candidate_voxel_sparse_count, search radius xyz
};

const uint FLAG_SUPPORT = 1u;
const uint FLAG_CLEARANCE = 2u;
const uint TILE_SIZE = 8u;
const uint LOCAL_COUNT = 512u;
const uint FOOTPRINT_CAPACITY = 128u;
const uint RECORD_STRIDE = 4u;
const uint NUM_DEBUG_CHANNELS = 8u;
const uint DEBUG_CH_TARGET_COVERAGE   = 0u;
const uint DEBUG_CH_TARGET_COMPLEXITY_FIT  = 1u;
const uint DEBUG_CH_TARGET_COLOR_FIT  = 2u;
const uint DEBUG_CH_TARGET_DENSITY    = 3u;
const uint DEBUG_CH_PLACEMENT_SCORE   = 4u;
const uint DEBUG_CH_SUPPORT_RATIO     = 5u;
const uint DEBUG_CH_SOLID_COLLISION   = 6u;
const uint DEBUG_CH_CLEARANCE_OVERLAP = 7u;
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
const uint SCORE_DEBUG_COLLISION_RECORD_READS = 15u;
const uint SCORE_DEBUG_PIVOT_RECORD_READS = 16u;
const uint SCORE_DEBUG_PROBE_WEIGHT_Q1000 = 17u;
const uint SCORE_DEBUG_COLLISION_STRENGTH_Q1000 = 18u;
const uint SCORE_DEBUG_PIVOT_BIAS_Q1000 = 19u;
const uint SCORE_DEBUG_PROFILE_PROBE_COUNT = 20u;
const uint SCORE_DEBUG_PROFILE_COLLISION_COUNT = 21u;
const uint SCORE_DEBUG_PROFILE_PIVOT_COUNT = 22u;
const uint SCORE_DEBUG_DEBUG_MAX_BASE = 23u;
const uint SCORE_DEBUG_RUNTIME_SPACING_TESTS = 31u;
const uint SCORE_DEBUG_RUNTIME_SPACING_PROFILE_MATCHES = 32u;
const uint SCORE_DEBUG_RUNTIME_SPACING_REJECTIONS = 33u;
const uint SCORE_DEBUG_RUNTIME_SPACING_MIN_DISTANCE_Q1000 = 34u;
const int RUNTIME_CONTRACT_SCAN_CAP = 4096;
const int PROFILE_CONTRACT_SCAN_CAP = 1024;

shared ivec4 s_footprint_pos_strength[128];
shared vec4 s_footprint_weight_flags[128];
shared float s_scores[512];
shared ivec4 s_candidate_origins[512];

struct VoxelSample {
    float scene;
    float collision;
    bool ignored;
};

struct EvalResult {
    float score;
    float support_ratio;
    float solid_collision;
    float scene_overlap;
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

void touch_profile_side_buffers(RuntimeProfileTableRecord record) {
    uint probe_start = record.ids.z;
    uint probe_count = record.ids.w;
    uint collision_start = record.ranges.x;
    uint collision_count = record.ranges.y;
    uint pivot_start = record.ranges.z;
    uint pivot_count = record.ranges.w;

    atomicMax(score_contract_debug[SCORE_DEBUG_PROFILE_PROBE_COUNT], probe_count);
    atomicMax(score_contract_debug[SCORE_DEBUG_PROFILE_COLLISION_COUNT], collision_count);
    atomicMax(score_contract_debug[SCORE_DEBUG_PROFILE_PIVOT_COUNT], pivot_count);

    if (probe_count > 0u && profile_side_counts.x > 0) {
        uint probe_index = min(probe_start, uint(profile_side_counts.x - 1));
        RuntimeProbeRecord probe = runtime_probe_records[probe_index];
        atomicAdd(score_contract_debug[SCORE_DEBUG_PROBE_RECORD_READS], 1u);
        atomicMax(score_contract_debug[SCORE_DEBUG_PROBE_WEIGHT_Q1000], q1000(probe.offset_weight.w));
    }

    if (collision_count > 0u && profile_side_counts.y > 0) {
        uint collision_index = min(collision_start, uint(profile_side_counts.y - 1));
        RuntimeCollisionRecord collision = runtime_collision_records[collision_index];
        atomicAdd(score_contract_debug[SCORE_DEBUG_COLLISION_RECORD_READS], 1u);
        atomicMax(score_contract_debug[SCORE_DEBUG_COLLISION_STRENGTH_Q1000], q1000(collision.y_max_erosion_dilation_strength.w));
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

bool runtime_same_profile_min_spacing_hit(ivec3 origin) {
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
    if (candidate_route_binding_debug[0] == 0u) {
        return;
    }

    uint range_count = candidate_route_binding_debug[1];
    if (range_count == 0u) {
        return;
    }

    uint range_index = min(group_index, range_count - 1u);
    uvec4 route_range = candidate_route_ranges[range_index];
    atomicAdd(candidate_route_binding_debug[2], 1u);
    candidate_route_binding_debug[4] = route_range.x;
    candidate_route_binding_debug[5] = route_range.y;

    if (route_range.y == 0u) {
        return;
    }

    uvec4 route_record = candidate_route_records[route_range.x];
    atomicAdd(candidate_route_binding_debug[3], 1u);
    candidate_route_binding_debug[6] = route_record.x;
    candidate_route_binding_debug[7] = route_record.y;
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
    s.scene = 0.0;
    s.collision = 0.0;
    s.ignored = false;

    if (!in_grid_bounds(p) || !in_sample_bounds(p)) {
        s.ignored = true;
        return s;
    }

    int i = voxel_index(p);
    s.scene = scene_field[i];
    s.collision = collision_field[i];
    return s;
}

EvalResult evaluate_candidate(ivec3 candidate_origin) {
    EvalResult r;
    r.score = -1.0;
    r.support_ratio = 0.0;
    r.solid_collision = 0.0;
    r.scene_overlap = 0.0;
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
    if (has_target != 0) {
        if (!in_sample_bounds(candidate_origin)) {
            return r;
        }
        if (target_occupancy[voxel_index(candidate_origin)] <= 0.01) {
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
        ivec3 p = candidate_origin + fp.xyz;

        VoxelSample voxel_sample = sample_voxel(p);
        if (voxel_sample.ignored) {
            r.ignored_sample += weight;
            continue;
        }

        if (footprint_collision_strength >= thresholds.x) {
            r.solid_collision += voxel_sample.collision * weight;
        } else {
            r.scene_overlap += voxel_sample.scene * footprint_collision_strength * weight;
        }

        if ((flags & FLAG_CLEARANCE) != 0u) {
            r.clearance_overlap += max(voxel_sample.scene, voxel_sample.collision) * weight;
        }

        if ((flags & FLAG_SUPPORT) != 0u) {
            VoxelSample below = sample_voxel(p + ivec3(0, -1, 0));
            if (!below.ignored) {
                r.support_total += weight;
                r.support_hit += step(0.01, max(below.scene, below.collision)) * weight;
            } else {
                r.ignored_sample += weight;
            }
        }

        if (has_target != 0 && in_grid_bounds(p) && in_sample_bounds(p)) {
            int idx = voxel_index(p);
            float target_complexity = target_occupancy[idx];
            r.target_total_weight += weight;
            r.target_density += target_complexity * weight;
            if (target_complexity > 0.01) {
                r.target_coverage += weight;
                r.target_complexity_fit += abs(target_complexity - footprint_collision_strength) * weight;
                vec4 tc = unpack_rgba8(target_color[idx]);
                r.target_color_dist += distance(tc.rgb, asset_col.rgb) * weight;
            }
        }
    }

    r.support_ratio = r.support_total > 0.0 ? r.support_hit / r.support_total : 0.0;
    r.valid = r.solid_collision <= thresholds.y
        && r.support_ratio >= thresholds.z
        && r.clearance_overlap <= thresholds.w
        && (has_target == 0 || r.target_coverage > 0.0);

    if (r.valid) {
        r.score =
            r.support_ratio * score_weights.x
            - r.solid_collision * score_weights.y
            - r.scene_overlap * score_weights.z
            - r.clearance_overlap * score_weights.w;
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

EvalResult evaluate_best_near(ivec3 base_candidate, out ivec3 best_origin) {
    EvalResult best_result;
    best_result.score = -1.0;
    best_result.support_ratio = 0.0;
    best_result.solid_collision = 0.0;
    best_result.scene_overlap = 0.0;
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
    best_origin = base_candidate;

    int radius_x = clamp(dispatch_search.y, 0, 4);
    int radius_y = clamp(dispatch_search.z, 0, 4);
    int radius_z = clamp(dispatch_search.w, 0, 4);
    for (int dz = -radius_z; dz <= radius_z; dz++) {
        for (int dy = -radius_y; dy <= radius_y; dy++) {
            for (int dx = -radius_x; dx <= radius_x; dx++) {
                ivec3 candidate = base_candidate + ivec3(dx, dy, dz);
                EvalResult r = evaluate_candidate(candidate);
                if (r.score > best_result.score) {
                    best_result = r;
                    best_origin = candidate;
                }
            }
        }
    }

    return best_result;
}

void write_record(uint slot, ivec3 origin, EvalResult r, uint tile_id) {
    uint base = slot * RECORD_STRIDE;
    tile_topk[base + 0u] = vec4(vec3(origin), r.score);
    tile_topk[base + 1u] = vec4(float(tile_id), float(ids_counts.y), float(ids_counts.z), float(ids_counts.w));
    tile_topk[base + 2u] = vec4(r.support_ratio, r.solid_collision, r.scene_overlap, r.clearance_overlap);
    tile_topk[base + 3u] = vec4(r.ignored_sample, r.valid ? 1.0 : 0.0, r.support_hit, r.support_total);
}

void write_debug_voxel(ivec3 origin, EvalResult r) {
    if (!in_grid_bounds(origin)) return;
    uint base = uint(voxel_index(origin)) * NUM_DEBUG_CHANNELS;
    debug_voxel[base + DEBUG_CH_TARGET_COVERAGE]   = r.target_coverage;
    debug_voxel[base + DEBUG_CH_TARGET_COMPLEXITY_FIT]   = r.target_complexity_fit;
    debug_voxel[base + DEBUG_CH_TARGET_COLOR_FIT]   = r.target_color_dist;
    debug_voxel[base + DEBUG_CH_TARGET_DENSITY]     = r.target_density;
    debug_voxel[base + DEBUG_CH_PLACEMENT_SCORE]    = r.score;
    debug_voxel[base + DEBUG_CH_SUPPORT_RATIO]      = r.support_ratio;
    debug_voxel[base + DEBUG_CH_SOLID_COLLISION]    = r.solid_collision;
    debug_voxel[base + DEBUG_CH_CLEARANCE_OVERLAP]  = r.clearance_overlap;

    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_TARGET_COVERAGE], q1000(r.target_coverage));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_TARGET_COMPLEXITY_FIT], q1000(r.target_complexity_fit));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_TARGET_COLOR_FIT], q1000(r.target_color_dist));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_TARGET_DENSITY], q1000(r.target_density));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_PLACEMENT_SCORE], q1000(r.score));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_SUPPORT_RATIO], q1000(r.support_ratio));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_SOLID_COLLISION], q1000(r.solid_collision));
    atomicMax(score_contract_debug[SCORE_DEBUG_DEBUG_MAX_BASE + DEBUG_CH_CLEARANCE_OVERLAP], q1000(r.clearance_overlap));
}

void main() {
    uint local_index = gl_LocalInvocationIndex;
    uint group_index = gl_WorkGroupID.x;
    uint tile_count = uint(grid_size_tile_count.w);
    bool direct_all_tiles = dispatch_search.x < 0;
    uint candidate_voxel_sparse_count = direct_all_tiles
        ? uint(-dispatch_search.x)
        : uint(max(dispatch_search.x, 0));
    uint top_k = uint(tile_counts_topk.w);

    if (group_index >= candidate_voxel_sparse_count) {
        return;
    }

    uint tile_id = direct_all_tiles ? group_index : candidate_voxel_sparse_ids[group_index];
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
    s_scores[local_index] = -1.0;
    s_candidate_origins[local_index] = ivec4(0);
    barrier();

    int tile_count_x = tile_counts_topk.x;
    int tile_count_y = tile_counts_topk.y;
    int tile_x = int(tile_id % uint(tile_count_x));
    int tile_y = int((tile_id / uint(tile_count_x)) % uint(tile_count_y));
    int tile_z = int(tile_id / uint(tile_count_x * tile_count_y));

    ivec3 tile_origin = ivec3(tile_x, tile_y, tile_z) * int(TILE_SIZE);
    ivec3 base_candidate = tile_origin + ivec3(gl_LocalInvocationID.xyz);
    ivec3 candidate_origin = base_candidate;
    EvalResult local_result = evaluate_best_near(base_candidate, candidate_origin);
    s_scores[local_index] = local_result.score;
    s_candidate_origins[local_index] = ivec4(candidate_origin, 0);

    write_debug_voxel(base_candidate, evaluate_candidate(base_candidate));

    barrier();

    if (local_index != 0u) {
        return;
    }

    uint base_slot = group_index * top_k;
    uint selected[8];
    uint selected_count = min(top_k, 8u);

    for (uint rank = 0u; rank < selected_count; rank++) {
        float best_score = -1.0;
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

        if (best_index >= LOCAL_COUNT || best_score < 0.0) {
            EvalResult empty_result;
            empty_result.score = -1.0;
            empty_result.support_ratio = 0.0;
            empty_result.solid_collision = 0.0;
            empty_result.scene_overlap = 0.0;
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
            write_record(base_slot + rank, ivec3(0), empty_result, tile_id);
            selected[rank] = LOCAL_COUNT;
            continue;
        }

        selected[rank] = best_index;
        ivec3 best_origin = s_candidate_origins[best_index].xyz;
        EvalResult best_result = evaluate_candidate(best_origin);
        write_record(base_slot + rank, best_origin, best_result, tile_id);
    }
}
