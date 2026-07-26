[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://127.0.0.1:2001/graphql',
    [string]$UploadUrl = 'http://127.0.0.1:4001',
    [string]$Manifest = (Join-Path $PSScriptRoot 'seed\demo.manifest.json'),
    [string]$Receipt = (Join-Path $PSScriptRoot 'seed\demo.receipt.json'),
    [string]$Password = $env:FAKEBOOK_DEMO_PASSWORD,
    [ValidateRange(5, 300)]
    [int]$RequestTimeoutSeconds = 30,
    [switch]$AllowRemoteDevelopmentDatabase,
    [switch]$AllowNonEmpty,
    [string]$EnvFile = (Join-Path (Split-Path -Parent $PSScriptRoot) '.env')
)

$ErrorActionPreference = 'Stop'
$maintenanceProject = Join-Path $PSScriptRoot 'Fakebook.Maintenance\Fakebook.Maintenance.csproj'

function Import-FakebookEnv([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $matches[1]
            $value = $matches[2].Trim().Trim('"')
            if (-not [Environment]::GetEnvironmentVariable($name)) {
                [Environment]::SetEnvironmentVariable($name, $value, 'Process')
            }
        }
    }
}

Import-FakebookEnv $EnvFile
if ([string]::IsNullOrWhiteSpace($Password)) { $Password = $env:FAKEBOOK_DEMO_PASSWORD }
if ([string]::IsNullOrWhiteSpace($Password)) {
    throw 'Set FAKEBOOK_DEMO_PASSWORD or pass -Password. Use a development-only password that satisfies the Auth policy.'
}
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { throw "Manifest not found: $Manifest" }

function Invoke-GraphQl {
    param([string]$Query, [hashtable]$Variables = @{}, [string]$Token)
    $headers = @{ Accept = 'application/json' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    $body = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 30 -Compress
    $response = Invoke-RestMethod -Uri $GatewayUrl -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec $RequestTimeoutSeconds
    if ($response.errors) {
        $messages = @($response.errors | ForEach-Object { $_.message }) -join '; '
        throw "GraphQL failed: $messages"
    }
    return $response.data
}

function Invoke-MaintenanceJson([string[]]$Arguments) {
    $output = & dotnet run --project $maintenanceProject --no-restore -- @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Maintenance command failed with exit code $LASTEXITCODE." }
    return (@($output | Where-Object { $_ -match '^\{' })[-1] | ConvertFrom-Json)
}

function Upload-DemoPng([string]$Token, [string]$Name) {
    $endpoint = ([Uri]::new(([Uri]$UploadUrl), '/media/upload')).AbsoluteUri
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds($RequestTimeoutSeconds)
    $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $multipart = [System.Net.Http.MultipartFormDataContent]::new()
    try {
        $bytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
        $file = [System.Net.Http.ByteArrayContent]::new($bytes)
        $file.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('image/png')
        $multipart.Add($file, 'file', "$Name.png")
        $response = $client.PostAsync($endpoint, $multipart).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "Upload failed ($([int]$response.StatusCode)): $text" }
        $uploaded = $text | ConvertFrom-Json
        $url = [string]$uploaded.url
        if ($url.StartsWith('/')) { $url = ([Uri]::new(([Uri]$UploadUrl), $url)).AbsoluteUri }
        return @{ url = $url; type = 0; assetId = [string]$uploaded.assetId }
    }
    finally {
        $multipart.Dispose()
        $client.Dispose()
    }
}

function Wait-Until([scriptblock]$Probe, [string]$Description, [int]$TimeoutSeconds = 45) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try { if (& $Probe) { return } } catch { }
        Start-Sleep -Milliseconds 750
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}

$preflight = Invoke-MaintenanceJson @('preflight', '--env-file', $EnvFile, '--json')
if ($preflight.isRemote -and -not $AllowRemoteDevelopmentDatabase) {
    throw 'The configured database is remote. Re-run with -AllowRemoteDevelopmentDatabase after verifying it is the intended Development database.'
}
if (-not $AllowNonEmpty -and [long]$preflight.totalRows -ne 0) {
    throw "Demo seed requires an empty application database; preflight found $($preflight.totalRows) rows. Run reset-demo.ps1 first."
}

