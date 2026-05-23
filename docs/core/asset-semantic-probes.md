# Asset Semantic Probes — 资产语义采样点

本文记录当前 `AutoVoxelDescriptor.semantic_probe_profile` 的资产侧约定。Probe 通过 `AutoObject.get_semantic_probes()` 读取或生成，但资产语义主来源仍是 descriptor；Probe 用于上游 prefilter 和候选集内部 rerank / validation，不负责从全资产库发现新候选。

![AutoObject probe scoring logic](../graphs/autoobject_probe_scoring_logic.svg)

## 当前边界

| 项 | 当前规则 |
| --- | --- |
| 候选来源 | `anchor_autoobject_topk` / 上游 prefilter。 |
| Probe 职责 | 在已允许的候选资产内计算匹配分、重排、降权或剔除。 |
| 禁止事项 | 不遍历全资产库，不输出全局 `voxel_asset_topK`，不替代 `score_voxel_tile.glsl`。 |
| 物理判断 | footprint、support、collision、clearance 仍由 placement score 阶段负责。 |
| TargetSV_B 采样 | 越界 sample 先 clamp 到最近的有效 TargetSV_B voxel。 |

旧版“每个 ground anchor 遍历所有 asset 并输出 voxel 级 top-K”的方案已废弃；当前 hard gate 是每个 anchor 的粗筛候选集。

`AutoObject.semantic_probe_profile`、`semantic_probe_density` 和 `context_sensing_radius` 只作为 Inspector / 配置字典兼容入口；新逻辑应通过 descriptor-backed getter 读取 probes。

## Probe 数据结构

每个 probe 表示相对某个 asset anchor 的采样点。

| 字段 | 含义 |
| --- | --- |
| `offset` | 相对 asset anchor 的采样位置。 |
| `expected_rgba8` | 期望颜色与复杂度，`RGB=color`，`A=complexity`。 |
| `expected_collision` | 期望碰撞 / 实体强度。 |
| `weight` | 对 probe 总分的权重。 |
| `flags` | 参与颜色、复杂度、collision、空白或支撑评分的位标记。 |
| `kind` | `positive` / `negative` 等 probe 类型。 |
| `source` | `convex`、`voxel_interior`、`surface`、`context` 等生成来源。 |

GPU prefilter buffer 按 SoA 保存：

```text
asset_probe_offset_buffer
asset_probe_expected_rgba8_buffer
asset_probe_weight_buffer
asset_probe_range_buffer  # asset_id -> start/count
```

## 生成来源

`SemanticProbeProfile.generate_from_mesh()` 当前按优先级生成候选点。

| 优先级 | `source` | 来源 | 用途 |
| --- | --- | --- | --- |
| 1 | `convex` | `Mesh.create_convex_shape()` 凸包点 | 覆盖资产简化轮廓。 |
| 2 | `voxel_interior` | `collision_voxels` 内部采样 | 表达 trunk、rock 等实体体积。 |
| 3 | `surface` | mesh 三角面 Poisson 采样 | 在 convex / collision 不足时补齐表面。 |
| 4 | `context` | mesh AABB 外围环形采样 | 小型草、灌木用于感知周围残余 TargetSV_B。 |

`context_sensing_radius = 0.0` 时禁用 context probe；`> 0.0` 时会在 mesh AABB 外围增加低权重感知 probes。

## 选择规则

选择阶段使用分层 Top-K + 最小距离约束：

```text
convex
  -> voxel_interior
  -> surface
  -> context
  -> final fallback
```

同一阶段会逐步放宽 `PROBE_WORLD_MIN_DISTANCE`，保证重要轮廓优先，同时避免 probes 过度聚集。

## Anchor 类型

资产可以通过 `allowed_anchor_kinds` 限制参与的 anchor 层：

| Anchor | 用途 |
| --- | --- |
| `ground` | 地面 / 支撑点资产，例如草、灌木、树、普通石头。 |
| `target_top` | 与 TargetSV_B 顶部或高处目标对齐的资产，例如部分岩体或冠层对齐测试。 |

同一个 asset 若支持多种 anchor，需要按对应 anchor 原点解释 `probe.offset`。

## 评分

每个候选 route 读取对应 anchor + asset 的 probes：

```text
sample_pos = anchor_pos + probe.offset
sample_pos = clamp(sample_pos, target_sv_min, target_sv_max)
sample     = TargetSV_B[sample_pos]
```

推荐基础分量：

```text
color_fit      = 1 - distance(sample.rgb, expected.rgb)
complexity_fit = 1 - abs(sample.a - expected.a)
collision_fit  = 1 - abs(sample_collision - expected_collision)
empty_fit      = 1 - sample_complexity
support_fit    = support_below(anchor)
```

总分只用于候选内部排序或剔除：

```text
probe_score = weighted(color_fit, complexity_fit, collision_fit, empty_fit, support_fit)
route_score = combine(candidate_score, probe_score, support_hint)
```

`route_score` 不能把未进入 `anchor_autoobject_topk` 的 asset 加回候选集。

## 与其他文档的关系

- `../placement/autoobject-probe-prefilter.md`：说明 GPU prefilter 如何生成 `anchor_autoobject_topk` 和 candidate voxel regions。
- `../placement/voxel-semantic-routing.md`：说明候选路由、TargetSV_B clamp 采样和 `candidate_voxel_sparses_by_asset` 的 candidate voxel-region 合约。
- `../placement/target-scene-voxel-projection.md`：说明源 TargetSV 与 brush-composited TargetSV_B 的边界，以及 projection cache 的后续方向。

## 验收标准

- 每个 asset 能导出稳定且数量可控的 `semantic_probes`。
- Probe scoring 只处理已通过上游筛选的候选资产。
- TargetSV / TargetSV_B 不包含 asset 类型标签。
- TargetSV_B 越界采样使用 clamp，不把边界外直接当作空白。
- 最终物理可行性仍由 `score_voxel_tile.glsl` 和 placement pipeline 判定。
