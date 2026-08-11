#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// 往 3D storage image 里写等差数列。MeshFill 的体素场用的正是 3D 纹理，所以这条路径必须验，
// 不能只验 2D 就假定 depth>1 也能跑。
//
// Binding contract, set 0:
//   0  writeonly image3D (r32f)   整块覆盖写 -> RDG.write
//
// Push constants (std430, 32B):
//   counts.xyz = width / height / depth
//   params.x   = base
//   params.y   = stride

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, r32f) uniform restrict writeonly image3D out_tex;

layout(push_constant, std430) uniform Params {
    uvec4 counts;
    vec4 params;
} pc;

void main() {
    ivec3 p = ivec3(gl_GlobalInvocationID.xyz);
    if (p.x >= int(pc.counts.x) || p.y >= int(pc.counts.y) || p.z >= int(pc.counts.z)) return;
    float idx = float((p.z * int(pc.counts.y) + p.y) * int(pc.counts.x) + p.x);
    imageStore(out_tex, p, vec4(pc.params.x + idx * pc.params.y, 0.0, 0.0, 0.0));
}
