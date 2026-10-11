#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$script:PackageRoot = $PSScriptRoot
$script:PackageConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'package-config.json') -Raw | ConvertFrom-Json
function Get-PackagePython([string]$Override) {
    $candidate = if ($Override) { $Override } else { $script:PackageConfig.python_exe }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'Pass -PythonExe with Python 3.12+ that has requirements-client.txt installed.' }
    & $candidate -c 'import sys, websockets; assert sys.version_info >= (3, 12)'
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.12+ and the pinned client dependency are required.' }
    return $candidate
}
function Get-ActiveInstall {
    $path = Join-Path $script:PackageRoot 'runtime/active-install.json'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Run Install.ps1 first.' }
    $active = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($active.removed) { throw 'This installation has already been removed.' }
    return $active
}
