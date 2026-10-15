<#
.SYNOPSIS
    Builds an App Attach package (signed MSIX converted to CimFS) for one application of the apps folder and copies it
    to the App Attach file share. Everything runs on a clean Windows 11 packaging VM through Run Command (no RDP).

.DESCRIPTION
    Reads apps\<App>\app.json (the same manifest Update-GoldImage.ps1 uses), then on the packaging VM, as SYSTEM:
      1. Downloads makeappx/signtool (NuGet Microsoft.Windows.SDK.BuildTools) and msixmgr, once.
      2. Creates a self-signed signing certificate whose subject is -Publisher, once (C:\msix\signing.pfx).
         For production, replace it with a code signing certificate from your PKI (same subject as -Publisher).
      3. Downloads the installer from the storage account (read-only SAS), installs it silently with the manifest
         command, and copies the installation folder (the folder of "validate") into the package layout.
      4. Writes AppxManifest.xml, packs and signs the MSIX.
      5. Converts it to CimFS (.cim and its data files) with msixmgr and copies them to the share.
    The public certificate (.cer) is saved locally: the session hosts must trust it (Local Machine > Trusted People),
    in the gold image for production.

    Needs: Storage Blob Data Reader on the installers storage account, and the key of the share's storage account
    (read with az, used only by the packaging VM to copy the files). The packaging VM needs outbound internet access
    to nuget.org and aka.ms for the tools.

.EXAMPLE
    .\New-AppAttachPackage.ps1 -ResourceGroup rg-images -VmName vm-msix-pkg -App contoso-app `
        -StorageAccount stinstallers01 -Container installers -PackageName Contoso.App -Publisher "CN=Contoso Packaging" `
        -Version 1.0.0.0 -ShareResourceGroup rg-profiles -ShareStorageAccount stprofiles01 -ShareName appattach
