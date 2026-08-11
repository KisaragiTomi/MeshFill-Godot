#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// c = a + b。图里作为"汇聚 pass"使用：它同时依赖两个上游，正好用来验证切段只发生在
// 真实汇聚点上，而两个上游填充 pass 之间一次都不切。
//
// Binding contract, set 0:
//   0  readonly float a[]    -> RDG.read
//   1  readonly float b[]    -> RDG.read
//   2  float c[]             整块覆盖写 -> RDG.write
//
// Push constants (std430, 32B):
//   counts.x = element_count

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// a / b 刻意**不加** restrict：双重归还回归用例会把同一个 buffer 同时绑到这两个 binding 上
// （合法且常见），而 restrict 正是在向编译器断言"这两个绑定不会别名"。两者都是 readonly，
// 实践上无害，但让回归测试建立在一个违反限定符契约的写法上不合适。c 是唯一的写入方，保留 restrict。
layout(set = 0, binding = 0, std430) readonly buffer BufA {
    float data[];
} a;

layout(set = 0, binding = 1, std430) readonly buffer BufB {
    float data[];
} b;

layout(set = 0, binding = 2, std430) restrict writeonly buffer BufC {
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
