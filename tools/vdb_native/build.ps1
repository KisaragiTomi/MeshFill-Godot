# Build vdb_to_voxels.exe against Houdini's OpenVDB (openvdb_sesi) using MSVC, then copy
# OpenVDB's runtime DLLs next to the exe so it is SELF-CONTAINED — it reads a .vdb with NO
# Houdini install required at runtime (Windows loads DLLs from the exe's own directory
# first). openvdb_sesi.dll's only non-system deps are tbb / blosc / zlib1 (verified via
# dumpbin), which get copied too. Houdini's SDK is used only to BUILD, not to run.
#
# Usage:  powershell -ExecutionPolicy Bypass -File tools/vdb_native/build.ps1
#         [-Hfs "D:/Program Files/Side Effects Software/Houdini 20.0.724"]
param(
    [string]$Hfs = "D:/Program Files/Side Effects Software/Houdini 20.0.724"
)
$ErrorActionPreference = "Stop"

# OpenVDB runtime DLLs bundled next to the exe (self-contained, no Houdini at runtime).
$RuntimeDlls = @("openvdb_sesi.dll", "tbb.dll", "blosc.dll", "zlib1.dll")

$src = Join-Path $PSScriptRoot "vdb_to_voxels.cpp"
$out = Join-Path $PSScriptRoot "vdb_to_voxels.exe"
$inc = Join-Path $Hfs "toolkit\include"
$libdir = Join-Path $Hfs "custom\houdini\dsolib"

foreach ($p in @($src, $inc, $libdir)) {
    if (-not (Test-Path $p)) { throw "missing: $p" }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere not found: $vswhere" }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw "no Visual Studio with the C++ toolset (VC.Tools.x86.x64) found" }
$vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found: $vcvars" }

# Generate a .bat so all the space-containing paths keep stable quoting (nesting quotes
# through `cmd /c "<string>"` mangles them). /MD makes _DLL defined -> OpenVDB's
# Platform.h auto-selects dllimport (matches openvdb_sesi.dll). C++17 required by OpenVDB 10.
$obj = Join-Path $PSScriptRoot "vdb_to_voxels.obj"
$bat = Join-Path $PSScriptRoot "_build.bat"
# NB: give /Fo and /Fe FULL file paths (no trailing backslash) — a `\"` at the end of a
# quoted arg escapes the quote and corrupts the rest of the command line.
$lines = @(
    '@echo off',
    "call `"$vcvars`"",
    "cl /nologo /utf-8 /std:c++17 /EHsc /O2 /MD /DNOMINMAX /D_USE_MATH_DEFINES /I`"$inc`" /Fo`"$obj`" `"$src`" /Fe`"$out`" /link /LIBPATH:`"$libdir`" openvdb_sesi.lib tbb.lib"
)
Set-Content -Path $bat -Value $lines -Encoding ASCII

Write-Host "Compiling vdb_to_voxels.exe ..." -ForegroundColor Cyan
& cmd /c $bat
$rc = $LASTEXITCODE

Remove-Item (Join-Path $PSScriptRoot "vdb_to_voxels.obj") -ErrorAction SilentlyContinue
Remove-Item $bat -ErrorAction SilentlyContinue
if ($rc -ne 0) { throw "build failed (exit $rc)" }
if (-not (Test-Path $out)) { throw "cl reported success but $out is missing" }

# Bundle OpenVDB's runtime DLLs next to the exe so it runs with no Houdini install.
$binDir = Join-Path $Hfs "bin"
foreach ($dll in $RuntimeDlls) {
    $srcDll = Join-Path $binDir $dll
    if (-not (Test-Path $srcDll)) { throw "runtime DLL missing: $srcDll" }
    Copy-Item $srcDll (Join-Path $PSScriptRoot $dll) -Force
}
Write-Host "OK -> $out (+ bundled $($RuntimeDlls.Count) DLLs: $($RuntimeDlls -join ', '))" -ForegroundColor Green
