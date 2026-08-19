#[compute]
#version 450

// 有符号余隙场（signed clearance field）的**画**侧。
//
// 跨批互斥的旧口径是「把已放置物当种子，逐个 anchor 在 XZ 邻域里扫一遍 seed_at_pixel
// 做成对距离测试」。本 pass 把那层关系**预先烘进一张常驻 XZ 场**：每个被接受的放置在
// 自己周围画一个圆锥，后续 anchor 只需在自己那一格 O(1) 读一次即可判互斥
// （查询侧见 shaders/init_anchor_atomic_reduce.glsl 的 clearance 段）。
//
// ── 场的编码 ────────────────────────────────────────────────────────────────
// 每格一个 uint（XZ 平面，grid_x * grid_z 个）：
//   stored == 0        未画过 = 无任何约束（**零填充即合法初值**，所以会话开始时
//                      直接分配一块 storage_buffer_zero 就行，不需要单独的清场 pass）
//   stored >  0        clearance = float(stored) / CLEARANCE_FIXED_SCALE - CLEARANCE_BIAS_VOXELS
//                      clearance = half_radius(已放置物) - dist(格, 已放置物)
// 偏置存在的唯一理由就是让 0 能表示"未画"；GLSL 没有 float 的原子 max，定点 uint +
// atomicMax 才能让"多个已放置物画同一格时取最紧的那个约束"无锁成立。
//
// ── 半径口径（必须与 arbitrate 的 conflicts() 同源）──────────────────────────
// 旧成对判据：dist < max(min_distance_voxels, (r_a + r_b) * asset_spacing_factor)
// 场是单边量，判据必须拆成「画侧半径 + 查侧半径」。拆法：
//   half(x) = max(r_x * asset_spacing_factor, max(min_distance_voxels * 0.5, 0.25))
//   判据    = dist < half(a) + half(b)
// 这个拆法在「两侧都 >= 下界」与「两侧都 < 下界」时**与旧判据逐位等价**，只有一侧跨界
// 时会多挡至多 min_distance_voxels * 0.5 体素（即偏保守，绝不会漏挡）。0.25 那一项对应
// 旧代码里 max(pair_distance * pair_distance, 0.25) 的 0.5 体素地板。
//
// Binding contract, set 0:
//   0  vec4  placement_records[]   记录源。stride 由 push 给：
//                                  stride=4（compact 出的 placement_results，
//                                  [base+0].xyz = voxel 原点、[base+1].y = 资产号）
//                                  stride=1（CPU 种子表，.xyz = 原点、.w = 资产号）
//   1  uint  record_count_dyn[]    GPU 侧记录数（compact 写的 result_count）
//   2  uint  clearance_field[]     ⇢ 常驻余隙场（atomicMax 写）
//   3  float asset_spacing_radius[] 每资产间距半径（体素）

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PlacementRecords {
    vec4 placement_records[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer RecordCountBuf {
    uint record_count_dyn[];
};

layout(set = 0, binding = 2, std430) restrict buffer ClearanceField {
    uint clearance_field[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer AssetSpacing {
    float asset_spacing_radius[];
};

layout(push_constant, std430) uniform Params {
    ivec4 counts; // record_capacity, record_stride(vec4 单位), grid_x, grid_z
    ivec4 modes;  // asset_count, count_source(0=buffer 1=push), push_count, asset_field(0=[base+1].y 1=[base].w)
    vec4 params;  // min_distance_voxels, asset_spacing_factor, max_spacing_radius, unused
};

const uint MAX_ASSETS = 256u;
// ⚠ 这两个常量是**画侧与查侧的共同约定**，改一处就必须同步改
// shaders/init_anchor_atomic_reduce.glsl 里同名的两个常量，否则场会被按错口径解码。
const float CLEARANCE_FIXED_SCALE = 256.0;
const float CLEARANCE_BIAS_VOXELS = 64.0;

float spacing_radius_of(uint asset, uint asset_count) {
    return asset < asset_count ? max(asset_spacing_radius[asset], 0.0) : 0.0;
}

// 见文件头「半径口径」。与 init_anchor_atomic_reduce.glsl 的同名函数逐字相同。
float clearance_half_radius(uint asset, uint asset_count, float min_distance, float factor) {
    float half_floor = max(min_distance * 0.5, 0.25);
    return max(spacing_radius_of(asset, asset_count) * factor, half_floor);
}

void main() {
    // 一个工作组 = 一条记录。组数按 2D 铺开（宿主侧 GROUP_ROW_LENGTH），免得记录数一旦
    // 超过单维组数上限（Vulkan 常见 65535）就整趟 dispatch 被拒——种子表是会跨轮累积的。
    uint record = gl_WorkGroupID.x + gl_WorkGroupID.y * gl_NumWorkGroups.x;
    uint capacity = uint(max(counts.x, 0));
    uint count = modes.y == 1 ? uint(max(modes.z, 0)) : record_count_dyn[0];
    count = min(count, capacity);
    if (record >= count) {
        return;
    }

    uint stride = uint(max(counts.y, 1));
    uint base = record * stride;
    vec3 origin = placement_records[base].xyz;
    uint asset = modes.w == 1
        ? uint(max(int(round(placement_records[base].w)), 0))
        : uint(max(int(round(placement_records[base + 1u].y)), 0));

    uint asset_count = min(uint(max(modes.x, 0)), MAX_ASSETS);
    float min_distance = params.x;
    float factor = params.y;
    float half_self = clearance_half_radius(asset, asset_count, min_distance, factor);
    // 画多远：查询方最大可能的半边半径。画到 half_self + half_max 之外的格，任何查询都
    // 判不出冲突，写进去只是浪费带宽；不画那些格正是「0 = 无约束」的用武之地。
    float half_max = max(max(params.z, 0.0) * factor, max(min_distance * 0.5, 0.25));
    int paint_radius = max(int(ceil(half_self + half_max)), 1);

    int grid_x = max(counts.z, 1);
    int grid_z = max(counts.w, 1);
    // 画侧与查侧都以**取整后的格心**为准（查侧的 pixel 同样是 round(origin.xz)），
    // 场因此是一张纯格点距离场，两侧不会出现半格的口径差。
    ivec2 center = ivec2(round(origin.x), round(origin.z));
    ivec2 begin = max(center - ivec2(paint_radius), ivec2(0));
    ivec2 end = min(center + ivec2(paint_radius), ivec2(grid_x - 1, grid_z - 1));
    ivec2 span = end - begin + ivec2(1);
    if (span.x <= 0 || span.y <= 0) {
        return;
    }

    uint area = uint(span.x) * uint(span.y);
    for (uint i = gl_LocalInvocationID.x; i < area; i += gl_WorkGroupSize.x) {
        int local_x = int(i % uint(span.x));
        int local_z = int(i / uint(span.x));
        ivec2 pixel = begin + ivec2(local_x, local_z);
        float dist = length(vec2(pixel - center));
        int stored = int(round((half_self - dist + CLEARANCE_BIAS_VOXELS) * CLEARANCE_FIXED_SCALE));
        // 落到偏置量程之外 = 比"无约束"还松，写进去反而会把 0 的语义弄脏。
        if (stored < 1) {
            continue;
        }
        atomicMax(clearance_field[uint(pixel.x + grid_x * pixel.y)], uint(stored));
    }
}
