<#
.SYNOPSIS
    Uploads a folder of installers to the installers container, one folder per application, with simple file
    names, and creates a starting app.json for each application.

.DESCRIPTION
    For every .exe, .msi and .reg file in -SourcePath:
      1. Application folder name from the file name: version and "Setup" removed, lower case, hyphens.
           "SEEPEX SCM (Local) v2.0.0.85 - Setup.exe"  ->  seepex-scm-local
      2. Version from the file name, when present (v2.0.0.85 -> 2.0.0.85).
      3. Upload to <Container>/<app>/setup.exe (setup.msi, <app>.reg), so the URL has no spaces.
         The original files are not changed.
      4. apps\<app>\app.json created when it does not exist yet (an existing one is never overwritten):
           .msi -> msiexec /i ... /qn /norestart (complete)
           .exe -> "<SWITCH>" to replace with the vendor's silent switch
           .reg -> reg.exe import (complete)
         "validate" is a placeholder: the main program file (or the registry key for .reg files).
    Then fill in the placeholders and run Update-GoldImage.ps1 with -Apps <folders> -StorageAccount -Container.

    Needs "Storage Blob Data Contributor" on the storage account and a network path to it (private endpoint).

.EXAMPLE
    .\Publish-AppInstallers.ps1 -SourcePath C:\Downloads\installers -StorageAccount stinstallers01 -Container installers
.EXAMPLE
    # Preview names and versions without uploading or creating files
    .\Publish-AppInstallers.ps1 -SourcePath C:\Downloads\installers -StorageAccount stinstallers01 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$SourcePath,
    [Parameter(Mandatory)] [string]$StorageAccount,
    [string]$Container = "installers"
)
$ErrorActionPreference = "Stop"
$env:AZURE_CORE_DISPLAY_REGION_IDENTIFIED = "false"
function Pass($msg) { Write-Host ("  PASS  {0}" -f $msg) -ForegroundColor Green }
function Fail($msg) { Write-Host ("  FAIL  {0}" -f $msg) -ForegroundColor Red; exit 1 }

if (-not (Test-Path $SourcePath)) { Fail "folder not found: $SourcePath" }
$files = Get-ChildItem -Path $SourcePath -File | Where-Object { $_.Extension -in '.exe', '.msi', '.reg' }
if (-not $files) { Fail "no .exe, .msi or .reg files in $SourcePath" }

$rows = foreach ($f in $files) {
    $base = $f.BaseName
    $version = if ($base -match '(?i)\bv?(\d+(?:\.\d+){1,3})\b') { $Matches[1] } else { '' }
    $name = $base -replace '(?i)\bv?\d+(\.\d+){1,3}\b', ' ' -replace '(?i)\b(setup|installer|install)\b', ' '
    $app = ($name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $app) { Fail "could not derive a folder name from '$($f.Name)'" }
    $ext = $f.Extension.ToLower()
    $installer = if ($ext -eq '.reg') { "$app.reg" } else { "setup$ext" }
    [pscustomobject]@{ App = $app; Version = $version; Installer = $installer; Source = $f.FullName; File = $f.Name; Ext = $ext
                       Display = ($name -replace '\s*[-(]+\s*$', '' -replace '\s+', ' ').Trim() }
}
$dupes = $rows | Group-Object App | Where-Object Count -gt 1
if ($dupes) { Fail "two files map to the same folder: $(($dupes.Group.File) -join ', '). Rename one of them first." }

Write-Host "`nSource: $SourcePath   Target: $StorageAccount/$Container`n"
foreach ($r in $rows) { Write-Host ("    {0,-38} {1,-10} {2,-16} <- {3}" -f $r.App, $r.Version, $r.Installer, $r.File) }
Write-Host ""

foreach ($r in $rows) {
    $blob = "$($r.App)/$($r.Installer)"
    if ($PSCmdlet.ShouldProcess("$StorageAccount/$Container/$blob", "upload $($r.File)")) {
        az storage blob upload --account-name $StorageAccount -c $Container --auth-mode login -n $blob -f $r.Source --overwrite -o none --only-show-errors
        if ($LASTEXITCODE -ne 0) { Fail "upload of $($r.File) failed (needs Storage Blob Data Contributor and a network path to $StorageAccount)" }
        Pass "uploaded $blob"
    }

    $dir = Join-Path $PSScriptRoot "apps/$($r.App)"
    $mf = Join-Path $dir "app.json"
    if (Test-Path $mf) { Write-Host "    $($r.App)\app.json already exists, left as is"; continue }
    $manifest = [ordered]@{ name = $r.Display; installer = $r.Installer }
    switch ($r.Ext) {
        '.msi' { $manifest.install = 'msiexec.exe /i "{installer}" /qn /norestart'; $manifest.validate = 'C:\Program Files\<FOLDER>\<PROGRAM>.exe' }
        '.exe' { $manifest.install = '"{installer}" <SWITCH>';                       $manifest.validate = 'C:\Program Files\<FOLDER>\<PROGRAM>.exe' }
        '.reg' { $manifest.install = 'reg.exe import "{installer}"';                 $manifest.validate = 'HKLM:\SOFTWARE\<KEY>' }
    }
    if ($r.Version -and $r.Ext -ne '.reg') { $manifest.version = $r.Version }
    if ($PSCmdlet.ShouldProcess($mf, "create app.json")) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # JSON written by hand: Windows PowerShell 5.1 ConvertTo-Json turns < > into \u003c \u003e
        $lines = foreach ($k in $manifest.Keys) { '  "{0}": "{1}"' -f $k, ($manifest[$k] -replace '\\', '\\' -replace '"', '\"') }
        "{`n" + ($lines -join ",`n") + "`n}" | Set-Content $mf -Encoding ascii
        Pass "created apps\$($r.App)\app.json"
    }
}

$todo = $rows | Where-Object { Test-Path (Join-Path $PSScriptRoot "apps/$($_.App)/app.json") } |
    Where-Object { (Get-Content (Join-Path $PSScriptRoot "apps/$($_.App)/app.json") -Raw) -match '<SWITCH>|<FOLDER>|<PROGRAM>|<KEY>' }
Write-Host "`nNext:"
if ($todo) { Write-Host "  1. Replace the <...> placeholders in:"; $todo | ForEach-Object { Write-Host "       notepad .\apps\$($_.App)\app.json" } }
else { Write-Host "  1. Review each app.json" }
Write-Host "  2. .\Update-GoldImage.ps1 ... -Apps $(($rows.App) -join ',') -StorageAccount $StorageAccount -Container $Container"
