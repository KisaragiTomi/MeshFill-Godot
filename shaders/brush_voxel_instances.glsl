#[compute]
#version 450

layout(local_size_x = 64) in;

// Brush voxel coordinates: (voxel_x, slice_index, voxel_z, _pad).
layout(set = 0, binding = 0, std430) restrict readonly buffer BrushVoxels {
    ivec4 brush_voxels[];
};

// Terrain height field, row-major, size = grid_x * grid_z. Stored as world
// height (already multiplied by height_span on the CPU staging side).
layout(set = 0, binding = 1, std430) restrict readonly buffer TerrainHeight {
    float terrain_height[];
};

// MultiMesh instance buffer (TRANSFORM_3D + use_colors): 16 floats per
// instance, 12 transform (3 rows of 3 basis + 1 origin) then 4 color.
layout(set = 0, binding = 2, std430) restrict writeonly buffer InstanceBuffer {
    float instances[];
};

// Per-voxel RGBA color, one vec4 per brush voxel.
layout(set = 0, binding = 3, std430) restrict readonly buffer BrushColors {
    vec4 brush_colors[];
};

// 坐标词汇与 voxel_field_instances.glsl / 其余 volume 同款：
// 位置 = grid_origin + (voxel + 0.5) * voxel_size，Y 再加 terrain * display_scale。
layout(push_constant, std430) uniform Params {
    int instance_count;
    int grid_x;
    int grid_y;        // = slice 数
    int grid_z;
    int height_count;
    float display_scale;
    float grid_origin_x;
    float grid_origin_y;
    float grid_origin_z;
    float voxel_size_x;
    float voxel_size_y;
    float voxel_size_z;
    float brush_r;
    float brush_g;
    float brush_b;
    float brush_a;
};

const int FLOATS_PER_INSTANCE = 16;

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= uint(instance_count)) {
        return;
    }

    ivec4 voxel = brush_voxels[idx];
    int vx = voxel.x;
    int slice_index = voxel.y;
    int vz = voxel.z;

    int gx = max(grid_x, 1);
    int gz = max(grid_z, 1);
    float fx = grid_origin_x + (float(vx) + 0.5) * voxel_size_x;
    float fz = grid_origin_z + (float(vz) + 0.5) * voxel_size_z;

    float terrain_y = 0.0;
    int height_idx = vz * gx + vx;
    if (vx >= 0 && vx < gx && vz >= 0 && vz < gz && height_idx >= 0 && height_idx < height_count) {
        terrain_y = terrain_height[height_idx];
    }
    float wy = grid_origin_y + (float(slice_index) + 0.5) * voxel_size_y + terrain_y * display_scale;

    uint base = idx * uint(FLOATS_PER_INSTANCE);
    // Row 0: basis row x + origin.x
    instances[base + 0u] = 1.0;
    instances[base + 1u] = 0.0;
    instances[base + 2u] = 0.0;
    instances[base + 3u] = fx;
    // Row 1
    instances[base + 4u] = 0.0;
    instances[base + 5u] = 1.0;
    instances[base + 6u] = 0.0;
    instances[base + 7u] = wy;
    // Row 2
    instances[base + 8u] = 0.0;
    instances[base + 9u] = 0.0;
    instances[base + 10u] = 1.0;
    instances[base + 11u] = fz;
    // Per-voxel color from SSBO
    vec4 color = brush_colors[idx];
    instances[base + 12u] = color.r;
    instances[base + 13u] = color.g;
    instances[base + 14u] = color.b;
    instances[base + 15u] = color.a;
}