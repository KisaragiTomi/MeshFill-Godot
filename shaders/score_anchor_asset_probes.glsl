#[compute]
#version 450

// Pass A — Score anchor × asset probe groups.
//
// Workgroup layout (16, 16, 1):
//   local_x = asset_lane  (0..15), covers 16 assets per block
//   local_y = probe_lane  (0..15), each asset's probes stride by 16
//
// Dispatch: (anchor_grid_x, anchor_grid_y, ceil(asset_count / 16))
//   WorkGroupID.xy → anchor_id
//   WorkGroupID.z  → asset_block
//
// Output: asset_scores[anchor_id * MAX_ASSETS + asset_id]

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// --- Buffers ---

layout(set = 0, binding = 0, std430) restrict readonly buffer AnchorBuf {
    uvec4 anchors[];    // (x, y, z, reserved)
};

// Per-asset probe range: asset_probe_range[asset_id] = (start, count)
layout(set = 0, binding = 1, std430) restrict readonly buffer ProbeRange {
    uvec2 asset_probe_range[];
};

// Flat probe data: 2 vec4 per probe
//   [2*i+0] = (offset.x, offset.y, offset.z, w_collision)
//   [2*i+1] = (rgba8_as_float, expected_collision, w_color, w_complexity)
layout(set = 0, binding = 2, std430) restrict readonly buffer ProbeData {
    vec4 probe_data[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer ComplexityCollision {
    vec2 complexity_coll[];
};

layout(set = 0, binding = 4, std430) restrict readonly buffer TargetField {
    vec4 target_field[];  // .rgb = target color, .a = completeness = max(complexity, collision)，表示体素完全度
};

layout(set = 0, binding = 5, std430) restrict writeonly buffer ScoresOut {
    float asset_scores[];
};

// GPU-resident anchor count (written by collect_sv_anchors, no CPU readback).
// Replaces the former push-constant anchor_count so dispatch can be indirect.
layout(set = 0, binding = 6, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_asset_count;  // xyz = grid dims, w = asset_count
    vec4  voxel_size_inv;         // xyz = 1.0 / voxel_size, w = unused
    uint  _unused_anchor_count;   // anchor count now read from AnchorCountBuf
    uint  anchor_grid_x;
    float min_prefilter_score;
    float _pad0;
};

// --- Constants ---

const uint MAX_ASSETS       = 256u;
const uint ASSET_LANES      = 16u;
const uint PROBE_LANES      = 16u;

const float SQRT3 = 1.732;

// --- Shared memory ---

shared float shared_score[16][16];

// --- Helpers ---

int voxel_index(ivec3 p) {
    return p.x + grid_size_asset_count.x * (p.z + grid_size_asset_count.z * p.y);
}

bool in_bounds(ivec3 p) {
    return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, grid_size_asset_count.xyz));
}

vec4 unpack_rgba8(uint packed) {
    return vec4(
        float((packed >> 24u) & 0xFFu) / 255.0,
        float((packed >> 16u) & 0xFFu) / 255.0,
        float((packed >>  8u) & 0xFFu) / 255.0,
        float((packed >>  0u) & 0xFFu) / 255.0
    );
}

// --- Probe evaluation ---
//
// Unified scoring: each probe carries per-metric weights (w_color, w_complexity,
// w_collision).  No flag/kind branches — behavior is controlled entirely by weights.
// Negative weights act as penalties: w_collision < 0 penalizes collision presence.
//
// Samples both target_field (TargetSV_B) and complexity_coll (SV scene state).
// target_field drives "what we want"; complexity_coll drives "what's already there".
// The fit values blend both sources so probes can reason about existing scene content.
//
// Sampling uses trilinear interpolation over the 8 nearest voxel neighbors so that
// probe positions between voxel centers produce smooth, continuous scores rather
// than snapping to the nearest cell.

