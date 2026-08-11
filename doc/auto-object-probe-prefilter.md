# AutoObject Probe Prefilter

本文记录 AutoObject probe 粗筛的当前实现契约。粗筛从 `TargetSV_B` 目标体积内部提取 position-only anchors（两门合取，见「Anchor 规则」），用 descriptor-backed semantic probes 给可用 `AutoObject` 打分，为每个 anchor 选出 top-K asset，并以 GPU 常驻 `anchor_candidate_handoff`（anchor / anchor_count / topk buffer）交接给细筛。最终 asset/pivot/yaw 由 `score_anchor_asset_residual.glsl` 以 anchor 为 origin 计算五维 residual gain 完成精筛。

![AutoObject probe prefilter pipeline](../demos/placement-autoobject-probe-prefilter/diagrams/autoobject_probe_prefilter_pipeline.svg)

![AutoObject probe scoring logic](../demos/placement-autoobject-probe-prefilter/diagrams/autoobject_probe_scoring_logic.svg)

当前实现已稳定：GPU pipeline、Host、Anchor、Probe source、resident anchor handoff 均已实现，CPU scoring path 已删除。以下输入/输出契约仅作为架构参考。

## 两级漏斗：probe 粗筛 → score 细筛

放置走两级漏斗，本 demo 只负责第一级（probe 粗筛）：

| 级别 | 子系统 | 对象 / 粒度 | 手段 | 产出 |
| --- | --- | --- | --- | --- |
| **probe 粗筛** | `AutoObjectProbePrefilterGPU.run_probe_prefilter` | 每 anchor × 每 asset | coarse `ProfileSample` 离散单格采样 + top-K + `min_prefilter_score` 阈值 | 每 anchor top-K asset 槽 → 常驻 `anchor_candidate_handoff` |
| **score 细筛** | `VoxelPlacementGenerator.run_multi_asset` → `score_anchor_asset_residual.glsl` | 每 anchor × top-K asset 槽 × pivot × yaw | 五维 residual gain（`loss_before - loss_after`）+ collision/clearance 有效性 | 被接受的放置 |

边界：粗筛只减少候选、决定"去哪 / 放什么"，从不写 `SceneVoxel`、从不替代 `score_anchor_asset_residual.glsl` 的 residual-gain 评分与约束验收；细筛决定"到底放不放 / 怎么放"。两级之间靠 GPU 常驻 `anchor_candidate_handoff`（anchor_buffer / anchor_count_buffer / topk_buffer，`origin_contract = "one_origin_per_anchor"`）交接，生产路径无 CPU 回读（anchor 位置回读 debug-only）。粗筛评的是 target 体积内部的 `anchor x asset`，细筛以每个 anchor 为唯一 origin 评 `top-K asset x pivot x yaw`，属于不同粒度的分层语义评分。

## 输入 / 输出

### 输入

| 数据 | 来源 | 用途 |
| --- | --- | --- |
| `SV[t - 1].complexity_field` | BlendSV-backed resident scene query channel | probe 场景复杂度采样（"已有内容"拟合）；不再参与 anchor 门控。 |
| `SV[t - 1].collision_field` | BlendSV-backed resident collision query channel | anchor / probe collision sampling。 |
| `target_completeness` | `TargetSV_B` complexity / collision read buffer | target demand 与 probe collision fit。 |
| `target_color` | `TargetSV_B` packed RGBA8 color / complexity | probe color / complexity fit。 |
| `autoobjects` | 当前可用 asset registry | 提供 semantic probes、collision samples、context radius。 |
| `voxel_sparse_ids` | dirty voxel regions / dirty tiles | 限定 anchor collection 的更新范围。 |

`TargetSV_B` 是 `TargetSV + BrushSV` 的 brush-composited read buffer，只作为 prefilter / routing / scoring / result feedback 的 target 输入。源 `TargetSV` 与 `BrushSV` 需要独立保存，便于重建 `TargetSV_B`。

### 输出

输出字段含义维护在 `scripts/autoobject_probe_prefilter_gpu.gd` 的 `_decode_results()` 和 `_empty_result()` 返回字典旁。

## GPU Pipeline

单次 `run_probe_prefilter()` 内一条 GPU 管线跑完，host 不回读 `anchor_count`（除 debug）：

