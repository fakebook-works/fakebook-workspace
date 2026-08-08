[CmdletBinding()]
param(
    [string]$EnvironmentFile = (Join-Path (Split-Path -Parent $PSScriptRoot) '.env'),
    [switch]$SkipNetwork
)

$ErrorActionPreference = 'Stop'
$dotnet = & (Join-Path $PSScriptRoot 'resolve-dotnet.ps1')

if (-not (Test-Path -LiteralPath $EnvironmentFile)) {
    throw "Environment file was not found: $EnvironmentFile"
}

$values = @{}
Get-Content -LiteralPath $EnvironmentFile -Encoding UTF8 | ForEach-Object {
    $rawLine = $_
    if ($rawLine.Length -gt 65536) {
        throw 'Environment file contains an oversized line.'
    }

    $line = $rawLine.Trim()
    if ($line.Length -eq 0 -or $line.StartsWith('#') -or -not $line.Contains('=')) {
        return
    }

    $parts = $line.Split('=', 2)
    $name = $parts[0].Trim()
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') {
        throw "Environment file contains an invalid variable name: '$name'."
    }
    if ($values.ContainsKey($name)) {
        throw "Environment file contains a duplicate variable: '$name'."
    }
    $values[$name] = $parts[1]
}

if (-not $values.ContainsKey('SMTP_ENABLE_SSL') -and $values.ContainsKey('EnableSsl')) {
    $values['SMTP_ENABLE_SSL'] = $values['EnableSsl']
    Write-Warning 'EnableSsl is deprecated; rename it to SMTP_ENABLE_SSL in .env.'
}

$required = @(
    'DB_HOST', 'DB_PORT', 'DB_NAME', 'DB_USER', 'DB_PASSWORD',
    'AUTH_DB_USER', 'AUTH_DB_PASSWORD', 'SOCIALGRAPH_DB_USER', 'SOCIALGRAPH_DB_PASSWORD',
    'RECOMMENDATION_DB_USER', 'RECOMMENDATION_DB_PASSWORD', 'SEARCH_DB_USER', 'SEARCH_DB_PASSWORD',
    'NOTIFICATION_DB_USER', 'NOTIFICATION_DB_PASSWORD', 'MESSENGER_DB_USER', 'MESSENGER_DB_PASSWORD',
    'PAYMENT_DB_USER', 'PAYMENT_DB_PASSWORD',
    'JWT_PRIVATE_KEY_BASE64', 'JWT_PUBLIC_KEY_BASE64', 'JWT_KEY_ID',
    'GATEWAY_SHARED_SECRET', 'PAYMENT_AUTH_SECRET',
    'AUTH_GATEWAY_SECRET', 'SOCIALGRAPH_GATEWAY_SECRET',
    'RECOMMENDATION_GATEWAY_SECRET', 'SEARCH_GATEWAY_SECRET',
    'NOTIFICATION_GATEWAY_SECRET', 'MESSENGER_GATEWAY_SECRET',
    'PAYMENT_GATEWAY_SECRET', 'AUTHENTICATION_INTERNAL_SECRET',
    'SOCIALGRAPH_INTERNAL_SECRET', 'SOCIALGRAPH_OUTBOX_ENCRYPTION_KEY',
    'RECOMMENDATION_INTERNAL_SECRET',
    'SEARCH_INTERNAL_SECRET', 'NOTIFICATION_INTERNAL_SECRET',
    'MESSENGER_INTERNAL_SECRET', 'UPLOAD_INTERNAL_SECRET', 'TAILSCALE_ORIGIN', 'MEDIA_HOST',
    'LOCAL_FRONTEND_ORIGIN', 'EDGE_PORT', 'SMTP_ENABLED',
    'PAYMENTS_ENABLED', 'PAYOS_CLIENT_ID', 'PAYOS_API_KEY', 'PAYOS_CHECKSUM_KEY'
)

$missing = @($required | Where-Object {
    -not $values.ContainsKey($_) -or [string]::IsNullOrWhiteSpace($values[$_])
})
if ($missing.Count -gt 0) {
    throw "Missing required environment variables: $($missing -join ', ')"
}

$secretNames = @(
    'JWT_PRIVATE_KEY_BASE64', 'GATEWAY_SHARED_SECRET', 'PAYMENT_AUTH_SECRET',
    'AUTH_GATEWAY_SECRET', 'SOCIALGRAPH_GATEWAY_SECRET',
    'RECOMMENDATION_GATEWAY_SECRET', 'SEARCH_GATEWAY_SECRET',
    'NOTIFICATION_GATEWAY_SECRET', 'MESSENGER_GATEWAY_SECRET',
    'PAYMENT_GATEWAY_SECRET', 'AUTHENTICATION_INTERNAL_SECRET',
    'SOCIALGRAPH_INTERNAL_SECRET', 'SOCIALGRAPH_OUTBOX_ENCRYPTION_KEY',
    'RECOMMENDATION_INTERNAL_SECRET',
    'SEARCH_INTERNAL_SECRET', 'NOTIFICATION_INTERNAL_SECRET',
    'MESSENGER_INTERNAL_SECRET', 'UPLOAD_INTERNAL_SECRET',
    'AUTH_DB_PASSWORD', 'SOCIALGRAPH_DB_PASSWORD', 'RECOMMENDATION_DB_PASSWORD',
    'SEARCH_DB_PASSWORD', 'NOTIFICATION_DB_PASSWORD', 'MESSENGER_DB_PASSWORD', 'PAYMENT_DB_PASSWORD'
)

$shortSecrets = @($secretNames | Where-Object { $values[$_].Length -lt 32 })
if ($shortSecrets.Count -gt 0) {
    throw "Secrets shorter than 32 characters: $($shortSecrets -join ', ')"
}

