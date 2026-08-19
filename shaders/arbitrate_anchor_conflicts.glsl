#[compute]
#version 450

// Reduce stage 2/3: iterative greedy score-NMS over the same-batch anchors.
//
// Replaces the retired single-pass random-priority arbitration
// (invalidate_anchor_conflicts.glsl). Every participant holds one of three
// monotone states in anchor_valid (a state never changes once decided):
//   UNDECIDED -> OUT       some higher-priority SELECTED anchor conflicts
//                          with this one;
//   UNDECIDED -> SELECTED  every higher-priority conflicting anchor is
//                          already OUT (or none exists).
// Priority = fine score descending, anchor id ascending on ties (a total
// order, no ties survive). The unique fixed point equals the sequential
// greedy walk "take the best-scoring candidate, drop everything conflicting
// with it, repeat" -- the batch keeps the highest-scoring feasible set
// instead of a random-priority one, and a loser's neighbors are re-eligible
// instead of being over-killed.
//
// In-place single-buffer updates are safe because the states are monotone: a
// stale read only delays a decision by one iteration, a fresh read only
// accelerates it; the fixed point is unchanged either way.
//
// Convergence control stays on the GPU: the last workgroup to finish an
// iteration (tracked via nms_finished_groups) compares nms_decided_count
// against nms_valid_count and zeroes the indirect dispatch args once every
// participant is decided. The host blindly enqueues a fixed budget of
// iterations; trailing ones launch zero workgroups and cost nothing. Each
// iteration decides at least the highest-priority undecided anchor, so the
// worst case is bounded.
//
// How many rounds it actually takes is the length of the longest
// priority-dependency chain in the conflict graph -- an anchor cannot decide
// until every higher-priority anchor it conflicts with has decided.
// Measured on the reference harness (D:/MyProject/ObjectReduce, same
// algorithm, only the input field changed):
//   * distinct random-ish scores      13 rounds   (many local maxima settle
//                                                  in parallel)
//   * score quantised to 8 levels    131 rounds   (ties collapse priority
//                                                  onto the id tie-break)
//   * monotone score gradient        136 rounds   (one chain spans the map)
//   * 2.7x denser packing             12 rounds   (density is irrelevant)
// This project's score is residual gain against a target field: spatially
// structured and heavily tied, i.e. the slow shape. Measured in this repo on
// 2026-08-19 via the nms_meta telemetry (VPG reads it back and reports it as
// reduce_nms_telemetry):
//   * un-gated, 38009 participants     59-62 rounds (varies run to run)
//   * Place batch, lattice interval 12    21 rounds (32.7 participants mean)
//
// Budget: 64, and whatever has not been decided by then is DISCARDED. That is
// a deliberate product decision (2026-08-19), not a fallback: leftovers stay
// UNDECIDED, compact only accepts SELECTED, so they are neither placed nor
// allowed to suppress anyone. At 64 the un-gated case has only single digits
// of headroom over its measured 59-62, so exhaustion there is expected rather
// than exceptional -- it is no longer silent, though: nms_meta is read back
// and an exhausted budget raises a warning plus budget_exhausted in the report.

// ⚠ 64, and it must stay in lockstep with the divisor init uses to size this
// dispatch (atomicMax(nms_dispatch_args[0], slot / N + 1)). Sized down from 256
// on purpose: with the participant list compacted, a gated Place batch has ~33
// participants on average and 253 at most, so a 256-wide group would put every
// scan of that batch into ONE workgroup -- i.e. one SM -- whereas before
// compaction the same scans were scattered across ~149 groups and ran on many
// SMs at once. 64 keeps small batches spread over several groups while the
// un-gated case (38009 participants) still gets ~594 groups.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// ⚠ binding 0/1/2 (FineCandidates / AnchorCountBuf / AnchorCandidateRef) are
// intentionally gone. This pass used to reach its own record through
// anchor_candidate_ref -> fine_candidates, i.e. an indirection into a 100+ MB
// buffer; both self and neighbour data now come from the pixel-indexed
// meta/record pair init writes. The binding numbers are left as a gap rather
// than renumbered, matching the precedent set by compact.

