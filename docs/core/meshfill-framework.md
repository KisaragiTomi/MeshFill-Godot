# MeshFill Framework

本文整理当前 MeshFill-Godot 框架的数据归属、生成主线、候选路由和运行时查询边界。本文只保留跨模块总览；资产字段细节见 `asset-properties.md`；SceneVoxel/source 写入、collision 和缓存规则见 `scene-voxel-field-system.md`；TargetSV 设计见 `target-scene-voxel-projection.md`；候选资产路由见 `voxel-semantic-routing.md`；AutoObject probe 粗筛见 `autoobject-probe-prefilter.md`。

![MeshFill 当前框架总览](../graphs/meshfill_current_framework.svg)

## 文档边界

- 本文回答“MeshFill 的模块如何串起来”：目标画布、资产默认值、候选路由、placement、source write、commit、缓存和查询的大体关系。
- `SceneVoxel` 字段、`voxel_write_spec`、source stream、`blend_scene_voxels()`、`collision_voxels`、terrain base collision 和 `SceneVoxelLocal` 细节统一放在 `scene-voxel-field-system.md`。
- 本文只保留这些系统的边界引用，避免和专题文档重复维护同一套规则。

## 核心约束

- `TargetSceneVoxel` / `TargetSV`、`BrushSV` 和合成后的 `TargetSV_B` 是目标效果画布：只提供 prefilter / routing / scoring / target fit 的目标信号，不写入 `tree`、`rock`、`grass` 等 asset 标签；源 `TargetSV` 与 `BrushSV` 需要存储，`TargetSV_B` 是默认读取输入。
- `AutoVoxelDescriptor` 是“资产是什么”的唯一语义主来源；`AutoObject` 只持有 descriptor 入口、运行时身份、mesh、放置约束和兼容字段。
- 运行时 record / `voxel_write_spec` 只回答“本次实例放在哪里、写什么 payload”；提交后的 `SceneVoxel` 才是后续系统读取的结果。
- probe prefilter 只减少候选 `AutoObject` / voxel regions，不直接写最终 `SceneVoxel`；score / top-K 主结果应随当前 SV epoch 留在 GPU `AnchorState`，不依赖 CPU 回读字典。
- Candidate voxel regions 必须保守扩张，覆盖 asset footprint、probe 插值采样半径、context 半径和插值 guard，宁可让更多 voxel 进入候选，也不要漏掉可能得分高的位置。
- 语义向量匹配只在每个 anchor 的粗筛候选资产内做 rerank / validate / prune，不遍历全资产库。
- 物理可放置性仍由 `score_voxel_tile.glsl` 的 footprint、support、collision、clearance、overlap 和 target fit 决定。
- 同类型 `AutoObject` 的 `min_spacing` 互斥可在 physical placement 前通过 `AutoObjectManager` 做低成本 candidate voxel-region 剪枝；最终 footprint / collision 仍由 GPU score 确认。
- runtime cache / metadata 只能提供查询、索引、debug 和候选剪枝，不成为资产默认值或 committed SceneVoxel 的第二套权威状态。

## Ownership

| Layer | Owner | Responsibility |
| --- | --- | --- |
| Actor runtime owner | `SceneVoxelActor`（暂名） | 与当前 `SceneVoxel[tick]` 同生命周期，统一持有 `SceneVoxelLocal`、GPU `AnchorState`、AutoObject registry、`TargetSV`、`BrushSV` 与 `TargetSV_B`。 |
| Target canvas | `TargetSceneVoxel` / `BrushSV` / `TargetSV_B` / `TargetSceneVoxelGenerator` | 源 `TargetSV` 保存中性原始目标；`BrushSV` 保存笔刷 delta / override；`TargetSV_B` 是二者合成后的实际采样目标；支持 GPU 生成、dirty 更新和可选 VDB 重采样导入。 |
| Asset defaults | `AutoVoxelDescriptor` / `AutoObject.voxel_descriptor` / typed assets | descriptor 保存资产默认语义、体素颜色、复杂度、碰撞 footprint、pivot variants、semantic probes 和可选 profile fallback；`AutoObject` 同名字段只作为 Inspector / 配置字典兼容入口。 |
| Probe prefilter | `AutoVoxelDescriptor.semantic_probe_profile` / `AutoObjectProbePrefilterGPU` / `AnchorState` | 从 `SceneVoxelLocal` / `TargetSV_B` 读取可放置 anchor，按 descriptor probes 采样，把 score / top-K 写入 GPU `AnchorState` 和 candidate route buffer。 |
| Candidate routing | GPU candidate route buffer / `candidate_voxel_sparses_by_asset` compat view | 把上游候选归一化、去重、可选 rerank，并聚合为每个 asset 的 candidate voxel regions；CPU 字典只是兼容 / debug 视图。 |
| Physical placement | `VoxelPlacementGenerator` / placement shaders | 只对 routed asset / candidate voxel regions 做 GPU score、reduce、stamp；可在 GPU scoring 前执行同类型 candidate voxel-region 剪枝；如果 asset 没有候选区域，本轮可跳过。 |
| Runtime record | record builders / `voxel_write_spec` | 统一创建或更新实例 record，保存位置、像素、channel、collision、source 和 debug handle。 |
| Source voxel | `AutoSceneVoxel` / `BrushSceneVoxel` | auto 和 brush 的当前 tick 写入意图；source stream 与提交规则见 `scene-voxel-field-system.md`。 |
| Final state | `blend_scene_voxels()` / `SceneVoxel` | committed read model；字段、合成和 collision 规则见 `scene-voxel-field-system.md`。 |
| Runtime sampling view | `SceneVoxelLocal` / `scripts/scene_voxel_runtime.gd` | 当前 SV epoch 的 runtime sampling/query view；由 committed `SceneVoxel` 初始化并可随 source write / stamp delta / dirty update 刷新，不是 source write 或语义权威。 |
| Query projection | metadata / `AutoObjectManager` | 提供运行时索引、调试查询、record handle、低分辨率 `Vector3i` cell 查询和同类型互斥预检；当前只有 `Y = 0` 单层，不作为资产默认值来源。 |

