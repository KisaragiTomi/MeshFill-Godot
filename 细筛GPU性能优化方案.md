# 细筛 GPU 性能优化方案

本方案来自 2026-07-14 对 anchor-origin residual-gain 细筛管线的性能瓶颈分析（静态代码走读，未跑实测）。对象是 `voxel_placement_generator.gd` 的 `run_multi_asset` 及其 5 个 compute pass。产出：**3 个确认瓶颈**（1 个架构级串行、1 个 scorer 双重浪费、1 组次要项）+ **分级优化方案**（4 个阶段）+ 落地顺序与验证门禁。

执行纪律：

- 先测后改——方案 0（分段计时）是所有 GPU 内核改动的前置，避免优化错对象。
- **绝不原地改常驻 SV/TargetSV 场格式**（爆炸半径见方案 A），派生 buffer 一律 scorer 私有。
- 每项改动一份外科式提交，`-e` 编辑器验证为准（本项目不跑 test 套件做常规验证）。
- 单任务 subagent 总数 ≤ 32。

## 管线结构与调度维度

单次 `run_multi_asset`，5 个 pass 串在一条 `ComputePassChain` 上（[`voxel_placement_generator.gd:485-490`](scripts/voxel_placement_generator.gd:485)）：

| Pass | Shader | 派发维度 | local_size | 说明 |
| --- | --- | --- | --- | --- |
| 1 finalize | `fine_score_dispatch_finalize.glsl` | `(1,1,1)` | `1×1×1` | 把常驻 anchor 计数写成 indirect args，host 不回读 |
| 2 score | `score_anchor_asset_residual.glsl` | indirect `(256, ⌈count/256⌉, topk)` | `64×1×1` | 1 workgroup = 1 个 `(anchor, k)` 候选，64 线程 = 64 个 `(pivot,yaw)` combo |
| 3 reduce | `reduce_anchor_candidates.glsl` | `(1,1,1)` | `1×1×1` | **单线程**贪心 max-select，公共候选池裁决 |
| 4 init bounds | `init_stamp_bounds` | `(⌈cap/64⌉,1,1)` | `64×1×1` | 清 stamp 包围盒 |
| 5 stamp | `stamp_asset_voxels.glsl` | `(result_capacity,1,1)` | `64×1×1` | 1 workgroup = 1 个落地记录，写体素场 |

规模常量：

```text
ANCHOR_CAPACITY = 65536      # autoobject_probe_prefilter_gpu.gd:30（256×256 网格）
TOPK            = 4          # autoobject_probe_prefilter_gpu.gd:29，端到端固化
rotation_slots  = 12         # voxel_placement_generator.gd:161，默认 yaw 槽数
result_capacity = 8          # voxel_placement_generator.gd:154，最终落地数（demo 默认）
候选池          = anchor_count × topk   # reduce 扫描范围
combo_count     = pivot_slots × yaw_slots  # scorer 每 workgroup 的摆法数
```

## 瓶颈清单（按 ROI 排序）

### 瓶颈 1：reduce 单线程串行贪心（架构级，最大）

`reduce_anchor_candidates` 以 `local_size 1×1×1` + `groups (1,1,1)` 派发（[`voxel_placement_generator.gd:487`](scripts/voxel_placement_generator.gd:487)）——**整个选择跑在一条 GPU lane 上，其余数千 lane 全部 idle 等它**。内核是三重嵌套贪心 NMS（[`reduce_anchor_candidates.glsl:77-131`](shaders/reduce_anchor_candidates.glsl:77)）：

- 外层 `result_capacity` 次；
- 中层每次**全量重扫**候选池 `anchor_count × topk`（无早停 argmax）；
- 内层对每个通过者再和已选结果做 `result_count` 次 3D min-distance 冲突检测。

单 lane 迭代量 ≈ `candidate_count × result_capacity² / 2`。随放置数**平方级**、随锚点池**线性级**膨胀：

| anchor_count | candidate_count | result_capacity | 单 lane 迭代 | 量级 |
| --- | --- | --- | --- | --- |
| 4000 | 16000 | 8 | ~0.6M | 尚可 |
| 4000 | 16000 | 64 | ~33M | 明显卡 |
| 4000 | 16000 | 256 | ~520M | 数百 ms~秒级 |
| 65536 | 262144 | 64 | ~537M | 秒级 |

### 瓶颈 2：scorer lane 欠占用 + 4 缓冲散射 gather（scorer 双重浪费）

