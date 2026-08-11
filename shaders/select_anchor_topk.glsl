#[compute]
#version 450

// Pass B — Per-anchor top-K asset selection.
//
// Workgroup (16, 16, 1) → 256 threads = one per asset slot.
// Dispatch: (anchor_grid_x, anchor_grid_y, 1)
//
// Reads asset_scores from Pass A, picks top TOPK assets per anchor.
// Output: anchor_topk[anchor_id * TOPK + k] = uvec2(asset_id, floatBitsToUint(score))

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ScoresIn {
    float asset_scores[];
};

// Output: packed (asset_id, score_bits)
layout(set = 0, binding = 1, std430) restrict writeonly buffer TopKOut {
    uvec2 anchor_topk[];
};

// GPU-resident anchor count (written by collect_sv_anchors, no CPU readback).
layout(set = 0, binding = 2, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(push_constant, std430) uniform Params {
    uint  asset_stride;
    uint  asset_count;
    uint  anchor_grid_x;
    float min_prefilter_score;
};

// ⚠ 2026-08-10 用户裁决：**粗筛暂时不淘汰任何候选**，top-K 扩到 16。
//
// 背景（实测，见 volume-display-domain-audit 之外的排查记录）：粗筛与细筛判据不同构——
// 粗筛问「外观像不像」（逐样本 fit 的加权平均），细筛问「盖下去残差会不会变小」
// （loss_before − loss_after，再按逐体素严格合取算 match_fraction）。两者之间不存在
// 单调关系，实测出现过粗筛最高分（0.8667）恰是细筛最差（gain −0.7587）的锚点。
// 叠加两条已知缺陷：粗筛不扫 yaw/pivot（细筛扫 12 档），且 coarse 探针的空间跨度
// 比一个体素还小（grass 12 条全落在同一格），粗筛实际没有空间分辨力。
//
// ⇒ 在 coarse score 重做之前，让它只做**排序**不做**淘汰**：全部资产都进候选池，
//    由细筛（有姿态穷举、有物理门、有覆盖率判据）独自决定。coarse score 的重新设计
//    另行安排，不在本次改动内。
//
// 因此：
//   * `min_prefilter_score` 这个 push 字段**当前被忽略**（保留字段是为了不动已冻结的
//     push 布局；host 侧的同名 @export 也随之暂时失效）。
//   * TOPK 4 → 16：资产数只要 ≤ 16 就人人有槽，粗筛的排序不再能挤掉任何人。
//     代价是候选池与 topk 缓冲按 topk 线性放大（anchor_capacity × topk × 64 B），
//     细筛派发的 workgroup 数同样 ×4。恢复淘汰时把 TOPK 调回去即可。
const uint TOPK = 16u;

// 哨兵必须落在**真实分数区间之外**。归一化之后粗筛分是加权平均 fit，取值 ~[-1, 1]，
// 负分是合法值——旧实现用 -1.0 当「缺席」、并以 `best < 0.0` 判空，等于把所有负分
// 候选一并丢掉。取门之后这条会成为新的隐式门，所以一并挪开。
const float SCORE_ABSENT = -1.0e30;  // 该槽不存在（tid 越界 / 锚点越界）
const float SCORE_TAKEN  = -2.0e30;  // 本轮已被取走

shared vec2 shared_scores[256];  // x = score, y = asset_id

void main() {
    uint anchor_id = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x;
    uint tid = gl_LocalInvocationID.y * 16u + gl_LocalInvocationID.x;
    uint safe_asset_stride = clamp(asset_stride, 1u, 256u);
    uint asset_count_clamped = min(asset_count, safe_asset_stride);
    uint anchor_count = anchor_count_dyn[0];

    float score = SCORE_ABSENT;
    if (anchor_id < anchor_count && tid < asset_count_clamped) {
        // 不设门：分数原样带进排序，负分照样是有效候选（见文件头的裁决说明）。
        score = asset_scores[anchor_id * safe_asset_stride + tid];
    }
    shared_scores[tid] = vec2(score, float(tid));
    barrier();

    // Thread 0 performs serial top-K selection
    if (tid == 0u && anchor_id < anchor_count) {
        for (uint k = 0u; k < TOPK; k++) {
            float best = SCORE_ABSENT;
            uint best_id = 0xFFFFFFFFu;

            for (uint j = 0u; j < asset_count_clamped; j++) {
                if (shared_scores[j].x > best) {
                    best = shared_scores[j].x;
                    best_id = uint(shared_scores[j].y);
                }
            }

            // 空槽判据只看 best_id：真实分数（含负分）一律成槽。
            if (best_id == 0xFFFFFFFFu) {
                anchor_topk[anchor_id * TOPK + k] = uvec2(0xFFFFFFFFu, floatBitsToUint(-1.0));
            } else {
                anchor_topk[anchor_id * TOPK + k] = uvec2(best_id, floatBitsToUint(best));
                shared_scores[best_id].x = SCORE_TAKEN;
            }
        }
    }
}
