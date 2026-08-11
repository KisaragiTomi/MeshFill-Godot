#[compute]
#version 450

// Deterministic terminal compaction for the one-pass atomic Anchor Reduce.
// Conflict priority is random-key based; Anchor ID order here only defines the
// deterministic cut at per-asset quota and result-capacity boundaries.

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FineCandidates {
    vec4 fine_candidates[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer AnchorCandidateRef {
    uint anchor_candidate_ref[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer AnchorValid {
    uint anchor_valid[];
};

layout(set = 0, binding = 4, std430) restrict readonly buffer AssetLookup {
    ivec4 asset_lookup[]; // x=profile_id, y=profile_index, z=quota, w=object_type
};

layout(set = 0, binding = 5, std430) restrict buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 6, std430) restrict buffer ResultCount {
    uint result_count;
};

layout(push_constant, std430) uniform Params {
    ivec4 counts; // anchor_capacity, result_capacity, asset_count, unused
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
    uint anchor_count = min(anchor_count_dyn[0], uint(max(counts.x, 0)));
    uint result_capacity = uint(max(counts.y, 0));
    uint asset_count = min(uint(max(counts.z, 0)), MAX_ASSETS);
    uint placed_per_asset[MAX_ASSETS];
    for (uint asset = 0u; asset < asset_count; asset++) {
        placed_per_asset[asset] = 0u;
    }

    uint selected = 0u;
    for (uint anchor = 0u; anchor < anchor_count && selected < result_capacity; anchor++) {
        uint candidate_ref = anchor_candidate_ref[anchor];
        if (candidate_ref == 0u || anchor_valid[anchor] == 0u) {
            continue;
        }
        uint src = (candidate_ref - 1u) * RECORD_STRIDE;
        uint asset = uint(max(int(round(fine_candidates[src + 1u].y)), 0));
        if (asset < asset_count) {
            int quota = asset_lookup[asset].z;
            if (quota > 0 && placed_per_asset[asset] >= uint(quota)) {
                continue;
            }
            placed_per_asset[asset] += 1u;
        }
        uint dst = selected * RECORD_STRIDE;
        placement_results[dst + 0u] = fine_candidates[src + 0u];
        placement_results[dst + 1u] = fine_candidates[src + 1u];
        placement_results[dst + 2u] = fine_candidates[src + 2u];
        placement_results[dst + 3u] = fine_candidates[src + 3u];
        selected += 1u;
    }

    result_count = selected;
    for (uint out_index = selected; out_index < result_capacity; out_index++) {
        write_empty(out_index);
    }
}
