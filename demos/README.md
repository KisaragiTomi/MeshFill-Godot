# Project Docs

This folder keeps MeshFill architecture notes, data schemas, pipeline plans, and generated diagrams. The root [`../README.md`](../README.md) is the GitHub entry page; this file is the detailed documentation index.

## Folder Map

| Folder | Purpose |
| --- | --- |
| [`core-meshfill-framework/`](core-meshfill-framework/) | MeshFill ownership model, runtime flow, and framework fixture scene |
| [`core-scene-voxel-field-system/`](core-scene-voxel-field-system/) | SV write payloads, committed `SceneVoxel`, and SV resident fields |
| [`core-scenevoxeltile/`](core-scenevoxeltile/) | `SceneVoxelTile` dirty sidecar index and debug scene |
| [`core-SPA-scene-placement-actor/`](core-SPA-scene-placement-actor/) | SPA orchestration, GPU AutoObject runtime architecture, and unified interactive demo |
| [`core-sv-anchor-collection/`](core-sv-anchor-collection/) | `collect_sv_anchors.glsl` position-only anchor rules demo |
| [`asset-descriptor-demo/`](asset-descriptor-demo/) | `AssetDescriptor` semantics, asset properties, semantic probes, and asset authoring |
| [`placement-autoobject-probe-prefilter/`](placement-autoobject-probe-prefilter/) | AutoObject semantic probe prefilter pipeline and demo |
| [`placement-score-3d/`](placement-score-3d/) | 3D volume score contract and VPG-driven placement demo |
| [`placement-voxel-semantic-routing/`](placement-voxel-semantic-routing/) | Candidate voxel-region routing diagrams |
| [`target-sv-point-cloud-conversion-c/`](target-sv-point-cloud-conversion-c/) | TargetSV projection, point-cloud conversion, and brush overlay |

## Core Framework

| File | Purpose |
| --- | --- |
| [`core-meshfill-framework/meshfill-framework.md`](core-meshfill-framework/meshfill-framework.md) | MeshFill ownership model, runtime flow, current modules, and framework rules |
| [`core-SPA-scene-placement-actor/scene-placement-actor.md`](core-SPA-scene-placement-actor/scene-placement-actor.md) | SPA ownership, asset registry, profile GPU buffer lifecycle, and prefilter -> placement -> commit orchestration |
| [`core-SPA-scene-placement-actor/autoobject-gpu-runtime-architecture.md`](core-SPA-scene-placement-actor/autoobject-gpu-runtime-architecture.md) | GPU-first runtime architecture for million-scale `AutoObject`, including GPU object buffers, profile container, direct object APIs with resident batch spawn, per-voxel object refs, and SV commit boundaries |
| [`asset-descriptor-demo/asset-descriptor.md`](asset-descriptor-demo/asset-descriptor.md) | `AssetDescriptor` unified definition, field groups, and authoring rules |
| [`asset-descriptor-demo/asset-properties.md`](asset-descriptor-demo/asset-properties.md) | Current `AutoObject`, descriptor, profile, and metadata field reference |
| [`core-scene-voxel-field-system/scene-voxel-field-system.md`](core-scene-voxel-field-system/scene-voxel-field-system.md) | SV write payloads, source voxel writes, final `SceneVoxel`, and GPU-resident SV query channels |
| [`core-scenevoxeltile/scenevoxeltile.md`](core-scenevoxeltile/scenevoxeltile.md) | `SceneVoxelTile` coarse SV cell index for dirty tracking, voxel bounds, AutoObject references, summaries, and partial rebuilds |
| [`asset-descriptor-demo/auto-asset-scripting.md`](asset-descriptor-demo/auto-asset-scripting.md) | Scripted rock and vegetation asset creation through Godot headless tools |
| [`asset-descriptor-demo/asset-semantic-probes.md`](asset-descriptor-demo/asset-semantic-probes.md) | Asset-side semantic probes used by current prefilter and planned candidate-only route validation |

## Placement And Target Fields

| File | Purpose |
| --- | --- |
| [`placement-score-3d/placement-score-3d.md`](placement-score-3d/placement-score-3d.md) | 3D volume score contract: landed in-shader 12-rotation scoring in `score_voxel_tile.glsl`; two-pass prototype sections kept as historical reference |
| [`target-sv-point-cloud-conversion-c/target-scene-voxel-projection.md`](target-sv-point-cloud-conversion-c/target-scene-voxel-projection.md) | `TargetSceneVoxel` canvas, stamp model, planned VDB import, projection cache, and current GPU persistence |
| [`target-sv-point-cloud-conversion-c/target-sv-point-cloud-conversion.md`](target-sv-point-cloud-conversion-c/target-sv-point-cloud-conversion.md) | Houdini point-cloud to TargetSV guidance buffer conversion acceptance |
| [`target-sv-point-cloud-conversion-c/targetsv-brush-overlay.md`](target-sv-point-cloud-conversion-c/targetsv-brush-overlay.md) | BrushSV overlay display and brush write acceptance |
| [`placement-autoobject-probe-prefilter/autoobject-probe-prefilter.md`](placement-autoobject-probe-prefilter/autoobject-probe-prefilter.md) | AutoObject semantic probe prefilter, CPU/GPU responsibilities, anchor collection, and candidate voxel-region output |
| [`core-sv-anchor-collection/core-sv-anchor-collection.md`](core-sv-anchor-collection/core-sv-anchor-collection.md) | Position-only anchor collection rules validated on a controlled SV field |

