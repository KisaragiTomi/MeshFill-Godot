#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// acc += src * k。读改写，必须声明为 RDG.read_write：
// 用 RDG.write 声明的话，图会认为本 pass 整块覆盖 acc，从而把前一个往 acc 里写东西的 pass
// 判成"输出无人需要"直接剔除 —— 结果是安静地累加到一块没初始化的池内存上。
//
// Binding contract, set 0:
//   0  readonly float src[]  -> RDG.read
//   1  float acc[]           读改写 -> RDG.read_write
//
// Push constants (std430, 32B):
//   counts.x = element_count
//   params.x = k

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SrcBuf {
    float data[];
} src;

layout(set = 0, binding = 1, std430) restrict buffer AccBuf {
    float data[];
} acc;

layout(push_constant, std430) uniform Params {
    uvec4 counts;
    vec4 params;
} pc;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= pc.counts.x) return;
    acc.data[i] += src.data[i] * pc.params.x;
}
