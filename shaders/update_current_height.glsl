#[compute]
#version 450

#define SHARE_TEX_SIZE 32

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D rw_current_scene_depth_a;
layout(rgba16f, set = 0, binding = 1) uniform image2D rw_current_scene_depth_b;
layout(rgba16f, set = 0, binding = 2) uniform image2D rw_result_a;
layout(rgba16f, set = 0, binding = 3) uniform image2D rw_result_b;
layout(rgba16f, set = 0, binding = 4) uniform image2D rw_debug_view;

layout(set = 1, binding = 0) uniform sampler2D t_mesh_depth;
layout(set = 1, binding = 1) uniform sampler2D t_scene_normal;
layout(set = 1, binding = 2) uniform sampler2D t_target_height;

layout(push_constant, std430) uniform Params {
    float max_height;      // offset 0
    float capture_size;    // offset 4
    int select_index;      // offset 8
    float overlap_ratio;   // offset 12
    int dirty_x;           // offset 16
    int dirty_y;           // offset 20
    int dirty_w;           // offset 24
    int dirty_h;           // offset 28
};

vec2 rot_uv(vec2 uv, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return vec2(c * uv.x + s * uv.y, -s * uv.x + c * uv.y);
}

vec2 scale_uv(vec2 uv, vec2 s) {
    return vec2(uv.x * s.x, uv.y * s.y);
}

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 work_size = imageSize(rw_current_scene_depth_a);
    if (pos.x >= work_size.x || pos.y >= work_size.y) {
        return;
    }
    uvec3 local_id = gl_LocalInvocationID;

    ivec2 max_result = imageSize(rw_result_a);
    vec4 result_idx_color = imageLoad(rw_result_a, ivec2(max_result.x - 1, max_result.y - 1));
    uint result_index = uint(result_idx_color.x);
    uint max_result_count = uint(result_idx_color.z);

    imageStore(rw_result_b, pos, imageLoad(rw_result_a, pos));

    float max_cell = float(work_size.x);
    ivec2 mesh_max_cell = textureSize(t_mesh_depth, 0);

    vec4 current_depth_color = imageLoad(rw_current_scene_depth_a, pos);
    float current_height = current_depth_color.x;
    float current_mask = current_depth_color.y;
    float current_gen_mask = current_depth_color.z;

    for (uint i = 0u; i < max_result_count; i++) {
        uint cur_idx = result_index - i - 1u;

        vec4 result_pos = imageLoad(rw_result_a, ivec2(int(cur_idx), 0));
        vec4 result_rot_size = imageLoad(rw_result_a, ivec2(int(cur_idx), 1));
        float rot = result_rot_size.x;
        float scl = result_rot_size.y;
        float scene_h = result_pos.z;

        vec2 uv = (vec2(pos) + 0.5) / max_cell;

        uv -= result_pos.xy;
        uv = rot_uv(uv, rot);
        uv = scale_uv(uv, vec2(1.0 / scl));
        uv += 0.5;

        if (uv.x > 1.0 || uv.y > 1.0 || uv.x < 0.0 || uv.y < 0.0) continue;

        ivec2 mesh_idx = ivec2(uv * vec2(mesh_max_cell));
        float mesh_h = texelFetch(t_mesh_depth, mesh_idx, 0).x;
        float mesh_mask_val = float(mesh_h > -10000.0);
        if (mesh_mask_val < 0.5) continue;

        float draw_h = mesh_h + scene_h * mesh_mask_val;
        float draw_mask = float(draw_h > current_height);

        float effective_draw_h = mix(draw_h, current_height, overlap_ratio);
        float local_target = texelFetch(t_target_height, pos, 0).x;
        float clamp_to = local_target > 0.01 ? local_target : max_height;
        float fix_depth = min(max(current_height, effective_draw_h), clamp_to);
        float mask_val = max(current_mask, draw_mask);
        current_depth_color.xyz = vec3(fix_depth, mask_val, current_gen_mask);
        current_height = current_depth_color.x;
        current_mask = current_depth_color.y;
        current_gen_mask = current_depth_color.z;
    }

    bool in_dirty = pos.x >= dirty_x && pos.y >= dirty_y
                    && pos.x < dirty_x + dirty_w && pos.y < dirty_y + dirty_h;
    if (in_dirty) {
        imageStore(rw_current_scene_depth_b, pos, current_depth_color);
    }
    imageStore(rw_result_b, ivec2(max_result.x - 1, max_result.y - 1), vec4(float(result_index), float(result_index), float(max_result_count), 0.0));
}