$expectedDatabaseUsers = @{
    AUTH_DB_USER = 'fakebook_auth'
    SOCIALGRAPH_DB_USER = 'fakebook_social_graph'
    RECOMMENDATION_DB_USER = 'fakebook_recommendation'
    SEARCH_DB_USER = 'fakebook_search'
    NOTIFICATION_DB_USER = 'fakebook_notification'
    MESSENGER_DB_USER = 'fakebook_messenger'
    PAYMENT_DB_USER = 'fakebook_payment'
}
foreach ($entry in $expectedDatabaseUsers.GetEnumerator()) {
    if ($values[$entry.Key] -ne $entry.Value) {
        throw "$($entry.Key) must equal '$($entry.Value)'."
    }
}

$smtpEnabled = $false
if (-not [bool]::TryParse($values['SMTP_ENABLED'], [ref]$smtpEnabled)) {
    throw 'SMTP_ENABLED must be true or false.'
}

$paymentsEnabled = $false
if (-not [bool]::TryParse($values['PAYMENTS_ENABLED'], [ref]$paymentsEnabled)) {
    throw 'PAYMENTS_ENABLED must be true or false.'
}

if ($smtpEnabled) {
    $smtpRequired = @(
        'SMTP_HOST', 'SMTP_PORT', 'SMTP_ENABLE_SSL', 'SMTP_USERNAME',
        'SMTP_PASSWORD', 'SMTP_FROM_EMAIL', 'SMTP_FROM_NAME'
    )
    $missingSmtp = @($smtpRequired | Where-Object {
        -not $values.ContainsKey($_) -or [string]::IsNullOrWhiteSpace($values[$_])
    })
    if ($missingSmtp.Count -gt 0) {
        throw "SMTP is enabled but variables are missing: $($missingSmtp -join ', ')"
    }

    $smtpPort = 0
    if (-not [int]::TryParse($values['SMTP_PORT'], [ref]$smtpPort) -or $smtpPort -lt 1 -or $smtpPort -gt 65535) {
        throw 'SMTP_PORT must be an integer between 1 and 65535.'
    }

    $smtpEnableSsl = $false
    if (-not [bool]::TryParse($values['SMTP_ENABLE_SSL'], [ref]$smtpEnableSsl)) {
        throw 'SMTP_ENABLE_SSL must be true or false.'
    }
}

$secretGroups = $secretNames | Group-Object { $values[$_] } | Where-Object Count -gt 1
if ($secretGroups) {
    $duplicates = $secretGroups | ForEach-Object {
        $duplicatedValue = $_.Name
        @($secretNames | Where-Object { $values[$_] -eq $duplicatedValue }) -join '/'
    }
    throw "Secrets must be distinct: $($duplicates -join ', ')"
}

$databasePort = 0
if (-not [int]::TryParse($values['DB_PORT'], [ref]$databasePort) -or $databasePort -lt 1 -or $databasePort -gt 65535) {
    throw 'DB_PORT must be an integer between 1 and 65535.'
}

$edgePort = 0
if (-not [int]::TryParse($values['EDGE_PORT'], [ref]$edgePort) -or $edgePort -lt 1 -or $edgePort -gt 65535) {
    throw 'EDGE_PORT must be an integer between 1 and 65535.'
}

$tailscaleUri = $null
if (-not [uri]::TryCreate($values['TAILSCALE_ORIGIN'], [UriKind]::Absolute, [ref]$tailscaleUri) -or
    $tailscaleUri.Scheme -ne 'https' -or
    [string]::IsNullOrWhiteSpace($tailscaleUri.Host) -or
    -not [string]::IsNullOrEmpty($tailscaleUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($tailscaleUri.Query) -or
    -not [string]::IsNullOrEmpty($tailscaleUri.Fragment) -or
    $tailscaleUri.AbsolutePath -ne '/') {
    throw 'TAILSCALE_ORIGIN must be an HTTPS origin without credentials, path, query, or fragment.'
}
if ($values['MEDIA_HOST'].TrimEnd('.') -ne $tailscaleUri.DnsSafeHost.TrimEnd('.')) {
    throw 'MEDIA_HOST must exactly match the hostname in TAILSCALE_ORIGIN.'
}

$localUri = $null
if (-not [uri]::TryCreate($values['LOCAL_FRONTEND_ORIGIN'], [UriKind]::Absolute, [ref]$localUri) -or
    $localUri.Scheme -notin 'http', 'https' -or
    [string]::IsNullOrWhiteSpace($localUri.Host) -or
    -not [string]::IsNullOrEmpty($localUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($localUri.Query) -or
    -not [string]::IsNullOrEmpty($localUri.Fragment) -or
    $localUri.AbsolutePath -ne '/') {
    throw 'LOCAL_FRONTEND_ORIGIN must be an HTTP(S) origin without credentials, path, query, or fragment.'
}

if (-not $SkipNetwork) {
    $reachable = Test-NetConnection -ComputerName $values['DB_HOST'] -Port $databasePort -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $reachable) {
        throw 'The configured PostgreSQL endpoint is not reachable over TCP.'
    }
}


$root = Split-Path -Parent $PSScriptRoot
& $dotnet run --project (Join-Path $root 'scripts\Fakebook.Maintenance') -- generate-jwt-keys --env-file $EnvironmentFile --json | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'JWT_PRIVATE_KEY_BASE64/JWT_PUBLIC_KEY_BASE64 are invalid or do not form a matching RSA key pair.'
}

Write-Host ("Environment validation passed: {0} distinct secrets, PostgreSQL configuration preserved{1}." -f $secretNames.Count, $(if ($SkipNetwork) { '' } else { ' and reachable' })) -ForegroundColor Green
