#[compute]
#version 450

// SceneVoxelTile numeric object-ref update pass.
//
// Binding contract, set 0:
//   binding 0: readonly int dirty_delta_words[]
//     20 x 32-bit words per delta, matching GPUAutoObjectRuntime
//     DIRTY_DELTA_STRIDE_BYTES = 80. Signed integer fields are stored as s32.
//   binding 1: uint object_refs[]
//     Fixed SceneVoxelTile object-ref slots:
//       object_refs[tile_index * refs_per_tile + slot]
//       0 = empty, numeric GPU AutoObject ref_key = object_id + 1.
//   binding 2: uint stats[]
//     Optional diagnostics. Bind at least a 1-u32 dummy buffer and set
//     capacities.w = 0 to disable writes. If enabled, zero before dispatch when
//     non-cumulative stats are desired.
//
// Push constants:
//   grid_size.xyz    = voxel grid dimensions
//   grid_size.w      = dirty_delta_count
//   tile_size.xyz    = SceneVoxelTile voxel dimensions
//   tile_size.w      = refs_per_tile
//   tile_grid.xyz    = SceneVoxelTile grid dimensions
//   tile_grid.w      = tile_count, or <= 0 to derive xyz product
//   capacities.x     = dirty_delta_capacity, or <= 0 to trust dirty_delta_count
//   capacities.y     = object_ref_capacity in u32 slots
//   capacities.z     = max numeric object_id count, or <= 0 for no limit
//   capacities.w     = stats_capacity in u32 counters
//   options.x bit 0  = parallel-by-delta mode. When unset, invocation 0 applies
//                      deltas in input order for conservative same-object safety.
//
// Stats layout:
//   0 overflow        insertion found no empty slot, or slot range exceeded capacity
//   1 non_numeric     negative object_id or object_id outside capacities.z
//   2 duplicate       insert found the ref already present in a tile
//   3 touched         tile touch events, not unique tiles
//   4 removed_slots   ref slots cleared
//   5 inserted_slots  ref slots filled
//   6 invalid_bounds  invalid grid/tile/object-ref parameters
//   7 skipped         deltas skipped by conservative guards
//
// Tile flattening follows the SceneVoxelTile GPU AutoObject convention:
//   tile_index = x + tile_grid_x * (z + tile_grid_z * y)

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer DirtyDeltas {
    int dirty_delta_words[];
};

layout(set = 0, binding = 1, std430) restrict buffer ObjectRefs {
    uint object_refs[];
};

