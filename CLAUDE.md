# MeshFill-Godot — Claude Rules

## Godot Editor: Single Instance Only

**Never launch a second Godot editor instance while the user's editor is already open.**

The meshfill editor plugin enforces single-instance: a second full editor launch or any
invocation that loads editor plugins (including `--import`) will be blocked or corrupt state.

| Invocation | Loads editor plugins? | Safe alongside open editor? |
|---|---|---|
| Full editor (GUI or `--editor`) | Yes | **No — blocked** |
| `--import` | Yes | **No — blocked** |
| `--headless --script foo.gd` (SceneTree `_init`) | No | **Yes** |

**Default pattern for headless tasks:**

```powershell
& 'D:\.aidata\Godot\godot-source\bin\godot.windows.editor.x86_64.console.exe' `
    --path 'D:\MyProject\AITest\MeshFill-Godot' `
    --headless --script tools/my_script.gd
```

Before spawning any Godot process, check whether one is already running:

```powershell
Get-Process -Name "godot*" -ErrorAction SilentlyContinue
```

If a full editor is running, **only** use `--headless --script`. Never use `--import` or open
a second editor window.

## Testing / Validation: Editor Only — No Headless Tests

**Do not use headless runs to test or validate behavior.** Headless has no
`RenderingDevice` (`get_rendering_device()` returns null) and no viewport, so GPU
pipelines, scoring output, and visual results cannot be verified — a headless
`--script` test that prints "PASS" only proves it did not crash, not that the
feature works.

- **If no editor is open, open one and test in it** (check first with the
  `Get-Process` command above):

  ```powershell
  & 'D:\.aidata\Godot\godot-source\bin\godot.windows.editor.x86_64.console.exe' `
      --path 'D:\MyProject\AITest\MeshFill-Godot' --editor --rendering-driver vulkan
  ```

  Verify in the viewport — via screenshots or the meshfill plugin TCP bridge on
  `127.0.0.1:6800`.
- **If an editor is already open, use it** — never launch a second instance
  (see *Single Instance Only*).
- `--check-only --script <file>` is a **syntax parse gate only**: it is allowed,
  but it is not a behavior test and never substitutes for in-editor validation.

## Godot Binary Paths

- Editor (no console window): `D:\.aidata\Godot\godot-source\bin\godot.windows.editor.x86_64.exe`
- Console variant (stdout visible): `D:\.aidata\Godot\godot-source\bin\godot.windows.editor.x86_64.console.exe`
