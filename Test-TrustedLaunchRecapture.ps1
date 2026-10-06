<#
.SYNOPSIS
    Quick validation: can a Trusted Launch gold image be re-captured into a TrustedLaunchSupported
    gallery definition and boot on an NVMe-only size (Dasv7) with Trusted Launch enabled?

    No Image Builder, no private networking. Public resources, one resource group, one script.
    Expected duration: 35 to 50 minutes, most of it waiting for Sysprep and capture.

.DESCRIPTION
    Steps (each prints a checkpoint line and stops on failure):
      1. Resource group, Compute Gallery, gallery definition (Gen2, TrustedLaunchSupported, SCSI+NVMe)
      2. "Gold image" VM: Marketplace Windows 11 multi-session, Trusted Launch, SCSI size (D4as_v5),
         with a marker file standing in for the customer's installed applications
      3. NVMe readiness + Sysprep, then capture into the gallery definition      <- Checkpoint A
      4. Test VM from that version on Standard_D4as_v7 with Trusted Launch       <- Checkpoint B
      5. Inside the test VM: NVMe controller, Secure Boot, vTPM, marker present  <- Checkpoint C

    If A, B and C pass, an existing TrustedLaunch gold image can be re-captured this way and
    (a) used as a Custom Image Template source and (b) deployed on Dasv7, with its apps intact.

.PARAMETER AdminPassword   Local admin password for the two VMs (12+ chars, complexity).
.PARAMETER SubnetId        OPTIONAL. Resource ID of an existing subnet. When set, both VMs are
                           created in it with no public IP. When omitted, a temporary VNet is created
                           in the resource group (still no public IP; all access is via Run Command).
.PARAMETER KeepSourceVm    Keep the generalized source VM after capture (default: delete it).
.PARAMETER SkipCleanup     Keep the test VM for manual inspection.

.EXAMPLE
    .\Test-TrustedLaunchRecapture.ps1 -AdminPassword (Read-Host -AsSecureString "Admin password")
.EXAMPLE
    .\Test-TrustedLaunchRecapture.ps1 -AdminPassword $pw -SubnetId "/subscriptions/.../subnets/snet-avd"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [securestring]$AdminPassword,
    [string]$SubscriptionId = "",
    [string]$ResourceGroup  = "rg-avd-img-test-lab",
    [string]$Location       = "westus3",   # Dasv7 (NVMe-only) availability varies by region and subscription; step 0 checks it
    [string]$GalleryName    = "galavdtest",
    [string]$ImageDefinition = "win11-avd-goldimage-tls",
    [string]$ImageVersion   = "1.0.0",
    [string]$SourceSku      = "win11-25h2-avd",       # Marketplace SKU standing in for the gold image
    [string]$SourceVmSize   = "Standard_D4as_v5",     # SCSI size, like the customer's current hosts
    [string]$TestVmSize     = "Standard_D4as_v7",     # NVMe-only size, the customer's target
    [string]$SubnetId       = "",                     # optional: existing subnet resource ID
    [switch]$KeepSourceVm,
    [switch]$SkipCleanup
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
foreach ($s in @($SourceVmSize, $TestVmSize)) {
    $r = $skus | Where-Object name -eq $s | Select-Object -First 1
    if (-not $r) { Fail "$s not offered in $Location" }
    if (@($r.restrictions).Count -gt 0) { Fail "$s is restricted in $Location for this subscription ($($r.restrictions -join ','))" }
    Pass "$s available"
}

# ---------------------------------------------------------------------------------------------
Step "1. Resource group, gallery, image definition (Gen2, TrustedLaunchSupported, SCSI+NVMe)"
az group create -n $ResourceGroup -l $Location -o none
az sig create -g $ResourceGroup --gallery-name $GalleryName -l $Location -o none
az sig image-definition create -g $ResourceGroup --gallery-name $GalleryName `
    --gallery-image-definition $ImageDefinition `
    --publisher "LabAVD" --offer "Win11-AVD" --sku "goldimage-tls" `
    --os-type Windows --os-state Generalized --hyper-v-generation V2 `
    --features "SecurityType=TrustedLaunchSupported DiskControllerTypes=SCSI,NVMe" -l $Location -o none
$feat = az sig image-definition show -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --query "features" -o json
Pass "definition features: $feat"

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
Step "3. Source VM: Marketplace Windows 11, TRUSTED LAUNCH, SCSI size (stands in for the gold image)"
az vm create -g $ResourceGroup -n $srcVm -l $Location `
    --image "MicrosoftWindowsDesktop:windows-11:${SourceSku}:latest" --size $SourceVmSize `
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true `
    --admin-username labadmin --admin-password $pw `
    --public-ip-address '""' --nsg-rule NONE @netArgs -o none
