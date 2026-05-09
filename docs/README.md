# Project Docs

This folder keeps project documentation, architecture notes, generated diagrams, and historical implementation plans out of the project root.

| File | Purpose |
| --- | --- |
| `local-context.md` | Short context for future local sessions |
| `meshfill-framework.md` | MeshFill framework ownership, runtime flow, and overview SVG |
| `auto-asset-scripting.md` | Scripted rock and vegetation asset creation |
| `asset-properties.md` | Current asset, record, and property schema |
| `scene-voxel-field-system.md` | UE-style source delta, final `SceneVoxel`, and `GlobalVoxelField` cache design |
| `vegetation-pipeline.md` | Vegetation occupancy, voxel, and scatter pipeline notes |
| `meshfill-rock-placement-flow.md` | Rock placement compute pipeline walkthrough |
| `voxel-semantic-routing.md` | Semantic routing plan for voxel asset coarse selection |
| `voxel-3d-migration-plan.md` | Historical 3D voxel migration checklist |
| `graphs/` | Editable GraphML diagrams and SVG previews |

The project root keeps only operational context that local tooling expects:

| File | Purpose |
| --- | --- |
| `../mempalace.md` | Shared project memory used by the local `meshfill-memory` skill |

## Documentation Rules

- Markdown file names use lowercase kebab-case, except conventional `README.md` files.
- Read and write documentation files as UTF-8 to preserve Chinese text.
- Windsurf workflow entry: `.windsurf/workflows/update-docs.md`.

