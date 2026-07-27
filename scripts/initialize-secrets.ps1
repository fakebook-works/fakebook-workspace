[CmdletBinding()]
param(
    [string]$EnvironmentFile = (Join-Path (Split-Path -Parent $PSScriptRoot) '.env'),
    [switch]$Rotate
)

$ErrorActionPreference = 'Stop'
$dotnet = & (Join-Path $PSScriptRoot 'resolve-dotnet.ps1')

$secretNames = @(
    'GATEWAY_SHARED_SECRET',
    'AUTH_GATEWAY_SECRET',
    'SOCIALGRAPH_GATEWAY_SECRET',
    'RECOMMENDATION_GATEWAY_SECRET',
    'SEARCH_GATEWAY_SECRET',
    'NOTIFICATION_GATEWAY_SECRET',
    'MESSENGER_GATEWAY_SECRET',
    'PAYMENT_GATEWAY_SECRET',
    'AUTHENTICATION_INTERNAL_SECRET',
    'SOCIALGRAPH_INTERNAL_SECRET',
    'SOCIALGRAPH_OUTBOX_ENCRYPTION_KEY',
    'RECOMMENDATION_INTERNAL_SECRET',
    'SEARCH_INTERNAL_SECRET',
    'NOTIFICATION_INTERNAL_SECRET',
    'MESSENGER_INTERNAL_SECRET',
    'UPLOAD_INTERNAL_SECRET',
    'PAYMENT_AUTH_SECRET'
)

function New-FakebookSecret {
    $bytes = [byte[]]::new(32)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

if (-not (Test-Path -LiteralPath $EnvironmentFile)) {
    throw "Environment file was not found: $EnvironmentFile"
}

$lines = [System.Collections.Generic.List[string]]::new()
Get-Content -LiteralPath $EnvironmentFile -Encoding UTF8 | ForEach-Object { $lines.Add($_) }

$existingIndexes = @{}
for ($index = 0; $index -lt $lines.Count; $index++) {
    $line = $lines[$index].Trim()
    if ($line.Length -eq 0 -or $line.StartsWith('#') -or -not $line.Contains('=')) {
        continue
    }

    $name = $line.Split('=', 2)[0]
    $existingIndexes[$name] = $index
}

$changed = [System.Collections.Generic.List[string]]::new()
foreach ($name in $secretNames) {
    $newValue = New-FakebookSecret
    if ($existingIndexes.ContainsKey($name)) {
        if (-not $Rotate) {
            continue
        }

        $lines[$existingIndexes[$name]] = "$name=$newValue"
        $changed.Add($name)
        continue
    }

    $lines.Add("$name=$newValue")
    $changed.Add($name)
}

if ($changed.Count -gt 0) {
    $temporaryFile = "$EnvironmentFile.tmp"
    try {
        [System.IO.File]::WriteAllLines($temporaryFile, $lines, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryFile -Destination $EnvironmentFile -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }
    Write-Host ("Initialized {0} distinct per-service secrets in {1}. Values were not printed." -f $changed.Count, $EnvironmentFile)
}
else {
    Write-Host 'All HMAC/encryption secrets are already present; no HMAC changes were made.'
}

$root = Split-Path -Parent $PSScriptRoot
$jwtArguments = @('run', '--project', (Join-Path $root 'scripts\Fakebook.Maintenance'), '--', 'generate-jwt-keys', '--env-file', $EnvironmentFile)
if ($Rotate) { $jwtArguments += '--rotate' }
& $dotnet @jwtArguments
if ($LASTEXITCODE -ne 0) { throw "JWT RSA key initialization failed with exit code $LASTEXITCODE." }
