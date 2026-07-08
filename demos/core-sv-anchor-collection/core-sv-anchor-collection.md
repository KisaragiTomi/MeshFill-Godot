# SV Anchor 采集演示场景

可视化 `shaders/collect_sv_anchors.glsl` 的「位置型 anchor」判定规则。在一个完全受控的 SV 场上跑真实的 GPU prefilter 管线（`AutoObjectProbePrefilterGPU.run_probe_prefilter`），读回 `anchors` 并与四条判定规则逐一对照。

- 源文档：`res://demos/core-SPA-scene-placement-actor/autoobject-gpu-runtime-architecture.md`
- 场景：`res://demos/core-sv-anchor-collection/core-sv-anchor-collection.tscn`
- 脚本：`res://demos/core-sv-anchor-collection/sv_anchor_collection_demo.gd`（继承 `core_demo_contract_fixture.gd`）

## 运行方式

> **@tool 编辑器模式，禁止 F6。**
>
> 在 Godot 编辑器中双击打开 `.tscn` 场景文件即可。脚本在编辑器视口中实时运行，anchor 选择、图层切换和阈值调整均在视口内操作。
> F6（Run Current Scene）和 F5（Run Project）被 `core_demo_contract_fixture.gd` 守卫代码禁止。

## anchor 是什么

anchor 是一组「只有位置、没有类型」的候选放置点。anchor 的语义完全由它所在的体素位置承载，GPU 记录里不存 `anchor_kind`。一个候选体素要成为 anchor，必须同时满足四条规则（缺一即被淘汰）：

| 规则 | 条件 | 阈值（默认） |
| --- | --- | --- |
| 自身复杂度够空 | `complexity_field[p] <= max_complexity_field` | 0.15 |
| 自身未被占据 | `collision_field[p] <= max_collision_field` | 0.05 |
| 此处被需要 | `target_field[p].a >= min_target_interest` | 0.01 |
| 脚下有支撑 | `max(complexity, collision)` of `p+(0,-1,0)` `>= min_support` | 0.25 |

## 受控场布局

网格 `16×8×16`，候选切片在 `y=1`，支撑切片在 `y=0`。把切片按象限分成四块 `8×8`，每个象限的候选体素只触发一条规则的失败，用于隔离验证：

| 象限 | 候选体素 | 设计意图 | 预期 |
| --- | --- | --- | --- |
| A | `(4,1,4)` | 四条规则全过 | 命中 anchor |
| B | `(12,1,4)` | 脚下支撑为 0 | 被淘汰（无支撑） |
| C | `(4,1,12)` | 自身 collision 超阈值 | 被淘汰（被占据） |
| D | `(12,1,12)` | target 需求为 0 | 被淘汰（无需求） |

候选位置取自每个象限中心：象限 0 跨 `[0,8)`、象限 1 跨 `[8,16)`，中心偏移落在 4 与 12。

## 数据流向

```text
complexity_field / collision_field / target_field / dirty_tiles
        │  (打包进 GPU storage buffers)
        ▼
collect_sv_anchors.glsl  ── 每个逻辑工作组 = 一个脏块 (8³=512 线程)
        │  命中体素 atomicAdd 进 AnchorOut[]
        ▼
run_probe_prefilter() 读回 → result["anchors"] = [{ id, voxel_pos }]
```

anchor 采集是整条 prefilter 管线的第一步。后续 score / top-k / reduce 与本演示无关，因此用一个最小的占位资产（单个 collision 探针）满足管线入参要求，焦点始终落在 anchor 命中集合上。

## 对照图层

全部体素显示统一走 `VoxelDisplay`（`build_colored`），通过快捷键切换四个图层，把每条规则单独画出来：

| 键 | 图层 | 含义 |
| --- | --- | --- |
| `1` | support | `y=0` 支撑层，绿色=过 `min_support`，橙色=不足 |
| `2` | demand | 候选层按 `target.a` 着色，紫色=有需求，灰色=无需求 |
| `3` | candidate | 候选层按自身复杂度/碰撞门控着色，绿色=可放，红色=被占据 |
| `4` | anchor | GPU 实际读回的命中=绿色，预期落选=红色 |

调阈值实时重跑：`[` / `]` 调 `min_support`，`-` / `=` 调 `min_target_interest`，`R` 重新采集。HUD 显示当前 GPU 状态、采集到的 anchor 数与 `reason`。

## 验证步骤

1. 用 Vulkan 驱动打开场景，确认 HUD 显示 `GPU: ready` 且 `anchors collected = 1`。
2. 按 `4` 查看 anchor 图层：只有象限 A 是绿色，B / C / D 均为红色。
3. 按 `1` / `2` / `3` 逐层核对：support 层 B 为橙色、candidate 层 C 为红色、demand 层 D 为灰色，与各自的淘汰原因一致。
4. 按 `[` 把 `min_support` 降到 0，按 `R` 重跑，确认 B 象限转为命中（anchors 增加）。
5. 按 `=` 提高 `min_target_interest` 越过候选需求，按 `R` 重跑，确认命中减少。

## 契约测试

GPU 路径依赖 `RenderingDevice` / Vulkan / storage buffers / readback，必须用 Vulkan 驱动运行，禁止 `--headless`：

```bash
godot --path . --rendering-driver vulkan --script tools/test_core_demo_contracts.gd
godot --path . --rendering-driver vulkan --script tools/test_autoobject_probe_prefilter.gd
```

缺少 `RenderingDevice` 时，anchor 采集必须显式 skip 或 fail；不得改走 CPU 替代路径并报告通过。

## 验收标准

- anchor 是位置型记录，不携带 `anchor_kind`；语义由体素位置承载。
- 一个候选体素成为 anchor 当且仅当：自身复杂度 `<= max_complexity_field`、自身碰撞 `<= max_collision_field`、`target.a >= min_target_interest`，且正下方体素 support `>= min_support`，四条规则同时成立。
- 受控场四象限各自隔离一条规则，GPU 读回结果只有象限 A 命中。
- anchor 采集运行在 GPU storage buffers 与 readback 路径上；缺少 `RenderingDevice` 时显式跳过，不得以 CPU 路径冒充通过。
- 所有体素可视化统一经由 `VoxelDisplay`，不在本场景内手搓 `MultiMesh` / `BoxMesh`。