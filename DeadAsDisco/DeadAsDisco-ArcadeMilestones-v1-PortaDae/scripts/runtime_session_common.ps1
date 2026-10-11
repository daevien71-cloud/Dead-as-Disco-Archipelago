# Shared literal-path and evidence helpers. Dot-sourcing performs no live action.
Set-StrictMode -Version Latest
$script:SessionTaskRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$script:SessionGameBin = 'C:\Program Files (x86)\Steam\steamapps\common\Dead as Disco\Pagoda\Binaries\Win64'
$script:SessionSaved = 'C:\Users\sip22\AppData\Local\Pagoda\Saved'
$script:SessionMods = 'C:\Program Files (x86)\Steam\steamapps\common\Dead as Disco\Pagoda\Content\Paks\~mods'

function Assert-GameClosed {
    if (@(Get-Process | Where-Object ProcessName -Match '^Pagoda').Count) { throw 'Pagoda is running; no install/remove action is permitted.' }
}

function Get-SafePath([string]$Path, [string]$Within = '', [switch]$MustExist) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw "Only local drive paths without alternate streams are permitted: $Path" }
    foreach ($part in $full.Substring(3).Split('\')) {
        if ($part -match '[ .]$') { throw "Ambiguous trailing characters in path: $Path" }
    }
    if ($Within) {
        $root = [IO.Path]::GetFullPath($Within).TrimEnd('\')
        if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Path escaped required root: $full" }
    }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point refused: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    if (Test-Path -LiteralPath $full) {
        $resolved = (Resolve-Path -LiteralPath $full).Path.TrimEnd('\')
        if (-not $resolved.Equals($full, [StringComparison]::OrdinalIgnoreCase)) { throw "Resolved target differs: $full" }
    } elseif ($MustExist) { throw "Required path missing: $full" }
    return $full
}

function Get-RelativeTarget([string]$Root, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative)) { throw 'Rooted relative path refused.' }
    $segments = $Relative -split '[\\/]'
    if (-not $segments.Count) { throw 'Empty relative path.' }
    foreach ($part in $segments) {
        if (-not $part -or $part -in @('.', '..') -or $part -match '[ .]$' -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "Unsafe relative path: $Relative"
        }
    }
    return Get-SafePath -Path (Join-Path $Root ($segments -join '\')) -Within $Root
}

function Get-SafeTreeFiles([string]$Root) {
    $safeRoot = Get-SafePath $Root -MustExist
    $stack = [Collections.Generic.Stack[string]]::new()
    $stack.Push($safeRoot)
    while ($stack.Count) {
        foreach ($entry in Get-ChildItem -LiteralPath $stack.Pop() -Force) {
            $safe = Get-SafePath $entry.FullName -Within $safeRoot -MustExist
            if ($entry.PSIsContainer) { $stack.Push($safe) } else { Write-Output $safe }
        }
    }
}

function Get-SessionHash([string]$Path) {
    $safe = Get-SafePath $Path -MustExist
    if ((Get-Item -LiteralPath $safe).PSIsContainer) { throw "File required: $safe" }
    return (Get-FileHash -LiteralPath $safe -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-FileRecord([string]$Path, $Record) {
    if ($Record.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$Record.bytes -lt 0) { throw 'Malformed hash or size in manifest.' }
    if ((Get-SessionHash $Path) -ne $Record.sha256.ToLowerInvariant() -or (Get-Item -LiteralPath $Path).Length -ne [long]$Record.bytes) {
        throw "File differs from immutable manifest: $Path"
    }
}

function New-SafeDirectory([string]$Path) {
    $safe = Get-SafePath $Path
    [IO.Directory]::CreateDirectory($safe) | Out-Null
    Get-SafePath $safe -MustExist | Out-Null
}

function Copy-NewVerifiedFile([string]$Source, [string]$Destination) {
    $sourceSafe = Get-SafePath $Source -MustExist
    $destinationSafe = Get-SafePath $Destination
    if (Test-Path -LiteralPath $destinationSafe) { throw "Refusing overwrite: $destinationSafe" }
    $sourceMetadata = Get-Item -LiteralPath $sourceSafe
    $sourceCreated = $sourceMetadata.CreationTimeUtc.ToString('o')
    $sourceLastWrite = $sourceMetadata.LastWriteTimeUtc.ToString('o')
    $before = Get-SessionHash $sourceSafe
    New-SafeDirectory (Split-Path -Parent $destinationSafe)
    [IO.File]::Copy($sourceSafe, $destinationSafe, $false)
    if ((Get-SessionHash $destinationSafe) -ne $before -or (Get-SessionHash $sourceSafe) -ne $before) {
        throw "Source changed or capture hash mismatch: $sourceSafe"
    }
    return [pscustomobject]@{ source=$sourceSafe; capture=$destinationSafe; bytes=(Get-Item -LiteralPath $destinationSafe).Length; sha256=$before; source_creation_utc=$sourceCreated; source_last_write_utc=$sourceLastWrite }
}

function Write-NewSessionJson([string]$Path, $Value) {
    $safe = Get-SafePath $Path
    New-SafeDirectory (Split-Path -Parent $safe)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 12) + "`n")
    $stream = [IO.File]::Open($safe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function Read-SessionInputs([string]$Plan, [string]$Baseline, [string]$SessionDirectory) {
    $planPath = Get-SafePath $Plan -Within $script:SessionTaskRoot -MustExist
    $baselinePath = Get-SafePath $Baseline -Within (Join-Path $script:SessionTaskRoot 'runtime\game-baselines') -MustExist
    $session = Get-SafePath $SessionDirectory -Within (Join-Path $script:SessionTaskRoot 'runtime\observer-sessions')
    $planData = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    $baselineData = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
    $stage = Get-SafePath $planData.staging_root -Within $script:SessionTaskRoot -MustExist
    $backup = Get-SafePath $baselineData.backup_root -Within (Join-Path $script:SessionTaskRoot 'runtime\game-baselines') -MustExist
    if ($backup -ne (Split-Path -Parent $baselinePath)) { throw 'Baseline manifest and backup directory differ.' }
    $seen = @{}
    $allowedFiles = @('dwmapi.dll', 'ue4ss\LICENSE', 'ue4ss\UE4SS.dll', 'ue4ss\UE4SS-settings.ini',
        'ue4ss\Mods\mods.txt', 'ue4ss\Mods\DADAPProbe\Scripts\main.lua',
        'ue4ss\Mods\DADAPMetadata\Scripts\main.lua', 'ue4ss\Mods\DADAPGASMetadata\Scripts\main.lua',
        'ue4ss\Mods\DADAPMetadata\Scripts\activation.json')
    $entries = foreach ($entry in $planData.entries) {
        $relative = $entry.relative_path.Replace('/', '\')
        if ($relative -notin $allowedFiles) {
            throw "Install plan contains a non-loader target: $relative"
        }
        $source = Get-RelativeTarget $stage $relative
        $destination = Get-RelativeTarget $script:SessionGameBin $relative
        if ($seen.ContainsKey($destination)) { throw 'Duplicate case-insensitive install target.' }
        $seen[$destination] = $true
        Assert-FileRecord $source $entry
        [pscustomobject]@{ path=$destination; source=$source; relative_path=$relative; sha256=$entry.sha256.ToLowerInvariant(); bytes=[long]$entry.bytes }
    }
    if (-not $seen.ContainsKey((Join-Path $script:SessionGameBin 'dwmapi.dll')) -or -not $seen.ContainsKey((Join-Path $script:SessionGameBin 'ue4ss\UE4SS.dll'))) {
        throw 'Plan must include the exact proxy and UE4SS library.'
    }
    foreach ($requiredKind in @('save_or_config', 'accepted_mod_readonly_hash', 'game_executable_readonly_hash', 'win64_initial_file')) {
        if (-not @($baselineData.entries | Where-Object kind -EQ $requiredKind).Count) { throw "Baseline lacks protected class: $requiredKind" }
    }
    foreach ($entry in $baselineData.entries) {
        switch ($entry.kind) {
            'save_or_config' { Get-SafePath $entry.source -Within $script:SessionSaved -MustExist:$false | Out-Null }
            'accepted_mod_readonly_hash' { Get-SafePath $entry.source -Within $script:SessionMods -MustExist:$false | Out-Null }
            'game_executable_readonly_hash' {
                if ($entry.source -ne (Join-Path $script:SessionGameBin 'PagodaSteam-Win64-Shipping.exe')) { throw 'Unexpected game executable baseline.' }
            }
            'win64_initial_file' {
                $initial = Get-SafePath $entry.source -Within $script:SessionGameBin
                if ((Split-Path -Parent $initial) -ne $script:SessionGameBin) { throw 'Unexpected nested Win64 baseline file.' }
            }
            default { throw "Unknown baseline kind: $($entry.kind)" }
        }
        if ($entry.kind -in @('save_or_config', 'accepted_mod_readonly_hash')) {
            $copy = Get-SafePath $entry.backup -Within $backup -MustExist
            Assert-FileRecord $copy $entry
        }
    }
    return [pscustomobject]@{ plan_path=$planPath; baseline_path=$baselinePath; session=$session; stage=$stage; plan=$planData; baseline=$baselineData; entries=@($entries); plan_sha256=(Get-SessionHash $planPath); baseline_sha256=(Get-SessionHash $baselinePath) }
}

function Get-ProtectedAudit($BaselineData) {
    $seen = @{}
    $hashes = @{}
    foreach ($entry in $BaselineData.entries) {
        $source = Get-SafePath $entry.source
        $seen[$source] = $true
        if (-not $hashes.ContainsKey($source)) { $hashes[$source] = if (Test-Path -LiteralPath $source) { Get-SessionHash $source } else { $null } }
        $hash = $hashes[$source]
        [pscustomobject]@{ source=$source; kind=$entry.kind; status=$(if ($hash -eq $entry.sha256) { 'unchanged' } elseif ($null -eq $hash) { 'missing' } else { 'changed' }); before_sha256=$entry.sha256; after_sha256=$hash }
    }
    $roots = @((Join-Path $script:SessionSaved 'SaveGames'), (Join-Path $script:SessionSaved 'SaveGamesBackup'), (Join-Path $script:SessionSaved 'Config'), $script:SessionMods)
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) {
            foreach ($source in Get-SafeTreeFiles $root) {
                if (-not $seen.ContainsKey($source)) {
                    $kind = if ($root -eq $script:SessionMods) { 'accepted_mod_readonly_hash' } else { 'save_or_config' }
                    [pscustomobject]@{ source=$source; kind=$kind; status='added'; before_sha256=$null; after_sha256=(Get-SessionHash $source) }
                }
            }
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $script:SessionGameBin -File -Force) {
        $source = Get-SafePath $file.FullName -Within $script:SessionGameBin -MustExist
        if (-not $seen.ContainsKey($source)) {
            [pscustomobject]@{ source=$source; kind='win64_initial_file'; status='added'; before_sha256=$null; after_sha256=(Get-SessionHash $source) }
        }
    }
}
