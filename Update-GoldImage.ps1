<#
.SYNOPSIS
    New gold image version in one command: VM from the current version -> install applications by
    script -> optional settings -> snapshot-free Sysprep + capture as a new version -> boot test on
    Dasv7 (NVMe) -> applications verified on the new image. Then roll it out with Session host update.

.DESCRIPTION
    Steps (each prints a checkpoint line and stops on failure):
      1. Resolve the starting version (latest in the definition, or -FromVersion)
      2. Build VM from that version: Trusted Launch, no public IP, not domain joined
      3. Install each application from its manifest (apps/<name>/app.json):
           - Internet mode (default): installer downloaded from the manifest's downloadUrl
           - Storage mode (-StorageAccount): installer read from <container>/<name>/<installer> through a
             short-lived, read-only user delegation SAS. No storage keys, no identity on the VM.
      4. Optional settings (-EnableTimeZoneRedirection)
      5. Sysprep, capture as -NewVersion and boot test on -TestVmSize, using Test-TrustedLaunchRecapture.ps1
      6. Applications verified inside a VM created from the NEW version; test VM deleted

    After it finishes: Host pool > Session host configuration > Update > image version -NewVersion.

.PARAMETER Apps            Folder names under .\apps (each with an app.json). Default: 7zip.
.PARAMETER StorageAccount  OPTIONAL. Storage account that holds the installers. When set, installers are read
                           from https://<account>.blob.core.windows.net/<Container>/<app>/<installer>.
                           The person running the script needs "Storage Blob Data Reader" on the account (to
                           create the SAS); the build VM needs a network path to it (public or private endpoint).
.PARAMETER Container       Blob container with the installers (default: installers).

.EXAMPLE
    $pw = Read-Host -AsSecureString "Admin password for the temporary VMs"
    .\Update-GoldImage.ps1 -AdminPassword $pw -ResourceGroup <image-rg> -Location westeurope -GalleryName <gallery> `
        -ImageDefinition <nvme-definition> -NewVersion 2026.2.0 -Apps 7zip -SubnetId <subnet-id> -EnableTimeZoneRedirection
.EXAMPLE
    # Installers from a storage account container instead of the internet
    .\Update-GoldImage.ps1 -AdminPassword $pw ... -NewVersion 2026.3.0 -Apps 7zip -StorageAccount stinstallers01 -Container installers
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [securestring]$AdminPassword,
    [string]$SubscriptionId  = "",
    [string]$ResourceGroup   = "rg-avd-img-test-lab",
    [string]$Location        = "westus3",
    [string]$GalleryName     = "galavdtest",
    [string]$ImageDefinition = "win11-avd-goldimage-tl",   # TrustedLaunch + SCSI,NVMe
    [string]$FromVersion     = "",                         # default: latest version in the definition
    [Parameter(Mandatory)] [string]$NewVersion,
    [string[]]$Apps          = @("7zip"),
    [string]$StorageAccount  = "",
    [string]$Container       = "installers",
    [string]$VmName          = "vm-gold-build",            # Windows computer name: max 15 chars
    [string]$VmResourceGroup = "",                         # default: -ResourceGroup
    [string]$VmSize          = "Standard_D4as_v5",
    [string]$TestVmSize      = "Standard_D4as_v7",
    [string]$SubnetId        = "",                         # recommended: the session hosts' subnet
    [switch]$EnableTimeZoneRedirection
)
$ErrorActionPreference = "Stop"
$pw = [System.Net.NetworkCredential]::new("", $AdminPassword).Password
if (-not $VmResourceGroup) { $VmResourceGroup = $ResourceGroup }
$t0 = Get-Date
function Step($msg) { Write-Host ("`n[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -ForegroundColor Cyan }
function Pass($msg) { Write-Host ("  PASS  {0}" -f $msg) -ForegroundColor Green }
function Fail($msg) { Write-Host ("  FAIL  {0}" -f $msg) -ForegroundColor Red; exit 1 }
function Invoke-OnVm([string]$rg, [string]$vm, [string]$script) {
    # multi-line scripts passed inline to az get mangled on Windows; write to a file and use @file
    $f = Join-Path ([IO.Path]::GetTempPath()) "avd-rc-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
    $script | Set-Content $f -Encoding ascii
    $out = az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript --scripts "@$f" --query "value[0].message" -o tsv
    Remove-Item $f -ErrorAction SilentlyContinue
    return ($out -join "`n")
}
if ($SubscriptionId) { az account set --subscription $SubscriptionId }
$mode = if ($StorageAccount) { "storage account $StorageAccount/$Container" } else { "internet (manifest downloadUrl)" }
Write-Host "Definition: $GalleryName/$ImageDefinition   New version: $NewVersion   Apps: $($Apps -join ', ')   Installers from: $mode"

