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
    uvec4 anchors[];    // (x, y, z, anchor_kind)
};

// Per-asset probe range: asset_probe_range[asset_id * 2 + anchor_kind] = (start, count)
layout(set = 0, binding = 1, std430) restrict readonly buffer ProbeRange {
    uvec2 asset_probe_range[];
};

// Bitmask per asset: bit 0 = accepts ground, bit 1 = accepts target_top
layout(set = 0, binding = 2, std430) restrict readonly buffer AnchorMask {
    uint asset_anchor_kind_mask[];
};

// Flat probe data: 2 vec4 per probe
//   [2*i+0] = (offset.x, offset.y, offset.z, weight)
//   [2*i+1] = (rgba8_as_float, expected_collision, flags_as_float, kind_as_float)
layout(set = 0, binding = 3, std430) restrict readonly buffer ProbeData {
    vec4 probe_data[];
};

layout(set = 0, binding = 4, std430) restrict readonly buffer SceneOcc {
    float scene_occ[];
};

layout(set = 0, binding = 5, std430) restrict readonly buffer CollisionOcc {
    float collision_occ[];
};

layout(set = 0, binding = 6, std430) restrict readonly buffer TargetOcc {
    float target_occ[];
};

layout(set = 0, binding = 7, std430) restrict readonly buffer TargetColor {
    uint target_color[];
};

