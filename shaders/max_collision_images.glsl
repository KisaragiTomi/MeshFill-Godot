#[compute]
#version 450

// Max-composite two scalar collision fields.
// Inputs: two R32F collision textures fetched by integer pixel coordinate.
// Output: one R32F storage image where out.r = max(a.r, b.r).

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_collision_a;
layout(set = 0, binding = 1) uniform sampler2D t_collision_b;

layout(r32f, set = 1, binding = 0) uniform writeonly image2D rw_collision_max;

layout(push_constant, std430) uniform Params {
    int width;
    int height;
    int _pad0;
    int _pad1;
};

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= width || pos.y >= height) {
        return;
    }

    float a = texelFetch(t_collision_a, pos, 0).r;
    float b = texelFetch(t_collision_b, pos, 0).r;
    imageStore(rw_collision_max, pos, vec4(max(a, b), 0.0, 0.0, 0.0));
}
