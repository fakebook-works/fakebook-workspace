[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$environmentFile = Join-Path $root '.env'

$config = @{}
foreach ($rawLine in Get-Content -LiteralPath $environmentFile -Encoding UTF8) {
    $line = $rawLine.Trim()
    if ($line.Length -eq 0 -or $line.StartsWith('#') -or -not $line.Contains('=')) {
        continue
    }
    $parts = $line.Split('=', 2)
    $config[$parts[0]] = $parts[1]
}

function Invoke-GraphQlSmoke {
    param(
        [string]$Name,
        [string]$Url,
        [string]$Query,
        [hashtable]$Headers = @{}
    )

    $body = @{ query = $Query } | ConvertTo-Json -Compress
    $response = Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' -Headers $Headers -Body $body -TimeoutSec 15
    if ($response.errors) {
        $messages = @($response.errors | ForEach-Object message) -join '; '
        throw "$Name GraphQL smoke failed: $messages"
    }
    Write-Host "$Name GraphQL OK" -ForegroundColor Green
}

function Invoke-ExpectedHttpStatus {
    param(
        [string]$Name,
        [string]$Url,
        [int]$ExpectedStatus,
        [string]$Body
    )

    $actualStatus = $null
    try {
        $response = Invoke-WebRequest `
            -Uri $Url `
            -Method Post `
            -ContentType 'application/json' `
            -Body $Body `
            -UseBasicParsing `
            -TimeoutSec 15
        $actualStatus = [int]$response.StatusCode
    }
    catch {
        $errorResponse = $_.Exception.Response
        if ($null -eq $errorResponse) {
            throw
        }
        $actualStatus = [int]$errorResponse.StatusCode
        $errorResponse.Close()
    }

    if ($actualStatus -ne $ExpectedStatus) {
        throw "$Name returned HTTP $actualStatus; expected $ExpectedStatus."
    }

    Write-Host "$Name HTTP $ExpectedStatus OK" -ForegroundColor Green
}

$healthChecks = @(
    @{ Name = 'Authentication'; Url = 'http://127.0.0.1:1001/health/ready' },
    @{ Name = 'SocialGraph'; Url = 'http://127.0.0.1:1002/health/ready' },
    @{ Name = 'Recommendation'; Url = 'http://127.0.0.1:1003/health' },
    @{ Name = 'Search'; Url = 'http://127.0.0.1:1004/health/ready' },
    @{ Name = 'Notification'; Url = 'http://127.0.0.1:1005/health/ready' },
    @{ Name = 'Messaging'; Url = 'http://127.0.0.1:1006/health/ready' },
    @{ Name = 'Payment'; Url = 'http://127.0.0.1:1007/health/ready' },
    @{ Name = 'Gateway'; Url = 'http://127.0.0.1:2001/health/ready' },
    @{ Name = 'Frontend'; Url = 'http://127.0.0.1:3001/' },
    @{ Name = 'Upload'; Url = 'http://127.0.0.1:4001/health' }
)

foreach ($check in $healthChecks) {
    $response = Invoke-WebRequest -Uri $check.Url -UseBasicParsing -TimeoutSec 15
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 400) {
        throw "$($check.Name) health smoke returned HTTP $($response.StatusCode)."
    }
    Write-Host "$($check.Name) health OK" -ForegroundColor Green
}

Invoke-GraphQlSmoke 'Authentication' 'http://127.0.0.1:1001/graphql' 'query { __typename }'
Invoke-GraphQlSmoke 'SocialGraph' 'http://127.0.0.1:1002/graphql' 'query { __typename }' @{
    'X-Gateway-Secret' = $config['SOCIALGRAPH_GATEWAY_SECRET']
}
Invoke-GraphQlSmoke 'SocialGraph user lookup contract' 'http://127.0.0.1:1002/graphql' 'query { userById(id: 1) { id } }' @{
    'X-Gateway-Secret' = $config['SOCIALGRAPH_GATEWAY_SECRET']
    'X-User-Id' = '1'
}
Invoke-GraphQlSmoke 'Recommendation' 'http://127.0.0.1:1003/graphql' 'query { hello }' @{
    'X-Gateway-Secret' = $config['RECOMMENDATION_GATEWAY_SECRET']
}
Invoke-GraphQlSmoke 'Search' 'http://127.0.0.1:1004/graphql' 'query { fastSearch(keyword: "fakebook_smoke_no_match") { __typename } }' @{
    'X-Gateway-Secret' = $config['SEARCH_GATEWAY_SECRET']
}
Invoke-GraphQlSmoke 'Notification' 'http://127.0.0.1:1005/graphql' 'query { __typename }' @{
    'X-Gateway-Secret' = $config['NOTIFICATION_GATEWAY_SECRET']
    'X-User-Id' = '1'
}
Invoke-ExpectedHttpStatus `
    -Name 'Messaging rejects untrusted GraphQL callers' `
    -Url 'http://127.0.0.1:1006/graphql' `
    -ExpectedStatus 401 `
    -Body '{"query":"query { __typename }"}'
Invoke-GraphQlSmoke 'Payment' 'http://127.0.0.1:1007/graphql' 'query { __typename }' @{
    'X-Gateway-Secret' = $config['PAYMENT_GATEWAY_SECRET']
    'X-User-Id' = '1'
}
Invoke-GraphQlSmoke 'Gateway' 'http://127.0.0.1:2001/graphql' 'query { __typename }'
Invoke-GraphQlSmoke 'Gateway/Search' 'http://127.0.0.1:2001/graphql' 'query { fastSearch(keyword: "fakebook_smoke_no_match") { __typename } }'

Write-Host 'All local Fakebook smoke checks passed.' -ForegroundColor Green