## Runtime Flow

```text
SceneVoxelActor[tick]
  -> SceneVoxel[tick - 1] committed read model
  -> SceneVoxelLocal runtime sampling view / scene_field / collision_field
  -> TargetSV + BrushSV -> TargetSV_B brush-composited target input
  -> AutoObject registry + descriptor-backed probe buffers
  -> collect dirty anchors / affected target bounds
  -> AutoObject probe prefilter
  -> GPU AnchorState(score/topK) + candidate route buffer
  -> optional candidate-only semantic rerank / route validation
  -> candidate voxel regions
  -> candidate_voxel_sparses_by_asset compat/debug view
  -> VoxelPlacementGenerator.run_multi_asset()
  -> optional same-type AutoObject exclusion gate
  -> score_voxel_tile.glsl physical score / reduce / stamp
  -> record builders
  -> AutoSceneVoxel write stream / BrushSceneVoxel write stream
     SceneVoxel base fields + auto/brush source fields
  -> blend_scene_voxels(tick)
  -> SceneVoxel[tick] committed read model
  -> derive / update SceneVoxelLocal sampling/query buffers
  -> dirty voxel-region / rect invalidation
```

## TargetSV 与路由边界

`TargetSceneVoxel` 是目标效果画布。源 `TargetSV` 可以来自当前 GPU 路径，也可以后续接入外部 VDB 离线重采样；`BrushSV` 保存笔刷覆盖 / delta；`TargetSV_B` 是源 `TargetSV` 与 `BrushSV` 合成后的实际采样目标。无论来源如何，它们都不携带资产类别；只有 `TargetSV_B` 提供 routing 和 score 阶段默认读取的目标信号；它不进入 `blend_scene_voxels()` 的 committed source 合成。

采样规范：

```text
sample_pos = anchor_pos + probe_or_context_offset
sample_pos = clamp(sample_pos, target_sv_min, target_sv_max)
sample_value = TargetSV_B[sample_pos]
```

- probe / context sample 越出 TargetSV_B 边界时，投射到最近的有效 TargetSV_B voxel。
- 越界采样不直接视为空白，也不直接判失败。
- clamp 只影响 TargetSV_B / target context 的读取位置，不改变 anchor、asset footprint 或最终 placement 坐标。
- `clamped_sample_count` 可作为 debug / confidence hint，第一版不要求参与 `route_score`。

## Candidate Routing Contract

```text
upstream prefilter
  -> collect anchors
  -> score descriptor-backed semantic probes
  -> anchor_autoobject_topk

candidate routing
  -> read candidates from anchor_autoobject_topk only
  -> optional semantic_score / target_score
  -> route_score rerank
  -> EMPTY pruning
  -> candidate_voxel_sparses_by_asset

placement
  -> each asset reads only its routed voxel regions
  -> optional same-type AutoObject exclusion gate prunes blocked voxel regions
  -> score_voxel_tile.glsl remains physical scoring
```

路由阶段的 hard gate 是每个 anchor 已筛选成功的候选资产。后续语义向量匹配不能重新遍历全资产库，也不能生成新的 asset candidate。它只能在候选集内部调整排序、降低置信度或剔除 route。

`candidate_voxel_sparses_by_asset` 是保守 candidate voxel-region 集合，不是精确采样点集合。构建时应从 anchor voxel 出发，按 asset footprint AABB、semantic probe offset 范围、`context_sensing_radius` 和至少 1 voxel 的插值 guard 扩张到 candidate voxel regions；最终是否放置仍由 `score_voxel_tile.glsl` 精筛决定。

`candidate_voxel_sparses_by_asset` 作为当前 placement 主接口：

```gdscript
{
    asset_index: Array[Vector3i]  # voxel-region coords; compat key may say voxel_sparse
}
```

该字典传入 `VoxelPlacementGenerator.run_multi_asset()` 的 `common_settings["candidate_voxel_sparses_by_asset"]`。对外语义是“每个 asset 本轮要检查哪些 voxel regions”；当前实现用 `Vector3i` 表示离散 voxel-region/block 坐标，生成器内部会再归一化成紧凑 id。它应偏向召回而非精确裁剪；若某个 asset 没有 candidate voxel region，则该 asset 本轮 placement 跳过并可标记为 prefilter skip。

