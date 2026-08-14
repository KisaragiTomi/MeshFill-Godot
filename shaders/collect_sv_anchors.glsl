#[compute]
#version 450

// Collect placeable anchor positions from dirty tiles.
// One logical workgroup = one dirty tile (8x8x8 = 512 threads).
// Host dispatch may be split over X/Y to stay inside per-axis group limits.
// Atomic-appends valid positions into AnchorOut buffer.  The anchor position
// itself carries the placement meaning; no separate anchor_kind is stored.
//
// Anchor gate: SAMPLE THE TARGET VOLUME AT THE TERRAIN HEIGHT — where the sample
// hits, emit an anchor.
//
// The grid's Y axis is terrain-relative (world.y = terrain_height * height_scale +
// grid_origin.y + (slice + 0.5) * voxel_size.y), so "the terrain height" is one FIXED
// slice for every (x, z) column: `terrain_slice` = the cell whose relative-height range
// starts at 0, computed host-side as floor(-grid_origin.y / voxel_size.y). That is why
// this gate needs no terrain height field — the height variation is already baked into
// the grid's own vertical frame.
//
// A voxel becomes an anchor iff it is INSIDE the target-occupied volume (target
// completeness byte > min_target_interest, GPU twin of Houdini's
// `volumesample(targetVol, 0, P) > 0`) AND it sits on a vertical sampling layer.
// Layers are phase-locked to `terrain_slice` and spaced `vertical_stride` apart:
//   stride <= 0  -> the terrain slice alone. This is the plain reading of the rule:
//                   one anchor per column, standing on the terrain, emitted only where
//                   the target volume actually covers the ground there.
//   stride == n  -> the terrain slice plus every n-th layer above it (stride 1 = every
//                   in-target cell at or above the terrain), i.e. the vertical density
//                   knob, now measured upward from the ground rather than from the
//                   target volume's own underside.
// Nothing BELOW the terrain slice can ever emit: the target volume routinely extends
// under the terrain (this bake: 27063 in-target cells one slice down, thousands deeper),
// and the previous bottom-of-column gate anchored to those, burying anchors underground.
//
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
    ivec4 dispatch_shape_pad;     // x = dirty dispatch groups_x, z = vertical_stride, w = terrain_slice
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

    if (!in_bounds(p)) return;

    // Vertical sampling layer test (see the gate description at the top of the file).
    // Purely local: no column scan, because the phase is the grid-wide terrain slice
    // rather than something this column has to be searched for.
    int terrain_slice = dispatch_shape_pad.w;
    int height_above_terrain = p.y - terrain_slice;
    if (height_above_terrain < 0) return;              // below ground never anchors
    int vertical_stride = dispatch_shape_pad.z;
    if (vertical_stride <= 0) {
        if (height_above_terrain != 0) return;         // terrain slice alone
    } else if ((height_above_terrain % vertical_stride) != 0) {
        return;
    }

    // "能采样到就生成" — the sample at this height decides it.
    if (in_target(voxel_index(p))) try_emit_anchor(p);
}
