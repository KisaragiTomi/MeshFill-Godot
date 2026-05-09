#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_generated;
layout(set = 0, binding = 1) uniform sampler2D t_override_mask;
layout(set = 0, binding = 2) uniform sampler2D t_override_delta;

layout(rgba16f, set = 1, binding = 0) uniform image2D rw_output;

layout(push_constant, std430) uniform Params {
    float _pad0;
    float _pad1;
    float _pad2;
    float _pad3;
};

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 tex_size = imageSize(rw_output);
    if (pos.x >= tex_size.x || pos.y >= tex_size.y) return;

    float mask = texelFetch(t_override_mask, pos, 0).r;
    vec4 gen = texelFetch(t_generated, pos, 0);
    vec4 delta = texelFetch(t_override_delta, pos, 0);
    imageStore(rw_output, pos, gen + delta * mask);
}
