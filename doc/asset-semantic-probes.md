# Asset Semantic Probes: 资产语义采样点

本文记录 `AssetDescriptor.semantic_probe_generator` 的资产侧约定。`AssetDescriptor` 整体定义见 [`asset-descriptor.md`](asset-descriptor.md)。Probe 是 descriptor-backed asset default：当前 GPU prefilter 用它对 `anchor x asset` 评分并收窄每个 anchor 的候选 `AutoObject`（top-K 槽）；后续候选内部 rerank / validation 也只能在这些候选内使用。Probe 不负责从全资产库发现新候选，也不写 committed `SceneVoxel`。

Descriptor 通过 SPA（`ScenePlacementActor`）注册到 GPU profile container，使其 probes/collision/pivots 即刻 GPU 可读；SPA 生命周期和访问接口见 [`scene-placement-actor.md`](scene-placement-actor.md)。

![AutoObject probe scoring logic](../demos/placement-autoobject-probe-prefilter/diagrams/autoobject_probe_scoring_logic.svg)

## 当前边界

| 项 | 当前规则 |
| --- | --- |
| 职责 | 表达资产局部采样期望，供 prefilter 对 `anchor x asset` 打分。 |
| 语义来源 | [`AssetDescriptor.semantic_probe_generator`](asset-descriptor.md)。`AutoObject` 同名字段只是 Inspector / config mirror。 |
| 读取入口 | GPU prefilter 走 `AutoObject.get_profile_samples()`；descriptor 侧 `get_semantic_probes()` 仍在。 |
| 输入 | descriptor `color` / `complexity` / `collision`、mesh、density、`context_sensing_radius`、当前 `SV[t - 1]` 和 `TargetSV_B` read buffers。 |
| 当前消费者 | `AutoObjectProbePrefilterGPU` 消费 coarse `ProfileSample` 做候选收窄；VPG score contract 从同一个常驻 Profile Arena 的定长槽位读 header / samples / pivots 做细粒度语义评分与约束绑定验收。两个 worker 均由 SPA 懒创建并注入共享 RD + profile container。 |
| Probe 职责 | 对 position-only anchor 与当前可用 asset registry 打分，输出候选收窄信号。 |
| 输出边界 | 输出是常驻 `anchor_candidate_handoff`（anchor / anchor_count / topk buffer）；`anchor_autoobject_topk` 当前是 GPU 内部中间结果；旧 docs-facing route view `candidate_voxel_regions_by_asset`（及 `autoobject_candidate_voxel_sparses` / `candidate_voxel_sparses_by_asset` legacy/debug alias）已随 candidate route 删除。 |
| 生命周期 | SPA.register_asset(descriptor) → descriptor 编译为 profile → AutoVoxelRuntimeProfileContainer.upload_profiles() → GPU resident → prefilter/placer 通过 SPA 借用 borrowed GPU buffers → dispatch 内部评分/top-K → 常驻 `anchor_candidate_handoff` 交接细筛。descriptor 注册后即时 GPU 可读，无需等待 frame end。 |
| Source of truth | Probe 默认值在 descriptor / `SemanticProbeGenerator`；候选交接在 prefilter 常驻 handoff；committed `SceneVoxel` 仍由 source write / blend 发布。 |
| 候选边界 | prefilter 只减少候选；candidate-only rerank 不能把未进入候选集的 asset 加回。 |
| 禁止事项 | 不遍历全资产库，不输出全局 `voxel_asset_topK`，不替代 `score_anchor_asset_residual.glsl`。 |
| 细筛约束 | collision 采样、clearance、spacing、target coverage 由 placement score 阶段结合细粒度语义分数验收。 |
| TargetSV_B 采样 | 越界 sample 直接 `continue` 跳过（`profile_sample_in_bounds()` 不通过即丢弃），**没有** clamp 到最近有效 voxel 这一步。 |
| 提交边界 | prefilter 不写 committed `SceneVoxel`；提交仍走 `AutoSceneVoxel` / `BrushSceneVoxel` source write 与 blend。 |

`AutoObject.semantic_probe_generator`、`semantic_probe_density` 和 `context_sensing_radius` 只作为 Inspector / 配置字典入口；新逻辑应通过 descriptor-backed getter 读取 probes。

本文只维护资产 probe schema 与 prefilter 交接。anchor 候选交接、空帧穿过、fine residual-gain score/constraints 和 result feedback 分别见 [`auto-object-probe-prefilter.md`](auto-object-probe-prefilter.md) 和 [`scene-voxel-field-system.md`](scene-voxel-field-system.md)。

## Probe 数据结构

