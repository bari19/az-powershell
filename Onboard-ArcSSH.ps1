<#
.SYNOPSIS
    Installs OpenSSH, configures SSH server, and onboards the host to Azure Arc.
.DESCRIPTION
    - Automatically requests UAC elevation if not running as Administrator.
    - Installs OpenSSH Client/Server and starts sshd automatically.
    - Sets firewall rules and installs Az.Ssh modules silently without prompts.
    - Installs Azure Connected Machine Agent and launches interactive Azure authentication.
    - Configures Azure Arc incoming port 22 for hybrid SSH access.
#>

# -------------------------------------------------------------------------
# STEP 0: Elevation Check (Triggers UAC Popup If Needed)
# -------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Administrative privileges required. Requesting elevation..." -ForegroundColor Yellow
    
    $pwshExe = if ($PSVersionTable.PSVersion.Major -ge 6) { "pwsh.exe" } else { "powershell.exe" }
    $targetPath =$PSCommandPath

    # If executed in-memory or piped, write to a temp file for elevation
    if (-not $targetPath -or -not (Test-Path -Path$targetPath)) {
        $targetPath = Join-Path$env:TEMP "Onboard-ArcSSH-Temp.ps1"
        $MyInvocation.MyCommand.ScriptBlock.ToString() \vert{} Out-File -FilePath$targetPath -Encoding UTF8 -Force
    }

    try {
        Start-Process $pwshExe -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$targetPath`""
        exit 0
    } catch {
        throw "Failed to elevate permissions. Please right-click PowerShell and select 'Run as Administrator'."
    }
}

# -------------------------------------------------------------------------
# STEP 1: Enable OpenSSH Client, Server & Firewall (Silent)
# -------------------------------------------------------------------------
Write-Host "==> [1/4] Configuring OpenSSH..." -ForegroundColor Cyan

# Install OpenSSH components only if missing
$capabilities = @("OpenSSH.Client~~~~0.0.1.0", "OpenSSH.Server~~~~0.0.1.0")
foreach ($cap in$capabilities) {
    $status = (Get-WindowsCapability -Online -Name$cap -ErrorAction SilentlyContinue).State
    if ($status -ne 'Installed') {
        Write-Host "    Installing $cap..." -ForegroundColor Gray
        Add-WindowsCapability -Online -Name $cap | Out-Null
    }
}

# Configure and start SSHD service
Set-Service -Name sshd -StartupType 'Automatic'
Start-Service -Name sshd -ErrorAction SilentlyContinue

# Ensure firewall rule exists
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
                        -DisplayName 'OpenSSH Server (sshd)' `
                        -Enabled True `
                        -Direction Inbound `
                        -Protocol TCP `
                        -Action Allow `
                        -LocalPort 22 | Out-Null
    Write-Host "    OpenSSH firewall rule created." -ForegroundColor Gray
}

# -------------------------------------------------------------------------
# STEP 2: Silently Install Az.Ssh Modules
# -------------------------------------------------------------------------
Write-Host "==> [2/4] Setting up PowerShell modules (Az.Ssh)..." -ForegroundColor Cyan

# Enforce TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

# Prevent interactive prompts for NuGet and PSGallery
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
}
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue

$requiredModules = @("Az.Ssh", "Az.Ssh.ArcProxy")
foreach ($module in$requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "    Installing $module module..." -ForegroundColor Gray
        Install-Module -Name $module -Scope AllUsers -Force -AllowClobber -Confirm:$false
    }
}

# -------------------------------------------------------------------------
# STEP 3: Azure Arc Agent Download & Installation
# -------------------------------------------------------------------------
Write-Host "==> [3/4] Installing Azure Connected Machine Agent..." -ForegroundColor Cyan

$env:SUBSCRIPTION_ID = "c2fedf4e-9e7d-467a-81f9-06c587a93518"
$env:RESOURCE_GROUP  = "Veeam-Quest"
$env:TENANT_ID       = "c6f61625-ce65-46cf-af05-904669e25f4a"
$env:LOCATION        = "westus2"
$env:AUTH_TYPE       = "token"
$env:CORRELATION_ID  = "c292aa86-1f7c-43c8-ac72-2b975a920d0b"
$env:CLOUD           = "AzureCloud"

$baseProgPath = if ($env:ProgramW6432) { $env:ProgramW6432 } else {$env:ProgramFiles }
$azcmagentExe = Join-Path$baseProgPath "AzureConnectedMachineAgent\azcmagent.exe"

try {
    # Prepare working directory
    $tempPath = Join-Path$env:SystemRoot "AzureConnectedMachineAgent\temp"
    if (-not (Test-Path -Path $tempPath)) {
        New-Item -Path $tempPath -ItemType Directory -Force | Out-Null
    }

    # Download installer
    $installScriptPath = Join-Path$tempPath "install_windows_azcmagent.ps1"
    Invoke-WebRequest -UseBasicParsing -Uri "https://gbl.his.arc.azure.com/azcmagent-windows" -TimeoutSec 30 -OutFile "$installScriptPath"
    
    # Execute agent installer silently
    & "$installScriptPath"
    if ($LASTEXITCODE -ne 0) { throw "Agent installation failed with exit code $LASTEXITCODE" }
    
    Start-Sleep -Seconds 3

# -------------------------------------------------------------------------
# STEP 4: Onboard to Arc & Enable Arc SSH Port Forwarding
# -------------------------------------------------------------------------
    Write-Host "==> [4/4] Connecting to Azure Arc (Authentication required)..." -ForegroundColor Cyan
    Write-Host "    Please follow the on-screen browser/device authentication prompt." -ForegroundColor Yellow

    # azcmagent connect opens the interactive device/browser authentication
    & "$azcmagentExe" connect `
        --resource-group "$env:RESOURCE_GROUP" `
        --tenant-id "$env:TENANT_ID" `
        --location "$env:LOCATION" `
        --subscription-id "$env:SUBSCRIPTION_ID" `
        --cloud "$env:CLOUD" `
        --tags 'ArcSQLServerExtensionDeployment=Disabled' `
        --enable-automatic-upgrade `
        --correlation-id "$env:CORRELATION_ID"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "==> Enabling incoming Arc SSH traffic on port 22..." -ForegroundColor Cyan
        & "$azcmagentExe" config set incomingconnections.ports 22
        
        Write-Host "`n[SUCCESS] Host is connected to Azure Arc and ready for SSH access!" -ForegroundColor Green
    } else {
        throw "Failed to connect to Azure Arc. Exit code: $LASTEXITCODE"
    }
}
catch {
    Write-Host -ForegroundColor Red "`n[ERROR] An error occurred during onboarding: $_"
    
    # Send telemetry log to Azure Arc diagnostic endpoint
    $logBody = @{
        subscriptionId = "$env:SUBSCRIPTION_ID"
        resourceGroup  = "$env:RESOURCE_GROUP"
        tenantId       = "$env:TENANT_ID"
        location       = "$env:LOCATION"
        correlationId  = "$env:CORRELATION_ID"
        authType       = "$env:AUTH_TYPE"
        operation      = "onboarding"
        messageType    = $_.FullyQualifiedErrorId
        message        = "$_"
    }
    
    Invoke-WebRequest -UseBasicParsing `
                      -Uri "https://gbl.his.arc.azure.com/log" `
                      -Method "PUT" `
                      -Body ($logBody | ConvertTo-Json) `
                      -ErrorAction SilentlyContinue | Out-Null
}
