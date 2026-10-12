# Findings, fixes and measured times

Everything here was hit in a lab subscription while building the scripts. Each item has the symptom, the
cause and what the scripts do about it.

## Trusted Launch images and the Custom Image Template

**Symptom:** the AVD Custom Image Template wizard refuses an existing Trusted Launch gold image as the source.

**Cause:** Azure VM Image Builder accepts `TrustedLaunchSupported` sources, not `TrustedLaunch`
([documentation](https://learn.microsoft.com/azure/virtual-machines/image-builder-overview#confidential-vm-and-trusted-launch-support)).
Re-capturing the image into a `TrustedLaunchSupported` definition does not work either; the platform refuses it:

```
(Conflict) The source '.../virtualMachines/vm-gold-src' contains TrustedLaunch or ConfidentialVM
security data that cannot be used in image with 'TrustedLaunchSupported' security type.
Please use either TrustedLaunch or ConfidentialVM security type.
```

A snapshot of the OS disk into a `TrustedLaunchSupported` definition was also tried (step 4b of
`Test-TrustedLaunchRecapture.ps1`, skipped with `-SkipExperiment`) and refused.

**Result:**

| Goal | Works? | How |
|---|---|---|
| Move the current gold image (apps included) to Dasv7 / NVMe and use session host update | Yes | Re-capture into a `TrustedLaunch` + `SCSI, NVMe` definition (`Test-TrustedLaunchRecapture.ps1`) |
| Use the current gold image as a Custom Image Template source | No | Platform limitation, see above |
| Automated, repeatable builds | Yes | Start from the Marketplace image and install apps and languages by script (`New-AvdImageTemplate.ps1`) |

## Display languages: offline install from the ISO

**Symptom:** a build with languages failed after 65 minutes with "The operation has timed out" inside
`Install-Language de-DE`.

**Cause:** on a patched image, `Install-Language` resolves every component through Windows Update, one at a time,
and gives up after about an hour.

**Fix:** `customizers/Install-Languages.ps1` downloads the Microsoft *Languages and Optional Features* ISO, mounts
it, and installs the language pack `.cab` plus the Features on Demand with `-Source <iso> -LimitAccess`, fully
offline. Windows Update runs once afterwards and brings the language components to the image's patch level. The
script also disables the scheduled tasks that remove unused language packs on the hosts (`LPRemove`,
`Pre-staged app cleanup`, `Uninstallation`) and sets `BlockCleanupOfUnusedPreinstalledLangPacks`.

`und-Hans` in `Get-InstalledLanguage` is the Simplified Chinese font package installed with zh-CN, not an extra language.

## NVMe at boot and Sysprep blockers

Before Sysprep, `Test-TrustedLaunchRecapture.ps1` sets the `stornvme` driver to start at boot, so an image built
on a SCSI size boots on an NVMe-only size, and removes the per-user Appx packages that commonly block Sysprep
(`OneDriveSync`, `LanguageExperiencePack`). If Sysprep does not finish in 25 minutes, it prints the end of
`setuperr.log`. `Update-GoldImage.ps1` also waits until `TiWorker` / `dism` are idle before Sysprep: a VM fresh
from a generalized image is often still servicing for a few minutes.

## Azure Policy and Image Builder staging storage

**Symptom:** the template build fails in the first minutes with "Key based authentication is not permitted on this
storage account", or a storage account's public network access keeps reverting to Disabled.

**Cause:** Image Builder creates its own storage account in a staging resource group and uses the storage key. A
policy with a `Modify` effect that disables shared key access or public network access on storage accounts breaks it.

**Fix:** a dedicated, **empty** staging resource group (`-StagingResourceGroup`; Image Builder refuses one that
already has resources) with a policy exemption scoped to it only:

```powershell
# find the assignment and reference IDs
az policy state list -o json | ConvertFrom-Json |
  Where-Object { $_.policyDefinitionAction -eq 'modify' -and $_.resourceType -like '*storageAccounts*' } |
  Select-Object policyAssignmentId, policyDefinitionReferenceId -Unique

az group create -n rg-avd-img-staging -l <region> -o none
az policy exemption create -n ex-imagebuilder-staging -g rg-avd-img-staging `
  --policy-assignment "<assignment id>" --policy-definition-reference-ids <ref-1> <ref-2> `
  --exemption-category Waiver --display-name "Image Builder staging storage"
```

Without permission to create exemptions, validate the customizers with `Test-CustomizersOnVm.ps1` instead.

## Lab networking

New VNets have no default outbound internet access. The lab VMs need it to download installers, the language ISO
and updates, so the scripts attach a NAT gateway to the temporary subnet. With `-SubnetId`, the subnet's existing
egress is used.

## Tooling notes

- PowerShell ISE turns informational Azure CLI messages on stderr (for example region recommendations) into
  terminating errors. Use PowerShell 7 in Windows Terminal, VS Code or Cloud Shell. The scripts also switch the
  region message off for their own run.
- Multi-line scripts passed inline to `az vm run-command` get mangled on Windows; the scripts write them to a temp
  file and pass `@file`.
- VM computer names are limited to 15 characters.

## Measured times (lab)

Windows 11 25H2 multi-session, build VM `Standard_D4as_v4`, test VM `Standard_D4as_v7`.

| Run | Time | Result |
|---|---|---|
| `Update-GoldImage.ps1`, 7-Zip + time zone redirection | 26 min | Installed and verified on the new version; NVMe, Secure Boot, vTPM on Dasv7 |
| `Update-GoldImage.ps1`, FSLogix profile settings | 27 min | Settings verified on the new version |
| `Test-CustomizersOnVm.ps1`, 7-Zip + de-DE, fr-FR, zh-CN | 27 min | ISO 6 min, de-DE 5 min, fr-FR 4 min, zh-CN 5 min; 21 language capabilities |
| `New-AvdImageTemplate.ps1`, full Image Builder build, same customizers + Windows Update | 91 min | Boots on Dasv7 with NVMe, three languages and 7-Zip |
| `Install-Language` (before the fix) | timed out at 65 min | First language never finished |
