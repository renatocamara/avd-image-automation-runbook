<#
.SYNOPSIS
    Runs inside the Image Builder build VM as the last customizer.
    Removes per-user Store packages that block Sysprep (OneDrive shell integration,
    Language Experience Packs downloaded by Windows Update) and sets the NVMe driver
    to load at boot so the image starts on NVMe-only VM sizes (Dasv6/Dasv7).
#>
$ErrorActionPreference = 'Continue'

# NVMe readiness (no-op on images that already have it)
sc.exe config stornvme start=boot | Out-Null
Write-Host "stornvme set to boot start"

# Store packages that make Sysprep fail. OneDrive itself (per-machine) stays installed
# and re-registers this package for each user at first sign-in.
Get-AppxPackage -AllUsers | Where-Object Name -match 'OneDriveSync|LanguageExperiencePack' | ForEach-Object {
    Write-Host "Removing $($_.PackageFullName)"
    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
}

# Clean temp files from the build
Remove-Item 'C:\Windows\Temp\apps' -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Cleanup done"
