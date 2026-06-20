# MeshFill Framework

本文整理当前 MeshFill-Godot 框架的数据归属、生成主线、候选路由和运行时查询边界。本文只保留跨模块总览；`AssetDescriptor` 定义见 [`auto-voxel-descriptor.md`](../asset-descriptor-demo/asset-descriptor.md)，资产字段归属边界见 [`asset-properties.md`](../asset-descriptor-demo/asset-properties.md)；SceneVoxel/source 写入、collision 和 SV 常驻显存规则见 [`scene-voxel-field-system.md`](../core-scene-voxel-field-system/scene-voxel-field-system.md)；TargetSV 设计见 [`target-scene-voxel-projection.md`](../target-sv-point-cloud-conversion-c/target-scene-voxel-projection.md)；候选资产路由见 [`voxel-semantic-routing.md`](../placement-voxel-semantic-routing/voxel-semantic-routing.md)；AutoObject probe 粗筛见 [`autoobject-probe-prefilter.md`](../placement-autoobject-probe-prefilter/autoobject-probe-prefilter.md)。**SPA**（`ScenePlacementActor`）是 MeshFill 的运行时统一编排器，管理 descriptor 注册、GPU buffer 生命周期和 prefilter→placement→commit 三阶段流水线；完整契约见 [`scene-placement-actor.md`](../core-scene-placement-actor/scene-placement-actor.md)。

![MeshFill 当前框架总览](meshfill_current_framework.svg)

## 文档边界

- 本文回答「MeshFill 的模块如何串起来」：目标画布、资产默认值、候选路由、placement、source write、commit、SV resident buffers 和查询的大体关系。SPA（`ScenePlacementActor`）是运行时统一编排器，拥有 descriptor 注册、GPU buffer 生命周期和 prefilter→placement→commit 三阶段流水线；详见 [`scene-placement-actor.md`](../core-scene-placement-actor/scene-placement-actor.md)。
- `SceneVoxel` 字段、`instance_stamp_write_spec` / `ISWS`、source stream、`blend_scene_voxels()`、`collision`、terrain base collision 和 SV 常驻显存细节统一放在 `scene-voxel-field-system.md`。
- `SceneVoxelTile` dirty sidecar、tile 尺寸和局部 object/source range 规则统一放在 [`scenevoxeltile.md`](scenevoxeltile.md)。
- `GPUAutoObjectRuntime` / `AutoVoxelRuntimeProfileContainer` 契约统一放在 [`autoobject-gpu-runtime-architecture.md`](autoobject-gpu-runtime-architecture.md)；本文只说明它们与当前框架的边界。
- 本文只保留这些系统的边界引用，避免和专题文档重复维护同一套规则。

## 核心约束

