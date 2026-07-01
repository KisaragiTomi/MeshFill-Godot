#[compute]
#version 450

// Dirty-range SceneVoxelTile resident summary update pass.
//
// Binding contract, set 0:
//   binding 0: readonly uint complexity_field_rgba8[] (RGBA8 unorm, .a = complexity)
//     Dense complexity occupancy volume.
//   binding 1: readonly uint collision_field_r8_words[] (R8 unorm, four voxels per uint)
//     Dense collision occupancy volume.
//   binding 2: writeonly uint tile_summaries[]
//     Resident 32-byte SceneVoxelTile summary records, matching
//     scripts/scene_voxel_tile_codec.gd:
//       [0] complexity_min      as float bits
//       [1] complexity_max      as float bits
//       [2] collision_min  as float bits
//       [3] collision_max  as float bits
//       [4] complexity_count
//       [5] collision_count
//       [6] pad (was non_empty)
//       [7] pad
//   binding 3: readonly uint dirty_tile_indices[]
//     Transient worklist: one resident tile buffer index per dirty SceneVoxelTile
//     work item. This is intentionally not the persistent dirty index buffer,
//     because clean publish can upload that buffer as empty before the summary
//     range pass runs.
//   binding 4: readonly uint tile_records[]
//     Resident 128-byte SceneVoxelTile records. The dirty index points at this
//     buffer and the summary buffer with the same record slot.
//
// Push constants:
//   dims.x      = dense volume x/z resolution
//   dims.y      = dense volume y slice count
//   dims.z      = dense voxel count
//   dims.w      = dirty tile worklist count
//   tile_size.x = SceneVoxelTile size in x
//   tile_size.y = SceneVoxelTile size in y
//   tile_size.z = SceneVoxelTile size in z
//   tile_size.w = summary stride in uint words, expected 8
//   tile_grid.x = SceneVoxelTile grid size in x
//   tile_grid.y = SceneVoxelTile grid size in y
//   tile_grid.z = SceneVoxelTile grid size in z
//   tile_grid.w = resident tile record count, or <= 0 to derive xyz product
//   params.x    = occupied threshold, normally VOXEL_OCCUPIED_EPSILON (0.01)
//   params.y    = quantization scale, normally SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE (1000000.0)
//   params.z    = tile record stride in uint words, normally 32
//
// Dense field flattening:
//   dense_index = x + xz_res * (z + xz_res * y)
//
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ComplexityField {
    uint complexity_field_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionField {
    uint collision_field_r8_words[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer TileSummaries {
    uint tile_summaries[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer DirtyTileIndices {
    uint dirty_tile_indices[];
};

layout(set = 0, binding = 4, std430) restrict readonly buffer TileRecords {
    uint tile_records[];
};

layout(push_constant, std430) uniform Params {
    ivec4 dims;
    ivec4 tile_size;
    ivec4 tile_grid;
    vec4 params;
};

const uint LOCAL_SIZE = 64u;
const uint EMPTY_MIN_SENTINEL = 0x7fffffffu;
const uint DEFAULT_TILE_RECORD_UINT_STRIDE = 32u;
const float DEFAULT_QUANT_SCALE = 1000000.0;

shared uint shared_complexity_count[64];      // 64 * 4 = 256 bytes
shared uint shared_complexity_min[64];        // 64 * 4 = 256 bytes
shared uint shared_complexity_max[64];        // 64 * 4 = 256 bytes
shared uint shared_collision_count[64];  // 64 * 4 = 256 bytes
shared uint shared_collision_min[64];    // 64 * 4 = 256 bytes
shared uint shared_collision_max[64];    // 64 * 4 = 256 bytes
// Total shared memory: 1536 bytes.

float quant_scale() {
    return params.y > 0.0 ? params.y : DEFAULT_QUANT_SCALE;
}

uint quantize_unit(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * quant_scale()));
}

float dequantize_unit(uint value) {
    return float(value) / quant_scale();
}

vec4 unpack_rgba8(uint packed) {
    return vec4(
        float((packed >> 24u) & 0xFFu) / 255.0,
        float((packed >> 16u) & 0xFFu) / 255.0,
        float((packed >>  8u) & 0xFFu) / 255.0,
        float((packed >>  0u) & 0xFFu) / 255.0
    );
}

float load_r8(uint index) {
    uint word = collision_field_r8_words[index >> 2u];
    uint shift = (index & 3u) * 8u;
    return float((word >> shift) & 0xFFu) / 255.0;
}

uint tile_record_stride() {
    return params.z > 0.0 ? uint(round(params.z)) : DEFAULT_TILE_RECORD_UINT_STRIDE;
}

int tile_count() {
    if (tile_grid.w > 0) {
        return tile_grid.w;
    }

    if (tile_grid.x <= 0 || tile_grid.y <= 0 || tile_grid.z <= 0) {
        return 0;
    }

    return tile_grid.x * tile_grid.y * tile_grid.z;
}

bool params_are_valid() {
    return (
        dims.x > 0
        && dims.y > 0
        && dims.z > 0
        && dims.w > 0
        && tile_size.x > 0
        && tile_size.y > 0
        && tile_size.z > 0
        && tile_size.w >= 8
        && tile_count() > 0
    );
}

ivec3 tile_record_ivec3(uint tile_index, uint word_offset) {
    uint base = tile_index * tile_record_stride() + word_offset;
    return ivec3(
        int(tile_records[base + 0u]),
        int(tile_records[base + 1u]),
        int(tile_records[base + 2u])
    );
}

int dense_index(ivec3 p) {
    return p.x + dims.x * (p.z + dims.x * p.y);
}

bool dense_coord_in_bounds(ivec3 p) {
    return (
        p.x >= 0 && p.x < dims.x
        && p.y >= 0 && p.y < dims.y
        && p.z >= 0 && p.z < dims.x
    );
}

void scan_value(float value, inout uint count, inout uint min_q, inout uint max_q) {
    if (!(value > params.x)) {
        return;
    }

    uint q = quantize_unit(value);
    count++;
    min_q = min(min_q, q);
    max_q = max(max_q, q);
}

void write_summary(uint tile_index, uint complexity_count, uint complexity_min_q, uint complexity_max_q, uint collision_count, uint collision_min_q, uint collision_max_q) {
    uint base = tile_index * uint(tile_size.w);
    bool has_complexity = complexity_count > 0u;
    bool has_collision = collision_count > 0u;

    tile_summaries[base + 0u] = floatBitsToUint(has_complexity ? dequantize_unit(complexity_min_q) : 0.0);
    tile_summaries[base + 1u] = floatBitsToUint(has_complexity ? dequantize_unit(complexity_max_q) : 0.0);
    tile_summaries[base + 2u] = floatBitsToUint(has_collision ? dequantize_unit(collision_min_q) : 0.0);
    tile_summaries[base + 3u] = floatBitsToUint(has_collision ? dequantize_unit(collision_max_q) : 0.0);
    tile_summaries[base + 4u] = complexity_count;
    tile_summaries[base + 5u] = collision_count;
    // [6] pad — previously non_empty; use complexity_count > 0 || collision_count > 0 instead
    tile_summaries[base + 6u] = 0u;
    tile_summaries[base + 7u] = 0u;
}

void main() {
    if (!params_are_valid()) {
        return;
    }

    uint worklist_index = gl_WorkGroupID.x;
    if (worklist_index >= uint(dims.w)) {
        return;
    }

    uint tile_index = dirty_tile_indices[worklist_index];
    if (tile_index >= uint(tile_count())) {
        return;
    }

    uint local_index = gl_LocalInvocationIndex;
    ivec3 volume_max = ivec3(dims.x, dims.y, dims.x);
    ivec3 tile_min = clamp(tile_record_ivec3(tile_index, 8u), ivec3(0), max(volume_max - ivec3(1), ivec3(0)));
    ivec3 tile_max = clamp(tile_record_ivec3(tile_index, 12u), tile_min, volume_max);
    ivec3 tile_span = tile_max - tile_min;
    if (tile_span.x <= 0 || tile_span.y <= 0 || tile_span.z <= 0) {
        if (local_index == 0u) {
            write_summary(tile_index, 0u, EMPTY_MIN_SENTINEL, 0u, 0u, EMPTY_MIN_SENTINEL, 0u);
        }
        return;
    }

    uint tile_voxel_count = uint(tile_span.x * tile_span.y * tile_span.z);

    uint complexity_count = 0u;
    uint complexity_min_q = EMPTY_MIN_SENTINEL;
    uint complexity_max_q = 0u;
    uint collision_count = 0u;
    uint collision_min_q = EMPTY_MIN_SENTINEL;
    uint collision_max_q = 0u;

    for (uint tile_offset = local_index; tile_offset < tile_voxel_count; tile_offset += LOCAL_SIZE) {
        int local_x = int(tile_offset % uint(tile_span.x));
        int local_z = int((tile_offset / uint(tile_span.x)) % uint(tile_span.z));
        int local_y = int(tile_offset / uint(tile_span.x * tile_span.z));
        ivec3 p = tile_min + ivec3(local_x, local_y, local_z);
        if (!dense_coord_in_bounds(p)) {
            continue;
        }

        int idx = dense_index(p);
        if (idx < 0 || idx >= dims.z) {
            continue;
        }

        scan_value(unpack_rgba8(complexity_field_rgba8[idx]).a, complexity_count, complexity_min_q, complexity_max_q);
        scan_value(load_r8(uint(idx)), collision_count, collision_min_q, collision_max_q);
    }

    shared_complexity_count[local_index] = complexity_count;
    shared_complexity_min[local_index] = complexity_min_q;
    shared_complexity_max[local_index] = complexity_max_q;
    shared_collision_count[local_index] = collision_count;
    shared_collision_min[local_index] = collision_min_q;
    shared_collision_max[local_index] = collision_max_q;
    barrier();

    for (uint step = LOCAL_SIZE / 2u; step > 0u; step >>= 1u) {
        if (local_index < step) {
            uint rhs = local_index + step;
            shared_complexity_count[local_index] += shared_complexity_count[rhs];
            shared_complexity_min[local_index] = min(shared_complexity_min[local_index], shared_complexity_min[rhs]);
            shared_complexity_max[local_index] = max(shared_complexity_max[local_index], shared_complexity_max[rhs]);
            shared_collision_count[local_index] += shared_collision_count[rhs];
            shared_collision_min[local_index] = min(shared_collision_min[local_index], shared_collision_min[rhs]);
            shared_collision_max[local_index] = max(shared_collision_max[local_index], shared_collision_max[rhs]);
        }
        barrier();
    }

    if (local_index == 0u) {
        write_summary(
            tile_index,
            shared_complexity_count[0],
            shared_complexity_min[0],
            shared_complexity_max[0],
            shared_collision_count[0],
            shared_collision_min[0],
            shared_collision_max[0]
        );
    }
}
