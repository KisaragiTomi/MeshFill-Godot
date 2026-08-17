# MeshFill-Godot：体素引导的程序化内容生成框架（未完成）

## 项目简介

MeshFill-Godot 是一套运行在 Godot 4.x 上的 GPU 加速程序化内容生成（PCG）框架。它以**三维体素画布**作为统一的场景描述媒介，将"目标效果"与"生成逻辑"完全解耦，使 PCG 流程适配 AI 训练与自动化场景生成。

## 核心理念：目标画布与生成的解耦

传统 PCG 系统中，"我想要什么效果"的决策和"如何放置"的执行是紧耦合的————————规则引擎既决定目标也执行放置。
这意味着执行生成的人，必须要对放置逻辑有一定的了解。
但对于工具使用者而言，他们只想关心，区域会有什么样的美术效果，放置结果对玩法有什么影响。
为了实现这样的目标设计了本架构。

MeshFill 采用截然不同的设计：

```text
TargetSceneVoxel（目标画布）            Placement Pipeline（生成管线）
┌─────────────────────────┐           ┌──────────────────────────┐
│ "我希望这里看起来是：      │           │ 读取目标画布               │
│  complexity=0.8          │           │ → 语义探针匹配候选资产      │
│  color=brown             │           │ → 物理可行性评分            │
│  collision=密集"          │  ═══>    │ → 放置实例并写回 SceneVoxel  │
│                          │           │ → 反馈评分对比目标          │
│ 不指定具体资产类型         │           │                           │
└─────────────────────────┘           └──────────────────────────┘
```

- **`TargetSceneVoxel`（目标体素画布）**：一个三维体素空间，每个体素携带 `complexity`（强度）、`color`（颜色）和 `collision`（碰撞）信息。它只描述"最终场景应该长什么样"，**不携带任何资产类别标签**（不写"这里放岩石A"或"这里放树B"）。
- **生成管线**：读取目标画布，通过 GPU 上的语义探针匹配、候选路由、物理可行性评分，选择最合适的资产放置到场景中。生成逻辑**只做拟合**——它的任务是让生成的 `SceneVoxel` 尽可能接近 `TargetSceneVoxel`。
- **反馈闭环**：每轮放置完成后，系统对比已提交的 `SceneVoxel[tick]` 与 `TargetSV_B`，计算反馈评分，指导下一轮生成。

### 为什么这样设计？

1. **统一的场景描述语言**：`TargetSceneVoxel` 为所有 PCG 任务提供了一种中性的、与资产无关的场景表示。无论是手工笔刷、程序化规则、还是 AI 模型输出，都可以写入同一个目标画布。
2. **适配 AI 训练**：AI 模型只需要学习预测"目标场景的体素分布"（即 TargetSV），而不需要学习"具体选择哪个资产"。资产选择、物理验证、碰撞检测等工程细节全部由生成管线处理。这大幅降低了 AI 的训练难度。
3. **生成策略可替换**：目标画布不变的情况下，可以替换内部的生成算法、资产库、评分策略，而不影响目标定义。这使得系统可以独立迭代"目标预测"和"生成执行"两个方向。

## 系统架构

### 核心模块

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| **SPA**（ScenePlacementActor） | `scripts/scene_placement_actor.gd` | 场景侧 facade / 唯一生命周期与 RD 所有者：导出生产门限、发布 Anchor / Fine 常驻交接、驱动 `run_anchors` / `run_score` / `run_place` |
| **ScenePlacementRuntime** | `scripts/scene_placement_runtime.gd` | 编排主体：资产注册、GPU buffer 生命周期、prefilter→placement→commit 三阶段流水线 |
| **SPASelectionHost** | `scripts/spa_selection_host.gd` | 点选路由、选中状态与反馈可视化宿主；独占持有 `PickIdPass`（生产路径唯一的点选后端） |
| **PickIdPass** | `scripts/utils/pick_id_pass.gd` | 「可视化即拾取几何」的 ID 拾取渲染半边（`shaders/pick_id.gdshader`）：把正在显示的 `MultiMesh` 镜像进 `own_world_3d` 的 SubViewport 再画一遍，片元写 24 位 `pick_id`，回读点击处一个像素。ID 不跨趟存活，每趟 `begin_pass()` 重分配 |
| **PickableDomain** | `scripts/pickable_domain.gd` | SPA 下所有可点选元素的共同基类：归属、域标识、内容 revision、显示节点、`register_pick_drawable()` 登记与 `resolve_pick()` 载荷解码。可见性即点选准入（画不出像素就没有 `pick_id`） |
| **VolumeScoreFineSelection** | `scripts/volume_score_fine_selection.gd` | Score 步的结果模型装配与 golden 快照格式化 |
| **TargetSV** | `scripts/target_scene_voxel_generator.gd` | 目标体素画布，GPU 生成/持久化/解码，对外提供 `target_completeness`/`target_collision` + `target_color` |
| **AssetDescriptor** | `scripts/asset_descriptor.gd` | 资产语义描述符，持久化 canonical `profile_samples`、pivot 与默认 color/complexity/collision；旧资源字段只在读取边界归一化 |
| **Probe Prefilter** | `scripts/autoobject_probe_prefilter_gpu.gd` | GPU 语义探针粗筛，从 TargetSV 和 SV[t-1] 中提取 anchor，匹配候选资产 |
| **VoxelPlacementGenerator** | `scripts/voxel_placement_generator.gd` | GPU Fine Score、Reduce 与 Stamp：从固定槽位 `profile_arena` 单 binding 读取本 slot 的 32 B `ProfileSample` fine range，共用 pivot/yaw/round/边界规则 |
| **ProfileArenaLayout** | `scripts/utils/profile_arena_layout.gd` | 固定槽位 Profile Arena 的布局单一真值源：容量常量 + `align16` 推导的各区偏移、`verify_layout()` 自检、`budget_report()` 浪费量报告、GLSL 常量与访问器发射 |
| **BakedAssetLoader** | `scripts/baked_asset_loader.gd` | Bake 产物的发现与校验单一入口：只扫 `BAKED_DESCRIPTOR_DIR`、按 `asset_id → 路径 → UID` 稳定排序、超限/重复/损坏一律明确失败 |
| **SceneVoxelCommitter** | `scripts/scene_voxel_committer.gd` | 体素提交与合成，管理 SceneVoxel 常驻显存状态（stamp-only 提交），tile/field 工具/debug 子系统拆分见 `scene_voxel_tile_store.gd` / `scene_voxel_field_builder.gd` / `scene_voxel_debug.gd` |
| **SceneVoxelTile** | `scripts/scene_voxel_tile_store.gd` | GPU 常驻粗粒度体素瓦片（默认 8×8×8、项目配置可覆盖），dirty worklist、summary 与对象引用索引 |
| **GPUAutoObjectRuntime** | `scripts/gpu_autoobject_runtime.gd` | GPU 端百万级运行时对象池，管理 object id/transform/profile |

