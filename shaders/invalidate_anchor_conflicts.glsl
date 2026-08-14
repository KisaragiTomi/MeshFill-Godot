#[compute]
#version 450

// One-pass conflict arbitration, two mechanisms with disjoint jobs:
//
//   1. **跨批互斥 = O(1) 查有符号余隙场**（本文件的 clearance 段）。已放置物在被接受
//      的那一刻就把自己的互斥关系画进常驻 XZ 场（shaders/paint_placement_clearance.glsl），
//      本 pass 只在 anchor 自己那一格读一次即可判定。⚠ 这里曾是「逐 anchor 在保守半径的
//      XZ 邻域里扫 seed_at_pixel + 精确 3D 成对测试」——每个 anchor 都要扫 (2r+1)² 格，
//      而且 seed_at_pixel 每格只装得下一个种子（同列多 Y 的种子会被覆盖丢失）。
//   2. **同轮互斥 = 逐对仲裁**（下面的 anchor_at_pixel 扫描）。同一批里的 anchor 还没被
//      接受，谁也没画进场，只能就地比。按随机优先级原子清掉低优先级的一端。线程即使
//      自身已失效也必须扫完：冲突边要从**不可变的候选集**求解，不能依赖时序中间态。
//      格点门（init 的 anchor_interval）开启时同轮候选几何上不可能冲突，这段是空转；
//      门关闭时它是唯一的同轮保护，因此保留。

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FineCandidates {
    vec4 fine_candidates[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer AnchorCandidateRef {
    uint anchor_candidate_ref[];
};

layout(set = 0, binding = 3, std430) restrict buffer AnchorValid {
    uint anchor_valid[];
};

layout(set = 0, binding = 4, std430) restrict readonly buffer AnchorAtPixel {
    uint anchor_at_pixel[];
};

layout(set = 0, binding = 7, std430) restrict readonly buffer AssetSpacing {
    float asset_spacing_radius[];
};

// 有符号余隙场（查侧只读）。编码与半径口径见 shaders/paint_placement_clearance.glsl 文件头。
layout(set = 0, binding = 8, std430) restrict readonly buffer ClearanceField {
    uint clearance_field[];
};

layout(push_constant, std430) uniform Params {
    ivec4 counts; // anchor_capacity, asset_count, unused, grid_x
    uvec4 grid_seed; // grid_z, random seed, unused x2
    vec4 params; // min distance, spacing factor, max asset radius, unused
};

const uint RECORD_STRIDE = 4u;
const uint MAX_ASSETS = 256u;
// ⚠ 与 shaders/paint_placement_clearance.glsl 的同名常量必须逐位一致。
const float CLEARANCE_FIXED_SCALE = 256.0;
const float CLEARANCE_BIAS_VOXELS = 64.0;

uint hash_u32(uint value) {
    value ^= value >> 16u;
    value *= 0x7FEB352Du;
    value ^= value >> 15u;
    value *= 0x846CA68Bu;
    value ^= value >> 16u;
    return value;
}

uint random_index(uint anchor_id) {
    return hash_u32(anchor_id ^ grid_seed.y);
}

bool priority_precedes(uint a, uint b) {
    uint random_a = random_index(a);
    uint random_b = random_index(b);
    return random_a < random_b || (random_a == random_b && a < b);
}

float spacing_radius_of(uint asset, uint asset_count) {
    return asset < asset_count ? max(asset_spacing_radius[asset], 0.0) : 0.0;
}

// 见 paint_placement_clearance.glsl 文件头「半径口径」。两处必须逐字相同。
float clearance_half_radius(uint asset, uint asset_count, float min_distance, float factor) {
    float half_floor = max(min_distance * 0.5, 0.25);
    return max(spacing_radius_of(asset, asset_count) * factor, half_floor);
}

bool conflicts(vec3 a, uint asset_a, vec3 b, uint asset_b, uint asset_count) {
    float pair_distance = max(params.x,
        (spacing_radius_of(asset_a, asset_count) + spacing_radius_of(asset_b, asset_count)) * params.y);
    vec3 delta = a - b;
    return dot(delta, delta) < max(pair_distance * pair_distance, 0.25);
}

void main() {
    uint anchor = gl_GlobalInvocationID.x;
    uint anchor_count = min(anchor_count_dyn[0], uint(max(counts.x, 0)));
    if (anchor >= anchor_count) {
        return;
    }
    uint self_ref = anchor_candidate_ref[anchor];
    if (self_ref == 0u) {
        return;
    }

    uint asset_count = min(uint(max(counts.y, 0)), MAX_ASSETS);
    int grid_x = max(counts.w, 1);
    int grid_z = max(int(grid_seed.x), 1);
    uint self_slot = self_ref - 1u;
    uint self_base = self_slot * RECORD_STRIDE;
    vec3 self_origin = fine_candidates[self_base + 0u].xyz;
    uint self_asset = uint(max(int(round(fine_candidates[self_base + 1u].y)), 0));
    ivec2 center = ivec2(round(self_origin.x), round(self_origin.z));

    // ── 1. 跨批互斥：O(1) 查余隙场 ─────────────────────────────────────────
    // clearance = half(已放置物) - dist；本 anchor 的半边半径 half(self)。
    // 判据 dist < half(placed) + half(self) 等价于 clearance > -half(self) —— 无近似。
    float half_self = clearance_half_radius(self_asset, asset_count, params.x, params.y);
    if (center.x >= 0 && center.y >= 0 && center.x < grid_x && center.y < grid_z) {
        uint stored = clearance_field[uint(center.x + grid_x * center.y)];
        if (stored != 0u) {
            float clearance = float(stored) / CLEARANCE_FIXED_SCALE - CLEARANCE_BIAS_VOXELS;
            if (clearance > -half_self) {
                atomicAnd(anchor_valid[anchor], 0u);
            }
        }
    }

    // ── 2. 同轮互斥：逐对仲裁（保守半径 XZ 扫描 + 精确 3D 成对测试）───────────
    float scan_distance = max(params.x,
        (spacing_radius_of(self_asset, asset_count) + max(params.z, 0.0)) * params.y);
    int scan_radius = max(int(ceil(scan_distance)), 1);
    ivec2 begin = max(center - ivec2(scan_radius), ivec2(0));
    ivec2 end = min(center + ivec2(scan_radius), ivec2(grid_x - 1, grid_z - 1));

    for (int z = begin.y; z <= end.y; z++) {
        for (int x = begin.x; x <= end.x; x++) {
            uint pixel = uint(x + grid_x * z);

            uint other_ref = anchor_at_pixel[pixel];
            if (other_ref == 0u) {
                continue;
            }
            uint other = other_ref - 1u;
            if (other == anchor || other >= anchor_count) {
                continue;
            }
            uint other_candidate_ref = anchor_candidate_ref[other];
            if (other_candidate_ref == 0u) {
                continue;
            }
            uint other_base = (other_candidate_ref - 1u) * RECORD_STRIDE;
            vec3 other_origin = fine_candidates[other_base + 0u].xyz;
            uint other_asset = uint(max(int(round(fine_candidates[other_base + 1u].y)), 0));
            if (!conflicts(self_origin, self_asset, other_origin, other_asset, asset_count)) {
                continue;
            }
            uint loser = priority_precedes(anchor, other) ? other : anchor;
            atomicAnd(anchor_valid[loser], 0u);
        }
    }
}
