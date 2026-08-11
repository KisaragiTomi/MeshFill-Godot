#[compute]
#version 450

// Select the highest-scoring valid Fine candidate for each live Anchor. This
// is the Score-only readback surface: one 64-byte record per Anchor instead of
// the full Anchor x top-K candidate pool. Equal scores keep the smaller k.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FineCandidates {
    vec4 fine_candidates[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer FineWinners {
    vec4 fine_winners[];
};

layout(push_constant, std430) uniform Params {
    uvec4 counts; // topk, anchor_capacity, unused x2
};

const uint RECORD_STRIDE = 4u;

void main() {
    uint anchor_id = gl_GlobalInvocationID.x;
    uint topk = max(counts.x, 1u);
    uint anchor_count = min(anchor_count_dyn[0], counts.y);
    if (anchor_id >= anchor_count) return;

    uint best_slot = 0xFFFFFFFFu;
    float best_score = -3.402823466e+38;
    for (uint k = 0u; k < topk; k++) {
        uint slot = anchor_id * topk + k;
        uint base = slot * RECORD_STRIDE;
        if (fine_candidates[base + 3u].y < 0.5) continue;
        float score = fine_candidates[base + 0u].w;
        if (isnan(score)) continue;
        if (best_slot == 0xFFFFFFFFu || score > best_score
                || (score == best_score && slot < best_slot)) {
            best_slot = slot;
            best_score = score;
        }
    }

    uint out_base = anchor_id * RECORD_STRIDE;
    if (best_slot == 0xFFFFFFFFu) {
        fine_winners[out_base + 0u] = vec4(0.0, 0.0, 0.0, -3.402823466e+38);
        fine_winners[out_base + 1u] = vec4(float(anchor_id), -1.0, 0.0, -1.0);
        fine_winners[out_base + 2u] = vec4(0.0);
        fine_winners[out_base + 3u] = vec4(-1.0, 0.0, 0.0, 0.0);
        return;
    }

    uint in_base = best_slot * RECORD_STRIDE;
    fine_winners[out_base + 0u] = fine_candidates[in_base + 0u];
    fine_winners[out_base + 1u] = fine_candidates[in_base + 1u];
    fine_winners[out_base + 2u] = fine_candidates[in_base + 2u];
    fine_winners[out_base + 3u] = fine_candidates[in_base + 3u];
}
