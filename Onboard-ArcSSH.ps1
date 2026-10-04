$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Elevating to Administrator..." -ForegroundColor Yellow
    $pwshExe = if ($PSVersionTable.PSVersion.Major -ge 6) { "pwsh.exe" } else { "powershell.exe" }
    Start-Process $pwshExe -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"C:\Onboard-ArcSSH.ps1`""
    exit 0
}

Write-Host "==> [1/4] Installing OpenSSH..." -ForegroundColor Cyan
@("OpenSSH.Client~~~~0.0.1.0", "OpenSSH.Server~~~~0.0.1.0") | ForEach-Object {
    if ((Get-WindowsCapability -Online -Name $_ -ErrorAction SilentlyContinue).State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $_ | Out-Null
    }
}
Set-Service -Name sshd -StartupType 'Automatic'
Start-Service -Name sshd -ErrorAction SilentlyContinue

if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

Write-Host "==> [2/4] Installing Az.Ssh Modules..." -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
}
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
@("Az.Ssh", "Az.Ssh.ArcProxy") | ForEach-Object {
    if (-not (Get-Module -ListAvailable -Name $_)) {
        Install-Module -Name $_ -Scope AllUsers -Force -AllowClobber -Confirm:$false
    }
}

Write-Host "==> [3/4] Installing Azure Connected Machine Agent..." -ForegroundColor Cyan
$env:SUBSCRIPTION_ID = "c2fedf4e-9e7d-467a-81f9-06c587a93518"
$env:RESOURCE_GROUP  = "Veeam-Quest"
$env:TENANT_ID       = "c6f61625-ce65-46cf-af05-904669e25f4a"
$env:LOCATION        = "westus2"
$env:AUTH_TYPE       = "token"
$env:CORRELATION_ID  = "c292aa86-1f7c-43c8-ac72-2b975a920d0b"
$env:CLOUD           = "AzureCloud"

$baseProgPath = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$azcmagentExe = Join-Path $baseProgPath "AzureConnectedMachineAgent\azcmagent.exe"

$tempPath = Join-Path $env:SystemRoot "AzureConnectedMachineAgent\temp"
if (-not (Test-Path -Path $tempPath)) { New-Item -Path $tempPath -ItemType Directory -Force | Out-Null }
$installScript = Join-Path $tempPath "install_windows_azcmagent.ps1"
Invoke-WebRequest -UseBasicParsing -Uri "https://gbl.his.arc.azure.com/azcmagent-windows" -TimeoutSec 30 -OutFile $installScript
& $installScript
if ($LASTEXITCODE -ne 0) { throw "Agent installation failed." }

Start-Sleep -Seconds 3

Write-Host "==> [4/4] Connecting to Azure Arc..." -ForegroundColor Cyan
& "$azcmagentExe" connect --resource-group "$env:RESOURCE_GROUP" --tenant-id "$env:TENANT_ID" --location "$env:LOCATION" --subscription-id "$env:SUBSCRIPTION_ID" --cloud "$env:CLOUD" --tags 'ArcSQLServerExtensionDeployment=Disabled' --enable-automatic-upgrade --correlation-id "$env:CORRELATION_ID"

if ($LASTEXITCODE -eq 0) {
    & "$azcmagentExe" config set incomingconnections.ports 22
    Write-Host "`n[SUCCESS] Host connected to Azure Arc and SSH is enabled!" -ForegroundColor Green
}
