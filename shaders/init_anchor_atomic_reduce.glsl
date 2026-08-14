#[compute]
#version 450

// Select exactly one Fine Score candidate per live Anchor and build the direct
// XZ-pixel lookup map used by the one-pass atomic Reduce's same-batch pairwise
// arbitration.
//
// The anchor collector guarantees at most one Anchor per (x,z) column. Map
// entries store index + 1 so zero-filled buffers are already valid empty maps.
//
// ⚠ 这里曾另建一张 `seed_at_pixel`（已放置物的 XZ 索引），供 invalidate 做跨批间距
// 扫描。跨批互斥已改为常驻的有符号余隙场（shaders/paint_placement_clearance.glsl
// 画、invalidate 查），那张图零读者且每格只装得下一个种子，已整条删除——种子现在
// 只在会话首批经 paint pass 直接烘进场里。

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FineCandidates {
    vec4 fine_candidates[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer AnchorCandidateRef {
    uint anchor_candidate_ref[]; // candidate slot + 1; zero = no valid candidate
};

layout(set = 0, binding = 3, std430) restrict buffer AnchorValid {
    uint anchor_valid[];
};

layout(set = 0, binding = 4, std430) restrict writeonly buffer AnchorAtPixel {
    uint anchor_at_pixel[]; // anchor id + 1; zero = empty
};

layout(push_constant, std430) uniform Params {
    ivec4 counts; // topk, anchor_capacity, unused(retired seed_count), grid_x
    ivec4 grid;   // grid_z, anchor_interval, anchor_phase_x, anchor_phase_z
};

const uint RECORD_STRIDE = 4u;

bool in_pixel_grid(ivec2 p, int grid_x, int grid_z) {
    return p.x >= 0 && p.y >= 0 && p.x < grid_x && p.y < grid_z;
}

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint topk = uint(max(counts.x, 1));
    uint anchor_capacity = uint(max(counts.y, 0));
    uint anchor_count = min(anchor_count_dyn[0], anchor_capacity);
    int grid_x = max(counts.w, 1);
    int grid_z = max(grid.x, 1);

    if (i < anchor_count) {
        uint best_slot = 0xFFFFFFFFu;
        float best_score = -3.402823466e+38;
        for (uint k = 0u; k < topk; k++) {
            uint slot = i * topk + k;
            uint base = slot * RECORD_STRIDE;
            if (fine_candidates[base + 3u].y < 0.5) {
                continue;
            }
            float score = fine_candidates[base + 0u].w;
            if (isnan(score)) {
                continue;
            }
            // Keep the tie-break explicit: within one Anchor, a smaller slot
            // is the smaller k because slots are laid out anchor * topk + k.
            if (best_slot == 0xFFFFFFFFu || score > best_score
                    || (score == best_score && slot < best_slot)) {
                best_slot = slot;
                best_score = score;
            }
        }
        if (best_slot != 0xFFFFFFFFu) {
            anchor_candidate_ref[i] = best_slot + 1u;
            anchor_valid[i] = 1u;
            vec3 origin = fine_candidates[best_slot * RECORD_STRIDE + 0u].xyz;
            ivec2 pixel = ivec2(round(origin.x), round(origin.z));
            // ── 格点门：本轮只让落在 (phase + k*interval) 上的 anchor 参赛 ──────
            // interval 取得足够大（≥ 最大资产足迹 + min_distance）时，同轮候选在几何上
            // 不可能互相冲突，后面那趟保守仲裁因此不会误杀——这正是它存在的目的。
            // 覆盖靠逐批推进相位；已放置物的 collision 盖章负责跨轮互斥。
            // interval <= 0 = 关闭本门，退回原行为。
            // pixel 恒 >= 0（in_pixel_grid 会兜底），所以取模不用处理负数。
            int anchor_interval = grid.y;
            if (anchor_interval > 0
                    && ((pixel.x % anchor_interval) != grid.z
                        || (pixel.y % anchor_interval) != grid.w)) {
                anchor_candidate_ref[i] = 0u;
                anchor_valid[i] = 0u;
            } else if (in_pixel_grid(pixel, grid_x, grid_z)) {
                anchor_at_pixel[pixel.x + grid_x * pixel.y] = i + 1u;
            } else {
                // An out-of-grid candidate cannot participate safely.
                anchor_candidate_ref[i] = 0u;
                anchor_valid[i] = 0u;
            }
        }
    }
}
