# Project Docs

This folder keeps MeshFill architecture notes, data schemas, pipeline plans, and generated diagrams. The root [`../README.md`](../README.md) is the GitHub entry page; this file is the detailed documentation index.

## Folder Map

| Folder | Purpose |
| --- | --- |
| [`core/`](core/) | Framework ownership, asset fields, source voxel state, and asset authoring notes |
| [`placement/`](placement/) | TargetSV, probe prefiltering, semantic routing, placement, and exclusion-field plans |

## Core Framework

| File | Purpose |
| --- | --- |
| [`core/meshfill-framework.md`](core/meshfill-framework.md) | MeshFill ownership model, runtime flow, current modules, and framework rules |
| [`core/scene-placement-actor.md`](core/scene-placement-actor.md) | SPA ownership, asset registry, profile GPU buffer lifecycle, and prefilter -> placement -> commit orchestration |
| [`core/autoobject-gpu-runtime-architecture.md`](core/autoobject-gpu-runtime-architecture.md) | GPU-first runtime architecture for million-scale `AutoObject`, including GPU object buffers, profile container, command queues, per-voxel object refs, and SV commit boundaries |
| [`core/asset-properties.md`](core/asset-properties.md) | Current `AutoObject`, descriptor, profile, and metadata field reference |
| [`core/scene-voxel-committer.md`](core/scene-voxel-committer.md) | `scripts/scene_voxel_committer.gd` 源码地图、状态域、GPU 计算阶段、对外 API 和验证入口 |
| [`core/scene-voxel-field-system.md`](core/scene-voxel-field-system.md) | SV write payloads, source voxel writes, final `SceneVoxel`, and GPU-resident SV query channels |
| [`core/scenevoxeltile.md`](core/scenevoxeltile.md) | `SceneVoxelTile` coarse SV cell index for dirty tracking, voxel bounds, AutoObject references, summaries, and partial rebuilds |
| [`core/auto-asset-scripting.md`](core/auto-asset-scripting.md) | Scripted rock and vegetation asset creation through Godot headless tools |
| [`core/asset-semantic-probes.md`](core/asset-semantic-probes.md) | Asset-side semantic probes used by current prefilter and planned candidate-only route validation |
| [`core/voxel-display.md`](core/voxel-display.md) | `VoxelDisplay` 统一体素栅格可视化：中心点 + 立方格尺寸 + 统一/逐格颜色，单 `MultiMesh` 渲染，碰撞预览与 occupancy 共享调参面 |

## Placement And Target Fields

| File | Purpose |
| --- | --- |
| [`placement/meshfill-object-volume-score-3d.md`](placement/meshfill-object-volume-score-3d.md) | Planned 3D per-object `50^3` volume score: subtile workgroups, 12 rotation slots, shared-memory sampling, and reduce aggregation |
| [`placement/meshfill-rock-placement-flow2.5d(暂停开发).md`](placement/meshfill-rock-placement-flow2.5d(暂停开发).md) | Paused 2.5D heightfield rock placement compute pipeline walkthrough (legacy/migration reference) |
| [`placement/target-scene-voxel-projection.md`](placement/target-scene-voxel-projection.md) | `TargetSceneVoxel` canvas, stamp model, planned VDB import, projection cache, and current GPU persistence |
| [`placement/autoobject-probe-prefilter.md`](placement/autoobject-probe-prefilter.md) | AutoObject semantic probe prefilter, CPU/GPU responsibilities, anchor collection, and candidate voxel-region output |
| [`placement/voxel-semantic-routing.md`](placement/voxel-semantic-routing.md) | Candidate asset routing and voxel-region routing after upstream prefilter |
| [`placement/voxel-semantic-routing-todo.md`](placement/voxel-semantic-routing-todo.md) | Current candidate-routing TODOs; excludes old full-asset semantic lookup tasks |

## Diagrams

