<#
.SYNOPSIS
    Runs inside the Image Builder build VM. Installs Windows 11 display languages OFFLINE from the
    Microsoft "Languages and Optional Features" ISO, the method documented for AVD images.

    Why not Install-Language: on an already-patched image it resolves every component through
    Windows Update, takes hours, and the cmdlet gives up with "The operation has timed out" after
    about 60 minutes (that is exactly how the first template build failed). The ISO method installs
    the language pack .cab and the Features on Demand from a local source with -LimitAccess, so it is
    deterministic: roughly 10 to 15 minutes per language. Windows Update then runs ONCE, at the end
    of the build, and brings the language components to the image's patch level.

.PARAMETER Languages
    Comma-separated language tags, e.g. "de-DE,fr-FR,zh-CN". Injected by the template.
.PARAMETER IsoUrl
    Languages and Optional Features ISO. Default: the 24H2/25H2 (26100) ISO from Microsoft Learn.
.NOTES
    Expected and harmless: a few optional capabilities are not present on the ISO for every language
    (Handwriting, OCR, Speech...). They are logged as "not available" and skipped. The three
    language packs this script was written for (de-DE, fr-FR, zh-CN) all have Basic + TextToSpeech
    + Speech + OCR + Handwriting; zh-CN additionally gets the Hans fonts.
    Reference: https://learn.microsoft.com/azure/virtual-desktop/windows-11-language-packs
#>
param(
    [string]$Languages = "de-DE",
    [string]$IsoUrl = "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1.240331-1435.ge_release_amd64fre_CLIENT_LOF_PACKAGES_OEM.iso"
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is 10x slower with the progress bar on
$log = "C:\Windows\Temp\imagebuild-languages.log"
Start-Transcript -Path $log -Append | Out-Null
function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" }

# ----- 1. Keep the language packs: Windows removes unused ones through these tasks -------------
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -TaskName 'Pre-staged app cleanup' -ErrorAction SilentlyContinue | Out-Null
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\MUI\' -TaskName 'LPRemove' -ErrorAction SilentlyContinue | Out-Null
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\LanguageComponentsInstaller' -TaskName 'Uninstallation' -ErrorAction SilentlyContinue | Out-Null
reg add 'HKLM\SOFTWARE\Policies\Microsoft\Control Panel\International' /v BlockCleanupOfUnusedPreinstalledLangPacks /t REG_DWORD /d 1 /f | Out-Null
Log "Language cleanup tasks disabled"

# ----- 2. Download and mount the ISO -----------------------------------------------------------
$iso = "C:\Windows\Temp\LanguagesAndOptionalFeatures.iso"
if (-not (Test-Path $iso)) {
    Log "Downloading ISO (a few GB, usually 3 to 6 minutes in Azure) ..."
    Invoke-WebRequest -Uri $IsoUrl -OutFile $iso -UseBasicParsing
    Log ("Downloaded {0:N0} MB" -f ((Get-Item $iso).Length / 1MB))
}
$img = Mount-DiskImage -ImagePath $iso -PassThru
$drive = ($img | Get-Volume).DriveLetter + ":"
$src = "$drive\LanguagesAndOptionalFeatures"
if (-not (Test-Path $src)) { throw "Folder LanguagesAndOptionalFeatures not found on the ISO ($drive)" }
Log "ISO mounted at $drive"

# ----- 3. Per language: language pack .cab, then Features on Demand from the same source --------
$fods = @('Basic', 'Handwriting', 'OCR', 'Speech', 'TextToSpeech')
$fonts = @{ 'zh-CN' = 'Hans'; 'zh-TW' = 'Hant'; 'ja-JP' = 'Jpan'; 'ko-KR' = 'Kore'; 'th-TH' = 'Thai'; 'ar-SA' = 'Arab'; 'he-IL' = 'Hebr' }
foreach ($lang in ($Languages -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    Log "=== $lang ==="
    $cab = Get-ChildItem $src -Filter "Microsoft-Windows-Client-Language-Pack_x64_$($lang.ToLower()).cab" | Select-Object -First 1
    if (-not $cab) { throw "Language pack for $lang not found on the ISO" }
    Log "Add-WindowsPackage $($cab.Name)"
    Add-WindowsPackage -Online -PackagePath $cab.FullName -NoRestart | Out-Null

    foreach ($f in $fods) {
        $cap = "Language.$f~~~$lang~0.0.1.0"
        try {
            Add-WindowsCapability -Online -Name $cap -Source $src -LimitAccess | Out-Null
            Log "  $cap installed"
        } catch {
            Log "  $cap not available on the ISO for $lang (skipped)"
        }
    }
    if ($fonts.ContainsKey($lang)) {
        $cap = "Language.Fonts.$($fonts[$lang])~~~und-$($fonts[$lang].ToUpper())~0.0.1.0"
        try { Add-WindowsCapability -Online -Name $cap -Source $src -LimitAccess | Out-Null; Log "  $cap installed" }
        catch { Log "  $cap not available (skipped)" }
    }
    Log "=== $lang done ==="
}

# ----- 4. Cleanup; a restart follows in the template (WindowsRestart customizer) ----------------
Dismount-DiskImage -ImagePath $iso | Out-Null
Remove-Item $iso -Force -ErrorAction SilentlyContinue
Log "Installed language packs now on the image:"
Get-WindowsPackage -Online | Where-Object PackageName -like 'Microsoft-Windows-Client-LanguagePack-Package*' |
    Select-Object -ExpandProperty PackageName | ForEach-Object { Log "  $_" }
Stop-Transcript | Out-Null
