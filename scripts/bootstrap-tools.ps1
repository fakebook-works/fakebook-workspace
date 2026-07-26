[CmdletBinding()]
param(
    [string]$ComposeVersion = 'v5.1.4',
    [string]$NitroVersion = '16.1.3'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$toolRoot = Join-Path $root '.tools'
New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null

$nitro = Join-Path $toolRoot 'nitro.exe'
if (-not (Test-Path -LiteralPath $nitro)) {
    & dotnet tool install ChilliCream.Nitro.CommandLine --version $NitroVersion --tool-path $toolRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Nitro CLI installation failed with exit code $LASTEXITCODE."
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
Write-Host 'Local Fakebook tools are installed and verified.' -ForegroundColor Green

