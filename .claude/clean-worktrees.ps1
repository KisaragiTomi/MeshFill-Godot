<#
  clean-worktrees.ps1
  Sweeps orphaned agent git worktrees left under .claude/worktrees/ by
  Claude Code agent isolation runs.

    - Removes directories under .claude/worktrees/ that `git worktree list`
      no longer tracks (true orphans).
    - Deletes dangling `worktree-agent-*` branches whose worktree is gone.
    - Runs `git worktree prune` to clear stale admin entries.

  PROTECTED: any worktree git still tracks (registered / locked) and the branch
  it has checked out are left untouched -- both are skipped explicitly. If git
  cannot enumerate worktrees at all, directory removal is skipped entirely, so a
  protected worktree is never deleted by mistake.

  Note: this script deliberately does NOT set $ErrorActionPreference = 'Stop'.
  Under Windows PowerShell 5.1 a native command writing to stderr becomes a
  terminating NativeCommandError, which would abort the cleanup loop. Default
  'Continue' plus explicit per-operation guards keeps it robust.

  Usage:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File clean-worktrees.ps1 [-DryRun]
#>
param([switch]$DryRun)

# Repo root = parent of the .claude/ dir this script lives in.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$repoRoot  = Split-Path -Parent $scriptDir
Set-Location -LiteralPath $repoRoot

$wtDir = Join-Path $repoRoot '.claude\worktrees'
if (-not (Test-Path -LiteralPath $wtDir)) { exit 0 }

function Normalize-Path([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $p = $p -replace '/', '\'
    try { $r = (Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue).Path } catch { $r = $null }
    if ($r) { $p = $r }
    return $p.ToLowerInvariant().TrimEnd('\')
}

# 1. Clear admin entries for worktrees whose dirs are already gone.
if (-not $DryRun) { git worktree prune 2>$null }

# 2. Protected sets from `git worktree list`: tracked dirs AND checked-out branches.
$registeredDirs     = @{}
$registeredBranches = @{}
foreach ($line in (git worktree list --porcelain 2>$null)) {
    if ($line -like 'worktree *') {
        $registeredDirs[(Normalize-Path $line.Substring(9))] = $true
    } elseif ($line -like 'branch *') {
        $b = ($line.Substring(7).Trim()) -replace '^refs/heads/', ''
        $registeredBranches[$b.ToLowerInvariant()] = $true
    }
}

# Safety: git must list at least the main worktree. If it returned nothing,
# bail before deleting anything -- never risk removing a protected worktree.
if ($registeredDirs.Count -eq 0) {
    Write-Output '{"systemMessage": "worktree cleanup skipped: git worktree list returned nothing"}'
    exit 0
}

# 3. Remove orphaned directories git no longer tracks.
$removed = @()
foreach ($d in (Get-ChildItem -LiteralPath $wtDir -Directory -ErrorAction SilentlyContinue)) {
    if (-not $registeredDirs.ContainsKey((Normalize-Path $d.FullName))) {
        if ($DryRun) {
            $removed += $d.Name
        } else {
            try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $removed += $d.Name } catch {}
        }
    }
}

# 4. Delete dangling worktree-agent-* branches, skipping any checked out by a
#    live worktree so git never has to error on a protected branch.
$delBranches = @()
foreach ($b in (git for-each-ref --format='%(refname:short)' 'refs/heads/worktree-agent-*' 2>$null)) {
    $b = $b.Trim()
    if ($b -and -not $registeredBranches.ContainsKey($b.ToLowerInvariant())) {
        $delBranches += $b
        if (-not $DryRun) { git branch -D $b 2>$null | Out-Null }
    }
}

# 5. Final prune for the dirs we just removed.
if (-not $DryRun) { git worktree prune 2>$null }

if ($removed.Count -gt 0 -or $delBranches.Count -gt 0) {
    $verb = if ($DryRun) { 'Would remove' } else { 'Removed' }
    $msg  = 'worktree cleanup: ' + $verb + ' ' + $removed.Count + ' orphaned dir(s) and ' + $delBranches.Count + ' dangling branch(es)'
    Write-Output ('{"systemMessage": "' + $msg + '"}')
}
exit 0
