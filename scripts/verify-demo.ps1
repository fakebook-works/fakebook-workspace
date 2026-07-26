[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://127.0.0.1:2001/graphql',
    [string]$Manifest = (Join-Path $PSScriptRoot 'seed\demo.manifest.json'),
    [string]$Receipt = (Join-Path $PSScriptRoot 'seed\demo.receipt.json'),
    [string]$Password = $env:FAKEBOOK_DEMO_PASSWORD,
    [ValidateRange(5, 300)]
    [int]$RequestTimeoutSeconds = 30,
    [switch]$AllowRemoteDevelopmentDatabase,
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
            if (-not [Environment]::GetEnvironmentVariable($name)) { [Environment]::SetEnvironmentVariable($name, $value, 'Process') }
        }
    }
}

function Invoke-GraphQl {
    param([string]$Query, [hashtable]$Variables = @{}, [string]$Token)
    $headers = @{ Accept = 'application/json' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    $body = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 30 -Compress
    $response = Invoke-RestMethod -Uri $GatewayUrl -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec $RequestTimeoutSeconds
    if ($response.errors) { throw ((@($response.errors | ForEach-Object message) -join '; ')) }
    return $response.data
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Can-ReadPost([string]$Token, [string]$PostId) {
    $data = Invoke-GraphQl 'query VerifyPost($id: Long!) { postDetail(postId: $id) { id } }' @{ id = [long]$PostId } $Token
    return $null -ne $data.postDetail
}

Import-FakebookEnv $EnvFile
if ([string]::IsNullOrWhiteSpace($Password)) { $Password = $env:FAKEBOOK_DEMO_PASSWORD }
if ([string]::IsNullOrWhiteSpace($Password)) { throw 'Set FAKEBOOK_DEMO_PASSWORD or pass -Password.' }
if (-not (Test-Path -LiteralPath $Manifest)) { throw "Manifest not found: $Manifest" }
if (-not (Test-Path -LiteralPath $Receipt)) { throw "Seed receipt not found: $Receipt" }

$manifestData = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$receiptData = Get-Content -LiteralPath $Receipt -Raw | ConvertFrom-Json
$tokens = @{}
foreach ($definition in $manifestData.users) {
    $login = Invoke-GraphQl 'mutation Login($input: LoginInput!) { login(input: $input) { accessToken user { userId status } } }' @{ input = @{ identifier = [string]$definition.email; password = $Password } }
    Assert-True ([string]$login.login.user.userId -eq [string]$receiptData.users.($definition.alias)) "User id mismatch for $($definition.alias)."
    Assert-True ([int]$login.login.user.status -eq 1) "Demo user $($definition.alias) is not active."
    $tokens[[string]$definition.alias] = [string]$login.login.accessToken
}

$privacyPosts = @(
    [string]$receiptData.posts.privacy0,
    [string]$receiptData.posts.privacy1,
    [string]$receiptData.posts.privacy2,
    [string]$receiptData.posts.privacy3
)
foreach ($postId in $privacyPosts) { Assert-True (Can-ReadPost $tokens.alice $postId) "Alice cannot read her own post $postId." }
Assert-True (Can-ReadPost $tokens.bob $privacyPosts[0]) 'Bob cannot read Alice public post.'
Assert-True (Can-ReadPost $tokens.bob $privacyPosts[1]) 'Bob cannot read Alice friends+followers post.'
Assert-True (Can-ReadPost $tokens.bob $privacyPosts[2]) 'Bob cannot read Alice friends post.'
Assert-True (-not (Can-ReadPost $tokens.bob $privacyPosts[3])) 'Bob can read Alice only-author post.'
Assert-True (Can-ReadPost $tokens.erin $privacyPosts[1]) 'Current follower cannot read privacy=1 post.'
Assert-True (-not (Can-ReadPost $tokens.erin $privacyPosts[2])) 'Follower can incorrectly read friends-only post.'
Assert-True (-not (Can-ReadPost $tokens.frank $privacyPosts[1])) 'Stranger can incorrectly read privacy=1 post.'

$developers = Invoke-GraphQl 'query VerifyGroup($id: Long!) { group(groupId: $id) { id memberCount adminCount } groupViewerState(groupId: $id) { isMember isAdmin canViewPosts } }' @{ id = [long]$receiptData.groups.developers } $tokens.alice
Assert-True ([bool]$developers.groupViewerState.isAdmin) 'Developers owner is not an admin.'
Assert-True ([bool]$developers.groupViewerState.isMember) 'Group admin is not also a member.'
Assert-True ([long]$developers.group.memberCount -eq 3) 'Developers member count is not 3.'

$blocked = Invoke-GraphQl 'query VerifyBlock($profile: Long!) { relationshipState(userId: $profile) { isBlocked isBlockedBy } }' @{ profile = [long]$receiptData.users.erin } $tokens.dave
Assert-True ([bool]$blocked.relationshipState.isBlocked) 'Dave -> Erin block invariant is missing.'

$direct = Invoke-GraphQl 'mutation VerifyDirect($input: CreateDirectConversationInput!) { createDirectConversation(input: $input) { id } }' @{ input = @{ targetUserId = [long]$receiptData.users.bob } } $tokens.alice
Assert-True ([string]$direct.createDirectConversation.id -eq [string]$receiptData.directConversation) 'Direct conversation is not server-idempotent.'

$search = Invoke-GraphQl 'query VerifySearch { searchUsers(keyword: "Alice", pageNumber: 1, pageSize: 10) { items { user { id } } } }' @{} $tokens.bob
Assert-True (@($search.searchUsers.items | Where-Object { [string]$_.user.id -eq [string]$receiptData.users.alice }).Count -gt 0) 'Search does not contain Alice.'
$notifications = Invoke-GraphQl 'query VerifyNotifications { notifications(first: 20, unreadOnly: false) { nodes { id } unreadCount } }' @{} $tokens.bob
Assert-True (@($notifications.notifications.nodes).Count -gt 0) 'Bob has no seeded notifications.'

$preflightOutput = & dotnet run --project $maintenanceProject --no-restore -- preflight --env-file $EnvFile --json
if ($LASTEXITCODE -ne 0) { throw 'Maintenance preflight failed.' }
$preflight = @($preflightOutput | Where-Object { $_ -match '^\{' })[-1] | ConvertFrom-Json
if ($preflight.isRemote -and -not $AllowRemoteDevelopmentDatabase) { throw 'Remote invariant verification requires -AllowRemoteDevelopmentDatabase.' }
$invariantOutput = & dotnet run --project $maintenanceProject --no-restore -- invariants --env-file $EnvFile --json
if ($LASTEXITCODE -ne 0) { throw 'Database invariants failed.' }
$invariants = @($invariantOutput | Where-Object { $_ -match '^\{' })[-1] | ConvertFrom-Json
Assert-True ([bool]$invariants.success) 'Database invariant verification failed.'

Write-Host 'Demo verification passed: privacy 0/1/2/3, group admin/member, block, direct-chat idempotency, Search, Notification, media/outbox invariants.' -ForegroundColor Green