layout(set = 0, binding = 3, std430) restrict buffer AnchorValid {
    uint anchor_valid[]; // ANCHOR_STATE_*, in-place three-state machine
};

layout(set = 0, binding = 4, std430) restrict readonly buffer ArbMetaAtPixel {
    uint arb_meta_at_pixel[]; // ((anchor id + 1) << 8) | asset; zero = empty
};

layout(set = 0, binding = 5, std430) coherent restrict buffer NmsMeta {
    uint nms_decided_count;
    uint nms_valid_count;
    uint nms_iteration_count;
    uint nms_finished_groups;
};

layout(set = 0, binding = 6, std430) restrict buffer NmsDispatchArgs {
    uint nms_dispatch_args[3];
};

layout(set = 0, binding = 7, std430) restrict readonly buffer AssetSpacing {
    float asset_spacing_radius[];
};

layout(set = 0, binding = 8, std430) restrict readonly buffer ArbRecordAtPixel {
    vec4 arb_record_at_pixel[]; // (origin.xyz, fine score) of that pixel's anchor
};

layout(set = 0, binding = 9, std430) restrict readonly buffer ParticipantList {
    uint participant_pixels[]; // compact slot -> pixel index (see init)
};

layout(push_constant, std430) uniform Params {
    ivec4 counts;  // anchor_capacity, asset_count, grid_x, grid_z
    vec4 params;   // min distance, spacing factor, max asset radius, unused
    ivec4 lattice; // anchor_interval (<=0 = gate off), phase_x, phase_z, unused
};

const uint RECORD_STRIDE = 4u;
const uint MAX_ASSETS = 256u;

// Must stay identical to init_anchor_atomic_reduce.glsl / compact.
const uint ANCHOR_STATE_OUT = 0u;
const uint ANCHOR_STATE_SELECTED = 1u;
const uint ANCHOR_STATE_UNDECIDED = 2u;

float spacing_radius_of(uint asset, uint asset_count) {
    return asset < asset_count ? max(asset_spacing_radius[asset], 0.0) : 0.0;
}

// Identical pair predicate to the retired invalidate pass: conflict when the
// 3D center distance is below max(min_distance, (r_a + r_b) * spacing_factor),
// floored at 0.5 voxels.
bool conflicts(vec3 a, uint asset_a, vec3 b, uint asset_b, uint asset_count) {
    float pair_distance = max(params.x,
        (spacing_radius_of(asset_a, asset_count) + spacing_radius_of(asset_b, asset_count)) * params.y);
    vec3 delta = a - b;
    return dot(delta, delta) < max(pair_distance * pair_distance, 0.25);
}

bool higher_priority(float other_score, uint other, float self_score, uint self) {
    return other_score > self_score || (other_score == self_score && other < self);
}

