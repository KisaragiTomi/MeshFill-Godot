#[compute]
#version 450

// Collect placeable anchor positions from dirty tiles.
// One logical workgroup = one dirty tile (8x8x8 = 512 threads).
// Host dispatch may be split over X/Y to stay inside per-axis group limits.
// Atomic-appends valid positions into AnchorOut buffer.  The anchor position
// itself carries the placement meaning; no separate anchor_kind is stored.
//
// Anchor gate: a voxel becomes an anchor iff it is INSIDE the target-occupied
// volume (target completeness byte > min_target_interest, GPU twin of Houdini's
// `volumesample(targetVol, 0, P) > 0`) AND it is the BOTTOMMOST such voxel in its
// (x, z) column — no in-target voxel exists below it. A lower in-target cell
// overrides (covers) higher ones, so at most one anchor is emitted per column
// (the lowest qualifying cell) and no anchor ever stacks above another. A vertical
// gap / overhang keeps only the column's very bottom in-target cell by design.
// "Below" is -y (the grid's up axis is +y; the old support gate also probed p.y-1).
// The former scene-occupancy / collision / support-below gates were dropped — the
// score stage already penalizes collision/overlap and enforces object spacing, so
// re-testing them here was redundant.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TargetField {
    uint target_field_rgba8[];  // packed r<<24|g<<16|b<<8|a；alpha 字节 = target completeness
};

layout(set = 0, binding = 1, std430) restrict readonly buffer TargetCollision {
    uint target_collision_u32[];  // one uint per voxel, quantized 0..255 in the low byte
};

layout(set = 0, binding = 2, std430) restrict readonly buffer DirtyTiles {
    uint dirty_tile_ids[];
};

// Output: packed anchors (x, y, z, reserved) as uvec4
layout(set = 0, binding = 3, std430) restrict buffer AnchorOut {
    uvec4 anchors[];
};

// Output: atomic counter for number of anchors written
layout(set = 0, binding = 4, std430) restrict buffer AnchorCount {
    uint anchor_count;
};

layout(set = 0, binding = 5, std430) restrict readonly buffer DirtyTileCount {
    uint dirty_tile_count[];
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

float load_target_collision(uint index) {
    return float(target_collision_u32[index] & 0xFFu) * (1.0 / 255.0);
}

// Phase 2：与 load_target_collision 用同一个反量化式子。
// 迁移前这里是 pack_target_field.glsl 的 `/ 255.0`，而 load_target_collision 是
// `* (1.0/255.0)`——in_target 的 max() 因此在同一个表达式里混用两种式子（256 个字节值里
// 有 126 个 float32 结果不同）。统一到共享形式后该不一致消失。
float load_target_complexity(uint index) {
    return float(target_field_rgba8[index] & 0xFFu) * (1.0 / 255.0);
}

// A cell is "inside the target volume" when its target completeness (.a) or its
// quantized target collision clears the interest threshold (thresholds.w).
bool in_target(int index) {
    float tv = max(load_target_complexity(uint(index)), load_target_collision(uint(index)));
    return tv > thresholds.w;
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
    uint dirty_count = min(dirty_tile_count[0], uint(max(grid_size_pad.w, 0)));
    if (group_idx >= dirty_count) return;

    uint tile_id = dirty_tile_ids[group_idx];
    ivec3 tile_origin = tile_id_to_origin(tile_id);
    ivec3 p = tile_origin + ivec3(gl_LocalInvocationID.xyz);

    // Anchor iff the cell is inside the target volume AND is the bottommost such
    // cell in its column: a lower in-target cell overrides (covers) higher ones, so
    // scan downward and reject if any voxel below p is also in-target. Still exactly
    // one anchor per (x,z) column ("no anchor above an anchor"), now the lowest cell.
    if (in_bounds(p) && in_target(voxel_index(p))) {
        bool bottommost = true;
        for (int y = p.y - 1; y >= 0; --y) {
            if (in_target(voxel_index(ivec3(p.x, y, p.z)))) {
                bottommost = false;
                break;
            }
        }
        if (bottommost) {
            try_emit_anchor(p);
        }
    }
}
