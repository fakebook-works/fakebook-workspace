[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$processFile = Join-Path $root '.run\local-processes.json'

if (-not (Test-Path -LiteralPath $processFile)) {
    Write-Host 'Fakebook local stack is not registered as running.'
    return
}

$entries = Get-Content -LiteralPath $processFile -Raw -Encoding UTF8 | ConvertFrom-Json
$rows = foreach ($entry in $entries) {
    $process = Get-Process -Id ([int]$entry.id) -ErrorAction SilentlyContinue
    $identityMatches = $false
    $status = 'Stopped'
    if ($process) {
        try {
            $expectedStart = [datetime]::Parse($entry.startedAt).ToUniversalTime()
            $actualStart = $process.StartTime.ToUniversalTime()
            $identityMatches = [Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -le 2
            $status = if ($identityMatches) { 'Running' } else { 'PID reused' }
        }
        catch {
            $status = 'Stopped'
        }
    }

    [pscustomobject]@{
        Service = $entry.name
        Port = $entry.port
        Pid = $entry.id
        Running = $identityMatches
        Status = $status
        Log = $entry.stdout
    }
}

$rows | Format-Table -AutoSize
