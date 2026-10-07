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

## Cleanup

```powershell
az group delete -n rg-avd-img-test-lab --yes --no-wait
```

## Related

`avd-image-automation-playbook` holds the full Custom Image Template pipeline (apps, languages, update cycle).
This runbook is the quick proof that feeds it.
