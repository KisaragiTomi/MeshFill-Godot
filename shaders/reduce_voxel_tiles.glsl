#[compute]
#version 450

// Serial global reducer for the first 3D voxel placement prototype.
// It scans TileTopKBuffer, applies distance deduplication, and writes a compact
// PlacementResultBuffer with the same 4-vec4 record layout.

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TileTopK {
    vec4 tile_topk[];
};

layout(set = 0, binding = 1, std430) restrict buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 2, std430) restrict buffer ResultCount {
    uint result_count;
};

layout(push_constant, std430) uniform Params {
    ivec4 counts;       // candidate_count, result_capacity, record_stride, _pad
    vec4 params;        // min_distance_voxels, _pad, _pad, _pad
};

const uint RECORD_STRIDE = 4u;
// Sentinel below any real penalty-only score, so the max-select baseline never beats a
// valid candidate. Mirrors INVALID_SCORE in score_voxel_tile.glsl (scores are now <= 0).
const float INVALID_SCORE = -1.0e18;

float result_distance(uint result_index, vec3 candidate_origin) {
    vec3 selected_origin = placement_results[result_index * RECORD_STRIDE + 0u].xyz;
    return distance(selected_origin, candidate_origin);
}

void write_empty(uint out_index) {
    uint base = out_index * RECORD_STRIDE;
    placement_results[base + 0u] = vec4(0.0, 0.0, 0.0, -1.0);
    placement_results[base + 1u] = vec4(0.0);
    placement_results[base + 2u] = vec4(0.0);
    placement_results[base + 3u] = vec4(0.0);
}

void main() {
    uint candidate_count = uint(max(counts.x, 0));
    uint result_capacity = uint(max(counts.y, 0));
    float min_distance_voxels = max(params.x, 0.0);

    result_count = 0u;

    for (uint out_index = 0u; out_index < result_capacity; out_index++) {
        float best_score = INVALID_SCORE;
        uint best_candidate = candidate_count;

        for (uint candidate_index = 0u; candidate_index < candidate_count; candidate_index++) {
            uint base = candidate_index * RECORD_STRIDE;
            vec4 pose = tile_topk[base + 0u];
            vec4 debug1 = tile_topk[base + 3u];
            // Gate on the valid flag only. The score (pose.w) is penalty-only now
            // (<= 0 for valid placements), so a "pose.w < 0.0" test would wrongly drop
            // every real placement that overlaps anything. Empty/invalid records carry
            // debug1.y == 0 (see score_voxel_tile.glsl record layout).
            if (debug1.y < 0.5) {
                continue;
            }

            bool too_close = false;
            for (uint selected = 0u; selected < result_count; selected++) {
                if (result_distance(selected, pose.xyz) < min_distance_voxels) {
                    too_close = true;
                    break;
                }
            }
            if (too_close) {
                continue;
            }

            if (pose.w > best_score) {
                best_score = pose.w;
                best_candidate = candidate_index;
            }
        }

        if (best_candidate >= candidate_count) {
            write_empty(out_index);
            continue;
        }

        uint src_base = best_candidate * RECORD_STRIDE;
        uint dst_base = out_index * RECORD_STRIDE;
        placement_results[dst_base + 0u] = tile_topk[src_base + 0u];
        placement_results[dst_base + 1u] = tile_topk[src_base + 1u];
        placement_results[dst_base + 2u] = tile_topk[src_base + 2u];
        placement_results[dst_base + 3u] = tile_topk[src_base + 3u];
        result_count++;
    }
}
