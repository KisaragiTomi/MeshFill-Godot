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

## Godot Binary Paths

- Editor (no console window): `D:\.aidata\Godot\godot-source\bin\godot.windows.editor.x86_64.exe`
- Console variant (stdout visible): `D:\.aidata\Godot\godot-source\bin\godot.windows.editor.x86_64.console.exe`
