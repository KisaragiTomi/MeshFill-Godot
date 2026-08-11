#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// 用等差数列填满一个 buffer。图里作为"源头 pass"使用。
//
// Binding contract, set 0:
//   0  float out_data[]      整块覆盖写 -> RDG.write
//
// Push constants (std430, 32B):
//   counts.x = element_count
//   params.x = base
//   params.y = stride

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer OutBuf {
    float data[];
} out_buf;

layout(push_constant, std430) uniform Params {
    uvec4 counts;
    vec4 params;
} pc;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= pc.counts.x) return;
    out_buf.data[i] = pc.params.x + float(i) * pc.params.y;
}