| Path | Purpose |
| --- | --- |
| [`svg/autoobject_asset_properties.svg`](svg/autoobject_asset_properties.svg) | Descriptor-owned semantics, descriptor-owned fields, shared fields, `instance_stamp_write_spec` / `ISWS`, and public `SceneVoxel` payload boundaries |
| [`svg/autoobject_descriptor_relationship.svg`](svg/autoobject_descriptor_relationship.svg) | Focused `AutoObject` runtime and `AssetDescriptor` authority relationship |
| [`svg/autoobject_gpu_runtime_architecture.svg`](svg/autoobject_gpu_runtime_architecture.svg) | GPU-owned million-scale `AutoObject` runtime, CPU command/debug control plane, profile container, per-voxel object refs, and SV commit boundary |
| [`svg/autoassetfactory_relationships.svg`](svg/autoassetfactory_relationships.svg) | Scaffold JSON, `AutoAssetFactory` normalization, saved object/vegetation assets, and runtime write path |
| [`svg/meshfill_current_framework.svg`](svg/meshfill_current_framework.svg) | Current tick-level framework flow from target guidance and previous SV through routing, placement, commit, feedback, and next SV |
| [`svg/scene-placement-actor.svg`](svg/scene-placement-actor.svg) | SPA-owned asset registry and runtime profile container with borrowed SV/runtime owners and the placement pipeline |
| [`svg/meshfill_compute_shader_3d_placement.svg`](svg/meshfill_compute_shader_3d_placement.svg) | Heightfield fitting compute pipeline, iterative fill/update passes, descriptor-backed object instancing, and `SceneVoxel` integration |
| [`svg/autoobject_probe_prefilter_pipeline.svg`](svg/autoobject_probe_prefilter_pipeline.svg) | GPU-only AutoObject probe prefilter, dirty-region anchor collection, voxel-region votes, and readback route expansion |
| [`svg/autoobject_probe_scoring_logic.svg`](svg/autoobject_probe_scoring_logic.svg) | Descriptor probe generation, GPU SoA packing, clamped SV/TargetSV_B sampling, weighted fit, and candidate-only top-K boundary |
| [`svg/scene-voxel-flow.svg`](svg/scene-voxel-flow.svg) | `instance_stamp_write_spec` / `ISWS`, auto/brush source streams, `blend_scene_voxels()`, accepted `SceneVoxel` fields, feedback, and SV resident fields |
| [`svg/scenevoxeltile.svg`](svg/scenevoxeltile.svg) | `SceneVoxelTile` coarse SV cell index, dirty triggers, SV owner boundary, object id ranges, summaries, and consumers |
| [`svg/target-scene-voxel-current.svg`](svg/target-scene-voxel-current.svg) | `TargetSV`, `BrushSV`, `TargetSV_B`, target read buffers, consumer boundaries, and planned guidance sources |
| [`svg/voxel-semantic-routing.svg`](svg/voxel-semantic-routing.svg) | Candidate voxel-region routing, conservative readback expansion, empty-route skip, same-type exclusion, and physical scoring boundary |

## Documentation Rules

- Markdown file names use lowercase kebab-case, except conventional `README.md` files.
- Keep prose language consistent with the document being edited.
- Read and write documentation files as UTF-8 to preserve Chinese text.
- Prefer tables for schemas, file maps, and responsibility lists.
- Use labeled code fences such as `gdscript`, `json`, `bash`, or `text`.
- When behavior is inferred from code rather than verified in a running scene, mark it explicitly.

## Voxel And Compute Terminology

Use these terms consistently in voxel, placement, and compute-shader docs:

| Term | Meaning |
| --- | --- |
| `volume` | The whole voxel data domain and its storage, such as a flat storage buffer or 3D texture. It is not a single element. |
| `voxel` | One element/cell inside a `volume`, addressed by `(x, y, z)` or a flattened index. |
| `tile` | A fixed-size 2D/3D block used for sparse storage, compaction, dirty rebuilds, or workgroup remapping. It is an implementation/storage term. |
| `SceneVoxelTile` | An SV-owned coarse cell index/dirty record that stores dirty flags, voxel bounds, object id ranges, and summaries. Default tile size is fixed `4x4x4` voxels and can be overridden by `meshfill/scene_voxel_tile/size_voxels`; it is not committed `SceneVoxel` payload. |
| `SceneVoxel Source Fusion` / `SVSF` | The formal name for the `AutoSV` + `BrushSV` + `LandscapeSV` (terrain base collision / target guidance) → `BlendSV` / committed `SceneVoxel` multi-source resolve-and-blend flow. Executed by `resolve_scene_voxel_sources.glsl` (per-source winner arbitration + merge) and `blend_scene_voxel_fields.glsl` (compact records → dense field), orchestrated by `blend_scene_voxels()`. |
| `voxel region` | A high-level candidate or dirty region used by placement/routing. Prefer this term in prose; runtime APIs expose current `candidate_voxel_regions_by_asset` / `candidate_voxel_regions` fields plus legacy/debug `candidate_voxel_sparses*`, `dirty_tiles`, or `tile_id` storage names. |

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [文档总览](../demos/docs-readme/docs-readme.md) | 测试方法与验收标准 | [`../demos/docs-readme/docs-readme.tscn`](../demos/docs-readme/docs-readme.tscn) |
| [Docs Index And Graphs](../demos/modules/docs-index-and-graphs/docs-index-and-graphs.md) | 测试方法与验收标准 | [`../demos/modules/docs-index-and-graphs/docs-index-and-graphs.tscn`](../demos/modules/docs-index-and-graphs/docs-index-and-graphs.tscn) |