每个 probe 表示相对统一 position-only asset anchor 的采样点。规范化字段以 `scripts/semantic_probe_generator.gd` 的 `normalize_probe()` / `make_probe()` 为准：

```gdscript
{
	"offset": Vector3.ZERO,          # anchor-relative sample position
	"expected_color": Color.WHITE,   # expected visual color
	"expected_complexity": 1.0,      # expected complexity / alpha（写回 expected_color.a）
	"expected_rgba8": 0xffffffff,    # semantic-side packed color + complexity
	"expected_collision": 0.0,       # expected solid strength
	"w_color": 1.0,                  # color_fit 权重
	"w_complexity": 1.0,             # complexity_fit 权重
	"w_collision": 1.0,              # collision_fit 权重
	"source": "mesh",                # mesh / context / manual / fallback
	"shape_source": "convex",        # optional generation priority/debug source
}
```

`make_probe()` 只产出上表中的键。旧的 `weight` / `flags` / `kind` 三键**已不存在**：评分项开关改由
三个浮点权重 `w_color` / `w_complexity` / `w_collision` 表达（权重为 0 即关闭该项），
`FLAG_COLOR` / `FLAG_COMPLEXITY` / `FLAG_COLLISION` / `FLAG_EMPTY` / `FLAG_SUPPORT` 位掩码和
`kind = positive/negative/support` 分支在 shader 侧都没有对应实现，support 探针已明确取消
（见 `scripts/asset_descriptor.gd` 顶部注释）。

⚠ 与之同名易混的另一套是 sample **阶段** flags（`SAMPLE_FLAG_COARSE` / `FINE` / `CLEARANCE` /
`STAMP_WRITE` / `SCORE_ONLY`，定义在 `scripts/utils/profile_record_schema.gd`）——它们标记 sample
参与哪个阶段，不是评分通道开关。

`expected_color` / `expected_complexity` 优先于 legacy `color` / `complexity` 输入；`expected_rgba8` 会在 GPU host packing 时转换为 shader 侧 RGBA8 顺序。

GPU prefilter 在 `run_probe_prefilter()` 内借用调用方传入的、已 `runtime_ready` 且在同一 `RenderingDevice` 上的 `AutoVoxelRuntimeProfileContainer` 的常驻 Profile Arena buffer，只为当前 asset 顺序生成 transient range buffer。`AutoVoxelRuntimeProfileContainer` 把同一套 descriptor / profile 语义归一化进**单个** GPU storage buffer（`ALL_GPU_BUFFER_NAMES == ["profile_arena"]`，Header/Samples/Pivots/MeshDescription 各占定长槽位）；VPG runtime/profile contract 只能在该 resident buffer ready、bound、consumed 后通过。`ISWS` 可以携带本轮实例 stamp 上下文，但 sample 默认值仍来自 descriptor / profile side 的资产数据，不从 `ISWS` 反推，也不能把 CPU staging / debug readback snapshot 当作 runtime success。

Prefilter 输出会附带 `profile_probe_pack` debug summary：borrowed Arena RID、profile id 映射和 no-RD / profile-container-not-ready blocked reason 都必须显式保持 `cpu_fallback=false`。该 summary 的字典键仍沿用 `profile_sample_records_borrowed` / `profile_sample_records_buffer` 旧名（`scripts/autoobject_probe_prefilter_gpu.gd`），值已是 Arena RID。该 summary 只说明 coarse score pass 的输入来源；Fine/Stamp 对同一 RID 的 fine 段和 pivot 槽位的绑定消费仍由 VPG contract 验收。

```text
profile_arena_sample(slot_index, i).offset_weight = vec4(local_offset_world, sample_weight)
profile_arena_sample(slot_index, i).payload       = uvec4(rgba8, packed_metrics, flags, reserved)
asset_probe_range[asset_id]                       = uvec2(slot_index, count)
```

Arena 化之后 `range.x` 存的是 **slot_index（= 稠密 profile_index）**，不再是扁平 buffer 里的全局累计
起点；coarse 段恒从槽内 0 起算。shader 侧只有一个 `ProfileArena` binding
（`score_anchor_asset_probes.glsl` 的 `set = 0, binding = 2`），probe 经
`decode_profile_sample(profile_arena_sample(slot_index, i))` 解出。

## 生成来源

`SemanticProbeGenerator.generate_from_mesh()` 按优先级生成候选点。`collision` 输入是通用 voxel 场的逐体素样本列表，每条目带 `local_pos` + 同级 `color` / `complexity` / `collision`。probe 的 collision 与 complexity 从同一个 voxel 读取，处于同一层级。不再支持手工固定形状（cylinder / box）采样。

