# PreToolUse hook: block runtime Godot launches (user rule 2026-07-14).
# Allowed forms: -e editor launch (the validation gate), --check-only parse gate,
# --version/--help. Everything else that invokes the godot binary with runtime
# flags (--headless / --script / -s / --import / --path / --rendering-driver /
# a .tscn scene) is denied. Behavior verification goes through the running
# editor's bridge (127.0.0.1:6800) instead.
#
# The command is split into statements and each is judged on its own, so an
# exemption flag in one statement (`grep -e foo; godot.exe --headless ...`)
# cannot whitelist a runtime launch in another.
$raw = [Console]::In.ReadToEnd()
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }  # fail-open on malformed payload
$cmd = [string]$payload.tool_input.command
if (-not $cmd) { exit 0 }

# Cheap pre-filter: nothing to do when the command never mentions godot at all.
if ($cmd -notmatch '(?i)godot') { exit 0 }

# A godot *invocation* token: a godot?.exe path, a bare `godot` command word, or
# a variable holding the binary (`& $godot`, `& $env:GODOT_BIN`). Deliberately
# does NOT match 'MeshFill-Godot' inside a project path (no .exe, preceded by
# '-'), so process filters / lock-file cleanup / es.exe searches stay allowed.
$godotToken = '(?i)(\$[\w:]*godot[\w:]*|godot[\w.\-]*\.exe|(^|[\s&''"(])godot(\s|$|[''"]))'
# Runtime-launch flags. `--path` counts: only a real launch passes it to godot.
$runtimeFlags = '(?i)--headless|--script|--import|--rendering-driver|--path|(^|\s)-s(\s|$)|\.tscn(\s|$|[''"])'
# Sanctioned launch forms, judged per statement.
$exempt = '(?i)(^|\s)-e(\s|$)|--check-only|--version|--help'

# Join line continuations (PowerShell backtick, POSIX backslash) so a multi-line
# launch stays one statement, then split on statement/pipeline separators.
$flat = $cmd -replace '`\r?\n', ' ' -replace '\\\r?\n', ' '
$statements = $flat -split '(?:;|&&|\|\||\||\r?\n)'

foreach ($st in $statements) {
    if ($st -notmatch $godotToken) { continue }
    if ($st -notmatch $runtimeFlags) { continue }
    if ($st -match $exempt) { continue }
    $reason = 'Runtime Godot launches are banned in this project (user rule): no --headless/--script/-s/--import/scene runs. Allowed: fresh -e editor launch and --check-only parse gate. Verify behavior via the running editor bridge (127.0.0.1:6800, tools/editor_bridge_probe.js). If a runtime run is genuinely required, ask the user for explicit permission first. Offending statement: ' + $st.Trim()
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 5
    [Console]::Out.WriteLine($out)
    exit 0
}
exit 0
