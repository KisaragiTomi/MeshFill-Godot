---
description: Lightweight Windsurf/Codex to Blender integration workflows. Use when the user wants to connect Windsurf, Codex, or project scripts to Blender without a heavy plugin: running Blender Python from the terminal, configuring Blender executable paths, live-reloading command files, or choosing between file watcher, HTTP/WebSocket bridge, and addon approaches.
---

# Blender Windsurf Link

## Default Approach

Prefer the lightest connection that gives the user the feedback loop they need:

1. **Terminal execution**: run `blender.exe --background --python script.py -- ...` from Windsurf/Codex. Best for batch rendering, `.blend` generation, and reproducible pipelines.
2. **Manual Run Script**: edit Python in Windsurf, run it from Blender's Text Editor. Best for quick experiments.
3. **File watcher**: keep Blender open, watch a command file, and execute it when Windsurf/Codex edits the file. Best lightweight interactive bridge.
4. **Local HTTP/WebSocket bridge**: run a small server inside Blender and post commands to it. Use only when file watcher is not interactive enough.
5. **Blender addon**: create a real addon only for long-lived UI panels, operators, preferences, or packaged team tools.

For most user requests asking for a "lightweight link", implement or recommend **file watcher** before HTTP/WebSocket or addon work.

## Project Path Pattern

When a project already has a configured Blender executable, reuse it everywhere instead of adding new path conventions.

For CityCraft on this machine, the known Blender path is:

```text
D:\Blender\blender-4.0.2-windows-x64\blender.exe
```

Use project-local scripts for launch entry points, and keep repo code accepting `--blender_path` overrides.

## File Watcher Workflow

Use `scripts/blender_file_watcher.py` as the starter bridge:

1. Create a command file, usually `blender_live/commands.py`, inside the project.
2. Start Blender and run the watcher script once:

```powershell
D:\Blender\blender-4.0.2-windows-x64\blender.exe --python C:\Users\KLW\.codex\skills\blender-windsurf-link\scripts\blender_file_watcher.py -- --command-file D:\path\to\project\blender_live\commands.py
```

3. Edit `commands.py` from Windsurf/Codex. Blender executes it whenever the file changes.

Command files execute inside Blender's Python process and receive normal `bpy` access. Keep them small and idempotent:

```python
import bpy

bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 1))
bpy.context.object.name = "LiveCube"
```

Use this pattern for creating objects, testing materials, moving cameras, triggering renders, or re-running a project visualization step while keeping Blender open.

## Safety Rules

- Only watch command files inside the user's active project or an explicitly requested directory.
- Do not watch broad directories recursively for code execution.
- Treat watched command files as trusted local automation. Do not run commands fetched from the network.
- Keep command files idempotent where possible: delete or update named objects before recreating them.
- For destructive Blender operations, prefer explicit object names or collections instead of clearing the whole scene unless the user requested a full reset.

## Choosing HTTP/WebSocket

Use a local server only when the user needs request/response behavior from Windsurf or another process, such as "create object and return its name", "capture viewport and return path", or "drive Blender from an external UI".

Keep it local-only by default:

```text
127.0.0.1:<port>
```

Avoid exposing Blender command execution on `0.0.0.0` unless the user explicitly understands the security implications.

## Validation

For terminal or watcher setups, validate with:

```powershell
& "D:\Blender\blender-4.0.2-windows-x64\blender.exe" --version
```

For file watcher setups, create a tiny command file that adds or renames one object, then verify Blender reports execution and the scene changes.