| 优先级 | `shape_source` | `source` | 来源 | 用途 |
| --- | --- | --- | --- | --- |
| 1 | `convex` | `mesh` | `Mesh.create_convex_shape()` 凸包点 | 覆盖资产简化轮廓。 |
| 2 | `voxel_interior` | `mesh` | `collision` 条目：通用 voxel 场逐体素样本 | 表达实体体积，并携带逐体素 color / complexity / collision。 |
| 3 | `surface` | `mesh` | mesh 三角面 Poisson 采样 | 在 convex / collision 不足时补齐表面。 |
| 4 | `context` | `context` | mesh AABB 外围环形采样 | 小型草、灌木用于感知周围残余 `TargetSV_B`。 |
| fallback | `fallback` | `fallback` | mesh 缺失或候选为空时的单点 probe | 保证 asset 至少有一个可评分 probe。 |

`context_sensing_radius = 0.0` 时禁用 context probe；`> 0.0` 时会在 mesh AABB 外围增加低权重 probes。

## 共享字段关系

Probe 期望值只依赖共享语义字段 `color`、`complexity` 和 `collision`；字段清单维护在 `scripts/shared_property_type.gd` 的 `SHARED_FIELD_KEYS` 声明旁。

`channel` 不参与 probe 语义。

## Probe 生成选择

选择阶段使用分层 Top-K + 最小距离约束：

```text
convex
  -> voxel_interior
  -> surface
  -> context
  -> final fallback
```

同一阶段会逐步放宽 `PROBE_WORLD_MIN_DISTANCE`，保证重要轮廓优先，同时避免 probes 过度聚集。

## Runtime 采样与评分

GPU score pass 对每个 anchor / asset 组合读取 probes：

```text
p = resolve_profile_sample_voxel(sample, anchor_pos, ..., voxel_size)
if (!profile_sample_in_bounds(p, grid_size)) continue;   // 越界即丢弃，不 clamp
idx               = voxel_index(p)
current_rgba      = unpack_profile_sample_rgba8(scene_complexity_rgba8[idx])
current_collision = float(scene_collision_u32[idx] & 0xFFu) * (1.0 / 255.0)
target_rgba       = unpack_profile_sample_rgba8(target_field_rgba8[idx])
target_collision  = float(target_collision_u32[idx] & 0xFFu) * (1.0 / 255.0)
```

shader 对每条 coarse sample 统一调用
`evaluate_profile_sample(sample, fields, PROFILE_SAMPLE_POLICY_COARSE_MATCH)`——没有 positive /
negative / empty / support 分支。三项 fit 定义在 `scripts/utils/placement_shared_glsl.gd`：

```text
color_fit      = 2 * (1 - distance(target.rgb, expected_color.rgb) / sqrt(3)) - 1
complexity_fit = 2 * (1 - abs(target.a - expected_complexity)) - 1
collision_fit  = 1 - abs(max(target_collision, current_collision) - expected_collision)
contribution   = sample_weight * dot(vec3(w_color, w_complexity, w_collision),
                                     vec3(color_fit, complexity_fit, collision_fit))
```

`color_fit` / `complexity_fit` 重映射到 `[-1, 1]`；`collision_fit` 取目标与当前场景 collision 的
`max()`，不是目标场 alpha。`sample_weight`（record 的 `offset_weight.w`）是**独立于**三个语义权重的
乘数，漏掉它会得到错误量级。旧的 `empty_fit` / `support_fit` 与「地下场景跳过非 collision probe」
的特判在当前 shader 中都不存在。

coarse pass 只消费带 `PROFILE_SAMPLE_FLAG_COARSE` 且 `sample_weight > 0` 的 sample，逐 lane 累加后
归约写入 `asset_scores[anchor_id * asset_stride + asset_id]`；`asset_stride` 由 push constant
`voxel_size_inv.w` 传入（不是硬编码的 256）。`min_prefilter_score` 只在 Pass B
（`shaders/select_anchor_topk.glsl`）里生效，对每个 anchor 选 `TOPK = 4`。

后续如果增加候选内 route validation，可在候选集合内组合 route score：

```text
route_score = combine(candidate_score, probe_score, support_hint)
```

`route_score` 不是细筛 residual gain 的输入；即使后续实现，也不能把未进入 prefilter top-K 候选槽的 asset 加回候选集。

## GPU Prefilter 输出

`AutoObjectProbePrefilterGPU.run_probe_prefilter()` 当前返回：

