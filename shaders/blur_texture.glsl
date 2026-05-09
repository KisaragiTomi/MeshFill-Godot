#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_input;

layout(rgba16f, set = 1, binding = 0) uniform image2D rw_output;

layout(push_constant, std430) uniform Params {
    float blur_scale;
    int dirty_x;
    int dirty_y;
    int dirty_w;
    int dirty_h;
    int _pad0;
    int _pad1;
    int _pad2;
};

void main() {
    ivec2 local_id = ivec2(gl_GlobalInvocationID.xy);
    if (local_id.x >= dirty_w || local_id.y >= dirty_h) return;
    ivec2 pos = ivec2(dirty_x + local_id.x, dirty_y + local_id.y);
    ivec2 tex_size = textureSize(t_input, 0);
    if (pos.x >= tex_size.x || pos.y >= tex_size.y) return;

    int max_cell = tex_size.x - 1;
    int radius = 7;

    vec4 center_pixel = texelFetch(t_input, pos, 0);

    float total_height = 0.0;
    float weight_sum = 0.0;

    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            ivec2 sp = clamp(pos + ivec2(dx, dy), ivec2(0), ivec2(max_cell));
            float w = exp(-float(dx * dx + dy * dy) / (2.0 * blur_scale * blur_scale));
            total_height += texelFetch(t_input, sp, 0).x * w;
            weight_sum += w;
        }
    }

    imageStore(rw_output, pos, vec4(total_height / weight_sum, center_pixel.yzw));
}
