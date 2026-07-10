#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TileSummaries {
    uint tile_summaries[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer CompactSummaries {
    uint compact_summary[];
};

layout(set = 0, binding = 2, std430) restrict buffer CompactCounter {
    uint counter[];
};

layout(push_constant, std430) uniform Params {
    ivec4 counts; // tile_count, summary_stride, compact_stride, unused
};

void main() {
    uint tile_index = gl_GlobalInvocationID.x;
    int tile_count = max(counts.x, 0);
    int summary_stride = max(counts.y, 1);
    int compact_stride = max(counts.z, 1);
    if (tile_index >= uint(tile_count) || summary_stride < 6 || compact_stride < 8) {
        return;
    }

    int src_base = int(tile_index) * summary_stride;
    uint scene_count = tile_summaries[src_base + 0];
    uint collision_count = tile_summaries[src_base + 3];
    if (scene_count == 0u && collision_count == 0u) {
        return;
    }

    uint out_index = atomicAdd(counter[0], 1u);
    if (out_index >= uint(tile_count)) {
        return;
    }

    int dst_base = int(out_index) * compact_stride;
    compact_summary[dst_base + 0] = tile_index;
    compact_summary[dst_base + 1] = scene_count;
    compact_summary[dst_base + 2] = tile_summaries[src_base + 1];
    compact_summary[dst_base + 3] = tile_summaries[src_base + 2];
    compact_summary[dst_base + 4] = collision_count;
    compact_summary[dst_base + 5] = tile_summaries[src_base + 4];
    compact_summary[dst_base + 6] = tile_summaries[src_base + 5];
    compact_summary[dst_base + 7] = 0u;
}
