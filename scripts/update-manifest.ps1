<#
.SYNOPSIS
    Records the commit of every service repository into services.manifest.json.

.DESCRIPTION
    The services live in their own repositories, so this repository on its own cannot say
    which build of each service a given docker-compose.yaml was verified against. Running
    this after a known-good verification captures that pairing, which is what makes a
    deployment reproducible later.

    Read-only with respect to the service repositories; it only inspects them.
#>
[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root 'services.manifest.json'
}

$services = [ordered]@{
    'APIGateway'            = 'APIGateway\API-Gateway'
    'Authentication'        = 'AuthenticationService\Backend-Authentication'
    'SocialGraph'           = 'SocialGraphService'
    'Recommendation'        = 'RecommendationService\Backend-Recommendation'
    'Search'                = 'SearchService\Backend-Search'
    'Notification'          = 'NotificationService'
    'Messenger'             = 'MessengerService'
    'Payment'               = 'PaymentService\Backend-Payment'
    'UploadServer'          = 'UploadSever\Upload-Server'
    'Frontend'              = 'Frontend\Frontend'
}

$entries = [ordered]@{}
foreach ($name in $services.Keys) {
    $path = Join-Path $root $services[$name]
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning "Service '$name' not found at $path; skipping."
        continue
    }

    $commit = (& git -C $path rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Service '$name' at $path is not a git repository; skipping."
        continue
    }

    $branch = (& git -C $path rev-parse --abbrev-ref HEAD 2>$null)
    $remote = (& git -C $path remote get-url origin 2>$null)
    $dirty = (& git -C $path status --porcelain 2>$null)

    $entries[$name] = [ordered]@{
        path   = $services[$name].Replace('\', '/')
        remote = if ($LASTEXITCODE -eq 0) { $remote } else { $null }
        branch = $branch
        commit = $commit
        clean  = [string]::IsNullOrWhiteSpace(($dirty -join ''))
    }
}

$manifest = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    services       = $entries
}

$json = $manifest | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))

$unclean = $entries.Keys | Where-Object { -not $entries[$_].clean }
if ($unclean) {
    Write-Warning "Recorded with uncommitted changes: $($unclean -join ', '). The commit ids do not describe the working tree."
}

Write-Output "Wrote $OutputPath"
