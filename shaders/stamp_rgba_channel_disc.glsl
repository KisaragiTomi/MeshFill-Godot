#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_tex;

layout(rgba16f, set = 1, binding = 0) uniform writeonly image2D out_image;

layout(push_constant, std430) uniform Params {
    ivec4 dims_center;    // width, height, center_x, center_y
    ivec4 radius_channel; // radius, channel, unused, unused
    vec4 values;          // value, unused, unused, unused
};

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= dims_center.x || p.y >= dims_center.y) {
        return;
    }

    vec4 out_value = texelFetch(source_tex, p, 0);
    ivec2 d = p - dims_center.zw;
    int radius = max(radius_channel.x, 0);
    int channel = clamp(radius_channel.y, 0, 3);
    if (d.x * d.x + d.y * d.y <= radius * radius) {
        out_value[channel] = max(out_value[channel], clamp(values.x, 0.0, 1.0));
    }

    imageStore(out_image, p, out_value);
}
