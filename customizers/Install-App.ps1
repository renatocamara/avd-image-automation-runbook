<#
.SYNOPSIS
    Runs inside the Image Builder build VM. Generic app installer:
    downloads an installer from the build storage account (using the template's managed identity)
    and runs the silent install command defined in the app's manifest.
.PARAMETER StorageAccount   Storage account that holds the installers.
.PARAMETER Container        Blob container.
.PARAMETER AppName          Folder name of the app in the container (apps/<AppName>/...).
.NOTES
    Each app folder contains app.json:
    {
      "installer": "7z2409-x64.msi",
      "install":   "msiexec.exe /i \"{installer}\" /qn /norestart",
      "validate":  "C:\\Program Files\\7-Zip\\7z.exe"
    }
#>
param(
    [string]$StorageAccount = "",
    [string]$Container = "",
    [Parameter(Mandatory)] [string]$AppName,
    [string]$ManifestUrl = ""      # lab mode: public URL of app.json; installer comes from its downloadUrl
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$log = "C:\Windows\Temp\imagebuild-$AppName.log"
Start-Transcript -Path $log -Append | Out-Null

$work = "C:\Windows\Temp\apps\$AppName"
New-Item -ItemType Directory -Path $work -Force | Out-Null
if ($ManifestUrl) {
    # 1-2 (lab mode). Public manifest; installer from the vendor URL in the manifest
    $manifest = Invoke-RestMethod -Uri $ManifestUrl
    $installerPath = Join-Path $work $manifest.installer
    Write-Host "Downloading $($manifest.installer) from $($manifest.downloadUrl) ..."
    Invoke-WebRequest -Uri $manifest.downloadUrl -OutFile $installerPath -UseBasicParsing
} else {
    # 1. Get a storage token from the build VM's managed identity (IMDS)
    $token = (Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri `
        'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/').access_token
    $headers = @{ Authorization = "Bearer $token"; 'x-ms-version' = '2021-08-06' }
    $base = "https://$StorageAccount.blob.core.windows.net/$Container/apps/$AppName"
    # 2. Read the manifest and download the installer
    $manifest = Invoke-RestMethod -Uri "$base/app.json" -Headers $headers
    $installerPath = Join-Path $work $manifest.installer
    Write-Host "Downloading $($manifest.installer) ..."
    Invoke-WebRequest -Uri "$base/$($manifest.installer)" -Headers $headers -OutFile $installerPath -UseBasicParsing
}

# 3. Run the silent install
$cmd = $manifest.install -replace '\{installer\}', $installerPath
Write-Host "Running: $cmd"
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $cmd" -Wait -PassThru -NoNewWindow
Write-Host "Exit code: $($proc.ExitCode)"
if ($proc.ExitCode -notin 0, 3010) { throw "Install of $AppName failed with exit code $($proc.ExitCode)" }

# 4. Validate
if ($manifest.validate -and -not (Test-Path $manifest.validate)) { throw "Validation failed: $($manifest.validate) not found" }
Write-Host "$AppName installed successfully"

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Stop-Transcript | Out-Null
