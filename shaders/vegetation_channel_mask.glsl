#[compute]
#version 450

// Extract one vegetation occupancy channel into an RF debug/placement mask.
// Input:
//   set0/binding0: RGBA16F occupancy texture.
// Output:
//   set1/binding0: R32F channel mask, zeroed below threshold and outside source bounds.

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_occupancy;

layout(r32f, set = 1, binding = 0) uniform writeonly image2D rw_channel_mask;

layout(push_constant, std430) uniform Params {
    int out_width;
    int out_height;
    int src_width;
    int src_height;
    int channel;
    float active_threshold;
    float _pad0;
    float _pad1;
};

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= out_width || p.y >= out_height) {
        return;
    }

    float value = 0.0;
    if (p.x < src_width && p.y < src_height && channel >= 0 && channel < 4) {
        vec4 occupancy = texelFetch(t_occupancy, p, 0);
        if (channel == 0) {
            value = occupancy.r;
        } else if (channel == 1) {
            value = occupancy.g;
        } else if (channel == 2) {
            value = occupancy.b;
        } else {
            value = occupancy.a;
        }
        if (value <= active_threshold) {
            value = 0.0;
        }
    }

    imageStore(rw_channel_mask, p, vec4(value, 0.0, 0.0, 0.0));
}
