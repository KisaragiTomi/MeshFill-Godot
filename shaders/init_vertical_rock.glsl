#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_scene_depth;
layout(set = 0, binding = 1) uniform sampler2D t_object_depth;
layout(set = 0, binding = 2) uniform sampler2D t_object_normal;
layout(set = 0, binding = 3) uniform sampler2D t_target_height;
layout(set = 0, binding = 4) uniform sampler2D t_rock_mask;
layout(set = 0, binding = 5) uniform sampler2D t_rock_override_mask;
layout(set = 0, binding = 6) uniform sampler2D t_rock_override_delta;

layout(rgba16f, set = 1, binding = 0) uniform image2D rw_current_scene_depth;
layout(rgba16f, set = 1, binding = 1) uniform image2D rw_target_height;
layout(rgba16f, set = 1, binding = 2) uniform image2D rw_debug_view;

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

    int max_cell = tex_size.x - 1;

    vec3 scene_normal = cal_normal(pos);
    float obj_height = max_height - min(texelFetch(t_object_depth, pos, 0).x, max_height);
    float height = max_height - texelFetch(t_scene_depth, pos, 0).x;

    bool is_bound = pos.x == 0 || pos.y == 0 || pos.x == max_cell || pos.y == max_cell;
    float prev_rock = texelFetch(t_rock_mask, pos, 0).r;
    float un_generate_mask = float(texelFetch(t_object_normal, pos, 0).z > 0.01 && obj_height > height);
    un_generate_mask = float(un_generate_mask > 0.0 || is_bound || height < 0.0 || prev_rock > 0.01);
    float generate_mask = float(dot(scene_normal, vec3(0.0, 0.0, 1.0)) < 0.75 && dot(scene_normal, vec3(0.0, 0.0, 1.0)) > 0.0);
    float rotate = atan(scene_normal.y, scene_normal.x);

    float ovr_mask = texelFetch(t_rock_override_mask, pos, 0).r;
    if (ovr_mask > 0.5) {
        float delta = texelFetch(t_rock_override_delta, pos, 0).r;
        generate_mask = clamp(generate_mask + max(delta, 0.0), 0.0, 1.0);
        un_generate_mask = clamp(un_generate_mask + max(-delta, 0.0), 0.0, 1.0);
    }

    imageStore(rw_current_scene_depth, pos, vec4(height, un_generate_mask, generate_mask, 0.0));

    float target_h = texelFetch(t_target_height, pos, 0).x;
    imageStore(rw_target_height, pos, vec4(target_h, generate_mask, rotate, 0.0));
}
