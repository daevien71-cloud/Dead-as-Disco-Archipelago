#requires -Version 7.2
param([string]$PythonExe, [int]$Port = 38281, [string]$Session = 'arcade-milestones-v1')
. (Join-Path $PSScriptRoot 'PackageCommon.ps1')
$python = Get-PackagePython $PythonExe
$hostScript = $script:PackageConfig.host_script
if (-not (Test-Path -LiteralPath $hostScript -PathType Leaf)) { throw 'The original workspace Archipelago host dependency is missing. Use an official Archipelago host with the included seed archive.' }
$seed = Join-Path $PSScriptRoot $script:PackageConfig.seed_archive
& $python $hostScript serve $seed --port $Port --session $Session --auto-shutdown 600
if ($LASTEXITCODE -ne 0) { throw 'Local host stopped with an error.' }
