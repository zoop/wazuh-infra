#!/bin/bash
# Zoop — Wazuh + IRIS Production Setup Script
# Run this once on a fresh Linux VM before starting docker compose

set -e

echo "=== Zoop SecOps Setup ==="

# 1. Check Docker
if ! command -v docker &> /dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker $USER
fi

if ! command -v docker compose &> /dev/null; then
  echo "Installing Docker Compose plugin..."
  sudo apt-get install -y docker-compose-plugin
fi

# 2. Set system limits for OpenSearch
echo "Setting system limits..."
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf

# 3. Create .env from example
if [ ! -f .env ]; then
  cp .env.example .env
  # Generate random secrets
  SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  SALT=$(python3 -c "import secrets; print(secrets.token_hex(16))")
  sed -i "s/change_this_to_a_random_secret/$SECRET/" .env
  sed -i "s/change_this_to_a_random_salt/$SALT/" .env
  echo "✓ .env created — edit IRIS_ADM_PASSWORD and other passwords before starting"
fi

# 4. Generate SSL certificates
echo "Generating SSL certificates..."
mkdir -p certs
cd certs

# Root CA
openssl genrsa -out root-ca-key.pem 2048
openssl req -new -x509 -sha256 -key root-ca-key.pem -out root-ca.pem -days 3650 \
  -subj "/C=US/L=California/O=Wazuh/OU=Wazuh/CN=root-ca"

cp root-ca.pem root-ca-manager.pem

# Wazuh Indexer
openssl genrsa -out wazuh-indexer-key.pem 2048
openssl req -new -key wazuh-indexer-key.pem -out wazuh-indexer.csr \
  -subj "/C=US/L=California/O=Wazuh/OU=Wazuh/CN=wazuh-indexer"
openssl x509 -req -in wazuh-indexer.csr -CA root-ca.pem -CAkey root-ca-key.pem \
  -CAcreateserial -out wazuh-indexer.pem -days 3650 -sha256
rm wazuh-indexer.csr

# Admin cert
openssl genrsa -out admin-key.pem 2048
openssl req -new -key admin-key.pem -out admin.csr \
  -subj "/C=US/L=California/O=Wazuh/OU=Wazuh/CN=admin"
openssl x509 -req -in admin.csr -CA root-ca.pem -CAkey root-ca-key.pem \
  -CAcreateserial -out admin.pem -days 3650 -sha256
rm admin.csr

# Wazuh Manager
openssl genrsa -out wazuh-manager-key.pem 2048
openssl req -new -key wazuh-manager-key.pem -out wazuh-manager.csr \
  -subj "/C=US/L=California/O=Wazuh/OU=Wazuh/CN=wazuh-manager"
openssl x509 -req -in wazuh-manager.csr -CA root-ca.pem -CAkey root-ca-key.pem \
  -CAcreateserial -out wazuh-manager.pem -days 3650 -sha256
rm wazuh-manager.csr

# Wazuh Dashboard
openssl genrsa -out wazuh-dashboard-key.pem 2048
openssl req -new -key wazuh-dashboard-key.pem -out wazuh-dashboard.csr \
  -subj "/C=US/L=California/O=Wazuh/OU=Wazuh/CN=wazuh-dashboard"
openssl x509 -req -in wazuh-dashboard.csr -CA root-ca.pem -CAkey root-ca-key.pem \
  -CAcreateserial -out wazuh-dashboard.pem -days 3650 -sha256
rm wazuh-dashboard.csr

cd ..
echo "✓ Certificates generated"

# 5. Start stack
echo "Starting Wazuh + IRIS..."
docker compose up -d

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Wazuh Dashboard : https://<your-server-ip>"
echo "  Username      : admin"
echo "  Password      : REDACTED_INDEXER_PASSWORD (change in .env)"
echo ""
echo "IRIS Dashboard  : https://<your-server-ip>:8443"
echo "  Username      : administrator"
echo "  Password      : REDACTED_IRIS_ADMIN_PASSWORD (change in .env)"
echo ""
echo "After IRIS is up, get your API key from:"
echo "  IRIS → My Profile → API Key"
echo "Then update IRIS_API_KEY in .env and restart."
