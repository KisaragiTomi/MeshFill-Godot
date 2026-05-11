---
description: Create new Godot 4.x projects from a standardized template with one command. Copies project.godot, fly camera from godot-source, main scene with WorldEnvironment and lighting. Use when creating new Godot project, init 3D scene, or setting up Godot workspace. Triggers: new project, create godot, init godot, new scene, godot project, create project.
---

# Godot Project Setup (Template)

## Quick Start

Run the setup script to create a new project from template:

```powershell
powershell -ExecutionPolicy Bypass -File "D:\.aidata\skills\godot-project-setup\new-godot-project.ps1" -ProjectPath "<path>" -ProjectName "<name>" -Import
```

Parameters:
- `-ProjectPath` (required): target directory
- `-ProjectName` (optional): display name, defaults to folder name
- `-Import` (optional): auto-run Godot resource import after copy
- `-Run` (optional): launch project after creation

## What the template includes

Directory `template/` is copied to target:

- `project.godot` - config with `__PROJECT_NAME__` placeholder auto-replaced
- `scenes/main.tscn` - main scene with ProceduralSky, ACES tonemap, SSAO, SSIL, DirectionalLight3D with shadows, PlaneMesh ground, Camera3D with fly_camera.gd
- `scripts/fly_camera.gd` - copied fresh from `$GODOT_SOURCE/misc/shared_scripts/fly_camera.gd` each time (fallback in template if source unavailable)
- `shaders/` - empty directory for custom shaders

### Scene node tree

Main (Node3D) contains: WorldEnvironment, Camera3D (fly_camera.gd), SunLight (DirectionalLight3D, shadow=on), Ground (100x100 PlaneMesh)

### Fly camera: RMB+mouse=rotate, WASD=move, E/Space=up, Q/Ctrl=down, Shift=sprint, scroll=dolly

## After creation

Verify by running:

```powershell
& "$env:GODOT_SOURCE\bin\godot.windows.editor.x86_64.console.exe" --path "<project>" --main-scene
```

## Rules

- Always quote paths containing spaces in --path arguments
- In .tscn files: ext_resource before sub_resource before node sections
- Use @onready + get_node() for cross-node references (more reliable than @export NodePath)
- fly_camera.gd canonical source: $GODOT_SOURCE/misc/shared_scripts/fly_camera.gd