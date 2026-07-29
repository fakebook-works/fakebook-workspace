[CmdletBinding()]
param(
    [switch]$RequireDocker
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dotnet = & (Join-Path $PSScriptRoot 'resolve-dotnet.ps1')
$results = [System.Collections.Generic.List[object]]::new()

function Invoke-FakebookCheck {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$WorkingDirectory,
        [Parameter(Mandatory)] [scriptblock]$Command
    )

    Write-Host "`n[$Name]" -ForegroundColor Cyan
    Push-Location $WorkingDirectory
    try {
        $global:LASTEXITCODE = 0
        & $Command
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        $results.Add([pscustomobject]@{ Name = $Name; ExitCode = $exitCode })
    }
    catch {
        Write-Host $_ -ForegroundColor Red
        $results.Add([pscustomobject]@{ Name = $Name; ExitCode = 1 })
    }
    finally {
        Pop-Location
    }
}

Invoke-FakebookCheck 'Local orchestration contracts' $root {
    & "$root\scripts\check-local-orchestration.ps1"
}
Invoke-FakebookCheck 'API security contracts' $root {
    & "$root\scripts\check-api-security-contracts.ps1"
}

Invoke-FakebookCheck 'Environment configuration' $root {
    & "$root\scripts\validate-environment.ps1"
}
Invoke-FakebookCheck 'UTF-8 encoding' $root {
    & "$root\scripts\check-encoding.ps1"
}
Invoke-FakebookCheck 'Secret leakage scan' $root {
    & "$root\scripts\check-secrets.ps1"
}
Invoke-FakebookCheck 'Canonical ports' $root {
    & "$root\scripts\check-ports.ps1"
}
Invoke-FakebookCheck 'Maintenance and demo tooling' $root {
    & $dotnet build .\scripts\Fakebook.Maintenance\Fakebook.Maintenance.csproj
    if ($LASTEXITCODE -ne 0) { return }
    foreach ($scriptName in @('reset-demo.ps1', 'seed-demo.ps1', 'verify-demo.ps1')) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root "scripts\$scriptName"),
            [ref]$tokens,
            [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            $errors | Format-List
            $global:LASTEXITCODE = 1
            return
        }
    }
}

Invoke-FakebookCheck 'Authentication' "$root\AuthenticationService\Backend-Authentication" {
    & $dotnet test .\fakebookAuth.sln
}
Invoke-FakebookCheck 'SocialGraph' "$root\SocialGraphService" {
    & $dotnet test .\SocialGraphService.sln
}
Invoke-FakebookCheck 'Search' "$root\SearchService\Backend-Search" {
    & $dotnet test .\BackEndSearchFakebook.sln
}
Invoke-FakebookCheck 'Notification' "$root\NotificationService" {
    & $dotnet test .\NotificationService.Tests\NotificationService.Tests.csproj
}
Invoke-FakebookCheck 'Messenger' "$root\MessengerService" {
    & $dotnet test .\MessengerService.sln
}
Invoke-FakebookCheck 'Payment unit tests' "$root\PaymentService\Backend-Payment" {
    & $dotnet test .\fakebookPayment.sln --filter 'FullyQualifiedName!~GraphQLCheckoutEndpointTests&FullyQualifiedName!~PaymentRepositoryIntegrationTests&FullyQualifiedName!~SchemaMigrationTests&FullyQualifiedName!~WebhookEndpointTests'
}
Invoke-FakebookCheck 'Upload' "$root\UploadSever\Upload-Server" {
    & $dotnet test .\Upload-Server.Tests\Upload-Server.Tests.csproj
}
Invoke-FakebookCheck 'Gateway' "$root\APIGateway\API-Gateway" {
    & $dotnet test .\fakebookGateway.sln
}
Invoke-FakebookCheck 'Recommendation' "$root\RecommendationService\Backend-Recommendation" {
    $python = "$root\RecommendationService\.venv\Scripts\python.exe"
    if (-not (Test-Path $python)) { $python = 'python' }
    & $python -m pytest -q
}
Invoke-FakebookCheck 'Frontend tests' "$root\Frontend\Frontend" {
    npm test
}
Invoke-FakebookCheck 'Frontend build' "$root\Frontend\Frontend" {
    npm run build
}
Invoke-FakebookCheck 'Frontend lint' "$root\Frontend\Frontend" {
    npm run lint
}

$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($docker) {
    Invoke-FakebookCheck 'Payment integration tests' "$root\PaymentService\Backend-Payment" {
        & $dotnet test .\fakebookPayment.sln
    }
    Invoke-FakebookCheck 'Docker Compose validation' $root {
        docker compose --env-file .\.env.example -f .\docker-compose.yaml config --quiet
    }
}
elseif ($RequireDocker) {
    $results.Add([pscustomobject]@{ Name = 'Docker availability'; ExitCode = 1 })
    Write-Error 'Docker is required but was not found.'
}
else {
    Write-Warning 'Docker is unavailable; Payment Testcontainers were skipped.'
    $standaloneCompose = "$root\.tools\docker-compose.exe"
    if (Test-Path -LiteralPath $standaloneCompose) {
        Invoke-FakebookCheck 'Docker Compose validation (standalone)' $root {
            & $standaloneCompose --env-file .\.env.example -f .\docker-compose.yaml config --quiet
        }
    }
    else {
        Write-Warning 'Standalone Docker Compose was not found; Compose validation was skipped.'
    }
}

Write-Host "`nFakebook verification summary" -ForegroundColor Cyan
$results | Format-Table -AutoSize
$failed = @($results | Where-Object ExitCode -ne 0)
if ($failed.Count -gt 0) {
    exit 1
}

exit 0
