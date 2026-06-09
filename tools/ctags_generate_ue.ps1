# 生成 UE 源码的 ctags 索引（最终版）
# 运行环境：D:\UnrealEngine-5.7.4-release
# 需要 .ctags 配置文件在同目录

param(
    [switch]$IncludePlugins,
    [switch]$IncludeThirdParty
)

$ErrorActionPreference = "Stop"
$UE_ROOT = "D:\UnrealEngine-5.7.4-release"
$CTAGS = "C:\Tools\ctags.exe"

Write-Host "========================================"
Write-Host " UE Ctags Index Generator"
Write-Host "========================================"

# 检查先决条件
if (-not (Test-Path $CTAGS)) {
    Write-Host "ERROR: ctags.exe not found at $CTAGS"
    Write-Host "Download: https://github.com/universal-ctags/ctags-win32/releases/tag/v6.1.0"
    exit 1
}
if (-not (Test-Path "$UE_ROOT\.ctags")) {
    Write-Host "ERROR: .ctags config not found at $UE_ROOT\.ctags"
    exit 1
}
if (-not (Test-Path "$UE_ROOT\Engine\Source")) {
    Write-Host "ERROR: Engine/Source not found"
    exit 1
}

# 将 TMP 指向 D 盘（sort 阶段需要大空间）
$env:TMP = "D:\Temp"
$env:TEMP = "D:\Temp"
New-Item -ItemType Directory D:\Temp -Force -ErrorAction SilentlyContinue | Out-Null

# 备份旧 tags
$TAGS_FILE = "$UE_ROOT\tags"
if (Test-Path $TAGS_FILE) {
    $backup = "$UE_ROOT\tags.prev"
    Move-Item $TAGS_FILE $backup -Force
    Write-Host "Backup: tags -> tags.prev"
}

# 排除选项
$extraExcludes = @()
if (-not $IncludePlugins) {
    Write-Host "Scope: Engine/Source only (exclude Plugins)"
    $extraExcludes += "--exclude=Engine/Plugins"
} else {
    Write-Host "Scope: Engine/Source + Plugins"
}
if ($IncludeThirdParty) {
    Write-Host "Including ThirdParty"
}

Write-Host ""
Write-Host "CTags: Universal Ctags 6.1.0"
Write-Host "Config: .ctags"
Write-Host "Output: tags ($TAGS_FILE)"
Write-Host ""

$sw = [System.Diagnostics.Stopwatch]::StartNew()

Push-Location $UE_ROOT
try {
    $ctagsArgs = @(
        "--options=.ctags",
        "-f", "tags"
    ) + $extraExcludes + @(
        "--recurse"
    )

    Write-Host "Running: ctags $($ctagsArgs -join ' ')"
    Write-Host ""

    $process = Start-Process -FilePath $CTAGS -ArgumentList $ctagsArgs -NoNewWindow -Wait -PassThru
    $exitCode = $process.ExitCode
} finally {
    Pop-Location
}

$sw.Stop()

if ($exitCode -eq 0 -and (Test-Path $TAGS_FILE)) {
    $size = (Get-Item $TAGS_FILE).Length
    $sizeMB = [math]::Round($size / 1MB, 1)
    Write-Host ""
    Write-Host "========================================"
    Write-Host " SUCCESS"
    Write-Host "========================================"
    Write-Host "Size   : $sizeMB MB"
    Write-Host "Time   : $($sw.Elapsed.TotalSeconds.ToString('0.0'))s"
    Write-Host "File   : $TAGS_FILE"
    Write-Host ""
    Write-Host "To rebuild: .\tools\ctags_generate_ue.ps1"
    Write-Host "In Cursor: Ctrl+T to search symbols"
} else {
    Write-Host ""
    Write-Host "ERROR: ctags exited with code $exitCode"
}
