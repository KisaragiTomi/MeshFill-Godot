#[compute]
#version 450

// Expand a 2D RF terrain/base collision image through all volume slices.
// Inputs:
//   set0/binding0: R32F terrain collision texture.
// Outputs:
//   set0/binding1: float collision volume buffer, flattened x + xz_res * (z + xz_res * y).

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_terrain_collision;

layout(set = 0, binding = 1, std430) restrict writeonly buffer CollisionVolume {
    float collision_field[];
};

layout(push_constant, std430) uniform Params {
    int xz_res;
    int total_slices;
    int src_width;
    int src_height;
    int voxel_count;
    float occupied_epsilon;
    float _pad0;
    float _pad1;
};

void main() {
    uint idx_u = gl_GlobalInvocationID.x;
    if (idx_u >= uint(voxel_count)) {
        return;
    }

    int idx = int(idx_u);
    int xz_area = xz_res * xz_res;
    int slice_offset = idx % xz_area;
    int x = slice_offset % xz_res;
    int z = slice_offset / xz_res;

    float value = 0.0;
    if (x < src_width && z < src_height) {
        value = clamp(texelFetch(t_terrain_collision, ivec2(x, z), 0).r, 0.0, 1.0);
        if (value <= occupied_epsilon) {
            value = 0.0;
        }
    }
    collision_field[idx] = value;
}
