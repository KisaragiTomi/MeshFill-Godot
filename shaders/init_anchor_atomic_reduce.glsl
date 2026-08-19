#[compute]
#version 450

// Reduce stage 1/3: per-anchor candidate selection + greedy-NMS state seeding.
//
// For each live anchor, pick its best Fine Score candidate (highest score,
// smaller slot on ties), then run the eligibility gates that do not depend on
// other anchors of this batch:
//   * lattice gate (anchor_interval): optional batching aid, <=0 disables.
//     With the exact greedy NMS downstream it is no longer needed for
//     correctness; it survives as a way to thin dense batches on demand.
//   * cross-batch clearance: O(1) lookup of the persistent signed clearance
//     field painted by shaders/paint_placement_clearance.glsl (there is no
//     seed map: session-first seeds are baked into the field by the paint
//     pass). An anchor that fails it can never be placed, so it must not
//     suppress anyone either -- it does not enter the arbitration at all.
//
// Survivors enter the iterative greedy score-NMS
// (shaders/arbitrate_anchor_conflicts.glsl) as ANCHOR_STATE_UNDECIDED and are
// counted into nms_valid_count; thread 0 sizes the NMS indirect dispatch from
// the live anchor count.
//
// The two pixel-indexed outputs (arb_meta_at_pixel / arb_record_at_pixel) are
// the arbitration's own compact index, and they only contain participants. The
// anchor collector guarantees at most one anchor per (x,z) column. All output
// buffers arrive zero-filled, so "leave untouched" already encodes "no
// candidate".
//
// Why a dedicated record instead of pointing at the Fine candidates: the NMS
// neighbour scan is the hottest read in the chain (hundreds of probes per
// anchor per round). Resolving a neighbour used to cost three dependent
// indirections ending in a random gather into the 100+ MB fine_candidates
// buffer. Copying the 16 bytes the scan actually needs into a pixel-indexed
// table (~1 MB for a 256x256 grid) turns that into two cache-friendly reads.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FineCandidates {
    vec4 fine_candidates[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer AnchorCandidateRef {
    uint anchor_candidate_ref[]; // candidate slot + 1; zero = no valid candidate
};

layout(set = 0, binding = 3, std430) restrict writeonly buffer AnchorValid {
    uint anchor_valid[]; // ANCHOR_STATE_*, see below
};

layout(set = 0, binding = 4, std430) restrict writeonly buffer ArbMetaAtPixel {
    // ((anchor id + 1) << 8) | asset; zero = empty. One read gives the
    // arbitrate pass both the neighbour's identity and its spacing asset.
    uint arb_meta_at_pixel[];
};

layout(set = 0, binding = 5, std430) coherent restrict buffer NmsMeta {
    uint nms_decided_count;
    uint nms_valid_count;
    uint nms_iteration_count;
    uint nms_finished_groups;
};

layout(set = 0, binding = 6, std430) restrict writeonly buffer NmsDispatchArgs {
    uint nms_dispatch_args[3];
};

layout(set = 0, binding = 7, std430) restrict readonly buffer AssetSpacing {
    float asset_spacing_radius[];
};

// Signed clearance field, query side. Encoding and the radius convention are
// documented in shaders/paint_placement_clearance.glsl.
layout(set = 0, binding = 8, std430) restrict readonly buffer ClearanceField {
    uint clearance_field[];
};

// Pixel-indexed arbitration record: the winning Fine candidate's
// (origin.xyz, score) vec4 copied verbatim. Paired with arb_meta_at_pixel.
layout(set = 0, binding = 9, std430) restrict writeonly buffer ArbRecordAtPixel {
    vec4 arb_record_at_pixel[];
};

// Compact participant list: slot -> pixel index. The arbitrate dispatch is
// sized from this list instead of from the whole anchor pool, so a batch whose
// lattice gate admits 253 of 38009 anchors launches 1 workgroup per round
// rather than 149 of which 99.3% of the threads exit on their first read.
// Slot order comes from the same atomicAdd that counts participants and is
// therefore arbitrary -- that is fine, it is only an iteration order. Priority
// still comes from (score, anchor id) carried in the record/meta pair, so the
// fixed point does not depend on it.
layout(set = 0, binding = 10, std430) restrict writeonly buffer ParticipantList {
    uint participant_pixels[];
};

layout(push_constant, std430) uniform Params {
    ivec4 counts;  // topk, anchor_capacity, asset_count, grid_x
    ivec4 grid;    // grid_z, anchor_interval, anchor_phase_x, anchor_phase_z
    vec4 spacing;  // min_distance_voxels, asset_spacing_factor, unused, unused
};

const uint RECORD_STRIDE = 4u;
const uint MAX_ASSETS = 256u;

// Anchor arbitration states. Shared by the three reduce shaders
// (init / arbitrate / compact); the values must stay identical across them.
// ANCHOR_STATE_OUT doubles as "no candidate": zero-filled buffers are valid.
const uint ANCHOR_STATE_OUT = 0u;
const uint ANCHOR_STATE_SELECTED = 1u;
const uint ANCHOR_STATE_UNDECIDED = 2u;

// Must match shaders/paint_placement_clearance.glsl bit for bit.
const float CLEARANCE_FIXED_SCALE = 256.0;
const float CLEARANCE_BIAS_VOXELS = 64.0;

bool in_pixel_grid(ivec2 p, int grid_x, int grid_z) {
    return p.x >= 0 && p.y >= 0 && p.x < grid_x && p.y < grid_z;
}

float spacing_radius_of(uint asset, uint asset_count) {
    return asset < asset_count ? max(asset_spacing_radius[asset], 0.0) : 0.0;
}

// See the "radius convention" note in paint_placement_clearance.glsl. The two
// functions must stay literally identical.
float clearance_half_radius(uint asset, uint asset_count, float min_distance, float factor) {
    float half_floor = max(min_distance * 0.5, 0.25);
    return max(spacing_radius_of(asset, asset_count) * factor, half_floor);
}

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint topk = uint(max(counts.x, 1));
    uint anchor_capacity = uint(max(counts.y, 0));
    uint anchor_count = min(anchor_count_dyn[0], anchor_capacity);
    uint asset_count = min(uint(max(counts.z, 0)), MAX_ASSETS);
    int grid_x = max(counts.w, 1);
    int grid_z = max(grid.x, 1);

    if (i == 0u) {
        // args[0] is *not* set here any more: it is accumulated below by the
        // participants themselves (atomicMax over their slot), so the dispatch
        // matches the participant count rather than the anchor pool. Zero
        // participants leave it at its zero-filled value => the whole NMS chain
        // no-ops, which is the same behaviour as before.
        nms_dispatch_args[1] = 1u;
        nms_dispatch_args[2] = 1u;
    }

    if (i >= anchor_count) {
        return;
    }

    uint best_slot = 0xFFFFFFFFu;
    float best_score = -3.402823466e+38;
    for (uint k = 0u; k < topk; k++) {
        uint slot = i * topk + k;
        uint base = slot * RECORD_STRIDE;
        if (fine_candidates[base + 3u].y < 0.5) {
            continue;
        }
        float score = fine_candidates[base + 0u].w;
        if (isnan(score)) {
            continue;
        }
        // Keep the tie-break explicit: within one Anchor, a smaller slot
        // is the smaller k because slots are laid out anchor * topk + k.
        if (best_slot == 0xFFFFFFFFu || score > best_score
                || (score == best_score && slot < best_slot)) {
            best_slot = slot;
            best_score = score;
        }
    }
    if (best_slot == 0xFFFFFFFFu) {
        return;
    }

    vec3 origin = fine_candidates[best_slot * RECORD_STRIDE + 0u].xyz;
    ivec2 pixel = ivec2(round(origin.x), round(origin.z));

    // Lattice gate: only anchors on (phase + k*interval) compete this batch.
    // Coverage across phases is the caller's business. pixel is >= 0 for any
    // in-grid candidate, so the modulo needs no negative handling.
    int anchor_interval = grid.y;
    if (anchor_interval > 0
            && ((pixel.x % anchor_interval) != grid.z
                || (pixel.y % anchor_interval) != grid.w)) {
        return;
    }
    // An out-of-grid candidate cannot participate safely.
    if (!in_pixel_grid(pixel, grid_x, grid_z)) {
        return;
    }

    // Cross-batch clearance: clearance = half(placed) - dist as painted by the
    // accepted placements; conflict iff dist < half(placed) + half(self),
    // which is exactly clearance > -half(self). No approximation.
    uint asset = uint(max(int(round(fine_candidates[best_slot * RECORD_STRIDE + 1u].y)), 0));
    float half_self = clearance_half_radius(asset, asset_count, spacing.x, spacing.y);
    uint stored = clearance_field[uint(pixel.x + grid_x * pixel.y)];
    if (stored != 0u) {
        float clearance = float(stored) / CLEARANCE_FIXED_SCALE - CLEARANCE_BIAS_VOXELS;
        if (clearance > -half_self) {
            return;
        }
    }

    anchor_candidate_ref[i] = best_slot + 1u;
    anchor_valid[i] = ANCHOR_STATE_UNDECIDED;
    uint pixel_index = uint(pixel.x + grid_x * pixel.y);
    // The asset index is clamped into the 8 packed bits. MAX_ASSETS is 256 and
    // any index >= asset_count already resolves to spacing radius 0 on both the
    // paint and the query side, so the clamp cannot change a conflict verdict.
    arb_meta_at_pixel[pixel_index] = ((i + 1u) << 8) | min(asset, 255u);
    arb_record_at_pixel[pixel_index] = fine_candidates[best_slot * RECORD_STRIDE + 0u];
    // One atomic serves three purposes: it counts participants (the NMS
    // convergence target), hands out this participant's compact slot, and --
    // via the atomicMax below -- sizes the arbitration dispatch to that count.
    uint slot = atomicAdd(nms_valid_count, 1u);
    participant_pixels[slot] = pixel_index;
    // ⚠ 64 must equal arbitrate_anchor_conflicts.glsl's local_size_x.
    atomicMax(nms_dispatch_args[0], slot / 64u + 1u);
}
