#[compute]
#version 450

// Packs target color into target_field buffer.
// target_field.a is derived from max(complexity, collision) — no separate occupancy buffer.
// Binding contract:
//   set=0 binding=0: readonly uint color_rgba8[]   (RGBA8 packed color per voxel)
//   set=0 binding=1: readonly vec4  complexity_field[]   (.a = complexity)
//   set=0 binding=2: readonly float collision_field[]
//   set=0 binding=3: buffer   vec4  target_field[]   (.rgb = color, .a = max(complexity, collision))

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ColorRgba8 {
    uint color_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer ComplexityField {
    vec4 complexity_field[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer CollisionField {
    float collision_field[];
};

layout(set = 0, binding = 3, std430) restrict buffer TargetField {
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
    if (idx >= uint(voxel_count)) {
        return;
    }

    vec4 color = unpack_rgba8(color_rgba8[idx]);
    float occupancy = max(complexity_field[idx].a, collision_field[idx]);
    target_field[idx] = vec4(color.rgb, clamp(occupancy, 0.0, 1.0));
}
