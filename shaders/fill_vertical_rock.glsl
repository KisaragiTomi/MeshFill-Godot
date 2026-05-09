#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D rw_current_scene_depth_a;
layout(rgba16f, set = 0, binding = 1) uniform image2D rw_current_scene_depth_b;
layout(rgba16f, set = 0, binding = 2) uniform image2D rw_result_a;
layout(rgba16f, set = 0, binding = 3) uniform image2D rw_result_b;
layout(rgba16f, set = 0, binding = 4) uniform image2D rw_filter_result;
layout(rgba16f, set = 0, binding = 5) uniform image2D rw_save_rotate_scale;
layout(rgba16f, set = 0, binding = 6) uniform image2D rw_target_height;
layout(rgba16f, set = 0, binding = 7) uniform image2D rw_debug_view;

layout(set = 1, binding = 0) uniform sampler2D t_mesh_depth;

layout(push_constant, std430) uniform Params {
    float max_height;             // offset 0
    float capture_size;           // offset 4
    float size;                   // offset 8
    float generate_threshold;     // offset 12
    float un_generate_threshold;  // offset 16
    int select_index;             // offset 20
    int dirty_x;                  // offset 24
    int dirty_y;                  // offset 28
    vec4 random_range;            // offset 32 (16-byte aligned)
    vec2 scale_range;             // offset 48
    int dirty_w;                  // offset 56
    int dirty_h;                  // offset 60
};

#define PI 3.14159265358979

float random_1d(float value) {
    return fract(sin(value * 15677.12154));
}

vec2 rot_uv_center(vec2 uv, float angle, vec2 center) {
    uv -= center;
    float s = sin(angle);
    float c = cos(angle);
    uv = vec2(c * uv.x + s * uv.y, -s * uv.x + c * uv.y);
    uv += center;
    return uv;
}

shared float share_mesh_height[16][16];
shared float compare_result[16][16];
shared vec4 select_data[16][16];

