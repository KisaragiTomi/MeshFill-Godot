#[compute]
#version 450

// Turns the GPU anchor_count (written by collect_sv_anchors) into Vulkan indirect
// dispatch args for the score + top-K passes, so the host never reads the count
// back. anchor_grid_x is FIXED and matches the score/top-K anchor_id decode
// (anchor_id = WorkGroupID.y * anchor_grid_x + WorkGroupID.x); only the y group
// count scales with the anchor count. count == 0 -> gy == 0 -> zero groups
// dispatched, so an empty frame flows through the pipeline without a CPU early-out.
//
// Indirect args layout is 3 uints: group_count_x, group_count_y, group_count_z.
//   score: z = asset_blocks (CPU-known, passed in push)
//   top-K: z = 1

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AnchorCount {
    uint anchor_count[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer ScoreIndirectArgs {
    uint score_indirect_args[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer TopkIndirectArgs {
    uint topk_indirect_args[];
};

layout(push_constant, std430) uniform Params {
    uint anchor_grid_x;
    uint asset_blocks;
    uint anchor_capacity;
    uint reserved0;
};

void main() {
    uint count = min(anchor_count[0], anchor_capacity);
    uint gx = max(anchor_grid_x, 1u);
    uint gy = (count + gx - 1u) / gx;  // 0 when count == 0

    score_indirect_args[0] = gx;
    score_indirect_args[1] = gy;
    score_indirect_args[2] = asset_blocks;

    topk_indirect_args[0] = gx;
    topk_indirect_args[1] = gy;
    topk_indirect_args[2] = 1u;
}
