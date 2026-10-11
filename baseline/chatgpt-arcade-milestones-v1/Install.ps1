#requires -Version 7.2
param([string]$PythonExe, [string]$SeedName, [int]$Team = 0, [int]$Slot = 1,
      [string]$PlayerName, [switch]$ValidateOnly)
. (Join-Path $PSScriptRoot 'PackageCommon.ps1')
. (Join-Path $PSScriptRoot 'scripts/runtime_session_common.ps1')
Assert-GameClosed
$python = Get-PackagePython $PythonExe
if (-not $SeedName) { $SeedName = $script:PackageConfig.seed_name }
if (-not $PlayerName) { $PlayerName = $script:PackageConfig.player_name }
$exe = Join-Path $script:SessionGameBin 'PagodaSteam-Win64-Shipping.exe'
if ((Get-SessionHash $exe) -ne $script:PackageConfig.game_exe_sha256) { throw 'Game build changed; this experimental adapter only supports the recorded PortaDae build.' }
$activePath = Join-Path $PSScriptRoot 'runtime/active-install.json'
if (Test-Path -LiteralPath $activePath) {
    $old = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
    if (-not $old.removed) { throw 'An installation is already recorded. Run Uninstall.ps1 before installing another seed.' }
}
if ((Test-Path -LiteralPath (Join-Path $script:SessionGameBin 'dwmapi.dll')) -or
    (Test-Path -LiteralPath (Join-Path $script:SessionGameBin 'ue4ss'))) { throw 'Existing UE4SS installation found. No files were changed.' }
New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'evidence') -Force | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
$stage = Join-Path $PSScriptRoot "runtime/prepared/$stamp"
$session = Join-Path $PSScriptRoot "runtime/installed/$stamp"
$state = Join-Path $PSScriptRoot 'runtime/state'
$prepText = & $python (Join-Path $PSScriptRoot 'scripts/prepare_arcade_checks_runtime.py') --session-directory $stage --state-dir $state --seed-name $SeedName --team $Team --slot $Slot --accept-owner-calibration
if ($LASTEXITCODE -ne 0) { throw 'Adapter preparation failed; game untouched.' }
$prep = ($prepText -join "`n") | ConvertFrom-Json
$backupText = & $python (Join-Path $PSScriptRoot 'scripts/snapshot_game_baseline.py')
if ($LASTEXITCODE -ne 0) { throw 'Current-save backup failed; game untouched.' }
$backup = ($backupText -join "`n") | ConvertFrom-Json
$active = [ordered]@{ plan=$prep.plan; baseline=$backup.manifest; session_directory=$session; state_directory=$state;
    python_exe=$python; player_name=$PlayerName; seed_name=$SeedName; team=$Team; slot=$Slot; removed=$false }
if (-not $ValidateOnly) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $activePath) -Force | Out-Null
    $active | ConvertTo-Json | Set-Content -LiteralPath $activePath -Encoding utf8
}
& (Join-Path $PSScriptRoot 'scripts/install_observer_session.ps1') -Plan $prep.plan -Baseline $backup.manifest -SessionDirectory $session -ValidateOnly:$ValidateOnly
if (-not $ValidateOnly) { Write-Host 'Installed. Start the AP host, then Start-Client.ps1; wait for connection before starting a fresh Arcade run in Steam.' }
