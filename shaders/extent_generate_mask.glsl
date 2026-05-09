#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_current_scene_depth;
layout(set = 0, binding = 1) uniform sampler2D t_height_normal;

layout(rgba16f, set = 1, binding = 0) uniform image2D rw_current_scene_depth;

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

void main() {
    ivec2 local_id = ivec2(gl_GlobalInvocationID.xy);
    if (local_id.x >= dirty_w || local_id.y >= dirty_h) return;
    ivec2 pos = ivec2(dirty_x + local_id.x, dirty_y + local_id.y);
    ivec2 tex_size = textureSize(t_current_scene_depth, 0);
    if (pos.x >= tex_size.x || pos.y >= tex_size.y) return;

    vec4 center = texelFetch(t_current_scene_depth, pos, 0);

    if (center.z > 0.0) {
        imageStore(rw_current_scene_depth, pos, center);
        return;
    }

    float mask_val = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            ivec2 np = clamp(pos + ivec2(dx, dy), ivec2(0), tex_size - 1);
            float nb_mask = texelFetch(t_current_scene_depth, np, 0).z;
            mask_val = max(mask_val, nb_mask);
        }
    }

    vec4 result = center;
    result.z = mask_val;
    imageStore(rw_current_scene_depth, pos, result);
}
