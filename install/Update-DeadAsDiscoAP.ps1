<#
.SYNOPSIS
  Updates the Dead as Disco Archipelago mod: fetches the latest version, reinstalls the mod and installs the
  new .apworld into Archipelago. Run through Update.bat. Close the game first.
#>
param(
    [string]$SourceZip,       # use this zip instead of downloading (for testing)
    [string]$GameDir,
    [string]$ArchipelagoDir
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'update_source.json') -Raw | ConvertFrom-Json

function Get-Fingerprint {
    $files = @('dead_as_disco.apworld', 'mod\DeadAsDiscoAP\Scripts\main.lua',
               'mod\DeadAsDiscoAP\Scripts\meteor.lua', 'mod\DeadAsDiscoAP\Scripts\cars.lua') | ForEach-Object { Join-Path $Root $_ }
    ($files | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash }) -join ','
}

function Find-ArchipelagoWorlds {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($ArchipelagoDir) { $candidates.Add($ArchipelagoDir) }
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Archipelago*' -and $_.InstallLocation } |
            ForEach-Object { $candidates.Add($_.InstallLocation.TrimEnd('\')) }
    }
    $candidates.Add('C:\ProgramData\Archipelago')
    foreach ($dir in ($candidates | Select-Object -Unique)) {
        $worlds = Join-Path $dir 'custom_worlds'
        if (Test-Path -LiteralPath $worlds) { return $worlds }
    }
    return $null
}

if (Get-Process -Name 'PagodaSteam-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'Dead as Disco is running. Close it and run Update again.'
}
$before = Get-Fingerprint

if (-not $SourceZip -and (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
    Write-Host 'Updating with git...'
    git -C $Root pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw 'git pull failed; see the message above.' }
} else {
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "DeadAsDiscoAP-update-$(Get-Random)"
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $zip = $SourceZip
        if (-not $zip) {
            $zip = Join-Path $temp 'latest.zip'
            $url = "https://github.com/$($Source.repo)/archive/refs/heads/$($Source.branch).zip"
            Write-Host "Downloading $url"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            try {
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            } catch {
                throw "Download failed ($($_.Exception.Message)). If the GitHub repo is private, the download needs it to be public, or update with git instead (git clone, then run Update.bat inside that folder)."
            }
        }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $temp 'src')
        $new = Get-ChildItem -LiteralPath (Join-Path $temp 'src') -Recurse -Filter 'Install-DeadAsDiscoAP.ps1' |
            Select-Object -First 1
        if (-not $new) { throw 'The download does not look like the Dead as Disco AP mod.' }
        $newRoot = Split-Path -Parent $new.DirectoryName
        Copy-Item -Path (Join-Path $newRoot '*') -Destination $Root -Recurse -Force
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$installArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'install\Install-DeadAsDiscoAP.ps1'))
if ($GameDir) { $installArgs += @('-GameDir', $GameDir) }
& powershell @installArgs
if ($LASTEXITCODE -ne 0) { throw 'Installing the mod failed; see the message above.' }

$worlds = Find-ArchipelagoWorlds
if ($worlds) {
    Copy-Item -LiteralPath (Join-Path $Root 'dead_as_disco.apworld') -Destination $worlds -Force
    Write-Host "Installed dead_as_disco.apworld into $worlds"
} else {
    Write-Host 'Could not find Archipelago. Give dead_as_disco.apworld to its Launcher with "Install APWorld".'
}

Write-Host ''
if ((Get-Fingerprint) -eq $before) {
    Write-Host 'Already up to date.'
} else {
    Write-Host 'Updated! Restart the Archipelago Launcher / Dead as Disco Client to use the new version.'
}
