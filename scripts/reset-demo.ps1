[CmdletBinding()]
param(
    [switch]$Apply,
    [ValidateSet('Development', 'Production')]
    [string]$Environment = 'Development',
    [string]$ConfirmFingerprint,
    [switch]$WritersAreStopped,
    [switch]$AllowRemoteDevelopmentDatabase,
    [switch]$SkipBackup,
    [string]$UploadPath,
    [string]$DockerVolume,
    [switch]$SkipUploadCleanup,
    [string]$EnvFile = (Join-Path (Split-Path -Parent $PSScriptRoot) '.env')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $PSScriptRoot 'Fakebook.Maintenance\Fakebook.Maintenance.csproj'

function Import-FakebookEnv([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Environment file not found: $Path" }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $matches[1]
            $value = $matches[2].Trim().Trim('"')
            if (-not [Environment]::GetEnvironmentVariable($name)) {
                [Environment]::SetEnvironmentVariable($name, $value, 'Process')
            }
        }
    }
}

function Invoke-Maintenance([string[]]$Arguments) {
    $output = & dotnet run --project $project --no-restore -- @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Maintenance command failed with exit code $LASTEXITCODE." }
    return $output
}

Import-FakebookEnv $EnvFile
$preflightArgs = @('preflight', '--env-file', $EnvFile, '--json')
if ($UploadPath) { $preflightArgs += @('--upload-path', $UploadPath) }
if ($DockerVolume) { $preflightArgs += @('--upload-target', "docker-volume:$DockerVolume") }
$preflightLine = @(Invoke-Maintenance $preflightArgs | Where-Object { $_ -match '^\{' })[-1]
$preflight = $preflightLine | ConvertFrom-Json

Write-Host "Fakebook reset target" -ForegroundColor Cyan
[pscustomobject]@{
    Fingerprint = $preflight.fingerprint
    Host = $preflight.configuredHost
    ServerAddress = $preflight.serverAddress
    Database = $preflight.database
    DatabaseUser = $preflight.databaseUser
    Schemas = ($preflight.schemas -join ', ')
    Tables = @($preflight.tables).Count
    Rows = $preflight.totalRows
    UploadPath = $preflight.uploadPath
    UploadTarget = $preflight.uploadTarget
    UploadEntries = $preflight.uploadEntries
    Remote = $preflight.isRemote
} | Format-List

if (-not $Apply) {
    Write-Host "Dry-run only. Apply with:" -ForegroundColor Yellow
    $remoteArgument = if ($preflight.isRemote) { ' -AllowRemoteDevelopmentDatabase' } else { '' }
    $uploadArgument = if ($UploadPath) { ' -UploadPath "' + $UploadPath + '"' } elseif ($DockerVolume) { ' -DockerVolume "' + $DockerVolume + '"' } else { ' -SkipUploadCleanup' }
    Write-Host ('.\scripts\reset-demo.ps1 -Apply -Environment Development -ConfirmFingerprint {0} -WritersAreStopped{1}{2}' -f $preflight.fingerprint, $remoteArgument, $uploadArgument)
    exit 0
}

if ($Environment -eq 'Production') { throw 'Production reset is permanently refused.' }
if (-not $WritersAreStopped) { throw 'Apply requires -WritersAreStopped.' }
if ($ConfirmFingerprint -ne $preflight.fingerprint) { throw "Fingerprint mismatch. Expected $($preflight.fingerprint)." }
if ($UploadPath -and $DockerVolume) { throw 'Choose either -UploadPath or -DockerVolume, not both.' }
if (-not $UploadPath -and -not $DockerVolume -and -not $SkipUploadCleanup) { throw 'Apply requires -UploadPath, -DockerVolume, or explicit -SkipUploadCleanup.' }

if (-not $SkipBackup) {
    $pgDump = Get-Command pg_dump -ErrorAction SilentlyContinue
    if (-not $pgDump) { throw 'pg_dump is unavailable. Install PostgreSQL client tools or explicitly pass -SkipBackup.' }
    $backupDirectory = Join-Path $root '.backups'
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $backupPath = Join-Path $backupDirectory ("fakebook-before-reset-{0:yyyyMMdd-HHmmss}.dump" -f (Get-Date))
    $previousPassword = $env:PGPASSWORD
    try {
        $env:PGPASSWORD = $env:DB_PASSWORD
        $schemaArguments = @('auth','social_graph','recommendation','search','notification','messenger','payment') | ForEach-Object { @('--schema', $_) }
        $flatSchemaArguments = @($schemaArguments | ForEach-Object { $_ })
        & $pgDump.Source --host $env:DB_HOST --port $env:DB_PORT --username $env:DB_USER --dbname $env:DB_NAME --format custom --file $backupPath @flatSchemaArguments
        if ($LASTEXITCODE -ne 0) { throw "pg_dump failed with exit code $LASTEXITCODE." }
        Write-Host "Backup created: $backupPath" -ForegroundColor Green
    }
    finally { $env:PGPASSWORD = $previousPassword }
}

$applyArgs = @(
    'apply', '--env-file', $EnvFile, '--environment', $Environment,
    '--confirm', $ConfirmFingerprint, '--writers-stopped', '--json'
)
if ($AllowRemoteDevelopmentDatabase) { $applyArgs += '--allow-remote-development-database' }
if ($UploadPath) { $applyArgs += @('--upload-path', $UploadPath) }
if ($DockerVolume) { $applyArgs += @('--upload-target', "docker-volume:$DockerVolume", '--skip-upload-cleanup') }
elseif ($SkipUploadCleanup) { $applyArgs += '--skip-upload-cleanup' }

$result = @(Invoke-Maintenance $applyArgs | Where-Object { $_ -match '^\{' })[-1] | ConvertFrom-Json
if ($DockerVolume) {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { throw 'Database reset succeeded, but Docker is unavailable for named-volume cleanup.' }
    $volumeLabel = (& $docker.Source volume inspect --format '{{ index .Labels "com.docker.compose.volume" }}' $DockerVolume).Trim()
    if ($LASTEXITCODE -ne 0 -or $volumeLabel -ne 'fakebook-media-data') {
        throw "Database reset succeeded, but volume '$DockerVolume' was not verified as Fakebook media storage."
    }
    & $docker.Source run --rm -v "${DockerVolume}:/data/media" alpine:3.20 sh -c 'find /data/media -mindepth 1 -delete'
    if ($LASTEXITCODE -ne 0) { throw 'Database reset succeeded, but Docker media-volume cleanup failed.' }
}
Write-Host "Reset complete: $($result.truncatedTables) tables truncated; $($result.deletedUploadEntries) upload entries deleted." -ForegroundColor Green
