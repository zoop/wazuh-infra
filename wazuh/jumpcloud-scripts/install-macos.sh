#!/bin/bash
# Wazuh Agent Installer for macOS
# Run this via JumpCloud Commands on all macOS devices

WAZUH_MANAGER_IP="YOUR_WAZUH_MANAGER_IP"
WAZUH_VERSION="4.9.2"
WAZUH_PKG="wazuh-agent-${WAZUH_VERSION}-1.arm64.pkg"
WAZUH_PKG_URL="https://packages.wazuh.com/4.x/macos/${WAZUH_PKG}"

echo "Installing Wazuh agent ${WAZUH_VERSION}..."

# Download installer
curl -s -o /tmp/${WAZUH_PKG} ${WAZUH_PKG_URL}
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to download Wazuh agent package"
  exit 1
fi

# Install
WAZUH_MANAGER="${WAZUH_MANAGER_IP}" installer -pkg /tmp/${WAZUH_PKG} -target /
if [ $? -ne 0 ]; then
  echo "ERROR: Installation failed"
  exit 1
fi

# Configure manager address
/Library/Ossec/bin/wazuh-control stop 2>/dev/null || true
sed -i '' "s|MANAGER_IP|${WAZUH_MANAGER_IP}|g" /Library/Ossec/etc/ossec.conf

# Start agent
/Library/Ossec/bin/wazuh-control start

echo "Wazuh agent installed and started successfully."
echo "Manager: ${WAZUH_MANAGER_IP}"
/Library/Ossec/bin/wazuh-control status
