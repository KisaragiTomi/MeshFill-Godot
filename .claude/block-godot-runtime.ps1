# PreToolUse hook: block runtime Godot launches (user rule 2026-07-14).
# Allowed forms: -e editor launch (the validation gate), --check-only parse gate,
# --version/--help. Everything else that invokes the godot binary with runtime
# flags (--headless / --script / -s / --import / --path / --rendering-driver /
# a .tscn scene) is denied. Behavior verification goes through the running
# editor's bridge (127.0.0.1:6800) instead.
$raw = [Console]::In.ReadToEnd()
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }  # fail-open on malformed payload
$cmd = [string]$payload.tool_input.command
if (-not $cmd) { exit 0 }
# Only care about commands that reference a godot executable (kill/filter/search
# commands mention 'godot' without '.exe' or with quotes breaking the token).
if ($cmd -notmatch '(?i)godot[^\s''"`]*\.exe') { exit 0 }
# Sanctioned exemptions.
if ($cmd -match '(^|\s)-e(\s|$)' -or $cmd -match '--check-only' -or $cmd -match '--version' -or $cmd -match '--help') { exit 0 }
# Deny only invocation-shaped commands (search tools like es.exe pass a godot
# filename as an argument but carry none of these flags).
if ($cmd -notmatch '--headless|--script|--import|--rendering-driver|--path|(^|\s)-s(\s|$)|\.tscn') { exit 0 }
$reason = 'Runtime Godot launches are banned in this project (user rule): no --headless/--script/-s/--import/scene runs. Allowed: fresh -e editor launch and --check-only parse gate. Verify behavior via the running editor bridge (127.0.0.1:6800, tools/editor_bridge_probe.js). If a runtime run is genuinely required, ask the user for explicit permission first.'
$out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 5
[Console]::Out.WriteLine($out)
exit 0
