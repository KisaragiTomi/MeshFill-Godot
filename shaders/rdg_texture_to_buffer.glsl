#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// 读 storage image、乘个系数、写进 buffer。存在的意义是让纹理的内容能被回读验证，
// 同时构造一条"纹理写 -> 纹理读"的 RAW 依赖。
//
// Binding contract, set 0:
//   0  readonly image2D (r32f)    -> RDG.read
//   1  float out_data[]           整块覆盖写 -> RDG.write
//
// Push constants (std430, 32B):
//   counts.x = width
//   counts.y = height
//   params.x = k

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform restrict readonly image2D src_tex;

layout(set = 0, binding = 1, std430) restrict writeonly buffer OutBuf {
    float data[];
} out_buf;

layout(push_constant, std430) uniform Params {
    uvec4 counts;
    vec4 params;
} pc;

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= int(pc.counts.x) || p.y >= int(pc.counts.y)) return;
    out_buf.data[p.y * int(pc.counts.x) + p.x] = imageLoad(src_tex, p).r * pc.params.x;
}
