# SV Anchor 采集

`shaders/collect_sv_anchors.glsl` 的「位置型 anchor」判定契约。上游是真实生产链（TargetSV 烘焙数据 + committer 支撑的 SceneVoxel + 常驻 target 读缓冲 + baked `AssetDescriptor` 资产），在其上跑真实 GPU prefilter（`ScenePlacementActor.run_autoobject_prefilter` → `AutoObjectProbePrefilterGPU.run_probe_prefilter`）产出 `anchors`。

- 相关文档：[`auto-object-gpu-runtime-architecture.md`](auto-object-gpu-runtime-architecture.md)

## anchor 判定

anchor 是一组「只有位置、没有类型」的候选放置点，GPU 记录里不存 `anchor_kind`。判定是**两门合取**——不是单一 inside-target 门：

判定的一句话版本：**在地形高度采样目标体积，采到就发锚。**

| 规则 | 条件 | 阈值（默认） |
| --- | --- | --- |
| 采样高度在地形切片或其之上 | `p.y - terrain_slice >= 0`，且 `anchor_vertical_stride <= 0` 时要求恰好 `== 0`，否则 `(p.y - terrain_slice) % anchor_vertical_stride == 0` | `anchor_vertical_stride` = 0 |
| 该处能采到目标体积 | `max(target_complexity[p], target_collision[p]) > min_target_interest` | 0.01 |

`terrain_slice` = 地形高度在网格里对应的切片。网格的 Y 是**地形相对**的（`world.y = terrain_height * height_scale + grid_origin.y + (slice + 0.5) * voxel_size.y`），地形起伏已经烘进这套竖直框架，所以「地表」是一个**与 `(x, z)` 无关的常数切片**：`floor(-grid_origin.y / voxel_size.y)`。当前生产配置 `grid_origin.y = -36`、`voxel_size.y = 3` ⇒ 切片 `12`（世界区间恰为地表上方 `[0, 3)`）。**本 pass 因此不需要地形高度场，也不做逐列扫描**——判定完全是逐体素的局部运算。

第一门顺带决定竖直方向的锚点密度（步长单位 = 体素层，**越小越密**）：`0`（默认）= 只采地形那一格，每列至多一个锚且一定站在地面上；`1` = 地表及以上每个 in-target 体素都出锚；`n > 1` = 地形切片 + 其上每 `n` 层一格。

**地形以下永不发锚。** 目标体积经常伸到地形以下（当前靶数据地形下一格就有 27,063 个 in-target 格，更深处还有数千），旧的「该列最底 in-target 体素」判定会把锚点锚到那些格子上、埋进地里；改按地形切片相位后不再发生。

当前靶数据（`256×24×256`，in-target 体素 147,426、非空列 45,793）实测：步长 `0` → 45,552 锚点（= 99.5% 的非空列），`1` → 113,624，`2` → 70,028，`4` → 49,875。锚点上限由 `ANCHOR_CAPACITY = 131072` 罩住（旧值 `65536` 是「每列至多一个」时代的列数上限，步长调到 1 就会顶破）。证据见 `shaders/collect_sv_anchors.glsl` 顶部的 gate 注释与 `in_target()` 实现。

旧的场景复杂度 / 碰撞 / 脚下支撑三门已从 anchor 采集中移除，归评分阶段所有——评分阶段已惩罚碰撞/重叠并强制间距，在此重测是冗余。

## 上游数据链（全真实，无脚手架）

| 阶段 | 生产入口 | 下游消费 |
| --- | --- | --- |
| S1 TargetSV | `TargetSVSetup` 节点 | `get_base_grid_frame()` / `get_grid_frame()` 出网格几何，`voxel_to_world()` 出体素→世界换算；`get_visual_bytes()`（packed rgba8，每体素 1 个 u32：rgb + 低字节 completeness）直接作目标场，无 CPU 重打包。`PlacementStageEnv.target_common_bytes()` 把它与 `get_collision_bytes()` 打成 `target_visual_rgba8_bytes` / `target_collision_r8_bytes` 键对（后者是历史键名，内容已是 unorm8-in-u32） |
| S0+S3+S4 底座 | 场景常驻 SPA；`PlacementStageEnv.make(existing_spa, options)` 只借用 | SPA 播种 terrain collision、注册 baked `.tres` 并按 TargetSV 网格配置 committer；adapter 不重新配置或持有这些资源 |
| S5+S6 采集 | `PlacementStageEnv.ensure_prefilter` | 内部串 `ensure_sv_committed`（真实 SV + 常驻 complexity/collision 场 RID 注入）→ `prepare_target_read_buffers_from_common_gpu`（常驻 vec4 field + unorm8_u32 collision 双缓冲）→ `run_autoobject_prefilter` |

资产是 baked `AssetDescriptor` `.tres`（`res://scenes/asset-overview/baked_descriptors/*.tres`），由 SPA 的 `load_baked_assets()` 统一扫入 registry（init 自动跑一次，Inspector 的 `Reload` 手动强制重扫），消费方走 `get_registered_descriptors()`。registry 为空 → `push_warning` 且不采集，绝不回退合成资产。

```text
TargetSVSetup (S1)                 ScenePlacementActor (S0+S3+S4)
  grid_frame/get_visual_bytes        terrain seed + baked .tres + committer
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
- 一个候选体素成为 anchor 当且仅当**两门同时成立**：它落在地形切片或其之上的采样层（相位锁 `terrain_slice`、层距 `anchor_vertical_stride`，步长 `0` 即只有地形切片本身），且该处能采到目标体积（`max(target_complexity, target_collision) > min_target_interest`）。地形以下的 in-target 体素一律不发锚。
- 上游全部走真实链：S1 TargetSV 烘焙数据、S4 committer 支撑的 SV（地形碰撞种子已种入）、S5 生产 target 读缓冲、baked `.tres` 资产；无手工 storage buffer handoff、无合成场/合成资产。
- anchor 采集运行在 GPU storage buffers 与 readback 路径上；缺少 `RenderingDevice` 时显式跳过，不得以 CPU 路径冒充通过。
- 体素可视化统一经由 `VoxelDisplay` / `TargetSVSetup`，不手搓 `MultiMesh` / `BoxMesh`。
