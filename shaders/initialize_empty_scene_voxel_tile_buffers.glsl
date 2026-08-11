#[compute]
#version 450

// Initializes the fixed empty SceneVoxelTile topology entirely on the GPU.
// Inputs: voxel grid, tile dimensions, tile grid, strides, and committed tick.
// Outputs: complete tile records, zero summaries, and zero object-reference slots.
// The owner submits and synchronizes this pass before publishing the buffers.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer TileRecords {
    uint tile_records[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer TileSummaries {
    uint tile_summaries[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer ObjectRefs {
    uint object_refs[];
};

layout(set = 0, binding = 3, std430) restrict buffer DirtyTileFlags {
    uint dirty_tile_flags[];
};

layout(set = 0, binding = 4, std430) restrict buffer DirtyTileWorklist {
    uint dirty_tile_worklist[];
};

layout(set = 0, binding = 5, std430) restrict buffer DirtyTileCount {
    uint dirty_tile_count[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size;    // voxel xyz, tile count
    ivec4 tile_size;    // tile xyz, record uint stride
    ivec4 tile_grid;    // tile-grid xyz, summary uint stride
    ivec4 layout_info;  // refs per tile, committed tick, operation, dirty flags
};

const int OP_INITIALIZE = 0;
const int OP_CLEAR_DIRTY = 1;
const int OP_FULL_DIRTY = 2;

uint fnv1a_byte(uint hash_value, uint value) {
    return (hash_value ^ value) * 16777619u;
}

uint fnv1a_decimal(uint hash_value, int value) {
    uint digits[10];
    uint count = 0u;
    uint remaining = uint(max(value, 0));
    if (remaining == 0u) {
        return fnv1a_byte(hash_value, 48u);
    }
    while (remaining > 0u && count < 10u) {
        digits[count++] = remaining % 10u;
        remaining /= 10u;
    }
    while (count > 0u) {
        count--;
        hash_value = fnv1a_byte(hash_value, 48u + digits[count]);
    }
    return hash_value;
}

uint tile_key_hash(ivec3 coord) {
    uint hash_value = 2166136261u;
    hash_value = fnv1a_decimal(hash_value, coord.x);
    hash_value = fnv1a_byte(hash_value, 58u);
    hash_value = fnv1a_decimal(hash_value, coord.y);
    hash_value = fnv1a_byte(hash_value, 58u);
    return fnv1a_decimal(hash_value, coord.z);
}

void main() {
    uint raw_index = gl_GlobalInvocationID.x;
    int tile_count = max(grid_size.w, 0);
    if (raw_index >= uint(tile_count)) {
        return;
    }

    int tile_index = int(raw_index);
    int operation = layout_info.z;
    if (operation == OP_CLEAR_DIRTY) {
        dirty_tile_flags[tile_index] = 0u;
        dirty_tile_worklist[tile_index] = 0u;
        if (tile_index == 0) {
            dirty_tile_count[0] = 0u;
            dirty_tile_count[1] = 0u;
        }
        return;
    }
    if (operation == OP_FULL_DIRTY) {
        dirty_tile_flags[tile_index] = uint(max(layout_info.w, 1));
        dirty_tile_worklist[tile_index] = uint(tile_index);
        if (tile_index == 0) {
            dirty_tile_count[0] = uint(tile_count);
            dirty_tile_count[1] = 0u;
        }
        return;
    }
    int grid_x = max(tile_grid.x, 1);
    int grid_z = max(tile_grid.z, 1);
    int plane = grid_x * grid_z;
    ivec3 coord = ivec3(
        tile_index % grid_x,
        tile_index / plane,
        (tile_index % plane) / grid_x
    );
    ivec3 safe_tile_size = max(tile_size.xyz, ivec3(1));
    ivec3 safe_grid_size = max(grid_size.xyz, ivec3(1));
    ivec3 voxel_min = clamp(coord * safe_tile_size, ivec3(0), safe_grid_size - ivec3(1));
    ivec3 voxel_max = min(voxel_min + safe_tile_size, safe_grid_size);

    int record_stride = max(tile_size.w, 32);
    int record_base = tile_index * record_stride;
    for (int word = 0; word < record_stride; word++) {
        tile_records[record_base + word] = 0u;
    }
    tile_records[record_base + 0] = uint(coord.x);
    tile_records[record_base + 1] = uint(coord.y);
    tile_records[record_base + 2] = uint(coord.z);
    tile_records[record_base + 4] = uint(safe_tile_size.x);
    tile_records[record_base + 5] = uint(safe_tile_size.y);
    tile_records[record_base + 6] = uint(safe_tile_size.z);
    tile_records[record_base + 8] = uint(voxel_min.x);
    tile_records[record_base + 9] = uint(voxel_min.y);
    tile_records[record_base + 10] = uint(voxel_min.z);
    tile_records[record_base + 11] = uint(max(layout_info.y, 0));
    tile_records[record_base + 12] = uint(voxel_max.x);
    tile_records[record_base + 13] = uint(voxel_max.y);
    tile_records[record_base + 14] = uint(voxel_max.z);
    tile_records[record_base + 16] = uint(voxel_min.x);
    tile_records[record_base + 17] = uint(voxel_min.z);
    tile_records[record_base + 18] = uint(voxel_max.x - voxel_min.x);
    tile_records[record_base + 19] = uint(voxel_max.z - voxel_min.z);
    int refs_per_tile = max(layout_info.x, 1);
    tile_records[record_base + 20] = uint(tile_index * refs_per_tile);
    tile_records[record_base + 28] = tile_key_hash(coord);

    int summary_stride = max(tile_grid.w, 8);
    int summary_base = tile_index * summary_stride;
    for (int word = 0; word < summary_stride; word++) {
        tile_summaries[summary_base + word] = 0u;
    }

    int ref_base = tile_index * refs_per_tile;
    for (int slot = 0; slot < refs_per_tile; slot++) {
        object_refs[ref_base + slot] = 0u;
    }

    dirty_tile_flags[tile_index] = uint(max(layout_info.w, 1));
    dirty_tile_worklist[tile_index] = uint(tile_index);
    if (tile_index == 0) {
        dirty_tile_count[0] = uint(tile_count);
        dirty_tile_count[1] = 0u;
    }
}
