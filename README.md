# wazuh-infra

Wazuh SIEM/EDR deployment for Zoop endpoint devices.

## What This Does

Deploys Wazuh Manager on GKE and provides scripts to install Wazuh agents on all 200 endpoint devices via JumpCloud Commands.

## Stack
- **Cloud**: GCP (GKE) — matches existing Zoop infrastructure
- **Deployment**: Helm chart following Zoop's standard pattern
- **Agent Rollout**: JumpCloud Commands (push to all devices at once)
- **CI/CD**: Jenkins (matches existing Zoop pipelines)

## Folder Structure

```
wazuh/
├── helm-chart/          # Deploys Wazuh Manager on GKE
├── jumpcloud-scripts/   # Agent installer scripts for endpoints
└── pipeline/            # Jenkins pipelines (dev + prod)
```

## Deployment Steps

1. **Deploy Wazuh Manager on GKE** — follow `wazuh/helm-chart/README.md`
2. **Get the LoadBalancer IP** — this is your WAZUH_MANAGER_IP
3. **Deploy agents to endpoints** — follow `wazuh/jumpcloud-scripts/README.md`

## Contact
For questions, share this repo with your DevOps team.
