# MeshFill-Godot — Claude Rules

## Godot Editor: Single Instance — Close the Existing One, Then Open a Fresh One

Only one editor may run at a time (the meshfill plugin enforces single-instance: a second
*simultaneous* full-editor launch, or any `--import`, while one is already running is blocked
and corrupts state).

**When you find an existing Godot process and need to (re)launch or validate: stop it first,
then open a fresh one. Do NOT reuse the running instance; close-and-reopen is the default —
you do not need to ask first.** A fresh launch reliably picks up edited `@tool` scripts and
shaders (a reused editor keeps stale in-memory versions), and closing before opening keeps it
single-instance.

**⚠ Scope every check/kill to THIS project.** Other projects' godot processes may run
concurrently on this machine (e.g. smoke tests from a parallel session on another repo);
they do not hold MeshFill's single-instance lock or port 6800, and must NOT be killed.
Never use a bare `Get-Process -Name "godot*"` sweep — filter by command line:

```powershell
# check + kill: only godot processes whose command line references this project
Get-CimInstance Win32_Process -Filter "Name like 'godot%'" |
    Where-Object { $_.CommandLine -match 'MeshFill-Godot' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
# delete a stale lock if present, then launch:
Remove-Item "$env:APPDATA\Godot\app_userdata\MeshFill-Godot\editor_instance.lock" -Force -ErrorAction SilentlyContinue
& 'D:\.aidata\Godot\godot-source\bin\godot.windows.editor.x86_64.console.exe' `
    --path 'D:\MyProject\AITest\MeshFill-Godot' -e --rendering-driver vulkan
```

Closing discards unsaved in-editor state; file edits already written to disk are safe. Mention
this if the user is likely mid-edit, but don't block on asking.

Exception — headless tool scripts don't open an editor and stay safe to run **alongside** a
running editor without closing it (e.g. `--check-only --script` parse gates, `--headless
--script tools/foo.gd`). `--import`, though, loads editor plugins and is still blocked
alongside a running editor — close first.

## Restarting Godot to Pick Up Changes

Some changes only take effect after an editor restart (addon/plugin script edits under
`addons/`, `project.godot` changes, and shader/`@tool` edits the running editor cached in
memory). Use the same close-and-reopen pattern above: stop the running editor, then launch a
fresh one. Never start a second editor alongside the first to "pick up" changes.

## Testing / Validation: `-e` Editor Launch Is the Gate

**Standard validation for any change is `-e` (editor) validation. Runtime test-suite
runs are NOT required** — do not run `tools/test_*.gd` suites (headless or Vulkan) as
routine validation; only run them when explicitly asked.

`-e` validation = launch the editor and let it load the project. The editor parses
every script on load, and the meshfill plugin TCP bridge (`127.0.0.1:6800`) coming up
means the whole project compiled. **Pass condition: editor loads with no script errors
(console output clean, bridge answers ping).**

- **If no editor is open, open one** (check first with the `Get-Process` command above):

  ```powershell
  & 'D:\.aidata\Godot\godot-source\bin\godot.windows.editor.x86_64.console.exe' `
      --path 'D:\MyProject\AITest\MeshFill-Godot' -e --rendering-driver vulkan
  ```

  Verify visuals in the viewport only when the change is visual — via screenshots or
  the bridge.
- **If an editor is already open, close it and open a fresh one** (see *Single Instance* above)
  — don't reuse the running instance; a fresh launch reliably picks up edited shaders/scripts.
- Headless runs prove nothing about behavior: no `RenderingDevice`
  (`get_rendering_device()` returns null), no viewport — a headless "PASS" only proves
  it did not crash.
- `--check-only --script <file>` is a **syntax parse gate only**; `-e` validation
  supersedes it.

## Godot Binary Paths

- Editor (no console window): `D:\.aidata\Godot\godot-source\bin\godot.windows.editor.x86_64.exe`
- Console variant (stdout visible): `D:\.aidata\Godot\godot-source\bin\godot.windows.editor.x86_64.console.exe`

## Placement / Score Demos: Render Real AssetDescriptor Assets, Never Proxy Boxes

**Any demo that visualizes *placed objects* (placement-score, placement pipeline,
scene-placement, etc.) must render the user's prepared assets — instance each
`AssetDescriptor`'s own `get_mesh()`. Never stand in synthetic proxy box shapes for
the placed objects.**

The prepared assets are `AssetDescriptor` `.tres` resources (e.g.
`res://assets/vegetation/*.tres`). Load them, drive scoring/placement from them, and
instance their real mesh at every accepted placement.

- Do **not** hardcode abstract box shapes (`ASSET_SHAPES` + colored
  `VoxelDisplay.build_from_transforms` boxes) as the placed-object visual. Those boxes
  were the old placeholder look the user rejected.
- The scoring shape comes from the asset: prefer the descriptor's own
  `get_collision()` / `voxel_profile.collision`, registered into the runtime profile
  container (whose resident `collision_records` the score/stamp shaders read); if a
  descriptor has no collision profile, derive the collision samples from its
  **mesh AABB** — do not fall back to a generic box asset.
- If no descriptor assets are found, **push a warning and place nothing** — never
  silently fall back to proxy boxes.
- `VoxelDisplay` box rendering is still fine for *field/voxel debug overlays*
  (collision/complexity/occupancy channels). This rule is about the **placed objects**
  themselves.

**Editor gotcha — descriptor methods need `@tool`.** `AssetDescriptor` (and any resource
class whose accessor methods a `@tool` demo calls at edit time) must have `@tool` at the
top. Without it, the editor loads the resource as a *placeholder* script instance:
exported **properties** are readable (a typed `Array[AssetDescriptor]` export still
populates), but **method calls** like `get_mesh()` / `get_collision()` don't execute and
return empty/fail — so `load()`-then-`get_mesh()` silently yields nothing in-editor while
working fine headless. Prefer declaring assets in the `.tscn` as an `ext_resource`
assigned to a typed `@export Array[AssetDescriptor]` (resolved by the scene loader before
`_ready`) over runtime folder-scan `load()`.

Reference implementation: [`demos/placement-score-3d/volume_score_demo.gd`](demos/placement-score-3d/volume_score_demo.gd)
(`placement_assets` export → `_load_descriptors` → `_build_asset_defs` → `_render_placements`),
and the `@tool` marker on [`scripts/asset_descriptor.gd`](scripts/asset_descriptor.gd).
