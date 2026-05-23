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
//   1: target_value_fit  — 1 − mean |target − degree|, higher = better
//   2: target_color_fit  — 1 − mean RGB distance to asset_color, higher = better
//   3: target_density    — average target value under footprint
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
    ivec4 footprint_pos_degree[];
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
const uint DEBUG_CH_TARGET_VALUE_FIT  = 1u;
const uint DEBUG_CH_TARGET_COLOR_FIT  = 2u;
const uint DEBUG_CH_TARGET_DENSITY    = 3u;
const uint DEBUG_CH_PLACEMENT_SCORE   = 4u;
const uint DEBUG_CH_SUPPORT_RATIO     = 5u;
const uint DEBUG_CH_SOLID_COLLISION   = 6u;
const uint DEBUG_CH_CLEARANCE_OVERLAP = 7u;

shared ivec4 s_footprint_pos_degree[128];
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
    float target_value_fit;
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
    r.target_value_fit = 0.0;
    r.target_color_dist = 0.0;
    r.target_density = 0.0;
    r.target_total_weight = 0.0;

    if (!in_grid_bounds(candidate_origin)) {
        return r;
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
        ivec4 fp = s_footprint_pos_degree[i];
        vec4 wf = s_footprint_weight_flags[i];
        float weight = max(wf.x, 0.0);
        uint flags = uint(max(wf.y, 0.0) + 0.5);
        float degree = clamp(float(fp.w) / 255.0, 0.0, 1.0);
        ivec3 p = candidate_origin + fp.xyz;

        VoxelSample voxel_sample = sample_voxel(p);
        if (voxel_sample.ignored) {
            r.ignored_sample += weight;
            continue;
        }

        if (degree >= thresholds.x) {
            r.solid_collision += voxel_sample.collision * weight;
        } else {
            r.scene_overlap += voxel_sample.scene * degree * weight;
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
            float target_val = target_occupancy[idx];
            r.target_total_weight += weight;
            r.target_density += target_val * weight;
            if (target_val > 0.01) {
                r.target_coverage += weight;
                r.target_value_fit += abs(target_val - degree) * weight;
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
        float mean_val_diff = r.target_coverage > 0.0
            ? r.target_value_fit / r.target_coverage : 1.0;
        float mean_color_dist = r.target_coverage > 0.0
            ? r.target_color_dist / r.target_coverage : 1.0;
        r.target_coverage = coverage_ratio;
        r.target_value_fit = clamp(1.0 - mean_val_diff, 0.0, 1.0);
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
    best_result.target_value_fit = 0.0;
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
    debug_voxel[base + DEBUG_CH_TARGET_VALUE_FIT]   = r.target_value_fit;
    debug_voxel[base + DEBUG_CH_TARGET_COLOR_FIT]   = r.target_color_dist;
    debug_voxel[base + DEBUG_CH_TARGET_DENSITY]     = r.target_density;
    debug_voxel[base + DEBUG_CH_PLACEMENT_SCORE]    = r.score;
    debug_voxel[base + DEBUG_CH_SUPPORT_RATIO]      = r.support_ratio;
    debug_voxel[base + DEBUG_CH_SOLID_COLLISION]    = r.solid_collision;
    debug_voxel[base + DEBUG_CH_CLEARANCE_OVERLAP]  = r.clearance_overlap;
}

void main() {
    uint local_index = gl_LocalInvocationIndex;
    uint group_index = gl_WorkGroupID.x;
    uint tile_count = uint(grid_size_tile_count.w);
    uint candidate_voxel_sparse_count = uint(max(dispatch_search.x, 0));
    uint top_k = uint(tile_counts_topk.w);

    if (group_index >= candidate_voxel_sparse_count) {
        return;
    }

    uint tile_id = candidate_voxel_sparse_ids[group_index];
    if (tile_id >= tile_count) {
        return;
    }

    int footprint_count = min(ids_counts.x, int(FOOTPRINT_CAPACITY));
    if (local_index < uint(footprint_count)) {
        s_footprint_pos_degree[local_index] = footprint_pos_degree[local_index];
        s_footprint_weight_flags[local_index] = footprint_weight_flags[local_index];
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
            empty_result.target_value_fit = 0.0;
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
