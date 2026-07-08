# Auto-sweep stale Claude Code agent worktrees under .claude/worktrees so they
# don't accumulate. Wired to the SessionStart hook in .claude/settings.local.json.
#
# Safe by design — a worktree is removed ONLY when all three hold:
#   * no unmerged commits        (committed work is never discarded)
#   * inactive for >= AgeHours   (protects worktrees an agent is using right now,
#                                  including ones from a concurrent session)
#   * not git-locked             (respects an explicit `git worktree lock`)
[CmdletBinding()]
param([double]$AgeHours = 2.0)

$ErrorActionPreference = 'SilentlyContinue'

# Project root = parent of the .claude dir this script lives in.
$projectDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location -LiteralPath $projectDir

$wtRoot = Join-Path $projectDir '.claude\worktrees'
if (-not (Test-Path -LiteralPath $wtRoot)) { return }

$now = Get-Date
$headSha = (git rev-parse HEAD).Trim()
$removed = @()

Get-ChildItem -LiteralPath $wtRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $wt = $_.FullName
    $id = $_.Name
    $adminDir = Join-Path $projectDir ".git\worktrees\$id"

    # locked -> respect it, never touch.
    if (Test-Path -LiteralPath (Join-Path $adminDir 'locked')) { return }

    # last activity = newest mtime among the worktree dir and its git admin files.
    $times = @($_.LastWriteTime)
    foreach ($f in 'index', 'HEAD', 'ORIG_HEAD') {
        $p = Join-Path $adminDir $f
        if (Test-Path -LiteralPath $p) { $times += (Get-Item -LiteralPath $p).LastWriteTime }
    }
    $lastActive = ($times | Measure-Object -Maximum).Maximum
    if (($now - $lastActive).TotalHours -lt $AgeHours) { return }   # still active

    # unmerged commits -> keep (never discard committed work).
    $branch = "worktree-$id"   # worktree dir `agent-xxx` -> branch `worktree-agent-xxx`
    git show-ref --verify --quiet "refs/heads/$branch"
    if ($LASTEXITCODE -eq 0) {
        $ahead = (git rev-list --count "$headSha..$branch").Trim()
        if ([int]$ahead -gt 0) { return }
    }

    # safe to remove.
    git worktree remove --force $wt *>$null
    if (Test-Path -LiteralPath $wt) { Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue }
    git show-ref --verify --quiet "refs/heads/$branch"
    if ($LASTEXITCODE -eq 0) { git branch -D $branch *>$null }
    $removed += $id
}

git worktree prune *>$null

if ($removed.Count -gt 0) {
    Write-Output ("[worktree-cleanup] removed {0} stale agent worktree(s): {1}" -f $removed.Count, ($removed -join ', '))
}