# ---------------------------------------------------------------------------------------------
Step "1. Starting version"
if (-not $FromVersion) {
    $names = az sig image-version list -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --query "[].name" -o tsv
    $FromVersion = @($names) | Where-Object { $_ } | Sort-Object { [version]$_ } | Select-Object -Last 1
    if (-not $FromVersion) { Fail "no versions found in $GalleryName/$ImageDefinition" }
}
if ([version]$NewVersion -le [version]$FromVersion) { Fail "-NewVersion $NewVersion must be higher than the starting version $FromVersion" }
$fromId = az sig image-version show -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --gallery-image-version $FromVersion --query id -o tsv
if (-not $fromId) { Fail "version $FromVersion not found" }
Pass "starting from $ImageDefinition/$FromVersion"
$ErrorActionPreference = "Continue"
$leftover = az vm show -g $ResourceGroup -n vm-gold-test --query name -o tsv 2>$null
$ErrorActionPreference = "Stop"
if ($leftover) { Fail "a VM named vm-gold-test already exists in $ResourceGroup (left from a previous run). Delete it first: az vm delete -g $ResourceGroup -n vm-gold-test --yes" }

# app manifests are read locally, before anything is created
$manifests = @{}
foreach ($app in $Apps) {
    $mf = Join-Path $PSScriptRoot "apps/$app/app.json"
    if (-not (Test-Path $mf)) { Fail "manifest not found: $mf" }
    $manifests[$app] = Get-Content $mf -Raw | ConvertFrom-Json
    if (-not $StorageAccount -and -not $manifests[$app].downloadUrl) { Fail "$app has no downloadUrl in app.json; use -StorageAccount" }
}
Pass "manifests: $($Apps -join ', ')"

