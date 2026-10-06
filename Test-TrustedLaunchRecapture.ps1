<#
.SYNOPSIS
    Quick validation: can an existing Trusted Launch gold image be re-captured into a new gallery
    definition that allows NVMe (DiskControllerTypes=SCSI,NVMe) and boot on an NVMe-only size (Dasv7)
    with Trusted Launch enabled, keeping its installed applications?

    FINDING (first run): the platform refuses to capture a TrustedLaunch VM into a
    TrustedLaunchSupported definition ("contains TrustedLaunch security data ... use either
    TrustedLaunch or ConfidentialVM"). So the re-capture goes into a TrustedLaunch definition, which
    is fine for Dasv7 and for session host update, but is NOT accepted as a Custom Image Template
    source (Image Builder only takes TrustedLaunchSupported). Automated builds start from Marketplace.
    Step 4b tries the snapshot route into TrustedLaunchSupported as a non-fatal experiment.

    No Image Builder, no private networking. Public resources, one resource group, one script.
    Expected duration: 35 to 50 minutes, most of it waiting for Sysprep and capture.

.DESCRIPTION
    Steps (each prints a checkpoint line and stops on failure):
      1. Resource group, Compute Gallery, gallery definition (Gen2, TrustedLaunch, SCSI+NVMe)
      2. "Gold image" VM: Marketplace Windows 11 multi-session, Trusted Launch, SCSI size (D4as_v5),
         with a marker file standing in for the customer's installed applications
      3. NVMe readiness + Sysprep, then capture into the gallery definition      <- Checkpoint A
      3b. Experiment: OS disk snapshot -> TrustedLaunchSupported definition      <- non-fatal
      4. Test VM from that version on Standard_D4as_v7 with Trusted Launch       <- Checkpoint B
      5. Inside the test VM: NVMe controller, Secure Boot, vTPM, marker present  <- Checkpoint C

    If A, B and C pass, an existing TrustedLaunch gold image can be re-captured this way and
    deployed on Dasv7 with its apps intact (and used by session host update).

.PARAMETER AdminPassword   Local admin password for the two VMs (12+ chars, complexity).
.PARAMETER SourceImageVersionId
                           OPTIONAL. Resource ID of your current gold image version in the Compute Gallery.
                           When set, the source VM is created from it (applications included) instead of
                           the Marketplace image. This is how to run the real thing, not the lab stand-in.
.PARAMETER SubnetId        OPTIONAL. Resource ID of an existing subnet. When set, both VMs are
                           created in it with no public IP. When omitted, a temporary VNet is created
                           in the resource group (still no public IP; all access is via Run Command).
.PARAMETER KeepSourceVm    Keep the generalized source VM after capture (default: delete it).
.PARAMETER SkipCleanup     Keep the test VM for manual inspection.
.PARAMETER SkipExperiment  Skip the TrustedLaunchSupported snapshot experiment (step 4b) and its extra
                           definition. Use this when running against a real gallery.

.EXAMPLE
    .\Test-TrustedLaunchRecapture.ps1 -AdminPassword (Read-Host -AsSecureString "Admin password")
.EXAMPLE
    .\Test-TrustedLaunchRecapture.ps1 -AdminPassword $pw -SubnetId "/subscriptions/.../subnets/snet-avd"
.EXAMPLE
    # Real gold image: capture your current version into the new NVMe-capable definition and test it on Dasv7
    $src = az sig image-version show -g <rg> --gallery-name <gallery> --gallery-image-definition <def> --gallery-image-version <ver> --query id -o tsv
    .\Test-TrustedLaunchRecapture.ps1 -AdminPassword $pw -SourceImageVersionId $src -ImageVersion 2026.1.0 -SkipExperiment
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [securestring]$AdminPassword,
    [string]$SubscriptionId = "",
    [string]$ResourceGroup  = "rg-avd-img-test-lab",
    [string]$Location       = "westus3",   # Dasv7 (NVMe-only) availability varies by region and subscription; step 0 checks it
    [string]$GalleryName    = "galavdtest",
    [string]$ImageDefinition = "win11-avd-goldimage-tl",      # TrustedLaunch + SCSI,NVMe (re-capture target)
    [string]$ExperimentDefinition = "win11-avd-goldimage-tls", # TrustedLaunchSupported (Image Builder source), snapshot experiment
    [string]$ImageVersion   = "1.0.0",
    [string]$SourceSku      = "win11-25h2-avd",       # Marketplace SKU standing in for the gold image (lab)
    [string]$SourceImageVersionId = "",               # OPTIONAL: resource ID of your CURRENT gold image version; replaces the Marketplace VM
    [string]$SourceVmSize   = "Standard_D4as_v5",     # SCSI size, like the customer's current hosts
    [string]$TestVmSize     = "Standard_D4as_v7",     # NVMe-only size, the customer's target
    [string]$SubnetId       = "",                     # optional: existing subnet resource ID
    [switch]$KeepSourceVm,
    [switch]$SkipCleanup,
    [switch]$SkipExperiment                           # do not create the TrustedLaunchSupported experiment definition (use in a real gallery)
)
$ErrorActionPreference = "Stop"
$pw = [System.Net.NetworkCredential]::new("", $AdminPassword).Password
$srcVm  = "vm-gold-src"
$testVm = "vm-gold-test"
$t0 = Get-Date
function Step($msg) { Write-Host ("`n[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -ForegroundColor Cyan }
function Pass($msg) { Write-Host ("  PASS  {0}" -f $msg) -ForegroundColor Green }
function Fail($msg) { Write-Host ("  FAIL  {0}" -f $msg) -ForegroundColor Red; exit 1 }

if ($SubscriptionId) { az account set --subscription $SubscriptionId }
$sub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
Write-Host "Subscription: $($sub.name) ($($sub.id))  Region: $Location  RG: $ResourceGroup"

# ---------------------------------------------------------------------------------------------
Step "0. Region check: both sizes must be available (no restrictions)"
# Keep the JMESPath simple (quotes/backticks get mangled on Windows); evaluate restrictions here
$skus = az vm list-skus --location $Location --resource-type virtualMachines --all `
    --query "[].{name:name, restrictions:restrictions[].reasonCode}" -o json | ConvertFrom-Json
function Test-SkuAvailable([string]$size) {
    $r = $skus | Where-Object name -eq $size | Select-Object -First 1
    if (-not $r) { return "not offered in $Location" }
    if (@($r.restrictions).Count -gt 0) { return "restricted for this subscription ($($r.restrictions -join ','))" }
    return $null
}
# Test VM size is the whole point of the test: it must be available as requested
$why = Test-SkuAvailable $TestVmSize
if ($why) { Fail "$TestVmSize $why" }
Pass "$TestVmSize available (test VM)"
# Source VM only needs to be an x64 SCSI-capable size (simulates today's gold image); fall back if needed
$candidates = @($SourceVmSize) + @("Standard_D4s_v5","Standard_D4ds_v5","Standard_D4ads_v5","Standard_D4as_v4","Standard_D4s_v4","Standard_D4s_v3","Standard_D2s_v5","Standard_D2s_v3","Standard_B4ms") | Select-Object -Unique
$picked = $null
foreach ($c in $candidates) {
    $why = Test-SkuAvailable $c
    if (-not $why) { $picked = $c; break }
    Write-Host "    $c $why, trying next" -ForegroundColor DarkGray
}
if (-not $picked) { Fail "No SCSI-capable source VM size available in $Location. Pass -SourceVmSize with one that is." }
if ($picked -ne $SourceVmSize) { Write-Host "    Using $picked for the source VM instead of $SourceVmSize" -ForegroundColor Yellow; $SourceVmSize = $picked }
Pass "$SourceVmSize available (source VM)"

# ---------------------------------------------------------------------------------------------
Step "1. Resource group, gallery, image definitions (Gen2, SCSI+NVMe)"
az group create -n $ResourceGroup -l $Location -o none
az sig create -g $ResourceGroup --gallery-name $GalleryName -l $Location -o none
az sig image-definition create -g $ResourceGroup --gallery-name $GalleryName `
    --gallery-image-definition $ImageDefinition `
    --publisher "LabAVD" --offer "Win11-AVD" --sku "goldimage-tl" `
    --os-type Windows --os-state Generalized --hyper-v-generation V2 `
    --features "SecurityType=TrustedLaunch DiskControllerTypes=SCSI,NVMe" -l $Location -o none
$feat = az sig image-definition show -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --query "features" -o json
Pass "re-capture definition $ImageDefinition features: $feat"
if (-not $SkipExperiment) {
    az sig image-definition create -g $ResourceGroup --gallery-name $GalleryName `
        --gallery-image-definition $ExperimentDefinition `
        --publisher "LabAVD" --offer "Win11-AVD" --sku "goldimage-tls" `
        --os-type Windows --os-state Generalized --hyper-v-generation V2 `
        --features "SecurityType=TrustedLaunchSupported DiskControllerTypes=SCSI,NVMe" -l $Location -o none
    Pass "experiment definition $ExperimentDefinition (TrustedLaunchSupported) ready"
}

# ---------------------------------------------------------------------------------------------
Step "2. Network"
if ($SubnetId) {
    Pass "using existing subnet: $SubnetId"
    $netArgs = @("--subnet", $SubnetId)
} else {
    az network vnet create -g $ResourceGroup -n vnet-imgtest --address-prefix 10.200.0.0/24 `
        --subnet-name snet-vms --subnet-prefix 10.200.0.0/26 -l $Location -o none
    $SubnetId = az network vnet subnet show -g $ResourceGroup --vnet-name vnet-imgtest -n snet-vms --query id -o tsv
    Pass "temporary VNet created (delete the resource group to remove it)"
    $netArgs = @("--subnet", $SubnetId)
}

# ---------------------------------------------------------------------------------------------
if ($SourceImageVersionId) {
    Step "3. Source VM from YOUR current gold image version (applications included), TRUSTED LAUNCH, SCSI size"
    $srcImage = $SourceImageVersionId
} else {
    Step "3. Source VM: Marketplace Windows 11, TRUSTED LAUNCH, SCSI size (stands in for the gold image)"
    $srcImage = "MicrosoftWindowsDesktop:windows-11:${SourceSku}:latest"
}
az vm create -g $ResourceGroup -n $srcVm -l $Location `
    --image $srcImage --size $SourceVmSize `
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true `
    --admin-username labadmin --admin-password $pw `
    --public-ip-address '""' --nsg-rule NONE @netArgs -o none
$sec = az vm show -g $ResourceGroup -n $srcVm --query "securityProfile" -o json
Pass "source VM created with securityProfile: $sec"

Step "3a. Marker file (stands in for installed apps), NVMe driver at boot, Sysprep"
# Multi-line scripts passed inline to az get mangled on Windows; write to a file and use @file
$prep = Join-Path ([IO.Path]::GetTempPath()) "avd-prep-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
@'
New-Item -ItemType Directory -Path C:\SampleApps -Force | Out-Null
Set-Content C:\SampleApps\marker.txt "Gold image marker $(Get-Date -Format o)"
sc.exe config stornvme start=boot | Out-Null
Get-AppxPackage -AllUsers | Where-Object Name -match 'OneDriveSync|LanguageExperiencePack' | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\sysprep.exe" -ArgumentList '/generalize /oobe /shutdown /mode:vm'
"sysprep started; marker=$(Test-Path C:\SampleApps\marker.txt)"
'@ | Set-Content $prep -Encoding ascii
$out = az vm run-command invoke -g $ResourceGroup -n $srcVm --command-id RunPowerShellScript --scripts "@$prep" --query "value[0].message" -o tsv
Remove-Item $prep -ErrorAction SilentlyContinue
Write-Host "    $out"
if ($out -notmatch 'sysprep started') { Fail "prep script did not run as expected (see output above)" }
Write-Host "  waiting for Sysprep to shut the VM down (usually 5-10 min)..."
$deadline = (Get-Date).AddMinutes(25)
do { Start-Sleep 30; $ps = az vm get-instance-view -g $ResourceGroup -n $srcVm --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv; Write-Host "    $(Get-Date -Format HH:mm:ss) $ps" }
while ($ps -ne 'PowerState/stopped' -and (Get-Date) -lt $deadline)
if ($ps -ne 'PowerState/stopped') {
    Write-Host "  Sysprep did not finish in 25 min. Last lines of setuperr.log:" -ForegroundColor Yellow
    az vm run-command invoke -g $ResourceGroup -n $srcVm --command-id RunPowerShellScript `
        --scripts "Get-Content C:\Windows\System32\Sysprep\Panther\setuperr.log -ErrorAction SilentlyContinue | Select-Object -Last 20" --query "value[0].message" -o tsv
    Fail "Sysprep did not complete (VM $srcVm left running for inspection)"
}
az vm deallocate -g $ResourceGroup -n $srcVm -o none
az vm generalize -g $ResourceGroup -n $srcVm -o none
Pass "source VM generalized"

# ---------------------------------------------------------------------------------------------
Step "4. CHECKPOINT A: capture the Trusted Launch VM into the TrustedLaunch + SCSI,NVMe definition"
$vmId = az vm show -g $ResourceGroup -n $srcVm --query id -o tsv
# remove a leftover version from a previous failed run (same name)
$ErrorActionPreference = "Continue"
az sig image-version delete -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --gallery-image-version $ImageVersion -o none 2>$null
$ErrorActionPreference = "Stop"
az sig image-version create -g $ResourceGroup --gallery-name $GalleryName `
    --gallery-image-definition $ImageDefinition --gallery-image-version $ImageVersion `
    --virtual-machine $vmId --target-regions $Location -o none
if ($LASTEXITCODE -ne 0) { Fail "capture into $ImageDefinition failed (source VM $srcVm kept for inspection)" }
$verId = az sig image-version show -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --gallery-image-version $ImageVersion --query "id" -o tsv
$state = az sig image-version show -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --gallery-image-version $ImageVersion --query "provisioningState" -o tsv
if (-not $verId -or $state -ne 'Succeeded') { Fail "capture did not produce a usable version (state=$state)" }
Pass "CHECKPOINT A: version $ImageVersion captured from a Trusted Launch VM into $ImageDefinition (TrustedLaunch, SCSI+NVMe)"

if (-not $SkipExperiment) {
Step "4b. EXPERIMENT (non-fatal): OS disk snapshot -> TrustedLaunchSupported definition (Image Builder source?)"
$ErrorActionPreference = "Continue"   # this block is allowed to fail
$osDisk = az vm show -g $ResourceGroup -n $srcVm --query "storageProfile.osDisk.managedDisk.id" -o tsv
az snapshot create -g $ResourceGroup -n "snap-gold-src" --source $osDisk -l $Location -o none
$snapId = az snapshot show -g $ResourceGroup -n "snap-gold-src" --query id -o tsv
az sig image-version delete -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ExperimentDefinition --gallery-image-version $ImageVersion -o none 2>$null
az sig image-version create -g $ResourceGroup --gallery-name $GalleryName `
    --gallery-image-definition $ExperimentDefinition --gallery-image-version $ImageVersion `
    --os-snapshot $snapId --target-regions $Location -o none 2>&1 | Tee-Object -Variable expOut | Out-Null
$expState = az sig image-version show -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ExperimentDefinition --gallery-image-version $ImageVersion --query "provisioningState" -o tsv 2>$null
if ($expState -eq 'Succeeded') {
    Pass "EXPERIMENT: snapshot of the TrustedLaunch OS disk WAS accepted into a TrustedLaunchSupported definition ($ExperimentDefinition/$ImageVersion). Worth testing as Custom Image Template source."
} else {
    Write-Host "  INFO  EXPERIMENT: snapshot route into TrustedLaunchSupported NOT accepted (expected). Automated builds must start from Marketplace." -ForegroundColor Yellow
    if ($expOut) { Write-Host "        $($expOut | Select-Object -First 3)" -ForegroundColor DarkGray }
}
az snapshot delete -g $ResourceGroup -n "snap-gold-src" -o none 2>$null
$ErrorActionPreference = "Stop"
}
if (-not $KeepSourceVm) { az vm delete -g $ResourceGroup -n $srcVm --yes -o none; Write-Host "  source VM deleted" }

# ---------------------------------------------------------------------------------------------
Step "5. CHECKPOINT B: test VM on $TestVmSize (NVMe-only) with Trusted Launch, from the captured version"
az vm create -g $ResourceGroup -n $testVm -l $Location --image $verId --size $TestVmSize `
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true `
    --admin-username labadmin --admin-password $pw `
    --public-ip-address '""' --nsg-rule NONE @netArgs -o none
if ($LASTEXITCODE -ne 0) { Fail "test VM creation on $TestVmSize failed (see error above)" }
$ctrl = az vm show -g $ResourceGroup -n $testVm --query "storageProfile.diskControllerType" -o tsv
if (-not $ctrl) { Fail "test VM $testVm not found after create" }
Pass "CHECKPOINT B: test VM created, diskControllerType=$ctrl"

# ---------------------------------------------------------------------------------------------
Step "6. CHECKPOINT C: inside the test VM"
$chk = Join-Path ([IO.Path]::GetTempPath()) "avd-check-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
@'
$r = [ordered]@{}
$r.OS           = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion + " build " + [Environment]::OSVersion.Version.Build
$r.Controller   = (Get-CimInstance Win32_SCSIController | Select-Object -ExpandProperty Name) -join '; '
$r.NVMe         = [bool](Get-CimInstance Win32_DiskDrive | Where-Object { $_.Model -match 'NVMe' -or $_.PNPDeviceID -match 'NVME' })
$r.SecureBoot   = try { Confirm-SecureBootUEFI } catch { $false }
$r.vTPM         = [bool](Get-Tpm -ErrorAction SilentlyContinue).TpmPresent
$r.Marker       = Test-Path 'C:\SampleApps\marker.txt'
$r.MarkerText   = if ($r.Marker) { Get-Content 'C:\SampleApps\marker.txt' } else { '' }
$r | ConvertTo-Json -Compress
'@ | Set-Content $chk -Encoding ascii
$out = az vm run-command invoke -g $ResourceGroup -n $testVm --command-id RunPowerShellScript --scripts "@$chk" --query "value[0].message" -o tsv
Remove-Item $chk -ErrorAction SilentlyContinue
$res = ($out -split "`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
$res | Format-List | Out-String | Write-Host
$ok = $true
foreach ($check in @('NVMe','SecureBoot','vTPM','Marker')) {
    if ($res.$check) { Pass $check } else { Write-Host "  FAIL  $check" -ForegroundColor Red; $ok = $false }
}
if (-not $ok) { Fail "CHECKPOINT C failed, see values above" }
Pass "CHECKPOINT C: boots on $TestVmSize with NVMe, Secure Boot, vTPM, and the marker from the source image"

# ---------------------------------------------------------------------------------------------
$mins = [math]::Round(((Get-Date) - $t0).TotalMinutes)
Write-Host "`nALL CHECKPOINTS PASSED in $mins min." -ForegroundColor Green
Write-Host "Re-capturing an existing Trusted Launch gold image into a TrustedLaunch + SCSI,NVMe definition works,"
Write-Host "and the result runs on NVMe-only sizes with Trusted Launch. Applications carry over (marker present)."
Write-Host "This version can be used for session hosts / session host update, but NOT as a Custom Image Template source."
Write-Host "Captured version ID:"
Write-Host "  $verId"
if ($SkipCleanup) { Write-Host "`nTest VM kept: $testVm. Delete the resource group when done: az group delete -n $ResourceGroup --yes" }
else { az vm delete -g $ResourceGroup -n $testVm --yes -o none; Write-Host "`nTest VM deleted. Gallery and image version kept in $ResourceGroup." }
