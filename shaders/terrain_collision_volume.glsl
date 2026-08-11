#[compute]
#version 450

// Expand a 2D RF terrain/base collision image through all volume slices.
// Inputs:
//   set0/binding0: R32F terrain collision texture.
// Outputs:
//   set0/binding1: collision volume buffer, one uint32 per voxel (quantized
//   unorm8 value 0..255 in the low byte).

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_terrain_collision;

layout(set = 0, binding = 1, std430) restrict buffer CollisionVolume {
    uint collision_field_u32[];
};

// 规范网格词汇（grid_x/y/z），与 scatter / merge / pick / score 同一套索引式。
// 迁移前是 (xz_res, total_slices) + `xz_area = xz_res * xz_res` 的方形式。
// voxel_count 由 gx*gy*gz 导出（CPU 侧本来就是这么算的），省下的字给 grid_z。
layout(push_constant, std430) uniform Params {
    int grid_x;
    int grid_y;      // = slice 数
    int grid_z;
    int src_width;
    int src_height;
    float occupied_epsilon;
    float _pad0;
    float _pad1;
};

uint quantize_unorm8(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * 255.0));
}

// Each invocation owns one voxel, so the pass fully initializes the output.
void store_r8(uint index, float value) {
    collision_field_u32[index] = quantize_unorm8(value);
}

void main() {
    uint idx_u = gl_GlobalInvocationID.x;
    int voxel_count = max(grid_x, 0) * max(grid_y, 0) * max(grid_z, 0);
    if (idx_u >= uint(voxel_count)) {
        return;
    }

    // 规范索引式 x + gx * (z + gz * y) 的逆：切片内偏移再拆 z/x。
    int idx = int(idx_u);
    int plane_voxels = max(grid_x * grid_z, 1);
    int slice_offset = idx % plane_voxels;
    int x = slice_offset % grid_x;
    int z = slice_offset / grid_x;

    float value = 0.0;
    if (x < src_width && z < src_height) {
        value = clamp(texelFetch(t_terrain_collision, ivec2(x, z), 0).r, 0.0, 1.0);
        if (value <= occupied_epsilon) {
            value = 0.0;
        }
    }
    store_r8(idx_u, value);
}
