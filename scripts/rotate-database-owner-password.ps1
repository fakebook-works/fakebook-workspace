<#
.SYNOPSIS
    Rotates the migration/bootstrap PostgreSQL password without printing it.

.DESCRIPTION
    Writes the future .env to a temporary sibling first, changes PostgreSQL using the old
    credential, then atomically replaces .env and verifies a fresh connection. Runtime
    containers do not receive this credential; they use their seven schema-scoped roles.
#>
[CmdletBinding()]
param(
    [switch]$WritersStopped,
    [string]$EnvironmentFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dotnet = & (Join-Path $PSScriptRoot 'resolve-dotnet.ps1')
if (-not $EnvironmentFile) { $EnvironmentFile = Join-Path $root '.env' }
$EnvironmentFile = [IO.Path]::GetFullPath($EnvironmentFile)
if (-not $WritersStopped) { throw 'Pass -WritersStopped after stopping service writers.' }
if (-not (Test-Path -LiteralPath $EnvironmentFile)) { throw "Environment file not found: $EnvironmentFile" }

$bytes = [byte[]]::new(32)
$generator = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
$replacement = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

$lines = [Collections.Generic.List[string]]::new()
$found = $false
foreach ($raw in [IO.File]::ReadAllLines($EnvironmentFile)) {
    if ($raw.StartsWith('DB_PASSWORD=', [StringComparison]::Ordinal)) {
        $lines.Add("DB_PASSWORD=$replacement")
        $found = $true
    }
    else { $lines.Add($raw) }
}
if (-not $found) { throw 'DB_PASSWORD was not found in the environment file.' }

$temporaryFile = "$EnvironmentFile.rotation-$([Guid]::NewGuid().ToString('N')).tmp"
[IO.File]::WriteAllLines($temporaryFile, $lines, [Text.UTF8Encoding]::new($false))
try {
    $preflightJson = & $dotnet run --project (Join-Path $root 'scripts\Fakebook.Maintenance') -- preflight --env-file $EnvironmentFile --json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the database fingerprint.' }
    $fingerprint = ($preflightJson | ConvertFrom-Json).fingerprint

    [Environment]::SetEnvironmentVariable('NEW_DB_PASSWORD', $replacement, 'Process')
    & $dotnet run --project (Join-Path $root 'scripts\Fakebook.Maintenance') -- rotate-owner-password --writers-stopped --confirm $fingerprint --env-file $EnvironmentFile --json
    if ($LASTEXITCODE -ne 0) { throw "Database password rotation failed with exit code $LASTEXITCODE." }

    Move-Item -LiteralPath $temporaryFile -Destination $EnvironmentFile -Force
    & $dotnet run --project (Join-Path $root 'scripts\Fakebook.Maintenance') -- preflight --env-file $EnvironmentFile --json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The rotated credential could not establish a fresh database connection.' }
}
finally {
    [Environment]::SetEnvironmentVariable('NEW_DB_PASSWORD', $null, 'Process')
    if (Test-Path -LiteralPath $temporaryFile) {
        Write-Warning "The recovery environment file remains at $temporaryFile."
    }
}

Write-Host 'Migration-owner database password rotated and verified (value not displayed).'
