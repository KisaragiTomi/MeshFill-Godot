#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D rw_filter_result;
layout(rgba16f, set = 0, binding = 1) uniform image2D rw_save_rotate_scale;
layout(rgba16f, set = 0, binding = 2) uniform image2D rw_current_scene_depth_a;
layout(rgba16f, set = 0, binding = 3) uniform image2D rw_result_a;
layout(rgba16f, set = 0, binding = 4) uniform image2D rw_result_b;
layout(rgba16f, set = 0, binding = 5) uniform image2D rw_debug_view;

layout(set = 1, binding = 0) uniform sampler2D t_scene_normal;

layout(push_constant, std430) uniform Params {
    int select_index;   // offset 0
    float _pad0;        // offset 4
    float _pad1;        // offset 8
    float _pad2;        // offset 12
};

shared vec4 shared_max_rw[16][16];
shared float shared_dedup[16][16];
shared uint counter;

void main() {
    uvec3 local_id = gl_LocalInvocationID;
    uint group_index = gl_LocalInvocationIndex;

    if (group_index == 0u) counter = 0u;

    float heightmap_max_cell = float(imageSize(rw_current_scene_depth_a).x);
    float max_cell = float(imageSize(rw_filter_result).x);

    vec4 filter_color = imageLoad(rw_filter_result, ivec2(local_id.xy));
    float compare_val = filter_color.x;

    shared_max_rw[local_id.x][local_id.y] = filter_color;
    shared_max_rw[local_id.x][local_id.y].y = compare_val > 0.0 ? float(group_index) : -1.0;
    shared_dedup[local_id.x][local_id.y] = -1.0;

    barrier();

    bool is_active = compare_val > 0.0;

    // Deduplication: remove overlapping placements
    if (is_active) {
        vec4 share_a = shared_max_rw[local_id.x][local_id.y];
        ivec2 save_idx_a = ivec2(share_a.zw);
        vec4 save_a = imageLoad(rw_save_rotate_scale, save_idx_a);
        float cmp_a = share_a.x;
        float size_a = save_a.y;

        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) {
                ivec2 offset = ivec2(local_id.xy) + ivec2(x, y);
                if (offset.x < 0 || offset.x >= 16 || offset.y < 0 || offset.y >= 16) continue;

                vec4 share_b = shared_max_rw[offset.x][offset.y];
                ivec2 save_idx_b = ivec2(share_b.zw);
                vec4 save_b = imageLoad(rw_save_rotate_scale, save_idx_b);
                float cmp_b = share_b.x;
                float size_b = save_b.y;

                float dist_ab = distance(vec2(save_idx_a) / heightmap_max_cell, vec2(save_idx_b) / heightmap_max_cell);

                if (dist_ab < (size_a + size_b) / 2.0 && cmp_b >= 0.0) {
                    bool is_change =
                        (cmp_a < cmp_b) ||
                        (cmp_a == cmp_b && (save_idx_a.x + int(float(save_idx_a.y) * max_cell) < save_idx_b.x + int(float(save_idx_b.y) * max_cell)));
                    is_change = (x == 0 && y == 0) ? false : is_change;
                    is_change = (cmp_b <= 0.0) ? false : is_change;

                    if (is_change) {
                        shared_max_rw[local_id.x][local_id.y] = vec4(-1.0);
                        is_active = false;
                    }
                }
            }
        }
    }

    barrier();

    // Deduplication pass 2: mark valid slots
    if (is_active) {
        vec4 share_data = shared_max_rw[local_id.x][local_id.y];
        int save_gid = int(share_data.y);
        if (save_gid >= 0) {
            shared_dedup[save_gid % 16][save_gid / 16] = 1.0;
        }
    }

    barrier();

    bool valid = shared_dedup[local_id.x][local_id.y] == 1.0;

    if (valid) {
        uint pre_val = atomicAdd(counter, 1u);

        ivec2 max_result_v = imageSize(rw_result_a);
        vec4 result_idx_color = imageLoad(rw_result_a, ivec2(max_result_v.x - 1, max_result_v.y - 1));
        uint result_idx_v = uint(result_idx_color.x);
        uint current_loc = result_idx_v + pre_val;

        if (current_loc < 1023u) {
            vec4 share_data = shared_max_rw[local_id.x][local_id.y];
            ivec2 save_idx = ivec2(share_data.zw);
            vec2 norm_uv = vec2(save_idx) / (heightmap_max_cell - 1.0);
            vec4 save_color = imageLoad(rw_save_rotate_scale, save_idx);

            imageStore(rw_result_b, ivec2(int(current_loc), 0), vec4(norm_uv.x, norm_uv.y, save_color.z, 0.0));
            imageStore(rw_result_b, ivec2(int(current_loc), 1), vec4(save_color.x, save_color.y, float(select_index), 0.0));
        }
    }

    barrier();

    if (group_index == 0u) {
        ivec2 max_result_f = imageSize(rw_result_a);
        vec4 result_idx_color_f = imageLoad(rw_result_a, ivec2(max_result_f.x - 1, max_result_f.y - 1));
        uint result_idx_f = uint(result_idx_color_f.x);
        imageStore(rw_result_b, ivec2(max_result_f.x - 1, max_result_f.y - 1), vec4(float(result_idx_f + counter), 0.0, float(counter), 0.0));
    }
}
