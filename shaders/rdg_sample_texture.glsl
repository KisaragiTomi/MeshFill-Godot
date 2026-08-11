#[compute]
#version 450

// RDG 自检套件（scripts/checks/rdg_selftest.gd）专用，非生产 shader。
// 通过 sampler2D 采样一张纹理，乘个系数写进 buffer（供回读验证）。
//
// 与 rdg_texture_to_buffer.glsl 的区别正是本 shader 存在的理由：那条走
// imageLoad(image2D, ivec2)（整数坐标直取，UNIFORM_TYPE_IMAGE），这条走
// texture(sampler2D, vec2)（带过滤/寻址，UNIFORM_TYPE_SAMPLER_WITH_TEXTURE）。
// 后者是两个 RID 一起绑（先 sampler 后 texture），且纹理必须带 TEXTURE_USAGE_SAMPLING_BIT。
//
// Binding contract, set 0:
//   0  sampler2D src_tex    -> RDG.sample(res, sampler)
//   1  float out_data[]     整块覆盖写 -> RDG.write
//
// Push constants (std430, 32B):
//   counts.x = width
//   counts.y = height
//   params.x = k        输出的乘数
//   params.y = u_shift  采样点在 U 方向上偏移几个纹素（用来验寻址模式确实生效）
//
// 采样点刻意对准像素中心 (p + 0.5) / size：配合 NEAREST 过滤，采到的就是 texel p 本身，
// 期望值可以逐元素精确写出来。落在纹素边界上的话，取到哪一格由舍入决定，测试会变成薛定谔的。

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src_tex;

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
    vec2 size = vec2(float(pc.counts.x), float(pc.counts.y));
    vec2 uv = (vec2(p) + vec2(0.5 + pc.params.y, 0.5)) / size;
    out_buf.data[p.y * int(pc.counts.x) + p.x] = texture(src_tex, uv).r * pc.params.x;
}