$manifestData = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$users = @{}
$tokens = @{}

foreach ($definition in $manifestData.users) {
    $data = Invoke-GraphQl @'
mutation CreateDemoUser($input: CreateUserInput!) {
  createUser(input: $input) { success userId message }
}
'@ @{ input = @{
        name = [string]$definition.name
        gender = [bool]$definition.gender
        birthdate = [string]$definition.birthdate
        location = [string]$definition.location
        email = [string]$definition.email
        password = $Password
    } }
    if (-not $data.createUser.success -or -not $data.createUser.userId) { throw "Could not create demo user $($definition.alias)." }
    $users[[string]$definition.alias] = [string]$data.createUser.userId
    Write-Host "Created $($definition.alias) -> $($data.createUser.userId)" -ForegroundColor DarkCyan
}

$activationArgs = @(
    'activate-users', '--env-file', $EnvFile, '--development-seed', '--environment', 'Development',
    '--confirm', [string]$preflight.fingerprint, '--json'
)
if ($AllowRemoteDevelopmentDatabase) { $activationArgs += '--allow-remote-development-database' }
foreach ($definition in $manifestData.users) { $activationArgs += @('--email', [string]$definition.email) }
$null = Invoke-MaintenanceJson $activationArgs

foreach ($definition in $manifestData.users) {
    $data = Invoke-GraphQl @'
mutation LoginDemoUser($input: LoginInput!) {
  login(input: $input) { accessToken user { userId email status } }
}
'@ @{ input = @{ identifier = [string]$definition.email; password = $Password } }
    $tokens[[string]$definition.alias] = [string]$data.login.accessToken
}

foreach ($pair in $manifestData.friendships) {
    $requester = [string]$pair[0]; $receiver = [string]$pair[1]
    $null = Invoke-GraphQl 'mutation Friend($requester: Long!, $receiver: Long!) { sendFriendRequest(requesterId: $requester, receiverId: $receiver) }' @{ requester = [long]$users[$requester]; receiver = [long]$users[$receiver] } $tokens[$requester]
    $null = Invoke-GraphQl 'mutation Accept($requester: Long!, $receiver: Long!) { acceptFriendRequest(requesterId: $requester, receiverId: $receiver) }' @{ requester = [long]$users[$requester]; receiver = [long]$users[$receiver] } $tokens[$receiver]
}

foreach ($pair in $manifestData.follows) {
    $actor = [string]$pair[0]; $target = [string]$pair[1]
    $null = Invoke-GraphQl 'mutation Follow($actor: Long!, $target: Long!) { followUser(followerId: $actor, targetUserId: $target) }' @{ actor = [long]$users[$actor]; target = [long]$users[$target] } $tokens[$actor]
}
foreach ($pair in $manifestData.blocks) {
    $actor = [string]$pair[0]; $target = [string]$pair[1]
    $null = Invoke-GraphQl 'mutation Block($actor: Long!, $target: Long!) { blockUser(blockerId: $actor, blockedUserId: $target) }' @{ actor = [long]$users[$actor]; target = [long]$users[$target] } $tokens[$actor]
}

$groups = @{}
foreach ($definition in $manifestData.groups) {
    $owner = [string]$definition.owner
    $data = Invoke-GraphQl @'
mutation CreateDemoGroup($input: CreateGroupInput!) {
  createGroup(input: $input) { id name privacy memberCount adminCount }
}
'@ @{ input = @{ creatorId = [long]$users[$owner]; name = [string]$definition.name; bio = [string]$definition.bio; privacy = [int]$definition.privacy } } $tokens[$owner]
    $groupId = [string]$data.createGroup.id
    $groups[[string]$definition.alias] = $groupId
    foreach ($member in $definition.members) {
        $null = Invoke-GraphQl 'mutation AddMember($group: Long!, $user: Long!) { addGroupMember(groupId: $group, userId: $user) }' @{ group = [long]$groupId; user = [long]$users[[string]$member] } $tokens[$owner]
    }
}