- `TargetSceneVoxel` / `TargetSV`、`BrushSV` 和合成后的 `TargetSV_B` 是目标效果画布：只提供 prefilter / routing / scoring / target fit / result feedback 的目标信号，不写入 asset 类型标签；源 `TargetSV` 与 `BrushSV` 需要存储，`TargetSV_B` 是默认读取输入。`TargetSceneVoxel` guidance record 只作为 guidance metadata，不进入 committed source 或 `SceneVoxel`。
- [`AssetDescriptor`](../asset-descriptor-demo/asset-descriptor.md) 是「资产是什么」的唯一语义主来源；`AutoObject` 只持有 descriptor 入口、运行时身份、mesh、放置约束和配置入口。
- 运行时 record / `instance_stamp_write_spec`（`ISWS`）只回答「本次实例放在哪里、写什么 payload」；提交后的 `SceneVoxel` 才是后续系统读取的结果，公开 per-voxel payload 统一写作 `complexity`、`color`、`collision` 和可选 `auto_mix`。`channel` 只属于 source/write context，不进入 committed read payload；`complexity` 是唯一强度字段。
- `collision` 是 descriptor、runtime record、source voxel 和 committed `SceneVoxel` 之间的 canonical shared field；placement footprint record/API 也使用同名 `collision`。`occupied`、`type`、`source_type`、`source_voxel_type` 和 `commit_tick` 不作为 committed per-voxel payload。
- probe prefilter 只减少候选 `AutoObject` / voxel regions，不直接写最终 `SceneVoxel`；当前 score / top-K 留在本轮 GPU dispatch 内部，readback 只输出 anchors、candidate voxel regions 和 debug profile，不能作为运行时成功路径替代 GPU resident buffer contract。
- Candidate voxel regions 必须保守扩张，覆盖 asset footprint、probe 插值采样半径、context 半径和插值 guard，宁可让更多 voxel 进入候选，也不要漏掉可能得分高的位置。
- 语义向量匹配只在每个 anchor 的粗筛候选资产内做 rerank / validate / prune，不遍历全资产库。
- `SV[t - 1]` 在 physical sampling 前必须已经是上一轮 `AutoSceneVoxel` / `BrushSceneVoxel` 合成后的 `BlendSV[t - 1]` resident read input；placement 不读取半成品 source stream。
- 物理可放置性仍由 `score_voxel_tile.glsl` 的 footprint、support、collision、clearance、overlap 和候选级 target fit 决定。
- placement 结束后，本 tick `AutoSceneVoxel` 需要再次与 `BrushSceneVoxel` 合成为 `BlendSV[tick]` / committed `SceneVoxel[tick]`；结果级 feedback score 由 `SceneVoxelCommitter.score_blendsv_feedback_against_target()` 比较 `BlendSV[tick]` 与当前 target read buffer（通常是 `TargetSV_B`，没有 target brush 时等价于 `TargetSV`）。
- 同类型 `AutoObject` 的 `min_spacing` 互斥收敛到 GPU object runtime / profile buffer contract；当前最终 footprint / collision 仍由 GPU score 确认。
- `GPUAutoObjectRuntime` 只拥有 runtime object state、profile id、bounds / exclusion inputs 和 dirty object delta；per-voxel object refs、SV grid、`SceneVoxelTile` dirty、source range rebuild、commit 和 SV resident fields 仍由 `SceneVoxelCommitter` / SV owner 维护。
- runtime metadata 只能提供查询、索引、debug 和候选剪枝，不成为资产默认值或 committed SceneVoxel 的第二套权威状态。

