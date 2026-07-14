#[compute]
#version 450

// Initializes VoxelStampBounds before stamp_asset_voxels.glsl writes accepted placements.
// One logical bound record is two uvec4 values:
//   0: uvec4(min_xyz, written_count)
//   1: uvec4(max_xyz_exclusive, reserved)

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer VoxelStampBounds {
    uvec4 stamp_bounds[];
};

layout(push_constant, std430) uniform Params {
    ivec4 bounds_count_stride_pad; // x = bound_count, y = uvec4 stride
};

void main() {
    uint index = gl_GlobalInvocationID.x;
    uint bound_count = uint(max(bounds_count_stride_pad.x, 0));
    if (index >= bound_count) {
        return;
    }

    uint stride = uint(max(bounds_count_stride_pad.y, 2));
    uint base = index * stride;
    stamp_bounds[base + 0u] = uvec4(0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu, 0u);
    stamp_bounds[base + 1u] = uvec4(0u);
}
