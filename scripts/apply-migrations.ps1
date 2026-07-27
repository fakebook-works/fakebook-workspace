<#
.SYNOPSIS
    Applies the services' SQL migration files to the configured database.

.DESCRIPTION
    The migration files under each service's migrations/ folder are plain SQL and were
    documented as "run this with psql". psql is not installed on every workstation, and
    when it is missing the command simply fails — which looks the same as having applied
    cleanly. This wrapper runs them through scripts/Fakebook.Maintenance instead, which
    already carries the Npgsql client and reads the same .env.

    Windows PowerShell 5.1 cannot load the .NET 8 Npgsql assembly directly, which is why
    this delegates rather than connecting itself.

    Do not confuse this with Fakebook.Maintenance's own "apply" command: that TRUNCATEs
    the managed schemas as part of a demo reset and will destroy data.

.PARAMETER File
    The .sql files to apply. Required: there is no migration history table, so nothing can
    tell which files have already run, and the older ones are not re-runnable — one still
    targets the "fb" schema that a later migration renamed to "auth". Run with no files to
    list what is available.

.PARAMETER WritersStopped
    Required acknowledgement that the services are stopped. Index builds lock the tables
    they touch, so applying them under load is a decision rather than a default.

.EXAMPLE
    # List what is available
    .\scripts\apply-migrations.ps1 -WritersStopped

    # Apply specific files
    .\scripts\stop-local.ps1
    .\scripts\apply-migrations.ps1 -WritersStopped -File `
        .\SocialGraphService\SocialGraph.Api\migrations\20260727_add_hot_path_indexes.sql, `
        .\AuthenticationService\Backend-Authentication\fakebookAuth\migrations\20260727_add_login_path_indexes.sql
#>
[CmdletBinding()]
param(
    [string[]]$File,
    [switch]$WritersStopped,
    [string]$EnvironmentFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $WritersStopped) {
    throw "Pass -WritersStopped to confirm the services are stopped. Index builds lock the tables they touch."
}

$arguments = @('run', '--project', (Join-Path $root 'scripts\Fakebook.Maintenance'), '--', 'migrate', '--writers-stopped')
foreach ($item in $File) {
    $arguments += @('--file', (Resolve-Path -LiteralPath $item).Path)
}
# Always passed explicitly: dotnet run does not set the working directory to the
# workspace, so the tool cannot find .env on its own.
if (-not $EnvironmentFile) { $EnvironmentFile = Join-Path $root '.env' }
if (-not (Test-Path -LiteralPath $EnvironmentFile)) { throw "Environment file not found: $EnvironmentFile" }
$arguments += @('--env-file', (Resolve-Path -LiteralPath $EnvironmentFile).Path)

Write-Host "Applying migrations via Fakebook.Maintenance..."
& dotnet @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Migration run failed with exit code $LASTEXITCODE."
}

Write-Host ""
Write-Host 'Verify with the catalog, for example:'
Write-Host "  SELECT indexname FROM pg_indexes WHERE schemaname IN ('social_graph','auth') ORDER BY 1;"
