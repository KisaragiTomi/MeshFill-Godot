#[compute]
#version 450

// Build the landscape cliff mask from a scalar height image.
// Input: set0/binding0 sampled R32F height texture.
// Output: set1/binding0 R32F mask, value = saturate((slope - start) / range).

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_height;

layout(r32f, set = 1, binding = 0) uniform writeonly image2D rw_mask;

layout(push_constant, std430) uniform Params {
    int out_width;
    int out_height;
    int src_width;
    int src_height;
    float capture_size;
    float slope_start;
    float slope_range;
    float _pad0;
};

float height_at(ivec2 p) {
    ivec2 clamped_p = clamp(p, ivec2(0), ivec2(src_width - 1, src_height - 1));
    return texelFetch(t_height, clamped_p, 0).r;
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= out_width || p.y >= out_height || src_width <= 0 || src_height <= 0) {
        return;
    }

    ivec2 src_p = ivec2(
        clamp(int(floor(float(p.x) / float(out_width) * float(src_width))), 0, src_width - 1),
        clamp(int(floor(float(p.y) / float(out_height) * float(src_height))), 0, src_height - 1)
    );
    int sx0 = max(src_p.x - 1, 0);
    int sx1 = min(src_p.x + 1, src_width - 1);
    int sy0 = max(src_p.y - 1, 0);
    int sy1 = min(src_p.y + 1, src_height - 1);
    float pixel_size = capture_size / max(float(src_width), 1.0);
    float dhdx = (height_at(ivec2(sx1, src_p.y)) - height_at(ivec2(sx0, src_p.y))) / max(float(sx1 - sx0) * pixel_size, 0.0001);
    float dhdz = (height_at(ivec2(src_p.x, sy1)) - height_at(ivec2(src_p.x, sy0))) / max(float(sy1 - sy0) * pixel_size, 0.0001);
    float slope = sqrt(dhdx * dhdx + dhdz * dhdz);
    float value = clamp((slope - slope_start) / max(slope_range, 0.0001), 0.0, 1.0);
    imageStore(rw_mask, p, vec4(value, 0.0, 0.0, 0.0));
}