`score_anchor_asset_residual` 每 workgroup 64 线程分给 `combo_count` 个 `(pivot,yaw)` 组合（[`score_anchor_asset_residual.glsl:385-409`](shaders/score_anchor_asset_residual.glsl:385)）。两个正交的浪费：

**2a 算力空转**：主流资产单 pivot × 12 yaw → `combo_count = 12`，仅 **12/64 ≈ 19%** 线程进评分内层（[`:443`](shaders/score_anchor_asset_residual.glsl:443)），其余 52 条仍要参与协同 AD 载入（[`:436`](shaders/score_anchor_asset_residual.glsl:436)，此处满载是好的）并卡在 `barrier()`（[`:441`](shaders/score_anchor_asset_residual.glsl:441)/[`:504`](shaders/score_anchor_asset_residual.glsl:504)/[`:524`](shaders/score_anchor_asset_residual.glsl:524)/[`:545`](shaders/score_anchor_asset_residual.glsl:545)）干等。单 pivot 是常态，ALU 常态浪费 ~80%（32 宽 warp 视角：线程 32-63 整条 warp 全闲仍占槽）。

**2b 散射访存**：内层对每个 AD 体素 × 每个活跃 combo 做 4 次未合并读（[`:461-472`](shaders/score_anchor_asset_residual.glsl:461)）：

| 读 | 缓冲 | 宽度 |
| --- | --- | --- |
| `complexity_field_rgba8[idx]` | CurrentSV rgb+复杂度 | 4B |
| `collision_field_u32[idx]` | CurrentSV 碰撞 | 4B |
| `target_field[idx]` | TargetSV rgba（float） | 16B |
| `target_collision_u32[idx]` | TargetSV 碰撞 | 4B |

`idx = origin + rotated_fp`（[`:453-459`](shaders/score_anchor_asset_residual.glsl:453)）随 combo（lane）发散——相邻 lane = 相邻旋转角 = 落点天各一方，地址完全不相邻。后果：**零合并、combo 间无复用、topk 间无复用**。每体素 4 个 buffer = 每体素 4 次独立 cache-line miss。评分本身只有几十 FLOP（[`:483-492`](shaders/score_anchor_asset_residual.glsl:483)），盖不住散射延迟 → 内核是 memory-bound，gather 是实际耗时主体，随 `ad_count` 线性放大。

### 瓶颈 3：次要项

- **16MB candidate buffer 每 run 清零**：`anchor_capacity × topk × 64B` = 16MB，`SCOPE_FRAME` 每次重分配+`storage_buffer_zero`（[`voxel_placement_generator.gd:343`](scripts/voxel_placement_generator.gd:343)）；reduce 又全量扫这块（大多是 `valid=0` 空槽）。
- **profiler 埋点太粗**：`_prof` 把 score+reduce+stamp 合并成单个 `score_reduce_stamp` 区间（[`voxel_placement_generator.gd:491-493`](scripts/voxel_placement_generator.gd:491)），因为三者在同一条无中间 sync 的链上——**当前无法把 reduce 的串行代价单独量出来**，这是它长期没被发现的原因。

## 优化方案

### 方案 0：分段计时（前置，必做）

在 score / reduce / stamp 之间插 GPU timestamp（或临时 `submit_and_sync` 分段），用真实 demo 场景的锚点数测出各 pass 实际占比。**先坐实"reduce 串行 vs scorer 访存"谁是当前主导，再决定后续力度**。

### 方案 A：融合采样 buffer（治 2b 访存，低风险优先）

把每体素的采样量**按职责分两条 buffer**融合，各自把"rgb/复杂度 + 碰撞"并进一条记录；scorer 内层的 4 次散射读压成 **2 次**天然对齐读（cur 一次、target 一次）：

```glsl
// scorer 私有派生 buffer，各 uvec2 / voxel = 8B，一次读拿全一侧
// CurrentSV 侧（每 run 重建，stamp 会改）
layout(set = 0, binding = 0, std430) restrict readonly buffer FusedCurrentSample {
    uvec2 cur_sample[];   // x = cur_rgba8 (rgb+复杂度), y = cur_collision (值在低字节)
};
// TargetSV 侧（设一次后静态，可常驻复用）
layout(set = 0, binding = 1, std430) restrict readonly buffer FusedTargetSample {
    uvec2 tgt_sample[];   // x = tgt_rgba8 (rgb+复杂度), y = tgt_collision (值在低字节)
};
```

