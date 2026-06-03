#[compute]
#version 450

// Build a tree placement mask around cliff or rock pixels.
// Inputs:
//   set0/binding0: R32F cliff mask
//   set0/binding1: R32F rock mask
// Output:
//   set1/binding0: R32F tree mask, dilated as an annulus around active source pixels.

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_cliff_mask;
layout(set = 0, binding = 1) uniform sampler2D t_rock_mask;

layout(r32f, set = 1, binding = 0) uniform writeonly image2D rw_tree_mask;

layout(push_constant, std430) uniform Params {
    int width;
    int height;
    int rock_width;
    int rock_height;
    int outer_radius_px;
    int inner_radius_px;
    float active_threshold;
    float _pad0;
};

float source_value(ivec2 p) {
    if (p.x < 0 || p.y < 0 || p.x >= width || p.y >= height) {
        return 0.0;
    }
    float cliff_value = texelFetch(t_cliff_mask, p, 0).r;
    float rock_value = 0.0;
    if (p.x < rock_width && p.y < rock_height) {
        rock_value = texelFetch(t_rock_mask, p, 0).r;
    }
    return max(cliff_value, rock_value);
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= width || p.y >= height) {
        return;
    }

    if (source_value(p) > active_threshold) {
        imageStore(rw_tree_mask, p, vec4(0.0));
        return;
    }

    int outer_sq = outer_radius_px * outer_radius_px;
    int inner_sq = inner_radius_px * inner_radius_px;
    float best = 0.0;
    for (int dy = -outer_radius_px; dy <= outer_radius_px; dy++) {
        for (int dx = -outer_radius_px; dx <= outer_radius_px; dx++) {
            int dist_sq = dx * dx + dy * dy;
            if (dist_sq > outer_sq || (inner_radius_px > 0 && dist_sq <= inner_sq)) {
                continue;
            }
            best = max(best, source_value(p + ivec2(dx, dy)));
        }
    }

    float value = best > active_threshold ? best : 0.0;
    imageStore(rw_tree_mask, p, vec4(value, 0.0, 0.0, 0.0));
}
