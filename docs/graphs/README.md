# Architecture Graphs

本目录保存 MeshFill 文档引用的架构图和流程图。图用于辅助理解；字段、接口和运行时行为仍以 `scripts/`、`shaders/` 和相邻 Markdown 文档为准。

## Graph Inventory

| File | Purpose | Owning Docs |
| --- | --- | --- |
| [`autoobject_asset_properties.svg`](autoobject_asset_properties.svg) | `AutoObject`、`AutoVoxelDescriptor`、compatibility mirror、`voxel_write_spec`、`SceneVoxel` commit 和 metadata 的归属图 | `docs/core/asset-properties.md`, `docs/core/auto-asset-scripting.md` |
| [`autoobject_descriptor_relationship.svg`](autoobject_descriptor_relationship.svg) | `AutoObject` runtime identity、descriptor 权威语义、compatibility mirror 和 record export 的关系 | `docs/core/asset-properties.md` |
| [`autoassetfactory_relationships.svg`](autoassetfactory_relationships.svg) | `AutoAssetFactory`、脚手架、typed asset、`AutoObject` helper 和 SV runtime path 边界 | `docs/core/asset-properties.md` |
| [`meshfill_current_framework.svg`](meshfill_current_framework.svg) | 当前 MeshFill 框架、数据归属、候选路由、source write、commit 和 runtime sampling view 总览 | `docs/core/meshfill-framework.md` |
| [`meshfill_compute_shader_3d_placement.svg`](meshfill_compute_shader_3d_placement.svg) | 3D placement GPU score/reduce/stamp、multi-asset priority/quota、CPU instantiation、dirty voxel-region 集成和 2.5D compatibility | `docs/placement/meshfill-rock-placement-flow.md`, `docs/history/voxel-3d-migration-plan.md` |
| [`autoobject_probe_prefilter_pipeline.svg`](autoobject_probe_prefilter_pipeline.svg) | GPU-only AutoObject probe prefilter pipeline、SceneVoxelActor lifetime inputs、GPU AnchorState 和 candidate route buffer | `docs/placement/autoobject-probe-prefilter.md` |
| [`autoobject_probe_scoring_logic.svg`](autoobject_probe_scoring_logic.svg) | TargetSV_B sampling、SceneVoxel occupancy、underground collision-only、weighted scoring 和 anchor top-K | `docs/core/asset-semantic-probes.md`, `docs/placement/autoobject-probe-prefilter.md` |
| [`scene-voxel-flow.svg`](scene-voxel-flow.svg) | `voxel_write_spec`、source write streams、`blend_scene_voxels()`、committed `SceneVoxel` 和 derived `SceneVoxelLocal` cache flow | `docs/core/scene-voxel-field-system.md` |
| [`scene-voxel-runtime-interactions.svg`](scene-voxel-runtime-interactions.svg) | `SceneVoxelLocal` 与 committed `SceneVoxel`、TargetSV_B guidance、prefilter、placement、validation 和 writeback 的交互 | `docs/core/scene-voxel-field-system.md` |
| [`target-scene-voxel-current.svg`](target-scene-voxel-current.svg) | 当前 TargetSV/TargetSV_B GPU 生成、持久化、调试显示和 routing-input flow | `docs/placement/target-scene-voxel-projection.md` |
| [`voxel-semantic-routing.svg`](voxel-semantic-routing.svg) | Candidate-only semantic routing、anchor prefilter hard gate、rerank/validation、EMPTY pruning、candidate voxel-region aggregation 和 physical placement | `docs/placement/voxel-semantic-routing.md`, `docs/placement/voxel-semantic-routing-todo.md` |

## Editing Notes

- 高层文档和 SVG prose 使用 `voxel region`；`voxel_sparse*`、`dirty_tiles` 和 `tile_id` 只作为兼容 API 或底层 storage/workgroup 名称。
- `TargetSV` / `BrushSV` / `TargetSV_B` 是 guidance / target canvas，不进入 committed `SceneVoxel` source write。
- `SceneVoxel` 是 committed read model；`SceneVoxelLocal` 是当前 SV epoch 的 sampling/query view，不是新的语义权威。
- `AutoVoxelDescriptor` 是资产默认语义权威来源；`AutoObject` 同名字段只表示 Inspector / 配置兼容入口。
- 修改 SVG 后，同步检查对应 Markdown 引用、图索引和 UTF-8 中文显示。
