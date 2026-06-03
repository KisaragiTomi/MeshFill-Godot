#[compute]
#version 450

// Resample an RF collision field to a square volume XZ resolution.
// Input:
//   set0/binding0: R32F source collision texture, usually base resolution.
// Output:
//   set1/binding0: R32F resampled collision texture.

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_collision_src;

layout(r32f, set = 1, binding = 0) uniform writeonly image2D rw_collision_out;

layout(push_constant, std430) uniform Params {
    int out_width;
    int out_height;
    int src_width;
    int src_height;
    int base_res;
    int _pad0;
    int _pad1;
    int _pad2;
};

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= out_width || p.y >= out_height) {
        return;
    }

    float value = 0.0;
    if (src_width > 0 && src_height > 0 && base_res > 0) {
        int bx = clamp(int(float(p.x) / float(out_width) * float(base_res)), 0, base_res - 1);
        int bz = clamp(int(float(p.y) / float(out_height) * float(base_res)), 0, base_res - 1);
        if (bx < src_width && bz < src_height) {
            value = clamp(texelFetch(t_collision_src, ivec2(bx, bz), 0).r, 0.0, 1.0);
        }
    }

    imageStore(rw_collision_out, p, vec4(value, 0.0, 0.0, 0.0));
}
