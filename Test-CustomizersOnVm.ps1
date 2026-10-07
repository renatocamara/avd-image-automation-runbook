<#
.SYNOPSIS
    Runs the template customizers on a plain VM instead of inside Image Builder. Use it to validate the
    scripts (languages, apps, cleanup) when Image Builder cannot run in the subscription (for example a
    policy that disables shared key access on its staging storage account), or to test a customizer
    change in 45 minutes instead of a 2-hour build.

    Flow: Marketplace Windows 11 multi-session VM (Trusted Launch) -> Run Command downloads and runs the
    customizers from -ScriptBaseUrl in the background -> polls a done marker -> reports installed
    languages and apps. The VM is left running so you can capture it with
    Test-TrustedLaunchRecapture.ps1 -SourceVmName (same prep + Sysprep + capture + Dasv7 test as production).

.EXAMPLE
    $pw = Read-Host -AsSecureString "Admin password"
    .\Test-CustomizersOnVm.ps1 -AdminPassword $pw -SubscriptionId <sub> -ResourceGroup rg-avd-img-test-lab -Location westus3 `
        -ScriptBaseUrl https://raw.githubusercontent.com/renatocamara/avd-image-automation-runbook/main
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [securestring]$AdminPassword,
    [string]$SubscriptionId = "",
    [string]$ResourceGroup  = "rg-avd-img-test-lab",
    [string]$Location       = "westus3",
    [string]$VmName         = "vm-customizer-test",
    [string]$VmSize         = "Standard_D4as_v4",
    [string]$MarketplaceSku = "win11-25h2-avd",
    [string[]]$Languages    = @("de-DE", "fr-FR", "zh-CN"),
    [string[]]$Apps         = @("7zip"),
    [Parameter(Mandatory)] [string]$ScriptBaseUrl,     # public base URL with customizers/ and apps/
    [string]$SubnetId       = "",                      # optional; default: temporary VNet in the resource group
    [int]$TimeoutMinutes    = 120
)
$ErrorActionPreference = "Stop"
$pw = [System.Net.NetworkCredential]::new("", $AdminPassword).Password
$ScriptBaseUrl = $ScriptBaseUrl.TrimEnd('/')
$t0 = Get-Date
function Step($msg) { Write-Host ("`n[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -ForegroundColor Cyan }
function Pass($msg) { Write-Host ("  PASS  {0}" -f $msg) -ForegroundColor Green }
function Fail($msg) { Write-Host ("  FAIL  {0}" -f $msg) -ForegroundColor Red; exit 1 }
function Invoke-OnVm([string]$script) {
    $f = Join-Path ([IO.Path]::GetTempPath()) "avd-rc-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
    $script | Set-Content $f -Encoding ascii
    $out = az vm run-command invoke -g $ResourceGroup -n $VmName --command-id RunPowerShellScript --scripts "@$f" --query "value[0].message" -o tsv
    Remove-Item $f -ErrorAction SilentlyContinue
    return $out
}
if ($SubscriptionId) { az account set --subscription $SubscriptionId }

Step "1. VM $VmName from $MarketplaceSku (Trusted Launch)"
az group create -n $ResourceGroup -l $Location -o none
if (-not $SubnetId) {
    az network vnet create -g $ResourceGroup -n vnet-imgtest --address-prefix 10.200.0.0/24 --subnet-name snet-vms --subnet-prefix 10.200.0.0/26 -l $Location --only-show-errors -o none
    $SubnetId = az network vnet subnet show -g $ResourceGroup --vnet-name vnet-imgtest -n snet-vms --query id -o tsv
}
az vm create -g $ResourceGroup -n $VmName -l $Location --image "MicrosoftWindowsDesktop:windows-11:${MarketplaceSku}:latest" --size $VmSize `
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true `
    --admin-username labadmin --admin-password $pw --subnet $SubnetId --public-ip-address '""' --nsg-rule NONE --only-show-errors -o none
if ($LASTEXITCODE -ne 0) { Fail "VM creation failed" }
Pass "VM created"

