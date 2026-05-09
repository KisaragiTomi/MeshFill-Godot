#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_terrain_height;
layout(set = 0, binding = 1) uniform sampler2D t_rock_mask;
layout(set = 0, binding = 2) uniform sampler2D t_dep_terrain;
layout(set = 0, binding = 3) uniform sampler2D t_dep_rock;

layout(r16f, set = 1, binding = 0) uniform image2D rw_override_mask;
layout(r16f, set = 1, binding = 1) uniform image2D rw_override_delta;

layout(push_constant, std430) uniform Params {
    float max_height;
    float threshold;
    float _pad0;
    float _pad1;
};

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 tex_size = imageSize(rw_override_mask);
    if (pos.x >= tex_size.x || pos.y >= tex_size.y) return;

    float mask = imageLoad(rw_override_mask, pos).r;
    if (mask < 0.5) return;

    float cur_h = max_height - texelFetch(t_terrain_height, pos, 0).r;
    float saved_h = texelFetch(t_dep_terrain, pos, 0).r;
    float cur_rock = texelFetch(t_rock_mask, pos, 0).r;
    float saved_rock = texelFetch(t_dep_rock, pos, 0).r;

    bool terrain_changed = abs(cur_h - saved_h) > threshold;
    bool rock_overlap = cur_rock > 0.5 && saved_rock < 0.5;

    if (terrain_changed || rock_overlap) {
        imageStore(rw_override_mask, pos, vec4(0.0));
        imageStore(rw_override_delta, pos, vec4(0.0));
    }
}
