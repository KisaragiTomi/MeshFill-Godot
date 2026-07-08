#[compute]
#version 450

// Converts the resident SV/BlendSV 8-bit field pair into the prefilter's merged
// float2-per-voxel complexity/collision buffer, replacing the CPU pack path.
// One thread per voxel.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ComplexityField {
    uint complexity_field_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionField {
    uint collision_field_r8_words[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer MergedFieldPair {
    vec2 complexity_collision[];
};

layout(push_constant, std430) uniform Params {
    int voxel_count;
    int reserved0;
    int reserved1;
    int reserved2;
};

void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= uint(max(voxel_count, 0))) {
        return;
    }
    float complexity = float(complexity_field_rgba8[index] & 0xFFu) / 255.0;
    uint word = collision_field_r8_words[index >> 2u];
    uint shift = (index & 3u) * 8u;
    float collision = float((word >> shift) & 0xFFu) / 255.0;
    complexity_collision[index] = vec2(complexity, collision);
}
