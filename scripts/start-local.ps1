[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$ConfigureTailscale,
    [int]$StartupTimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runRoot = Join-Path $root '.run'
$processFile = Join-Path $runRoot 'local-processes.json'
$processes = [System.Collections.Generic.List[object]]::new()

function Normalize-ProcessPathVariable {
    $variables = [Environment]::GetEnvironmentVariables('Process')
    $pathEntries = @($variables.Keys |
        Where-Object { ([string]$_) -ieq 'path' } |
        ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = [string]$variables[$_] } })
    if ($pathEntries.Count -le 1) { return }

    $preferred = ($pathEntries | Where-Object Name -CEQ 'PATH' | Select-Object -First 1).Value
    if ([string]::IsNullOrWhiteSpace($preferred)) { $preferred = $pathEntries[0].Value }
    foreach ($entry in $pathEntries) {
        [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
    }
    [Environment]::SetEnvironmentVariable('Path', $preferred, 'Process')
}

Normalize-ProcessPathVariable

function Read-DotEnv {
    param([string]$Path)

    $result = @{}
    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#') -or -not $line.Contains('=')) {
            continue
        }

        $parts = $line.Split('=', 2)
        $result[$parts[0]] = $parts[1]
    }
    return $result
}

function Assert-PortAvailable {
    param([int]$Port)

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
    }
    catch {
        throw "Port $Port is already in use. Stop the owning process before starting Fakebook."
    }
    finally {
        $listener.Stop()
    }
}

function Test-TcpPort([string]$HostName, [int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        return $task.Wait(500) -and $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Wait-TcpPort([string]$Name, [string]$HostName, [int]$Port, [Diagnostics.Process]$Process) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ($Process.HasExited) { throw "$Name exited before opening $HostName`:$Port." }
        if (Test-TcpPort $HostName $Port) { return }
        Start-Sleep -Milliseconds 200
    }
    throw "$Name did not open $HostName`:$Port within $StartupTimeoutSeconds seconds."
}

function Invoke-CheckedCommand {
    param(
        [string]$Name,
        [string]$WorkingDirectory,
        [string]$FilePath,
        [string[]]$ArgumentList,
        [hashtable]$Environment = @{}
    )

    Write-Host "[$Name]" -ForegroundColor Cyan
    $original = @{}
    foreach ($key in $Environment.Keys) {
        $original[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }

    Push-Location $WorkingDirectory
    try {
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "$Name failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $original[$key], 'Process')
        }
    }
}

function Start-FakebookProcess {
    param(
        [string]$Name,
        [int]$Port,
        [string]$WorkingDirectory,
        [string]$FilePath,
        [string[]]$ArgumentList,
        [hashtable]$Environment
    )

    Assert-PortAvailable $Port
    $stdout = Join-Path $runRoot "$Name.stdout.log"
    $stderr = Join-Path $runRoot "$Name.stderr.log"
    foreach ($path in $stdout, $stderr) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    $original = @{}
    foreach ($key in $Environment.Keys) {
        $original[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }

    try {
        $startArguments = @{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
            WorkingDirectory = $WorkingDirectory
            WindowStyle = 'Hidden'
            RedirectStandardOutput = $stdout
            RedirectStandardError = $stderr
            PassThru = $true
        }
        $process = Start-Process @startArguments
    }
    finally {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $original[$key], 'Process')
        }
    }

    $process = Get-Process -Id $process.Id
    $entry = [pscustomobject]@{
        name = $Name
        port = $Port
        id = $process.Id
        startedAt = $process.StartTime.ToUniversalTime().ToString('o')
        stdout = $stdout
        stderr = $stderr
    }
    $processes.Add($entry)
    $processes | ConvertTo-Json | Set-Content -LiteralPath $processFile -Encoding UTF8
    Write-Host "Started $Name on 127.0.0.1:$Port (PID $($process.Id))."
    return $process
}

function Wait-FakebookEndpoint {
    param(
        [string]$Name,
        [string]$Url,
        [System.Diagnostics.Process]$Process
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) {
            $entry = $processes | Where-Object name -eq $Name | Select-Object -First 1
            if ($entry -and (Test-Path -LiteralPath $entry.stderr)) {
                Get-Content -LiteralPath $entry.stderr -Tail 40 -Encoding UTF8
            }
            throw "$Name exited before becoming ready."
        }

        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                Write-Host "$Name is ready." -ForegroundColor Green
                return
            }
        }
        catch { }

        Start-Sleep -Milliseconds 750
    }

    throw "$Name did not become ready within $StartupTimeoutSeconds seconds."
}

