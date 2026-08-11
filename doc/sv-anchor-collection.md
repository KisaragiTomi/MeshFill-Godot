# SV Anchor 采集

`shaders/collect_sv_anchors.glsl` 的「位置型 anchor」判定契约。上游是真实生产链（TargetSV 烘焙数据 + committer 支撑的 SceneVoxel + 常驻 target 读缓冲 + baked `AssetDescriptor` 资产），在其上跑真实 GPU prefilter（`ScenePlacementActor.run_autoobject_prefilter` → `AutoObjectProbePrefilterGPU.run_probe_prefilter`）产出 `anchors`。

- 相关文档：[`auto-object-gpu-runtime-architecture.md`](auto-object-gpu-runtime-architecture.md)

## anchor 判定

anchor 是一组「只有位置、没有类型」的候选放置点，GPU 记录里不存 `anchor_kind`。判定是**两门合取**——不是单一 inside-target 门：

| 规则 | 条件 | 阈值（默认） |
| --- | --- | --- |
| 在目标体积内 | `max(target_complexity[p], target_collision[p]) > min_target_interest` | 0.01 |
| 是该列最底的 in-target 体素 | 同一 `(x, z)` 列中其下方（`-y`）不存在 in-target 体素 | — |

第二门的后果：**每个 `(x, z)` 列至多产出一个 anchor**（最低的那个合格体素），anchor 之间不会在垂直方向堆叠；竖直间隙 / 悬垂只保留该列最底的 in-target 体素。「下方」指 `-y`（网格 up 轴为 `+y`）。证据见 `shaders/collect_sv_anchors.glsl` 顶部的 gate 注释与 `in_target()` / 列扫描实现。

旧的场景复杂度 / 碰撞 / 脚下支撑三门已从 anchor 采集中移除，归评分阶段所有——评分阶段已惩罚碰撞/重叠并强制间距，在此重测是冗余。

## 上游数据链（全真实，无脚手架）

| 阶段 | 生产入口 | 下游消费 |
| --- | --- | --- |
| S1 TargetSV | `TargetSVSetup` 节点 | `get_display_snapshot()` 出网格几何/地形高度；`decode_gpu()` 的 `target_visual_rgba8_bytes`（packed rgba8，每体素 1 个 u32：rgb + 低字节 completeness）直接作目标场，无 CPU 重打包 |
| S0+S3+S4 底座 | 场景常驻 SPA；`PlacementStageEnv.make(existing_spa, options)` 只借用 | SPA 播种 terrain collision、注册 baked `.tres` 并按 TargetSV 网格配置 committer；adapter 不重新配置或持有这些资源 |
| S5+S6 采集 | `PlacementStageEnv.ensure_prefilter` | 内部串 `ensure_sv_committed`（真实 SV + 常驻 complexity/collision 场 RID 注入）→ `prepare_target_read_buffers_from_common_gpu`（常驻 vec4 field + unorm8_u32 collision 双缓冲）→ `run_autoobject_prefilter` |

资产是 baked `AssetDescriptor` `.tres`（`res://scenes/asset-overview/baked_descriptors/*.tres`），经场景 typed `@export var placement_assets: Array[AssetDescriptor]` 注入（编辑器 placeholder 坑：不做运行期 `load()` 扫描）。`placement_assets` 为空 → `push_warning` 且不采集，绝不回退合成资产。

```text
TargetSVSetup (S1)                 ScenePlacementActor (S0+S3+S4)
  snapshot/decode_gpu                terrain seed + baked .tres + committer
        │                                   │
        ▼                                   ▼
  目标场 (CPU 侧解码)             ensure_prefilter (S5 常驻 target 双缓冲 + S6)
                                            │
                                            ▼
                        collect_sv_anchors.glsl → result["anchors"] = [{ id, voxel_pos }]
```

anchor top-K 是固定 GPU 契约（`select_anchor_topk.glsl` 的 `TOPK = 4u`），常驻 GPU 不读回。

## 验收标准

- anchor 是位置型记录，不携带 `anchor_kind`；语义由体素位置承载。
- 一个候选体素成为 anchor 当且仅当**两门同时成立**：它在目标体积内（`max(target_complexity, target_collision) > min_target_interest`），且它是所在 `(x, z)` 列中最底的 in-target 体素。
- 上游全部走真实链：S1 TargetSV 烘焙数据、S4 committer 支撑的 SV（地形碰撞种子已种入）、S5 生产 target 读缓冲、baked `.tres` 资产；无手工 storage buffer handoff、无合成场/合成资产。
- anchor 采集运行在 GPU storage buffers 与 readback 路径上；缺少 `RenderingDevice` 时显式跳过，不得以 CPU 路径冒充通过。
- 体素可视化统一经由 `VoxelDisplay` / `TargetSVSetup`，不手搓 `MultiMesh` / `BoxMesh`。
