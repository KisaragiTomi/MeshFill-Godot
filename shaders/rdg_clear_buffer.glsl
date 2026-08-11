#[compute]
#version 450

// 内建清零 pass（UE: AddClearUAVPass）。由 RDGBuilder.add_clear_pass 使用，
// 是 RDG 家族唯一的**生产用**内建 shader（其余 rdg_* shader 只服务 scripts/checks 的自检套件）。
//
// 池发回来的物理内存带着上一张图的残留，read_write（累加/原子）语义必须先清一遍，
// 否则累加落在垃圾上 —— GPU 不报错，只出错数。
//
// Binding contract, set 0:
//   0  float out_data[]     整块覆盖写 -> RDG.write
//
// Push constants (std430, 32B):
//   counts.x = element_count   要写的 float 个数（= 逻辑字节数 / 4）
//   params.x = 写入的常量值

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
    out_buf.data[i] = pc.params.x;
}