## Current Modules

| Module | Main files | Notes |
| --- | --- | --- |
| TargetSV generation | `scripts/target_scene_voxel_generator.gd` / `shaders/target_scene_voxel.glsl` | 当前 GPU 生成 TargetSV visual / collision buffers 和 debug preview。 |
| TargetSV persistence | `scripts/main.gd` | 保存、加载、重算和显示 TargetSV overlay。 |
| Asset model | `scripts/auto_object.gd` / `scripts/auto_voxel_descriptor.gd` / typed asset scripts | `AutoObject` 是共同运行时基类；`AutoVoxelDescriptor` 是资产默认语义唯一权威来源，profile 只作为共享数据和生成辅助。 |
| Probe prefilter | `scripts/autoobject_probe_prefilter_gpu.gd` / `docs/placement/autoobject-probe-prefilter.md` | GPU-only 粗筛路径，输出 `anchor_autoobject_topk` 和 `autoobject_candidate_voxel_sparses`；不保留 CPU fallback。 |
| Semantic routing | `docs/placement/voxel-semantic-routing.md` | 定义候选内 rerank、route validation、EMPTY pruning、TargetSV_B clamp 采样和 `candidate_voxel_sparses_by_asset` 的 candidate voxel-region 合约。 |
| 3D voxel placement | `scripts/voxel_placement_generator.gd` / `shaders/score_voxel_tile.glsl` / `shaders/reduce_voxel_tiles.glsl` / `shaders/stamp_voxel_field.glsl` | 物理精筛和 stamp 主路径；不负责全库语义查找。 |
| SceneVoxelLocal runtime view | `scripts/scene_voxel_runtime.gd` | 当前 SV epoch 的 runtime sampling / dirty view；辅助 probe sampling、placement sampling、validation 和 debug query，不作为 SV 权威数据模型。 |
| Placement fitting | `scripts/cliff_generator.gd` / fitting shaders | 通用同类资产 fitting producer；当前类名保留历史命名。 |
| Runtime indexing | `scripts/auto_object_manager.gd` / metadata | 根据 `auto_id` / `instance_id` 查找运行时 record；维护低分辨率 `Vector3i(x, y, z)` cell 索引用于邻近查询和同类型互斥预检，当前 `_spatial_y_layer()` 固定为 `0`，所以仍是一层。 |
| Incremental editing | `scripts/pcg_pipeline.gd` / `scripts/pcg_layer.gd` / `scripts/nutrition_layer.gd` / `scripts/main.gd` | dirty rect、override、brush commit 和局部刷新。 |

## Dirty Update Rules

普通 scene field 变化：

```text
dirty voxel region (compat: dirty tile)
  -> rerun upstream prefilter for affected anchors
  -> rebuild candidate_voxel_sparses_by_asset entries touched by dirty voxel region
  -> skip assets whose routed voxel region list becomes empty
```

Target color / complexity 变化：

```text
dirty target bounds
  -> expand by local / wide context radius
  -> expand by probe interpolation guard
  -> update affected context voxel regions
  -> rerun route validation for affected anchors
  -> rebuild affected candidate_voxel_sparses_by_asset
```

更新完成后不需要对所有 asset 重新生成 voxel 级 top-K；只需要处理 dirty / affected voxel regions 和相关 asset routes。

## Maintenance Rules

- 新增资产语义字段时默认加入 `AutoVoxelDescriptor`，不要在 `AutoObject` 上新增第二套同名语义状态。
- 新增资产字段时，先判断它属于资产默认值、运行时 record、source voxel write path、TargetSV 目标画布还是最终 `SceneVoxel` 状态。
- metadata 只能挂索引、调试字段和 `voxel_write_spec` handle，不能成为对象默认值的主来源。
- 自动生成和画笔修改只通过本 tick source voxel write path 更新 `SceneVoxel`；具体 source / commit 规则见 `scene-voxel-field-system.md`。
- `TargetSceneVoxel` 不写资产标签；资产选择只能通过 prefilter / routing / placement 形成。
- `SceneVoxelLocal` / `scripts/scene_voxel_runtime.gd` 是当前 SV epoch 的 runtime sampling/query view，服务 probe、placement、validation 和 debug，不直接承担最终编辑语义。
- `collision_voxels`、`collision_field` 和 terrain base collision 的归属统一维护在 `scene-voxel-field-system.md`。
- `AutoObject` 不应使用运行时缩放；`_configure_auto_object()` 强制 `scale = Vector3.ONE`，semantic probes 按 unscaled asset/local space 生成和采样。
- Probe 粗筛只减少候选 `AutoObject` / voxel regions，不直接写最终 `SceneVoxel`。
- `score_voxel_tile.glsl` 不新增 semantic dot / MLP / target neighborhood pooling。
- 文档读写统一使用 UTF-8，避免中文内容出现乱码。
- 流程变更时同步更新本文档、`scene-voxel-field-system.md`、`docs/placement/voxel-semantic-routing.md` 和 `docs/graphs/meshfill_current_framework.svg`。
