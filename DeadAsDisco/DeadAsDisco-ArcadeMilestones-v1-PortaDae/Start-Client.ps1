#requires -Version 7.2
param([string]$Server = 'ws://127.0.0.1:38281', [string]$PlayerName,
      [string]$PythonExe, [switch]$AllowRemote, [switch]$AskPassword)
. (Join-Path $PSScriptRoot 'PackageCommon.ps1')
$active = Get-ActiveInstall
if (-not $PythonExe) { $PythonExe = $active.python_exe }
$python = Get-PackagePython $PythonExe
if (-not $PlayerName) { $PlayerName = $active.player_name }
$arguments = @('-m', 'dad_ap.arcade_client', '--server', $Server, '--slot', $PlayerName,
    '--state-dir', $active.state_directory, '--adapter-plan', $active.plan)
if ($AllowRemote) { $arguments += '--allow-remote' }
if ($AskPassword) { $arguments += '--ask-password' }
Push-Location $PSScriptRoot
try { & $python @arguments } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw 'Client stopped with an error; inspect the console.' }
