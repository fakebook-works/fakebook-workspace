[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Assert-ContainsLiteral {
    param(
        [string]$Content,
        [string]$Expected,
        [string]$Description
    )

    if ($Content.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) {
        throw "Local orchestration contract is missing $Description ('$Expected')."
    }
}

function Assert-DoesNotContainLiteral {
    param(
        [string]$Content,
        [string]$Unexpected,
        [string]$Description
    )

    if ($Content.IndexOf($Unexpected, [StringComparison]::Ordinal) -ge 0) {
        throw "Local orchestration still contains $Description ('$Unexpected')."
    }
}

$scriptNames = @(
    'start-local.ps1',
    'stop-local.ps1',
    'status-local.ps1',
    'smoke-local.ps1',
    'validate-environment.ps1'
)

foreach ($scriptName in $scriptNames) {
    $path = Join-Path $PSScriptRoot $scriptName
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw "$scriptName has PowerShell parse errors: $($parseErrors.Message -join '; ')"
    }
}

$projectPaths = @(
    'AuthenticationService\Backend-Authentication\fakebookAuth\fakebookAuth.csproj',
    'SocialGraphService\SocialGraph.Api\SocialGraph.Api.csproj',
    'SearchService\Backend-Search\BackEndSearchFakebook.csproj',
    'NotificationService\NotificationService\NotificationService.csproj',
    'MessengerService\MessengerService\MessengerService.csproj',
    'PaymentService\Backend-Payment\fakebookPayment\fakebookPayment.csproj',
    'UploadSever\Upload-Server\Fakebook.UploadServer.csproj',
    'APIGateway\API-Gateway\fakebookGateway\fakebookGateway.csproj',
    'APIGateway\API-Gateway\fakebookGateway\compose-fusion.ps1',
    'Frontend\Frontend\vite.config.ts'
)
foreach ($relativePath in $projectPaths) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relativePath))) {
        throw "Local orchestration path does not exist: $relativePath"
    }
}

$viteConfig = Get-Content -LiteralPath (Join-Path $root 'Frontend\Frontend\vite.config.ts') -Raw -Encoding UTF8
Assert-ContainsLiteral $viteConfig 'env.VITE_API_GATEWAY_URL' 'Vite Gateway target input'
Assert-ContainsLiteral $viteConfig 'env.VITE_GRAPHQL_GATEWAY_URL' 'Vite GraphQL target input'
Assert-ContainsLiteral $viteConfig 'env.VITE_DEV_GATEWAY_TARGET' 'Vite private Gateway target input'
Assert-ContainsLiteral $viteConfig 'env.VITE_DEV_UPLOAD_TARGET' 'Vite private Upload target input'
Assert-ContainsLiteral $viteConfig 'env.VITE_DEV_ALLOWED_HOST' 'Vite tailnet allowed host input'

$start = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'start-local.ps1') -Raw -Encoding UTF8
foreach ($contract in @(
    'ConnectionStrings__DefaultConnection',
    'ConnectionStrings__SecurityRedis',
    "New-ServiceDatabaseConnection 'AUTH'",
    "New-ServiceDatabaseConnection 'SOCIALGRAPH'",
    "New-ServiceDatabaseConnection 'SEARCH'",
    "New-ServiceDatabaseConnection 'NOTIFICATION'",
    "New-ServiceDatabaseConnection 'MESSENGER'",
    "New-ServiceDatabaseConnection 'PAYMENT'",
    "`$config['RECOMMENDATION_DB_USER']",
    'Jwt__PrivateKeyBase64',
    'Jwt__PublicKeyBase64',
    'Gateway__AuthenticationServiceSharedSecret',
    'InternalSearchService__Secret',
    'ConnectionStrings__NotificationDb',
    'InternalAuthentication__NotificationServiceSecret',
    'InternalServices__SocialGraph__SharedSecret',
    'IntegrationOutbox__PayloadEncryptionKey',
    'RECOMMENDATION_INTERNAL_SECRET',
    'SOCIAL_GRAPH_SERVICE_SECRET',
    'InternalServices__Authentication__SharedSecret',
    'InternalServices__Search__SharedSecret',
    'InternalServices__Recommendation__SharedSecret',
    'InternalServices__Messaging__SharedSecret',
    'InternalServices__Notification__SharedSecret',
    'Authentication__PaymentSecret',
    'SocialGraph__InternalSecret',
    'AuthService__Url',
    'Gateway__FusionArchivePath',
    'SMTP_ENABLE_SSL',
    'VITE_API_GATEWAY_URL',
    'VITE_GRAPHQL_GATEWAY_URL',
    'VITE_UPLOAD_SERVER_URL',
    'VITE_DEV_GATEWAY_TARGET',
    'VITE_DEV_UPLOAD_TARGET'
    'VITE_DEV_ALLOWED_HOST'
)) {
    Assert-ContainsLiteral $start $contract "environment key"
}

foreach ($url in @(
    'http://127.0.0.1:1001/health/ready',
    'http://127.0.0.1:1002/health/ready',
    'http://127.0.0.1:1003/health/ready',
    'http://127.0.0.1:1004/health/ready',
    'http://127.0.0.1:1005/health/ready',
    'http://127.0.0.1:1006/health/ready',
    'http://127.0.0.1:1007/health/ready',
    'http://127.0.0.1:2001/health/ready',
    'http://127.0.0.1:3001/',
    'http://127.0.0.1:4001/health/ready'
)) {
    Assert-ContainsLiteral $start $url "readiness URL"
}

Assert-ContainsLiteral $start 'Export SocialGraph Fusion schema' 'SocialGraph schema export before Fusion composition'
Assert-ContainsLiteral $start 'gatewaySocialGraphSchemaPath' 'SocialGraph schema copy into Gateway source schemas'
Assert-ContainsLiteral $start 'compose-fusion.ps1' 'Gateway Fusion archive composition'
Assert-DoesNotContainLiteral $start "`$config['JWT_SIGNING_KEY']" 'legacy shared JWT signer'


$status = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'status-local.ps1') -Raw -Encoding UTF8
Assert-ContainsLiteral $status 'PID reused' 'PID reuse reporting'
Assert-ContainsLiteral $status 'startedAt' 'registered process identity verification'

$stop = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'stop-local.ps1') -Raw -Encoding UTF8
Assert-ContainsLiteral $stop 'startedAt' 'safe process identity verification'

$smoke = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'smoke-local.ps1') -Raw -Encoding UTF8
Assert-DoesNotContainLiteral $smoke "'Gateway/Recommendation'" 'hidden Gateway hello smoke query'
Assert-ContainsLiteral $smoke 'Messaging rejects untrusted GraphQL callers' 'data-independent Messaging smoke check'

Write-Host 'Local orchestration contracts passed.' -ForegroundColor Green