### 数据流

```text
TargetSV（目标画布） + BrushSV（笔刷覆盖）
      │
      ▼
  TargetSV_B（合成目标）
      │
      ├──────────────────────────────────┐
      ▼                                  ▼
  Probe Prefilter                  SceneVoxel[t-1]
  （coarse sample 离散粗筛）       （上一轮已提交场景状态）
      │                                  │
      ▼                                  ▼
  Anchor Candidate Handoff        Placement Scoring
  （anchor/count/top-K 常驻）←────  （Fine residual + 物理约束）
      │
      ▼
  Voxel Placement Generator
  （多资产放置生成）
      │
      ▼
  Accepted Placements → AutoSceneVoxel[tick]
      │
      ▼
  commit_scene_voxels() → SceneVoxel[tick]（stamp-only 提交）
      │
      ▼
  Feedback Score（对比 TargetSV_B）
```

### 三阶段流水线

1. **Prefilter（粗筛）**：从 `SV[t-1]` 和 `TargetSV_B` 中提取 position-only anchors，用 descriptor 的 coarse `ProfileSample` 对每个 anchor 做离散单格评分，选出 top-K 资产并发布 GPU 常驻 `anchor_candidate_handoff`。
2. **Placement（精筛）**：对每个 anchor × top-K asset × pivot × yaw 执行 residual-gain Fine Score；Fine 与 Stamp 从同一个 sample RID 的 `fine_sample_range` 读取，并共用离散地址解析、字段解码和 compose 规则。
3. **Commit（提交）**：本轮 stamp 的 `AutoSceneVoxel` 字段状态即 committed `SceneVoxel[tick]`（stamp-only 提交；`BrushSceneVoxel` 只是 SPA 常驻 overlay，不进入提交），发布为下一轮的稳定读取输入 `SV[t]`。最后对比 `SceneVoxel[tick]` 与 `TargetSV_B` 计算反馈评分。

## GPU 优先架构

项目的核心路径由 GLSL compute shader 在 Vulkan `RenderingDevice` 上执行：