layout(set = 0, binding = 8, std430) restrict writeonly buffer ScoresOut {
    float asset_scores[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_asset_count;  // xyz = grid dims, w = asset_count
    vec4  voxel_size_inv;         // xyz = 1.0 / voxel_size, w = unused
    uint  anchor_count;
    uint  anchor_grid_x;
    float min_prefilter_score;
    float _pad0;
};

// --- Constants ---

const uint MAX_ASSETS       = 256u;
const uint ASSET_LANES      = 16u;
const uint PROBE_LANES      = 16u;

const uint ANCHOR_KIND_GROUND     = 0u;
const uint ANCHOR_KIND_TARGET_TOP = 1u;

const uint FLAG_COLOR      = 1u;
const uint FLAG_COMPLEXITY = 2u;
const uint FLAG_COLLISION  = 4u;
const uint FLAG_EMPTY      = 8u;
const uint FLAG_SUPPORT    = 16u;

const float UNDERGROUND_OCC_THRESHOLD = 0.5;

// --- Shared memory ---

shared float shared_score[16][16];
shared float shared_weight[16][16];

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

float eval_probe(ivec3 sp, uint flags, uint kind, vec4 e_col, float e_coll) {
    int idx = voxel_index(sp);
    float s_scene = scene_occ[idx];

    // Underground: only collision scoring contributes
    if (s_scene >= UNDERGROUND_OCC_THRESHOLD) {
        if ((flags & FLAG_COLLISION) == 0u) return 0.0;
        if ((flags & FLAG_EMPTY) != 0u || kind == 1u) return 0.0;  // negative
        if ((flags & FLAG_SUPPORT) != 0u || kind == 2u) return 0.0; // support
        return clamp(1.0 - abs(target_occ[idx] - e_coll), 0.0, 1.0);
    }

    // Empty / negative
    if ((flags & FLAG_EMPTY) != 0u || kind == 1u) {
        vec4 sc = unpack_rgba8(target_color[idx]);
        return 1.0 - max(sc.a, max(target_occ[idx], s_scene));
    }

    // Support
    if ((flags & FLAG_SUPPORT) != 0u || kind == 2u) {
        ivec3 below = sp + ivec3(0, -1, 0);
        if (!in_bounds(below)) return 0.0;
        int bi = voxel_index(below);
        return clamp(max(scene_occ[bi], collision_occ[bi]), 0.0, 1.0);
    }

    // Positive: weighted color + complexity + collision
    vec4 sc = unpack_rgba8(target_color[idx]);
    float s_coll = target_occ[idx];
    float score = 0.0;
    float wsum = 0.0;
    if ((flags & FLAG_COLOR) != 0u) {
        score += 1.0 - distance(sc.rgb, e_col.rgb) / 1.732;
        wsum += 1.0;
    }
    if ((flags & FLAG_COMPLEXITY) != 0u) {
        score += 1.0 - abs(sc.a - e_col.a);
        wsum += 1.0;
    }
    if ((flags & FLAG_COLLISION) != 0u) {
        score += 1.0 - abs(s_coll - e_coll);
        wsum += 1.0;
    }
    return score / max(wsum, 1e-6);
}

// --- Main ---

void main() {
    uint anchor_id   = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x;
    uint asset_block = gl_WorkGroupID.z;
    uint asset_lane  = gl_LocalInvocationID.x;  // 0..15
    uint probe_lane  = gl_LocalInvocationID.y;  // 0..15
    uint asset_count = min(uint(grid_size_asset_count.w), MAX_ASSETS);
    uint asset_id    = asset_block * ASSET_LANES + asset_lane;

    float lane_score  = 0.0;
    float lane_weight = 0.0;

    if (anchor_id < anchor_count && asset_id < asset_count) {
        uvec4 anchor = anchors[anchor_id];
        ivec3 anchor_pos = ivec3(anchor.xyz);
        uint anchor_kind = anchor.w;
        uint anchor_kind_bit = 1u << anchor_kind;

        // Check if this asset accepts this anchor kind
        if ((asset_anchor_kind_mask[asset_id] & anchor_kind_bit) != 0u) {
            uint probe_range_idx = asset_id * 2u + anchor_kind;
            uvec2 range = asset_probe_range[probe_range_idx];
            uint probe_start = range.x;
            uint probe_count = range.y;

            // Stride through probes: this lane handles probe indices
            // probe_lane, probe_lane + 16, probe_lane + 32, ...
            for (uint i = probe_lane; i < probe_count; i += PROBE_LANES) {
                uint pi = (probe_start + i) * 2u;
                vec4 d0 = probe_data[pi];
                vec4 d1 = probe_data[pi + 1u];

                vec3  offset = d0.xyz;
                float weight = max(d0.w, 0.0);
                uint  rgba8  = floatBitsToUint(d1.x);
                float e_coll = d1.y;
                uint  flags  = floatBitsToUint(d1.z);
                uint  kind   = floatBitsToUint(d1.w);

                ivec3 sp = anchor_pos + ivec3(round(offset * voxel_size_inv.xyz));
                if (in_bounds(sp)) {
                    // Underground early-skip for non-collision probes
                    float s_scene = scene_occ[voxel_index(sp)];
                    if (s_scene >= UNDERGROUND_OCC_THRESHOLD && (flags & FLAG_COLLISION) == 0u) {
                        continue;
                    }
                    vec4 e_col = unpack_rgba8(rgba8);
                    float ps = eval_probe(sp, flags, kind, e_col, e_coll);
                    lane_score  += ps * weight;
                    lane_weight += weight;
                }
            }
        }
    }

    // Write per-lane results to shared memory
    shared_score[asset_lane][probe_lane]  = lane_score;
    shared_weight[asset_lane][probe_lane] = lane_weight;
    barrier();

    // Reduce across probe lanes (probe_lane == 0 accumulates)
    if (probe_lane == 0u && anchor_id < anchor_count && asset_id < MAX_ASSETS) {
        float sum_score  = 0.0;
        float sum_weight = 0.0;
        for (uint py = 0u; py < PROBE_LANES; py++) {
            sum_score  += shared_score[asset_lane][py];
            sum_weight += shared_weight[asset_lane][py];
        }
        float final_score = asset_id < asset_count
            ? sum_score / max(sum_weight, 1e-6)
            : -1.0;
        asset_scores[anchor_id * MAX_ASSETS + asset_id] = final_score;
    }
}
