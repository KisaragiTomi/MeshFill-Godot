# MeshFill-Godot

`MeshFill-Godot` is a Godot 4.6 procedural scene filling prototype. It is currently focused on terrain-driven rock and vegetation placement, 3D voxel fields, `AutoObject` asset semantics, GPU compute placement, `TargetSceneVoxel`, and semantic probe prefiltering.

The project is an engineering prototype rather than a finished game. Its main goal is to settle the MeshFill framework: data ownership, generation stages, runtime records, target voxel fields, and debuggable placement flow.

## Current Focus

- `AutoObject`, `AutoRock`, and `AutoVegetation` hold asset defaults such as voxel color, complexity, `collision` / `collision_strength`, pivots, and semantic probes.
- `instance_stamp_write_spec` (`ISWS`) stores per-instance runtime placement data, source voxel intent, and lookup fields.
- `SceneVoxel` represents committed scene state and keeps its SV query channels resident on the GPU for later placement, validation, and debug queries.
- `TargetSceneVoxel` is a neutral target canvas for color, complexity, and collision intent. It does not store labels such as `tree`, `rock`, or `grass`.
- `AutoObjectProbePrefilterGPU` collects anchors from `SV` / `TargetSV`, scores asset probes, and outputs candidate `AutoObject` top-K plus candidate voxel regions.
- `VoxelPlacementGenerator` remains responsible for physical scoring: footprint, support, collision, clearance, and final stamping.

## Project Layout

| Path | Purpose |
| --- | --- |
| `main.tscn` | Main scene with `GameLogic`, fly camera, and basic lighting |
| `scripts/main.gd` | Generation orchestration, debug UI, hotkeys, TargetSV persistence, and overlays |
| `scripts/` | Runtime code for AutoObject, rocks, vegetation, voxel fields, placement, and prefiltering |
| `shaders/` | RenderingDevice compute shaders for TargetSV, prefiltering, and voxel placement |
| `tools/` | Godot headless tests, asset scaffolding, texture tools, and conversion utilities |
| `docs/` | Architecture, schemas, pipeline notes, and TODO documents |
| `docs/graphs/` | GraphML and SVG architecture diagrams |
| `assets/` | Godot resource assets |
| `geo/` | FBX and height source assets |
| `textures/` / `landscape/` | Scene depth, height, normal, mask, and landscape input textures |

## Requirements

- Godot 4.6 with the project configured for `Forward Plus`.
- A desktop GPU and driver that support Godot `RenderingDevice` compute shaders.
- Python only for optional texture and terrain utility scripts.

## Run

Open `project.godot` in Godot and run `main.tscn`.

Command-line launch:

```bash
godot --path .
```

If your Godot executable is not named `godot`, replace it with the local Godot 4.6 executable path.

## Interactive Controls

| Input | Action |
| --- | --- |
| Right mouse + drag | Capture mouse and rotate the fly camera |
| `W` / `A` / `S` / `D` | Move camera |
| `Q` / `E` / `Space` | Move camera down / up |
| `Shift` | Fast camera movement |
| Mouse wheel | Adjust captured movement speed or move forward/back while uncaptured |
| `C` | Run one rock generation step |
| `P` | Generate vegetation |
| `J` | Toggle saved `TargetSceneVoxel` preview |
| `Ctrl+J` | Recompute and save `TargetSceneVoxel` |
| `G` / `H` | Toggle target height / height diff debug overlays |
| `V` | Toggle delta overlay |
| `B` | Toggle brush mode |
| `N` | Cycle brush target layer |
| `T` | Toggle tile refresh mode |
| `I` | Toggle probe inspect mode |
| `M` | Toggle combined mask overlay |
| `Ctrl+Z` | Undo brush override |
| `F12` | Save a viewport screenshot to the Godot user data directory |

## Useful Headless Commands

```bash
godot --headless --path . --script tools/test_autoobject_probe_prefilter.gd
godot --headless --path . --script tools/test_voxel_placement_generator.gd
godot --headless --path . --script tools/test_scene_voxel_field.gd
godot --headless --path . --script tools/scaffold_auto_asset.gd -- --config res://tools/my_asset.json
```

These scripts are useful for local checks and resource generation. They are not a complete CI suite.
`tools/test_autoobject_probe_prefilter.gd` exercises the GPU-only prefilter path and requires a working RenderingDevice.

## Documentation Map

| Document | Topic |
| --- | --- |
| [`docs/README.md`](docs/README.md) | Full documentation index |
| [`docs/core/meshfill-framework.md`](docs/core/meshfill-framework.md) | Current framework ownership model and runtime flow |
| [`docs/core/asset-properties.md`](docs/core/asset-properties.md) | Current AutoObject, descriptor, profile, `instance_stamp_write_spec` / `ISWS`, and metadata field reference |
| [`docs/core/scene-voxel-field-system.md`](docs/core/scene-voxel-field-system.md) | Source voxel writes, final `SceneVoxel`, and GPU-resident SV query channels |
| [`docs/placement/target-scene-voxel-projection.md`](docs/placement/target-scene-voxel-projection.md) | TargetSV canvas, stamp model, VDB import plan, projection cache, and persistence |
| [`docs/placement/autoobject-probe-prefilter.md`](docs/placement/autoobject-probe-prefilter.md) | AutoObject probe prefilter and GPU candidate voxel-region output |
| [`docs/placement/voxel-semantic-routing.md`](docs/placement/voxel-semantic-routing.md) | Candidate asset routing and voxel-region routing |
| [`docs/core/auto-asset-scripting.md`](docs/core/auto-asset-scripting.md) | Scripted rock and vegetation asset creation |
| [`docs/graphs/README.md`](docs/graphs/README.md) | Architecture graph index |

## Notes

- `user://target_scene_voxel/` stores generated TargetSV flat buffers, preview images, and metadata.
- `.godot/`, logs, temporary files, and local editor state are intentionally ignored.
- Documentation and SVG files should stay UTF-8 so Chinese notes remain readable.
