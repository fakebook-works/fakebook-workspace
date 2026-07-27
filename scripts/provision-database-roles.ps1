<#
.SYNOPSIS
    Provisions one least-privilege PostgreSQL login per Fakebook service.

.DESCRIPTION
    Generates missing service passwords into the gitignored .env without printing them,
    renders the committed SQL template into a temporary file, applies it through the
    maintenance client, and verifies both login and effective cross-schema isolation.

    Runtime services receive data privileges only. The DB_USER/DB_PASSWORD pair remains
    the migration owner and is not passed to service containers after compose is updated.

.PARAMETER WritersStopped
    Required acknowledgement that service writers are stopped for the maintenance window.

.PARAMETER InitializeCredentials
    Adds/fixes the seven *_DB_USER variables and generates any missing, placeholder, or
    weak service password. Existing strong passwords are preserved.

.PARAMETER DemoteOwner
    After successful verification, removes SUPERUSER/CREATEDB/CREATEROLE/BYPASSRLS and
    inheritance from the fakebook migration owner. This is intentionally explicit because
    recreating a deleted runtime role later then requires a PostgreSQL administrator.
#>
[CmdletBinding()]
param(
    [switch]$WritersStopped,
    [switch]$InitializeCredentials,
    [switch]$DemoteOwner,
    [string]$EnvironmentFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dotnet = & (Join-Path $PSScriptRoot 'resolve-dotnet.ps1')
if (-not $EnvironmentFile) { $EnvironmentFile = Join-Path $root '.env' }
$EnvironmentFile = [IO.Path]::GetFullPath($EnvironmentFile)
if (-not (Test-Path -LiteralPath $EnvironmentFile)) {
    throw "Environment file not found: $EnvironmentFile"
}
if (-not $WritersStopped) {
    throw 'Pass -WritersStopped after stopping every service writer.'
}

$specifications = @(
    @{ Prefix = 'AUTH';           Role = 'fakebook_auth';           Token = 'auth' },
    @{ Prefix = 'SOCIALGRAPH';    Role = 'fakebook_social_graph';   Token = 'social_graph' },
    @{ Prefix = 'RECOMMENDATION'; Role = 'fakebook_recommendation'; Token = 'recommendation' },
    @{ Prefix = 'SEARCH';         Role = 'fakebook_search';         Token = 'search' },
    @{ Prefix = 'NOTIFICATION';   Role = 'fakebook_notification';   Token = 'notification' },
    @{ Prefix = 'MESSENGER';      Role = 'fakebook_messenger';      Token = 'messenger' },
    @{ Prefix = 'PAYMENT';        Role = 'fakebook_payment';        Token = 'payment' }
)

function Read-EnvironmentFile([string]$Path) {
    $result = @{}
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $separator = $line.IndexOf('=')
        if ($separator -le 0) { continue }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim().Trim('"')
        $result[$key] = $value
    }
    return $result
}

function Set-EnvironmentValues([string]$Path, [hashtable]$Updates) {
    $lines = [Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $separator = $raw.IndexOf('=')
        if ($separator -gt 0) {
            $key = $raw.Substring(0, $separator).Trim()
            if ($Updates.ContainsKey($key)) {
                $lines.Add("$key=$($Updates[$key])")
                $seen[$key] = $true
                continue
            }
        }
        $lines.Add($raw)
    }
    foreach ($key in $Updates.Keys | Sort-Object) {
        if (-not $seen.ContainsKey($key)) { $lines.Add("$key=$($Updates[$key])") }
    }
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

function New-StrongSecret {
    $bytes = [byte[]]::new(32)
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-StrongSecret([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match '^(replace|change[_-]?me|disabled)') { return $false }
    return [Text.Encoding]::UTF8.GetByteCount($Value) -ge 32
}

$environment = Read-EnvironmentFile $EnvironmentFile
$updates = @{}
foreach ($specification in $specifications) {
    $userKey = "$($specification.Prefix)_DB_USER"
    $passwordKey = "$($specification.Prefix)_DB_PASSWORD"
    $configuredUser = $environment[$userKey]
    $configuredPassword = $environment[$passwordKey]

    if ($configuredUser -ne $specification.Role) {
        if (-not $InitializeCredentials) {
            throw "$userKey must equal '$($specification.Role)'. Run with -InitializeCredentials."
        }
        $updates[$userKey] = $specification.Role
    }
    if (-not (Test-StrongSecret $configuredPassword)) {
        if (-not $InitializeCredentials) {
            throw "$passwordKey is missing, placeholder, or shorter than 32 UTF-8 bytes. Run with -InitializeCredentials."
        }
        $updates[$passwordKey] = New-StrongSecret
    }
}

if ($updates.Count -gt 0) {
    Set-EnvironmentValues $EnvironmentFile $updates
    Write-Host "Stored $($updates.Count) database role settings in the gitignored environment file (values not displayed)."
}

$environment = Read-EnvironmentFile $EnvironmentFile
$templatePath = Join-Path $PSScriptRoot 'sql\2026-07-27-per-service-roles.sql'
$sql = [IO.File]::ReadAllText($templatePath)
foreach ($specification in $specifications) {
    $password = [string]$environment["$($specification.Prefix)_DB_PASSWORD"]
    if (-not (Test-StrongSecret $password)) { throw "Credential validation failed after updating .env." }
    $escapedPassword = $password.Replace("'", "''")
    $sql = $sql.Replace("CHANGE_ME_$($specification.Token)", $escapedPassword)
}
if ($sql.Contains('CHANGE_ME_')) { throw 'Not every SQL credential placeholder was rendered.' }

$temporarySql = Join-Path ([IO.Path]::GetTempPath()) ("fakebook-service-roles-{0}.sql" -f [Guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($temporarySql, $sql, [Text.UTF8Encoding]::new($false))
    $maintenanceProject = Join-Path $root 'scripts\Fakebook.Maintenance'
    Write-Host 'Applying least-privilege service roles (passwords are not logged)...'
    & $dotnet run --project $maintenanceProject -- migrate --writers-stopped --file $temporarySql --env-file $EnvironmentFile
    if ($LASTEXITCODE -ne 0) { throw "Role migration failed with exit code $LASTEXITCODE." }

    Write-Host 'Verifying role attributes, login, own-schema access, and cross-schema denial...'
    & $dotnet run --project $maintenanceProject -- verify-service-roles --env-file $EnvironmentFile
    if ($LASTEXITCODE -ne 0) { throw "Role verification failed with exit code $LASTEXITCODE." }

    if ($DemoteOwner) {
        $preflightJson = & $dotnet run --project $maintenanceProject -- preflight --env-file $EnvironmentFile --json
        if ($LASTEXITCODE -ne 0) { throw 'Could not read the database fingerprint before owner demotion.' }
        $fingerprint = ($preflightJson | ConvertFrom-Json).fingerprint
        & $dotnet run --project $maintenanceProject -- demote-owner --writers-stopped --confirm $fingerprint --env-file $EnvironmentFile
        if ($LASTEXITCODE -ne 0) { throw "Owner demotion failed with exit code $LASTEXITCODE." }
    }
}
finally {
    if (Test-Path -LiteralPath $temporarySql) {
        Remove-Item -LiteralPath $temporarySql -Force
    }
}

Write-Host 'Database role provisioning completed successfully.'
