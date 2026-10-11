param(
    [Parameter(Mandatory=$true)][string]$Plan,
    [Parameter(Mandatory=$true)][string]$Baseline,
    [Parameter(Mandatory=$true)][string]$SessionDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime_session_common.ps1')
Assert-GameClosed
$inputData = Read-SessionInputs $Plan $Baseline $SessionDirectory
$session = Get-SafePath $inputData.session -MustExist
$intentPath = Get-SafePath (Join-Path $session 'install-intent.json') -Within $session -MustExist
$intent = Get-Content -LiteralPath $intentPath -Raw | ConvertFrom-Json
if ($intent.schema_version -ne 1 -or $intent.game_bin -ne $script:SessionGameBin -or $intent.session_directory -ne $session -or
    $intent.plan_sha256 -ne $inputData.plan_sha256 -or $intent.baseline_sha256 -ne $inputData.baseline_sha256 -or
    $intent.proxy_absent_before -ne $true -or $intent.loader_absent_before -ne $true) { throw 'Session intent does not match these exact immutable inputs.' }
if ((Get-SessionHash (Join-Path $session 'inputs\plan.json')) -ne $intent.plan_sha256 -or
    (Get-SessionHash (Join-Path $session 'inputs\baseline.json')) -ne $intent.baseline_sha256) { throw 'Frozen session input copy changed.' }
if (Test-Path -LiteralPath (Join-Path $session 'removal-journal.json')) { throw 'Removal already recorded; preserve evidence and inspect before retrying.' }
$proxy = Get-SafePath (Join-Path $script:SessionGameBin 'dwmapi.dll') -Within $script:SessionGameBin
$loader = Get-SafePath (Join-Path $script:SessionGameBin 'ue4ss') -Within $script:SessionGameBin
# Capture first, even if a later installed-file verification refuses deletion.
$capture = Get-SafePath (Join-Path $session ('captures\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))) -Within $session
if (Test-Path -LiteralPath $capture) { throw 'Capture directory already exists.' }
New-SafeDirectory $capture
$captured = [Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $loader) {
    foreach ($source in @(Get-SafeTreeFiles $loader)) {
        $relative = [IO.Path]::GetRelativePath($loader, $source)
        $target = Get-RelativeTarget (Join-Path $capture 'installed-ue4ss') $relative
        $captured.Add((Copy-NewVerifiedFile $source $target))
    }
}
if (Test-Path -LiteralPath $proxy) { $captured.Add((Copy-NewVerifiedFile $proxy (Join-Path $capture 'dwmapi.dll'))) }
foreach ($name in @('SaveGames', 'SaveGamesBackup', 'Config')) {
    $sourceRoot = Join-Path $script:SessionSaved $name
    if (Test-Path -LiteralPath $sourceRoot) {
        foreach ($source in @(Get-SafeTreeFiles $sourceRoot)) {
            $relative = [IO.Path]::GetRelativePath($script:SessionSaved, $source)
            $captured.Add((Copy-NewVerifiedFile $source (Get-RelativeTarget (Join-Path $capture 'Saved') $relative)))
        }
    }
}
$gameLog = Join-Path $script:SessionSaved 'Logs\Pagoda.log'
if (Test-Path -LiteralPath $gameLog) {
    $captured.Add((Copy-NewVerifiedFile $gameLog (Join-Path $capture 'Saved\Logs\Pagoda.log')))
}
$initialWin64 = @{}
foreach ($entry in $inputData.baseline.entries | Where-Object kind -EQ 'win64_initial_file') { $initialWin64[$entry.source] = $true }
$extraWin64 = foreach ($file in Get-ChildItem -LiteralPath $script:SessionGameBin -File -Force) {
    if (-not $initialWin64.ContainsKey($file.FullName) -and $file.FullName -ne $proxy) {
        $row = Copy-NewVerifiedFile $file.FullName (Join-Path (Join-Path $capture 'Win64Extras') $file.Name)
        $captured.Add($row)
        $row
    }
}
Write-NewSessionJson (Join-Path $capture 'capture-manifest.json') ([ordered]@{ created_utc=[DateTime]::UtcNow.ToString('o'); entries=@($captured.ToArray()); unplanned_win64_files=@($extraWin64); saves_restored=$false })
$preAudit = @(Get-ProtectedAudit $inputData.baseline)
Write-NewSessionJson (Join-Path $capture 'protected-audit-before-removal.json') $preAudit
$installedChecks = foreach ($entry in $inputData.entries) {
    $exists = Test-Path -LiteralPath $entry.path
    $hash = if ($exists) { Get-SessionHash $entry.path } else { $null }
    [pscustomobject]@{ path=$entry.path; exists=$exists; expected_sha256=$entry.sha256; actual_sha256=$hash; matches=($exists -and $hash -eq $entry.sha256) }
}
Write-NewSessionJson (Join-Path $capture 'installed-file-verification.json') @($installedChecks)
if (@($installedChecks | Where-Object { $_.exists -and -not $_.matches }).Count) {
    throw "An installed file changed; all available evidence was captured at $capture. No loader file was removed."
}
$journalPath = Join-Path $session 'install-journal.json'
if (Test-Path -LiteralPath $journalPath) {
    $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    if ($journal.outcome -eq 'installed' -and @($installedChecks | Where-Object { -not $_.exists }).Count) { throw 'A completed installation has missing files; inspect captured evidence before removal.' }
}
# Recheck the exact deletion scope and captured hashes immediately before removal.
Assert-GameClosed
foreach ($row in $captured) {
    if ((Get-SessionHash $row.capture) -ne $row.sha256 -or (Get-SessionHash $row.source) -ne $row.sha256) { throw 'Evidence or source changed after capture; refusing removal.' }
}
if (Test-Path -LiteralPath $loader) {
    $resolved = Get-SafePath $loader -Within $script:SessionGameBin -MustExist
    if ($resolved -ne (Join-Path $script:SessionGameBin 'ue4ss') -or (Split-Path -Parent $resolved) -ne $script:SessionGameBin) { throw 'Deletion target is not the exact newly installed loader directory.' }
    $currentFiles = @(Get-SafeTreeFiles $resolved)
    $capturedLoader = @($captured | Where-Object { $_.source.StartsWith($loader + '\', [StringComparison]::OrdinalIgnoreCase) })
    if ($currentFiles.Count -ne $capturedLoader.Count) { throw 'Loader tree changed since capture.' }
    $capturedByPath = @{}
    foreach ($row in $capturedLoader) { $capturedByPath[$row.source] = $row }
    foreach ($file in $currentFiles) {
        if (-not $capturedByPath.ContainsKey($file)) { throw 'Loader pathname set changed since capture.' }
        $row = $capturedByPath[$file]
        if ((Get-SessionHash $file) -ne $row.sha256 -or (Get-SessionHash $row.capture) -ne $row.sha256) { throw 'Loader or captured content changed before deletion.' }
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if (Test-Path -LiteralPath $proxy) {
    Get-SafePath $proxy -Within $script:SessionGameBin -MustExist | Out-Null
    $proxyRecord = @($inputData.entries | Where-Object path -EQ $proxy)[0]
    Assert-FileRecord $proxy $proxyRecord
    Remove-Item -LiteralPath $proxy -Force
}
$postAudit = @(Get-ProtectedAudit $inputData.baseline)
$changed = @($postAudit | Where-Object status -NE 'unchanged')
$report = [ordered]@{ removed_utc=[DateTime]::UtcNow.ToString('o'); game_bin=$script:SessionGameBin; session_directory=$session; plan_sha256=$inputData.plan_sha256; baseline_sha256=$inputData.baseline_sha256; loader_removed=(-not (Test-Path -LiteralPath $loader) -and -not (Test-Path -LiteralPath $proxy)); capture=$capture; save_restore_performed=$false; all_baseline_entries_unchanged=($changed.Count -eq 0); changed_count=$changed.Count; entries=$postAudit; unplanned_win64_files=@($extraWin64) }
Write-NewSessionJson (Join-Path $session 'removal-journal.json') $report
[pscustomobject]@{ loader_removed=$report.loader_removed; capture=$capture; save_restore_performed=$false; changed_count=$changed.Count; changed=$changed; removal_journal=(Join-Path $session 'removal-journal.json') } | ConvertTo-Json -Depth 8
