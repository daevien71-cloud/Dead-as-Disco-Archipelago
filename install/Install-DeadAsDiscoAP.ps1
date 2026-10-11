<#
.SYNOPSIS
  Installs the Dead as Disco Archipelago mod (and UE4SS, if it isn't installed yet).

.DESCRIPTION
  Run from the release folder or the repo: powershell -ExecutionPolicy Bypass -File Install-DeadAsDiscoAP.ps1
  Close the game first. Game saves are never touched.
  Use -Uninstall to remove the mod (and UE4SS, if this script installed it and no other mods use it).
#>
param(
    [string]$GameDir,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ModName = 'DeadAsDiscoAP'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-PackageFile([string]$Relative) {
    foreach ($base in @($Here, (Split-Path -Parent $Here))) {
        $candidate = Join-Path $base $Relative
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw "Could not find $Relative next to this script."
}

function Find-GameDir {
    $libraries = New-Object System.Collections.Generic.List[string]
    try {
        $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
        if ($steam) { $libraries.Add(($steam -replace '/', '\')) }
    } catch { }
    $libraries.Add('C:\Program Files (x86)\Steam')
    foreach ($steamRoot in @($libraries)) {
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($match in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libraries.Add(($match.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }
    foreach ($library in ($libraries | Select-Object -Unique)) {
        $dir = Join-Path $library 'steamapps\common\Dead as Disco'
        if (Test-Path -LiteralPath (Join-Path $dir 'Pagoda\Binaries\Win64\PagodaSteam-Win64-Shipping.exe')) { return $dir }
    }
    throw 'Could not find Dead as Disco in your Steam libraries. Pass -GameDir "<path to Dead as Disco folder>".'
}

function Set-ModsTxtEntry([string]$Path, [string]$Name, [int]$Enabled) {
    $lines = @()
    if (Test-Path -LiteralPath $Path) { $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() -ne '' }) }
    $lines = @($lines | Where-Object { $_ -notmatch "^\s*$([regex]::Escape($Name))\s*:" })
    if ($Enabled -ge 0) { $lines += "$Name : $Enabled" }
    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}

if (-not $GameDir) { $GameDir = Find-GameDir }
$Win64 = Join-Path $GameDir 'Pagoda\Binaries\Win64'
if (-not (Test-Path -LiteralPath (Join-Path $Win64 'PagodaSteam-Win64-Shipping.exe'))) {
    throw "$GameDir doesn't look like the Dead as Disco folder."
}
if (Get-Process -Name 'PagodaSteam-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'Dead as Disco is running. Close it and run this again.'
}

$Ue4ssDir = Join-Path $Win64 'ue4ss'
$ModsDir = Join-Path $Ue4ssDir 'Mods'
$ModDir = Join-Path $ModsDir $ModName
$RecordPath = Join-Path $Win64 'DeadAsDiscoAP-install.json'
$BridgeDir = Join-Path $env:LOCALAPPDATA 'DeadAsDiscoAP'

try {
    if ($Uninstall) {
        $record = $null
        if (Test-Path -LiteralPath $RecordPath) { $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json }
        if (Test-Path -LiteralPath $ModDir) { Remove-Item -LiteralPath $ModDir -Recurse -Force }
        if (Test-Path -LiteralPath (Join-Path $ModsDir 'mods.txt')) { Set-ModsTxtEntry (Join-Path $ModsDir 'mods.txt') $ModName -1 }
        if ($record -and $record.installed_ue4ss) {
            $stock = @('BPML_GenericFunctions', 'BPModLoaderMod', 'CheatManagerEnablerMod', 'ConsoleCommandsMod',
                       'ConsoleEnablerMod', 'Keybinds', 'LineTraceMod', 'SplitScreenMod', 'shared')
            $others = @(Get-ChildItem -LiteralPath $ModsDir -Directory | Where-Object { $stock -notcontains $_.Name })
            if ($others.Count -eq 0) {
                Remove-Item -LiteralPath $Ue4ssDir -Recurse -Force
                Remove-Item -LiteralPath (Join-Path $Win64 'dwmapi.dll') -Force
                Write-Host 'Removed UE4SS (this installer had added it).'
            } else {
                Write-Host "Left UE4SS in place because other mods use it: $($others.Name -join ', ')"
            }
        }
        if (Test-Path -LiteralPath $RecordPath) { Remove-Item -LiteralPath $RecordPath -Force }
        Write-Host 'Dead as Disco AP mod removed. Your saves were not touched.'
        return
    }

    $installedUe4ss = $false
    if (-not (Test-Path -LiteralPath (Join-Path $Win64 'dwmapi.dll'))) {
        $zip = Find-PackageFile 'third_party\UE4SS_v3.0.1-1164-g5e627997.zip'
        Write-Host "Installing UE4SS into $Win64"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($entry in $archive.Entries) {
                $target = Join-Path $Win64 ($entry.FullName -replace '/', '\')
                if ($entry.FullName.EndsWith('/')) { New-Item -ItemType Directory -Force -Path $target | Out-Null; continue }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        } finally { $archive.Dispose() }
        # Only our mod runs; the sample mods that ship with UE4SS stay off.
        $modsJson = Join-Path $ModsDir 'mods.json'
        if (Test-Path -LiteralPath $modsJson) { Remove-Item -LiteralPath $modsJson -Force }
        Set-Content -LiteralPath (Join-Path $ModsDir 'mods.txt') -Encoding ASCII -Value @(
            'CheatManagerEnablerMod : 0', 'ConsoleCommandsMod : 0', 'ConsoleEnablerMod : 0', 'SplitScreenMod : 0',
            'LineTraceMod : 0', 'BPML_GenericFunctions : 0', 'BPModLoaderMod : 0', 'Keybinds : 0')
        $installedUe4ss = $true
    } elseif (Test-Path -LiteralPath $RecordPath) {
        $installedUe4ss = [bool](Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json).installed_ue4ss
    }

    $source = Find-PackageFile "mod\$ModName"
    if (Test-Path -LiteralPath $ModDir) { Remove-Item -LiteralPath $ModDir -Recurse -Force }
    Copy-Item -LiteralPath $source -Destination $ModDir -Recurse
    Set-Content -LiteralPath (Join-Path $ModDir 'enabled.txt') -Value '' -Encoding ASCII
    Set-ModsTxtEntry (Join-Path $ModsDir 'mods.txt') $ModName 1

    New-Item -ItemType Directory -Force -Path $BridgeDir | Out-Null
    @{ installed_ue4ss = $installedUe4ss; installed_at = (Get-Date).ToString('o') } | ConvertTo-Json |
        Set-Content -LiteralPath $RecordPath -Encoding ASCII

    Write-Host ''
    Write-Host "Installed the Dead as Disco AP mod into $Win64"
    Write-Host 'Next: open the Archipelago Launcher, start "Dead as Disco Client", connect, then play Arcade.'
} catch {
    if ($_.Exception -is [System.UnauthorizedAccessException] -or "$($_.Exception.Message)" -match 'denied') {
        throw 'Windows blocked writing to the game folder. Right-click PowerShell, choose "Run as administrator", and run this again.'
    }
    throw
}