体素与计算术语参见顶层 [`README.md`](../README.md#voxel-and-compute-terminology)。`SPA` 即 `ScenePlacementActor`，MeshFill 运行时数据的一站式编排容器，详见 [`scene-placement-actor.md`](../core-scene-placement-actor/scene-placement-actor.md)。

## Ownership

| Layer | Source of truth / owner | Responsibility / output |
| --- | --- | --- |
| SPA (MeshFill orchestrator) | `ScenePlacementActor` | 拥有 `AutoVoxelRuntimeProfileContainer` 完整生命周期；管理 asset registry、GPU buffer 就绪、prefilter→placement→commit 三阶段流水线编排；暴露 `is_gpu_ready()`、`run_placement_pipeline()` 等统一入口。 |
| SV runtime owner | `SceneVoxelCommitter` | 持有 committed `SceneVoxel`、SV resident buffers、`SceneVoxelTile` dirty sidecar 和 debug buffer/readback 边界；placement 时把 `TargetSV_B`、AutoObject registry 与 dirty tile ids 传给 prefilter。通过 SPA 注入引用。 |
| Target canvas | `TargetSceneVoxel` / `BrushSV` / `TargetSV_B` / `TargetSceneVoxelGenerator` | 源 `TargetSV` 保存中性原始目标；`BrushSV` 保存笔刷 delta / override；`TargetSV_B` 是二者合成后的实际采样目标；当前支持 GPU 生成、持久化和 dirty 更新。 |
| Asset defaults | `AssetDescriptor` / `AutoObject.voxel_descriptor` / descriptor-backed assets | descriptor 保存所有资产种类的默认语义；字段定义见 [`auto-voxel-descriptor.md`](../asset-descriptor-demo/asset-descriptor.md)。`AutoObject` 同名字段只作为 Inspector / 配置字典入口，descriptor 通过 SPA.register_asset() 注册并立即上传 GPU。 |
| Probe prefilter | `AssetDescriptor.semantic_probe_profile` / `AutoObjectProbePrefilterGPU` | 从 SV `SV[t - 1]` / `TargetSV_B` 读取可放置 anchor，按 descriptor probes 在 GPU 内部打分和 top-K，并 readback voxel-region votes。SPA 创建 prefilter worker 并注入共享 RD。 |
| Candidate routing | `candidate_voxel_regions_by_asset` / legacy `candidate_voxel_sparses_by_asset` debug view，`candidate_route_profiles` debug | Host readback 后按 footprint、probe offset、context radius 和 interpolation guard 扩张为每个 asset 的 candidate voxel regions；这是 VPG candidate 输入，不是 CPU placement 替代路径。 |
| Physical placement | `VoxelPlacementGenerator` / placement shaders | 只对 routed asset / candidate voxel regions 做 GPU score、reduce、stamp；可在 GPU scoring 前执行同类型 candidate voxel-region 剪枝；如果 asset 没有候选区域，本轮可跳过。SPA 创建 placer worker 并注入共享 RD + profile_container。 |
| Instance stamp write spec | `instance_stamp_write_spec` / `ISWS` builders | 统一创建或更新本次实例 / stamp 写入 record，保存位置、像素、channel、collision、source 和 debug handle。 |
| Source voxel | `AutoSceneVoxel` / `BrushSceneVoxel` | auto 和 brush 的当前 tick 写入意图；source stream 与提交规则见 `scene-voxel-field-system.md`。 |
| Blend / final state | `SceneVoxelCommitter.blend_scene_voxels()` | **SceneVoxel Source Fusion (SVSF)**：将本 tick `AutoSceneVoxel`、`BrushSceneVoxel` 与 `LandscapeSV`（terrain base collision / target guidance）合成为 `BlendSV` / committed `SceneVoxel`；`SV[t - 1]` 读取的是上一轮 `BlendSV` resident fields。 |
| Result feedback | `SceneVoxelCommitter.score_blendsv_feedback_against_target()` | post-commit GPU feedback pass；比较 `BlendSV[tick]` / committed `SceneVoxel` 与 `TargetSV_B` / `TargetSV` 的 complexity 和 completely overlap（即 `max(complexity, collision)` 的重合度）。 |
| SV resident buffers | `SceneVoxelCommitter` | SV 自持 `SV[t - 1]` 和 `SV[tick]` 的 scene/collision GPU resident buffers、grid metadata 和 dirty regions；previous 是本轮稳定读取输入，current 是本轮提交结果。 |
| Query projection | metadata / `GPUAutoObjectRuntime` / `AutoVoxelRuntimeProfileContainer` / `SceneVoxelTile` | 提供运行时 object id 查询、profile id、调试 lookup、dirty object ranges 和局部 rebuild 索引；`GPUAutoObjectRuntime` 不拥有 SV grid 或 commit，`AutoVoxelRuntimeProfileContainer` 不作为 CPU-side placement 替代路径。通过 SPA 暴露统一访问接口。 |

## Stage Contracts

| Stage | Inputs | Outputs | Boundary |
| --- | --- | --- | --- |
| Target read | `TargetSV`、`BrushSV`、target dirty bounds | `TargetSV_B` read buffers、target debug metadata | 只提供 guidance；不进入 source write 或 committed `SceneVoxel`。 |
| Prefilter | `SV[t - 1]` resident fields、`TargetSV_B`、descriptor-backed probes、dirty tile ids | anchors、GPU-internal `anchor_autoobject_topk`、candidate voxel-region votes | 只收窄候选；不做最终 physical placement。SPA 通过 `_build_autoobject_array_for_pipeline()` 构建输入，注入 profile_container 的 borrowed GPU buffers。 |
| Candidate routing | voxel-region votes、asset footprint、probe offsets、context radius、interpolation guard | `candidate_voxel_regions_by_asset` / legacy `candidate_voxel_sparses_by_asset`、`candidate_route_profiles` debug | 输出偏召回的 candidate voxel regions；空候选 asset 本轮跳过。 |
| Physical placement | routed asset defs、`SV[t - 1]` scene/collision fields、`TargetSV_B` target buffers | accepted placements、VPG temp duplicate buffers；可选 `gpu_autoobject_runtime_writeback` / `instance_stamp_writeback` | `score_voxel_tile.glsl` 负责 footprint、support、collision、clearance、overlap 和 target fit；`ISWS` / source records 只在显式请求 source writeback 时生成。SPA 注入 profile_container 和 gpu_runtime 到 placement settings。 |
| Commit | `AutoSceneVoxel[tick]`、`BrushSceneVoxel[tick]`、GPU commit payload buffers | `BlendSV[tick]` / committed `SceneVoxel[tick]`、`SV[tick]` resident fields | `blend_scene_voxels()` 是 public read model 发布点。SPA 调用 `sv_committer.apply_voxel_write_spec()`。 |
| Feedback | committed `BlendSV[tick]`、`TargetSV_B` / `TargetSV` | result-level target feedback score | 只评价提交结果；不替代候选评分。 |

## Runtime Flow

```text
SPA (ScenePlacementActor) 编排层
  → initialize(RD, sv_committer, gpu_runtime)
  → register_asset(descriptor, mesh) × N  [即时 GPU 上传]
  → is_gpu_ready()?  [验证就绪状态]
  → run_placement_pipeline()  [每帧入口]

SceneVoxelCommitter / SV owner [tick]
  -> BlendSV[t - 1] / SceneVoxel[tick - 1]
     previous AutoSceneVoxel + BrushSceneVoxel committed result
  -> SV[t - 1]: complexity_field, collision_field
     physical sampling reads previous BlendSV resident fields
  -> TargetSV + BrushSV -> TargetSV_B brush-composited target input
  -> AutoObject registry + descriptor-backed probe buffers
     SPA 管理 asset registry → AutoObjectProbePrefilterGPU
  -> collect dirty anchors / affected target bounds
  -> AutoObject probe prefilter
     SPA 注入 profile_container borrowed probe_records GPU buffer
  -> GPU score/topK internal pass
  -> readback voxel-region votes
  -> conservative expansion by route profile
  -> candidate_voxel_regions_by_asset debug view
  -> VoxelPlacementGenerator.run_multi_asset()
     VPG owns temporary duplicated buffers for same-batch avoidance
     SPA 注入 shared RD + profile_container + gpu_runtime
  -> GPU same-type exclusion / runtime-profile contract
  -> score_voxel_tile.glsl physical score / reduce / stamp
     candidate score reads SV[t - 1] + TargetSV_B
  -> accepted placements + temporary scene/collision output
     optional: GPUAutoObjectRuntime writeback + ISWS source writeback
  -> record builders
  -> AutoSceneVoxel[tick] write stream / BrushSceneVoxel[tick] write stream
     source fields + debug buffer labels
  -> blend_scene_voxels(tick): AutoSceneVoxel[tick] + BrushSceneVoxel[tick]
  -> BlendSV[tick] / SceneVoxel[tick]
  -> score_blendsv_feedback_against_target(BlendSV[tick], TargetSV_B / TargetSV)
     result feedback score after commit, not candidate score
  -> SV[tick]: complexity_field, collision_field
  -> next tick: SV[tick] promotes to SV[t - 1]
  -> dirty SceneVoxelTile / voxel-region invalidation
```

## TargetSV 与路由边界

`TargetSceneVoxel` 是目标效果画布。源 `TargetSV` 可以来自当前 GPU 路径，也可以后续接入外部 VDB 离线重采样；`BrushSV` 保存笔刷覆盖 / delta；`TargetSV_B` 是源 `TargetSV` 与 `BrushSV` 合成后的实际采样目标。无论来源如何，它们都不携带资产类别；只有 `TargetSV_B` 提供 routing 和 score 阶段默认读取的目标信号。`TargetSceneVoxel` guidance record 可保留为 target / guidance metadata 和 debug 回查，但不进入 `blend_scene_voxels()` 的 committed source 合成。

采样规范：

```text
sample_pos = anchor_pos + probe_or_context_offset
sample_pos = clamp(sample_pos, target_sv_min, target_sv_max)
sample_value = TargetSV_B[sample_pos]
```

- probe / context sample 越出 TargetSV_B 边界时，投射到最近的有效 TargetSV_B voxel。
- 越界采样不直接视为空白，也不直接判失败。
- clamp 只影响 TargetSV_B / target context 的读取位置，不改变 anchor、asset footprint 或最终 placement 坐标。
- `clamped_sample_count` 可作为 debug / confidence hint；当前未进入 placement score。

## Candidate Routing Contract

```text
upstream prefilter
  -> collect anchors
  -> score descriptor-backed semantic probes
  -> anchor_autoobject_topk

candidate routing
  -> read GPU voxel-region votes
  -> expand by footprint / probes / context / guard
  -> skip empty candidate regions
  -> candidate_voxel_regions_by_asset

placement
  -> each asset reads only its routed voxel regions
  -> GPU same-type exclusion / runtime-profile contract prunes blocked voxel regions
  -> score_voxel_tile.glsl remains physical scoring
```

路由阶段的 hard gate 是每个 anchor 已筛选成功的候选资产。候选内语义 rerank / validate / prune 不能重新遍历全资产库或生成新的 asset candidate，只能在候选集内部调整排序、降低置信度或剔除 route。

`candidate_voxel_regions_by_asset` 是保守 candidate voxel-region 集合，不是精确采样点集合。构建时应从 anchor voxel 出发，按 asset footprint AABB、semantic probe offset 范围、`context_sensing_radius` 和至少 1 voxel 的插值 guard 扩张到 candidate voxel regions；最终是否放置仍由 `score_voxel_tile.glsl` 精筛决定。`candidate_voxel_sparses_by_asset` 是 legacy alias。

`candidate_voxel_regions_by_asset` 作为当前 placement 主接口：

```gdscript
{
	0: [Vector3i(1, 0, 2), Vector3i(2, 0, 2)], # asset index -> candidate voxel-region coords
}
```

该字典传入 `VoxelPlacementGenerator.run_multi_asset()` 的 `common_settings["candidate_voxel_regions_by_asset"]`；legacy `common_settings["candidate_voxel_sparses_by_asset"]` 仍兼容。对外语义是「每个 asset 本轮要检查哪些 voxel regions」；当前实现用 `Vector3i` 表示离散 voxel-region / block 坐标，生成器内部会再归一化成紧凑 id。字段名里的 `voxel_sparse` 是 legacy debug 命名，不表示单个 voxel。它应偏向召回而非精确裁剪；若某个 asset 没有 candidate voxel region，则该 asset 本轮 placement 跳过并可标记为 prefilter skip。

## Current Modules

| Module | Main files | Notes |
| --- | --- | --- |
| SPA (ScenePlacementActor) | `scripts/scene_placement_actor.gd` | 运行时编排器，拥有 `AutoVoxelRuntimeProfileContainer` 完整生命周期，管理 asset registry、GPU buffer 就绪和 prefilter→placement→commit 三阶段流水线。详见 [`scene-placement-actor.md`](../core-scene-placement-actor/scene-placement-actor.md)。 |
| TargetSV generation | `scripts/target_scene_voxel_generator.gd` / `shaders/target_scene_voxel.glsl` | 当前 GPU 生成 TargetSV visual / collision buffers、decode read buffers 和 debug preview。 |
| TargetSV persistence | `scripts/main.gd` | 保存、加载、重算和显示 TargetSV overlay。 |
| Asset model | `scripts/auto_object.gd` / `scripts/auto_voxel_descriptor.gd` | `AutoObject` 是共同运行时基类；`AssetDescriptor` 的统一定义见 [`auto-voxel-descriptor.md`](../asset-descriptor-demo/asset-descriptor.md)。profile 只作为共享数据和生成辅助，descriptor 通过 SPA.register_asset() 注册并即时上传 GPU。 |
| Probe prefilter | `scripts/autoobject_probe_prefilter_gpu.gd` / [`autoobject-probe-prefilter.md`](../placement-autoobject-probe-prefilter/autoobject-probe-prefilter.md) | GPU-only 粗筛路径；`anchor_autoobject_topk` 当前不回读，公开输出以 `candidate_voxel_regions_by_asset` 为主；`autoobject_candidate_voxel_sparses` / `candidate_voxel_sparses_by_asset` 仅作为 legacy/debug alias；不保留 CPU 替代路径。SPA 创建 prefilter worker 并注入共享 RD + profile_container。 |
| Semantic routing | [`voxel-semantic-routing.md`](../placement-voxel-semantic-routing/voxel-semantic-routing.md) | 定义当前 `candidate_voxel_regions_by_asset` / legacy `candidate_voxel_sparses_by_asset` candidate voxel-region 合约、TargetSV_B clamp 采样、空候选 skip，以及候选内 rerank / route validation 边界。 |
| 3D voxel placement | `scripts/voxel_placement_generator.gd` / `shaders/score_voxel_tile.glsl` / `shaders/reduce_voxel_tiles.glsl` / `shaders/stamp_voxel_field.glsl` | 物理精筛和 stamp 主路径；不负责全库语义查找。SPA 创建 placer worker 并注入共享 RD + profile_container。 |
| SV resident buffers | `scripts/scene_voxel_committer.gd` | `SceneVoxelCommitter` 持有 SV resident state；SV 自持 `SV[t - 1]` / `SV[tick]` 的 scene/collision GPU resident buffers、grid metadata 和 dirty regions，服务 probe、placement、validation 和 debug query，不作为第二套权威数据模型。SPA 借用引用。 |
| Placement fitting | `scripts/placement_fitting_generator.gd` / `init_heightfield_fitting.glsl` / `fill_heightfield_asset.glsl` | 通用 heightfield fitting producer；当前 rock/cliff 流程只是 consumer。 |
| Runtime object indexing | `GPUAutoObjectRuntime` / `AutoVoxelRuntimeProfileContainer` / `SceneVoxelTile` | GPU object pool 负责 object id、`object_type`、profile、transform、bounds 和 dirty delta；profile container 负责 resident profile/probe/collision/pivot buffers；`SceneVoxelTile` 只保存局部 object id ranges 和 dirty summary。SPA 拥有 profile_container，借用 gpu_runtime。 |
| Dirty `SceneVoxelTile` updates | `scripts/main.gd` / `scripts/scene_voxel_committer.gd` / `scripts/autoobject_probe_prefilter_gpu.gd` / `scripts/voxel_placement_generator.gd` | AutoObject、brush、target、profile 和 placement 只发 dirty delta / bounds；SV owner 通过 `mark_scene_voxel_tile_dirty()` / `mark_scene_voxel_tile_bounds_dirty()` 映射为 affected `SceneVoxelTile` dirty。`invalidate_sv_tile()` / `invalidate_sv_rect()` 只是 legacy compatibility storage，再局部重建 source/routing、candidate voxel regions 和 BlendSV-backed resident fields。 |

## Dirty Update Rules

普通 complexity field 变化：

```text
AutoObject / brush / placement delta
  -> mark affected SceneVoxelTile dirty
     named entry: mark_scene_voxel_tile_dirty() / mark_scene_voxel_tile_bounds_dirty()
     legacy storage: invalidate_sv_tile() / invalidate_sv_rect()
  -> rebuild dirty tile source ranges and summaries
  -> rerun upstream prefilter for affected anchors
  -> rebuild candidate_voxel_regions_by_asset entries touched by dirty tiles
  -> blend_scene_voxels(tick) only when source changed
```

Target color / complexity 变化：

```text
dirty target bounds
  -> mark affected SceneVoxelTile target/routing dirty
     target dirty rect bridges to SceneVoxelTile routing/scoring dirty
  -> expand by context_sensing_radius
  -> expand by probe interpolation guard
  -> update affected candidate voxel regions
  -> rerun prefilter for affected anchors
  -> rebuild affected candidate_voxel_regions_by_asset
```

更新完成后不需要对所有 asset 重新生成 voxel 级 top-K；只需要处理 dirty / affected voxel regions 和相关 asset routes。

## Maintenance Rules

- 新增资产语义字段时默认加入 [`AssetDescriptor`](../asset-descriptor-demo/asset-descriptor.md)，不要在 `AutoObject` 上新增第二套同名语义状态。
- 新增资产字段时，先判断它属于资产默认值、运行时 record、source voxel write path、TargetSV 目标画布还是最终 `SceneVoxel` 状态。
- metadata 只能挂索引、调试字段和 `instance_stamp_write_spec` / `ISWS` handle，不能成为对象默认值的主来源；`voxel_write_spec` 只作为 legacy compatibility alias。
- 自动生成和画笔修改先进入 `SceneVoxelTile` dirty，再通过本 tick source voxel write path 更新 `SceneVoxel`；具体 source / commit 规则见 `scene-voxel-field-system.md`。
- `TargetSceneVoxel` 不写资产标签，也不进入 committed source / `SceneVoxel`；资产选择只能通过 prefilter / routing / placement 形成。
- SV resident buffers 和 dirty regions 由 `SceneVoxelCommitter` 自持 `SV[t - 1]` / `SV[tick]` 两个 epoch，服务 probe、placement、validation 和 debug；不存在第二套运行时权威状态。
- `GPUAutoObjectRuntime` / `AutoVoxelRuntimeProfileContainer` / VPG 的 contract validation 必须确认 shared-RD buffers ready、bound、consumed；无 `RenderingDevice` 时只能 SKIP GPU upload / placement 或输出 `contract_blocked=true`、`cpu_fallback=false`。通过 SPA 的 `is_gpu_ready()` 统一检查就绪状态。
- `BrushSV` / source stamp 是 dirty `SceneVoxelTile` 重建出的写入意图，不是绕过 tile 的第二套 SV 更新入口。
- full rebuild 只作为维护路径，语义等价于 dirty all tiles；不要把 per-frame full SV flush 作为普通 runtime 路径。
- `collision`、`collision_field` 和 terrain base collision 的归属统一维护在 `scene-voxel-field-system.md`。
- `AutoObject` 不应使用运行时缩放；`_configure_auto_object()` 强制 `scale = Vector3.ONE`，semantic probes 按 unscaled asset/local space 生成和采样。
- Probe 粗筛只减少候选 `AutoObject` / voxel regions，不直接写最终 `SceneVoxel`。
- `score_voxel_tile.glsl` 不新增 semantic dot / MLP / target neighborhood pooling。
- 文档读写统一使用 UTF-8，避免中文内容出现乱码。
- 流程变更时同步更新本文档、`scene-voxel-field-system.md`、`scene-placement-actor.md` 和相关 placement 文档；SVG 由图表负责范围单独更新。
- SPA 是 MeshFill 运行时数据的一站式入口：所有 descriptor 注册、GPU buffer 访问和 pipeline 编排应通过 SPA 而非直接操作 `AutoVoxelRuntimeProfileContainer` 或 worker 实例。


> **禁止 --headless**：本模块的所有 GPU 测试依赖 RenderingDevice，必须在 Vulkan 驱动下运行（--rendering-driver vulkan），使用 --headless 会导致测试无法访问 GPU，CPU fallback 不得作为通过条件。

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [框架总览](../../demos/core-meshfill-framework/core-meshfill-framework.md) | 测试方法与验收标准 | [`../../demos/core-meshfill-framework/core-meshfill-framework.tscn`](../../demos/core-meshfill-framework/core-meshfill-framework.tscn) |
| [Target Canvas Guidance](../../demos/modules/target-canvas-guidance/target-canvas-guidance.md) | 测试方法与验收标准 | [`../../demos/modules/target-canvas-guidance/target-canvas-guidance.tscn`](../../demos/modules/target-canvas-guidance/target-canvas-guidance.tscn) |
| [Candidate Routing Contract](../../demos/modules/candidate-routing-contract/candidate-routing-contract.md) | 测试方法与验收标准 | [`../../demos/modules/candidate-routing-contract/candidate-routing-contract.tscn`](../../demos/modules/candidate-routing-contract/candidate-routing-contract.tscn) |
| [SceneVoxel Commit](../../demos/modules/scene-voxel-commit/scene-voxel-commit.md) | 测试方法与验收标准 | [`../../demos/modules/scene-voxel-commit/scene-voxel-commit.tscn`](../../demos/modules/scene-voxel-commit/scene-voxel-commit.tscn) |
| [GPU AutoObject Runtime Plan](../../demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.md) | 测试方法与验收标准 | [`../../demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.tscn`](../../demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.tscn) |