```text
dirty voxel regions / dirty tiles
  -> collect_sv_anchors.glsl                       # 收集 target 体积内部 anchors（atomic append）
  -> prefilter_anchor_dispatch_finalize.glsl       # anchor_count -> 间接派发参数（无 CPU 回读）
  -> score_anchor_asset_probes.glsl                # 间接派发；每 anchor x asset probe 采样打分
  -> select_anchor_topk.glsl                       # 间接派发；每 anchor 选 top-K asset
  -> 常驻 anchor_candidate_handoff（anchor / anchor_count / topk buffer，SCOPE_PERSISTENT，交接细筛）
```

anchor 位置数组 / count 回读是 debug-only（`debug_read_anchors`，用于 `result["anchors"]` 可视化），默认关闭，路由路径全 GPU-first。

Shader 职责：

| Shader | 职责 |
| --- | --- |
| `collect_sv_anchors.glsl` | 从 dirty tile / voxel 收集统一 position-only anchors；两门合取（在 target 体积内 **且** 是该 `(x, z)` 列最底的 in-target 体素，见「Anchor 规则」），atomic-append 进 anchor 缓冲。 |
| `prefilter_anchor_dispatch_finalize.glsl` | 单线程把 GPU 常驻 `anchor_count` 转成 score / top-K 的间接派发参数（`gx = 256`，`gy = ceil(count / 256)`）；`count == 0` -> 0 组 -> 空帧自然穿过，host 永不回读。 |
| `score_anchor_asset_probes.glsl` | 每个 anchor / asset 组合按 probes 采样 `SV` 与 `TargetSV_B` buffer，输出 asset score。 |
| `select_anchor_topk.glsl` | 为每个 anchor 选择 top-K assets（低于 `min_prefilter_score` 的 asset 被拒绝）。 |

粗筛不再做 tile 聚合或候选区域膨胀：旧的 `reduce_anchor_topk_to_voxel_regions.glsl` / `pack_candidate_route_records_from_votes.glsl`（candidate route）已随 tile 细筛管线删除。

`anchor_candidate_handoff` 的 anchor / anchor_count / topk 缓冲是 SCOPE_PERSISTENT 常驻，跨 `gc_frame()` 存活并交接给细筛；`anchor_capacity = 65536`、`topk = 4`（编译期契约）、`origin_contract = "one_origin_per_anchor"`——每个 anchor 就是一个候选 origin，细筛不再枚举 tile 内 512 个候选原点。

## Anchor 规则

当前 anchor 是 position-only：

```text
anchor_buffer[i] = uvec4(voxel_x, voxel_y, voxel_z, 0)   # 位置本身承载放置含义，无 anchor_kind
```

门控是**两条合取**（不是单一 inside-target 门），不再写入或区分 `ground` / `target_top` kind
（`shaders/collect_sv_anchors.glsl`）：

1. **cell 在 target 体积内部**：`max(target_complexity[idx], target_collision[idx]) > min_target_interest`
   （completeness 与量化 collision 取 `max`，是 Houdini `Pipeline.hip` 里
   `volumesample(targetVol, 0, P) > 0` 的 GPU 孪生）。
2. **它是该 `(x, z)` 列最底的 in-target 体素**：其下方（`-y`）不存在 in-target 体素。

第二条使**每个 `(x, z)` 列至多发出一个 anchor**（最低的合格体素），anchor 永不垂直堆叠；
竖直间隙 / 悬垂按设计只保留该列最底的 in-target cell。这也是 `256×256` XZ 网格锚点上限
`65536` 的来源。

旧的 scene-occupancy / collision / support-below 门控已删除：score 阶段已惩罚 collision/overlap 并强制物件间距，anchor 阶段再测一遍属冗余（还多一次 field 读）。最终物理约束仍由 placement collision-sample scoring 确认；`ground` / `target_top` 名称只作为配置输入同义词归一到 `anchor`。

## Probe 规则

Probe 语义经 `AutoObject.get_profile_samples(density)`（GPU prefilter 的打包入口）进入 coarse `ProfileSample`，通常来自 `AssetDescriptor.semantic_probe_generator`（descriptor 侧 `get_semantic_probes()` 仍在）。当前 prefilter 不从 `object_type` 推导语义，也不使用 `object_subtype`。

Probe packed 字段含义维护在 `scripts/semantic_probe_generator.gd` 的 probe record 构造和 `scripts/autoobject_probe_prefilter_gpu.gd` 的 probe packing 代码旁。

采样越界时，`score_anchor_asset_probes.glsl` **直接 `continue` 丢弃该 sample**（`profile_sample_in_bounds()` 不通过），不 clamp 到最近有效体素。在界内则按同一体素线性索引读四个 `set = 0` binding：`scene_complexity_rgba8`（binding 3）、`scene_collision_u32`（binding 4）、`target_field_rgba8`（binding 5）、`target_collision_u32`（binding 6）。

