#[compute]
#version 450

// Reduce stage 3/3: deterministic terminal compaction.
//
// Accepts exactly the anchors left in ANCHOR_STATE_SELECTED by the greedy
// score-NMS (arbitrate_anchor_conflicts.glsl). UNDECIDED leftovers from an
// exhausted iteration budget stay UNDECIDED and are dropped here, never placed
// with unresolved conflicts.
//
// Per-asset quota is retired: the reduce carries no asset dimension any more,
// every candidate is just one range + one score, and the only selection policy
// in the whole chain is the arbitration's score priority.
//
// ⚠ result_capacity is a **buffer bound, not a selection rule**. When the NMS
// produces more winners than the result buffer holds, this loop fills up in
// anchor-id order and stops; the rest are left for the next batch. Anchor ids
// come from an unordered atomicAdd in collect_sv_anchors.glsl, so which
// winners land first in a saturated batch is arbitrary and unstable across
// runs. Keep result_capacity above the expected winner count if that matters.

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

// ⚠ binding 4 (AssetLookup) is intentionally gone: its only use here was the
// retired per-asset quota (`asset_lookup[].z`). The gap is left as-is rather
// than renumbering, so the remaining bindings keep their existing host wiring.

layout(set = 0, binding = 5, std430) restrict buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 6, std430) restrict buffer ResultCount {
    uint result_count;
};

layout(push_constant, std430) uniform Params {
    // counts.z used to be asset_count (for the retired quota lookup); the slot
    // stays so the host push layout is unchanged, but nothing reads it now.
    ivec4 counts; // anchor_capacity, result_capacity, unused, unused
};

const uint RECORD_STRIDE = 4u;

// Must stay identical to init_anchor_atomic_reduce.glsl / arbitrate.
const uint ANCHOR_STATE_SELECTED = 1u;

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

    uint selected = 0u;
    // `selected < result_capacity` is now a defensive bound, not a policy: the
    // rank pass already demoted everything past the ceiling, so the loop is
    // expected to run out of SELECTED anchors before it runs out of slots.
    for (uint anchor = 0u; anchor < anchor_count && selected < result_capacity; anchor++) {
        uint candidate_ref = anchor_candidate_ref[anchor];
        if (candidate_ref == 0u || anchor_valid[anchor] != ANCHOR_STATE_SELECTED) {
            continue;
        }
        uint src = (candidate_ref - 1u) * RECORD_STRIDE;
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