- **目标生成**：`target_scene_voxel.glsl` 生成 TargetSV visual/collision buffers
- **统一样本粗筛**：`score_anchor_asset_probes.glsl` 按 `(slot_index, 槽内局部下标)` 从 Arena 读取一个离散 voxel，不再做八邻域三线性采样
- **细粒度放置评分**：`score_anchor_asset_residual.glsl` 从固定槽位 `profile_arena` 单 binding 读本 slot 的 fine range 计算 residual gain；`stamp_asset_voxels.glsl` 仅写带 `SAMPLE_FLAG_STAMP_WRITE` 的样本
- **固定槽位 Profile Arena**：Header/Samples/Pivots 同住一个定长 slot（Mesh 区保留占位不写：mesh 是每资产的），一个 RID / 一个 Binding / 一个单调 Revision；地址按 `profile_index`（稠密）直接算出，容量守卫是编译期常量。布局权威见 `ProfileArenaLayout`
- **Stamp-only 提交**：committed `SceneVoxel` 纯 auto，stamp 即提交（`stamp_asset_voxels.glsl` / `scatter_sv_field_records.glsl`）；`BrushSV` 常驻挂 SPA，`BlendSV` = SV + BrushSV 按需合成（`compose_blend_sv_fields.glsl`），供 3D score 与 TargetSV 对比，用完即删
- **Anchor 采集与选择**：`collect_sv_anchors.glsl`（在地形高度采样目标体积，采到即发锚；`anchor_vertical_stride` 决定地表之上再叠几层）→ `select_anchor_topk.glsl`（每 anchor `TOPK = 4`）→ `select_anchor_winners.glsl`（Score-only 分支的 per-anchor 胜者）
- **Reduce 三阶段**：`init_anchor_atomic_reduce.glsl` → `invalidate_anchor_conflicts.glsl` → `compact_anchor_atomic_reduce.glsl`
- **点选**：生产路径只有 ID 拾取——各域经 `PickableDomain.register_pick_drawable()` 登记显示用的 `MultiMeshInstance3D`，`PickIdPass` 镜像它们到独立 World3D 的 SubViewport 用 `pick_id.gdshader` 重画一遍，回读点击像素得 `pick_id`，再按分配区间反查域与实例下标（`resolve_pick()`）。旧的 GPU 射线求交路径（`pick_scene_voxel.glsl` / `pick_unified.glsl`）已于 2026-08-10 删除
- **瓦片管理**：`scene_voxel_tile_object_ref_update.glsl` dirty 追踪与 tile 级固定槽位（每 tile 8 槽）对象引用更新，配合 `init_scene_voxel_tile_summaries.glsl` / `reduce_scene_voxel_tile_summaries.glsl` / `compact_scene_voxel_tile_summaries.glsl`

### 调度基础设施（compute-pass toolkit）

上述 shader 的派发不再手写 `rd.compute_list_bind_* / set_push_constant / add_barrier` 样板，而是通过 `scripts/utils/` 下三个可复用模块编排（各 dispatch 站点正逐步迁移至此）：

- **`PushConstantLayout`**：std430 push-constant 声明式打包器，用有序字段 schema 构造一次、偏移按对齐规则算好并缓存，消除手写 `encode_s32(offset, …)` 与「字节偏移和 GLSL block 静默错位」类 bug。
- **`ComputeKernel`**：单个 compute shader 的封装，shader + pipeline 只编译一次、push-constant 布局声明一次，每次 dispatch 只传数据并产出 pass 描述符。
- **`ComputePassChain`**：把一串 pass 在单条 compute list 里顺序调度，段间自动补 barrier、收尾统一 submit，根除「忘插 barrier → 静默数据竞争」这一脆弱点。

运行要求：Godot 4.x + Vulkan 渲染驱动（`--rendering-driver vulkan`），不使用 `--headless`。

## 为什么适合 AI 训练

1. **单一监督信号**：AI 只需预测 `TargetSceneVoxel`（一个 3D 体素网格的 complexity + color + collision + 风格特征向量），不需要学习离散的资产选择或物理约束。
2. **可微分的目标函数**：反馈评分（`score_blendsv_feedback_against_target`）比较生成结果与目标画布的差异，可直接作为 AI 的 loss/reward。
3. **闭环迭代**：TargetSV → 生成 → SceneVoxel → 反馈评分 → 更新 TargetSV/策略，形成完整的 RL 训练循环。
4. **资产无关**：AI 不关心资产库中有什么，只需描述场景的视觉和结构意图。资产库可以独立扩充而不需要重新训练模型。
5. **统一的场景表示**：无论是手工设计、程序化规则、还是神经网络输出，都汇入同一个体素画布格式，便于构建大规模训练数据集。

## 文档导航

- [`doc/README.md`](doc/README.md) — 完整文档索引、命名规则与术语表
- [`doc/scene-voxel-field-system.md`](doc/scene-voxel-field-system.md) — SceneVoxel 字段契约与 source/commit 边界
- [`doc/asset-descriptor.md`](doc/asset-descriptor.md) — AssetDescriptor 资产语义定义
- [`doc/scene-placement-actor.md`](doc/scene-placement-actor.md) — SPA 运行时编排器契约
- [`doc/auto-object-gpu-runtime-architecture.md`](doc/auto-object-gpu-runtime-architecture.md) — GPU 端百万级运行时架构
- [`doc/target-scene-voxel-projection.md`](doc/target-scene-voxel-projection.md) — TargetSV 目标画布边界
- [`doc/auto-object-probe-prefilter.md`](doc/auto-object-probe-prefilter.md) — 语义探针粗筛流程
- [`demos/placement-voxel-semantic-routing/voxel-semantic-routing.svg`](demos/placement-voxel-semantic-routing/voxel-semantic-routing.svg) — 候选资产路由契约图

## 技术栈

- **引擎**：Godot 4.x（RenderingDevice + Vulkan）
- **计算**：40 个 GLSL compute shader（`shaders/*.glsl`）
- **调度**：compute-pass toolkit（`PushConstantLayout` / `ComputeKernel` / `ComputePassChain`）统一 GPU 派发与 barrier 编排
- **语言**：GDScript（编排层） + GLSL（GPU 计算层）
- **数据**：体素存储缓冲区（storage buffer）、3D 纹理、SceneVoxelTile 稀疏瓦片管理
