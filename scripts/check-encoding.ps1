[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
$extensions = '.cs', '.ts', '.tsx', '.js', '.jsx', '.py', '.md', '.json', '.yml', '.yaml'
$excluded = '\\(bin|obj|node_modules|dist|build|\.git|\.venv|\.artifacts|coverage)\\'
$badPatterns = @(
    ([char]0x00C3).ToString(),
    ([char]0x00C2).ToString(),
    ([char]0xFFFD).ToString(),
    (([char]0x00E1).ToString() + [char]0x00BB),
    (([char]0x00E1).ToString() + [char]0x00BA),
    (([char]0x00C4).ToString() + [char]0x2018),
    (([char]0x00C4).ToString() + [char]0x0192),
    (([char]0x00C6).ToString() + [char]0x00B0),
    (([char]0x00C6).ToString() + [char]0x00A1)
)

$matches = foreach ($file in Get-ChildItem $root -Recurse -File |
    Where-Object { $_.Extension -in $extensions -and $_.FullName -notmatch $excluded }) {
    Select-String -LiteralPath $file.FullName -Encoding UTF8 -CaseSensitive -Pattern $badPatterns
}

if ($matches) {
    $matches | Select-Object Path, LineNumber, Line | Format-Table -AutoSize
    throw 'Common UTF-8 mojibake sequences were found.'
}

Write-Host 'No common UTF-8 mojibake sequences were found.' -ForegroundColor Green
