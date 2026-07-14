#[compute]
#version 450

// Packs TargetSV visual RGBA8 into a vec4 field. Alpha is target complexity.
// Target collision remains in a separate packed-R8 buffer.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ColorRgba8 {
    uint color_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer TargetField {
    vec4 target_field[];
};

layout(push_constant, std430) uniform Params {
    int voxel_count;
};

vec4 unpack_rgba8(uint packed) {
    return vec4(
        float((packed >> 24u) & 0xFFu) / 255.0,
        float((packed >> 16u) & 0xFFu) / 255.0,
        float((packed >>  8u) & 0xFFu) / 255.0,
        float((packed >>  0u) & 0xFFu) / 255.0
    );
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= uint(voxel_count)) return;
    target_field[idx] = unpack_rgba8(color_rgba8[idx]);
}
