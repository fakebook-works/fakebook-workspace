[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$ClearTailscale
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runRoot = Join-Path $root '.run'
$processFile = Join-Path $runRoot 'local-processes.json'

function Reset-FakebookTailscaleServe {
    if (-not $ClearTailscale) {
        return
    }

    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($tailscale) {
        & $tailscale.Source serve reset
        if ($LASTEXITCODE -ne 0) {
            throw "Tailscale Serve reset failed with exit code $LASTEXITCODE."
        }
    }
}

if (-not (Test-Path -LiteralPath $processFile)) {
    if (-not $Quiet) {
        Write-Host 'No Fakebook local process registry was found.'
    }
    Reset-FakebookTailscaleServe
    return
}

$entries = Get-Content -LiteralPath $processFile -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($entry in $entries) {
    $process = Get-Process -Id ([int]$entry.id) -ErrorAction SilentlyContinue
    if (-not $process) {
        continue
    }

    try {
        $expectedStart = [datetime]::Parse($entry.startedAt).ToUniversalTime()
        $actualStart = $process.StartTime.ToUniversalTime()
    }
    catch {
        continue
    }
    if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
        if (-not $Quiet) {
            Write-Warning "Skipped PID $($entry.id) because it has been reused by another process."
        }
        continue
    }

    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    if (-not $process.WaitForExit(10000)) {
        throw "Process $($entry.name) (PID $($entry.id)) did not stop within 10 seconds."
    }
    if (-not $Quiet) {
        Write-Host "Stopped $($entry.name) (PID $($entry.id))."
    }
}

Remove-Item -LiteralPath $processFile -Force
Reset-FakebookTailscaleServe
