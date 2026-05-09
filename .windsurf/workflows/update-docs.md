---
description: update project documentation with the MeshFill docs rules
---

# Update Docs Workflow

Use this workflow when creating, renaming, deleting, or editing files under `docs/`.

## Rules

1. Read and write all Markdown documentation as UTF-8.
2. Use lowercase kebab-case file names for Markdown files under `docs/`, except conventional `README.md` files.
3. When renaming or deleting a document, update every Markdown reference to the old path.
4. Do not continue editing text that appears garbled; first verify encoding and recover readable content.
5. Keep design documents concise. Prefer sections for goal, constraints, data flow, interfaces/buffers, implementation steps, validation, and risks.
6. Remove or merge obsolete historical plans when their useful content is covered by current architecture docs.

## Canonical Docs

- `docs/README.md`: documentation index and basic documentation rules.
- `docs/meshfill-framework.md`: framework ownership, runtime flow, and maintenance rules.
- `docs/asset-properties.md`: asset field and record schema.
- `docs/scene-voxel-field-system.md`: `SceneVoxel`, `GlobalVoxelField`, commit flow, and dirty tile rules.
- `docs/voxel-semantic-routing.md`: semantic routing and voxel asset coarse selection design.

## Steps

1. Identify which canonical doc owns the information being changed.
2. Edit the smallest relevant section using UTF-8.
3. If file names changed, update references in all Markdown files.
4. Remove stale or contradictory text instead of preserving duplicate old plans.
5. Verify no old document names or broken references remain.

