[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Read-WorkspaceText([string]$RelativePath) {
    $path = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required API security artifact is missing: $RelativePath"
    }
    return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
}

function Assert-ContainsLiteral(
    [string]$Content,
    [string]$Expected,
    [string]$Description
) {
    if ($Content.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) {
        throw "API security contract is missing $Description ('$Expected')."
    }
}

function Assert-DoesNotContainLiteral(
    [string]$Content,
    [string]$Unexpected,
    [string]$Description
) {
    if ($Content.IndexOf($Unexpected, [StringComparison]::Ordinal) -ge 0) {
        throw "API security contract contains forbidden $Description ('$Unexpected')."
    }
}

function Assert-LiteralCount(
    [string]$Content,
    [string]$Literal,
    [int]$Expected,
    [string]$Description
) {
    $count = ([regex]::Matches($Content, [regex]::Escape($Literal))).Count
    if ($count -ne $Expected) {
        throw "API security contract expected $Expected occurrence(s) of $Description, found $count."
    }
}

$requiredDocuments = @(
    'AGENTS.md',
    'CLAUDE.md',
    'docs\api-security-contract.md',
    'docs\internal-request-signing.md',
    'secure.md',
    'APIGateway\API-Gateway\AGENTS.md',
    'AuthenticationService\Backend-Authentication\AGENTS.md',
    'Frontend\Frontend\AGENTS.md',
    'MessengerService\AGENTS.md',
    'NotificationService\AGENTS.md',
    'PaymentService\Backend-Payment\AGENTS.md',
    'RecommendationService\Backend-Recommendation\AGENTS.md',
    'SearchService\Backend-Search\AGENTS.md',
    'SocialGraphService\AGENTS.md',
    'UploadSever\Upload-Server\AGENTS.md'
)
foreach ($document in $requiredDocuments) {
    Read-WorkspaceText $document | Out-Null
}

# The .NET signing implementation is intentionally copied into independently built
# services. Drift creates cross-service replay/compatibility bugs, so all copies must
# remain byte-identical and use the distributed, fail-closed nonce store.
$signingFiles = @(
    'AuthenticationService\Backend-Authentication\fakebookAuth\Security\InternalRequestSigning.cs',
    'SocialGraphService\SocialGraph.Api\Infrastructure\InternalRequestSigning.cs',
    'SearchService\Backend-Search\Infrastructure\Security\InternalRequestSigning.cs',
    'NotificationService\NotificationService\Security\InternalRequestSigning.cs',
    'MessengerService\MessengerService\Infrastructure\Security\InternalRequestSigning.cs',
    'PaymentService\Backend-Payment\fakebookPayment\Security\InternalRequestSigning.cs',
    'UploadSever\Upload-Server\InternalRequestSigning.cs'
)
$signingHashes = foreach ($relativePath in $signingFiles) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Internal signing implementation is missing: $relativePath"
    }
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
if (@($signingHashes | Sort-Object -Unique).Count -ne 1) {
    throw 'The seven .NET internal request-signing implementations have drifted.'
}

$signing = Read-WorkspaceText $signingFiles[0]
foreach ($contract in @(
    'StringSetAsync(',
    'When.NotExists',
    'InternalNonceClaimResult.Unavailable',
    'StatusCodes.Status503ServiceUnavailable',
    'ConnectionStrings:SecurityRedis is required when internal signatures are required.'
)) {
    Assert-ContainsLiteral $signing $contract 'distributed fail-closed replay protection'
}

$pythonSigning = Read-WorkspaceText 'RecommendationService\Backend-Recommendation\ForFakebook\internal_signing.py'
foreach ($contract in @('nx=True', 'ex=retention', 'UNAVAILABLE = "unavailable"')) {
    Assert-ContainsLiteral $pythonSigning $contract 'Python distributed replay protection'
}
$pythonApi = Read-WorkspaceText 'RecommendationService\Backend-Recommendation\ForFakebook\EmbeddingModel.py'
Assert-ContainsLiteral $pythonApi 'INTERNAL_REPLAY_PROTECTION_UNAVAILABLE' 'Python fail-closed replay response'
Assert-ContainsLiteral $pythonApi 'recommendation_schema_is_ready' 'Recommendation migration readiness check'
$recommendationDatabase = Read-WorkspaceText 'RecommendationService\Backend-Recommendation\ForFakebook\database.py'
Assert-DoesNotContainLiteral $recommendationDatabase 'CREATE TABLE' 'Recommendation runtime table DDL'
Assert-DoesNotContainLiteral $recommendationDatabase 'CREATE INDEX' 'Recommendation runtime index DDL'

