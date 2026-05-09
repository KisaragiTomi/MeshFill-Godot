#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_scene_depth;
layout(set = 0, binding = 1) uniform sampler2D t_rock_mask;

layout(rgba16f, set = 1, binding = 0) uniform image2D rw_nutrition;

layout(push_constant, std430) uniform Params {
    float max_height;
    float capture_size;
    int dirty_x;
    int dirty_y;
    int dirty_w;
    int dirty_h;
    int _pad0;
    int _pad1;
};

vec3 cal_normal(ivec2 pos) {
    ivec2 tex_size = textureSize(t_scene_depth, 0);
    int max_cell = tex_size.x - 1;

    ivec2 xyl = clamp(pos + ivec2(-1, 0), ivec2(0), ivec2(max_cell));
    ivec2 xyr = clamp(pos + ivec2(1, 0), ivec2(0), ivec2(max_cell));
    ivec2 xyb = clamp(pos + ivec2(0, 1), ivec2(0), ivec2(max_cell));
    ivec2 xyt = clamp(pos + ivec2(0, -1), ivec2(0), ivec2(max_cell));

    float height_l = max_height - texelFetch(t_scene_depth, xyl, 0).x;
    float height_r = max_height - texelFetch(t_scene_depth, xyr, 0).x;
    float height_b = max_height - texelFetch(t_scene_depth, xyb, 0).x;
    float height_t = max_height - texelFetch(t_scene_depth, xyt, 0).x;

    vec3 dir_ddx = vec3(vec2(xyr - xyl) / float(max_cell) * capture_size, height_r - height_l);
    vec3 dir_ddy = vec3(vec2(xyt - xyb) / float(max_cell) * capture_size, height_t - height_b);

    dir_ddx = length(dir_ddx) > 0.001 ? normalize(dir_ddx) : vec3(0.0, 0.0, 1.0);
    dir_ddy = length(dir_ddy) > 0.001 ? normalize(dir_ddy) : vec3(0.0, 0.0, 1.0);

    return cross(dir_ddy, dir_ddx);
}

void main() {
    ivec2 local_id = ivec2(gl_GlobalInvocationID.xy);
    if (local_id.x >= dirty_w || local_id.y >= dirty_h) return;
    ivec2 pos = ivec2(dirty_x + local_id.x, dirty_y + local_id.y);
    ivec2 tex_size = textureSize(t_scene_depth, 0);
    if (pos.x >= tex_size.x || pos.y >= tex_size.y) return;

    float h = max_height - texelFetch(t_scene_depth, pos, 0).r;
    float rock = texelFetch(t_rock_mask, pos, 0).r;
    vec3 normal = cal_normal(pos);
    float slope = length(normal.xy);

    float h_norm = clamp(h / max_height, 0.0, 1.0);
    float h_factor = 1.0 - abs(h_norm - 0.3) * 1.5;
    h_factor = clamp(h_factor, 0.05, 1.0);

    float slope_factor = 1.0 - clamp(slope * 3.0, 0.0, 1.0);

    float rock_factor = 1.0 - clamp(rock, 0.0, 1.0);

    float nutrition = h_factor * slope_factor * rock_factor;
    imageStore(rw_nutrition, pos, vec4(nutrition, 0.0, 0.0, 0.0));
}
