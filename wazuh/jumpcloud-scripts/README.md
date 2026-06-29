# JumpCloud Agent Deployment Scripts

These scripts install the Wazuh agent on endpoint devices via JumpCloud Commands.

## Before You Start

You need the Wazuh Manager IP. Get it by running:
```
kubectl get svc wazuh-manager-agents -n wazuh
```
Copy the EXTERNAL-IP value.

## Steps

### 1. Update the scripts
In both scripts below, replace `YOUR_WAZUH_MANAGER_IP` with the actual IP.

### 2. Deploy via JumpCloud

**For macOS devices:**
1. Go to JumpCloud → Commands → New Command
2. Command Type: `macOS`
3. Paste contents of `install-macos.sh`
4. Select all macOS devices → Run

**For Windows devices:**
1. Go to JumpCloud → Commands → New Command
2. Command Type: `Windows`
3. Paste contents of `install-windows.ps1`
4. Select all Windows devices → Run

### 3. Verify
After 5-10 minutes, check the Wazuh dashboard — devices should start appearing as connected agents.

## Troubleshooting
- If an agent doesn't show up after 10 minutes, re-run the script on that device
- Firewall must allow outbound TCP on ports 1514 and 1515 to the Wazuh Manager IP
