# SessionStart hook: proactively inject the "no runtime Godot launch" rule into
# context at the very start of every session, so the agent (and any subagents it
# spawns) never even attempts a banned launch form and wastes a turn getting
# denied by the reactive block-godot-runtime.ps1 PreToolUse gate.
#
# Emits a Claude Code SessionStart `additionalContext` payload on stdout. The
# incoming stdin payload (source = startup/resume/clear) is ignored. Fails open:
# any error path emits nothing and exits 0.
try { $null = [Console]::In.ReadToEnd() } catch {}

$context = @'
[MeshFill-Godot standing rule -- Godot launch policy]
Runtime Godot launches are BANNED in this project (user rule, hook-enforced).
Do NOT launch the godot binary with --headless, --script, -s, --import, or a
scene (.tscn) path -- not even "just once to verify". A PreToolUse hook will
deny it, so trying only wastes a turn. This applies to you AND to any subagent
you spawn: if you delegate testing/verification/running, put this same rule in
the subagent's prompt.

Only two launch forms are allowed:
  1. Fresh `-e` editor launch (the validation gate): stop any existing MeshFill
     editor first, then launch a new one.
  2. `--check-only --script <file>` (parse gate -- parses only, runs nothing).

To verify BEHAVIOR, do not run a headless script. Use the running editor's
plugin bridge on 127.0.0.1:6800 (tools/editor_bridge_probe.js /
tools/golden_snapshot_check.js). A headless run proves nothing anyway: no
RenderingDevice, no viewport.

If a runtime run is genuinely unavoidable, ask the user for explicit permission
first -- do not attempt it on your own.
'@

$out = @{
    hookSpecificOutput = @{
        hookEventName    = 'SessionStart'
        additionalContext = $context
    }
} | ConvertTo-Json -Compress -Depth 5

[Console]::Out.WriteLine($out)
exit 0
