#[compute]
#version 450

// Extract one occupancy channel into an RF voxel-volume slice image.
// Input:
//   set0/binding0: RGBA16F occupancy texture at base resolution.
// Output:
//   set1/binding0: R32F slice image at requested XZ resolution.

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_occupancy;

layout(r32f, set = 1, binding = 0) uniform writeonly image2D rw_slice;

layout(push_constant, std430) uniform Params {
    int out_width;
    int out_height;
    int src_width;
    int src_height;
    int base_res;
    int channel;
    float occupied_epsilon;
    float _pad0;
};

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= out_width || p.y >= out_height) {
        return;
    }

    float value = 0.0;
    if (src_width > 0 && src_height > 0 && base_res > 0 && channel >= 0 && channel < 4) {
        int sx = clamp(int(float(p.x) / float(out_width) * float(base_res)), 0, base_res - 1);
        int sz = clamp(int(float(p.y) / float(out_height) * float(base_res)), 0, base_res - 1);
        if (sx < src_width && sz < src_height) {
            vec4 occupancy = texelFetch(t_occupancy, ivec2(sx, sz), 0);
            if (channel == 0) {
                value = occupancy.r;
            } else if (channel == 1) {
                value = occupancy.g;
            } else if (channel == 2) {
                value = occupancy.b;
            } else {
                value = occupancy.a;
            }
            if (value <= occupied_epsilon) {
                value = 0.0;
            }
        }
    }

    imageStore(rw_slice, p, vec4(value, 0.0, 0.0, 0.0));
}
