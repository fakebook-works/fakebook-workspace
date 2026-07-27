[CmdletBinding()]
param(
    [string]$ComposeVersion = 'v5.1.4',
    [string]$NitroVersion = '16.1.3',
    [string]$GarnetVersion = '2.1.0',
    [string]$GarnetSha256 = 'b810ee558d3db7211f4c34175ec46c736a8b8984f7e457ec5d3ebbd9b703569c'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$toolRoot = Join-Path $root '.tools'
New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
$dotnet = & (Join-Path $PSScriptRoot 'resolve-dotnet.ps1')

$nitro = Join-Path $toolRoot 'nitro.exe'
if (-not (Test-Path -LiteralPath $nitro)) {
    & $dotnet tool install ChilliCream.Nitro.CommandLine --version $NitroVersion --tool-path $toolRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Nitro CLI installation failed with exit code $LASTEXITCODE."
    }
}

# Microsoft Garnet provides the Redis protocol used by nonce replay protection in
# host-mode development. Docker Compose continues to use redis-stack-server.
$garnetRoot = Join-Path $toolRoot "garnet-$GarnetVersion"
$garnet = Join-Path $garnetRoot 'GarnetServer.exe'
if (-not (Test-Path -LiteralPath $garnet)) {
    $garnetArchive = Join-Path $toolRoot "garnet-$GarnetVersion-win-x64.zip"
    if (-not (Test-Path -LiteralPath $garnetArchive)) {
        $garnetAsset = "https://github.com/microsoft/garnet/releases/download/v$GarnetVersion/win-x64-based-readytorun.zip"
        Invoke-WebRequest -Uri $garnetAsset -OutFile $garnetArchive -UseBasicParsing
    }
    $actualGarnetHash = (Get-FileHash -LiteralPath $garnetArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualGarnetHash -ne $GarnetSha256.ToLowerInvariant()) {
        throw 'Microsoft Garnet checksum verification failed.'
    }
    if (-not (Test-Path -LiteralPath $garnetRoot)) {
        New-Item -ItemType Directory -Path $garnetRoot | Out-Null
        Expand-Archive -LiteralPath $garnetArchive -DestinationPath $garnetRoot
    }
    if (-not (Test-Path -LiteralPath $garnet)) {
        $discovered = Get-ChildItem -LiteralPath $garnetRoot -Recurse -Filter GarnetServer.exe | Select-Object -First 1
        if (-not $discovered) { throw 'GarnetServer.exe was not found in the verified release archive.' }
        $garnet = $discovered.FullName
    }
}
else {
    Write-Host 'Nitro CLI is already present.'
}

$compose = Join-Path $toolRoot 'docker-compose.exe'
$checksumPath = "$compose.sha256"
if (-not (Test-Path -LiteralPath $compose)) {
    $asset = "https://github.com/docker/compose/releases/download/$ComposeVersion/docker-compose-windows-x86_64.exe"
    Invoke-WebRequest -Uri $asset -OutFile $compose -UseBasicParsing
    Invoke-WebRequest -Uri "$asset.sha256" -OutFile $checksumPath -UseBasicParsing
}

if (-not (Test-Path -LiteralPath $checksumPath)) {
    $asset = "https://github.com/docker/compose/releases/download/$ComposeVersion/docker-compose-windows-x86_64.exe"
    Invoke-WebRequest -Uri "$asset.sha256" -OutFile $checksumPath -UseBasicParsing
}

$expected = ((Get-Content -LiteralPath $checksumPath -Encoding ASCII).Split(
    ' ', [System.StringSplitOptions]::RemoveEmptyEntries)[0]).ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $compose -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) {
    throw 'Docker Compose checksum verification failed.'
}

& $nitro --version
& $compose version
Write-Host "Microsoft Garnet $GarnetVersion is checksum-verified."
Write-Host 'Local Fakebook tools are installed and verified.' -ForegroundColor Green
