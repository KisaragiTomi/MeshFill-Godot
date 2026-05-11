#[compute]
#version 450

// Collect placeable anchors (ground + target_top) from dirty tiles.
// One workgroup = one dirty tile (8×8×8 = 512 threads).
// Atomic-appends valid anchors into AnchorOut buffer.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SceneOcc {
    float scene_occ[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionOcc {
    float collision_occ[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer TargetOcc {
    float target_occ[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer DirtyTiles {
    uint dirty_tile_ids[];
};

// Output: packed anchors (x, y, z, anchor_kind) as uvec4
layout(set = 0, binding = 4, std430) restrict buffer AnchorOut {
    uvec4 anchors[];
};

// Output: atomic counter for number of anchors written
layout(set = 0, binding = 5, std430) restrict buffer AnchorCount {
    uint anchor_count;
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_pad;          // xyz = grid dims, w = dirty_tile_count
    ivec4 tile_grid_size_pad;     // xyz = tile grid dims, w = anchor_capacity
    vec4  thresholds;             // x = max_scene_occ, y = max_collision_occ,
                                  // z = min_support, w = min_target_interest
};

const uint TILE_SIZE = 8u;
const uint ANCHOR_KIND_GROUND     = 0u;
const uint ANCHOR_KIND_TARGET_TOP = 1u;

int voxel_index(ivec3 p) {
    return p.x + grid_size_pad.x * (p.z + grid_size_pad.z * p.y);
}

bool in_bounds(ivec3 p) {
    return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, grid_size_pad.xyz));
}

ivec3 tile_id_to_origin(uint tile_id) {
    int tx = int(tile_id) % tile_grid_size_pad.x;
    int tz = (int(tile_id) / tile_grid_size_pad.x) % tile_grid_size_pad.z;
    int ty = int(tile_id) / (tile_grid_size_pad.x * tile_grid_size_pad.z);
    return ivec3(tx, ty, tz) * int(TILE_SIZE);
}

float get_support(ivec3 p) {
    ivec3 below = p + ivec3(0, -1, 0);
    if (!in_bounds(below)) return 0.0;
    int bi = voxel_index(below);
    return max(scene_occ[bi], collision_occ[bi]);
}

void try_emit_anchor(ivec3 p, uint kind) {
    uint cap = uint(tile_grid_size_pad.w);
    uint idx = atomicAdd(anchor_count, 1u);
    if (idx < cap) {
        anchors[idx] = uvec4(uint(p.x), uint(p.y), uint(p.z), kind);
    }
}

// Shared: column-max target_top detection.
// For target_top we need the highest occupied target voxel per XZ column in
// this tile.  We store the best Y per (local_x, local_z) = 8×8 = 64 slots.
shared int s_top_y[8][8];

void main() {
    uint group_idx = gl_WorkGroupID.x;
    uint dirty_count = uint(max(grid_size_pad.w, 0));
    if (group_idx >= dirty_count) return;

    uint tile_id = dirty_tile_ids[group_idx];
    ivec3 tile_origin = tile_id_to_origin(tile_id);
    ivec3 p = tile_origin + ivec3(gl_LocalInvocationID.xyz);

    float max_scene   = thresholds.x;
    float max_coll    = thresholds.y;
    float min_support = thresholds.z;
    float min_target  = thresholds.w;

    uint lx = gl_LocalInvocationID.x;
    uint ly = gl_LocalInvocationID.y;
    uint lz = gl_LocalInvocationID.z;

    // Init shared for target_top column tracking
    if (ly == 0u) {
        s_top_y[lx][lz] = -1;
    }
    barrier();

    // --- Ground anchor check ---
    if (in_bounds(p)) {
        int idx = voxel_index(p);
        float sv = scene_occ[idx];
        float cv = collision_occ[idx];
        float tv = target_occ[idx];

        if (sv <= max_scene && cv <= max_coll && tv >= min_target) {
            float support = get_support(p);
            if (support >= min_support) {
                try_emit_anchor(p, ANCHOR_KIND_GROUND);
            }
        }

        // Target top: track highest target-occupied voxel per column
        if (tv >= min_target && sv <= max_scene && cv <= max_coll) {
            atomicMax(s_top_y[lx][lz], int(ly));
        }
    }
    barrier();

    // --- Target top anchor emit (one thread per column) ---
    if (ly == 0u && lz == 0u) {
        // Not needed — we emit per-column below
    }
    // Each column (lx, lz): thread with ly==0 checks the result
    if (ly == 0u) {
        int best_local_y = s_top_y[lx][lz];
        if (best_local_y >= 0) {
            ivec3 top_p = tile_origin + ivec3(int(lx), best_local_y, int(lz));
            if (in_bounds(top_p)) {
                float support = get_support(top_p);
                if (support >= min_support) {
                    try_emit_anchor(top_p, ANCHOR_KIND_TARGET_TOP);
                }
            }
        }
    }
}
