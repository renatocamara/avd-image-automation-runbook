# AVD Image Automation Runbook

Fast, public-by-default validation of one question for Azure Virtual Desktop gold images:

> Can an existing **Trusted Launch** gold image be re-captured into a **TrustedLaunchSupported**
> Compute Gallery definition and run on an **NVMe-only** VM size (Dasv7) with Trusted Launch enabled,
> keeping its installed applications?

If yes, that re-captured image can be used as the source of an AVD **Custom Image Template**
(Azure VM Image Builder), which rejects `SecurityType = TrustedLaunch` sources but accepts
`TrustedLaunchSupported` ([documentation](https://learn.microsoft.com/en-us/azure/virtual-machines/image-builder-overview#confidential-vm-and-trusted-launch-support)).

## Run it

Requirements: PowerShell 7, Azure CLI, `az login`, Contributor on the subscription.

```powershell
$pw = Read-Host -AsSecureString "Admin password for the lab VMs"
.\Test-TrustedLaunchRecapture.ps1 -AdminPassword $pw -ResourceGroup rg-avd-img-test-lab -Location eastus2
```

About 35 to 50 minutes. The script prints one line per checkpoint and stops on the first failure.

| Checkpoint | Proves |
|---|---|
| A | A Trusted Launch VM can be captured into a `TrustedLaunchSupported` definition |
| B | The captured version deploys on `Standard_D4as_v7` with Trusted Launch |
| C | Inside that VM: NVMe controller, Secure Boot on, vTPM present, marker file from the source image present |

## Optional: run inside an existing VNet

By default the script creates a small temporary VNet in the resource group. VMs never get a public IP;
everything runs through Azure Run Command. To use your own subnet instead, pass its resource ID:

```powershell
$subnet = az network vnet subnet show -g <vnet-rg> --vnet-name <vnet> -n <subnet> --query id -o tsv
.\Test-TrustedLaunchRecapture.ps1 -AdminPassword $pw -SubnetId $subnet
```

Nothing else changes. Pick whichever fits your environment.

## Applying this to a real gold image

Replace step 3 of the script (the Marketplace VM) with a VM created from your current gold image
version, then run the same Sysprep, capture, and test steps. In Azure CLI terms:

```powershell
$src = az sig image-version show -g <rg> --gallery-name <gallery> --gallery-image-definition <current-def> --gallery-image-version <ver> --query id -o tsv
az vm create -g <rg> -n vm-gold-src --image $src --size Standard_D4as_v5 --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true ...
```

## Cleanup

```powershell
az group delete -n rg-avd-img-test-lab --yes --no-wait
```

## Related

`avd-image-automation-playbook` holds the full Custom Image Template pipeline (apps, languages, update cycle).
This runbook is the quick proof that feeds it.
