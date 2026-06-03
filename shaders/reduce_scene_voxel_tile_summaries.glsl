#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SceneField {
    float scene_field[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionField {
    float collision_field[];
};

layout(set = 0, binding = 2, std430) restrict buffer TileSummaries {
    uint summary[];
};

layout(push_constant, std430) uniform Params {
    ivec4 dims;      // xz_res, total_slices, voxel_count, tile_count
    ivec4 tile_size; // tile_size_x, tile_size_y, tile_size_z, summary_stride
    ivec4 tile_grid; // tile_grid_x, tile_grid_y, tile_grid_z, unused
    vec4 params;     // occupied_threshold, quant_scale, unused, unused
};

uint quantize_unit(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * max(params.y, 1.0)));
}

void reduce_value(int tile_index, int count_offset, int min_offset, int max_offset, float value) {
    if (tile_index < 0 || tile_index >= dims.w || value <= params.x) {
        return;
    }

    int base = tile_index * tile_size.w;
    uint q = quantize_unit(value);
    atomicAdd(summary[base + count_offset], 1u);
    atomicMin(summary[base + min_offset], q);
    atomicMax(summary[base + max_offset], q);
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    int voxel_count = max(dims.z, 0);
    if (idx >= uint(voxel_count)) {
        return;
    }

    int xz_res = max(dims.x, 0);
    int total_slices = max(dims.y, 0);
    int plane_voxels = xz_res * xz_res;
    if (xz_res <= 0 || total_slices <= 0 || plane_voxels <= 0) {
        return;
    }

    int slice_index = int(idx / uint(plane_voxels));
    if (slice_index < 0 || slice_index >= total_slices) {
        return;
    }

    int in_slice = int(idx - uint(slice_index * plane_voxels));
    int z = in_slice / xz_res;
    int x = in_slice - z * xz_res;

    int tile_x = clamp(x / max(tile_size.x, 1), 0, max(tile_grid.x - 1, 0));
    int tile_y = clamp(slice_index / max(tile_size.y, 1), 0, max(tile_grid.y - 1, 0));
    int tile_z = clamp(z / max(tile_size.z, 1), 0, max(tile_grid.z - 1, 0));
    int tile_index = tile_x + tile_grid.x * (tile_y + tile_grid.y * tile_z);

    reduce_value(tile_index, 0, 1, 2, scene_field[idx]);
    reduce_value(tile_index, 3, 4, 5, collision_field[idx]);
}
