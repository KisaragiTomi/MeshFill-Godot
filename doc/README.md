# Project Documentation

This folder is the single home for MeshFill architecture notes, data schemas, demo contracts, and implementation plans. The root [`README.md`](../README.md) remains the GitHub entry page; root `CLAUDE.md` and `mempalace.md` remain in place because project tooling reads those conventional paths.

## Core Architecture

| File | Purpose |
| --- | --- |
| [`asset-descriptor.md`](asset-descriptor.md) | `AssetDescriptor` definition, field groups, and authoring rules |
| [`asset-properties.md`](asset-properties.md) | `AutoObject`, descriptor, profile, and metadata field reference |
| [`asset-semantic-probes.md`](asset-semantic-probes.md) | Asset-side semantic probes and candidate filtering boundaries |
| [`auto-asset-scripting.md`](auto-asset-scripting.md) | Scripted object and vegetation asset creation |
| [`auto-object-gpu-runtime-architecture.md`](auto-object-gpu-runtime-architecture.md) | GPU-first runtime architecture for million-scale `AutoObject` data |
| [`auto-object-instance-emit.md`](auto-object-instance-emit.md) | GPU instance emit, direct rendering, and picking payloads |
| [`auto-object-probe-prefilter.md`](auto-object-probe-prefilter.md) | GPU semantic-probe prefilter and resident candidate handoff |
| [`scene-placement-actor.md`](scene-placement-actor.md) | SPA ownership and prefilter -> placement -> commit orchestration |
| [`scene-voxel-field-system.md`](scene-voxel-field-system.md) | SV writes, committed `SceneVoxel`, and resident field contracts |
| [`scene-voxel-tile.md`](scene-voxel-tile.md) | `SceneVoxelTile` coarse index, dirty tracking, and partial rebuilds |
| [`sv-anchor-collection.md`](sv-anchor-collection.md) | Position-only anchor collection rules |
| [`target-scene-voxel-projection.md`](target-scene-voxel-projection.md) | `TargetSceneVoxel` canvas and projection boundaries |
| [`target-sv-brush-overlay.md`](target-sv-brush-overlay.md) | BrushSV overlay display and write acceptance |
| [`target-sv-point-cloud-conversion.md`](target-sv-point-cloud-conversion.md) | Houdini point-cloud to TargetSV conversion acceptance |

## Demo And Test Contracts

| File | Purpose |
| --- | --- |
| [`core-scene-placement-actor.md`](core-scene-placement-actor.md) | SPA + AutoObject end-to-end placement test-scene contract |
| [`placement-score-3d.md`](placement-score-3d.md) | 3D residual-gain volume-score contract |
| [`ui-click-test-plan.md`](ui-click-test-plan.md) | Core SPA click-selection UI test plan |

The two live scene files remain with their runtime assets:
[`placement-score-3d.tscn`](../demos/placement-score-3d/placement-score-3d.tscn) and
[`asset-overview.tscn`](../scenes/asset-overview/asset-overview.tscn).

## Plans

| File | Purpose |
| --- | --- |
| [`auto-volume-base-class-plan.md`](auto-volume-base-class-plan.md) | Shared `AutoVolume` base-class plan |
| [`gpu-direct-rendering-plan.md`](gpu-direct-rendering-plan.md) | GPU direct-rendering implementation plan |
| [`volume-display-domain-audit.md`](../volume-display-domain-audit.md) | Per-domain audit of the five Voxel Display domains: what each still implements for itself vs what belongs in the AutoVolume base chain (kept at repo root) |
| [`project-simplification-plan.md`](project-simplification-plan.md) | Project simplification and cleanup plan |
| [`unified-picking-plan.md`](unified-picking-plan.md) | Voxel-format and picking unification plan |

## Diagrams

