#[compute]
#version 450

// One-pass conflict arbitration. Every Anchor scans the direct XZ maps inside
// a conservative radius, performs the exact 3D pair test, and atomically
// clears the lower-priority endpoint. A thread must keep scanning even after
// its own valid word becomes zero: all conflict edges are resolved from the
// immutable candidate set, never from timing-dependent intermediate validity.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FineCandidates {
    vec4 fine_candidates[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer AnchorCandidateRef {
    uint anchor_candidate_ref[];
};

layout(set = 0, binding = 3, std430) restrict buffer AnchorValid {
    uint anchor_valid[];
};

layout(set = 0, binding = 4, std430) restrict readonly buffer AnchorAtPixel {
    uint anchor_at_pixel[];
};

layout(set = 0, binding = 5, std430) restrict readonly buffer SeedPlacements {
    vec4 seed_placements[];
};

layout(set = 0, binding = 6, std430) restrict readonly buffer SeedAtPixel {
    uint seed_at_pixel[];
};

layout(set = 0, binding = 7, std430) restrict readonly buffer AssetSpacing {
    float asset_spacing_radius[];
};

layout(push_constant, std430) uniform Params {
    ivec4 counts; // anchor_capacity, asset_count, seed_count, grid_x
    uvec4 grid_seed; // grid_z, random seed, unused x2
    vec4 params; // min distance, spacing factor, max asset radius, unused
};

const uint RECORD_STRIDE = 4u;
const uint MAX_ASSETS = 256u;

uint hash_u32(uint value) {
    value ^= value >> 16u;
    value *= 0x7FEB352Du;
    value ^= value >> 15u;
    value *= 0x846CA68Bu;
    value ^= value >> 16u;
    return value;
}

uint random_index(uint anchor_id) {
    return hash_u32(anchor_id ^ grid_seed.y);
}

bool priority_precedes(uint a, uint b) {
    uint random_a = random_index(a);
    uint random_b = random_index(b);
    return random_a < random_b || (random_a == random_b && a < b);
}

float spacing_radius_of(uint asset, uint asset_count) {
    return asset < asset_count ? max(asset_spacing_radius[asset], 0.0) : 0.0;
}

bool conflicts(vec3 a, uint asset_a, vec3 b, uint asset_b, uint asset_count) {
    float pair_distance = max(params.x,
        (spacing_radius_of(asset_a, asset_count) + spacing_radius_of(asset_b, asset_count)) * params.y);
    vec3 delta = a - b;
    return dot(delta, delta) < max(pair_distance * pair_distance, 0.25);
}

void main() {
    uint anchor = gl_GlobalInvocationID.x;
    uint anchor_count = min(anchor_count_dyn[0], uint(max(counts.x, 0)));
    if (anchor >= anchor_count) {
        return;
    }
    uint self_ref = anchor_candidate_ref[anchor];
    if (self_ref == 0u) {
        return;
    }

    uint asset_count = min(uint(max(counts.y, 0)), MAX_ASSETS);
    uint seed_count = uint(max(counts.z, 0));
    int grid_x = max(counts.w, 1);
    int grid_z = max(int(grid_seed.x), 1);
    uint self_slot = self_ref - 1u;
    uint self_base = self_slot * RECORD_STRIDE;
    vec3 self_origin = fine_candidates[self_base + 0u].xyz;
    uint self_asset = uint(max(int(round(fine_candidates[self_base + 1u].y)), 0));
    float scan_distance = max(params.x,
        (spacing_radius_of(self_asset, asset_count) + max(params.z, 0.0)) * params.y);
    int scan_radius = max(int(ceil(scan_distance)), 1);
    ivec2 center = ivec2(round(self_origin.x), round(self_origin.z));
    ivec2 begin = max(center - ivec2(scan_radius), ivec2(0));
    ivec2 end = min(center + ivec2(scan_radius), ivec2(grid_x - 1, grid_z - 1));

    for (int z = begin.y; z <= end.y; z++) {
        for (int x = begin.x; x <= end.x; x++) {
            uint pixel = uint(x + grid_x * z);

            uint seed_ref = seed_at_pixel[pixel];
            if (seed_ref != 0u) {
                uint seed = seed_ref - 1u;
                if (seed < seed_count) {
                    vec4 seed_data = seed_placements[seed];
                    uint seed_asset = uint(max(int(round(seed_data.w)), 0));
                    if (conflicts(self_origin, self_asset, seed_data.xyz, seed_asset, asset_count)) {
                        atomicAnd(anchor_valid[anchor], 0u);
                    }
                }
            }

            uint other_ref = anchor_at_pixel[pixel];
            if (other_ref == 0u) {
                continue;
            }
            uint other = other_ref - 1u;
            if (other == anchor || other >= anchor_count) {
                continue;
            }
            uint other_candidate_ref = anchor_candidate_ref[other];
            if (other_candidate_ref == 0u) {
                continue;
            }
            uint other_base = (other_candidate_ref - 1u) * RECORD_STRIDE;
            vec3 other_origin = fine_candidates[other_base + 0u].xyz;
            uint other_asset = uint(max(int(round(fine_candidates[other_base + 1u].y)), 0));
            if (!conflicts(self_origin, self_asset, other_origin, other_asset, asset_count)) {
                continue;
            }
            uint loser = priority_precedes(anchor, other) ? other : anchor;
            atomicAnd(anchor_valid[loser], 0u);
        }
    }
}
