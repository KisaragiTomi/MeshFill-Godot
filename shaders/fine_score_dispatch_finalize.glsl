#[compute]
#version 450

// Fine-score indirect dispatch finalize.
//
// Converts the GPU-resident anchor count (written by collect_sv_anchors) into
// Vulkan indirect dispatch args for score_anchor_asset_residual.glsl, so the
// host never reads the count back:
//   origin_count = min(anchor_count[0], anchor_capacity)   (counter can overshoot)
//   groups = (anchor_grid_x, ceil(origin_count / anchor_grid_x), topk)
// One workgroup per (anchor, topk-slot) candidate pair. count == 0 -> gy == 0,
// so empty frames flow through with zero score workgroups and no CPU early-out.

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AnchorCount {
    uint anchor_count[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer FineScoreIndirectArgs {
    uint fine_score_args[]; // [group_count_x, group_count_y, group_count_z]
};

layout(push_constant, std430) uniform Params {
    uint anchor_grid_x;   // fixed dispatch width (matches the scorer's anchor_id decode)
    uint topk;            // per-anchor asset slots (group z axis)
    uint anchor_capacity; // clamp for the overshooting collect counter
    uint reserved0;
};

void main() {
    uint count = min(anchor_count[0], anchor_capacity);
    uint gx = max(anchor_grid_x, 1u);
    uint gy = (count + gx - 1u) / gx;
    fine_score_args[0] = gx;
    fine_score_args[1] = gy;
    fine_score_args[2] = max(topk, 1u);
}