### Probe 评分公式 (`eval_probe`)

每个 probe 的 sample position 由 `resolve_profile_sample_voxel()` 求出；`profile_sample_in_bounds()` 不通过时该 sample **直接 `continue` 跳过**，不 clamp 到 grid 边界。

**没有分支判定**——所有 probe 使用统一的加权求和公式，行为通过三个 per-metric 权重 `w_color`、`w_complexity`、`w_collision` 控制。

#### 三个 Fit 分量

| Fit 分量 | 公式 | 含义 |
| --- | --- | --- |
| color_fit | `2 × (1 - dist(target.rgb, expected.rgb) / sqrt(3)) - 1` | 颜色越接近目标越高，重映射到 `[-1, 1]` |
| complexity_fit | `2 × (1 - \|target.a - expected_complexity\|) - 1` | 复杂度越接近目标越高，重映射到 `[-1, 1]` |
| collision_fit | `1 - \|max(target_collision, current_collision) - expected_collision\|` | 取**目标与当前场景 collision 的 max**，不是目标场 alpha |

#### 评分公式

```text
probe_score = sample_weight × (w_color × color_fit
                             + w_complexity × complexity_fit
                             + w_collision × collision_fit)
```

权重为 0 的分量不参与计算。`sample_weight`（record 的 `offset_weight.w`）是**独立于**三个语义权重的
乘数——漏掉它会得到错误量级。公式定义在 `scripts/utils/placement_shared_glsl.gd` 的
`evaluate_profile_sample(..., PROFILE_SAMPLE_POLICY_COARSE_MATCH)`。

#### 典型权重配置

| 用途 | w_color | w_complexity | w_collision | 说明 |
| --- | --- | --- | --- | --- |
| 通用 | 1.0 | 1.0 | 1.0 | 三项等权 |
| 纯碰撞（地面/支撑） | 0.0 | 0.0 | 1.0 | 只关注实体占位 |
| 纯视觉 | 1.0 | 0.5 | 0.0 | 关注颜色和复杂度 |
| 空旷区域 | 0.0 | 0.1 | 0.0 | 期望低值 → 低复杂度位置得高分 |

#### GPU 数据布局（固定槽位 Profile Arena，32 字节 / sample）

probe 不再有独立 SSBO：它是常驻 Profile Arena 槽位里的一条 coarse `ProfileSample`，
shader 侧只有一个 `ProfileArena` binding（`score_anchor_asset_probes.glsl` 的
`set = 0, binding = 2`），经 `decode_profile_sample(profile_arena_sample(slot_index, i))` 解出：

```text
offset_weight = vec4(local_offset_world.xyz, sample_weight)
payload       = uvec4(rgba8, packed_metrics, flags, reserved)
```

`packed_metrics` 里解出 `collision` 与三个语义权重 `(w_color, w_complexity, w_collision)`。
per-asset range 是 `uvec2(slot_index, coarse_count)`，coarse 段恒从槽内下标 0 起算。

### Per-anchor 聚合

每个 anchor × asset 组合遍历该 asset 的所有 probe：

```text
asset_score = Σ probe_score_i    for all probes i
```

16 个 probe lane（`PROBE_LANES = 16`）通过 shared memory 并行归约。结果写入
`asset_scores[anchor_id * asset_stride + asset_id]`——`asset_stride` 由 push constant
`voxel_size_inv.w` 传入，**不是**硬编码的 256。

### Top-K 选择

`select_anchor_topk.glsl` 为每个 anchor 选出 `TOPK = 4`，按运行时 `asset_count` 遍历
（`asset_stride` clamp 到 256 只是容量上限，不是遍历量）：

```text
anchor_topk[anchor_id * 4 + k] = uvec2(asset_id, floatBitsToUint(score))
```

- Thread 0 串行选择，每次挑最高分，标记已选（-2.0）再选下一个
- `0xFFFFFFFF` 表示空槽位，`score < 0` 表示被拒绝
- `min_prefilter_score` 可以全局过滤低分 asset

### Top-K 交接（不回读）

top-K 缓冲不回读 CPU：`result["anchor_autoobject_topk"]` 恒为空 dict（GPU internal），实际数据经 `anchor_candidate_handoff.topk_buffer_rid` 常驻交接给细筛（`score_anchor_asset_residual.glsl` 直读）。

## Context Sensing