$deployCompose = Read-WorkspaceText 'docker-compose.yaml'
Assert-LiteralCount $deployCompose 'InternalAuth__RequireSignature: "true"' 7 'deploy signature enforcement'
Assert-LiteralCount $deployCompose 'InternalAuth__SendLegacySecret: "false"' 7 'deploy legacy-secret transmission disablement'
Assert-LiteralCount $deployCompose 'DatabaseMigrations__Enabled: "false"' 3 'deploy .NET startup migration disablement'
Assert-LiteralCount $deployCompose 'RECOMMENDATION_DB_MIGRATIONS_ENABLED: "false"' 1 'deploy Recommendation startup migration disablement'
Assert-LiteralCount $deployCompose 'Database__ApplySchemaOnStartup: "false"' 2 'deploy Search/Payment startup migration disablement'
Assert-LiteralCount $deployCompose 'Database__ApplyMigrationsOnStartup: "false"' 1 'deploy Notification startup migration disablement'
Assert-LiteralCount $deployCompose 'ConnectionStrings__SecurityRedis: redis:6379' 6 'deploy .NET security Redis wiring'
Assert-LiteralCount $deployCompose 'SECURITY_REDIS_URL: redis://redis:6379/0' 1 'deploy Python security Redis wiring'
Assert-LiteralCount $deployCompose 'Jwt__PrivateKeyBase64:' 1 'deploy Auth-only JWT private key'
Assert-LiteralCount $deployCompose 'Jwt__PublicKeyBase64:' 2 'deploy Gateway/Upload JWT public key'
Assert-LiteralCount $deployCompose 'pull_policy: always' 10 'prebuilt application image pull policy'
Assert-DoesNotContainLiteral $deployCompose '    build:' 'source build in the GHCR deployment compose'
Assert-DoesNotContainLiteral $deployCompose 'dockerfile:' 'Dockerfile reference in the GHCR deployment compose'
Assert-DoesNotContainLiteral $deployCompose 'Jwt__SigningKey:' 'deploy legacy fleet-wide JWT signer'
Assert-DoesNotContainLiteral $deployCompose ('Username=$' + '{DB_USER}') 'deploy migration owner in runtime connection strings'
Assert-DoesNotContainLiteral $deployCompose ('Password=$' + '{DB_PASSWORD}') 'deploy migration owner in runtime connection strings'
Assert-DoesNotContainLiteral $deployCompose 'TAILSCALE_ORIGIN' 'development-only Tailscale origin in deploy configuration'
Assert-DoesNotContainLiteral $deployCompose 'Tailscale' 'development-only Tailscale documentation in deploy configuration'
Assert-DoesNotContainLiteral $deployCompose 'tailnet' 'development-only tailnet documentation in deploy configuration'
Assert-ContainsLiteral $deployCompose '${PUBLIC_ORIGIN:?Set PUBLIC_ORIGIN in .env}' 'operator-managed HTTPS deploy origin'
Assert-ContainsLiteral $deployCompose '${EDGE_BIND_ADDRESS:-127.0.0.1}:${EDGE_PORT:-8080}:80' 'loopback-safe deploy edge binding'

