#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// 往 storage image 里写等差数列。用来验证纹理资源走完整条链路：
// 池化分配 -> UNIFORM_TYPE_IMAGE 绑定 -> 生命周期 -> 跨纹理的 RAW 依赖。
//
// Binding contract, set 0:
//   0  writeonly image2D (r32f)   整块覆盖写 -> RDG.write
//
// Push constants (std430, 32B):
//   counts.x = width
//   counts.y = height
//   params.x = base
//   params.y = stride

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform restrict writeonly image2D out_tex;

layout(push_constant, std430) uniform Params {
    uvec4 counts;
    vec4 params;
} pc;

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= int(pc.counts.x) || p.y >= int(pc.counts.y)) return;
    float idx = float(p.y * int(pc.counts.x) + p.x);
    imageStore(out_tex, p, vec4(pc.params.x + idx * pc.params.y, 0.0, 0.0, 0.0));
}
