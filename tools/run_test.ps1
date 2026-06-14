# run_test.ps1 -- unified Godot script runner
#
# Always runs scripts that need RenderingDevice / compute shaders with the
# Vulkan rendering driver, so callers cannot accidentally use --headless.
#
# Usage:
#   tools/run_test.ps1 tools/test_x.gd [tools/test_y.gd ...]
#   tools/run_test.ps1 -Godot "D:\path\to\godot.exe" tools/test_x.gd
#   $env:GODOT_BIN = "D:\path\to\godot.exe"; tools/run_test.ps1 tools/test_x.gd
#
# CPU-only scripts that want headless should call godot directly, not this runner.

param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Scripts,

    [string] $Godot = "",

    [string] $RenderingDriver = "vulkan"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-GodotBinary {
    param([string] $Explicit)

    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) {
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    if ($env:GODOT_BIN -and (Test-Path -LiteralPath $env:GODOT_BIN)) {
        return (Resolve-Path -LiteralPath $env:GODOT_BIN).Path
    }
    foreach ($name in @("godot", "godot.exe", "godot.windows.editor.x86_64.console.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            return $cmd.Source
        }
    }
    throw "Godot binary not found. Pass -Godot <path> or set the GODOT_BIN environment variable."
}

# Guard: reject headless-related arguments mixed into the script list.
foreach ($s in $Scripts) {
    if ($s -match "(?i)^--?headless$") {
        throw "run_test.ps1 forbids --headless. GPU scripts must run on the Vulkan driver."
    }
}

$godotBin = Resolve-GodotBinary $Godot

$failed = @()
foreach ($script in $Scripts) {
    $scriptPath = $script
    if (-not [System.IO.Path]::IsPathRooted($scriptPath)) {
        $scriptPath = Join-Path $RepoRoot $scriptPath
    }
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Host "[SKIP] script not found: $script"
        $failed += $script
        continue
    }

    Write-Host ""
    Write-Host "=== running $script (driver=$RenderingDriver) ==="
    & $godotBin --path $RepoRoot --rendering-driver $RenderingDriver --script $scriptPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] $script (exit $LASTEXITCODE)"
        $failed += $script
    } else {
        Write-Host "[OK] $script"
    }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed scripts:"
    $failed | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host ""
Write-Host "All scripts passed."