// Compute a single-voxel score contribution from pre-sampled field values.
float eval_probe(vec4 tf, vec2 sv, vec4 e_col, float e_coll,
                 float w_color, float w_complexity, float w_collision) {
    // Bipolar fit for color/complexity: match quality [0,1] is remapped to [-1,1].
    // A mismatch now casts a negative vote instead of merely contributing 0, so a
    // large probe count stops being a one-sided advantage — assets that match the
    // target accumulate positive evidence, assets whose color/shape disagrees
    // accumulate negative evidence and sink below smaller well-matched assets.
    float color_match      = 1.0 - distance(tf.rgb, e_col.rgb) / SQRT3;  // [0,1]
    float complexity_match = 1.0 - abs(tf.a - e_col.a);                  // [0,1]
    float color_fit        = 2.0 * color_match - 1.0;                    // [-1,1]
    float complexity_fit   = 2.0 * complexity_match - 1.0;               // [-1,1]

    // Collision stays unipolar [0,1] so exclusion-zone negative weights keep their
    // meaning: empty space -> fit 0 -> negative weight contributes 0 (no spurious
    // reward), occupied space -> fit 1 -> negative weight penalizes as intended.
    float collision_fit    = 1.0 - abs(max(tf.a, sv.y) - e_coll);        // [0,1]

    return w_color * color_fit + w_complexity * complexity_fit + w_collision * collision_fit;
}

// Trilinearly sample target_field and complexity_coll at a continuous voxel-space
// position, then evaluate the probe score.  Corners outside the grid are clamped.
float eval_probe_trilinear(vec3 fsp, vec4 e_col, float e_coll,
                           float w_color, float w_complexity, float w_collision) {
    ivec3 p0  = ivec3(floor(fsp));
    vec3  t   = fsp - vec3(p0);          // fractional part in [0,1]
    ivec3 dim = grid_size_asset_count.xyz;

    vec4 tf_acc = vec4(0.0);
    vec2 sv_acc = vec2(0.0);

    for (int dz = 0; dz <= 1; dz++) {
        for (int dy = 0; dy <= 1; dy++) {
            for (int dx = 0; dx <= 1; dx++) {
                ivec3 sp  = clamp(p0 + ivec3(dx, dy, dz), ivec3(0), dim - ivec3(1));
                int   idx = voxel_index(sp);
                float w   = (dx == 0 ? (1.0 - t.x) : t.x)
                          * (dy == 0 ? (1.0 - t.y) : t.y)
                          * (dz == 0 ? (1.0 - t.z) : t.z);
                tf_acc += target_field[idx]    * w;
                sv_acc += complexity_coll[idx] * w;
            }
        }
    }

    return eval_probe(tf_acc, sv_acc, e_col, e_coll, w_color, w_complexity, w_collision);
}

// --- Main ---

void main() {
    uint anchor_id   = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x;
    uint asset_block = gl_WorkGroupID.z;
    uint asset_lane  = gl_LocalInvocationID.x;  // 0..15
    uint probe_lane  = gl_LocalInvocationID.y;  // 0..15
    uint asset_count = min(uint(grid_size_asset_count.w), MAX_ASSETS);
    uint asset_id    = asset_block * ASSET_LANES + asset_lane;
    uint anchor_count = anchor_count_dyn[0];

    float lane_score  = 0.0;

    if (anchor_id < anchor_count && asset_id < asset_count) {
        uvec4 anchor = anchors[anchor_id];
        ivec3 anchor_pos = ivec3(anchor.xyz);

        uvec2 range = asset_probe_range[asset_id];
        uint probe_start = range.x;
        uint probe_count = range.y;

        for (uint i = probe_lane; i < probe_count; i += PROBE_LANES) {
            uint pi = (probe_start + i) * 2u;
            vec4 d0 = probe_data[pi];
            vec4 d1 = probe_data[pi + 1u];

            vec3  offset       = d0.xyz;
            float w_collision  = d0.w;
            uint  rgba8        = floatBitsToUint(d1.x);
            float e_coll       = d1.y;
            float w_color      = d1.z;
            float w_complexity = d1.w;

            // Continuous voxel-space position; trilinear sampling blends 8 neighbors.
            vec3 fsp = vec3(anchor_pos) + offset * voxel_size_inv.xyz;

            vec4 e_col = unpack_rgba8(rgba8);
            float ps = eval_probe_trilinear(fsp, e_col, e_coll, w_color, w_complexity, w_collision);
            lane_score += ps;
        }
    }

    // Write per-lane results to shared memory
    shared_score[asset_lane][probe_lane]  = lane_score;
    barrier();

    // Reduce across probe lanes (probe_lane == 0 accumulates)
    if (probe_lane == 0u && anchor_id < anchor_count && asset_id < MAX_ASSETS) {
        float sum_score  = 0.0;
        for (uint py = 0u; py < PROBE_LANES; py++) {
            sum_score  += shared_score[asset_lane][py];
        }
        float final_score = asset_id < asset_count
            ? sum_score
            : -1.0;
        asset_scores[anchor_id * MAX_ASSETS + asset_id] = final_score;
    }
}
