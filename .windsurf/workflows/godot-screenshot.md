---
description: Capture screenshots from running Godot games. FIRST CHOICE for any visual verification, UI testing, screenshot capture, or "show me the current screen" request when a Godot game is running. Trigger terms: screenshot, capture screen, visual check, UI preview, show screen, game screenshot, take screenshot.
---

# Godot Game Screenshot

Capture the current game viewport as a PNG image.

## When to Use

- User asks to see the current game screen
- Need visual verification after UI changes
- Testing UI layout, theme, or visual elements
- Any request involving screenshot or visual capture
- Before/after screen clicks to verify operations

## Method 1: TCP Screenshot (Preferred for RimWorld)

For projects with McpInteractionServer (TCP on `127.0.0.1:9090`):

```python
import socket, json, base64, pathlib

def tcp_screenshot(output="screenshots/screenshot.png"):
    s = socket.create_connection(("127.0.0.1", 9090), timeout=15)
    s.sendall(json.dumps({"command": "screenshot"}).encode() + b"\n")
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
        if b"\n" in buf:
            break
    s.close()
    result = json.loads(buf.split(b"\n")[0])
    img_b64 = result.get("data", "")
    pathlib.Path(output).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(output).write_bytes(base64.b64decode(img_b64))
    return output
```

Or use the existing tool:

```powershell
python tools/tcp_query.py screenshot screenshots/check.png
```

## Method 2: File Command System

For projects with file-command polling (e.g. SceneGenerator's `layout_loader.gd`):

```powershell
$cmd = "C:/Users/19223/AppData/Roaming/Godot/app_userdata/<ProjectName>/cmd.txt"

Set-Content -Path $cmd -Value "screenshot" -NoNewline       # current view
Set-Content -Path $cmd -Value "screenshot_all" -NoNewline   # 6 preset angles
```

Output: `<project_root>/screenshot_*.png`

Wait for terminal output `All screenshots done.` before reading files.

## Method 3: Command-Line Screenshot

For any Godot project, run headless:

```powershell
& "$env:GODOT_SOURCE\bin\godot.windows.editor.x86_64.console.exe" `
  --path "<project>" --main-scene --quit-after 2 --write-movie screenshot.png
```

## Method 4: Pawn-Following Video Capture (RimWorld)

Capture 60 frames following a specific colonist within 5 cell radius, encode to MP4:

```powershell
python tools/capture_pawn_video.py 0 screenshots/pawn_test.mp4
python tools/capture_pawn_video.py --name "Ozzy" screenshots/ozzy.mp4
```

Supports `--frames`, `--radius`, `--fps` parameters. See rimworld-autotest SKILL for details.

## Prerequisites

- Godot game must be running (for TCP and file command methods)
- TCP server on 127.0.0.1:9090 (for Method 1 & 4)
- FFmpeg installed and in PATH (for Method 4)
- Project must have a file-command polling system (for Method 2)
