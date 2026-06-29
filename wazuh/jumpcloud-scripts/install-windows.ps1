# Wazuh Agent Installer for Windows
# Run this via JumpCloud Commands on all Windows devices

$WAZUH_MANAGER_IP = "YOUR_WAZUH_MANAGER_IP"
$WAZUH_VERSION = "4.9.2"
$WAZUH_MSI = "wazuh-agent-${WAZUH_VERSION}-1.msi"
$WAZUH_URL = "https://packages.wazuh.com/4.x/windows/${WAZUH_MSI}"
$INSTALLER_PATH = "C:\Temp\${WAZUH_MSI}"

Write-Host "Installing Wazuh agent ${WAZUH_VERSION}..."

# Create temp directory
New-Item -ItemType Directory -Force -Path "C:\Temp" | Out-Null

# Download installer
Write-Host "Downloading Wazuh agent..."
Invoke-WebRequest -Uri $WAZUH_URL -OutFile $INSTALLER_PATH
if (-not (Test-Path $INSTALLER_PATH)) {
    Write-Error "ERROR: Failed to download Wazuh agent"
    exit 1
}

# Install silently with manager address
Write-Host "Installing..."
Start-Process msiexec -ArgumentList "/i `"${INSTALLER_PATH}`" /q WAZUH_MANAGER=`"${WAZUH_MANAGER_IP}`" WAZUH_REGISTRATION_SERVER=`"${WAZUH_MANAGER_IP}`"" -Wait

# Start the agent service
Write-Host "Starting Wazuh agent service..."
Start-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
Set-Service -Name "WazuhSvc" -StartupType Automatic

# Verify
$service = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
if ($service.Status -eq "Running") {
    Write-Host "Wazuh agent installed and running successfully."
    Write-Host "Manager: ${WAZUH_MANAGER_IP}"
} else {
    Write-Error "ERROR: Wazuh service is not running. Check logs at C:\Program Files (x86)\ossec-agent\ossec.log"
    exit 1
}

# Cleanup
Remove-Item $INSTALLER_PATH -Force
