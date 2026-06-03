#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer TileSummaries {
    uint summary[];
};

layout(push_constant, std430) uniform Params {
    ivec4 counts; // tile_count, summary_stride, min_sentinel, unused
};

void main() {
    uint tile_index = gl_GlobalInvocationID.x;
    int tile_count = max(counts.x, 0);
    int stride = max(counts.y, 1);
    if (tile_index >= uint(tile_count) || stride < 6) {
        return;
    }

    int base = int(tile_index) * stride;
    uint sentinel = uint(max(counts.z, 0));
    summary[base + 0] = 0u;
    summary[base + 1] = sentinel;
    summary[base + 2] = 0u;
    summary[base + 3] = 0u;
    summary[base + 4] = sentinel;
    summary[base + 5] = 0u;
}
