#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// 在 GPU 上算出下一个 pass 的工作组数，写进 dispatch_indirect 的参数缓冲。
// 用来验证 INDIRECT 访问确实参与了依赖建边：写 args 到读 args 之间必须切段，
// 这条依赖手接 dispatch 链时最容易漏 —— 漏了的话 GPU 读到的是上一帧的组数。
//
// Binding contract, set 0:
//   0  uint args[3]         整块覆盖写 -> RDG.write；资源须由 create_indirect_args_buffer 创建
//
// Push constants (std430, 32B):
//   counts.x = element_count
//   counts.y = 下游 pass 的 local_size_x

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer ArgsBuf {
    uint data[];
} args;

layout(push_constant, std430) uniform Params {
    uvec4 counts;
    vec4 params;
} pc;

void main() {
    if (gl_GlobalInvocationID.x > 0u) return;
    uint local = max(pc.counts.y, 1u);
    args.data[0] = (pc.counts.x + local - 1u) / local;
    args.data[1] = 1u;
    args.data[2] = 1u;
}
