# Architecture Graphs

本目录保存 MeshFill 文档引用的架构图和流程图。图只用于辅助理解；字段、接口和运行时行为仍以 `scripts/`、`shaders/` 和相邻 Markdown 文档为准。

## Graph Inventory

| File | Purpose | Owning Docs |
| --- | --- | --- |
| [`autoobject_asset_properties.svg`](autoobject_asset_properties.svg) | descriptor 权威语义、descriptor-owned fields、shared fields、`instance_stamp_write_spec` (`ISWS`)、public `SceneVoxel` payload 与 metadata/debug 边界 | `docs/core/asset-properties.md`, `docs/core/auto-asset-scripting.md` |
| [`autoobject_descriptor_relationship.svg`](autoobject_descriptor_relationship.svg) | `AutoObject` runtime identity、`AutoVoxelDescriptor` 语义权威、descriptor-backed getters、record export 与 metadata projection 的关系 | `docs/core/asset-properties.md` |
| [`autoobject_gpu_runtime_architecture.svg`](autoobject_gpu_runtime_architecture.svg) | 百万级 `AutoObject` GPU runtime、CPU command/debug control plane、runtime profile container、per-voxel object refs 与 SV commit 边界 | `docs/core/autoobject-gpu-runtime-architecture.md` |
| [`autoassetfactory_relationships.svg`](autoassetfactory_relationships.svg) | JSON scaffold、`AutoAssetFactory` shared-field 归一化、rock/vegetation 资源生成与 runtime `instance_stamp_write_spec` (`ISWS`) 写入路径 | `docs/core/asset-properties.md`, `docs/core/auto-asset-scripting.md` |
| [`meshfill_current_framework.svg`](meshfill_current_framework.svg) | 当前 tick 内从 `TargetSV_B` / `SV[t - 1]` 到 prefilter、candidate voxel regions、physical placement、commit、feedback 和 `SV[tick]` 的主流程 | `docs/core/meshfill-framework.md` |
| [`scene-placement-actor.svg`](scene-placement-actor.svg) | `ScenePlacementActor` 的 asset registry、owned runtime profile container、prefilter/placement/commit 编排和借用的 SV/runtime 边界 | `docs/core/scene-placement-actor.md` |
| [`meshfill_compute_shader_3d_placement.svg`](meshfill_compute_shader_3d_placement.svg) | heightfield fitting compute pass、迭代 fill/find/update、CPU `AutoRock` 实例化和 `SceneVoxel` 集成 | `docs/placement/meshfill-rock-placement-flow.md` |
| [`autoobject_probe_prefilter_pipeline.svg`](autoobject_probe_prefilter_pipeline.svg) | GPU-only AutoObject probe prefilter、dirty voxel-region anchor collection、voxel-region votes、readback expansion 和 placement contract | `docs/placement/autoobject-probe-prefilter.md` |
| [`autoobject_probe_scoring_logic.svg`](autoobject_probe_scoring_logic.svg) | descriptor probe 生成、SoA buffer、clamped `SV` / `TargetSV_B` 采样、weighted fit、anchor top-K 与 candidate-only 边界 | `docs/core/asset-semantic-probes.md`, `docs/placement/autoobject-probe-prefilter.md` |
| [`scene-voxel-flow.svg`](scene-voxel-flow.svg) | `instance_stamp_write_spec` (`ISWS`)、**SceneVoxel Source Fusion (SVSF)**：`AutoSceneVoxel` / `BrushSceneVoxel` / `LandscapeSV` source streams → `blend_scene_voxels()` → accepted `SceneVoxel` fields → feedback → SV resident fields | `docs/core/scene-voxel-field-system.md` |
| [`scenevoxeltile.svg`](scenevoxeltile.svg) | `SceneVoxelTile` 粗粒度 SV cell index / dirty record、dirty triggers、voxel bounds、object id ranges、summary 与 partial rebuild 消费者 | `docs/core/scenevoxeltile.md` |
| [`target-scene-voxel-current.svg`](target-scene-voxel-current.svg) | `TargetSV`、`BrushSV`、`TargetSV_B`、target read buffers、prefilter/scoring/feedback consumers 与非 source-write 边界 | `docs/placement/target-scene-voxel-projection.md` |
| [`voxel-semantic-routing.svg`](voxel-semantic-routing.svg) | candidate voxel-region routing、conservative readback expansion、empty-route skip、same-type exclusion、physical scoring 与 future rerank 边界 | `docs/placement/voxel-semantic-routing.md`, `docs/placement/voxel-semantic-routing-todo.md` |

## Editing Notes

- 高层文档和 SVG prose 使用 `voxel region`；`voxel_sparse*`、`dirty_tiles` 和 `tile_id` 只作为 debug API 或底层 storage/workgroup 名称。
- 命名的粗粒度 SV 管理记录写作 `SceneVoxelTile`；它是 SV coarse index / dirty record，不是 committed `SceneVoxel` payload，默认固定 `4x4x4` voxels，可由 `meshfill/scene_voxel_tile/size_voxels` 调整。
- `candidate_voxel_regions_by_asset` 是当前 docs-facing route/debug view；`candidate_voxel_sparses_by_asset` 仅作为 legacy alias，语义上仍是 candidate voxel regions，空候选直接 skip。
- 统一使用 canonical `collision`；`collision` 只作为 placement runtime footprint record/API 名称出现。
- committed `SceneVoxel` accepted fields 统一写作 `complexity/color/collision`，可选 `auto_mix`；`channel` 只作为 source/write context 或 scatter profile。
- `occupied`、`type`、`source_type`、`commit_tick` 属于派生视图、索引或 metadata，不画成 per-voxel payload。
- `TargetSV` / `BrushSV` / `TargetSV_B` 是 guidance / target canvas，不进入 committed `SceneVoxel` source write。
- `BlendSV` / `SceneVoxel` 是 committed read model；SV resident state 持有 scene/collision 查询通道，runtime sampling、dirty 和坐标职责归 SV。
- `AutoVoxelDescriptor` 是资产默认语义权威来源；`AutoObject` 同名字段只表示 Inspector / 配置入口。
- 修改 SVG 后，同步检查对应 Markdown 引用、图索引和 UTF-8 中文显示。

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [图表总览](../../demos/graphs-readme/graphs-readme.md) | 测试方法与验收标准 | [`../../demos/graphs-readme/graphs-readme.tscn`](../../demos/graphs-readme/graphs-readme.tscn) |
| [Docs Index And Graphs](../../demos/modules/docs-index-and-graphs/docs-index-and-graphs.md) | 测试方法与验收标准 | [`../../demos/modules/docs-index-and-graphs/docs-index-and-graphs.tscn`](../../demos/modules/docs-index-and-graphs/docs-index-and-graphs.tscn) |
