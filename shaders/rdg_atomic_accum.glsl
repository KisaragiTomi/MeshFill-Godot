#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// 原子累加：acc[i] += src[i]（uint）。这是 RDG.read_write 的**正当**用途 ——
// 原子操作天生就是就地读改写，没法拆成「读 A 写 B」的 ping-pong。
//
// 对照 rdg_accum.glsl（非原子的 acc[i] += src[i]*k）：那种写法本工程**不推荐**，
// 它能改写成 ping-pong，而 ping-pong 只用 write 声明、不存在漏声明的风险。
//
// 本 shader 同时是 ComputeKernel.uses_atomics 源码扫描的正样本。
//
// Binding contract, set 0:
//   0  readonly uint src[]   -> RDG.read
//   1  uint acc[]            原子读改写 -> RDG.read_write（声明成 write 会让上游初始化 pass 被剔除）
//
// Push constants (std430, 32B):
//   counts.x = element_count

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SrcBuf {
    uint data[];
} src;

layout(set = 0, binding = 1, std430) restrict buffer AccBuf {
    uint data[];
} acc;

layout(push_constant, std430) uniform Params {
    uvec4 counts;
    vec4 params;
} pc;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= pc.counts.x) return;
    atomicAdd(acc.data[i], src.data[i]);
}