`context_sensing_radius` 仍是 descriptor / profile 字段（随 Profile Arena 槽位 header 常驻上传），但它的旧消费者——candidate route 的召回扩张——已随 candidate route 删除。anchor-origin 细筛直接以 anchor 为 origin 在资产自身 `fine_sample_range` 上评分，不需要 route 覆盖扩张。

## Candidate Region Expansion

（历史）candidate region expansion 已随 candidate route 删除：旧的 docs-facing `candidate_voxel_regions_by_asset` 输出不复存在（`candidate_voxel_sparses_by_asset` 是更旧的 legacy alias），`candidate_route_extents`、route profile 构建与 CPU/GPU route pack 均已移除。粗筛输出即 `anchor_candidate_handoff`，细筛以 anchor 为 origin，无需保守区域扩张。

## 与 Placement 的关系

```text
prefilter 常驻 anchor_candidate_handoff（anchor / anchor_count / topk buffer，SCOPE_PERSISTENT）
  -> ScenePlacementActor 常驻交接（track_borrowed_rid + 交接契约 settings）
  -> VoxelPlacementGenerator.run_multi_asset()   # 一条 GPU 链跑完全部 asset，无 CPU fallback
  -> fine_score_dispatch_finalize.glsl           # anchor_count -> 间接派发（origin_count == anchor_count）
  -> score_anchor_asset_residual.glsl            # score 细筛：anchor x top-K asset 槽 x pivot x yaw 五维 residual gain
  -> init_anchor_atomic_reduce.glsl              # 每个 Anchor 选唯一 Fine 候选并建立 XZ 直接索引
  -> invalidate_anchor_conflicts.glsl            # 稳定 random 优先级 + atomicAnd 单轮失效
  -> compact_anchor_atomic_reduce.glsl           # barrier 后按 Anchor ID 应用 quota/capacity 并写出
  -> init_stamp_bounds -> stamp_asset_voxels.glsl  # mixed-asset stamp（state-chain 原位提交）
  -> accepted placements
  -> optional GPUAutoObjectRuntime writeback（GPU-direct 常驻）
  -> instance_stamp_writeback
  -> dirty SceneVoxelTile / commit_scene_voxels()
```

旧 `candidate_voxel_regions_by_asset` 输出（及 legacy `candidate_voxel_sparses_by_asset` alias）已随 candidate route 删除，不再是任何路径的输出。

边界：

- prefilter 只减少候选，不直接写入 scene。
- `anchor_count == 0` 的空帧自然穿过（finalize 写出 0 组间接派发），不回退 full grid。
- `score_anchor_asset_residual.glsl` 以 anchor 为 origin，对 top-K asset 槽的每个 pivot × yaw 组合在一次 `ProfileSample` fine range 遍历里算五维（collision/complexity/R/G/B）residual gain：`loss_before(CurrentSV vs TargetSV) - loss_after(compose(CurrentSV, AD) vs TargetSV)`；Fine 与 Stamp 共用 `profile_sample_runtime` 坐标解析和 compose 规则，clearance sample 只进物理 clearance 累计。
- 细筛不重复粗筛的 `anchor x asset` routing/top-K；no-op 是隐式 baseline，`gain > threshold` 才 valid。同一 Anchor 只保留 gain 最高的 Fine 候选，不同 Anchor 不比较 gain；冲突 loser 由稳定 random 键决定。
- runtime writeback 和 `instance_stamp_writeback` 是 accepted placement 之后的显式 opt-in；prefilter 本身不拥有 runtime object state 或 committed SV source。

## TargetSV_B Source 边界

`TargetSV_B` 是 guidance / target 输入，不是 committed source voxel stream：

- `target_completeness` 和 `target_color` 从 `TargetSV_B` 映射而来。
- `TargetSceneVoxel` guidance record 会跳过 source buffers。
- committed `SceneVoxel` 由 stamp（VPG state-chain / CPU 入口盖章）和 `commit_scene_voxels()` 发布，纯 auto；brush 内容在 SPA 常驻 `BrushSV` 层。

更完整的目标画布说明见 [`target-scene-voxel-projection.md`](target-scene-voxel-projection.md)。

## Debug 输出

Debug 输出字段含义维护在 `scripts/autoobject_probe_prefilter_gpu.gd` 的 readback 返回字典旁。

`best_autoobject_id`、`best_probe_score`、`rejected_reason` 等 overlay 信息可以后续扩展，但不是当前 readback 主契约。

## TODO / Open Questions

- 额外的 candidate validation / MLP 只作为候选内二次验证计划，不能绕过 upstream prefilter，也不替代细筛 residual gain。
- 是否增加 tile summary / mip / feedback priority。
