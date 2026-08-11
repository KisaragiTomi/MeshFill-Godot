#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// dst = src * k。图里作为"链式 pass"使用：串成长链时每一环的中间量生命周期都只跨一个 pass，
// 是验证瞬态池复用（N 个虚拟中间量塌成 2 块物理内存）的主力。
//
// Binding contract, set 0:
//   0  readonly float src[]  -> RDG.read
//   1  float dst[]           整块覆盖写 -> RDG.write
//
// Push constants (std430, 32B):
//   counts.x = element_count
//   params.x = k

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SrcBuf {
    float data[];
} src;

layout(set = 0, binding = 1, std430) restrict writeonly buffer DstBuf {
    float data[];
} dst;

layout(push_constant, std430) uniform Params {
    uvec4 counts;
    vec4 params;
} pc;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= pc.counts.x) return;
    dst.data[i] = src.data[i] * pc.params.x;
}