**为什么 cur / target 分开、不融成一条 uvec4**（用户拍板 2026-07-14）：

- **职责不同**：CurrentSV 是"当前已放置状态"、TargetSV 是"目标约束"，语义上是两类输入。
- **重建节奏不同（更硬的理由）**：cur 每 run 被 stamp 改、须每 run 重建；target 设一次后静态。合成一条 uvec4 会**逼着每 run 连静态的 target 半边一起重建**。分开 = target buffer 建一次常驻复用（正好接替 `pack_target_field` 的角色）、cur buffer 每 run 重建。
- 代价：比单 uvec4 多一次读（4→2 而非 4→1），换职责清晰 + 免重建静态半边，净划算。

机制：散射下每次读都要吃一整条 cache line；**每体素的 buffer 数 = 每体素的独立 miss 数**。4 buffer → 2 记录 = 每体素 4 次 miss → **2 次**，砍半访存事务。散射越严重收益越直接（反直觉）。

落地要点（scorer 私有、零爆炸半径）：

- **建法复用现成模式**：`pack_prefilter_field_pair.glsl` 已是"1 线程/体素读分离常驻场、写派生融合 buffer"的先例（[`pack_prefilter_field_pair.glsl:29-37`](shaders/pack_prefilter_field_pair.glsl:29)）。cur / target 各一个这样的 pre-pass，记录做成 uvec2（保留完整 rgba8）。
- **target 侧吃紧凑上游源**：TargetSV 原生就是 rgba8（`color_rgba8`），当前被 `pack_target_field.glsl` 展开成 vec4 float（16B）才给 scorer。target 融合 buffer 直接从 rgba8 源建 uvec2（8B），**scorer 不再读那 16B 的胀开形态**；精度近无损（评分 `abs(cur-tgt)` 的 cur 本就是 8-bit，float target 的亚 1/255 精度对 8-bit 操作数无效）。
- **零爆炸半径**：两个 pre-pass 读现有场、写 scorer 私有 buffer，**常驻 SV/TargetSV 格式一律不动**；`target_field` vec4 仍留给其它 reader（`score_anchor_asset_probes.glsl` 等多个）。

⚠ 坑位：

- **target 别保留 float vec4 再拼碰撞**——std430 下 `struct{vec4; uint}` stride 被撑到 **32B**、白扔 12B/体素；量化到 rgba8 后用 uvec2（8B）。
- **不能复用粗筛的 `MergedFieldPair`（vec2）**——它只抽 complexity 低字节、**丢了 rgb**（粗筛不做颜色匹配）；细筛算五维含 RGB，必须保留完整 rgba8。
- 成本：cur / target 各一次 pre-pass（写合并、便宜）+ 派生 16B/体素（cur 8B + target 8B）；cur 每 run 重建、target 建一次。稀疏放置时可只在锚点包围盒内建 cur 半边（后续增强）。
- **彻底消掉 `pack_target_field`（`target_field` vec4→rgba8 供所有 reader）是更大的收益**（省展开 pass + 12B/体素常驻），但要改 ~5-6 个 target reader——**属高爆炸半径，宜并入 V2**（见下）。

### 方案 B：scorer combo→lane 重映射（治 2a 算力）

让 64 线程别为单 pivot 空掉 80%。候选方向（择一，需实测取舍）：

- 一个 workgroup 覆盖多个 `(anchor, k)`，用满 64 lane；
- 按 `combo_count` 动态收窄有效 local 范围 / 用 subgroup 打包；
- 把同锚点的 4 个 topk slot 折进同一 workgroup，**复用 AD 载入与锚点周边 CurrentSV gather**（同时缓解 2b 的 topk 间无复用）。

### 方案 C：并行化 reduce（治瓶颈 1，收益最大但最难）

拆单线程贪心 NMS：

- **先并行 compaction**：把 `valid=1` 候选压实到连续区间，中层不再扫满稀疏池（也顺带削瓶颈 3 的空槽扫描）；
- **分块并行 argmax + 单 lane 只做最终 min-distance 挑选**：贪心的选择有串行依赖，但每轮的"求全局最大"可并行；
- **空间网格加速冲突检测**：把内层 O(result_count) 的 min-distance 检测降到 O(邻域)。

### 与 V2 三维稀疏存储迁移的关系（须先拍板顺序）

