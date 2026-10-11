param(
    [Parameter(Mandatory=$true)][string]$Plan,
    [Parameter(Mandatory=$true)][string]$Baseline,
    [Parameter(Mandatory=$true)][string]$SessionDirectory,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime_session_common.ps1')
Assert-GameClosed
$inputData = Read-SessionInputs $Plan $Baseline $SessionDirectory
if (Test-Path -LiteralPath $inputData.session) { throw 'Session directory already exists; use a new session without overwriting evidence.' }
$proxy = Get-SafePath (Join-Path $script:SessionGameBin 'dwmapi.dll') -Within $script:SessionGameBin
$loader = Get-SafePath (Join-Path $script:SessionGameBin 'ue4ss') -Within $script:SessionGameBin
if ((Test-Path -LiteralPath $proxy) -or (Test-Path -LiteralPath $loader)) { throw 'Existing proxy or UE4SS directory; refusing installation.' }
foreach ($entry in $inputData.entries) { if (Test-Path -LiteralPath $entry.path) { throw "Install target already exists: $($entry.path)" } }
$audit = @(Get-ProtectedAudit $inputData.baseline)
if (@($audit | Where-Object status -NE 'unchanged').Count) { throw 'Protected saves/config/mods/game files differ from the supplied baseline; create/review a fresh baseline.' }
if ($ValidateOnly) {
    [pscustomobject]@{ validated=$true; live_files_modified=$false; file_count=$inputData.entries.Count; session=$inputData.session } | ConvertTo-Json
    return
}
New-SafeDirectory $inputData.session
Copy-NewVerifiedFile $inputData.plan_path (Join-Path $inputData.session 'inputs\plan.json') | Out-Null
Copy-NewVerifiedFile $inputData.baseline_path (Join-Path $inputData.session 'inputs\baseline.json') | Out-Null
if ((Get-SessionHash (Join-Path $inputData.session 'inputs\plan.json')) -ne $inputData.plan_sha256 -or
    (Get-SessionHash $inputData.plan_path) -ne $inputData.plan_sha256 -or
    (Get-SessionHash (Join-Path $inputData.session 'inputs\baseline.json')) -ne $inputData.baseline_sha256 -or
    (Get-SessionHash $inputData.baseline_path) -ne $inputData.baseline_sha256) { throw 'Plan or baseline changed while freezing session inputs; no live copy started.' }
$intent = [ordered]@{ schema_version=1; created_utc=[DateTime]::UtcNow.ToString('o'); game_bin=$script:SessionGameBin; session_directory=$inputData.session; plan_path=$inputData.plan_path; baseline_path=$inputData.baseline_path; plan_sha256=$inputData.plan_sha256; baseline_sha256=$inputData.baseline_sha256; proxy_absent_before=$true; loader_absent_before=$true; entries=$inputData.entries; protected_audit=$audit }
Write-NewSessionJson (Join-Path $inputData.session 'install-intent.json') $intent
$installed = [Collections.Generic.List[object]]::new()
$outcome = 'incomplete'
try {
    Assert-GameClosed
    foreach ($entry in $inputData.entries) {
        Assert-FileRecord $entry.source $entry
        Copy-NewVerifiedFile $entry.source $entry.path | Out-Null
        $installed.Add([pscustomobject]@{ path=$entry.path; sha256=$entry.sha256; bytes=$entry.bytes })
        Assert-FileRecord $entry.path $entry
    }
    $outcome = 'installed'
} finally {
    $journal = [ordered]@{ schema_version=1; outcome=$outcome; created_utc=[DateTime]::UtcNow.ToString('o'); game_bin=$script:SessionGameBin; session_directory=$inputData.session; plan_sha256=$inputData.plan_sha256; baseline_sha256=$inputData.baseline_sha256; entries=@($installed.ToArray()); no_preexisting_file_overwritten=$true }
    Write-NewSessionJson (Join-Path $inputData.session 'install-journal.json') $journal
}
[pscustomobject]@{ outcome=$outcome; installed_count=$installed.Count; install_journal=(Join-Path $inputData.session 'install-journal.json') } | ConvertTo-Json
