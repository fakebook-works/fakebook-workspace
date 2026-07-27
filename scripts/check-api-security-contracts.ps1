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

$compose = Read-WorkspaceText 'docker-compose.yml'
Assert-LiteralCount $compose 'InternalAuth__RequireSignature: "true"' 7 'managed signature enforcement'
Assert-LiteralCount $compose 'InternalAuth__SendLegacySecret: "false"' 7 'legacy-secret transmission disablement'
Assert-LiteralCount $compose 'ConnectionStrings__SecurityRedis: redis:6379' 6 '.NET security Redis wiring'
Assert-LiteralCount $compose 'SECURITY_REDIS_URL: redis://redis:6379/0' 1 'Python security Redis wiring'
Assert-LiteralCount $compose 'Jwt__PrivateKeyBase64:' 1 'Auth-only JWT private key'
Assert-LiteralCount $compose 'Jwt__PublicKeyBase64:' 2 'Gateway/Upload JWT public key'
Assert-DoesNotContainLiteral $compose 'Jwt__SigningKey:' 'legacy fleet-wide JWT signer'
Assert-DoesNotContainLiteral $compose ('Username=$' + '{DB_USER}') 'migration owner in runtime connection strings'
Assert-DoesNotContainLiteral $compose ('Password=$' + '{DB_PASSWORD}') 'migration owner in runtime connection strings'

$gatewayProgram = Read-WorkspaceText 'APIGateway\API-Gateway\fakebookGateway\Program.cs'
foreach ($contract in @(
    'AddMaxExecutionDepthRule',
    'AddMaxAllowedFieldCycleDepthRule',
    'MaxAllowedFields',
    'MaxExpandedNodes',
    'SecurityAlgorithms.RsaSha256',
    'ValidAlgorithms'
)) {
    Assert-ContainsLiteral $gatewayProgram $contract 'Gateway GraphQL/JWT enforcement'
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
