[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
$workspaceSdk = Join-Path $root '.tools\dotnet10\dotnet.exe'
if (Test-Path -LiteralPath $workspaceSdk) {
    Write-Output $workspaceSdk
    return
}

$command = Get-Command dotnet -ErrorAction Stop
Write-Output $command.Source
