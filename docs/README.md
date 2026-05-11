# Project Docs

This folder keeps MeshFill architecture notes, data schemas, pipeline plans, generated diagrams, and historical migration notes out of the project root. The root [`../README.md`](../README.md) is the GitHub entry page; this file is the detailed documentation index.

## Core Framework

| File | Purpose |
| --- | --- |
| `meshfill-framework.md` | MeshFill ownership model, runtime flow, current modules, and framework rules |
| `asset-properties.md` | `AutoObject`, persistent asset fields, `voxel_record`, source voxel, and `SceneVoxel` schema notes |
| `scene-voxel-field-system.md` | Source deltas, final `SceneVoxel`, and `GlobalVoxelField` cache design |
| `auto-asset-scripting.md` | Scripted rock and vegetation asset creation through Godot headless tools |
| `asset-semantic-probes.md` | Semantic probe generation and asset-side probe conventions |

## Placement And Target Fields

| File | Purpose |
| --- | --- |
| `meshfill-rock-placement-flow.md` | Rock placement compute pipeline walkthrough |
| `vegetation-pipeline.md` | Vegetation occupancy, voxel, scatter, and validation pipeline notes |
| `target-scene-voxel-projection.md` | `TargetSceneVoxel` canvas, stamp model, VDB import plan, projection cache, and current GPU persistence |
| `target-scene-voxel-current.svg` | Current TargetSV GPU generation, persistence, and debug display flow |
| `autoobject-probe-prefilter.md` | AutoObject semantic probe prefilter, CPU/GPU responsibilities, anchor collection, and candidate tile output |
| `voxel-semantic-routing.md` | Candidate asset routing and tile routing after upstream prefilter |
| `voxel-semantic-routing-todo.md` | Deferred semantic routing and MLP-related work |
| `voxel-3d-migration-plan.md` | Historical 3D voxel migration checklist |

## Diagrams

| Path | Purpose |
| --- | --- |
| `graphs/README.md` | Graph inventory and editing notes |
| `graphs/meshfill_current_framework.svg` | Current framework overview |
| `graphs/meshfill_compute_shader_3d_placement.svg` | Compute shader 3D placement flow |
| `graphs/autoobject_probe_scoring_logic.svg` | AutoObject probe scoring logic |
| `voxel-semantic-routing.svg` | Semantic routing overview |

## Documentation Rules

- Markdown file names use lowercase kebab-case, except conventional `README.md` files.
- Keep prose language consistent with the document being edited.
- Read and write documentation files as UTF-8 to preserve Chinese text.
- Prefer tables for schemas, file maps, and responsibility lists.
- Use labeled code fences such as `gdscript`, `json`, `bash`, or `text`.
- When behavior is inferred from code rather than verified in a running scene, mark it explicitly.
