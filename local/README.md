# Run Wazuh Locally

Run the full Wazuh stack on your Mac using Docker — no cloud needed.

## Requirements

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed
- Docker allocated at least **8GB RAM**
  - Docker Desktop → Settings → Resources → Memory → set to 8GB

## Steps

### 1. Clone this repo
```bash
git clone https://github.com/adinzoop/wazuh-infra.git
cd wazuh-infra/local
```

### 2. Generate SSL certificates
```bash
# Clone the official Wazuh docker repo just for cert generation
git clone https://github.com/wazuh/wazuh-docker.git /tmp/wazuh-docker
cp -r /tmp/wazuh-docker/single-node/config ./config
cp -r /tmp/wazuh-docker/single-node/generate-indexer-certs.yml ./generate-indexer-certs.yml

docker compose -f generate-indexer-certs.yml run --rm generator
```

### 3. Create your `.env` file
```bash
cp .env.example .env
# edit .env and set INDEXER_PASSWORD / API_PASSWORD
```

### 4. Start Wazuh
```bash
docker compose up -d
```

Wait about **2-3 minutes** for everything to start up.

### 5. Open the Dashboard
- URL: `https://localhost`
- Username: `admin`
- Password: value of `INDEXER_PASSWORD` in `local/.env`

> Your browser will show a security warning — that's normal for self-signed certs. Click "Advanced" → "Proceed".

## Stop Wazuh
```bash
docker compose down
```

## Stop and delete all data
```bash
docker compose down -v
```

## Test It With Your Own Mac

Install the Wazuh agent on your own MacBook to see it show up in the dashboard:

```bash
# Download and install agent
curl -s https://packages.wazuh.com/4.x/macos/wazuh-agent-4.9.2-1.arm64.pkg -o /tmp/wazuh-agent.pkg
WAZUH_MANAGER="127.0.0.1" sudo installer -pkg /tmp/wazuh-agent.pkg -target /

# Start the agent
sudo /Library/Ossec/bin/wazuh-control start
```

Your Mac should appear in the Wazuh dashboard under **Agents** within a minute.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Dashboard not loading after 3 mins | `docker compose logs wazuh-dashboard` to check errors |
| Indexer unhealthy | Increase Docker RAM to 8GB+ |
| Can't connect agent | Make sure port 1514 and 1515 are not blocked |
