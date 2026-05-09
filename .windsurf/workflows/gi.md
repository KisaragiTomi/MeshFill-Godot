---
description: Godot GI editing workflow and memory for 2D and 3D rendering. Use when working on FluidCrowd 2D Radiance Cascades global illumination, 2D emission/light maps, 3D SDFGI/VoxelGI/LightmapGI/ReflectionProbe/Environment lighting, shader import/runtime issues, minimap/visibility-layer interactions, GI denoising/stabilization, or when updating project GI memory after changes.
---

# GI

## Quick Start

Use this skill for Godot GI/rendering work. First read the project `MEMORY.md` if present, then choose the matching track:

- **2D GI**: Read `references/fluidcrowd-gi.md` for FluidCrowd Radiance Cascades, GPU emission textures, agent/event emitters, denoising, and minimap/layer interactions.
- **3D GI**: Read `references/godot-3d-gi.md` for Godot SDFGI, VoxelGI, LightmapGI, ReflectionProbe, Environment, material emission, and 3D shader/runtime checks.

If the task mixes 2D overlays with a 3D world, identify the boundary between world lighting, screen-space presentation, and UI/minimap layers before editing.

Start by checking the local worktree:

```powershell
git status --short
rg -n "GPUGI|gi_|debug_stage|laser|emission|temporal|Radiance|SDFGI|VoxelGI|LightmapGI|ReflectionProbe|Environment|WorldEnvironment|Camera3D|MeshInstance3D" scripts shaders scenes MEMORY.md
```

Treat existing uncommitted changes as user work. Preserve them unless the user explicitly asks for a revert.

## 2D Workflow

Use this track for FluidCrowd and other texture/screen-space 2D GI paths.

1. Identify which 2D GI surface is involved:
   - `scripts/gpu_gi.gd`: pass orchestration, buffers, uniforms, output images, denoise/stabilize.
   - `scripts/crowd_sim.gd`: lifecycle, viewport region, sprite presentation, HUD controls, buffer wiring.
   - `scripts/gpu_agents.gd` and `shaders/agent_combat.glsl`: combat events or per-agent data that feed GI.
   - `shaders/gi_*.glsl`: emission, blockers, JFA, distance, cascades, resolve, stabilization.

2. Prefer small storage buffers for new GI shader parameters. Avoid adding push constants to new GI compute shaders unless the project has already proven that path safe in Godot 4.6.

3. Keep the GI compute order explicit:

```text
clear emission -> wall mask -> agent/event emission -> seed -> JFA -> distance -> cascades -> image -> stabilize
```

4. For new visual emitters, write into the emission image before seed/JFA/distance so they can participate in GI. For screen-only diagnostics, draw in `_draw()` instead.

5. If editing noise or flicker, inspect both shader and runtime state:
   - `gi_stabilize.glsl` does spatial blur and temporal history blend.
   - `GPUGI.temporal_blend` defaults to `0.82`.
   - `GPUGI.spatial_filter_strength` defaults to `0.65`.
   - Region changes disable temporal history through `_is_same_region()`.

6. Validate with Godot after 2D code or shader changes:

```powershell
D:\Godot\godot-source\bin\godot.windows.editor.x86_64.exe --headless --path d:\MyProject\FluidCrowd --check-only --script res://scripts/gpu_gi.gd
D:\Godot\godot-source\bin\godot.windows.editor.x86_64.exe --headless --path d:\MyProject\FluidCrowd --check-only --script res://scripts/crowd_sim.gd
D:\Godot\godot-source\bin\godot.windows.editor.x86_64.exe --headless --path d:\MyProject\FluidCrowd --import
```

If `godot` is not on `PATH`, use the executable referenced by `Start.bat`.

## 3D Workflow

Use this track for world-space GI, 3D materials, probes, baked lighting, environment lighting, or 3D shader/runtime issues.

1. Identify which 3D GI system is active:
   - `WorldEnvironment` / `Environment`: SDFGI, ambient light, sky, tonemap, glow, volumetric fog.
   - `VoxelGI`: dynamic GI volume coverage, bake state, bounds, cell size, and probe data.
   - `LightmapGI`: baked lightmaps, UV2 validity, bake mode, and static/dynamic object settings.
   - `ReflectionProbe`: reflection coverage, update mode, blend distance, and interaction with rough materials.
   - `MeshInstance3D`, materials, and shaders: emission energy, transparency, vertex color, normal maps, and render priority.

2. Keep 3D lighting changes scoped to the system causing the symptom. Do not tune Environment exposure, material emission, probe bounds, and shader color space at the same time unless the current task requires a coordinated look pass.

3. For missing or weak 3D GI, inspect the data path in this order:

```text
emissive material or light -> mesh visibility/layers -> GI participation flags -> GI volume/environment coverage -> postprocess/exposure -> final camera view
```

4. For 3D flicker, blotches, or leaks, check camera movement, temporal accumulation, mesh scale, surface thickness, probe/volume bounds, and whether dynamic objects are expected to contribute or only receive GI.

5. Validate 3D changes with project-specific Godot checks first, then launch a short runtime pass if the issue is visual:

```powershell
godot --headless --path <project> --import
godot --headless --path <project> --check-only --script <script>
godot --path <project> --quit-after 8
```

Read `references/godot-3d-gi.md` before making 3D GI or material-lighting changes.

## Memory Updates

After meaningful GI edits, update project `MEMORY.md` with:

- New or changed GI files.
- Runtime flow changes.
- Whether the change affects the 2D track, 3D track, or both.
- Important Godot/RenderingDevice constraints.
- Verification commands and results.

Keep memory concise and source-grounded. Do not duplicate long shader code in memory.

## Reference

Read `references/fluidcrowd-gi.md` for 2D FluidCrowd Radiance Cascades details, current file roles, denoising notes, or patterns for agent/ranged-attack emission.

Read `references/godot-3d-gi.md` for 3D Godot GI selection, scene/material checks, and visual-debug workflow.