$hostCompose = Read-WorkspaceText 'fixdeploy\compose.yaml'
Assert-LiteralCount $hostCompose 'DatabaseMigrations__Enabled: "false"' 3 'host .NET startup migration disablement'
Assert-LiteralCount $hostCompose 'RECOMMENDATION_DB_MIGRATIONS_ENABLED: "false"' 1 'host Recommendation startup migration disablement'
Assert-LiteralCount $hostCompose 'Database__ApplySchemaOnStartup: "false"' 2 'host Search/Payment startup migration disablement'
Assert-LiteralCount $hostCompose 'Database__ApplyMigrationsOnStartup: "false"' 1 'host Notification startup migration disablement'
foreach ($subgraphVariable in @(
    'GATEWAY_AUTHENTICATION_SUBGRAPH_URL',
    'GATEWAY_SOCIALGRAPH_SUBGRAPH_URL',
    'GATEWAY_RECOMMENDATION_SUBGRAPH_URL',
    'GATEWAY_SEARCH_SUBGRAPH_URL',
    'GATEWAY_NOTIFICATION_SUBGRAPH_URL',
    'GATEWAY_MESSAGING_SUBGRAPH_URL',
    'GATEWAY_PAYMENT_SUBGRAPH_URL'
)) {
    Assert-ContainsLiteral $deployCompose $subgraphVariable "runtime Gateway endpoint override $subgraphVariable"
}
foreach ($image in @(
    'ghcr.io/fakebook-works/backend-authentication:',
    'ghcr.io/fakebook-works/backend-socialgraph:',
    'ghcr.io/fakebook-works/backend-recommendation:',
    'ghcr.io/fakebook-works/backend-search:',
    'ghcr.io/fakebook-works/backend-notification:',
    'ghcr.io/fakebook-works/backend-messaging:',
    'ghcr.io/fakebook-works/backend-payment:',
    'ghcr.io/fakebook-works/api-gateway:',
    'ghcr.io/fakebook-works/upload-server:',
    'ghcr.io/fakebook-works/frontend:'
)) {
    Assert-ContainsLiteral $deployCompose $image "GHCR image $image"
}

$gatewayProgram = Read-WorkspaceText 'APIGateway\API-Gateway\fakebookGateway\Program.cs'
foreach ($contract in @(
    'AddMaxExecutionDepthRule',
    'AddMaxAllowedFieldCycleDepthRule',
    'MaxAllowedFields',
    'MaxExpandedNodes',
    'SecurityAlgorithms.RsaSha256',
    'ValidAlgorithms',
    'options.Tool.Enable = app.Environment.IsDevelopment()'
)) {
    Assert-ContainsLiteral $gatewayProgram $contract 'Gateway GraphQL/JWT enforcement'
}
$gatewayEndpointHandler = Read-WorkspaceText 'APIGateway\API-Gateway\fakebookGateway\Gateway\FusionSubgraphEndpointHandler.cs'
Assert-ContainsLiteral $gatewayEndpointHandler 'request.RequestUri = endpoint.Uri' 'runtime Fusion endpoint override'
$gatewayEndpointOptions = Read-WorkspaceText 'APIGateway\API-Gateway\fakebookGateway\Gateway\SubgraphEndpointsOptions.cs'
foreach ($endpoint in 1001..1007) {
    Assert-ContainsLiteral $gatewayEndpointOptions "http://127.0.0.1:$endpoint/graphql" "canonical loopback subgraph port $endpoint"
}
$gatewayEdge = Read-WorkspaceText 'APIGateway\API-Gateway\fakebookGateway\Gateway\GatewayEdgeMiddleware.cs'
Assert-ContainsLiteral $gatewayEdge 'context.Request.Headers.Remove(header)' 'browser trusted-header stripping'
Assert-ContainsLiteral $gatewayEdge 'Closing realtime stream for revoked session' 'realtime session revalidation'

foreach ($programPath in @(
    'AuthenticationService\Backend-Authentication\fakebookAuth\Program.cs',
    'SocialGraphService\SocialGraph.Api\Program.cs',
    'SearchService\Backend-Search\Program.cs',
    'NotificationService\NotificationService\Program.cs',
    'MessengerService\MessengerService\Program.cs',
    'UploadSever\Upload-Server\Program.cs'
)) {
    $program = Read-WorkspaceText $programPath
    Assert-ContainsLiteral $program 'UseMiddleware<InternalRequestSignatureMiddleware>()' "incoming signature middleware in $programPath"
}