Step "2. Customizers in the background on the VM (same order as the template)"
$lines = @('$ProgressPreference = "SilentlyContinue"', 'Start-Transcript C:\Windows\Temp\customizers.log -Append | Out-Null', 'try {')
foreach ($app in $Apps) {
    $lines += "Invoke-WebRequest -Uri '$ScriptBaseUrl/customizers/Install-App.ps1' -OutFile C:\Windows\Temp\Install-App.ps1 -UseBasicParsing"
    $lines += "& C:\Windows\Temp\Install-App.ps1 -ManifestUrl '$ScriptBaseUrl/apps/$app/app.json' -AppName '$app'"
}
if ($Languages.Count -gt 0) {
    $lines += "Invoke-WebRequest -Uri '$ScriptBaseUrl/customizers/Install-Languages.ps1' -OutFile C:\Windows\Temp\Install-Languages.ps1 -UseBasicParsing"
    $lines += "& C:\Windows\Temp\Install-Languages.ps1 -Languages '$($Languages -join ',')'"
}
$lines += '"OK" | Set-Content C:\Windows\Temp\customizers.done'
$lines += '} catch { "FAILED: $_" | Set-Content C:\Windows\Temp\customizers.done; throw }'
$lines += 'finally { Stop-Transcript | Out-Null }'
$runner = ($lines -join "`r`n")
# Run Command has a 90 min limit; start the work detached and poll a marker instead
$launcher = @"
Set-Content -Path C:\Windows\Temp\run-customizers.ps1 -Value @'
$runner
'@
Remove-Item C:\Windows\Temp\customizers.done -ErrorAction SilentlyContinue
Start-Process powershell.exe -ArgumentList '-ExecutionPolicy Bypass -NoProfile -File C:\Windows\Temp\run-customizers.ps1' -WindowStyle Hidden
"started"
"@
$out = (Invoke-OnVm $launcher) -join "`n"
if ($out -notmatch 'started') { Fail "could not start the customizers: $out" }
Write-Host "  running: apps=$($Apps -join ',') languages=$($Languages -join ','); polling every 2 min (ISO download + ~12 min per language)"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    Start-Sleep 120
    $st = (Invoke-OnVm 'if (Test-Path C:\Windows\Temp\customizers.done) { Get-Content C:\Windows\Temp\customizers.done } else { "RUNNING: " + ((Get-Content C:\Windows\Temp\imagebuild-languages.log -Tail 1 -ErrorAction SilentlyContinue) -replace "^\s+","") }') -join "`n"
    Write-Host "    $(Get-Date -Format HH:mm:ss) $($st.Trim())"
} while ($st -match '^RUNNING' -and (Get-Date) -lt $deadline)
if ($st -notmatch '^OK') {
    Write-Host "  Last 40 lines of the language log:" -ForegroundColor Yellow
    Invoke-OnVm 'Get-Content C:\Windows\Temp\imagebuild-languages.log -Tail 40 -ErrorAction SilentlyContinue; Get-Content C:\Windows\Temp\customizers.log -Tail 20 -ErrorAction SilentlyContinue'
    Fail "customizers did not finish OK ($($st.Trim())). VM $VmName kept for inspection."
}
Pass "customizers finished"

Step "3. Restart and verify"
az vm restart -g $ResourceGroup -n $VmName -o none
Start-Sleep 60
$res = Invoke-OnVm @'
"LANGS: " + ((Get-InstalledLanguage).LanguageId -join ', ')
"PACKS: " + ((Get-WindowsPackage -Online | Where-Object PackageName -like 'Microsoft-Windows-Client-LanguagePack-Package*' | ForEach-Object { ($_.PackageName -split '~')[3] }) -join ', ')
"CAPS:  " + ((Get-WindowsCapability -Online | Where-Object { $_.Name -like 'Language.*' -and $_.State -eq 'Installed' }).Count) + " language capabilities installed"
"7ZIP:  " + (Test-Path 'C:\Program Files\7-Zip\7z.exe')
"TASKS: LPRemove=" + (Get-ScheduledTask -TaskName LPRemove -ErrorAction SilentlyContinue).State
'@
$text = ($res -join "`n")
$text -split "`n" | ForEach-Object { Write-Host "    $_" }
foreach ($lang in $Languages) { if ($text -notmatch [regex]::Escape($lang)) { Fail "$lang not reported as installed" } }
Pass "all requested languages present"
Write-Host ("`nDone in {0} min. VM {1} is running and NOT Sysprep'd." -f [math]::Round(((Get-Date) - $t0).TotalMinutes), $VmName)
Write-Host "Next (optional): capture it exactly like production and test on Dasv7:"
Write-Host "  .\Test-TrustedLaunchRecapture.ps1 -AdminPassword `$pw -ResourceGroup $ResourceGroup -Location $Location -ImageVersion 1.1.0 -SourceVmName $VmName -SkipExperiment"