$aliceMedia = Upload-DemoPng $tokens.alice 'alice-public-post'
$posts = @{}
foreach ($privacy in 0..3) {
    $media = if ($privacy -eq 0) { @(@{ type = 0; url = $aliceMedia.url }) } else { @() }
    $data = Invoke-GraphQl @'
mutation CreatePrivacyPost($input: CreateFeedPostInput!) {
  createFeedPost(input: $input) { id privacy }
}
'@ @{ input = @{
        authorId = [long]$users.alice
        content = "Demo privacy $privacy - deterministic Fakebook feed post"
        privacy = $privacy
        media = $media
        taggedUserIds = @()
        mentionedUserIds = @()
    } } $tokens.alice
    $posts["privacy$privacy"] = [string]$data.createFeedPost.id
}

$publicGroupPost = Invoke-GraphQl @'
mutation CreatePublicGroupPost($input: CreateGroupPostInput!) {
  createGroupPost(input: $input) { id }
}
'@ @{ input = @{ authorId = [long]$users.alice; groupId = [long]$groups.developers; content = 'Welcome to the Fakebook Developers demo group.'; media = @(); mentionedUserIds = @([long]$users.bob) } } $tokens.alice
$posts.publicGroup = [string]$publicGroupPost.createGroupPost.id

$privateGroupPost = Invoke-GraphQl @'
mutation CreatePrivateGroupPost($input: CreateGroupPostInput!) {
  createGroupPost(input: $input) { id }
}
'@ @{ input = @{ authorId = [long]$users.bob; groupId = [long]$groups.lab; content = 'Private Microservice Lab architecture notes.'; media = @(); mentionedUserIds = @([long]$users.carol) } } $tokens.bob
$posts.privateGroup = [string]$privateGroupPost.createGroupPost.id

$direct1 = Invoke-GraphQl 'mutation Direct($input: CreateDirectConversationInput!) { createDirectConversation(input: $input) { id } }' @{ input = @{ targetUserId = [long]$users.bob } } $tokens.alice
$direct2 = Invoke-GraphQl 'mutation Direct($input: CreateDirectConversationInput!) { createDirectConversation(input: $input) { id } }' @{ input = @{ targetUserId = [long]$users.bob } } $tokens.alice
if ([string]$direct1.createDirectConversation.id -ne [string]$direct2.createDirectConversation.id) { throw 'Direct conversation creation is not idempotent.' }
$conversationId = [string]$direct1.createDirectConversation.id
$message = Invoke-GraphQl 'mutation Send($input: SendMessageInput!) { sendMessage(input: $input) { id sequence } }' @{ input = @{ conversationId = $conversationId; clientMessageId = [guid]::NewGuid().ToString(); text = 'Hello Bob - deterministic demo message.'; attachmentUrls = @() } } $tokens.alice

Wait-Until {
    $search = Invoke-GraphQl 'query SearchAlice { searchUsers(keyword: "Alice", pageNumber: 1, pageSize: 10) { items { user { id } } } }' @{} $tokens.bob
    @($search.searchUsers.items | Where-Object { [string]$_.user.id -eq [string]$users.alice }).Count -gt 0
} 'Search indexing for Alice'

Wait-Until {
    $notifications = Invoke-GraphQl 'query DemoNotifications { notifications(first: 20, unreadOnly: false) { nodes { id } } }' @{} $tokens.bob
    @($notifications.notifications.nodes).Count -gt 0
} 'notification projection for Bob'

$receiptValue = [ordered]@{
    generatedAt = [DateTimeOffset]::UtcNow.ToString('O')
    gatewayUrl = $GatewayUrl
    users = $users
    groups = $groups
    posts = $posts
    directConversation = $conversationId
    firstMessage = [string]$message.sendMessage.id
}
$receiptDirectory = Split-Path -Parent $Receipt
if ($receiptDirectory) { New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null }
$receiptValue | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Receipt -Encoding utf8
Write-Host "Demo seed completed. Receipt: $Receipt" -ForegroundColor Green
