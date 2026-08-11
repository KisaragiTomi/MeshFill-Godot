#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// c = a + b，但输入在 set 0、输出在 set 1。用来验证多 uniform set 的绑定：
// param_sets[s][i] 必须落到 set s 的 binding i，错位一个 set 的话 uniform_set_create 未必失败，
// shader 读到的却全是别的资源。
//
// Binding contract:
//   set 0, binding 0  readonly float a[]   -> RDG.read
//   set 0, binding 1  readonly float b[]   -> RDG.read
//   set 1, binding 0  float c[]            整块覆盖写 -> RDG.write
//
// Push constants (std430, 32B):
//   counts.x = element_count

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer BufA {
    float data[];
} a;

layout(set = 0, binding = 1, std430) restrict readonly buffer BufB {
    float data[];
} b;

layout(set = 1, binding = 0, std430) restrict writeonly buffer BufC {
    float data[];
} c;

layout(push_constant, std430) uniform Params {
    uvec4 counts;
    vec4 params;
} pc;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= pc.counts.x) return;
    c.data[i] = a.data[i] + b.data[i];
}
