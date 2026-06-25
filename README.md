# MeshFill-Godot：体素引导的程序化内容生成框架（未完成）

## 项目简介

MeshFill-Godot 是一套运行在 Godot 4.x 上的 GPU 加速程序化内容生成（PCG）框架。它以**三维体素画布**作为统一的场景描述媒介，将"目标效果"与"生成逻辑"完全解耦，使 PCG 流程适配 AI 训练与自动化场景生成。

## 核心理念：目标画布与生成的解耦

传统 PCG 系统中，"我想要什么效果"的决策和"如何放置"的执行是紧耦合的————————规则引擎既决定目标也执行放置。
这意味着执行生成的人，必须要对放置逻辑有一定的了解。
但对于工具使用者而言，他们只想关心，区域会有什么样的美术效果，放置结果对玩法有什么影响。
为了实现这样的目标设计了本架构。

MeshFill 采用截然不同的设计：

```
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
| **SPA**（ScenePlacementActor） | `scripts/scene_placement_actor.gd` | 运行时统一编排器，管理资产注册、GPU buffer 生命周期、prefilter→placement→commit 三阶段流水线 |
| **TargetSV** | `scripts/target_scene_voxel_generator.gd` | 目标体素画布，GPU 生成/持久化/解码，对外提供 `target_occupancy` + `target_color` |
| **AssetDescriptor** | `scripts/auto_voxel_descriptor.gd` | 资产语义描述符，定义每个可放置物体的默认 color/complexity/collision/探针 |
| **Probe Prefilter** | `scripts/autoobject_probe_prefilter_gpu.gd` | GPU 语义探针粗筛，从 TargetSV 和 SV[t-1] 中提取 anchor，匹配候选资产 |
| **VoxelPlacementGenerator** | `scripts/voxel_placement_generator.gd` | GPU 物理评分与放置，footprint/support/collision/clearance 精筛 |
| **SceneVoxelCommitter** | `scripts/scene_voxel_committer.gd` | 体素提交与合成，管理 SceneVoxel 常驻显存状态和源体素 blend |
| **SceneVoxelTile** | 内嵌于 committer | 粗粒度体素瓦片（4×4×4），dirty 追踪、局部重建、对象引用索引 |
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
  （语义探针粗筛）                 （上一轮已提交场景状态）
      │                                  │
      ▼                                  ▼
  Candidate Voxel Regions         Physical Scoring
  （候选体素区域）          ←────  （物理可行性评分）
      │
      ▼
  Voxel Placement Generator
  （多资产放置生成）
      │
      ▼
  Accepted Placements → AutoSceneVoxel[tick]
      │
      ▼
  blend_scene_voxels() → SceneVoxel[tick]
      │
      ▼
  Feedback Score（对比 TargetSV_B）
```

### 三阶段流水线

1. **Prefilter（粗筛）**：从 `SV[t-1]` 和 `TargetSV_B` 中提取 position-only anchors，用 descriptor 的语义探针对每个 anchor 打分，选出 top-K 候选资产，扩张为候选体素区域。
2. **Placement（精筛）**：对每个资产的候选区域，执行 GPU 物理评分（footprint 覆盖、support 支撑、collision 碰撞、clearance 间距、overlap 重叠、target fit 目标匹配），通过后 stamp 放置。
3. **Commit（提交）**：将本轮的 `AutoSceneVoxel` 与 `BrushSceneVoxel` 合成为 committed `SceneVoxel[tick]`，发布为下一轮的稳定读取输入 `SV[t]`。最后对比 `SceneVoxel[tick]` 与 `TargetSV_B` 计算反馈评分。

## GPU 优先架构

项目包含 87 个 GLSL compute shader，核心路径全部 GPU 化：

- **目标生成**：`target_scene_voxel.glsl` 生成 TargetSV visual/collision buffers
- **探针评分**：`score_anchor_asset_probes.glsl` 对标 anchor 和资产探针
- **物理放置**：`score_voxel_tile.glsl` footprint/support/collision/clearance 精筛
- **源体素合成**（**SceneVoxel Source Fusion / SVSF**）：`AutoSV` + `BrushSV` + `LandscapeSV` → `BlendSV`，由 `resolve_scene_voxel_sources.glsl` 和 `blend_scene_voxel_fields.glsl` 完成
- **瓦片管理**：`scene_voxel_tile_object_ref_update.glsl` dirty 追踪与对象引用更新

运行要求：Godot 4.x + Vulkan 渲染驱动（`--rendering-driver vulkan`），不使用 `--headless`。

## 为什么适合 AI 训练

1. **单一监督信号**：AI 只需预测 `TargetSceneVoxel`（一个 3D 体素网格的 complexity + color + collision + 风格特征向量），不需要学习离散的资产选择或物理约束。
2. **可微分的目标函数**：反馈评分（`score_blendsv_feedback_against_target`）比较生成结果与目标画布的差异，可直接作为 AI 的 loss/reward。
3. **闭环迭代**：TargetSV → 生成 → SceneVoxel → 反馈评分 → 更新 TargetSV/策略，形成完整的 RL 训练循环。
4. **资产无关**：AI 不关心资产库中有什么，只需描述场景的视觉和结构意图。资产库可以独立扩充而不需要重新训练模型。
5. **统一的场景表示**：无论是手工设计、程序化规则、还是神经网络输出，都汇入同一个体素画布格式，便于构建大规模训练数据集。

## 文档导航

- [`demos/core-meshfill-framework/meshfill-framework.md`](demos/core-meshfill-framework/meshfill-framework.md) — 框架总览，模块归属与运行时流程
- [`demos/core-scene-voxel-field-system/scene-voxel-field-system.md`](demos/core-scene-voxel-field-system/scene-voxel-field-system.md) — SceneVoxel 字段契约与 source/commit 边界
- [`demos/asset-descriptor-demo/asset-descriptor.md`](demos/asset-descriptor-demo/asset-descriptor.md) — AssetDescriptor 资产语义定义
- [`demos/core-SPA-scene-placement-actor/scene-placement-actor.md`](demos/core-SPA-scene-placement-actor/scene-placement-actor.md) — SPA 运行时编排器契约
- [`demos/core-SPA-scene-placement-actor/autoobject-gpu-runtime-architecture.md`](demos/core-SPA-scene-placement-actor/autoobject-gpu-runtime-architecture.md) — GPU 端百万级运行时架构
- [`demos/target-sv-point-cloud-conversion-c/target-scene-voxel-projection.md`](demos/target-sv-point-cloud-conversion-c/target-scene-voxel-projection.md) — TargetSV 目标画布边界
- [`demos/placement-autoobject-probe-prefilter/autoobject-probe-prefilter.md`](demos/placement-autoobject-probe-prefilter/autoobject-probe-prefilter.md) — 语义探针粗筛流程
- [`demos/placement-voxel-semantic-routing/voxel-semantic-routing.md`](demos/placement-voxel-semantic-routing/voxel-semantic-routing.md) — 候选资产路由契约

## 技术栈

- **引擎**：Godot 4.x（RenderingDevice + Vulkan）
- **计算**：87 个 GLSL compute shader
- **语言**：GDScript（编排层） + GLSL（GPU 计算层）
- **数据**：体素存储缓冲区（storage buffer）、3D 纹理、SceneVoxelTile 稀疏瓦片管理