void main() {
    uvec3 dispatch_id = gl_GlobalInvocationID;
    uvec3 local_id = gl_LocalInvocationID;
    uvec3 group_id = gl_WorkGroupID;
    uint group_index = gl_LocalInvocationIndex;

    ivec2 pos = ivec2(dispatch_id.xy);
    float max_cell = float(imageSize(rw_current_scene_depth_a).x);
    vec2 uv = vec2(pos) / max_cell;
    vec2 group_uv = vec2(local_id.xy) / 16.0;

    ivec2 mesh_size_xy = textureSize(t_mesh_depth, 0);

    imageStore(rw_result_b, pos, imageLoad(rw_result_a, pos));
    imageStore(rw_current_scene_depth_b, pos, imageLoad(rw_current_scene_depth_a, pos));
    imageStore(rw_save_rotate_scale, pos, vec4(0.0));
    if (group_index == 0u) {
        imageStore(rw_filter_result, ivec2(group_id.xy), vec4(0.0));
    }

    vec4 root_scene_color = imageLoad(rw_current_scene_depth_a, pos);
    vec4 target_height_color = imageLoad(rw_target_height, pos);

    float rotate = target_height_color.z
        + (random_range.x + random_1d(float(dispatch_id.x) + float(dispatch_id.y) * 0.001) * (random_range.y - random_range.x)) * 2.0 * PI;
    float rand_height_off = random_range.z + random_1d(float(dispatch_id.x) + float(dispatch_id.y) * 0.101) * (random_range.w - random_range.z);
    float random_scale = scale_range.x + random_1d(float(dispatch_id.x) * 0.137 + float(dispatch_id.y) * 0.913) * (scale_range.y - scale_range.x);
    random_scale = max(random_scale, 0.0001);
    float target_h = target_height_color.x;
    float root_generate_mask = root_scene_color.z;
    float root_un_generate_mask = root_scene_color.y;

    compare_result[local_id.x][local_id.y] = 0.0;
    share_mesh_height[local_id.x][local_id.y] = 0.0;

    ivec2 mesh_uv = ivec2(group_uv * vec2(mesh_size_xy));
    vec4 mesh_color = texelFetch(t_mesh_depth, mesh_uv, 0);
    share_mesh_height[local_id.x][local_id.y] = mesh_color.x;

    barrier();

    bool in_dirty = pos.x >= dirty_x && pos.y >= dirty_y
                    && pos.x < dirty_x + dirty_w && pos.y < dirty_y + dirty_h;
    bool mask_check = (root_generate_mask == 0.0 || root_un_generate_mask > 0.0);
    bool is_active = !(mask_check && (local_id.x != 0u || local_id.y != 0u)) && in_dirty;

    float un_gen_count = 0.0;
    float gen_count = 0.0;
    float max_index = 16.0;
    float max_count = max_index * max_index;
    float draw_size = size * random_scale;
    float mesh_step = draw_size / max_index;
    int void_count = 0;
    float height_fix = 0.0;
    bool out_of_bounds = false;

    if (is_active) {
        for (float y = 0.0; y < max_index; y += 1.0) {
            for (float x = 0.0; x < max_index; x += 1.0) {
                float read_mesh_h = share_mesh_height[int(x)][int(y)];
                if (read_mesh_h < -10000.0) continue;

                float mesh_h = read_mesh_h + target_h;
                void_count += 1;

                vec2 test_uv = vec2(uv.x + (x - max_index / 2.0) * mesh_step, uv.y + (y - max_index / 2.0) * mesh_step);
                test_uv = rot_uv_center(test_uv, rotate, uv);

                bool oob = any(greaterThan(test_uv, vec2(1.0))) || any(lessThan(test_uv, vec2(0.0)));
                if (oob && any(notEqual(local_id.xy, uvec2(0)))) {
                    out_of_bounds = true;
                    break;
                }

                ivec2 sample_pos = clamp(ivec2(test_uv * max_cell), ivec2(0), ivec2(int(max_cell) - 1));
                vec4 check_color = imageLoad(rw_current_scene_depth_a, sample_pos);
                float current_h = check_color.x;
                float gen_mask = check_color.z;
                float un_gen_mask = check_color.y;

                un_gen_count += float(un_gen_mask > 0.0);
                gen_count += float(gen_mask > 0.0 && un_gen_mask == 0.0 && mesh_h > current_h);
                height_fix = max(height_fix, current_h - mesh_h);
            }
            if (out_of_bounds) break;
        }

        if (!out_of_bounds) {
            height_fix *= 0.5;
            target_h += height_fix + rand_height_off;

            gen_count = (void_count > 0 && gen_count / float(void_count) > generate_threshold) ? gen_count : 0.0;
            gen_count = (void_count > 0 && un_gen_count / float(void_count) < un_generate_threshold) ? gen_count : 0.0;
            gen_count = mask_check ? 0.0 : gen_count;

            float score = gen_count > 0.0 ? gen_count * max_count - un_gen_count : 0.0;
            compare_result[local_id.x][local_id.y] = max(score, 0.0);
            select_data[local_id.x][local_id.y] = vec4(rotate, draw_size, target_h, float(select_index));
        }
    }

    barrier();

    if (group_index != 0u) return;

    vec3 sel = vec3(0.0);
    for (float y = 0.0; y < max_index; y += 1.0) {
        for (float x = 0.0; x < max_index; x += 1.0) {
            float rv = compare_result[int(x)][int(y)];
            sel = rv > sel.x ? vec3(rv, x, y) : sel;
        }
    }

    if (sel.x == 0.0) return;

    int rx = int(sel.y);
    int ry = int(sel.z);
    float result_rotate = select_data[rx][ry].x;
    float result_size = select_data[rx][ry].y;
    float result_height = select_data[rx][ry].z;
    float result_mesh_idx = select_data[rx][ry].w;

    ivec2 sel_idx = ivec2(int(group_id.x) * int(max_index) + rx, int(group_id.y) * int(max_index) + ry);
    vec4 filter_r = vec4(sel.x, 0.0, vec2(sel_idx));
    vec4 save_data = vec4(result_rotate, result_size, result_height, result_mesh_idx);

    imageStore(rw_filter_result, ivec2(group_id.xy), filter_r);
    imageStore(rw_save_rotate_scale, sel_idx, save_data);
}
