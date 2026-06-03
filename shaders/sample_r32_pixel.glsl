#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D SourceField;

layout(set = 0, binding = 1, std430) restrict buffer OutputValue {
    float value;
};

layout(push_constant, std430) uniform Params {
    ivec4 dims_pixel; // width, height, pixel_x, pixel_z
};

void main() {
    int x = clamp(dims_pixel.z, 0, max(dims_pixel.x - 1, 0));
    int z = clamp(dims_pixel.w, 0, max(dims_pixel.y - 1, 0));
    value = texelFetch(SourceField, ivec2(x, z), 0).r;
}
