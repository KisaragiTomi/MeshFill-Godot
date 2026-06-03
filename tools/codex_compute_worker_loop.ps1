param(
	[ValidateSet("Start", "Run", "Once", "Stop", "Status")]
	[string]$Mode = "Start",
	[int]$IntervalMinutes = 10,
	[string]$CodexExe = "C:\Users\19223\AppData\Local\OpenAI\Codex\bin\7dea4a003bc76627\codex.exe"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$PromptPath = Join-Path $PSScriptRoot "codex_compute_worker_prompt.md"
$StateDir = Join-Path $ProjectRoot ".codex-worker"
$LogDir = Join-Path $StateDir "logs"
$PidFile = Join-Path $StateDir "loop.pid"
$LockFile = Join-Path $StateDir "worker.lock"

function Ensure-StateDir {
	New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
	New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Get-LoopProcess {
	if (-not (Test-Path -LiteralPath $PidFile)) {
		return $null
	}
	$rawPid = (Get-Content -LiteralPath $PidFile -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -First 1)
	if ([string]::IsNullOrWhiteSpace($rawPid)) {
		return $null
	}
	$pidValue = [int]$rawPid
	return Get-Process -Id $pidValue -ErrorAction SilentlyContinue
}

function Invoke-CodexWorkerOnce {
	Ensure-StateDir

	if (-not (Test-Path -LiteralPath $CodexExe)) {
		throw "Codex executable not found: $CodexExe"
	}
	if (-not (Test-Path -LiteralPath $PromptPath)) {
		throw "Prompt file not found: $PromptPath"
	}
	if (Test-Path -LiteralPath $LockFile) {
		$lockAge = (Get-Date) - (Get-Item -LiteralPath $LockFile).LastWriteTime
		if ($lockAge.TotalHours -lt 6) {
			"[$(Get-Date -Format o)] Previous worker still locked; skipping this tick." |
				Out-File -FilePath (Join-Path $LogDir "loop.log") -Encoding UTF8 -Append
			return
		}
	}

	Set-Content -LiteralPath $LockFile -Value (Get-Date -Format o) -Encoding UTF8
	try {
		$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
		$stdout = Join-Path $LogDir "$stamp.stdout.log"
		$stderr = Join-Path $LogDir "$stamp.stderr.log"
		$final = Join-Path $LogDir "$stamp.final.md"
		$promptInput = Join-Path $LogDir "$stamp.prompt.md"
		$prompt = Get-Content -LiteralPath $PromptPath -Encoding UTF8 -Raw

		Set-Content -LiteralPath $promptInput -Value $prompt -Encoding UTF8
		$args = @(
			"--cd", $ProjectRoot,
			"--sandbox", "danger-full-access",
			"--ask-for-approval", "never",
			"exec",
			"--ephemeral",
			"--output-last-message", $final,
			"-"
		)
		$proc = Start-Process `
			-FilePath $CodexExe `
			-ArgumentList $args `
			-RedirectStandardInput $promptInput `
			-RedirectStandardOutput $stdout `
			-RedirectStandardError $stderr `
			-WindowStyle Hidden `
			-Wait `
			-PassThru

		$exitCode = $proc.ExitCode
		"[$(Get-Date -Format o)] Worker exit code: $exitCode; final: $final" |
			Out-File -FilePath (Join-Path $LogDir "loop.log") -Encoding UTF8 -Append
	} finally {
		Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
	}
}

function Start-WorkerLoop {
	Ensure-StateDir
	$existing = Get-LoopProcess
	if ($existing) {
		Write-Output "Already running: PID $($existing.Id)"
		return
	}

	$args = @(
		"-NoProfile",
		"-ExecutionPolicy", "Bypass",
		"-File", $MyInvocation.ScriptName,
		"-Mode", "Run",
		"-IntervalMinutes", $IntervalMinutes,
		"-CodexExe", $CodexExe
	)
	$proc = Start-Process -FilePath "powershell.exe" -ArgumentList $args -WindowStyle Hidden -PassThru
	Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding UTF8
	Write-Output "Started MeshFill Codex worker loop: PID $($proc.Id)"
}

function Run-WorkerLoop {
	Ensure-StateDir
	Set-Content -LiteralPath $PidFile -Value $PID -Encoding UTF8
	while ($true) {
		Invoke-CodexWorkerOnce
		Start-Sleep -Seconds ([Math]::Max(60, $IntervalMinutes * 60))
	}
}

function Stop-WorkerLoop {
	$existing = Get-LoopProcess
	if (-not $existing) {
		Write-Output "No running loop found."
		Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
		return
	}
	Stop-Process -Id $existing.Id -Force
	Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
	Write-Output "Stopped MeshFill Codex worker loop: PID $($existing.Id)"
}

function Show-WorkerStatus {
	Ensure-StateDir
	$existing = Get-LoopProcess
	if ($existing) {
		Write-Output "Running: PID $($existing.Id)"
	} else {
		Write-Output "Not running"
	}
	Write-Output "Logs: $LogDir"
	Get-ChildItem -LiteralPath $LogDir -Filter "*.final.md" -ErrorAction SilentlyContinue |
		Sort-Object LastWriteTime -Descending |
		Select-Object -First 5 FullName, LastWriteTime
}

switch ($Mode) {
	"Start" { Start-WorkerLoop }
	"Run" { Run-WorkerLoop }
	"Once" { Invoke-CodexWorkerOnce }
	"Stop" { Stop-WorkerLoop }
	"Status" { Show-WorkerStatus }
}
