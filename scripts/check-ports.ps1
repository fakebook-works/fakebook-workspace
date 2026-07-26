[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$excluded = '\\(bin|obj|node_modules|dist|build|\.git|\.venv|\.tools|\.run|\.artifacts|coverage)\\'
$extensions = '.cs', '.ts', '.tsx', '.js', '.jsx', '.py', '.md', '.json', '.yml', '.yaml', '.ps1'
$forbidden = @(
    'localhost:5000', 'localhost:5001', 'localhost:5010',
    'localhost:5013', 'localhost:5016', 'localhost:5050',
    'localhost:5191', 'localhost:5223',
    'authentication:5001', 'social-graph:5223', 'socialgraph:5223',
    'search:8080', 'messaging:5013', 'payment:5016',
    'EXPOSE 5013', 'EXPOSE 5016', 'EXPOSE 8080',
    'ASPNETCORE_HTTP_PORTS=8080', 'ASPNETCORE_URLS=http://+:5013',
    'ASPNETCORE_URLS=http://+:5016'
)

$matches = foreach ($file in Get-ChildItem $root -Recurse -File | Where-Object {
    $_.FullName -ne $PSCommandPath -and
    $_.FullName -notmatch $excluded -and
    ($_.Extension -in $extensions -or $_.Name -eq 'Dockerfile')
}) {
    Select-String -LiteralPath $file.FullName -Encoding UTF8 -SimpleMatch -Pattern $forbidden
}

if ($matches) {
    $matches | Select-Object Path, LineNumber, Line | Format-Table -AutoSize
    throw 'Legacy Fakebook service ports were found.'
}

Write-Host 'All checked service URLs use the canonical Fakebook ports.' -ForegroundColor Green