// Returns the new state for one undecided anchor; UNDECIDED means "cannot
// conclude this iteration" (a higher-priority conflicting anchor is itself
// still undecided).
//
// The neighbour scan reads only the two pixel-indexed arbitration arrays
// (arb_meta_at_pixel / arb_record_at_pixel, ~1.3 MB together for a 256x256
// grid) written by init. It deliberately never touches fine_candidates: that
// buffer is 100+ MB and reaching a neighbour's record in it took three
// dependent indirections, which made the hottest loop in the chain a random
// gather. Only this anchor's *own* record still comes from there -- once per
// thread per round, not once per probe.
uint evaluate(uint anchor, vec3 self_origin, float self_score, uint self_asset,
        uint anchor_capacity, uint asset_count, int grid_x, int grid_z) {
    ivec2 center = ivec2(round(self_origin.x), round(self_origin.z));

    // Conservative XZ scan window (same bound the retired pass used). The pair
    // predicate tests full 3D distance, which is >= the XZ distance, so every
    // possible conflict partner lies inside this window.
    float scan_distance = max(params.x,
        (spacing_radius_of(self_asset, asset_count) + max(params.z, 0.0)) * params.y);
    int scan_radius = max(int(ceil(scan_distance)), 1);
    ivec2 begin = max(center - ivec2(scan_radius), ivec2(0));
    ivec2 end = min(center + ivec2(scan_radius), ivec2(grid_x - 1, grid_z - 1));

    // Lattice stride. When init's lattice gate is on, *every* participant sits
    // on (phase + k * interval) -- the gate returns before writing the pixel
    // index -- so the scan can step by `interval` and still visit every
    // occupant. Stepping by 1 instead would walk interval^2 - 1 guaranteed-empty
    // pixels for each real one (at the shipped interval of 12 that is 99.3% of
    // a 25x25 window). Gate off (interval <= 0) degenerates to the dense step 1.
    int stride = max(lattice.x, 1);
    ivec2 first = begin;
    if (lattice.x > 0) {
        // begin is clamped to >= 0, so the modulo needs no negative handling.
        first.x = begin.x + ((lattice.y - begin.x) % stride + stride) % stride;
        first.y = begin.y + ((lattice.z - begin.y) % stride + stride) % stride;
    }

    bool blocked = false;
    for (int z = first.y; z <= end.y; z += stride) {
        for (int x = first.x; x <= end.x; x += stride) {
            uint pixel_index = uint(x + grid_x * z);
            uint meta = arb_meta_at_pixel[pixel_index];
            if (meta == 0u) {
                continue;
            }
            uint other = (meta >> 8) - 1u;
            if (other == anchor || other >= anchor_capacity) {
                continue;
            }
            vec4 other_record = arb_record_at_pixel[pixel_index];
            // Priority is tested before the state read on purpose: it rejects
            // roughly half the occupied neighbours using data already in hand,
            // so those never pay for the scattered anchor_valid lookup.
            if (!higher_priority(other_record.w, other, self_score, anchor)) {
                continue;
            }
            // Single read per surviving neighbor: stale values are safe (monotone).
            uint other_state = anchor_valid[other];
            if (other_state == ANCHOR_STATE_OUT) {
                continue;
            }
            if (!conflicts(self_origin, self_asset, other_record.xyz, meta & 0xFFu, asset_count)) {
                continue;
            }
            if (other_state == ANCHOR_STATE_SELECTED) {
                return ANCHOR_STATE_OUT;
            }
            blocked = true;
        }
    }
    return blocked ? ANCHOR_STATE_UNDECIDED : ANCHOR_STATE_SELECTED;
}

void main() {
    // One thread per *participant*, not per anchor slot. init compacted the
    // gate survivors into participant_pixels and sized this dispatch to their
    // count, so the whole workgroup is doing real work instead of 99% of it
    // exiting on the first state read.
    uint slot = gl_GlobalInvocationID.x;
    uint participant_count = nms_valid_count;
    uint anchor_capacity = uint(max(counts.x, 0));
    uint asset_count = min(uint(max(counts.y, 0)), MAX_ASSETS);
    int grid_x = max(counts.z, 1);
    int grid_z = max(counts.w, 1);

    // No early return before barrier(): every invocation of the workgroup
    // must reach it, including the out-of-range tail.
    if (slot < participant_count) {
        uint pixel_index = participant_pixels[slot];
        uint self_meta = arb_meta_at_pixel[pixel_index];
        uint anchor = (self_meta >> 8) - 1u;
        if (self_meta != 0u && anchor_valid[anchor] == ANCHOR_STATE_UNDECIDED) {
            vec4 self_record = arb_record_at_pixel[pixel_index];
            uint next_state = evaluate(anchor, self_record.xyz, self_record.w,
                self_meta & 0xFFu, anchor_capacity, asset_count, grid_x, grid_z);
            if (next_state != ANCHOR_STATE_UNDECIDED) {
                anchor_valid[anchor] = next_state;
                atomicAdd(nms_decided_count, 1u);
            }
        }
    }

    barrier();
    memoryBarrier();
    if (gl_LocalInvocationIndex != 0u) {
        return;
    }
    uint total_groups = gl_NumWorkGroups.x * gl_NumWorkGroups.y * gl_NumWorkGroups.z;
    if (atomicAdd(nms_finished_groups, 1u) + 1u != total_groups) {
        return;
    }
    // Last workgroup of this iteration: reset the tally for the next one and
    // shut the chain down once every participant is decided.
    nms_finished_groups = 0u;
    nms_iteration_count += 1u;
    if (nms_decided_count >= nms_valid_count) {
        nms_dispatch_args[0] = 0u;
    }
}
