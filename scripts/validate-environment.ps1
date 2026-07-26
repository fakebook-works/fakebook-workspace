[CmdletBinding()]
param(
    [string]$EnvironmentFile = (Join-Path (Split-Path -Parent $PSScriptRoot) '.env'),
    [switch]$SkipNetwork
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $EnvironmentFile)) {
    throw "Environment file was not found: $EnvironmentFile"
}

$values = @{}
Get-Content -LiteralPath $EnvironmentFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line.Length -eq 0 -or $line.StartsWith('#') -or -not $line.Contains('=')) {
        return
    }

    $parts = $line.Split('=', 2)
    $values[$parts[0]] = $parts[1]
}

if (-not $values.ContainsKey('SMTP_ENABLE_SSL') -and $values.ContainsKey('EnableSsl')) {
    $values['SMTP_ENABLE_SSL'] = $values['EnableSsl']
    Write-Warning 'EnableSsl is deprecated; rename it to SMTP_ENABLE_SSL in .env.'
}

$required = @(
    'DB_HOST', 'DB_PORT', 'DB_NAME', 'DB_USER', 'DB_PASSWORD',
    'JWT_SIGNING_KEY', 'GATEWAY_SHARED_SECRET', 'PAYMENT_AUTH_SECRET',
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
    'JWT_SIGNING_KEY', 'GATEWAY_SHARED_SECRET', 'PAYMENT_AUTH_SECRET',
    'AUTH_GATEWAY_SECRET', 'SOCIALGRAPH_GATEWAY_SECRET',
    'RECOMMENDATION_GATEWAY_SECRET', 'SEARCH_GATEWAY_SECRET',
    'NOTIFICATION_GATEWAY_SECRET', 'MESSENGER_GATEWAY_SECRET',
    'PAYMENT_GATEWAY_SECRET', 'AUTHENTICATION_INTERNAL_SECRET',
    'SOCIALGRAPH_INTERNAL_SECRET', 'SOCIALGRAPH_OUTBOX_ENCRYPTION_KEY',
    'RECOMMENDATION_INTERNAL_SECRET',
    'SEARCH_INTERNAL_SECRET', 'NOTIFICATION_INTERNAL_SECRET',
    'MESSENGER_INTERNAL_SECRET', 'UPLOAD_INTERNAL_SECRET'
)

$shortSecrets = @($secretNames | Where-Object { $values[$_].Length -lt 32 })
if ($shortSecrets.Count -gt 0) {
    throw "Secrets shorter than 32 characters: $($shortSecrets -join ', ')"
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
if (-not [uri]::TryCreate($values['TAILSCALE_ORIGIN'], [UriKind]::Absolute, [ref]$tailscaleUri) -or $tailscaleUri.Scheme -ne 'https') {
    throw 'TAILSCALE_ORIGIN must be an absolute HTTPS URL.'
}
if ($values['MEDIA_HOST'].TrimEnd('.') -ne $tailscaleUri.DnsSafeHost.TrimEnd('.')) {
    throw 'MEDIA_HOST must exactly match the hostname in TAILSCALE_ORIGIN.'
}

$localUri = $null
if (-not [uri]::TryCreate($values['LOCAL_FRONTEND_ORIGIN'], [UriKind]::Absolute, [ref]$localUri) -or $localUri.Scheme -notin 'http', 'https') {
    throw 'LOCAL_FRONTEND_ORIGIN must be an absolute HTTP or HTTPS URL.'
}

if (-not $SkipNetwork) {
    $reachable = Test-NetConnection -ComputerName $values['DB_HOST'] -Port $databasePort -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $reachable) {
        throw 'The configured PostgreSQL endpoint is not reachable over TCP.'
    }
}

Write-Host ("Environment validation passed: {0} distinct secrets, PostgreSQL configuration preserved{1}." -f $secretNames.Count, $(if ($SkipNetwork) { '' } else { ' and reachable' })) -ForegroundColor Green
