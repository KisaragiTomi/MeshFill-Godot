param(
    [int]$IntervalSeconds = 300,
    [switch]$Once,
    [string]$ProjectRoot = "",
    [string]$GodotExe = "godot"
)

$ErrorActionPreference = "Continue"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")
} else {
    $ProjectRoot = Resolve-Path -LiteralPath $ProjectRoot
}

$LogDir = Join-Path $ProjectRoot ".automation"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$LogPath = Join-Path $LogDir "spa-interface-automation.log"
$CandidatePath = Join-Path $LogDir "spa-interface-candidates.latest.txt"
$StatusPath = Join-Path $LogDir "spa-interface-automation.latest.json"

function Write-AutomationLog {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$stamp] $Message"
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
            return
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds (50 * ($attempt + 1))
        } catch {
            return
        }
    }
}

function Invoke-LoggedCommand {
    param(
        [string]$Label,
        [string]$FilePath,
        [string[]]$Arguments
    )
    Write-AutomationLog "RUN $Label :: $FilePath $($Arguments -join ' ')"
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        Write-AutomationLog "$Label | $line"
    }
    return @{
        label = $Label
        exit_code = $exitCode
        ok = ($exitCode -eq 0)
    }
}

function Test-RequiredSpaInterface {
    param([string]$RelativePath, [string]$Pattern)
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        return @{
            ok = $false
            reason = "missing_file"
            path = $RelativePath
            pattern = $Pattern
        }
    }
    $matches = Select-String -LiteralPath $path -Pattern $Pattern -SimpleMatch -Encoding UTF8
    return @{
        ok = ($null -ne $matches)
        reason = if ($null -ne $matches) { "ok" } else { "missing_pattern" }
        path = $RelativePath
        pattern = $Pattern
    }
}

function Invoke-SpaInterfaceAutomationOnce {
    Set-Location -LiteralPath $ProjectRoot
    $started = Get-Date
    Write-AutomationLog "BEGIN spa interface automation iteration"

    $candidatePattern = "target_read_buffers_from_common|_target_color_rgba8_bytes_from_common|_target_occupancy_bytes_from_common|run_probe_prefilter|run_multi_asset|auto_voxel_runtime_profile_container|runtime_profile_container|profile_container|BrushSV|brush_sv|mesh_description|meshdescription|get_mesh_description_buffer|get_registered_mesh_descriptions|source_mesh"
    $candidateResult = Invoke-LoggedCommand `
        -Label "candidate-scan" `
        -FilePath "rg" `
        -Arguments @("-n", $candidatePattern, "scripts", "tools", "docs/core")

    if (Test-Path -LiteralPath $LogPath) {
        Select-String -LiteralPath $LogPath -Pattern "candidate-scan |" -SimpleMatch |
            Select-Object -Last 400 |
            ForEach-Object { $_.Line } |
            Set-Content -LiteralPath $CandidatePath -Encoding UTF8
    }

    $interfaceChecks = @()
    $interfaceChecks += (Test-RequiredSpaInterface -RelativePath "scripts/scene_placement_actor.gd" -Pattern "target_read_buffers_from_common")
    $interfaceChecks += (Test-RequiredSpaInterface -RelativePath "scripts/scene_placement_actor.gd" -Pattern "set_brush_sv_persistence_metadata")
    $interfaceChecks += (Test-RequiredSpaInterface -RelativePath "scripts/scene_placement_actor.gd" -Pattern "get_mesh_description_buffer")
    $interfaceChecks += (Test-RequiredSpaInterface -RelativePath "scripts/scene_placement_actor.gd" -Pattern "readback_mesh_description_debug_snapshot")
    $interfaceChecks += (Test-RequiredSpaInterface -RelativePath "tools/test_target_sv_buffer_decode.gd" -Pattern "target_read_buffers_from_common")
    $interfaceChecks += (Test-RequiredSpaInterface -RelativePath "tools/test_target_sv_buffer_decode.gd" -Pattern "get_gpu_readiness_report")
    $interfaceChecks += (Test-RequiredSpaInterface -RelativePath "tools/test_target_sv_buffer_decode.gd" -Pattern "readback_mesh_description_debug_snapshot")
    foreach ($check in $interfaceChecks) {
        Write-AutomationLog "CHECK $($check.path) pattern=$($check.pattern) ok=$($check.ok) reason=$($check.reason)"
    }

    $godotResult = Invoke-LoggedCommand `
        -Label "godot-target-spa-contract" `
        -FilePath $GodotExe `
        -Arguments @("--path", ".", "--rendering-driver", "vulkan", "--script", "tools/test_target_sv_buffer_decode.gd")

    $checksOk = -not ($interfaceChecks | Where-Object { -not $_.ok })
    $ok = [bool]($candidateResult.ok -and $checksOk -and $godotResult.ok)
    $status = [ordered]@{
        ok = $ok
        started_at = $started.ToString("o")
        finished_at = (Get-Date).ToString("o")
        interval_seconds = $IntervalSeconds
        candidate_scan = $candidateResult
        interface_checks = $interfaceChecks
        godot_test = $godotResult
        godot_exe = $GodotExe
        candidate_log = $CandidatePath
        log = $LogPath
    }
    $status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
    Write-AutomationLog "END spa interface automation iteration ok=$ok"
    return $ok
}

do {
    Invoke-SpaInterfaceAutomationOnce | Out-Null
    if ($Once) {
        break
    }
    Start-Sleep -Seconds $IntervalSeconds
} while ($true)
