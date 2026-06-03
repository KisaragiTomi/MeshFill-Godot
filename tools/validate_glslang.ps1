param(
    [string[]] $Shader = @(),
    [string] $Validator = "",
    [string] $TargetEnv = "vulkan1.2",
    [switch] $KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ShaderRoot = Join-Path $RepoRoot "shaders"
$TempRoot = Join-Path $env:TEMP "meshfill-glslang"

function Find-GlslangValidator {
    param([string] $ExplicitPath)

    if ($ExplicitPath -and (Test-Path -LiteralPath $ExplicitPath)) {
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    $cmd = Get-Command glslangValidator -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }

    $candidates = @()
    if ($env:VULKAN_SDK) {
        $candidates += (Join-Path $env:VULKAN_SDK "Bin\glslangValidator.exe")
    }
    $candidates += @(
        "C:\Program Files\RenderDoc\plugins\spirv\glslangValidator.exe",
        "D:\Program Files\Side Effects Software\Houdini 20.0.724\bin\glslangValidator.exe",
        "D:\UnrealEngine-5.7.4-release\Engine\Binaries\ThirdParty\glslang\glslangValidator.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "glslangValidator.exe was not found. Install Vulkan SDK or pass -Validator <path>."
}

function Get-ShaderInputs {
    param([string[]] $InputPaths)

    if ($InputPaths.Count -gt 0) {
        $expandedInputs = @()
        foreach ($inputPath in $InputPaths) {
            $expandedInputs += ($inputPath -split "," | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        return $expandedInputs | ForEach-Object {
            $path = $_
            if (-not [System.IO.Path]::IsPathRooted($path)) {
                $path = Join-Path $RepoRoot $path
            }
            Get-Item -LiteralPath $path
        }
    }

    return Get-ChildItem -LiteralPath $ShaderRoot -Filter "*.glsl" -File | Sort-Object Name
}

function Convert-ToGlslangInput {
    param(
        [System.IO.FileInfo] $Source,
        [string] $Destination
    )

    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $Source.FullName
    $text = $text -replace "(?m)^\s*#\[compute\]\s*\r?\n?", ""
    Set-Content -Encoding UTF8 -LiteralPath $Destination -Value $text
}

function Get-DisplayPath {
    param([string] $FullPath)

    $root = $RepoRoot.Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ($FullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }
    return $FullPath
}

$validatorPath = Find-GlslangValidator $Validator
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

$shaderFiles = @(Get-ShaderInputs $Shader)
if ($shaderFiles.Count -eq 0) {
    Write-Host "No GLSL shaders found."
    exit 0
}

Write-Host "glslangValidator: $validatorPath"
Write-Host "target-env: $TargetEnv"

$failed = @()
foreach ($shaderPath in $shaderFiles) {
    $source = Get-Item -LiteralPath $shaderPath.FullName
    $relative = Get-DisplayPath $source.FullName
    $tempSource = Join-Path $TempRoot ($source.BaseName + ".comp.glsl")
    $spvOut = Join-Path $TempRoot ($source.BaseName + ".spv")

    Convert-ToGlslangInput $source $tempSource

    $args = @(
        "-V",
        "--target-env", $TargetEnv,
        "-S", "comp",
        "-I$ShaderRoot",
        "-o", $spvOut,
        $tempSource
    )
    $output = & $validatorPath @args 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] $relative"
    } else {
        Write-Host "[FAIL] $relative"
        if ($output) {
            $output | ForEach-Object { Write-Host "  $_" }
        }
        $failed += $relative
    }
}

if (-not $KeepTemp) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed shaders:"
    $failed | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host ""
Write-Host "All shaders passed glslang validation."
