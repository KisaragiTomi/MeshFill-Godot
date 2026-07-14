<#
  concept-gate.ps1  —  Claude Code PostToolUse hook (advisory / non-blocking).

  Purpose: keep project vocabulary from drifting. When an Edit/Write/MultiEdit
  introduces a NEW top-level concept that is not yet registered in the canonical
  glossary (mempalace.md), inject a reminder asking Claude to register it there
  (release definition + REGISTRY token) before the concept spreads.

  Detected "new concept" signals (high-precision, low false-positive):
    - a `class_name X` declaration whose X is not in mempalace.md's REGISTRY block
    - a `.glsl` shader file whose basename is not in the REGISTRY block

  This is ADVISORY: PostToolUse cannot block (the tool already ran). It only
  emits { hookSpecificOutput.additionalContext } so Claude sees the reminder
  and updates mempalace.md.

  FAIL-OPEN: any parse/IO error, or a missing mempalace.md, exits 0 with no
  output — a glossary hiccup must never disrupt editing. Like clean-worktrees.ps1
  this deliberately avoids $ErrorActionPreference='Stop' and guards per-op.

  Input : hook JSON on stdin (tool_name, tool_input.{file_path,new_string,content,edits}).
  Output: on a finding, one compact JSON object on stdout; else nothing.
#>

try {
    # --- read hook payload from stdin as UTF-8 ---------------------------------
    try { [Console]::InputEncoding  = [System.Text.Encoding]::UTF8 } catch {}
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    $data = $raw | ConvertFrom-Json
    $toolName = [string]$data.tool_name
    $ti = $data.tool_input
    if ($null -eq $ti) { exit 0 }

    $filePath = [string]$ti.file_path
    if ([string]::IsNullOrWhiteSpace($filePath)) { exit 0 }

    # Only gate project source: GDScript / GLSL. Ignore everything else.
    $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
    if ($ext -ne '.gd' -and $ext -ne '.glsl') { exit 0 }

    # Skip regenerated / vendored / transient trees.
    $lower = $filePath.Replace('/', '\').ToLowerInvariant()
    if ($lower -match '\\node_modules\\' -or `
        $lower -match '\\\.godot\\'      -or `
        $lower -match '\\worktrees\\') { exit 0 }

    # --- gather the newly written text ----------------------------------------
    $newText = ''
    switch ($toolName) {
        'Edit'      { $newText = [string]$ti.new_string }
        'MultiEdit' {
            if ($ti.edits) { $newText = (($ti.edits | ForEach-Object { [string]$_.new_string }) -join "`n") }
        }
        'Write' {
            if ($ti.content)        { $newText = [string]$ti.content }
            elseif ($ti.file_text)  { $newText = [string]$ti.file_text }
        }
        default {
            # Unknown tool: fall back to whatever textual fields exist.
            if ($ti.new_string) { $newText = [string]$ti.new_string }
            elseif ($ti.content){ $newText = [string]$ti.content }
        }
    }
    if ($null -eq $newText) { $newText = '' }

    # --- load the REGISTRY token set from mempalace.md ------------------------
    # Repo root = parent of the .claude/ dir this script lives in (cwd-independent).
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
    $repoRoot  = Split-Path -Parent $scriptDir
    $glossary  = Join-Path $repoRoot 'mempalace.md'
    if (-not (Test-Path -LiteralPath $glossary)) { exit 0 }   # no glossary => no gate

    $known = New-Object System.Collections.Generic.HashSet[string]
    $inReg = $false
    foreach ($line in (Get-Content -LiteralPath $glossary -Encoding UTF8)) {
        if ($line -match 'REGISTRY:BEGIN') { $inReg = $true;  continue }
        if ($line -match 'REGISTRY:END')   { $inReg = $false; break }
        if (-not $inReg) { continue }
        $t = $line.Trim()
        if ($t -eq '')                { continue }
        if ($t.StartsWith('#'))       { continue }   # comment
        if ($t.StartsWith('```'))     { continue }   # code fence
        if ($t.StartsWith('<!--'))    { continue }   # html comment
        [void]$known.Add($t)
    }
    if ($known.Count -eq 0) { exit 0 }   # registry unreadable/empty => fail-open

    # --- detect unregistered new concepts -------------------------------------
    $newClasses = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($newText, '(?m)^\s*class_name\s+([A-Za-z_][A-Za-z0-9_]*)')) {
        $name = $m.Groups[1].Value
        if (-not $known.Contains($name) -and -not $newClasses.Contains($name)) {
            [void]$newClasses.Add($name)
        }
    }

    $newShaders = New-Object System.Collections.Generic.List[string]
    if ($ext -eq '.glsl') {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
        if ($base -and -not $known.Contains($base)) { [void]$newShaders.Add($base) }
    }

    if ($newClasses.Count -eq 0 -and $newShaders.Count -eq 0) { exit 0 }

    # --- emit advisory reminder (PostToolUse additionalContext) ---------------
    $parts = @()
    if ($newClasses.Count -gt 0) { $parts += ('class_name: ' + ($newClasses -join ', ')) }
    if ($newShaders.Count -gt 0) { $parts += ('shader: '     + ($newShaders -join ', ')) }
    $joined = $parts -join '; '

    $msg = '[concept-gate] New concept(s) not registered in mempalace.md -> ' + $joined + '. ' +
           'Add a one-line definition under the matching section of mempalace.md AND add the token to ' +
           'the REGISTRY block. Follow the naming laws (word-roots / verb-directions in section 2; do not ' +
           'coin synonyms). If this renames an existing concept, update the REGISTRY token too.'

    $out = @{
        hookSpecificOutput = @{
            hookEventName     = 'PostToolUse'
            additionalContext = $msg
        }
    }
    # ConvertTo-Json (PS 5.1) escapes non-ASCII to \uXXXX => safe on any console codepage.
    $out | ConvertTo-Json -Depth 5 -Compress
    exit 0
}
catch {
    # Fail-open: never let a glossary-gate error disrupt editing.
    exit 0
}
