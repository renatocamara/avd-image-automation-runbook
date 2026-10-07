# AVD Image Automation Runbook

Fast, public-by-default validation of one question for Azure Virtual Desktop gold images:

> Can an existing **Trusted Launch** gold image be re-captured into a new Compute Gallery definition
> that allows NVMe (`DiskControllerTypes = SCSI, NVMe`) and run on an **NVMe-only** VM size (Dasv7)
> with Trusted Launch enabled, keeping its installed applications?

## Finding so far

The first run answered a second question on the way. Capturing a Trusted Launch VM into a
**`TrustedLaunchSupported`** definition is refused by the platform:

```
(Conflict) The source '.../virtualMachines/vm-gold-src' contains TrustedLaunch or ConfidentialVM
security data that cannot be used in image with 'TrustedLaunchSupported' security type.
Please use either TrustedLaunch or ConfidentialVM security type.
```

Combined with the Image Builder limitation (it accepts `TrustedLaunchSupported` sources but not
`TrustedLaunch`, [documentation](https://learn.microsoft.com/en-us/azure/virtual-machines/image-builder-overview#confidential-vm-and-trusted-launch-support)),
this means:

| Goal | Works? | How |
|---|---|---|
| Move the current gold image (apps included) to Dasv7 / NVMe, and use session host update | Yes (checkpoints A, B, C) | Re-capture it into a new `TrustedLaunch` + `SCSI, NVMe` definition |
| Use the current gold image as the source of a Custom Image Template | No | Image Builder cannot take a `TrustedLaunch` image, and the image cannot be re-captured as `TrustedLaunchSupported` |
| Automated, repeatable builds (Custom Image Template) | Yes | Start from the Marketplace image and install applications and languages with scripts |

The script also tries the snapshot route (OS disk snapshot into a `TrustedLaunchSupported` definition)
as a non-fatal experiment, step 4b, to close that door with evidence rather than assumption.

## Run it

Requirements: PowerShell 7, Azure CLI, `az login`, Contributor on the subscription.

```powershell
$pw = Read-Host -AsSecureString "Admin password for the lab VMs"
.\Test-TrustedLaunchRecapture.ps1 -AdminPassword $pw -ResourceGroup rg-avd-img-test-lab -Location westus3
```

About 35 to 50 minutes. The script prints one line per checkpoint and stops on the first failure.

| Checkpoint | Proves |
|---|---|
| A | A Trusted Launch VM can be captured into a `TrustedLaunch` + `SCSI, NVMe` definition |
| B | The captured version deploys on `Standard_D4as_v7` with Trusted Launch |
| C | Inside that VM: NVMe controller, Secure Boot on, vTPM present, marker file from the source image present |

> Region note: Dasv7 sizes are not offered in every region. Step 0 of the script checks that `Standard_D4as_v5` and `Standard_D4as_v7` are available and unrestricted in the chosen region and stops before creating anything if not. In our lab subscription `Standard_D4as_v7` was only available in **West US 3**, hence the default.

## Optional: run inside an existing VNet

By default the script creates a small temporary VNet in the resource group. VMs never get a public IP;
everything runs through Azure Run Command. To use your own subnet instead, pass its resource ID:

```powershell
$subnet = az network vnet subnet show -g <vnet-rg> --vnet-name <vnet> -n <subnet> --query id -o tsv
.\Test-TrustedLaunchRecapture.ps1 -AdminPassword $pw -SubnetId $subnet
```

Nothing else changes. Pick whichever fits your environment.

## Applying this to your real gold image

Pass `-SourceImageVersionId` with the resource ID of your current gold image version. The script then
creates the source VM from it (applications included) instead of the Marketplace image, and runs the same
preparation, Sysprep, capture into the new `TrustedLaunch` + `SCSI, NVMe` definition, and Dasv7 test:

```powershell
$src = az sig image-version show -g <rg> --gallery-name <gallery> --gallery-image-definition <current-def> --gallery-image-version <ver> --query id -o tsv
.\Test-TrustedLaunchRecapture.ps1 -AdminPassword $pw -ResourceGroup <rg> -Location <region> `
    -GalleryName <gallery> -ImageDefinition <new-nvme-def> -ImageVersion 2026.1.0 `
    -SourceImageVersionId $src -SubnetId <your subnet id> -SkipExperiment
```

`-SkipExperiment` leaves out the `TrustedLaunchSupported` experiment definition (step 4b), which has no
place in a real gallery. The script is safe to run in an existing resource group and gallery: it only adds
the new definition, the new version and two temporary VMs (`vm-gold-src`, `vm-gold-test`), which must not
exist beforehand.

The marker file is still written (harmless) so checkpoint C stays identical. Add `-KeepSourceVm` if you
want to inspect the generalized VM afterwards.

## New gold image revision from a VM you built by hand

This is the day-to-day flow once the NVMe definition exists: build the next gold image on a VM the way you
do today (install, configure, do **not** Sysprep), then let the script do the rest:

```powershell
.\Test-TrustedLaunchRecapture.ps1 -AdminPassword $pw -ResourceGroup <image-rg> -GalleryName <gallery> `
    -ImageDefinition <nvme-definition> -ImageVersion 2026.2.0 `
    -SourceVmName <gold-image-vm> -SourceVmResourceGroup <vm-rg> -SkipExperiment
```

With `-SourceVmName` the script: checks the VM is running, Trusted Launch and idle (no `TiWorker`/`dism`
still servicing), snapshots its OS disk (`-SkipSnapshot` to skip), sets `stornvme` to start at boot, removes
the per-user packages that block Sysprep, runs Sysprep, captures the VM into the definition as the given
version, and boots a Dasv7 test VM to confirm NVMe, Secure Boot, vTPM and the installed languages. The source
VM is never deleted, but it is generalized by Sysprep and will not boot again; the snapshot is the way back.
The subnet is taken from the VM's NIC unless `-SubnetId` is given.

Roll the new version out with **Session host update** on a host pool created with session host configuration.

## Automated build: Custom Image Template (`New-AvdImageTemplate.ps1`)

The other half of the picture: a repeatable build that starts from the Marketplace Windows 11
multi-session image, installs applications by script, adds display languages, patches once, runs
Sysprep cleanup and publishes to the gallery. One script, public resources, no Image Builder
extension needed in the CLI.

```powershell
.\New-AvdImageTemplate.ps1 -SubscriptionId <sub> -ResourceGroup rg-avd-img-test-lab -Location westus3
# attach to a running build
.\New-AvdImageTemplate.ps1 -ResourceGroup rg-avd-img-test-lab -MonitorOnly
```

What it creates: managed identity + custom role, gallery definition `win11-avd-template-tls`
(`TrustedLaunchSupported`, `SCSI, NVMe`: the only security type Image Builder can write to; VMs made from
it still run with Trusted Launch), a storage account with the `customizers/` scripts and `apps/` installers,
and the template resource tagged for the AVD portal blade. Then it starts the build and follows it.

Customizer order: apps (`apps/<name>/app.json`, see 7-Zip), languages, restart, Windows Update, restart,
Sysprep cleanup. `-Languages @()` or `-Apps @()` to leave a step out. `-SubnetId` to build inside an
existing VNet.

### If the build fails with "Key based authentication is not permitted on this storage account"

Image Builder creates its own storage account in a staging resource group and talks to it with the
storage key. A subscription policy that disables shared key access (or public network access) on
storage accounts kills the build in the first minutes, before any customizer runs. Image Builder cannot
work around it; the fix is a policy exemption on the staging resource group. Pass
`-StagingResourceGroup <name>` so the template uses a fixed, pre-created resource group you can exempt.
If you cannot create exemptions in that subscription (shared or sandbox subscriptions), validate the
customizers on a plain VM instead with `Test-CustomizersOnVm.ps1`, which runs the same scripts in the
same order through Run Command, then capture that VM with `Test-TrustedLaunchRecapture.ps1 -SourceVmName`.

### Measured result (lab, Windows 11 25H2 multi-session, Standard_D4as_v4)

`Test-CustomizersOnVm.ps1` with 7-Zip plus de-DE, fr-FR and zh-CN: ISO download 6 min, de-DE 5 min,
fr-FR 4 min, zh-CN 5 min (fonts included), 27 min end to end including reboot and verification. All three
languages reported by `Get-InstalledLanguage`, 21 language capabilities installed, cleanup tasks disabled.
The previous attempt with `Install-Language` had timed out after 65 minutes on the first language.

### Why the language step uses the ISO and not `Install-Language`

The first build with languages failed after 65 minutes with "The operation has timed out" inside
`Install-Language de-DE`. On a patched image that cmdlet resolves every component through Windows
Update, one at a time, and gives up after about an hour. `customizers/Install-Languages.ps1` instead
downloads the Microsoft *Languages and Optional Features* ISO, mounts it, and installs the language
pack `.cab` plus the Features on Demand with `-Source <iso> -LimitAccess`: fully offline, 10 to 15 minutes
per language. Windows Update runs once, after the languages, and brings them to the image's patch level.
It also disables the cleanup tasks that would otherwise remove unused language packs on the hosts.

## Cleanup

```powershell
az group delete -n rg-avd-img-test-lab --yes --no-wait
```

## Related

`avd-image-automation-playbook` is the longer-form version of the same pipeline (docs, design decisions,
private networking as a later step). This runbook is the short, public, one-script-per-outcome version.