function Enable-FakebookTailscaleServe {
    param([uri]$Origin)

    $tailscale = (Get-Command tailscale -ErrorAction Stop).Source
    $stdout = Join-Path $runRoot 'tailscale-serve.stdout.log'
    $stderr = Join-Path $runRoot 'tailscale-serve.stderr.log'
    foreach ($path in $stdout, $stderr) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    $process = Start-Process `
        -FilePath $tailscale `
        -ArgumentList @(
            'serve',
            '--bg',
            "--https=$($Origin.Port)",
            '--yes',
            'http://127.0.0.1:3001') `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -PassThru

    if (-not $process.WaitForExit(20000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
        $details = @(
            if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw -Encoding UTF8 }
            if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw -Encoding UTF8 }
        ) -join [Environment]::NewLine
        if ($details -match 'Serve is not enabled on your tailnet') {
            Write-Warning $details.Trim()
            return $false
        }
        throw 'Tailscale Serve did not finish configuring within 20 seconds.'
    }

    if ($process.ExitCode -ne 0) {
        $details = @(
            if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw -Encoding UTF8 }
            if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw -Encoding UTF8 }
        ) -join [Environment]::NewLine
        Write-Warning "Tailscale Serve configuration failed with exit code $($process.ExitCode). $($details.Trim())"
        return $false
    }

    return $true
}

function Get-ConfigOrDefault {
    param(
        [hashtable]$Config,
        [string]$Name,
        [string]$Default
    )

    $value = [string]$Config[$Name]
    return $(if ([string]::IsNullOrWhiteSpace($value)) { $Default } else { $value })
}

$environmentFile = Join-Path $root '.env'
& (Join-Path $PSScriptRoot 'validate-environment.ps1') -EnvironmentFile $environmentFile
$config = Read-DotEnv $environmentFile
$smtpEnableSsl = if ($config.ContainsKey('SMTP_ENABLE_SSL')) {
    $config['SMTP_ENABLE_SSL']
}
elseif ($config.ContainsKey('EnableSsl')) {
    $config['EnableSsl']
}
else {
    'true'
}
$redisConnectionString = if ($config.ContainsKey('REDIS_CONNECTION_STRING') -and
    -not [string]::IsNullOrWhiteSpace($config['REDIS_CONNECTION_STRING'])) {
    $config['REDIS_CONNECTION_STRING']
}
else {
    '127.0.0.1:6379,abortConnect=false,connectTimeout=500,syncTimeout=1000'
}
$traceSampleRatio = if ($config.ContainsKey('OTEL_TRACE_SAMPLE_RATIO') -and
    -not [string]::IsNullOrWhiteSpace($config['OTEL_TRACE_SAMPLE_RATIO'])) {
    $config['OTEL_TRACE_SAMPLE_RATIO']
}
else {
    '0.1'
}
$localFrontendOrigin = $config['LOCAL_FRONTEND_ORIGIN'].TrimEnd('/')
$tailscaleOrigin = $config['TAILSCALE_ORIGIN'].TrimEnd('/')
$publicOrigin = if ($config.ContainsKey('PUBLIC_ORIGIN')) {
    $config['PUBLIC_ORIGIN'].TrimEnd('/')
}
else {
    ''
}
$uploadCleanupEnabled = if ($config.ContainsKey('LOCAL_UPLOAD_CLEANUP_ENABLED')) {
    $config['LOCAL_UPLOAD_CLEANUP_ENABLED']
}
else {
    # Production/deploy is the default cleanup owner. Keeping local cleanup off avoids
    # two hosts sweeping the same symlink/SMB media root unless the operator has explicitly
    # verified cross-host locking. Standalone local development may opt in in .env.
    'false'
}
$uploadCleanupIntervalMinutes = if ($config.ContainsKey('UPLOAD_CLEANUP_INTERVAL_MINUTES')) {
    $config['UPLOAD_CLEANUP_INTERVAL_MINUTES']
}
else {
    '2'
}
$uploadReferenceDeleteGraceMinutes = if ($config.ContainsKey('UPLOAD_REFERENCE_DELETE_GRACE_MINUTES')) {
    $config['UPLOAD_REFERENCE_DELETE_GRACE_MINUTES']
}
else {
    '0'
}
$uploadAuthorizationReservationMinutes = if ($config.ContainsKey('UPLOAD_AUTHORIZATION_RESERVATION_MINUTES')) {
    $config['UPLOAD_AUTHORIZATION_RESERVATION_MINUTES']
}
else {
    '10080'
}
$uploadDeletedTombstoneRetentionMinutes = if ($config.ContainsKey('UPLOAD_DELETED_TOMBSTONE_RETENTION_MINUTES')) {
    $config['UPLOAD_DELETED_TOMBSTONE_RETENTION_MINUTES']
}
else {
    '43200'
}
$uploadQuarantineRetentionMinutes = if ($config.ContainsKey('UPLOAD_QUARANTINE_RETENTION_MINUTES')) {
    $config['UPLOAD_QUARANTINE_RETENTION_MINUTES']
}
else {
    '60'
}
$uploadImageLossyQuality = if ($config.ContainsKey('UPLOAD_IMAGE_LOSSY_QUALITY')) {
    $config['UPLOAD_IMAGE_LOSSY_QUALITY']
}
else {
    '78'
}
$uploadPreferredStillImageFormat = if ($config.ContainsKey('UPLOAD_PREFERRED_STILL_IMAGE_FORMAT')) {
    $config['UPLOAD_PREFERRED_STILL_IMAGE_FORMAT']
}
else {
    'preserve'
}
$uploadMaxStoredImageDimension = if ($config.ContainsKey('UPLOAD_MAX_STORED_IMAGE_DIMENSION')) {
    $config['UPLOAD_MAX_STORED_IMAGE_DIMENSION']
}
else {
    '6144'
}

if (Test-Path -LiteralPath $processFile) {
    $registeredJson = Get-Content -LiteralPath $processFile -Raw -Encoding UTF8 | ConvertFrom-Json
    # Windows PowerShell can return a JSON array as one nested Object[] when it is
    # wrapped directly in @(...). Pass it through the pipeline to enumerate every
    # registered service before validating the process ids.
    $registered = @($registeredJson | ForEach-Object { $_ })
    $allRegisteredProcessesAreRunning = $registered.Count -gt 0

    foreach ($entry in $registered) {
        $process = Get-Process -Id ([int]$entry.id) -ErrorAction SilentlyContinue
        if (-not $process) {
            $allRegisteredProcessesAreRunning = $false
            break
        }

        try {
            $expectedStart = [datetime]::Parse([string]$entry.startedAt).ToUniversalTime()
            $actualStart = $process.StartTime.ToUniversalTime()
            if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
                $allRegisteredProcessesAreRunning = $false
                break
            }
        }
        catch {
            $allRegisteredProcessesAreRunning = $false
            break
        }
    }

    if ($allRegisteredProcessesAreRunning) {
        Write-Host 'Fakebook local stack is already running.' -ForegroundColor Green
        Write-Host 'Local: http://localhost:3001'
        Write-Host 'Use scripts\status-local.ps1 or scripts\stop-local.ps1.'
        return
    }

    throw 'A stale or partially running Fakebook registry exists. Run scripts\stop-local.ps1, then start again.'
}

New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $runRoot 'media') -Force | Out-Null

$dotnet = & (Join-Path $PSScriptRoot 'resolve-dotnet.ps1')
$node = (Get-Command node -ErrorAction Stop).Source
$python = Join-Path $root 'RecommendationService\.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    $python = (Get-Command python -ErrorAction Stop).Source
}
$vite = Join-Path $root 'Frontend\Frontend\node_modules\vite\bin\vite.js'
if (-not (Test-Path -LiteralPath $vite)) {
    throw 'Frontend dependencies are missing. Run npm ci in Frontend\Frontend.'
}

$projects = @(
    'AuthenticationService\Backend-Authentication\fakebookAuth\fakebookAuth.csproj',
    'SocialGraphService\SocialGraph.Api\SocialGraph.Api.csproj',
    'SearchService\Backend-Search\BackEndSearchFakebook.csproj',
    'NotificationService\NotificationService\NotificationService.csproj',
    'MessengerService\MessengerService\MessengerService.csproj',
    'PaymentService\Backend-Payment\fakebookPayment\fakebookPayment.csproj',
    'UploadSever\Upload-Server\Fakebook.UploadServer.csproj',
    'APIGateway\API-Gateway\fakebookGateway\fakebookGateway.csproj'
)

if (-not $SkipBuild) {
    foreach ($relativeProject in $projects) {
        $project = Join-Path $root $relativeProject
        Invoke-CheckedCommand -Name "Build $relativeProject" -WorkingDirectory (Split-Path -Parent $project) -FilePath $dotnet -ArgumentList @('build', $project, '--configuration', 'Release', '-m:1')
    }

    $recommendationRequirements = Join-Path $root 'RecommendationService\Backend-Recommendation\requirements.txt'
    $requirementsFingerprint = (Get-FileHash -LiteralPath $recommendationRequirements -Algorithm SHA256).Hash
    $requirementsMarker = Join-Path $runRoot 'recommendation-requirements.sha256'
    $installedFingerprint = if (Test-Path -LiteralPath $requirementsMarker) {
        (Get-Content -LiteralPath $requirementsMarker -Raw -Encoding ASCII).Trim()
    }
    else { '' }
    if ($installedFingerprint -ne $requirementsFingerprint) {
        Invoke-CheckedCommand `
            -Name 'Install Recommendation dependencies' `
            -WorkingDirectory (Join-Path $root 'RecommendationService\Backend-Recommendation') `
            -FilePath $python `
            -ArgumentList @('-m', 'pip', 'install', '--disable-pip-version-check', '-r', $recommendationRequirements)
        [IO.File]::WriteAllText($requirementsMarker, $requirementsFingerprint, [Text.Encoding]::ASCII)
    }

    $npm = (Get-Command npm.cmd -ErrorAction Stop).Source
    Invoke-CheckedCommand -Name 'Build Frontend' -WorkingDirectory (Join-Path $root 'Frontend\Frontend') -FilePath $npm -ArgumentList @('run', 'build')
}

function New-ServiceDatabaseConnection([string]$Prefix) {
    return "Host=$($config['DB_HOST']);Port=$($config['DB_PORT']);Database=$($config['DB_NAME']);Username=$($config["${Prefix}_DB_USER"]);Password=$($config["${Prefix}_DB_PASSWORD"]);Timeout=10;Command Timeout=30"
}
$authDb = New-ServiceDatabaseConnection 'AUTH'
$socialGraphDb = New-ServiceDatabaseConnection 'SOCIALGRAPH'
$searchDb = New-ServiceDatabaseConnection 'SEARCH'
$notificationDb = New-ServiceDatabaseConnection 'NOTIFICATION'
$messengerDb = New-ServiceDatabaseConnection 'MESSENGER'
$paymentDb = New-ServiceDatabaseConnection 'PAYMENT'
$socialGraphProjectRoot = Join-Path $root 'SocialGraphService\SocialGraph.Api'
$socialGraphSchemaPath = Join-Path $runRoot 'social-graph.schema.graphqls'
$gatewaySocialGraphSchemaPath = Join-Path $root 'APIGateway\API-Gateway\fakebookGateway\Gateway\schema\SocialGraph\schema.graphqls'
Invoke-CheckedCommand `
    -Name 'Export SocialGraph Fusion schema' `
    -WorkingDirectory $socialGraphProjectRoot `
    -FilePath $dotnet `
    -ArgumentList @(
        'bin\Release\net10.0\SocialGraph.Api.dll',
        'schema', 'export',
        '--output', $socialGraphSchemaPath
    ) `
    -Environment @{
        'ASPNETCORE_ENVIRONMENT' = 'Production'
        'DOTNET_ENVIRONMENT' = 'Production'
        'DatabaseMigrations__Enabled' = 'false'
    }
$socialGraphSchema = [IO.File]::ReadAllText($socialGraphSchemaPath)
$socialGraphSchema = [Text.RegularExpressions.Regex]::Replace(
    $socialGraphSchema,
    '(?m)^  userById\(id: Long!\): User @cost\(weight: "10"\)\r?\n',
    '')
[IO.File]::WriteAllText(
    $socialGraphSchemaPath,
    $socialGraphSchema,
    [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $socialGraphSchemaPath -Destination $gatewaySocialGraphSchemaPath -Force

$searchProjectRoot = Join-Path $root 'SearchService\Backend-Search'
$searchSchemaPath = Join-Path $runRoot 'search.schema.graphqls'
$gatewaySearchSchemaPath = Join-Path $root 'APIGateway\API-Gateway\fakebookGateway\Gateway\schema\Search\schema.graphqls'
Invoke-CheckedCommand `
    -Name 'Export Search Fusion schema' `
    -WorkingDirectory $searchProjectRoot `
    -FilePath $dotnet `
    -ArgumentList @(
        'bin\Release\net10.0\BackEndSearchFakebook.dll',
        'schema', 'export',
        '--output', $searchSchemaPath
    ) `
    -Environment @{
        'ASPNETCORE_ENVIRONMENT' = 'Production'
        'DOTNET_ENVIRONMENT' = 'Production'
        'ConnectionStrings__DefaultConnection' = "$searchDb;Search Path=search"
        'Database__ApplySchemaOnStartup' = 'false'
        'InternalSearchService__Secret' = $config['SEARCH_INTERNAL_SECRET']
        'Gateway__InternalSharedSecret' = $config['SEARCH_GATEWAY_SECRET']
        'InternalServices__Messaging__BaseUrl' = 'http://127.0.0.1:1006'
        'InternalServices__Messaging__SharedSecret' = $config['MESSENGER_INTERNAL_SECRET']
        'InternalServices__SocialGraph__BaseUrl' = 'http://127.0.0.1:1002'
        'InternalServices__SocialGraph__SharedSecret' = $config['SOCIALGRAPH_INTERNAL_SECRET']
    }
Copy-Item -LiteralPath $searchSchemaPath -Destination $gatewaySearchSchemaPath -Force

$messagingProjectRoot = Join-Path $root 'MessengerService\MessengerService'
$messagingSchemaPath = Join-Path $messagingProjectRoot 'schema.graphqls'
$gatewayMessagingSchemaPath = Join-Path $root 'APIGateway\API-Gateway\fakebookGateway\Gateway\schema\Messaging\schema.graphqls'
Invoke-CheckedCommand `
    -Name 'Export Messaging Fusion schema' `
    -WorkingDirectory $messagingProjectRoot `
    -FilePath $dotnet `
    -ArgumentList @(
        'bin\Release\net10.0\MessengerService.dll',
        'schema', 'export',
        '--schema-name', 'Messaging',
        '--output', $messagingSchemaPath
    ) `
    -Environment @{
        'ASPNETCORE_ENVIRONMENT' = 'Production'
        'DOTNET_ENVIRONMENT' = 'Production'
        'ConnectionStrings__PostgreSQL' = "$messengerDb;Search Path=messenger"
        'DatabaseMigrations__Enabled' = 'false'
        'Gateway__InternalSharedSecret' = $config['MESSENGER_GATEWAY_SECRET']
        'InternalServices__MessengerSharedSecret' = $config['MESSENGER_INTERNAL_SECRET']
        'InternalServices__SocialGraph__BaseUrl' = 'http://127.0.0.1:1002'
        'InternalServices__SocialGraph__SharedSecret' = $config['SOCIALGRAPH_INTERNAL_SECRET']
        'InternalServices__Upload__BaseUrl' = 'http://127.0.0.1:4001'
        'InternalServices__Upload__SharedSecret' = $config['UPLOAD_INTERNAL_SECRET']
        'InternalServices__TimeoutSeconds' = '3'
        'Messaging__AllowedAttachmentHosts__0' = 'localhost'
        'Messaging__AllowedAttachmentHosts__1' = ([uri]$tailscaleOrigin).Host
    }
Copy-Item -LiteralPath $messagingSchemaPath -Destination $gatewayMessagingSchemaPath -Force

$gatewayRoot = Join-Path $root 'APIGateway\API-Gateway\fakebookGateway'
& (Join-Path $gatewayRoot 'compose-fusion.ps1') -Environment Development -Archive 'gateway.local.far'

$commonDotnet = @{
    'ASPNETCORE_ENVIRONMENT' = 'Production'
    'DOTNET_ENVIRONMENT' = 'Production'
    'DOTNET_EnableDiagnostics' = '0'
    'InternalAuth__RequireSignature' = 'true'
    'InternalAuth__SendLegacySecret' = 'false'
    'ConnectionStrings__SecurityRedis' = $redisConnectionString
    'Observability__TraceSampleRatio' = $traceSampleRatio
}

function Merge-Environment {
    param([hashtable]$Base, [hashtable]$Specific)
    $merged = @{}
    foreach ($key in $Base.Keys) { $merged[$key] = $Base[$key] }
    foreach ($key in $Specific.Keys) { $merged[$key] = $Specific[$key] }
    return $merged
}

try {
    $tailscaleConfigured = $false
    if (-not (Test-TcpPort '127.0.0.1' 6379)) {
        $garnet = Get-ChildItem (Join-Path $root '.tools') -Recurse -Filter GarnetServer.exe -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if (-not $garnet) {
            throw 'Redis is unavailable and Microsoft Garnet is not installed. Run scripts\bootstrap-tools.ps1.'
        }
        $garnetWorkingDirectory = Join-Path $runRoot 'garnet'
        New-Item -ItemType Directory -Path $garnetWorkingDirectory -Force | Out-Null
        $securityCache = Start-FakebookProcess `
            -Name 'security-cache' `
            -Port 6379 `
            -WorkingDirectory $garnetWorkingDirectory `
            -FilePath $garnet.FullName `
            -ArgumentList @('--bind', '127.0.0.1', '--port', '6379', '--memory', '64m', '--page', '4m', '--segment', '64m', '--index', '16m') `
            -Environment @{ 'DOTNET_ROOT' = (Join-Path $root '.tools\dotnet10') }
        Wait-TcpPort 'security-cache' '127.0.0.1' 6379 $securityCache
    }

    $auth = Start-FakebookProcess -Name 'authentication' -Port 1001 -WorkingDirectory (Join-Path $root 'AuthenticationService\Backend-Authentication\fakebookAuth') -FilePath $dotnet -ArgumentList @('bin\Release\net10.0\fakebookAuth.dll') -Environment (Merge-Environment $commonDotnet @{
        'ASPNETCORE_URLS' = 'http://127.0.0.1:1001'
        'ConnectionStrings__DefaultConnection' = "$authDb;Search Path=auth"
        'DatabaseMigrations__Enabled' = 'false'
        'Jwt__Issuer' = 'fakebook-auth'
        'Jwt__Audience' = 'fakebook'
        'Jwt__PrivateKeyBase64' = $config['JWT_PRIVATE_KEY_BASE64']
        'Jwt__KeyId' = $config['JWT_KEY_ID']
        'Jwt__LegacySigningKey' = $config['JWT_LEGACY_SIGNING_KEY']
        'Gateway__InternalSharedSecret' = $config['AUTH_GATEWAY_SECRET']
        'Gateway__AuthenticationServiceSharedSecret' = $config['AUTHENTICATION_INTERNAL_SECRET']
        'Payment__InternalSharedSecret' = $config['PAYMENT_AUTH_SECRET']
        'Auth__AbsoluteSessionDays' = '90'
        # The host launcher is explicitly served at http://localhost:3001. Production-like
        # Docker/Tailscale keeps Secure=true; the localhost-only process must allow the browser
        # to retain its HttpOnly refresh cookie so the 15-minute access token can rotate.
        'Auth__RefreshTokenCookieSecure' = 'false'
        'Smtp__Enabled' = $config['SMTP_ENABLED']
        'Smtp__Host' = $config['SMTP_HOST']
        'Smtp__Port' = $config['SMTP_PORT']
        'Smtp__EnableSsl' = $smtpEnableSsl
        'Smtp__Username' = $config['SMTP_USERNAME']
        'Smtp__Password' = $config['SMTP_PASSWORD']
        'Smtp__FromEmail' = $config['SMTP_FROM_EMAIL']
        'Smtp__FromName' = $config['SMTP_FROM_NAME']
    })
    Wait-FakebookEndpoint 'authentication' 'http://127.0.0.1:1001/health/ready' $auth

    $search = Start-FakebookProcess -Name 'search' -Port 1004 -WorkingDirectory (Join-Path $root 'SearchService\Backend-Search') -FilePath $dotnet -ArgumentList @('bin\Release\net10.0\BackEndSearchFakebook.dll') -Environment (Merge-Environment $commonDotnet @{
        'ASPNETCORE_URLS' = 'http://127.0.0.1:1004'
        'ConnectionStrings__DefaultConnection' = "$searchDb;Search Path=search"
        'Database__ApplySchemaOnStartup' = 'false'
        'InternalSearchService__Secret' = $config['SEARCH_INTERNAL_SECRET']
        'Gateway__InternalSharedSecret' = $config['SEARCH_GATEWAY_SECRET']
        'InternalServices__Messaging__BaseUrl' = 'http://127.0.0.1:1006'
        'InternalServices__Messaging__SharedSecret' = $config['MESSENGER_INTERNAL_SECRET']
        'InternalServices__Messaging__TimeoutSeconds' = '3'
        'InternalServices__Messaging__CacheSeconds' = '45'
        'InternalServices__SocialGraph__BaseUrl' = 'http://127.0.0.1:1002'
        'InternalServices__SocialGraph__SharedSecret' = $config['SOCIALGRAPH_INTERNAL_SECRET']
        'InternalServices__SocialGraph__TimeoutSeconds' = '3'
        'InternalServices__SocialGraph__CacheSeconds' = '45'
    })
    Wait-FakebookEndpoint 'search' 'http://127.0.0.1:1004/health/ready' $search

    $notification = Start-FakebookProcess -Name 'notification' -Port 1005 -WorkingDirectory (Join-Path $root 'NotificationService\NotificationService') -FilePath $dotnet -ArgumentList @('bin\Release\net10.0\NotificationService.dll') -Environment (Merge-Environment $commonDotnet @{
        'ASPNETCORE_URLS' = 'http://127.0.0.1:1005'
        'ConnectionStrings__NotificationDb' = "$notificationDb;Search Path=notification"
        'Database__ApplyMigrationsOnStartup' = 'false'
        'InternalAuthentication__GatewaySecret' = $config['NOTIFICATION_GATEWAY_SECRET']
        'InternalAuthentication__NotificationServiceSecret' = $config['NOTIFICATION_INTERNAL_SECRET']
        'Snowflake__NodeId' = '5'
    })
    Wait-FakebookEndpoint 'notification' 'http://127.0.0.1:1005/health/ready' $notification

    $messaging = Start-FakebookProcess -Name 'messaging' -Port 1006 -WorkingDirectory (Join-Path $root 'MessengerService\MessengerService') -FilePath $dotnet -ArgumentList @('bin\Release\net10.0\MessengerService.dll') -Environment (Merge-Environment $commonDotnet @{
        'ASPNETCORE_URLS' = 'http://127.0.0.1:1006'
        'ConnectionStrings__PostgreSQL' = "$messengerDb;Search Path=messenger"
        'DatabaseMigrations__Enabled' = 'false'
        'Gateway__InternalSharedSecret' = $config['MESSENGER_GATEWAY_SECRET']
        'InternalServices__MessengerSharedSecret' = $config['MESSENGER_INTERNAL_SECRET']
        'InternalServices__SocialGraph__BaseUrl' = 'http://127.0.0.1:1002'
        'InternalServices__SocialGraph__SharedSecret' = $config['SOCIALGRAPH_INTERNAL_SECRET']
        'InternalServices__Upload__BaseUrl' = 'http://127.0.0.1:4001'
        'InternalServices__Upload__SharedSecret' = $config['UPLOAD_INTERNAL_SECRET']
        'InternalServices__TimeoutSeconds' = '3'
        'Messaging__AllowedAttachmentHosts__0' = 'localhost'
        'Messaging__AllowedAttachmentHosts__1' = ([uri]$tailscaleOrigin).Host
    })
    Wait-FakebookEndpoint 'messaging' 'http://127.0.0.1:1006/health/ready' $messaging

    $recommendationUser = [Uri]::EscapeDataString($config['RECOMMENDATION_DB_USER'])
    $recommendationPassword = [Uri]::EscapeDataString($config['RECOMMENDATION_DB_PASSWORD'])
    $recommendationDatabase = [Uri]::EscapeDataString($config['DB_NAME'])
    $recommendation = Start-FakebookProcess -Name 'recommendation' -Port 1003 -WorkingDirectory (Join-Path $root 'RecommendationService\Backend-Recommendation') -FilePath $python -ArgumentList @('-m', 'uvicorn', 'ForFakebook.EmbeddingModel:app', '--host', '127.0.0.1', '--port', '1003') -Environment @{
        'DATABASE_URL' = "postgresql://$recommendationUser`:$recommendationPassword@$($config['DB_HOST']):$($config['DB_PORT'])/$recommendationDatabase`?options=-csearch_path%3Drecommendation%2Cpublic"
        'RECOMMENDATION_DB_MIGRATIONS_ENABLED' = 'false'
        'INTERNAL_SHARED_SECRET' = $config['RECOMMENDATION_GATEWAY_SECRET']
        'RECOMMENDATION_INTERNAL_SECRET' = $config['RECOMMENDATION_INTERNAL_SECRET']
        'SOCIAL_GRAPH_SERVICE_SECRET' = $config['SOCIALGRAPH_INTERNAL_SECRET']
        'SOCIAL_GRAPH_BASE_URL' = 'http://127.0.0.1:1002'
        'INTERNAL_AUTH_REQUIRE_SIGNATURE' = 'true'
        'INTERNAL_AUTH_SEND_LEGACY_SECRET' = 'false'
        'SECURITY_REDIS_URL' = "redis://$($redisConnectionString.Split(',')[0])/0"
        'OTEL_TRACES_SAMPLER_ARG' = $traceSampleRatio
        'RECOMMENDATION_MEDIA_ALLOWED_HOSTS' = ([uri]$tailscaleOrigin).Host
        'RECOMMENDATION_MEDIA_BASE_URL' = $tailscaleOrigin
        'RECOMMENDATION_MEDIA_REQUIRE_ALLOWLIST' = 'true'
        'RECOMMENDATION_MEDIA_MAX_BYTES' = '26214400'
        'RECOMMENDATION_VIDEO_MAX_BYTES' = '524288000'
        'RECOMMENDATION_MAX_VIDEO_FRAMES' = '24'
        'RECOMMENDATION_MAX_MEDIA_PIXELS' = '40000000'
        'RECOMMENDATION_ADVANCED_RANKING_ENABLED' = Get-ConfigOrDefault $config 'RECOMMENDATION_ADVANCED_RANKING_ENABLED' 'true'
        'RECOMMENDATION_EXPLORATION_ENABLED' = Get-ConfigOrDefault $config 'RECOMMENDATION_EXPLORATION_ENABLED' 'true'
        'RECOMMENDATION_FRESHNESS_ENABLED' = Get-ConfigOrDefault $config 'RECOMMENDATION_FRESHNESS_ENABLED' 'true'
        'RECOMMENDATION_DIVERSITY_ENABLED' = Get-ConfigOrDefault $config 'RECOMMENDATION_DIVERSITY_ENABLED' 'true'
        'RECOMMENDATION_SEEN_SUPPRESSION_ENABLED' = Get-ConfigOrDefault $config 'RECOMMENDATION_SEEN_SUPPRESSION_ENABLED' 'true'
        'RECOMMENDATION_IMPRESSION_RERANKING_ENABLED' = Get-ConfigOrDefault $config 'RECOMMENDATION_IMPRESSION_RERANKING_ENABLED' 'true'
        'RECOMMENDATION_FRESHNESS_HALF_LIFE_HOURS' = Get-ConfigOrDefault $config 'RECOMMENDATION_FRESHNESS_HALF_LIFE_HOURS' '72'
        'RECOMMENDATION_EXPLORATION_RATE' = Get-ConfigOrDefault $config 'RECOMMENDATION_EXPLORATION_RATE' '0.12'
        'RECOMMENDATION_SEMANTIC_WEIGHT' = Get-ConfigOrDefault $config 'RECOMMENDATION_SEMANTIC_WEIGHT' '0.58'
        'RECOMMENDATION_FRESHNESS_WEIGHT' = Get-ConfigOrDefault $config 'RECOMMENDATION_FRESHNESS_WEIGHT' '0.20'
        'RECOMMENDATION_SOURCE_WEIGHT' = Get-ConfigOrDefault $config 'RECOMMENDATION_SOURCE_WEIGHT' '0.10'
        'RECOMMENDATION_EXPLORATION_WEIGHT' = Get-ConfigOrDefault $config 'RECOMMENDATION_EXPLORATION_WEIGHT' '0.12'
        'RECOMMENDATION_MAX_AUTHOR_QUOTA' = Get-ConfigOrDefault $config 'RECOMMENDATION_MAX_AUTHOR_QUOTA' '3'
        'RECOMMENDATION_MAX_GROUP_QUOTA' = Get-ConfigOrDefault $config 'RECOMMENDATION_MAX_GROUP_QUOTA' '4'
        'RECOMMENDATION_SEEN_TTL_DAYS' = Get-ConfigOrDefault $config 'RECOMMENDATION_SEEN_TTL_DAYS' '30'
        'RECOMMENDATION_IMPRESSION_PENALTY' = Get-ConfigOrDefault $config 'RECOMMENDATION_IMPRESSION_PENALTY' '0.06'
        'RECOMMENDATION_RETENTION_CLEANUP_INTERVAL_SECONDS' = Get-ConfigOrDefault $config 'RECOMMENDATION_RETENTION_CLEANUP_INTERVAL_SECONDS' '3600'
        'RECOMMENDATION_RETENTION_CLEANUP_BATCH_SIZE' = Get-ConfigOrDefault $config 'RECOMMENDATION_RETENTION_CLEANUP_BATCH_SIZE' '1000'
        'RECOMMENDATION_RETENTION_CLEANUP_MAX_BATCHES' = Get-ConfigOrDefault $config 'RECOMMENDATION_RETENTION_CLEANUP_MAX_BATCHES' '10'
        'RECOMMENDATION_RETENTION_CLEANUP_TIME_BUDGET_SECONDS' = Get-ConfigOrDefault $config 'RECOMMENDATION_RETENTION_CLEANUP_TIME_BUDGET_SECONDS' '30'
        'PYTHONUNBUFFERED' = '1'
    }
    Wait-FakebookEndpoint 'recommendation' 'http://127.0.0.1:1003/health/ready' $recommendation

    $social = Start-FakebookProcess -Name 'social-graph' -Port 1002 -WorkingDirectory (Join-Path $root 'SocialGraphService\SocialGraph.Api') -FilePath $dotnet -ArgumentList @('bin\Release\net10.0\SocialGraph.Api.dll') -Environment (Merge-Environment $commonDotnet @{
        'ASPNETCORE_URLS' = 'http://127.0.0.1:1002'
        'ConnectionStrings__PostgreSQL' = "$socialGraphDb;Search Path=social_graph"
        'ConnectionStrings__Redis' = $redisConnectionString
        'DatabaseMigrations__Enabled' = 'false'
        'Gateway__InternalSharedSecret' = $config['SOCIALGRAPH_GATEWAY_SECRET']
        'InternalServices__SocialGraph__SharedSecret' = $config['SOCIALGRAPH_INTERNAL_SECRET']
        'InternalServices__Authentication__BaseUrl' = 'http://127.0.0.1:1001'
        'InternalServices__Authentication__SharedSecret' = $config['AUTHENTICATION_INTERNAL_SECRET']
        'InternalServices__Search__BaseUrl' = 'http://127.0.0.1:1004'
        'InternalServices__Search__SharedSecret' = $config['SEARCH_INTERNAL_SECRET']
        'InternalServices__Recommendation__BaseUrl' = 'http://127.0.0.1:1003'
        'InternalServices__Recommendation__SharedSecret' = $config['RECOMMENDATION_INTERNAL_SECRET']
        'InternalServices__Messaging__BaseUrl' = 'http://127.0.0.1:1006'
        'InternalServices__Messaging__SharedSecret' = $config['MESSENGER_INTERNAL_SECRET']
        'InternalServices__Notification__BaseUrl' = 'http://127.0.0.1:1005'
        'InternalServices__Notification__SharedSecret' = $config['NOTIFICATION_INTERNAL_SECRET']
        'InternalServices__Upload__BaseUrl' = 'http://127.0.0.1:4001'
        'InternalServices__Upload__SharedSecret' = $config['UPLOAD_INTERNAL_SECRET']
        'IntegrationOutbox__PayloadEncryptionKey' = $config['SOCIALGRAPH_OUTBOX_ENCRYPTION_KEY']
        'IntegrationOutbox__EnsureSchemaOnStartup' = 'false'
        'InternalServices__TimeoutSeconds' = '10'
    })
    Wait-FakebookEndpoint 'social-graph' 'http://127.0.0.1:1002/health/ready' $social

    $payment = Start-FakebookProcess -Name 'payment' -Port 1007 -WorkingDirectory (Join-Path $root 'PaymentService\Backend-Payment\fakebookPayment') -FilePath $dotnet -ArgumentList @('bin\Release\net10.0\fakebookPayment.dll') -Environment (Merge-Environment $commonDotnet @{
        'ASPNETCORE_URLS' = 'http://127.0.0.1:1007'
        'ConnectionStrings__PaymentDatabase' = "$paymentDb;Search Path=payment"
        'Database__ApplySchemaOnStartup' = 'false'
        'Payment__PublicBaseUrl' = $tailscaleOrigin
        'Payment__FrontendPublicUrl' = $tailscaleOrigin
        'Payment__PaymentsEnabled' = $config['PAYMENTS_ENABLED']
        'PayOS__ClientId' = $config['PAYOS_CLIENT_ID']
        'PayOS__ApiKey' = $config['PAYOS_API_KEY']
        'PayOS__ChecksumKey' = $config['PAYOS_CHECKSUM_KEY']
        'Gateway__SharedSecret' = $config['PAYMENT_GATEWAY_SECRET']
        'Authentication__Endpoint' = 'http://127.0.0.1:1001/graphql'
        'Authentication__PaymentSecret' = $config['PAYMENT_AUTH_SECRET']
        'SocialGraph__BaseUrl' = 'http://127.0.0.1:1002'
        'SocialGraph__InternalSecret' = $config['SOCIALGRAPH_INTERNAL_SECRET']
    })
    Wait-FakebookEndpoint 'payment' 'http://127.0.0.1:1007/health/ready' $payment

    $upload = Start-FakebookProcess -Name 'upload' -Port 4001 -WorkingDirectory (Join-Path $root 'UploadSever\Upload-Server') -FilePath $dotnet -ArgumentList @('bin\Release\net10.0\Fakebook.UploadServer.dll') -Environment (Merge-Environment $commonDotnet @{
        'ASPNETCORE_URLS' = 'http://127.0.0.1:4001'
        'Jwt__Issuer' = 'fakebook-auth'
        'Jwt__Audience' = 'fakebook'
        'Jwt__PublicKeyBase64' = $config['JWT_PUBLIC_KEY_BASE64']
        'Jwt__KeyId' = $config['JWT_KEY_ID']
        'Jwt__LegacySigningKey' = $config['JWT_LEGACY_SIGNING_KEY']
        'AuthService__Url' = 'http://127.0.0.1:1001/graphql'
        'Cors__AllowedOrigins__0' = $localFrontendOrigin
        'Cors__AllowedOrigins__1' = $tailscaleOrigin
        'UploadStorage__RootPath' = (Join-Path $runRoot 'media')
        'UploadStorage__StagedUploadsEnabled' = 'true'
        'UploadStorage__PendingLifetimeMinutes' = '1440'
        'UploadStorage__CleanupIntervalMinutes' = $uploadCleanupIntervalMinutes
        'UploadStorage__PendingCleanupGraceMinutes' = '120'
        'UploadStorage__ReferenceDeleteGraceMinutes' = $uploadReferenceDeleteGraceMinutes
        'UploadStorage__AuthorizationReservationMinutes' = $uploadAuthorizationReservationMinutes
        'UploadStorage__BrowserReservationMinutes' = '120'
        'UploadStorage__DeletedTombstoneRetentionMinutes' = $uploadDeletedTombstoneRetentionMinutes
        'UploadStorage__QuarantineRetentionMinutes' = $uploadQuarantineRetentionMinutes
        'UploadStorage__LifecycleLockTimeoutSeconds' = '15'
        'UploadStorage__CleanupEnabled' = $uploadCleanupEnabled
        'UploadStorage__ImageLossyQuality' = $uploadImageLossyQuality
        'UploadStorage__PreferredStillImageFormat' = $uploadPreferredStillImageFormat
        'UploadStorage__MaxStoredImageDimension' = $uploadMaxStoredImageDimension
        'UploadStorage__AllowedMediaOrigins__0' = 'http://127.0.0.1:4001'
        'UploadStorage__AllowedMediaOrigins__1' = $localFrontendOrigin
        'UploadStorage__AllowedMediaOrigins__2' = $tailscaleOrigin
        'UploadStorage__AllowedMediaOrigins__3' = $publicOrigin
        'InternalApi__SharedSecret' = $config['UPLOAD_INTERNAL_SECRET']
    })
    Wait-FakebookEndpoint 'upload' 'http://127.0.0.1:4001/health/ready' $upload

    $gateway = Start-FakebookProcess -Name 'gateway' -Port 2001 -WorkingDirectory $gatewayRoot -FilePath $dotnet -ArgumentList @('bin\Release\net10.0\fakebookGateway.dll') -Environment (Merge-Environment $commonDotnet @{
        'ASPNETCORE_URLS' = 'http://127.0.0.1:2001'
        'Jwt__Issuer' = 'fakebook-auth'
        'Jwt__Audience' = 'fakebook'
        'Jwt__PublicKeyBase64' = $config['JWT_PUBLIC_KEY_BASE64']
        'Jwt__KeyId' = $config['JWT_KEY_ID']
        'Jwt__LegacySigningKey' = $config['JWT_LEGACY_SIGNING_KEY']
        'Gateway__FusionArchivePath' = 'gateway.local.far'
        'Gateway__InternalSharedSecret' = $config['GATEWAY_SHARED_SECRET']
        'Gateway__SubgraphSecrets__Authentication' = $config['AUTH_GATEWAY_SECRET']
        'Gateway__SubgraphSecrets__SocialGraph' = $config['SOCIALGRAPH_GATEWAY_SECRET']
        'Gateway__SubgraphSecrets__Recommendation' = $config['RECOMMENDATION_GATEWAY_SECRET']
        'Gateway__SubgraphSecrets__Search' = $config['SEARCH_GATEWAY_SECRET']
        'Gateway__SubgraphSecrets__Notification' = $config['NOTIFICATION_GATEWAY_SECRET']
        'Gateway__SubgraphSecrets__Messaging' = $config['MESSENGER_GATEWAY_SECRET']
        'Gateway__SubgraphSecrets__Payment' = $config['PAYMENT_GATEWAY_SECRET']
        'Gateway__AllowedOrigins__0' = $localFrontendOrigin
        'Gateway__AllowedOrigins__1' = $tailscaleOrigin
        'Subgraphs__Authentication__Url' = 'http://127.0.0.1:1001/graphql'
        'Subgraphs__Payment__WebhookUrl' = 'http://127.0.0.1:1007/internal/webhooks/payos'
    })
    Wait-FakebookEndpoint 'gateway' 'http://127.0.0.1:2001/health/ready' $gateway

    $frontend = Start-FakebookProcess -Name 'frontend' -Port 3001 -WorkingDirectory (Join-Path $root 'Frontend\Frontend') -FilePath $node -ArgumentList @($vite, '--host', '127.0.0.1', '--port', '3001') -Environment @{
        'VITE_API_GATEWAY_URL' = '/api'
        'VITE_GRAPHQL_GATEWAY_URL' = '/graphql'
        'VITE_UPLOAD_SERVER_URL' = '/media'
        'VITE_DEV_GATEWAY_TARGET' = 'http://127.0.0.1:2001'
        'VITE_DEV_UPLOAD_TARGET' = 'http://127.0.0.1:4001'
        'VITE_DEV_ALLOWED_HOST' = ([uri]$tailscaleOrigin).Host
    }
    Wait-FakebookEndpoint 'frontend' 'http://127.0.0.1:3001/' $frontend

    & (Join-Path $PSScriptRoot 'smoke-local.ps1')

    if ($ConfigureTailscale) {
        $tailscaleConfigured = Enable-FakebookTailscaleServe ([uri]$tailscaleOrigin)
    }

    Write-Host ''
    Write-Host 'Fakebook local stack is ready.' -ForegroundColor Green
    Write-Host 'Local: http://localhost:3001'
    if ($tailscaleConfigured) {
        Write-Host "Tailnet: $tailscaleOrigin"
    }
    Write-Host 'Use scripts\status-local.ps1 and scripts\stop-local.ps1 to inspect or stop it.'
}
catch {
    Write-Host $_ -ForegroundColor Red
    & (Join-Path $PSScriptRoot 'stop-local.ps1') -Quiet
    throw
}
