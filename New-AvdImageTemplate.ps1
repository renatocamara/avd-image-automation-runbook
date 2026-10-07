<#
.SYNOPSIS
    One script, public resources: creates an AVD Custom Image Template (Azure VM Image Builder) that
    builds a Windows 11 multi-session image from the Marketplace with applications installed by
    script, display languages installed offline from the Microsoft ISO, Windows Update once at the
    end, and Sysprep cleanup. Then starts the build and follows it to the end.

    Expected duration: 10 min setup + 60 to 110 min build (3 languages). Idempotent: run again to
    re-create the template with changes (templates are immutable; the old one is deleted).

.DESCRIPTION
    Steps:
      0. Subscription, resource providers, build VM size availability
      1. Resource group, managed identity, custom role (gallery + image permissions)
      2. Compute Gallery + image definition (Gen2, TrustedLaunchSupported, SCSI+NVMe)
         TrustedLaunchSupported is what Image Builder can write to; VMs from it can use Trusted Launch.
      3. Storage account + container with the customizer scripts and app installers (public endpoint,
         no anonymous access; the build VM reads with the managed identity)
      4. Template JSON (generated next to this script) and template resource, tagged so it shows in
         Azure Virtual Desktop > Custom image templates
      5. Start build and monitor until Succeeded/Failed
    Optional: -SubnetId to build inside an existing VNet (Network Contributor + subnet policy handled).

.EXAMPLE
    .\New-AvdImageTemplate.ps1 -SubscriptionId <sub> -ResourceGroup rg-avd-img-test-lab -Location westus3
.EXAMPLE
    # Lab without a storage account (public repo): customizers from raw GitHub, apps from their downloadUrl
    .\New-AvdImageTemplate.ps1 -ResourceGroup rg-avd-img-test-lab -Location westus3 `
        -ScriptBaseUrl https://raw.githubusercontent.com/renatocamara/avd-image-automation-runbook/main
.EXAMPLE
    .\New-AvdImageTemplate.ps1 -ResourceGroup rg-avd-img-test-lab -Languages "de-DE" -Apps @() -MonitorOnly
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId  = "",
    [string]$ResourceGroup   = "rg-avd-img-test-lab",
    [string]$Location        = "westus3",
    [string]$IdentityName    = "id-avd-imagebuilder",
    [string]$GalleryName     = "galavdtest",
    [string]$ImageDefinition = "win11-avd-template-tls",        # TrustedLaunchSupported + SCSI,NVMe (Image Builder output)
    [string]$StorageAccount  = "",                               # default: stavdimg + 12 chars of the subscription id
    [string]$Container       = "imagebuild",
    [string]$TemplateName    = "cit-win11-avd-multilang",
    [string]$MarketplaceSku  = "win11-25h2-avd",                 # multi-session; use win11-25h2-avd-m365 for M365 Apps
    [string[]]$Languages     = @("de-DE", "fr-FR", "zh-CN"),
    [string[]]$Apps          = @("7zip"),                        # folders under .\apps
    [bool]$ApplyWindowsUpdates = $true,
    [string]$BuildVmSize     = "Standard_D4as_v5",               # x64, SCSI; falls back if restricted
    [int]$BuildTimeoutMinutes = 360,
    [string]$SubnetId        = "",                               # optional: existing subnet resource ID
    [string]$ScriptBaseUrl   = "",                               # optional: public base URL for customizers/ and apps/ (e.g. raw GitHub); skips the storage account
    [string]$StagingResourceGroup = "",                          # optional: pre-created, EMPTY resource group for Image Builder's staging resources (lets you exempt it from policies)
    [switch]$SkipBuild,                                          # create the template only
    [switch]$MonitorOnly                                         # attach to a running build
)
$ErrorActionPreference = "Stop"
$t0 = Get-Date
function Step($msg) { Write-Host ("`n[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -ForegroundColor Cyan }
function Pass($msg) { Write-Host ("  PASS  {0}" -f $msg) -ForegroundColor Green }
function Fail($msg) { Write-Host ("  FAIL  {0}" -f $msg) -ForegroundColor Red; exit 1 }
$apiVersion = "2024-02-01"
$here = $PSScriptRoot

