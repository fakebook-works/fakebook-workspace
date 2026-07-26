[CmdletBinding()]
param(
    [string]$EnvironmentFile = (Join-Path (Split-Path -Parent $PSScriptRoot) '.env')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$values = @{}
foreach ($rawLine in Get-Content -LiteralPath $EnvironmentFile -Encoding UTF8) {
    $line = $rawLine.Trim()
    if ($line.Length -eq 0 -or $line.StartsWith('#') -or -not $line.Contains('=')) {
        continue
    }
    $parts = $line.Split('=', 2)
    $values[$parts[0]] = $parts[1]
}

$secretNames = @(
    'DB_PASSWORD', 'JWT_SIGNING_KEY', 'GATEWAY_SHARED_SECRET',
    'PAYMENT_AUTH_SECRET', 'AUTH_GATEWAY_SECRET',
    'SOCIALGRAPH_GATEWAY_SECRET', 'RECOMMENDATION_GATEWAY_SECRET',
    'SEARCH_GATEWAY_SECRET', 'NOTIFICATION_GATEWAY_SECRET',
    'MESSENGER_GATEWAY_SECRET', 'PAYMENT_GATEWAY_SECRET',
    'AUTHENTICATION_INTERNAL_SECRET', 'SOCIALGRAPH_INTERNAL_SECRET',
    'SOCIALGRAPH_OUTBOX_ENCRYPTION_KEY',
    'RECOMMENDATION_INTERNAL_SECRET', 'SEARCH_INTERNAL_SECRET',
    'NOTIFICATION_INTERNAL_SECRET', 'MESSENGER_INTERNAL_SECRET',
    'SMTP_PASSWORD', 'PAYOS_API_KEY', 'PAYOS_CHECKSUM_KEY'
)

$excluded = '\\(bin|obj|node_modules|dist|build|\.git|\.venv|\.tools|\.run|coverage)\\'
$extensions = '.cs', '.ts', '.tsx', '.js', '.jsx', '.py', '.md', '.json', '.yml', '.yaml', '.sql', '.ps1', '.html', '.css'
$findings = [System.Collections.Generic.List[object]]::new()

foreach ($file in Get-ChildItem $root -Recurse -File | Where-Object {
    $_.Name -ne '.env' -and
    $_.Extension -in $extensions -and
    $_.FullName -notmatch $excluded -and
    $_.Length -lt 5MB
}) {
    try {
        $content = [IO.File]::ReadAllText($file.FullName)
    }
    catch {
        continue
    }

    foreach ($name in $secretNames) {
        $value = $values[$name]
        if ($value -and $value.Length -ge 8 -and $content.Contains($value)) {
            $findings.Add([pscustomobject]@{ Secret = $name; Path = $file.FullName })
        }
    }
}

if ($findings.Count -gt 0) {
    $findings | Format-Table -AutoSize
    throw 'One or more configured secrets were found in repository text files.'
}

Write-Host 'No configured secret values were found in repository text files.' -ForegroundColor Green
