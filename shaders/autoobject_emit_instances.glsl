#[compute]
#version 450

// AutoObject 实例 emit：把常驻对象池编译成「绘制载荷 + 点选 OBB」两块紧凑表。
// 契约见《AutoObject实例GPU直提与点选交接计划.md》§4；字节布局的唯一真值源是
// AutoObjectInstanceRenderer.GLSL_CONSTANTS，下面的 @@GEN 区块由它发射。
//
// 为什么从**常驻对象 buffer** 产出而不是从 VPG 的 winner result_buffer：常驻 buffer 是 stamp
// 与 tile store 消费的同一份 SSOT，且它在 despawn 与编辑之后依然存活；winner buffer 只活一轮。
//
// 四趟（同一条 compute list，段间由 ComputePassChain 自动插屏障）：
//   pass 0 count    每 (工作组, 批) 的存活数 → wg_counts，并按 (工作组, 批) atomicAdd 进批总数；
//                   顺带把 instance_render / instance_pick 整块清零
//                   （清零必须在 scatter 之前、且不能与 scatter 同趟，否则清掉刚写的行）
//   pass 1 prefix   单线程独占扫描 → instance_start；游标归零；写 instance_dispatch
//   pass 3 wg_scan  单工作组分块扫描 wg_counts → wg_offsets
//   pass 2 scatter  slot = instance_start[b] + wg_offsets[wg][b] + 组内名次，同一 slot 写两块
//
// ⚠ **槽位即身份。** 槽位下标就是拾取 ID（`pick_id.gdshader` 的
// `pick_id = pick_id_base + INSTANCE_ID`，区间由 `PickIdPass.prepare()` 按
// `mm.instance_count` 分配）。所以 slot 必须是 (alive 集合, asset_index, object_id) 的
// **纯函数**：剔除只能改「这个槽画不画」，绝不能改「谁在哪个槽」。
// 原来的 `slot = instance_start[b] + atomicAdd(cursor[b], 1)` 破了这条 —— Vulkan 对
// atomicAdd 的返回顺序不作任何保证，实测 20 万对象同输入连跑两轮，187 462 / 187 500 个
// 槽位换主（99.98%）。后果是「ID 图渲染」与「resolve 读 instance_pick」之间夹进一次 emit
// 就解出另一个合法 object_id —— 点 A 选中 B，且 resolve_pick 的批号自检抓不到。
// 相机移动（`sync()` 的 camera_moved 门）即可触发。
// 保序流压缩后同一测量为 0。验证台：GPUDirectEmitLab 的 EmitLab.verify_slot_stability()。
// ⚠ 小规模验不出来：144 个对象只有 3 个工作组，几乎没有争用，两次运行给出过 135 与 0
// 两个相反结果。要量这类无序性至少得上到几千个工作组。
//
// batch_header 与 instance_dispatch 由宿主在 begin_compute_list() 之前 buffer_zero；
// 它们不能在 pass 0 里清（与同趟的 atomicAdd 竞争）。
//
// 绑定契约 set 0（GPUAutoObjectRuntime 常驻状态，借用只读）：
//   0  readonly int   alive[]
//   1  readonly int   profile[]
//   2  readonly int   object_flags[]
//   3  readonly int   object_asset_index[]
//   4  readonly ivec4 bounds_min[]
//   5  readonly mat4  transforms[]
//
// 绑定契约 set 1（renderer 自有输出 + 借用输入）：
//   0  float instances[]        20 float / 实例（TRANSFORM_3D + colors + custom data）
//   1  uint  pick_words[]       32 word / 实例（128 B）
//   2  uint  batch_words[]      16 word / 批（64 B）
//   3  uint  dispatch_words[4]  [groups_x(64), 1, 1, live_count]
//   4  readonly vec4 mesh_desc[]      8 vec4 / 资产（128 B，ScenePlacementRuntime 拥有）
//   5  readonly float terrain_height[]  地形高度场（renderer 自有常驻；未注入时为 1 元占位）
//   6  uint  wg_counts[]           每 (工作组, 批) 的存活数，下标 wg * batch_count + b
//   7  uint  wg_offsets[]          上者的逐批独占前缀，同一下标

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Alive { int alive[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Profile { int profile[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer ObjectFlags { int object_flags[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer AssetIndexBuffer { int object_asset_index[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer BoundsMin { ivec4 bounds_min[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer TransformBuffer { mat4 transforms[]; };

layout(set = 1, binding = 0, std430) restrict buffer InstanceRender { float instances[]; };
layout(set = 1, binding = 1, std430) restrict buffer InstancePick { uint pick_words[]; };
layout(set = 1, binding = 2, std430) restrict buffer BatchHeader { uint batch_words[]; };
layout(set = 1, binding = 3, std430) restrict buffer InstanceDispatch { uint dispatch_words[]; };
layout(set = 1, binding = 4, std430) restrict readonly buffer MeshDescription { vec4 mesh_desc[]; };
layout(set = 1, binding = 5, std430) restrict readonly buffer TerrainHeight { float terrain_height[]; };
layout(set = 1, binding = 6, std430) restrict buffer WorkgroupCounts { uint wg_counts[]; };
layout(set = 1, binding = 7, std430) restrict buffer WorkgroupOffsets { uint wg_offsets[]; };

layout(push_constant, std430) uniform Params {
    ivec4 counts;   // x=object_capacity y=batch_count z=instance_capacity w=pass_index
    ivec4 options;  // x=option_bits y=terrain_res z=object_revision w=pad
    vec4 camera;      // xyz=camera_pos w=cull_distance（<=0 关闭剔除）
    vec4 grid_origin; // xyz=grid_origin w=pad
    vec4 voxel_size;  // xyz=voxel_size w=pad
    vec4 default_color;
};

// @@GEN autoobject_instance_layout — generated from scripts/auto_object_instance_renderer.gd, do not edit
// 实例表字节布局 SSOT：AutoObjectInstanceRenderer.GLSL_CONSTANTS
// CPU 用这些下标解码、GLSL 用它们写入；任一侧单边改动的症状是"某字段读出隔壁字段的值"，
// 不崩、只静默错。scripts/checks/glsl_gen_block_checks.gd 守卫两侧不漂移。

// instance_render[]：MultiMesh 形状，20 float / 实例
const int AOI_RENDER_FLOATS = 20;
const int AOI_R_ROW0 = 0;
const int AOI_R_ROW1 = 4;
const int AOI_R_ROW2 = 8;
const int AOI_R_COLOR = 12;
const int AOI_R_CUSTOM = 16;

// instance_pick[]：128 B / 实例 = 32 word
const int AOI_PICK_WORDS = 32;
const int AOI_P_ROW0 = 0;
const int AOI_P_ROW1 = 4;
const int AOI_P_ROW2 = 8;
const int AOI_P_COLOR = 12;
const int AOI_P_OBB_CENTER = 16;
const int AOI_P_OBB_YAW = 19;
const int AOI_P_OBB_HALF = 20;
const int AOI_P_OBB_RADIUS = 23;
const int AOI_P_OBJECT_ID = 24;
const int AOI_P_PROFILE_ID = 25;
const int AOI_P_BATCH_INDEX = 26;
const int AOI_P_FLAGS = 27;
const int AOI_P_VOXEL_MIN_X = 28;
const int AOI_P_VOXEL_MIN_Y = 29;
const int AOI_P_VOXEL_MIN_Z = 30;
const int AOI_P_ASSET_INDEX = 31;

// instance_pick flags（AOI_P_FLAGS 的位）
const uint AOI_FLAG_ALIVE = 1u;
const uint AOI_FLAG_SELECTED = 2u;
const uint AOI_FLAG_CULLED = 4u;
const uint AOI_FLAG_TERRAIN_REBASED = 8u;

// batch_header[]：64 B / 批 = 16 word
const int AOI_BATCH_WORDS = 16;
const int AOI_B_INSTANCE_START = 0;
const int AOI_B_INSTANCE_COUNT = 1;
const int AOI_B_PROFILE_ID = 2;
const int AOI_B_ASSET_INDEX = 3;
const int AOI_B_CAPACITY = 4;
const int AOI_B_REVISION = 5;
const int AOI_B_CURSOR = 6;
const int AOI_B_FLAGS = 7;

// instance_dispatch[4]：间接派发参数 + 存活计数
const int AOI_D_GROUPS_X = 0;
const int AOI_D_GROUPS_Y = 1;
const int AOI_D_GROUPS_Z = 2;
const int AOI_D_LIVE_COUNT = 3;
const int AOI_DISPATCH_LOCAL_SIZE_X = 64;

// mesh_description（ScenePlacementRuntime 拥有，stride 128 B = 8 vec4）
const int AOI_MESH_DESC_VEC4 = 8;
const int AOI_MESH_AABB_POSITION_VEC4 = 2;
const int AOI_MESH_AABB_SIZE_VEC4 = 3;

// pass 下标
const int AOI_PASS_COUNT = 0;
const int AOI_PASS_PREFIX = 1;
const int AOI_PASS_SCATTER = 2;
const int AOI_PASS_WG_SCAN = 3;

// option_bits
const int AOI_OPT_TERRAIN = 1;
const int AOI_OPT_CULL = 2;
const int AOI_OPT_STABLE_SLOTS = 4;
// @@END autoobject_instance_layout

// ── 保序流压缩用的工作组内共享量 ────────────────────────────────────────────
// s_alive / s_batch 由 count 与 scatter 两趟各填一次。两趟的 gid 划分相同、判据相同
// （都走 classify()），所以两趟看到的内容必然一致 —— 这是名次能对上的前提。
shared uint s_alive[64];
shared int s_batch[64];
shared uint s_scan[64];

// 本线程在**本工作组内、同一批中**的存活序号（按 gid 升序）。
// 与 wg_offsets 相加就是批内全局名次，全程不依赖任何原子操作的完成顺序。
uint stable_local_rank(uint lid, int asset) {
    uint rank = 0u;
    for (uint j = 0u; j < lid; j++) {
        if (s_alive[j] == 1u && s_batch[j] == asset) {
            rank++;
        }
    }
    return rank;
}

// 这个 gid 是否是「该被 emit 的存活对象」，并取出批号。
// ⚠ count 与 scatter 必须用**同一套判据**，否则两趟算出的名次对不上，
// 症状是少数实例落到别人的槽位上——不报错、只是点选串位。
bool classify(uint gid, out int asset) {
    asset = -1;
    if (gid >= uint(max(counts.x, 0))) {
        return false;
    }
    if (alive[gid] == 0) {
        return false;
    }
    int a = object_asset_index[gid];
    if (a < 0 || a >= counts.y) {
        // 没有对应批次的存活对象：静默丢弃会让"渲染少了几棵树"无处可查，
        // 诊断由宿主对比 live_count 与 Σinstance_count 得出。
        return false;
    }
    asset = a;
    return true;
}

// 覆盖 object_capacity 所需的工作组数。count 趟派发得更大（要顺带清 instance 行），
// 超出的工作组不参与计数，也不能写 wg_counts —— 那会越界。
int object_workgroup_count() {
    return (max(counts.x, 0) + 63) / 64;
}

// 地形高度采样：与被它取代的 CPU 规则（volume_score_demo._terrain_rebase_object_states）
// 逐字同构——同一个 floor 分桶、同一个 clamp、同一个 vz * res + vx 下标。
// ⚠ 该下标假设高度场是 res × res 的方阵且 res == grid.x；grid.z > grid.x 时 CPU 版本会越界，
// 这里靠 length 守卫兜住（返回 0 而不是读越界），不复刻那个缺陷。
float sample_terrain_height(vec3 world_pos) {
    int res = max(options.y, 0);
    if (res <= 0) {
        return 0.0;
    }
    vec3 safe_voxel = max(voxel_size.xyz, vec3(0.0001));
    int vx = clamp(int(floor((world_pos.x - grid_origin.x) / safe_voxel.x)), 0, res - 1);
    int vz = clamp(int(floor((world_pos.z - grid_origin.z) / safe_voxel.z)), 0, res - 1);
    int index = vz * res + vx;
    if (index < 0 || index >= res * res) {
        return 0.0;
    }
    return terrain_height[index];
}

void clear_instance_row(uint slot) {
    uint render_base = slot * uint(AOI_RENDER_FLOATS);
    for (uint i = 0u; i < uint(AOI_RENDER_FLOATS); i++) {
        instances[render_base + i] = 0.0;
    }
    uint pick_base = slot * uint(AOI_PICK_WORDS);
    for (uint i = 0u; i < uint(AOI_PICK_WORDS); i++) {
        pick_words[pick_base + i] = 0u;
    }
}

void pass_count(uint gid) {
    uint lid = gl_LocalInvocationID.x;
    uint wg = gl_WorkGroupID.x;

    // 清零与计数同趟安全：清的是 instance_* 两块，计数写的是 batch_words，互不相干。
    if (gid < uint(max(counts.z, 0))) {
        clear_instance_row(gid);
    }

    int asset = -1;
    bool is_live = classify(gid, asset);
    s_alive[lid] = is_live ? 1u : 0u;
    s_batch[lid] = asset;
    // ⚠ barrier() 必须被工作组内**所有**线程执行，所以上面那些判据都写成标志位而不是提前 return。
    barrier();

    if (int(wg) >= object_workgroup_count()) {
        return;   // 只为清行而多派发的工作组：不参与计数，也不能写 wg_counts
    }
    // 每个批号交给一个线程统计本工作组的存活数，顺带加进批总数。
    // 每 (工作组, 批) 只有一次 atomicAdd，而不是每对象一次 —— 争用反而比原来小。
    for (int b = int(lid); b < counts.y; b += 64) {
        uint c = 0u;
        for (uint j = 0u; j < 64u; j++) {
            if (s_alive[j] == 1u && s_batch[j] == b) {
                c++;
            }
        }
        wg_counts[wg * uint(counts.y) + uint(b)] = c;
        if (c > 0u) {
            atomicAdd(batch_words[uint(b) * uint(AOI_BATCH_WORDS) + uint(AOI_B_INSTANCE_COUNT)], c);
        }
    }
}

// 对 wg_counts 逐批做独占扫描 → wg_offsets。单工作组 64 线程的分块扫描：
// 每线程扫一段求和 → 线程 0 扫这 64 个段和 → 每线程回填自己那段的前缀。
void pass_wg_scan() {
    uint lid = gl_LocalInvocationID.x;
    uint w_count = uint(object_workgroup_count());
    uint batches = uint(max(counts.y, 1));
    uint chunk = (w_count + 63u) / 64u;
    uint begin = uint(lid) * chunk;
    uint finish = min(begin + chunk, w_count);

    for (uint b = 0u; b < batches; b++) {
        uint sum = 0u;
        for (uint w = begin; w < finish; w++) {
            sum += wg_counts[w * batches + b];
        }
        s_scan[lid] = sum;
        barrier();
        if (lid == 0u) {
            uint running = 0u;
            for (uint t = 0u; t < 64u; t++) {
                uint v = s_scan[t];
                s_scan[t] = running;
                running += v;
            }
        }
        barrier();
        uint offset = s_scan[lid];
        for (uint w = begin; w < finish; w++) {
            uint v = wg_counts[w * batches + b];
            wg_offsets[w * batches + b] = offset;
            offset += v;
        }
        // 下一轮 b 会重用 s_scan，必须等所有线程读完写完。
        barrier();
    }
}

void pass_prefix() {
    uint running = 0u;
    uint capacity = uint(max(counts.z, 0));
    for (int b = 0; b < counts.y; b++) {
        uint base = uint(b) * uint(AOI_BATCH_WORDS);
        uint wanted = batch_words[base + uint(AOI_B_INSTANCE_COUNT)];
        // 容量守卫：溢出的批被截断而不是写越界。截断量由宿主对比 live_count 与容量看出。
        uint start = min(running, capacity);
        uint granted = min(wanted, capacity - start);
        batch_words[base + uint(AOI_B_INSTANCE_START)] = start;
        batch_words[base + uint(AOI_B_INSTANCE_COUNT)] = granted;
        batch_words[base + uint(AOI_B_ASSET_INDEX)] = uint(b);
        batch_words[base + uint(AOI_B_CAPACITY)] = capacity - start;
        batch_words[base + uint(AOI_B_REVISION)] = uint(max(options.z, 0));
        batch_words[base + uint(AOI_B_CURSOR)] = 0u;
        running = start + granted;
    }
    dispatch_words[uint(AOI_D_GROUPS_X)] =
        (running + uint(AOI_DISPATCH_LOCAL_SIZE_X) - 1u) / uint(AOI_DISPATCH_LOCAL_SIZE_X);
    dispatch_words[uint(AOI_D_GROUPS_Y)] = 1u;
    dispatch_words[uint(AOI_D_GROUPS_Z)] = 1u;
    dispatch_words[uint(AOI_D_LIVE_COUNT)] = running;
}

void pass_scatter(uint gid) {
    uint lid = gl_LocalInvocationID.x;
    uint wg = gl_WorkGroupID.x;

    int asset = -1;
    bool is_live = classify(gid, asset);
    s_alive[lid] = is_live ? 1u : 0u;
    s_batch[lid] = asset;
    barrier();   // 必须所有线程都到，所以判死也要等到这之后再 return
    if (!is_live) {
        return;
    }

    uint batch_base = uint(asset) * uint(AOI_BATCH_WORDS);
    uint granted = batch_words[batch_base + uint(AOI_B_INSTANCE_COUNT)];
    // 保序：批内名次 = 工作组前缀 + 组内前缀。纯函数，同输入必得同置换（见文件头「槽位即身份」）。
    uint local = wg_offsets[wg * uint(max(counts.y, 1)) + uint(asset)]
        + stable_local_rank(lid, asset);
    if (local >= granted) {
        return;
    }
    uint slot = batch_words[batch_base + uint(AOI_B_INSTANCE_START)] + local;
    if (slot >= uint(max(counts.z, 0))) {
        return;
    }

    mat4 m = transforms[gid];
    vec3 bx = m[0].xyz;
    vec3 by = m[1].xyz;
    vec3 bz = m[2].xyz;
    vec3 origin = m[3].xyz;

    uint flags = AOI_FLAG_ALIVE;
    if ((object_flags[gid] & 2) != 0) {   // GPUAutoObjectRuntime.OBJECT_FLAG_SELECTED
        flags |= AOI_FLAG_SELECTED;
    }
    if ((options.x & AOI_OPT_TERRAIN) != 0) {
        // 采样列 = 实例列（pivot 位移之后），复刻被替代的 CPU 规则；
        // 「anchor 列才是语义正确的一方」留给 P0-A 的常驻高度场 plumbing 一并处置。
        origin.y += sample_terrain_height(origin);
        flags |= AOI_FLAG_TERRAIN_REBASED;
    }

    bool culled = false;
    if ((options.x & AOI_OPT_CULL) != 0 && camera.w > 0.0) {
        culled = distance(origin, camera.xyz) > camera.w;
    }
    if (culled) {
        flags |= AOI_FLAG_CULLED;
    }

    // ── instance_render：MultiMesh 行布局（行 = 基向量行 + 原点分量）──────────────
    // 剔除的槽位写零基向量（voxel_field_instances.glsl 的 write_hidden 同手法）：
    // 实例塌缩成一点，什么都不光栅化，于是 visible_instance_count 可以永远保持 -1，
    // 任何计数都不必为了正确性回到 CPU。
    uint rb = slot * uint(AOI_RENDER_FLOATS);
    if (culled) {
        for (uint i = 0u; i < uint(AOI_RENDER_FLOATS); i++) {
            instances[rb + i] = 0.0;
        }
    } else {
        instances[rb + 0u] = bx.x; instances[rb + 1u] = by.x; instances[rb + 2u] = bz.x; instances[rb + 3u] = origin.x;
        instances[rb + 4u] = bx.y; instances[rb + 5u] = by.y; instances[rb + 6u] = bz.y; instances[rb + 7u] = origin.y;
        instances[rb + 8u] = bx.z; instances[rb + 9u] = by.z; instances[rb + 10u] = bz.z; instances[rb + 11u] = origin.z;
        instances[rb + 12u] = default_color.r;
        instances[rb + 13u] = default_color.g;
        instances[rb + 14u] = default_color.b;
        instances[rb + 15u] = ((flags & AOI_FLAG_SELECTED) != 0u) ? 1.0 : default_color.a;
        instances[rb + 16u] = float(gid);
        instances[rb + 17u] = float(profile[gid]);
        instances[rb + 18u] = float(asset);
        instances[rb + 19u] = float(flags);
    }

    // ── instance_pick：与上面同一个 slot、同一轮循环写出 ──────────────────────────
    // 「画出来的」与「点中的」因此在构造上不可能分家。前三行与 instance_render 的
    // f32[0..11] 逐字节相同（剔除时那边是零，这里保留真值 + CULLED 位，让消费者
    // 自己决定跳过——把不可见的东西也写成零会让"为什么点不中"完全无法诊断）。
    uint pb = slot * uint(AOI_PICK_WORDS);
    pick_words[pb + 0u] = floatBitsToUint(bx.x);
    pick_words[pb + 1u] = floatBitsToUint(by.x);
    pick_words[pb + 2u] = floatBitsToUint(bz.x);
    pick_words[pb + 3u] = floatBitsToUint(origin.x);
    pick_words[pb + 4u] = floatBitsToUint(bx.y);
    pick_words[pb + 5u] = floatBitsToUint(by.y);
    pick_words[pb + 6u] = floatBitsToUint(bz.y);
    pick_words[pb + 7u] = floatBitsToUint(origin.y);
    pick_words[pb + 8u] = floatBitsToUint(bx.z);
    pick_words[pb + 9u] = floatBitsToUint(by.z);
    pick_words[pb + 10u] = floatBitsToUint(bz.z);
    pick_words[pb + 11u] = floatBitsToUint(origin.z);
    pick_words[pb + 12u] = floatBitsToUint(default_color.r);
    pick_words[pb + 13u] = floatBitsToUint(default_color.g);
    pick_words[pb + 14u] = floatBitsToUint(default_color.b);
    pick_words[pb + 15u] = floatBitsToUint(default_color.a);

    // OBB 来自 mesh_description[asset].mesh_aabb —— 已经 GPU 常驻，不需要新上传任何东西。
    // ⚠ 绝不能用 autoobject_bounds_min/max 反推 OBB：那是 stamp 足迹的绝对网格体素索引、
    // yaw 已烘焙，反解 yaw 会二次施加旋转，且 voxel_min * voxel_size 漏了 grid_origin。
    uint desc_base = uint(asset) * uint(AOI_MESH_DESC_VEC4);
    vec3 aabb_position = mesh_desc[desc_base + uint(AOI_MESH_AABB_POSITION_VEC4)].xyz;
    vec3 aabb_size = mesh_desc[desc_base + uint(AOI_MESH_AABB_SIZE_VEC4)].xyz;

    vec3 local_center = aabb_position + aabb_size * 0.5;
    vec3 world_center = origin + bx * local_center.x + by * local_center.y + bz * local_center.z;
    vec3 scale = vec3(length(bx), length(by), length(bz));
    vec3 half_extent = aabb_size * 0.5 * scale;
    // yaw 从常驻 transform 无损反解：写它的 yaw_transform_y 令列 0 = (ca,0,-sa)、列 2 = (sa,0,ca)，
    // 故 yaw = atan(sa, ca) = atan(m[2].x, m[0].x)。XZ 两列同一缩放，atan 对缩放不敏感。
    float yaw = atan(m[2].x, m[0].x);

    pick_words[pb + uint(AOI_P_OBB_CENTER) + 0u] = floatBitsToUint(world_center.x);
    pick_words[pb + uint(AOI_P_OBB_CENTER) + 1u] = floatBitsToUint(world_center.y);
    pick_words[pb + uint(AOI_P_OBB_CENTER) + 2u] = floatBitsToUint(world_center.z);
    pick_words[pb + uint(AOI_P_OBB_YAW)] = floatBitsToUint(yaw);
    pick_words[pb + uint(AOI_P_OBB_HALF) + 0u] = floatBitsToUint(half_extent.x);
    pick_words[pb + uint(AOI_P_OBB_HALF) + 1u] = floatBitsToUint(half_extent.y);
    pick_words[pb + uint(AOI_P_OBB_HALF) + 2u] = floatBitsToUint(half_extent.z);
    pick_words[pb + uint(AOI_P_OBB_RADIUS)] = floatBitsToUint(length(half_extent));

    pick_words[pb + uint(AOI_P_OBJECT_ID)] = gid;
    pick_words[pb + uint(AOI_P_PROFILE_ID)] = uint(max(profile[gid], 0));
    pick_words[pb + uint(AOI_P_BATCH_INDEX)] = uint(asset);
    pick_words[pb + uint(AOI_P_FLAGS)] = flags;

    ivec3 voxel_min = bounds_min[gid].xyz;
    pick_words[pb + uint(AOI_P_VOXEL_MIN_X)] = uint(max(voxel_min.x, 0));
    pick_words[pb + uint(AOI_P_VOXEL_MIN_Y)] = uint(max(voxel_min.y, 0));
    pick_words[pb + uint(AOI_P_VOXEL_MIN_Z)] = uint(max(voxel_min.z, 0));
    pick_words[pb + uint(AOI_P_ASSET_INDEX)] = uint(asset);
}

void main() {
    uint gid = gl_GlobalInvocationID.x;
    if (counts.w == AOI_PASS_COUNT) {
        pass_count(gid);
    } else if (counts.w == AOI_PASS_PREFIX) {
        if (gid == 0u) {
            pass_prefix();
        }
    } else if (counts.w == AOI_PASS_WG_SCAN) {
        pass_wg_scan();
    } else if (counts.w == AOI_PASS_SCATTER) {
        pass_scatter(gid);
    }
}