$sec = az vm show -g $ResourceGroup -n $srcVm --query "securityProfile" -o json
Pass "source VM created with securityProfile: $sec"

Step "3a. Marker file (stands in for installed apps), NVMe driver at boot, Sysprep"
az vm run-command invoke -g $ResourceGroup -n $srcVm --command-id RunPowerShellScript --scripts @'
New-Item -ItemType Directory -Path C:\SampleApps -Force | Out-Null
Set-Content C:\SampleApps\marker.txt "Gold image marker $(Get-Date -Format o)"
sc.exe config stornvme start=boot | Out-Null
Get-AppxPackage -AllUsers | Where-Object Name -match 'OneDriveSync|LanguageExperiencePack' | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\sysprep.exe" -ArgumentList '/generalize /oobe /shutdown /mode:vm'
"sysprep started"
'@ --query "value[0].message" -o tsv
Write-Host "  waiting for Sysprep to shut the VM down..."
do { Start-Sleep 30; $ps = az vm get-instance-view -g $ResourceGroup -n $srcVm --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv; Write-Host "    $ps" }
while ($ps -ne 'PowerState/stopped')
az vm deallocate -g $ResourceGroup -n $srcVm -o none
az vm generalize -g $ResourceGroup -n $srcVm -o none
Pass "source VM generalized"

# ---------------------------------------------------------------------------------------------
Step "4. CHECKPOINT A: capture the Trusted Launch VM into the TrustedLaunchSupported definition"
$vmId = az vm show -g $ResourceGroup -n $srcVm --query id -o tsv
az sig image-version create -g $ResourceGroup --gallery-name $GalleryName `
    --gallery-image-definition $ImageDefinition --gallery-image-version $ImageVersion `
    --virtual-machine $vmId --target-regions $Location -o none
$verId = az sig image-version show -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --gallery-image-version $ImageVersion --query "id" -o tsv
if (-not $verId) { Fail "capture did not produce a version" }
Pass "CHECKPOINT A: version $ImageVersion captured from a Trusted Launch VM into a TrustedLaunchSupported definition"
if (-not $KeepSourceVm) { az vm delete -g $ResourceGroup -n $srcVm --yes -o none; Write-Host "  source VM deleted" }

# ---------------------------------------------------------------------------------------------
Step "5. CHECKPOINT B: test VM on $TestVmSize (NVMe-only) with Trusted Launch, from the captured version"
az vm create -g $ResourceGroup -n $testVm -l $Location --image $verId --size $TestVmSize `
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true `
    --admin-username labadmin --admin-password $pw `
    --public-ip-address '""' --nsg-rule NONE @netArgs -o none
$ctrl = az vm show -g $ResourceGroup -n $testVm --query "storageProfile.diskControllerType" -o tsv
Pass "CHECKPOINT B: test VM created, diskControllerType=$ctrl"

# ---------------------------------------------------------------------------------------------
Step "6. CHECKPOINT C: inside the test VM"
$out = az vm run-command invoke -g $ResourceGroup -n $testVm --command-id RunPowerShellScript --scripts @'
$r = [ordered]@{}
$r.OS           = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion + " build " + [Environment]::OSVersion.Version.Build
$r.Controller   = (Get-CimInstance Win32_SCSIController | Select-Object -ExpandProperty Name) -join '; '
$r.NVMe         = [bool](Get-CimInstance Win32_DiskDrive | Where-Object { $_.Model -match 'NVMe' -or $_.PNPDeviceID -match 'NVME' })
$r.SecureBoot   = try { Confirm-SecureBootUEFI } catch { $false }
$r.vTPM         = [bool](Get-Tpm -ErrorAction SilentlyContinue).TpmPresent
$r.Marker       = Test-Path 'C:\SampleApps\marker.txt'
$r.MarkerText   = if ($r.Marker) { Get-Content 'C:\SampleApps\marker.txt' } else { '' }
$r | ConvertTo-Json -Compress
'@ --query "value[0].message" -o tsv
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
Write-Host "Re-capturing an existing Trusted Launch gold image into a TrustedLaunchSupported definition works,"
Write-Host "and the result runs on NVMe-only sizes with Trusted Launch. Applications carry over (marker present)."
Write-Host "Captured version ID (use as Custom Image Template source):"
Write-Host "  $verId"
if ($SkipCleanup) { Write-Host "`nTest VM kept: $testVm. Delete the resource group when done: az group delete -n $ResourceGroup --yes" }
else { az vm delete -g $ResourceGroup -n $testVm --yes -o none; Write-Host "`nTest VM deleted. Gallery and image version kept in $ResourceGroup." }
