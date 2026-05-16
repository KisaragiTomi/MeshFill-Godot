# Project Docs

This folder keeps MeshFill architecture notes, data schemas, pipeline plans, generated diagrams, and historical migration notes out of the project root. The root [`../README.md`](../README.md) is the GitHub entry page; this file is the detailed documentation index.

## Folder Map

| Folder | Purpose |
| --- | --- |
| [`core/`](core/) | Framework ownership, asset fields, source voxel state, and asset authoring notes |
| [`placement/`](placement/) | TargetSV, probe prefiltering, semantic routing, placement, and exclusion-field plans |
| [`graphs/`](graphs/) | SVG, GraphML, and rendered QA previews |
| [`history/`](history/) | Completed migration records and temporarily discarded design notes |

## Core Framework

| File | Purpose |
| --- | --- |
| [`core/meshfill-framework.md`](core/meshfill-framework.md) | MeshFill ownership model, runtime flow, current modules, and framework rules |
| [`core/asset-properties.md`](core/asset-properties.md) | Current `AutoObject`, descriptor, profile, and metadata field reference |
| [`core/scene-voxel-field-system.md`](core/scene-voxel-field-system.md) | SV write payloads, source voxel deltas, final `SceneVoxel`, and `GlobalVoxelField` cache design |
| [`core/auto-asset-scripting.md`](core/auto-asset-scripting.md) | Scripted rock and vegetation asset creation through Godot headless tools |
| [`core/asset-semantic-probes.md`](core/asset-semantic-probes.md) | Asset-side semantic probes used by prefilter and candidate-only route validation |

## Placement And Target Fields

| File | Purpose |
| --- | --- |
| [`placement/meshfill-rock-placement-flow.md`](placement/meshfill-rock-placement-flow.md) | Rock placement compute pipeline walkthrough |
| [`placement/target-scene-voxel-projection.md`](placement/target-scene-voxel-projection.md) | `TargetSceneVoxel` canvas, stamp model, planned VDB import, projection cache, and current GPU persistence |
| [`placement/autoobject-probe-prefilter.md`](placement/autoobject-probe-prefilter.md) | AutoObject semantic probe prefilter, CPU/GPU responsibilities, anchor collection, and candidate voxel-region output |
| [`placement/voxel-semantic-routing.md`](placement/voxel-semantic-routing.md) | Candidate asset routing and voxel-region routing after upstream prefilter |
| [`placement/voxel-semantic-routing-todo.md`](placement/voxel-semantic-routing-todo.md) | Current candidate-routing TODOs; excludes old full-asset semantic lookup tasks |

## Diagrams

| Path | Purpose |
| --- | --- |
| [`graphs/README.md`](graphs/README.md) | Graph inventory and editing notes |
| [`graphs/autoobject_asset_properties.svg`](graphs/autoobject_asset_properties.svg) | AutoObject class, resource, field, record, and metadata property map |
| [`graphs/meshfill_current_framework.svg`](graphs/meshfill_current_framework.svg) | Current framework overview |
| [`graphs/meshfill_compute_shader_3d_placement.svg`](graphs/meshfill_compute_shader_3d_placement.svg) | Compute shader 3D placement flow |
| [`graphs/autoobject_probe_scoring_logic.svg`](graphs/autoobject_probe_scoring_logic.svg) | AutoObject probe scoring logic |
| [`graphs/target-scene-voxel-current.svg`](graphs/target-scene-voxel-current.svg) | Current TargetSV GPU generation, persistence, and debug display flow |
| [`graphs/voxel-semantic-routing.svg`](graphs/voxel-semantic-routing.svg) | Semantic routing overview |

## History

| File | Purpose |
| --- | --- |
| [`history/voxel-3d-migration-plan.md`](history/voxel-3d-migration-plan.md) | Completed historical 3D voxel placement implementation record |
| [`history/vegetation-pipeline-暂时丢弃.md`](history/vegetation-pipeline-暂时丢弃.md) | Temporarily discarded vegetation pipeline note |

## Documentation Rules

- Markdown file names use lowercase kebab-case, except conventional `README.md` files.
- Keep prose language consistent with the document being edited.
- Read and write documentation files as UTF-8 to preserve Chinese text.
- Prefer tables for schemas, file maps, and responsibility lists.
- Use labeled code fences such as `gdscript`, `json`, `bash`, or `text`.
- When behavior is inferred from code rather than verified in a running scene, mark it explicitly.