`项目兼容性与多输入适配审计.md` 的 **阶段 V2（常驻 field 对页式稀疏化）**（[项目兼容性与多输入适配审计.md:358](项目兼容性与多输入适配审计.md:358)）与本方案在**同一批场 buffer、同一批 shader** 上动土，必须协同、不能各改各的：

- 前置澄清：**生产热路径早已是 3D 稠密线性**（每体素 4B：complexity RGBA8-in-u32 + collision unorm8-in-u32）；所谓"2D volume 存储"是**测试/检视专用形态**（`committer._volume` 生产恒空）。V1 是退役 2D 测试残留（清理），**V2 才是真·稀疏**（tile 目录 + 4×4×4 页池）。
- V2 读方明列"score/collect/pick/prefilter pack/compose 等全部线性寻址 shader"要改成 `voxel_index → directory[tile_index]` 间接寻址（[项目兼容性与多输入适配审计.md:363](项目兼容性与多输入适配审计.md:363)）——**细筛 scorer 正是其一**。
- V2 页池已在问"complexity/collision 各一池或合池"（[项目兼容性与多输入适配审计.md:362](项目兼容性与多输入适配审计.md:362)）——**这正是本方案 A 的融合决策**。用户"cur/target 分两条、各把 collision 并进 rgb/复杂度"的指示，直接就是 V2 页池布局输入：**committed 对 → cur 页池、target 对 → target 页池**。
- ⚠ **顺序风险**：若现在先把方案 A 建成**独立稠密融合 buffer**，V2 上来又要把 scorer 改成稀疏寻址，且这块稠密 buffer 与 V2"干掉 128MB 稠密场"的目标相悖 → 扔掉重做。
- 建议：**V2 若近期做 → 把方案 A 的 pair 融合直接并入 V2 页池布局**（页记录即 uvec2 pair），一次成型；**V2 若押后 → 方案 A 作稠密临时件先上**，V2 时再迁到页池（scorer 寻址那步 V2 本来也要改，融合布局可平移）。

## 落地顺序与风险

| 阶段 | 动作 | 治 | 风险 | 前置 |
| --- | --- | --- | --- | --- |
| 0 | 分段计时 | — | 无 | 无 |
| A | 融合采样 buffer | 2b | 低（派生 buffer，零爆炸半径） | 0 确认卡访存 |
| B | combo→lane 重映射 | 2a | 中（改 scorer 线程模型，需保结果逐位一致） | 0 |
| C | 并行 reduce | 1 | 高（贪心串行依赖，须保证与串行选择等价） | 0 确认 result_capacity 会放大 |

先做低风险的 A（第一刀、收益明确），B/C 视方案 0 的数字决定力度。**A/B 都不治瓶颈 1**；当 `result_capacity` 或锚点池增大时，瓶颈 1 是结构性大头，最终需要 C。⚠ 方案 A 与 V2 稀疏迁移改同一批 shader/场，**先拍板 A 独立上还是并入 V2 页池**再动手（见上节）。

## 验证门禁

- 每项改动跑 `-e` 编辑器验证（关闭在跑实例后开一个 fresh 的，见 CLAUDE.md 单实例规则）：零脚本错误 + 桥应答 = PASS。
- 行为不变类改动（A/B）须**结果逐位一致**：融合 buffer / 线程重映射不改评分值，用 `volume_score` golden 快照对照（注意：anchor-fine 落地后 golden v2 需先重录，见 mem `anchor-fine-residual-pipeline`）。
- C 改选择逻辑，须对照串行 reduce 的选择结果验证等价（同一候选池、同 min-distance/quota 下选出同一批）。

## Open Questions

- 方案 0 未跑：reduce 与 scorer 在当前真实 demo 场景（实际 anchor_count、result_capacity）下的实测占比未知——决定 A/B/C 排期的关键数字待补。
- 融合 buffer 是否值得建全网格 vs 仅锚点包围盒，取决于总采样数 vs voxel_count 的比值，需实测。
- combo→lane 重映射的具体形态（多候选/动态/subgroup）需在 2a 与 shared memory 占用之间权衡后定。
- V2（三维稀疏存储，见 [`项目兼容性与多输入适配审计.md:335`](项目兼容性与多输入适配审计.md:335)）排期未定；它与方案 A 改同一批 shader/场，**方案 A 先独立上还是并入 V2 页池，取决于 V2 是否近期执行**——须先拍板顺序。