#>
param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$VmName,
    [Parameter(Mandatory)] [string]$App,
    [Parameter(Mandatory)] [string]$StorageAccount,
    [string]$Container = "installers",
    [Parameter(Mandatory)] [string]$PackageName,          # letters, digits, dots; e.g. Contoso.App
    [Parameter(Mandatory)] [string]$Publisher,            # e.g. "CN=Contoso Packaging" (= certificate subject)
    [Parameter(Mandatory)] [string]$Version,              # four parts, e.g. 1.0.0.0
    [string]$DisplayName = "",
    [string]$InstallDir = "",                             # default: the folder of "validate" in app.json
    [Parameter(Mandatory)] [string]$ShareResourceGroup,
    [Parameter(Mandatory)] [string]$ShareStorageAccount,
    [Parameter(Mandatory)] [string]$ShareName,
    [string]$SubscriptionId = ""
)
$ErrorActionPreference = "Stop"
$env:AZURE_CORE_DISPLAY_REGION_IDENTIFIED = "false"
function Step($msg) { Write-Host ("`n[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -ForegroundColor Cyan }
function Pass($msg) { Write-Host ("  PASS  {0}" -f $msg) -ForegroundColor Green }
function Fail($msg) { Write-Host ("  FAIL  {0}" -f $msg) -ForegroundColor Red; exit 1 }

if ($SubscriptionId) { az account set --subscription $SubscriptionId }
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') { Fail "-Version must have four parts, e.g. 1.0.0.0" }
if ($Publisher -notmatch '^CN=') { Fail "-Publisher must start with CN=, e.g. ""CN=Contoso Packaging""" }

Step "1. Manifest apps\$App\app.json"
$mf = Join-Path $PSScriptRoot "apps\$App\app.json"
if (-not (Test-Path $mf)) { Fail "not found: $mf" }
$m = Get-Content $mf -Raw | ConvertFrom-Json
if (-not $m.installer -or -not $m.install) { Fail "app.json needs installer and install" }
if (-not $InstallDir) {
    if (-not $m.validate -or $m.validate -like 'HKLM:*') { Fail "app.json has no program path in validate; pass -InstallDir" }
    $InstallDir = Split-Path $m.validate -Parent
}
$exe = if ($m.validate -and $m.validate -notlike 'HKLM:*') { Split-Path $m.validate -Leaf } else { "" }
if (-not $exe) { Fail "no executable known; validate in app.json must be the program file" }
if (-not $DisplayName) { $DisplayName = if ($m.name) { "$($m.name)" } else { $PackageName } }
Pass "installer $($m.installer), folder $InstallDir, program $exe"

Step "2. Access"
$expiry = (Get-Date).ToUniversalTime().AddHours(2).ToString("yyyy-MM-ddTHH:mmZ")
$sas = az storage container generate-sas --account-name $StorageAccount -n $Container --permissions r --expiry $expiry --auth-mode login --as-user -o tsv
if (-not $sas) { Fail "could not create a SAS on $StorageAccount/$Container (needs Storage Blob Data Reader)" }
$key = az storage account keys list -g $ShareResourceGroup -n $ShareStorageAccount --query "[0].value" -o tsv
if (-not $key) { Fail "could not read the key of $ShareStorageAccount" }
Pass "read-only SAS on $Container (until $expiry UTC) and share key"

$remote = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$url = '__URL__'; $installer = '__INSTALLER__'; $install = '__INSTALL__'; $srcDir = '__INSTALLDIR__'; $exe = '__EXE__'
$name = '__NAME__'; $pub = '__PUB__'; $ver = '__VER__'; $display = '__DISPLAY__'
$share = '__SHARE__'; $sa = '__SA__'; $key = '__KEY__'
$root = 'C:\msix'; $work = "$root\build-$name-$ver"
function Run($exe, $argList) { $o = & $exe @argList 2>&1; if ($LASTEXITCODE -ne 0) { $o | Select-Object -Last 8; throw "$(Split-Path $exe -Leaf) exit $LASTEXITCODE" } }
try {
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$work\layout\Assets", "$work\cim", "$work\src" | Out-Null

if (-not (Test-Path "$root\sdk\makeappx.exe")) {
    Invoke-WebRequest https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools -OutFile "$root\sdk-buildtools.zip" -UseBasicParsing
    Expand-Archive "$root\sdk-buildtools.zip" "$root\sdk-buildtools" -Force
    $x64 = (Get-ChildItem "$root\sdk-buildtools" -Recurse -Filter makeappx.exe | Where-Object FullName -match '\\x64\\' | Select-Object -First 1).DirectoryName
    New-Item -ItemType Directory -Force "$root\sdk" | Out-Null
    Copy-Item "$x64\*" "$root\sdk" -Recurse -Force
}
if (-not (Test-Path "$root\msixmgr\x64\msixmgr.exe")) {
    Invoke-WebRequest https://aka.ms/msixmgr -OutFile "$root\msixmgr.zip" -UseBasicParsing
    Expand-Archive "$root\msixmgr.zip" "$root\msixmgr" -Force
}
'STEP tools ready'

if (-not (Test-Path "$root\signing.pfx")) {
    $pfxPw = [guid]::NewGuid().ToString('N')
    $cert = New-SelfSignedCertificate -Type Custom -Subject $pub -KeyUsage DigitalSignature -FriendlyName "App Attach signing" `
        -CertStoreLocation Cert:\LocalMachine\My -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') -NotAfter (Get-Date).AddYears(2)
    Export-PfxCertificate -Cert $cert -FilePath "$root\signing.pfx" -Password (ConvertTo-SecureString $pfxPw -AsPlainText -Force) | Out-Null
    Export-Certificate -Cert $cert -FilePath "$root\signing.cer" | Out-Null
    Set-Content "$root\signing.pwd" $pfxPw
}
$pfxPw = (Get-Content "$root\signing.pwd" -Raw).Trim()
'STEP certificate ready'

$file = "$work\src\$installer"
Invoke-WebRequest $url -OutFile $file -UseBasicParsing
$cmd = $install -replace '\{installer\}', $file
$p = Start-Process -FilePath cmd.exe -ArgumentList "/s /c `"$cmd`"" -Wait -PassThru -NoNewWindow
if ($p.ExitCode -notin 0, 3010) { throw "install exit code $($p.ExitCode)" }
if (-not (Test-Path (Join-Path $srcDir $exe))) { throw "after install, not found: $srcDir\$exe" }
Copy-Item $srcDir "$work\layout\App" -Recurse -Force
Get-ChildItem "$work\layout\App" -Filter 'unins*' | Remove-Item -Force
$fv = (Get-Item (Join-Path $srcDir $exe)).VersionInfo.ProductVersion
"STEP installed and copied: $srcDir (program version $fv)"

Add-Type -AssemblyName System.Drawing
foreach ($a in @(@('StoreLogo', 50), @('Square150x150Logo', 150), @('Square44x44Logo', 44))) {
    $b = New-Object System.Drawing.Bitmap $a[1], $a[1]
    $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::SteelBlue); $g.Dispose()
    $b.Save("$work\layout\Assets\$($a[0]).png", [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
}
$esc = { param($s) [Security.SecurityElement]::Escape($s) }
$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities" IgnorableNamespaces="uap rescap">
  <Identity Name="$name" Publisher="$(& $esc $pub)" Version="$ver" ProcessorArchitecture="x86" />
  <Properties>
    <DisplayName>$(& $esc $display)</DisplayName>
    <PublisherDisplayName>$(& $esc ($pub -replace '^CN=',''))</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies><TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" /></Dependencies>
  <Resources><Resource Language="en-us" /></Resources>
  <Applications>
    <Application Id="App" Executable="App\$exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="$(& $esc $display)" Description="$(& $esc $display)" BackgroundColor="transparent" Square150x150Logo="Assets\Square150x150Logo.png" Square44x44Logo="Assets\Square44x44Logo.png" />
    </Application>
  </Applications>
  <Capabilities><rescap:Capability Name="runFullTrust" /></Capabilities>
</Package>
"@
[IO.File]::WriteAllText("$work\layout\AppxManifest.xml", $manifest)
$msix = "$work\$name`_$ver.msix"
Run "$root\sdk\makeappx.exe" @('pack', '/d', "$work\layout", '/p', $msix, '/o')
Run "$root\sdk\signtool.exe" @('sign', '/fd', 'SHA256', '/f', "$root\signing.pfx", '/p', $pfxPw, $msix)
'STEP packed and signed'

$cimName = "$($name.ToLower())-$ver.cim"
Run "$root\msixmgr\x64\msixmgr.exe" @('-Unpack', '-packagePath', $msix, '-destination', "$work\cim\$cimName", '-applyACLs', '-create', '-fileType', 'cim', '-rootDirectory', 'apps')
'STEP converted to CimFS'

net use $share /user:localhost\$sa $key | Out-Null
Copy-Item "$work\cim\*" $share -Force
$size = (Get-ChildItem "$work\cim" | Measure-Object Length -Sum).Sum / 1MB
net use $share /delete /y | Out-Null
"STEP copied to share: $share\$cimName ({0:N1} MB in {1} files)" -f $size, (Get-ChildItem "$work\cim").Count
'CER:' + [Convert]::ToBase64String([IO.File]::ReadAllBytes("$root\signing.cer"))
'PKG-OK'
} catch { "PKG-FAIL $($_.Exception.Message)" }
'@

$share = "\\$ShareStorageAccount.file.core.windows.net\$ShareName"
$url = "https://$StorageAccount.blob.core.windows.net/$Container/$App/$($m.installer)?$sas"
$values = [ordered]@{
    '__URL__' = $url; '__INSTALLER__' = "$($m.installer)"; '__INSTALL__' = "$($m.install)"; '__INSTALLDIR__' = $InstallDir
    '__EXE__' = $exe; '__NAME__' = $PackageName; '__PUB__' = $Publisher; '__VER__' = $Version; '__DISPLAY__' = $DisplayName
    '__SHARE__' = $share; '__SA__' = $ShareStorageAccount; '__KEY__' = $key
}
foreach ($k in $values.Keys) { $remote = $remote.Replace($k, ($values[$k] -replace "'", "''")) }

Step "3. Package on $VmName (installer, MSIX, signature, CimFS, copy to share: 5 to 15 minutes)"
$f = Join-Path ([IO.Path]::GetTempPath()) "avd-pkg-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
$remote | Set-Content $f -Encoding ascii
try {
    $out = (az vm run-command invoke -g $ResourceGroup -n $VmName --command-id RunPowerShellScript --scripts "@$f" --query "value[*].message" -o tsv) -join "`n"
} finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
$out -split "`n" | Where-Object { $_ -match '^STEP ' } | ForEach-Object { Pass ($_ -replace '^STEP ', '') }
if ($out -notmatch 'PKG-OK') { Fail (($out -split "`n" | Where-Object { $_ -and $_ -notmatch '^(STEP|CER:)' }) -join ' | ') }

$cerB64 = ([regex]::Match($out, 'CER:([A-Za-z0-9+/=]+)')).Groups[1].Value
$cerFile = Join-Path $PSScriptRoot "appattach-signing.cer"
[IO.File]::WriteAllBytes($cerFile, [Convert]::FromBase64String($cerB64))
$subject = ([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cerFile)).Subject
Pass "public certificate saved: $cerFile ($subject)"

Write-Host "`nPACKAGE READY: $share\$($PackageName.ToLower())-$Version.cim" -ForegroundColor Green
Write-Host "Next:"
Write-Host "  1. Session hosts trust $cerFile (Local Machine > Trusted People); in the gold image for production"
Write-Host "  2. Azure Virtual Desktop > App attach > Create: host pool, image path above, assignment to a test group"