## Diagrams

| Path | Purpose |
| --- | --- |
| [`asset-descriptor-demo/diagrams/autoobject_asset_properties.svg`](asset-descriptor-demo/diagrams/autoobject_asset_properties.svg) | Descriptor-owned semantics, descriptor-owned fields, shared fields, `instance_stamp_write_spec` / `ISWS`, and public `SceneVoxel` payload boundaries |
| [`asset-descriptor-demo/diagrams/autoobject_descriptor_relationship.svg`](asset-descriptor-demo/diagrams/autoobject_descriptor_relationship.svg) | Focused `AutoObject` runtime and `AssetDescriptor` authority relationship |
| [`core-SPA-scene-placement-actor/diagrams/autoobject_gpu_runtime_architecture.svg`](core-SPA-scene-placement-actor/diagrams/autoobject_gpu_runtime_architecture.svg) | GPU-owned million-scale `AutoObject` runtime, CPU command/debug control plane, profile container, per-voxel object refs, and SV commit boundary |
| [`asset-descriptor-demo/diagrams/autoassetfactory_relationships.svg`](asset-descriptor-demo/diagrams/autoassetfactory_relationships.svg) | Scaffold JSON, `AutoAssetFactory` normalization, saved object/vegetation assets, and runtime write path |
| [`core-meshfill-framework/diagrams/meshfill_current_framework.svg`](core-meshfill-framework/diagrams/meshfill_current_framework.svg) | Current tick-level framework flow from target guidance and previous SV through routing, placement, commit, feedback, and next SV |
| [`core-SPA-scene-placement-actor/diagrams/scene-placement-actor.svg`](core-SPA-scene-placement-actor/diagrams/scene-placement-actor.svg) | SPA-owned asset registry and runtime profile container with borrowed SV/runtime owners and the placement pipeline |
| [`placement-autoobject-probe-prefilter/diagrams/autoobject_probe_prefilter_pipeline.svg`](placement-autoobject-probe-prefilter/diagrams/autoobject_probe_prefilter_pipeline.svg) | GPU-only AutoObject probe prefilter, dirty-region anchor collection, voxel-region votes, and readback route expansion |
| [`placement-autoobject-probe-prefilter/diagrams/autoobject_probe_scoring_logic.svg`](placement-autoobject-probe-prefilter/diagrams/autoobject_probe_scoring_logic.svg) | Descriptor probe generation, GPU SoA packing, clamped SV/TargetSV_B sampling, weighted fit, and candidate-only top-K boundary |
| [`core-scene-voxel-field-system/diagrams/scene-voxel-flow.svg`](core-scene-voxel-field-system/diagrams/scene-voxel-flow.svg) | `instance_stamp_write_spec` / `ISWS`, stamp-only commit (`commit_scene_voxels()`), BrushSV overlay / BlendSV compose, accepted `SceneVoxel` fields, feedback, and SV resident fields |
| [`core-scenevoxeltile/diagrams/scenevoxeltile.svg`](core-scenevoxeltile/diagrams/scenevoxeltile.svg) | `SceneVoxelTile` coarse SV cell index, dirty triggers, SV owner boundary, object id ranges, summaries, and consumers |
| [`target-sv-point-cloud-conversion-c/diagrams/target-scene-voxel-current.svg`](target-sv-point-cloud-conversion-c/diagrams/target-scene-voxel-current.svg) | `TargetSV`, `BrushSV`, `TargetSV_B`, target read buffers, consumer boundaries, and planned guidance sources |
| [`target-sv-point-cloud-conversion-c/diagrams/target-sv-point-cloud-conversion-overview.svg`](target-sv-point-cloud-conversion-c/diagrams/target-sv-point-cloud-conversion-overview.svg) | TargetSV point cloud conversion viewport alignment, height texture sampling, and preview output path |
| [`placement-voxel-semantic-routing/diagrams/voxel-semantic-routing.svg`](placement-voxel-semantic-routing/diagrams/voxel-semantic-routing.svg) | Candidate voxel-region routing, conservative readback expansion, empty-route skip, same-type exclusion, and physical scoring boundary |

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
| `Stamp-only commit` | Committed `SceneVoxel` is pure-auto resident field state; the stamp IS the commit (`stamp_voxel_field.glsl` in-place state-chain stamp, `scatter_sv_field_records.glsl` for CPU-entry records, published by `commit_scene_voxels()`). `BrushSV` is an SPA-resident overlay that never commits; `BlendSV` = on-demand compose of SV + BrushSV (`compose_blend_sv_fields.glsl`) used for 3D score sampling and TargetSV comparison, released after use. |
| `voxel region` | A high-level candidate or dirty region used by placement/routing. Prefer this term in prose; runtime APIs expose current `candidate_voxel_regions_by_asset` / `candidate_voxel_regions` fields plus legacy/debug `candidate_voxel_sparses*`, `dirty_tiles`, or `tile_id` storage names. |

## 测试场景

每个 demo 目录的知识文档自带 `## 测试场景` 表格，链接该 demo 的测试文档与 `.tscn` 场景，由 `tools/test_core_demo_contracts.gd` 契约校验；本索引不再单独维护场景清单。
