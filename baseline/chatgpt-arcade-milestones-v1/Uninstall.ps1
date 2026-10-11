#requires -Version 7.2
. (Join-Path $PSScriptRoot 'PackageCommon.ps1')
. (Join-Path $PSScriptRoot 'scripts/runtime_session_common.ps1')
Assert-GameClosed
$active = Get-ActiveInstall
$mods = Join-Path $script:SessionGameBin 'ue4ss/Mods'
if (Test-Path -LiteralPath $mods) {
    foreach ($entry in Get-ChildItem -LiteralPath $mods -Force) {
        if ($entry.Name -notin @('DADAPProbe', 'mods.txt')) { throw 'Additional UE4SS mods were added. Preserve them and remove them separately before using this uninstaller.' }
    }
}
& (Join-Path $PSScriptRoot 'scripts/remove_observer_session.ps1') -Plan $active.plan -Baseline $active.baseline -SessionDirectory $active.session_directory
$active.removed = $true
$active | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime/active-install.json') -Encoding utf8
Write-Host 'AP loader removed. Current saves and gameplay progress were preserved; no save backup was restored.'