# ---------------------------------------------------------------------------------------------
Step "2. Build VM $VmName from $FromVersion (Trusted Launch, no public IP, not domain joined)"
if (-not $SubnetId) {
    # lab only: temporary VNet with a NAT gateway so the VM can download installers and updates
    az network vnet create -g $ResourceGroup -n vnet-imgtest --address-prefix 10.200.0.0/24 --subnet-name snet-vms --subnet-prefix 10.200.0.0/26 -l $Location --only-show-errors -o none
    az network public-ip create -g $ResourceGroup -n pip-imgtest-nat --sku Standard --allocation-method Static -l $Location --only-show-errors -o none
    az network nat gateway create -g $ResourceGroup -n nat-imgtest --public-ip-addresses pip-imgtest-nat --idle-timeout 10 -l $Location --only-show-errors -o none
    az network vnet subnet update -g $ResourceGroup --vnet-name vnet-imgtest -n snet-vms --nat-gateway nat-imgtest --only-show-errors -o none
    $SubnetId = az network vnet subnet show -g $ResourceGroup --vnet-name vnet-imgtest -n snet-vms --query id -o tsv
    Write-Host "    temporary VNet with NAT gateway (lab)"
}
$ErrorActionPreference = "Continue"
$existing = az vm show -g $VmResourceGroup -n $VmName --query "provisioningState" -o tsv 2>$null
$ErrorActionPreference = "Stop"
if ($existing) {
    az vm start -g $VmResourceGroup -n $VmName -o none
    Pass "$VmName already exists, reusing it (delete it first to start clean)"
} else {
    az vm create -g $VmResourceGroup -n $VmName -l $Location --image $fromId --size $VmSize `
        --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true `
        --admin-username goldadmin --admin-password $pw --subnet $SubnetId `
        --public-ip-address '""' --nsg-rule NONE --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) { Fail "VM creation failed (see error above)" }
    Pass "$VmName created"
}

# ---------------------------------------------------------------------------------------------
Step "3. Install applications ($mode)"
$sas = ""
if ($StorageAccount) {
    $expiry = (Get-Date).ToUniversalTime().AddHours(3).ToString("yyyy-MM-ddTHH:mmZ")
    $sas = az storage container generate-sas --account-name $StorageAccount -n $Container --permissions r `
        --expiry $expiry --auth-mode login --as-user -o tsv
    if (-not $sas) { Fail "could not create a SAS on $StorageAccount/$Container (needs Storage Blob Data Reader for the signed-in user)" }
    Pass "read-only SAS on $Container, valid until $expiry UTC"
}
foreach ($app in $Apps) {
    $m = $manifests[$app]
    $url = if ($StorageAccount) { "https://$StorageAccount.blob.core.windows.net/$Container/$app/$($m.installer)?$sas" } else { $m.downloadUrl }
    $shown = if ($StorageAccount) { "https://$StorageAccount.blob.core.windows.net/$Container/$app/$($m.installer)" } else { $url }
    Write-Host "    $app <- $shown"
    $install = $m.install -replace "'", "''"
    $validate = "$($m.validate)" -replace "'", "''"
    $script = @"
`$ProgressPreference = 'SilentlyContinue'
`$dir = 'C:\Windows\Temp\apps\$app'; New-Item -ItemType Directory -Path `$dir -Force | Out-Null
`$file = Join-Path `$dir '$($m.installer)'
try { Invoke-WebRequest -Uri '$url' -OutFile `$file -UseBasicParsing } catch { "APP-FAIL download: `$(`$_.Exception.Message)"; return }
`$cmd = '$install' -replace '\{installer\}', `$file
`$p = Start-Process -FilePath cmd.exe -ArgumentList "/c `$cmd" -Wait -PassThru -NoNewWindow
if (`$p.ExitCode -notin 0, 3010) { "APP-FAIL install exit code `$(`$p.ExitCode)"; return }
if ('$validate' -and -not (Test-Path '$validate')) { "APP-FAIL validation: $validate not found"; return }
Remove-Item `$dir -Recurse -Force -ErrorAction SilentlyContinue
"APP-OK exit code `$(`$p.ExitCode)"
"@
    $out = Invoke-OnVm $VmResourceGroup $VmName $script
    if ($out -notmatch 'APP-OK') { Fail "$app : $($out.Trim())" }
    Pass "$app installed and validated ($($m.validate))"
}

# ---------------------------------------------------------------------------------------------
Step "4. Settings"
if ($EnableTimeZoneRedirection) {
    $out = Invoke-OnVm $VmResourceGroup $VmName @'
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name fEnableTimeZoneRedirection -Value 1 -Type DWord
"TZ=" + (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services').fEnableTimeZoneRedirection
'@
    if ($out -notmatch 'TZ=1') { Fail "time zone redirection not set: $out" }
    Pass "time zone redirection enabled"
} else { Write-Host "    none requested" }

# a VM fresh from a generalized image can still be servicing for a few minutes; Sysprep must wait for it
Write-Host "    waiting for Windows servicing to be idle before Sysprep..."
$deadline = (Get-Date).AddMinutes(20)
do {
    $busy = (Invoke-OnVm $VmResourceGroup $VmName "((Get-Process | Where-Object Name -match '^(dism|TiWorker|lpksetup)$').Name | Sort-Object -Unique) -join ','").Trim()
    if ($busy) { Write-Host "    $(Get-Date -Format HH:mm:ss) busy: $busy"; Start-Sleep 60 }
} while ($busy -and (Get-Date) -lt $deadline)
if ($busy) { Fail "$VmName still busy after 20 min ($busy); re-run the same command later (the VM is reused)" }
Pass "$VmName idle"

# ---------------------------------------------------------------------------------------------
Step "5. Sysprep, capture as $NewVersion and boot test on $TestVmSize (Test-TrustedLaunchRecapture.ps1)"
& (Join-Path $PSScriptRoot "Test-TrustedLaunchRecapture.ps1") -AdminPassword $AdminPassword `
    -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -Location $Location `
    -GalleryName $GalleryName -ImageDefinition $ImageDefinition -ImageVersion $NewVersion `
    -SourceVmName $VmName -SourceVmResourceGroup $VmResourceGroup -SkipSnapshot `
    -TestVmSize $TestVmSize -SubnetId $SubnetId -SkipExperiment -SkipCleanup
if ($LASTEXITCODE -ne 0) { Fail "capture / boot test failed (see above)" }

# ---------------------------------------------------------------------------------------------
Step "6. Applications on the NEW image (inside the test VM)"
$checks = ($Apps | ForEach-Object { "'$_=' + (Test-Path '$($manifests[$_].validate)')" }) -join "`n"
$out = Invoke-OnVm $ResourceGroup "vm-gold-test" $checks
$out -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "    $_" }
foreach ($app in $Apps) { if ($out -notmatch "$([regex]::Escape($app))=True") { Fail "$app not found on the new image (test VM vm-gold-test kept for inspection)" } }
az vm delete -g $ResourceGroup -n vm-gold-test --yes -o none
Pass "all applications present on $NewVersion; test VM deleted"

# ---------------------------------------------------------------------------------------------
$verId = az sig image-version show -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --gallery-image-version $NewVersion --query id -o tsv
Write-Host ("`nNEW GOLD IMAGE READY in {0} min: {1}/{2}" -f [math]::Round(((Get-Date) - $t0).TotalMinutes), $ImageDefinition, $NewVersion) -ForegroundColor Green
Write-Host "  $verId"
Write-Host "Build VM $VmName is generalized now and can be deleted:  az vm delete -g $VmResourceGroup -n $VmName --yes"
Write-Host "Roll it out:  Host pool > Session host configuration > Update > image version $NewVersion"
