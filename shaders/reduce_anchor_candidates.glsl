#[compute]
#version 450

// Common-pool candidate reduce (replaces the per-asset reduce_voxel_tiles.glsl).
//
// All assets' fine candidates compete in ONE pool: greedy serial max-select by
// residual gain with
//   - valid-flag gate (validity already includes the score_gain > threshold
//     no-op baseline, physical collision/clearance limits and target coverage),
//   - per-asset quota from asset_lookup[asset].z (<= 0 means unlimited),
//   - same-origin rejection + min-distance conflict resolution against every
//     already selected result (3D Euclidean, voxel coords).
// candidate_count derives from the GPU-resident anchor count (clamped against
// the overshooting collect counter) — no CPU readback.
//
// Input/output records share the 4-vec4 (64 B) fine candidate layout:
//   [0] origin.xyz, residual gain
//   [1] anchor_id, asset_index, yaw_slot, global_pivot_index
//   [2] solid_collision, loss_before_mean, loss_after_mean, clearance_overlap
//   [3] profile_index, valid, coarse probe score, reserved
// Real results are compacted at [0, result_count); empty slots carry gain -1
// and valid 0.

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FineCandidates {
    vec4 fine_candidates[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer AssetLookup {
    ivec4 asset_lookup[]; // x=profile_id, y=profile_index, z=quota, w=object_type
};

layout(set = 0, binding = 3, std430) restrict buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 4, std430) restrict buffer ResultCount {
    uint result_count;
};

layout(push_constant, std430) uniform Params {
    ivec4 counts;   // topk, result_capacity, asset_count, anchor_capacity
    vec4 params;    // min_distance_voxels, reserved x3
};

const uint RECORD_STRIDE = 4u;
const uint MAX_ASSETS = 256u;

void write_empty(uint out_index) {
    uint base = out_index * RECORD_STRIDE;
    placement_results[base + 0u] = vec4(0.0, 0.0, 0.0, -1.0);
    placement_results[base + 1u] = vec4(0.0);
    placement_results[base + 2u] = vec4(0.0);
    placement_results[base + 3u] = vec4(0.0);
}

void main() {
    uint topk = uint(max(counts.x, 1));
    uint result_capacity = uint(max(counts.y, 0));
    uint asset_count = min(uint(max(counts.z, 0)), MAX_ASSETS);
    uint anchor_count = min(anchor_count_dyn[0], uint(max(counts.w, 0)));
    uint candidate_count = anchor_count * topk;
    float min_distance = max(params.x, 0.0);
    float min_distance_sq = min_distance * min_distance;

    uint placed_per_asset[MAX_ASSETS];
    for (uint a = 0u; a < asset_count; a++) {
        placed_per_asset[a] = 0u;
    }

    result_count = 0u;
    for (uint out_index = 0u; out_index < result_capacity; out_index++) {
        float best_score = -1.0e30;
        uint best_index = 0xFFFFFFFFu;

        for (uint c = 0u; c < candidate_count; c++) {
            uint base = c * RECORD_STRIDE;
            if (fine_candidates[base + 3u].y < 0.5) {
                continue; // valid-flag gate (includes the no-op baseline)
            }
            float score = fine_candidates[base + 0u].w;
            if (best_index != 0xFFFFFFFFu && score <= best_score) {
                continue;
            }
            uint asset = uint(max(int(round(fine_candidates[base + 1u].y)), 0));
            if (asset < asset_count) {
                int quota = asset_lookup[asset].z;
                if (quota > 0 && placed_per_asset[asset] >= uint(quota)) {
                    continue;
                }
            }
            vec3 origin = fine_candidates[base + 0u].xyz;
            bool conflicts = false;
            for (uint s = 0u; s < result_count; s++) {
                vec3 selected = placement_results[s * RECORD_STRIDE + 0u].xyz;
                vec3 delta = origin - selected;
                float dist_sq = dot(delta, delta);
                if (dist_sq < min_distance_sq || dist_sq < 0.25) {
                    conflicts = true; // min-distance or same-voxel origin
                    break;
                }
            }
            if (conflicts) {
                continue;
            }
            best_score = score;
            best_index = c;
        }

        if (best_index == 0xFFFFFFFFu) {
            write_empty(out_index);
            continue;
        }

        uint src = best_index * RECORD_STRIDE;
        uint dst = result_count * RECORD_STRIDE;
        placement_results[dst + 0u] = fine_candidates[src + 0u];
        placement_results[dst + 1u] = fine_candidates[src + 1u];
        placement_results[dst + 2u] = fine_candidates[src + 2u];
        placement_results[dst + 3u] = fine_candidates[src + 3u];
        uint asset = uint(max(int(round(fine_candidates[src + 1u].y)), 0));
        if (asset < asset_count) {
            placed_per_asset[asset] += 1u;
        }
        result_count += 1u;
    }
}
