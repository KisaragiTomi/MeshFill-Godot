#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer CollisionField {
    uint collision_field_u32[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionRecords {
    vec4 records[]; // x, z, slice, collision_strength
};

// 规范网格词汇（grid.xyz = grid_size，grid.w = record_count）。迁移前是
// (xz_res, total_slices, voxel_count, record_count) 四元组 + `x + xz_res*(z + xz_res*y)`
// 方形式；voxel_count 现由 gx*gy*gz 导出（CPU 侧本来就是这么算的），省下的那一格放 grid_z。
layout(push_constant, std430) uniform Params {
    ivec4 grid; // grid_x, grid_y(= slice 数), grid_z, record_count
};

uint quantize_unorm8(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * 255.0));
}

// Collision stores one quantized 0..255 value per uint32; unorm8 quantization
// preserves ordering, so a plain atomicMax is the monotonic merge.
void atomic_max_r8(uint index, float value) {
    atomicMax(collision_field_u32[index], quantize_unorm8(value));
}

void main() {
    uint record_index = gl_GlobalInvocationID.x;
    if (record_index >= uint(max(grid.w, 0))) {
        return;
    }

    vec4 record = records[record_index];
    int x = int(record.x + 0.5);
    int z = int(record.y + 0.5);
    int y = int(record.z + 0.5);
    if (
        x < 0 || x >= grid.x ||
        z < 0 || z >= grid.z ||
        y < 0 || y >= grid.y
    ) {
        return;
    }

    // 规范索引式 x + gx * (z + gz * y)（= VoxelGeneral.voxel_index）。
    int idx = x + grid.x * (z + grid.z * y);
    int voxel_count = max(grid.x, 0) * max(grid.y, 0) * max(grid.z, 0);
    if (idx < 0 || idx >= voxel_count) {
        return;
    }

    atomic_max_r8(uint(idx), record.w);
}