| Path | Purpose |
| --- | --- |
| [`../scenes/asset-overview/diagrams/autoobject_asset_properties.svg`](../scenes/asset-overview/diagrams/autoobject_asset_properties.svg) | Descriptor-owned semantics, descriptor-owned fields, shared fields, `instance_stamp_write_spec` / `ISWS`, and public `SceneVoxel` payload boundaries |
| [`../scenes/asset-overview/diagrams/autoobject_descriptor_relationship.svg`](../scenes/asset-overview/diagrams/autoobject_descriptor_relationship.svg) | Focused `AutoObject` runtime and `AssetDescriptor` authority relationship |
| [`core-SPA-scene-placement-actor/diagrams/autoobject_gpu_runtime_architecture.svg`](../demos/core-SPA-scene-placement-actor/diagrams/autoobject_gpu_runtime_architecture.svg) | GPU-owned million-scale `AutoObject` runtime, CPU command/debug control plane, profile container, tile-level object refs, and SV commit boundary |
| [`../scenes/asset-overview/diagrams/autoassetfactory_relationships.svg`](../scenes/asset-overview/diagrams/autoassetfactory_relationships.svg) | Scaffold JSON, `AutoAssetFactory` normalization, saved object/vegetation assets, and runtime write path |
| [`core-SPA-scene-placement-actor/diagrams/scene-placement-actor.svg`](../demos/core-SPA-scene-placement-actor/diagrams/scene-placement-actor.svg) | SPA-owned asset registry and runtime profile container with borrowed SV/runtime owners and the placement pipeline |
| [`placement-autoobject-probe-prefilter/diagrams/autoobject_probe_prefilter_pipeline.svg`](../demos/placement-autoobject-probe-prefilter/diagrams/autoobject_probe_prefilter_pipeline.svg) | GPU-only AutoObject probe prefilter, dirty-region anchor collection, per-anchor top-K, and the resident anchor_candidate_handoff |
| [`placement-autoobject-probe-prefilter/diagrams/autoobject_probe_scoring_logic.svg`](../demos/placement-autoobject-probe-prefilter/diagrams/autoobject_probe_scoring_logic.svg) | Descriptor probe generation, profile-arena packing, SV/TargetSV_B sampling, weighted fit, and candidate-only top-K boundary |
| [`core-scene-voxel-field-system/diagrams/scene-voxel-flow.svg`](../demos/core-scene-voxel-field-system/diagrams/scene-voxel-flow.svg) | `instance_stamp_write_spec` / `ISWS`, stamp-only commit (`commit_scene_voxels()`), BrushSV overlay / BlendSV compose, accepted `SceneVoxel` fields, feedback, and SV resident fields |
| [`core-scenevoxeltile/diagrams/scenevoxeltile.svg`](../demos/core-scenevoxeltile/diagrams/scenevoxeltile.svg) | `SceneVoxelTile` coarse SV cell index, dirty triggers, SV owner boundary, object-ref slots, summaries, and consumers |
| [`core-SPA-scene-placement-actor/diagrams/spa_selection_mode_transition.svg`](../demos/core-SPA-scene-placement-actor/diagrams/spa_selection_mode_transition.svg) | ⚠ **历史产物**：SPA selection-mode state machine。该机制已删除（状态机 2026-08-07、模式号 2026-08-10），准入只看显示开关；图中 API 全仓不存在 |
| [`core-SPA-scene-placement-actor/diagrams/voxel-pick-flow.svg`](../demos/core-SPA-scene-placement-actor/diagrams/voxel-pick-flow.svg) | Full GPU voxel-pick path: world ray to resident buffer reuse keys to pick shader to readback decode |
| [`core-meshfill-framework/meshfill_current_framework.svg`](../demos/core-meshfill-framework/meshfill_current_framework.svg) | Current end-to-end MeshFill framework overview |
| [`target-sv-point-cloud-conversion-c/diagrams/target-scene-voxel-current.svg`](../demos/target-sv-point-cloud-conversion-c/diagrams/target-scene-voxel-current.svg) | `TargetSV`, `BrushSV`, `TargetSV_B`, target read buffers, consumer boundaries, and planned guidance sources |
| [`target-sv-point-cloud-conversion-c/diagrams/target-sv-point-cloud-conversion-overview.svg`](../demos/target-sv-point-cloud-conversion-c/diagrams/target-sv-point-cloud-conversion-overview.svg) | TargetSV point cloud conversion viewport alignment, height texture sampling, and preview output path |
| [`placement-voxel-semantic-routing/voxel-semantic-routing.svg`](../demos/placement-voxel-semantic-routing/voxel-semantic-routing.svg) | Candidate voxel-region routing, conservative readback expansion, empty-route skip, same-type exclusion, and physical scoring boundary |

## Documentation Rules

- Keep ordinary project documentation in `doc/`; keep only conventional tooling and entry files at the repository root.
- Markdown file names use lowercase ASCII kebab-case, except conventional `README.md`, `CLAUDE.md`, and `mempalace.md` files.
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
| `SceneVoxelTile` | An SPA-owned GPU coarse cell index/dirty record that stores dirty flags, voxel bounds, object-ref slots, and summaries. Default tile size is `8x8x8` voxels and can be overridden by `meshfill/scene_voxel_tile/size_voxels`; it is not committed `SceneVoxel` payload. |
| `Stamp-only commit` | Committed `SceneVoxel` is pure-auto resident field state; the stamp IS the commit (`stamp_asset_voxels.glsl` mixed-asset in-place state-chain stamp, `scatter_sv_field_records.glsl` for CPU-entry records, published by `commit_scene_voxels()`). `BrushSV` is an SPA-resident overlay that never commits; `BlendSV` = on-demand compose of SV + BrushSV (`compose_blend_sv_fields.glsl`) used for 3D score sampling and TargetSV comparison, released after use. |
| `voxel region` | A high-level dirty region used by SV maintenance (`dirty_tiles` / `tile_id` storage names). The old placement-routing region APIs (`candidate_voxel_regions_by_asset` / `candidate_voxel_regions`, legacy/debug `candidate_voxel_sparses*`) were deleted with the candidate route; the prefilter now hands fine scoring the resident `anchor_candidate_handoff` (one origin per anchor). |

## `## 测试场景` 契约

`tools/test_core_demo_contracts.gd`（已于 2026-08-07 删除：只能经 --script 启动，本仓禁跑 = 从来没跑过，此约束现无守卫）曾硬编码四份 core 文档，要求每份都带一个
`## 测试场景` 表格，且表格行同时链接一个存在的 `doc/*.md` 与一个存在的 `demos/**/*.tscn`：

- [`auto-object-gpu-runtime-architecture.md`](auto-object-gpu-runtime-architecture.md)
- [`scene-placement-actor.md`](scene-placement-actor.md)
- [`scene-voxel-field-system.md`](scene-voxel-field-system.md)
- [`scene-voxel-tile.md`](scene-voxel-tile.md)

demo 场景清理后，这四份的表格统一指向仅存的
[`placement-score-3d.tscn`](../demos/placement-score-3d/placement-score-3d.tscn)，
该 `.tscn` 的 `DemoSetup` 节点用 `metadata/source_docs`（`;` 分隔）登记这四份来源文档。
其余文档不受该契约约束，已移除各自的 `## 测试场景` 与运行步骤章节。
