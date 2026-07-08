#[compute]
#version 450

// Pass B — Per-anchor top-K asset selection.
//
// Workgroup (16, 16, 1) → 256 threads = one per asset slot.
// Dispatch: (anchor_grid_x, anchor_grid_y, 1)
//
// Reads asset_scores from Pass A, picks top TOPK assets per anchor.
// Output: anchor_topk[anchor_id * TOPK + k] = uvec2(asset_id, floatBitsToUint(score))

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ScoresIn {
    float asset_scores[];
};

// Output: packed (asset_id, score_bits)
layout(set = 0, binding = 1, std430) restrict writeonly buffer TopKOut {
    uvec2 anchor_topk[];
};

// GPU-resident anchor count (written by collect_sv_anchors, no CPU readback).
layout(set = 0, binding = 2, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(push_constant, std430) uniform Params {
    uint  _unused_anchor_count;  // anchor count now read from AnchorCountBuf
    uint  asset_count;
    uint  anchor_grid_x;
    float min_prefilter_score;
};

const uint MAX_ASSETS = 256u;
const uint TOPK = 4u;

shared vec2 shared_scores[256];  // x = score, y = asset_id

void main() {
    uint anchor_id = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x;
    uint tid = gl_LocalInvocationID.y * 16u + gl_LocalInvocationID.x;
    uint asset_count_clamped = min(asset_count, MAX_ASSETS);
    uint anchor_count = anchor_count_dyn[0];

    float score = -1.0;
    if (anchor_id < anchor_count && tid < asset_count_clamped) {
        score = asset_scores[anchor_id * MAX_ASSETS + tid];
        if (score < min_prefilter_score) {
            score = -1.0;
        }
    }
    shared_scores[tid] = vec2(score, float(tid));
    barrier();

    // Thread 0 performs serial top-K selection
    if (tid == 0u && anchor_id < anchor_count) {
        for (uint k = 0u; k < TOPK; k++) {
            float best = -1.0;
            uint best_id = 0xFFFFFFFFu;

            for (uint j = 0u; j < asset_count_clamped; j++) {
                if (shared_scores[j].x > best) {
                    best = shared_scores[j].x;
                    best_id = uint(shared_scores[j].y);
                }
            }

            if (best_id == 0xFFFFFFFFu || best < 0.0) {
                anchor_topk[anchor_id * TOPK + k] = uvec2(0xFFFFFFFFu, floatBitsToUint(-1.0));
            } else {
                anchor_topk[anchor_id * TOPK + k] = uvec2(best_id, floatBitsToUint(best));
                shared_scores[best_id].x = -2.0;  // mark as taken
            }
        }
    }
}
