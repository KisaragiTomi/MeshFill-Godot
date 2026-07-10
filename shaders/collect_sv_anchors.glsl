#[compute]
#version 450

// Collect placeable anchor positions from dirty tiles.
// One logical workgroup = one dirty tile (8x8x8 = 512 threads).
// Host dispatch may be split over X/Y to stay inside per-axis group limits.
// Atomic-appends valid positions into AnchorOut buffer.  The anchor position
// itself carries the placement meaning; no separate anchor_kind is stored.
//
// Anchor gate (Houdini Pipeline.hip parity): a voxel becomes an anchor iff it
// lies INSIDE the target-occupied volume, i.e. target_field[idx].a > min_target_interest.
// This is the GPU twin of Houdini's `i@anchor = volumesample(targetVol, 0, P) > 0`:
// the anchor stage only answers "is this cell within the desired target region".
// The former scene-occupancy / collision / support-below gates were dropped — the
// score stage already penalizes collision/overlap and enforces object spacing, so
// re-testing them here was redundant work (and cost an extra field read + a
// below-neighbor probe per voxel).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TargetField {
    vec4 target_field[];  // .rgb = target color, .a = completeness = max(complexity, collision)
};

layout(set = 0, binding = 1, std430) restrict readonly buffer DirtyTiles {
    uint dirty_tile_ids[];
};

// Output: packed anchors (x, y, z, reserved) as uvec4
layout(set = 0, binding = 2, std430) restrict buffer AnchorOut {
    uvec4 anchors[];
};

// Output: atomic counter for number of anchors written
layout(set = 0, binding = 3, std430) restrict buffer AnchorCount {
    uint anchor_count;
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_pad;          // xyz = grid dims, w = dirty_tile_count
    ivec4 tile_grid_size_pad;     // xyz = tile grid dims, w = anchor_capacity
    vec4  thresholds;             // w = min_target_interest (x/y/z retired: scene/collision/support gates dropped)
    ivec4 dispatch_shape_pad;     // x = dirty dispatch groups_x
};

const uint TILE_SIZE = 8u;

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

void try_emit_anchor(ivec3 p) {
    uint cap = uint(tile_grid_size_pad.w);
    uint idx = atomicAdd(anchor_count, 1u);
    if (idx < cap) {
        anchors[idx] = uvec4(uint(p.x), uint(p.y), uint(p.z), 0u);
    }
}

void main() {
    uint dispatch_groups_x = uint(max(dispatch_shape_pad.x, 1));
    uint group_idx = gl_WorkGroupID.y * dispatch_groups_x + gl_WorkGroupID.x;
    uint dirty_count = uint(max(grid_size_pad.w, 0));
    if (group_idx >= dirty_count) return;

    uint tile_id = dirty_tile_ids[group_idx];
    ivec3 tile_origin = tile_id_to_origin(tile_id);
    ivec3 p = tile_origin + ivec3(gl_LocalInvocationID.xyz);

    float min_target = thresholds.w;

    // Anchor iff the cell is inside the target-occupied volume.
    if (in_bounds(p)) {
        int idx = voxel_index(p);
        float tv = target_field[idx].a;
        if (tv > min_target) {
            try_emit_anchor(p);
        }
    }
}