$authSecurity = Read-WorkspaceText 'AuthenticationService\Backend-Authentication\fakebookAuth\Security\SecurityServices.cs'
foreach ($contract in @(
    'ConcurrencyLimiter',
    'JwtSecurityTokenHandler',
    'TokenValidationParameters',
    'AlgorithmValidator = ValidateAlgorithm',
    'SecurityAlgorithms.RsaSha256'
)) {
    Assert-ContainsLiteral $authSecurity $contract 'bounded password/JWT security'
}
$bcryptFiles = @(Get-ChildItem (Join-Path $root 'AuthenticationService\Backend-Authentication\fakebookAuth') -Recurse -File -Filter *.cs |
    Select-String -SimpleMatch 'BCrypt.Net.BCrypt' |
    ForEach-Object Path |
    Sort-Object -Unique)
$expectedBcryptPath = [IO.Path]::GetFullPath(
    (Join-Path $root 'AuthenticationService\Backend-Authentication\fakebookAuth\Security\SecurityServices.cs'))
if (@($bcryptFiles).Count -ne 1 -or
    -not [IO.Path]::GetFullPath($bcryptFiles[0]).Equals($expectedBcryptPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'BCrypt calls must remain isolated behind the bounded IPasswordHasher implementation.'
}

$observabilityFiles = @(
    'AuthenticationService\Backend-Authentication\fakebookAuth\Observability\FakebookServiceDefaults.cs',
    'SocialGraphService\SocialGraph.Api\Observability\FakebookServiceDefaults.cs',
    'SearchService\Backend-Search\Infrastructure\Observability\FakebookServiceDefaults.cs',
    'NotificationService\NotificationService\Observability\FakebookServiceDefaults.cs',
    'MessengerService\MessengerService\Observability\FakebookServiceDefaults.cs',
    'PaymentService\Backend-Payment\fakebookPayment\Observability\FakebookServiceDefaults.cs',
    'UploadSever\Upload-Server\Observability\FakebookServiceDefaults.cs',
    'APIGateway\API-Gateway\fakebookGateway\Observability\FakebookServiceDefaults.cs'
)
foreach ($relativePath in $observabilityFiles) {
    $content = Read-WorkspaceText $relativePath
    Assert-ContainsLiteral $content 'DisableForUnsafeHttpMethods()' "safe-method retry policy in $relativePath"
}

$socialProgram = Read-WorkspaceText 'SocialGraphService\SocialGraph.Api\Program.cs'
Assert-ContainsLiteral $socialProgram 'BlockVisibilityService' 'central SocialGraph block policy registration'
Assert-ContainsLiteral $socialProgram 'UserProvisioningCoordinator' 'registration saga registration'
$socialOutbox = Read-WorkspaceText 'SocialGraphService\SocialGraph.Api\Infrastructure\Outbox\IntegrationOutboxPublisher.cs'
Assert-ContainsLiteral $socialOutbox '_payloadProtector.Protect' 'outbox payload protection'
foreach ($test in @(
    'SocialGraphService\tests\SocialGraph.Api.Tests\BlockVisibilityRegressionTests.cs',
    'SocialGraphService\tests\SocialGraph.Api.Tests\DistributedNonceValidationTests.cs',
    'SocialGraphService\tests\SocialGraph.Api.Tests\UserProvisioningCoordinatorTests.cs'
)) {
    Read-WorkspaceText $test | Out-Null
}

$upload = Read-WorkspaceText 'UploadSever\Upload-Server\Program.cs'
foreach ($contract in @(
    'AuditPayloadAsync',
    'AuditOverlapBytes',
    'MatchesMagicHeader',
    'IsSafeLeafFileName',
    'X-Content-Type-Options'
)) {
    Assert-ContainsLiteral $upload $contract 'bounded Upload validation'
}
$uploadTests = Read-WorkspaceText 'UploadSever\Upload-Server\Upload-Server.Tests\UploadAuthenticationTests.cs'
Assert-ContainsLiteral $uploadTests 'Upload_rejects_active_content_after_the_old_8kb_audit_window' 'full-stream Upload regression test'

$recommendation = Read-WorkspaceText 'RecommendationService\Backend-Recommendation\ForFakebook\embedding_service.py'
foreach ($contract in @(
    '_allowed_media_hosts',
    '_ip_is_blocked',
    'allow_redirects=False',
    '_read_capped',
    '_download_capped_to_temp'
)) {
    Assert-ContainsLiteral $recommendation $contract 'Recommendation SSRF protection'
}

Write-Host 'API security contracts passed.' -ForegroundColor Green