layout(set = 0, binding = 2, std430) restrict buffer Stats {
    uint stats[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size;
    ivec4 tile_size;
    ivec4 tile_grid;
    ivec4 capacities;
    ivec4 options;
};

const uint DIRTY_DELTA_WORD_STRIDE = 20u;

const uint DELTA_OBJECT_ID = 0u;
const uint DELTA_OLD_MIN_X = 4u;
const uint DELTA_OLD_MIN_Y = 5u;
const uint DELTA_OLD_MIN_Z = 6u;
const uint DELTA_REMOVED = 7u;
const uint DELTA_OLD_MAX_X = 8u;
const uint DELTA_OLD_MAX_Y = 9u;
const uint DELTA_OLD_MAX_Z = 10u;
const uint DELTA_ALIVE_AFTER = 11u;
const uint DELTA_NEW_MIN_X = 12u;
const uint DELTA_NEW_MIN_Y = 13u;
const uint DELTA_NEW_MIN_Z = 14u;
const uint DELTA_NEW_MAX_X = 16u;
const uint DELTA_NEW_MAX_Y = 17u;
const uint DELTA_NEW_MAX_Z = 18u;

const uint STAT_OVERFLOW = 0u;
const uint STAT_NON_NUMERIC = 1u;
const uint STAT_DUPLICATE = 2u;
const uint STAT_TOUCHED = 3u;
const uint STAT_REMOVED_SLOTS = 4u;
const uint STAT_INSERTED_SLOTS = 5u;
const uint STAT_INVALID_BOUNDS = 6u;
const uint STAT_SKIPPED = 7u;

const int MODE_PARALLEL_BY_DELTA = 1;

void stat_add(uint stat_index, uint amount) {
    if (amount == 0u) {
        return;
    }

    int stats_capacity = max(capacities.w, 0);
    if (stat_index >= uint(stats_capacity)) {
        return;
    }

    atomicAdd(stats[stat_index], amount);
}

int dirty_delta_count() {
    int count = max(grid_size.w, 0);
    int capacity = capacities.x > 0 ? capacities.x : count;
    return min(count, max(capacity, 0));
}

int tile_count() {
    if (tile_grid.x <= 0 || tile_grid.y <= 0 || tile_grid.z <= 0) {
        return 0;
    }

    int product = tile_grid.x * tile_grid.y * tile_grid.z;
    if (tile_grid.w > 0) {
        return min(tile_grid.w, product);
    }
    return product;
}

bool params_are_valid() {
    return (
        grid_size.x > 0 && grid_size.y > 0 && grid_size.z > 0
        && tile_size.x > 0 && tile_size.y > 0 && tile_size.z > 0
        && tile_size.w > 0
        && tile_count() > 0
        && capacities.y > 0
    );
}

ivec3 normalize_min(ivec3 voxel_min, ivec3 voxel_max) {
    ivec3 max_grid_index = max(grid_size.xyz - ivec3(1), ivec3(0));
    return clamp(min(voxel_min, voxel_max - ivec3(1)), ivec3(0), max_grid_index);
}

ivec3 normalize_max(ivec3 voxel_min, ivec3 voxel_max, ivec3 normalized_min) {
    ivec3 grid_limit = max(grid_size.xyz, ivec3(1));
    return clamp(max(voxel_min + ivec3(1), voxel_max), normalized_min + ivec3(1), grid_limit);
}

ivec3 tile_coord_from_voxel(ivec3 p) {
    ivec3 tile = p / tile_size.xyz;
    return clamp(tile, ivec3(0), max(tile_grid.xyz - ivec3(1), ivec3(0)));
}

int tile_index_from_coord(ivec3 tile_coord) {
    return tile_coord.x + tile_grid.x * (tile_coord.z + tile_grid.z * tile_coord.y);
}

bool tile_range_from_bounds(
    ivec3 voxel_min,
    ivec3 voxel_max,
    out ivec3 tile_min,
    out ivec3 tile_max
) {
    if (!params_are_valid()) {
        return false;
    }

    ivec3 min_v = normalize_min(voxel_min, voxel_max);
    ivec3 max_v = normalize_max(voxel_min, voxel_max, min_v);
    tile_min = tile_coord_from_voxel(min_v);
    tile_max = tile_coord_from_voxel(max_v - ivec3(1));
    return all(lessThanEqual(tile_min, tile_max));
}

uint slot_count_for_tile(int tile_index, out uint slot_base) {
    int safe_tile_count = tile_count();
    if (tile_index < 0 || tile_index >= safe_tile_count) {
        slot_base = 0u;
        return 0u;
    }

    uint refs_per_tile = uint(max(tile_size.w, 1));
    slot_base = uint(tile_index) * refs_per_tile;
    uint object_ref_capacity = uint(max(capacities.y, 0));
    if (slot_base >= object_ref_capacity) {
        return 0u;
    }

    return min(refs_per_tile, object_ref_capacity - slot_base);
}

void remove_ref_from_tile(int tile_index, uint ref_key) {
    uint slot_base = 0u;
    uint slot_count = slot_count_for_tile(tile_index, slot_base);
    if (slot_count == 0u) {
        stat_add(STAT_OVERFLOW, 1u);
        return;
    }

    uint removed_count = 0u;
    for (uint slot = 0u; slot < slot_count; slot++) {
        uint slot_index = slot_base + slot;
        uint previous = atomicCompSwap(object_refs[slot_index], ref_key, 0u);
        if (previous == ref_key) {
            removed_count++;
        }
    }

    if (removed_count > 0u) {
        stat_add(STAT_REMOVED_SLOTS, removed_count);
        stat_add(STAT_TOUCHED, 1u);
    }
}

void insert_ref_into_tile(int tile_index, uint ref_key) {
    uint slot_base = 0u;
    uint slot_count = slot_count_for_tile(tile_index, slot_base);
    if (slot_count == 0u) {
        stat_add(STAT_OVERFLOW, 1u);
        return;
    }

    for (uint slot = 0u; slot < slot_count; slot++) {
        uint slot_index = slot_base + slot;
        uint previous = atomicCompSwap(object_refs[slot_index], ref_key, ref_key);
        if (previous == ref_key) {
            stat_add(STAT_DUPLICATE, 1u);
            stat_add(STAT_TOUCHED, 1u);
            return;
        }
    }

    for (uint slot = 0u; slot < slot_count; slot++) {
        uint slot_index = slot_base + slot;
        uint previous = atomicCompSwap(object_refs[slot_index], 0u, ref_key);
        if (previous == 0u) {
            stat_add(STAT_INSERTED_SLOTS, 1u);
            stat_add(STAT_TOUCHED, 1u);
            return;
        }
        if (previous == ref_key) {
            stat_add(STAT_DUPLICATE, 1u);
            stat_add(STAT_TOUCHED, 1u);
            return;
        }
    }

    stat_add(STAT_OVERFLOW, 1u);
}

void visit_tiles_for_bounds(ivec3 voxel_min, ivec3 voxel_max, uint ref_key, bool remove_ref) {
    ivec3 tile_min;
    ivec3 tile_max;
    if (!tile_range_from_bounds(voxel_min, voxel_max, tile_min, tile_max)) {
        stat_add(STAT_INVALID_BOUNDS, 1u);
        return;
    }

    int safe_tile_count = tile_count();
    for (int ty = tile_min.y; ty <= tile_max.y; ty++) {
        for (int tz = tile_min.z; tz <= tile_max.z; tz++) {
            for (int tx = tile_min.x; tx <= tile_max.x; tx++) {
                int tile_index = tile_index_from_coord(ivec3(tx, ty, tz));
                if (tile_index < 0 || tile_index >= safe_tile_count) {
                    stat_add(STAT_INVALID_BOUNDS, 1u);
                    continue;
                }

                if (remove_ref) {
                    remove_ref_from_tile(tile_index, ref_key);
                } else {
                    insert_ref_into_tile(tile_index, ref_key);
                }
            }
        }
    }
}

void process_delta(uint delta_index) {
    uint base = delta_index * DIRTY_DELTA_WORD_STRIDE;

    int object_id = dirty_delta_words[base + DELTA_OBJECT_ID];
    if (object_id < 0 || (capacities.z > 0 && object_id >= capacities.z)) {
        stat_add(STAT_NON_NUMERIC, 1u);
        stat_add(STAT_SKIPPED, 1u);
        return;
    }

    uint ref_key = uint(object_id) + 1u;
    if (ref_key == 0u) {
        stat_add(STAT_NON_NUMERIC, 1u);
        stat_add(STAT_SKIPPED, 1u);
        return;
    }

    ivec3 old_min = ivec3(
        dirty_delta_words[base + DELTA_OLD_MIN_X],
        dirty_delta_words[base + DELTA_OLD_MIN_Y],
        dirty_delta_words[base + DELTA_OLD_MIN_Z]
    );
    ivec3 old_max = ivec3(
        dirty_delta_words[base + DELTA_OLD_MAX_X],
        dirty_delta_words[base + DELTA_OLD_MAX_Y],
        dirty_delta_words[base + DELTA_OLD_MAX_Z]
    );
    ivec3 new_min = ivec3(
        dirty_delta_words[base + DELTA_NEW_MIN_X],
        dirty_delta_words[base + DELTA_NEW_MIN_Y],
        dirty_delta_words[base + DELTA_NEW_MIN_Z]
    );
    ivec3 new_max = ivec3(
        dirty_delta_words[base + DELTA_NEW_MAX_X],
        dirty_delta_words[base + DELTA_NEW_MAX_Y],
        dirty_delta_words[base + DELTA_NEW_MAX_Z]
    );

    bool removed = dirty_delta_words[base + DELTA_REMOVED] != 0;
    bool alive_after = dirty_delta_words[base + DELTA_ALIVE_AFTER] != 0;

    visit_tiles_for_bounds(old_min, old_max, ref_key, true);
    if (!removed && alive_after) {
        visit_tiles_for_bounds(new_min, new_max, ref_key, false);
    }
}

void main() {
    if (!params_are_valid()) {
        if (gl_GlobalInvocationID.x == 0u) {
            stat_add(STAT_INVALID_BOUNDS, 1u);
        }
        return;
    }

    int count = dirty_delta_count();
    if (count <= 0) {
        return;
    }

    bool parallel_by_delta = (options.x & MODE_PARALLEL_BY_DELTA) != 0;
    if (parallel_by_delta) {
        uint delta_index = gl_GlobalInvocationID.x;
        if (delta_index >= uint(count)) {
            return;
        }
        process_delta(delta_index);
        return;
    }

    if (gl_GlobalInvocationID.x != 0u) {
        return;
    }

    for (uint delta_index = 0u; delta_index < uint(count); delta_index++) {
        process_delta(delta_index);
    }
}
