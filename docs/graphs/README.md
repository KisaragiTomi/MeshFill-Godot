# Architecture Graphs

| File | Use |
| --- | --- |
| `autoobject_system.svg` | AutoObject ownership, placement, record, and query boundary overview |
| `autoobject_system.qa.png` | Rendered QA preview for the AutoObject system graph |
| `autoobject_asset_properties.svg` | AutoObject class, resource, field, record, and metadata property map |
| `autoobject_asset_properties.qa.png` | Rendered QA preview for the AutoObject asset properties graph |
| `meshfill_current_framework.svg` | Current framework overview across asset defaults, placement systems, runtime records, source deltas, final `SceneVoxel`, and `GlobalVoxelField` cache |
| `meshfill_compute_shader_3d_placement.svg` | Compute shader 3D placement fitting flow from inputs and GPU passes to CPU surface-normal decoration and consumer handoff |
| `autoobject_probe_scoring_logic.svg` | AutoObject probe scoring and candidate selection logic |
| `autoobject_probe_scoring_logic.qa.png` | Rendered QA preview for the probe scoring graph |
| `target-scene-voxel-current.svg` | Current TargetSV GPU generation, persistence, and debug display flow |
| `voxel-semantic-routing.svg` | Candidate-only semantic routing overview |
| `meshfill_architecture.graphml` | Editable node graph for yEd or other GraphML tools |

The graphs follow the current ownership rule:

```text
AutoObject / Resource owns defaults.
voxel_record owns runtime scene data.
metadata is only an index and query projection.
TargetSceneVoxel owns neutral target visual/collision intent.
```

Open the `.graphml` file in yEd to move nodes, change colors, or run automatic layout. Keep stable node ids when editing so future generated versions can preserve layout more easily.