if ($SubscriptionId) { az account set --subscription $SubscriptionId }
$sub = az account show --query "{name:name, id:id}" -o json | ConvertFrom-Json
if (-not $SubscriptionId) { $SubscriptionId = $sub.id }
if (-not $StorageAccount) { $StorageAccount = "stavdimg" + ($SubscriptionId -replace '-', '').Substring(0, 12) }
$templateId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.VirtualMachineImages/imageTemplates/$TemplateName"
Write-Host "Subscription: $($sub.name) ($($sub.id))  Region: $Location  RG: $ResourceGroup  Template: $TemplateName"

# =============================================================================================
function Watch-Build {
    Write-Host "  Build log (if needed): staging resource group of the template > storage account > container packerlogs > customization.log"
    do {
        $s = az resource show --ids $templateId --query "properties.lastRunStatus" -o json | ConvertFrom-Json
        $elapsed = if ($s.startTime) { [math]::Round(((Get-Date) - [datetime]$s.startTime).TotalMinutes) } else { 0 }
        Write-Host ("  [{0}] {1,-10} {2,-14} {3,4} min  {4}" -f (Get-Date -Format 'HH:mm:ss'), $s.runState, $s.runSubState, $elapsed, $s.message)
        if ($s.runState -in 'Running', 'Canceling') { Start-Sleep 60 }
    } while ($s.runState -in 'Running', 'Canceling')
    if ($s.runState -ne 'Succeeded') { Fail "build $($s.runState): $($s.message)" }
    Pass "BUILD SUCCEEDED in $elapsed min"
    az sig image-version list -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition `
        --query "[].{Version:name, Published:publishingProfile.publishedDate, State:provisioningState}" -o table
    $ver = az sig image-version list -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --query "[-1].id" -o tsv
    Write-Host "`nLatest version ID: $ver"
    Write-Host "Test it on an NVMe size with Trusted Launch (same checks as the re-capture script):"
    Write-Host "  az vm create -g $ResourceGroup -n vm-template-test -l $Location --image $ver --size Standard_D4as_v7 --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true --admin-username labadmin --admin-password <pw> --public-ip-address '""""' --nsg-rule NONE$(if ($SubnetId) { " --subnet $SubnetId" })"
}
if ($MonitorOnly) { Step "Monitoring $TemplateName"; Watch-Build; exit 0 }

# =============================================================================================
Step "0. Resource providers and build VM size"
foreach ($p in 'Microsoft.VirtualMachineImages', 'Microsoft.Compute', 'Microsoft.Storage', 'Microsoft.Network', 'Microsoft.ManagedIdentity', 'Microsoft.DesktopVirtualization') {
    $state = az provider show --namespace $p --query registrationState -o tsv
    if ($state -ne 'Registered') { Write-Host "    registering $p ..."; az provider register --namespace $p --wait -o none }
}
Pass "resource providers registered"
$skus = az vm list-skus --location $Location --resource-type virtualMachines --all `
    --query "[].{name:name, restrictions:restrictions[].reasonCode}" -o json | ConvertFrom-Json
function Test-SkuAvailable([string]$size) {
    $r = $skus | Where-Object name -eq $size | Select-Object -First 1
    if (-not $r) { return "not offered in $Location" }
    if (@($r.restrictions).Count -gt 0) { return "restricted ($($r.restrictions -join ','))" }
    return $null
}
$picked = $null
foreach ($c in (@($BuildVmSize) + @("Standard_D4s_v5", "Standard_D4ds_v5", "Standard_D4as_v4", "Standard_D4s_v4", "Standard_D4s_v3") | Select-Object -Unique)) {
    $why = Test-SkuAvailable $c
    if (-not $why) { $picked = $c; break }
    Write-Host "    $c $why, trying next" -ForegroundColor DarkGray
}
if (-not $picked) { Fail "no x64 build VM size available in $Location; pass -BuildVmSize" }
$BuildVmSize = $picked
Pass "build VM size: $BuildVmSize"
$skuOk = az vm image list-skus --location $Location --publisher MicrosoftWindowsDesktop --offer windows-11 --query "[?name=='$MarketplaceSku'].name" -o tsv
if (-not $skuOk) { Fail "Marketplace SKU $MarketplaceSku not found in $Location (az vm image list-skus -l $Location -p MicrosoftWindowsDesktop -f windows-11 -o table)" }
Pass "Marketplace SKU $MarketplaceSku available"

# =============================================================================================
Step "1. Resource group, managed identity, custom role"
az group create -n $ResourceGroup -l $Location -o none
az identity create -g $ResourceGroup -n $IdentityName -l $Location -o none
$identityId  = az identity show -g $ResourceGroup -n $IdentityName --query id -o tsv
$principalId = az identity show -g $ResourceGroup -n $IdentityName --query principalId -o tsv
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$roleName = "AVD Image Builder ($ResourceGroup)"
$roleFile = Join-Path ([IO.Path]::GetTempPath()) "avd-imagebuilder-role.json"
@{
    Name = $roleName
    Description = "Lets AVD custom image templates (Azure Image Builder) read the gallery and write image versions."
    Actions = @("Microsoft.Compute/galleries/read", "Microsoft.Compute/galleries/images/read",
                "Microsoft.Compute/galleries/images/versions/read", "Microsoft.Compute/galleries/images/versions/write",
                "Microsoft.Compute/images/write", "Microsoft.Compute/images/read", "Microsoft.Compute/images/delete")
    NotActions = @()
    AssignableScopes = @($scope)
} | ConvertTo-Json | Set-Content $roleFile -Encoding ascii
if (-not (az role definition list --name $roleName --query "[0].roleName" -o tsv)) {
    az role definition create --role-definition "@$roleFile" -o none
    Write-Host "    custom role created, waiting 60 s for replication"; Start-Sleep 60
}
$ErrorActionPreference = "Continue"
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role $roleName --scope $scope -o none 2>$null
$ErrorActionPreference = "Stop"
Pass "identity $IdentityName with role '$roleName' on $ResourceGroup"

# =============================================================================================
Step "2. Compute Gallery and image definition (Gen2, TrustedLaunchSupported, SCSI+NVMe)"
az sig create -g $ResourceGroup --gallery-name $GalleryName -l $Location -o none
az sig image-definition create -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition `
    --publisher "LabAVD" --offer "Win11-AVD" --sku "template-multilang" `
    --os-type Windows --os-state Generalized --hyper-v-generation V2 `
    --features "SecurityType=TrustedLaunchSupported DiskControllerTypes=SCSI,NVMe" -l $Location --only-show-errors -o none
$imageDefId = az sig image-definition show -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --query id -o tsv
$feat = az sig image-definition show -g $ResourceGroup --gallery-name $GalleryName --gallery-image-definition $ImageDefinition --query "features[].value" -o tsv
Pass "definition $ImageDefinition features: $($feat -join ' | ')"

# =============================================================================================
if ($ScriptBaseUrl) {
    Step "3. Scripts and installers from $ScriptBaseUrl (no storage account)"
    $ScriptBaseUrl = $ScriptBaseUrl.TrimEnd('/')
    foreach ($f in 'customizers/Install-Languages.ps1', 'customizers/Install-App.ps1', 'customizers/Sysprep-Cleanup.ps1') {
        try { $null = Invoke-WebRequest -Uri "$ScriptBaseUrl/$f" -UseBasicParsing -Method Head } catch { Fail "$ScriptBaseUrl/$f is not reachable" }
    }
    Pass "customizers reachable; apps will be downloaded from the downloadUrl in each app.json"
} else {
Step "3. Storage account with customizers and installers"
    # public endpoint on purpose: the build VM lives in Image Builder's own network and reads the blobs with
    # the managed identity (no anonymous access). Some subscriptions default new accounts to Deny, so set it explicitly.
    az storage account create -n $StorageAccount -g $ResourceGroup -l $Location --sku Standard_LRS --kind StorageV2 `
        --allow-blob-public-access false --min-tls-version TLS1_2 --public-network-access Enabled --default-action Allow `
        --bypass AzureServices --only-show-errors -o none
    az storage account update -n $StorageAccount -g $ResourceGroup --public-network-access Enabled --default-action Allow --bypass AzureServices -o none
    $net = az storage account show -n $StorageAccount -g $ResourceGroup --query "[publicNetworkAccess, networkRuleSet.defaultAction]" -o tsv
    if (($net -join ' ') -notmatch 'Enabled\s+Allow') { Fail "storage account network rules are '$($net -join '/')'; a policy may enforce Deny. Use -SubnetId with a Storage service endpoint, or allow public access on $StorageAccount" }
    $saId = az storage account show -n $StorageAccount -g $ResourceGroup --query id -o tsv
    $ErrorActionPreference = "Continue"
    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Reader" --scope $saId -o none 2>$null
    $me = az ad signed-in-user show --query id -o tsv 2>$null
    if ($me) { az role assignment create --assignee-object-id $me --assignee-principal-type User --role "Storage Blob Data Contributor" --scope $saId -o none 2>$null }
    $ErrorActionPreference = "Stop"
    az storage container create -n $Container --account-name $StorageAccount --auth-mode login --only-show-errors -o none
    # upload with retry: the Blob Data Contributor assignment can take a minute to apply
    function Upload-Blob($file, $name) {
        for ($i = 1; $i -le 6; $i++) {
            az storage blob upload --account-name $StorageAccount -c $Container -f $file -n $name --auth-mode login --overwrite --only-show-errors -o none 2>$null
            if ($LASTEXITCODE -eq 0) { return }
            Write-Host "    upload of $name failed (attempt $i), waiting 20 s for role propagation"; Start-Sleep 20
        }
        Fail "could not upload $name to $StorageAccount/$Container"
    }
    foreach ($f in 'Install-Languages.ps1', 'Install-App.ps1', 'Sysprep-Cleanup.ps1') { Upload-Blob (Join-Path $here "customizers\$f") "customizers/$f" }
    foreach ($app in $Apps) {
        $dir = Join-Path $here "apps\$app"
        $manifest = Get-Content (Join-Path $dir "app.json") -Raw | ConvertFrom-Json
        $installer = Join-Path $dir $manifest.installer
        if (-not (Test-Path $installer)) {
            Write-Host "    downloading $($manifest.installer) from $($manifest.downloadUrl)"
            $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri $manifest.downloadUrl -OutFile $installer -UseBasicParsing
        }
        Upload-Blob (Join-Path $dir "app.json") "apps/$app/app.json"
        Upload-Blob $installer "apps/$app/$($manifest.installer)"
    }
    Pass "uploaded customizers and $($Apps.Count) app(s) to $StorageAccount/$Container"
}

# =============================================================================================
Step "4. Template $TemplateName"
# each customizer downloads its script and runs it. Storage mode: token from IMDS (template identity).
# URL mode: plain public download (lab only).
function Script-Customizer($name, $script, $argLine) {
    if ($ScriptBaseUrl) {
        $inline = @(
            "`$ProgressPreference='SilentlyContinue'",
            "Invoke-WebRequest -Uri '$ScriptBaseUrl/customizers/$script' -OutFile C:\Windows\Temp\$script -UseBasicParsing",
            "& C:\Windows\Temp\$script $argLine")
    } else {
        $blobBase = "https://$StorageAccount.blob.core.windows.net/$Container"
        $inline = @(
            "`$ProgressPreference='SilentlyContinue'",
            "`$t=(Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/').access_token",
            "Invoke-WebRequest -Uri '$blobBase/customizers/$script' -Headers @{Authorization=""Bearer `$t"";'x-ms-version'='2021-08-06'} -OutFile C:\Windows\Temp\$script -UseBasicParsing",
            "& C:\Windows\Temp\$script $argLine")
    }
    @{ type = "PowerShell"; name = $name; runElevated = $true; runAsSystem = $true; inline = $inline }
}
$customize = @()
foreach ($app in $Apps) {
    $appArgs = if ($ScriptBaseUrl) { "-ManifestUrl '$ScriptBaseUrl/apps/$app/app.json' -AppName '$app'" } else { "-StorageAccount '$StorageAccount' -Container '$Container' -AppName '$app'" }
    $customize += Script-Customizer "App-$app" "Install-App.ps1" $appArgs
}
if ($Languages.Count -gt 0) {
    $customize += Script-Customizer "InstallLanguages" "Install-Languages.ps1" "-Languages '$($Languages -join ',')'"
    $customize += @{ type = "WindowsRestart"; name = "RestartAfterLanguages"; restartTimeout = "30m" }
}
if ($ApplyWindowsUpdates) {
    $customize += @{ type = "WindowsUpdate"; name = "WindowsUpdate"; searchCriteria = "IsInstalled=0"
                     filters = @("exclude:`$_.Title -like '*Preview*'", "include:`$true"); updateLimit = 40 }
    $customize += @{ type = "WindowsRestart"; name = "RestartAfterUpdates"; restartTimeout = "30m" }
}
$customize += Script-Customizer "SysprepCleanup" "Sysprep-Cleanup.ps1" ""

$vmProfile = @{ vmSize = $BuildVmSize; osDiskSizeGB = 127; userAssignedIdentities = @($identityId) }
if ($SubnetId) {
    $vnetId = ($SubnetId -split '/subnets/')[0]
    $ErrorActionPreference = "Continue"
    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Network Contributor" --scope $vnetId -o none 2>$null
    $ErrorActionPreference = "Stop"
    az network vnet subnet update --ids $SubnetId --private-link-service-network-policies Disabled -o none
    $vmProfile.vnetConfig = @{ subnetId = $SubnetId }
    Write-Host "    building inside $SubnetId"
}
$props = [ordered]@{}
if ($StagingResourceGroup) {
    # Image Builder creates a storage account in its staging RG and uses shared-key auth on it. A policy that
    # disables shared key access or public network access on storage breaks the build ("Key based
    # authentication is not permitted"). A fixed staging RG is the scope to exempt from that policy.
    az group create -n $StagingResourceGroup -l $Location -o none
    $ErrorActionPreference = "Continue"
    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role Contributor --scope "/subscriptions/$SubscriptionId/resourceGroups/$StagingResourceGroup" -o none 2>$null
    $ErrorActionPreference = "Stop"
    $props.stagingResourceGroup = "/subscriptions/$SubscriptionId/resourceGroups/$StagingResourceGroup"
    Write-Host "    staging resource group: $StagingResourceGroup (exempt it from storage network/shared-key policies if needed)"
}
$template = [ordered]@{
    type = "Microsoft.VirtualMachineImages/imageTemplates"; apiVersion = $apiVersion; location = $Location
    tags = @{ AVD_IMAGE_TEMPLATE = "AVD_IMAGE_TEMPLATE" }     # makes it visible under AVD > Custom image templates
    identity = @{ type = "UserAssigned"; userAssignedIdentities = @{ $identityId = @{} } }
    properties = $props + [ordered]@{
        buildTimeoutInMinutes = $BuildTimeoutMinutes
        vmProfile  = $vmProfile
        source     = @{ type = "PlatformImage"; publisher = "MicrosoftWindowsDesktop"; offer = "windows-11"; sku = $MarketplaceSku; version = "latest" }
        customize  = $customize
        distribute = @(@{ type = "SharedImage"; galleryImageId = $imageDefId; runOutputName = "$TemplateName-run"; excludeFromLatest = $false
                          targetRegions = @(@{ name = $Location; replicaCount = 1; storageAccountType = "Standard_LRS" }) })
    }
}
$outDir = Join-Path $here "generated"; New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$outFile = Join-Path $outDir "$TemplateName.json"
$template | ConvertTo-Json -Depth 20 | Set-Content $outFile -Encoding utf8
Write-Host "    template JSON: $outFile"
# templates are immutable: replace if it exists (a running build must be cancelled first)
$ErrorActionPreference = "Continue"
$existing = az resource show --ids $templateId --query "properties.lastRunStatus.runState" -o tsv 2>$null
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -eq 0) {
    if ($existing -eq 'Running') { Fail "template $TemplateName has a build running; use -MonitorOnly or cancel it first" }
    Write-Host "    template exists, replacing it"
    az resource delete --ids $templateId -o none
}
az resource create -g $ResourceGroup -n $TemplateName --resource-type Microsoft.VirtualMachineImages/imageTemplates `
    --api-version $apiVersion --is-full-object --properties "@$outFile" --only-show-errors -o none
$prov = az resource show --ids $templateId --query "properties.provisioningState" -o tsv
if ($prov -ne 'Succeeded') { Fail "template provisioning: $prov ($(az resource show --ids $templateId --query 'properties.provisioningError.message' -o tsv))" }
Pass "template created: $($customize.Count) customizers (apps: $($Apps -join ','); languages: $($Languages -join ','); updates: $ApplyWindowsUpdates; scripts from $(if ($ScriptBaseUrl) { $ScriptBaseUrl } else { $StorageAccount }))"
if ($SkipBuild) { Write-Host "`n-SkipBuild: start it with  az resource invoke-action --action run --ids $templateId --no-wait"; exit 0 }

# =============================================================================================
Step "5. Build (60 to 110 min with 3 languages)"
az resource invoke-action --action run --ids $templateId --no-wait -o none
Start-Sleep 30
Watch-Build
Write-Host ("`nTotal {0} min." -f [math]::Round(((Get-Date) - $t0).TotalMinutes))