```gdscript
{
	"anchors": [],                              # position-only anchor readback (debug_read_anchors，默认关闭)
	"anchor_autoobject_topk": {},               # GPU internal, not read back
	"anchor_candidate_handoff": {},             # resident anchor / anchor_count / topk buffer 交接
	"anchor_count": 0,                          # collected anchor count（debug readback 时才非 0）
	"profile_probe_pack": {},                   # probe pack source / borrowed buffer debug
	"prefilter_reason": "ok",                   # ok / no-RD / blocked reason
	"cpu_fallback": false,                      # no CPU success path
}
```

旧的 per-asset candidate-region 输出键（`candidate_voxel_regions_by_asset`、legacy `candidate_voxel_sparses*` alias、`candidate_route_extents`）已随 candidate route 删除。prefilter 不会写 source stream、不会改 `SV[t - 1]`，也不会发布 committed `SceneVoxel`。

## Anchor 语义

当前 anchor 统一为 position-only `anchor`。资产不再通过 `ground` / `target_top` 区分 anchor 类型；`allowed_anchor_kinds` 仅作为 config 入口保留，读取时会归一到单一 `anchor`。

Prefilter 从 supported candidate position 来源收集位置，写入统一的 `anchor_buffer`，probe offset 始终按统一 anchor 原点解释。

## 可执行 JSON 示例

probe 会由 descriptor-backed `collision`、mesh 和默认 probe 参数生成。

```json
{
  "type": "vegetation",
  "asset_id": "sample_autoobject",
  "channel": 1,
  "radius": 0.45,
  "color": [0.25, 0.55, 0.22, 0.6],
  "complexity": 0.6,
  "collision": [],
  "group": "placed_autoobjects",
  "mesh_create_method": "create_sample_autoobject_mesh"
}
```

## 验收标准

- 每个 asset 能导出稳定且数量可控的 `semantic_probes`。
- Probe scoring 只收窄当前可用 `AutoObject`（每 anchor top-K 候选槽）。
- `AutoVoxelRuntimeProfileContainer` 只有在 GPU upload 后 `runtime_ready == true` 且 required buffers 有效时，才能作为 runtime/profile contract 输入。
- TargetSV / TargetSV_B 不包含 asset 类型标签。
- TargetSV_B 越界采样直接跳过该 sample（不 clamp、也不当作空白计分）。
- 最终物理可行性仍由 `score_anchor_asset_residual.glsl`、三阶段原子失效 Reduce 和 placement pipeline 判定。
- Prefilter 不写 committed `SceneVoxel`，`anchor_count == 0` 空帧自然穿过，不回退 full grid。

## 相关入口

- `scripts/semantic_probe_generator.gd`：probe 生成、规范化、字段默认值与 selection priority。
- `scripts/asset_descriptor.gd`：descriptor-backed `semantic_probe_generator`、density、context radius 与 `get_semantic_probes()`。
- `asset-descriptor.md`：descriptor 的统一定义、字段分组和 authoring 边界。
- `scripts/auto_voxel_runtime_profile_container.gd`：descriptor / profile 去重、`profile_id`、GPU resident profile table/sample/pivot buffers 与 debug readback。
- `scripts/autoobject_probe_prefilter_gpu.gd`：GPU buffer packing、dispatch 与常驻 `anchor_candidate_handoff` 交接。
- `shaders/score_anchor_asset_probes.glsl`：clamped sampling、score terms、`min_prefilter_score` 前的 probe evaluation。
- `shaders/select_anchor_topk.glsl`：per-anchor top-K asset 槽选择（handoff 的 topk buffer 生产者）。
- [`auto-object-probe-prefilter.md`](auto-object-probe-prefilter.md)：placement 侧 prefilter / routing 边界。
- [`scene-voxel-field-system.md`](scene-voxel-field-system.md)：`SV[t - 1]` / `TargetSV_B` 读取边界、source write 和 committed `SceneVoxel` 发布。

## 开放问题

- Prefilter 借用 container 的常驻 Profile Arena，并通过 `profile_probe_pack` 公开 borrowed / blocked 状态；per-asset range buffer 仍是本轮 transient buffer，因为 `score_anchor_asset_probes.glsl` 以当前 asset 顺序读取 `uvec2(slot_index, count)`。（该 summary 的字典键仍沿用 `profile_sample_records_borrowed` / `profile_sample_records_buffer` 旧名，值已是 Arena RID。）
- 资产 profile 常驻后只有 **一个** GPU 生产 buffer：`AutoVoxelRuntimeProfileContainer.ALL_GPU_BUFFER_NAMES == ["profile_arena"]`，Header/Samples/Pivots/MeshDescription 全在定长槽位里；coarse/Fine 通过槽内连续 range 区分，不能恢复 CPU-side runtime 替代路径。
- 当前文档只引用 placement 相关文档作为边界说明，不在这里维护 placement 方案细节。
