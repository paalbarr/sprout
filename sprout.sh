#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# sprout.sh  (0.5 — operational)
# ------------------------------------------------------------------------------
# Generates a portable Docker Compose stack with:
#
#   - OpenClaw    (alpine/openclaw)         — gateway + dashboard
#   - Redis       (redis:7-alpine)          — cache / state
#   - Nginx       (nginx:alpine)            — internal reverse proxy
#   - Tailscale   (tailscale/tailscale)     — single entry point to the tailnet
#
# Architecture:
#
#   tailnet ──HTTPS──► tailscale (serve) ──► nginx :80 ──► openclaw :18789
#                       └─ shares a network namespace with nginx ─┘
#
#   Dedicated Docker network with a subnet and fixed IPs. It does not depend on
#   the host IP/LAN. It is always reachable at:
#   https://<TS_HOSTNAME>.<your-tailnet>.ts.net
#
# Fixes included since the previous version:
#   1. openclaw.json includes "mode": "local" (without it, the gateway fails to start)
#   2. tailscale serve is configured through the CLI in start.sh
#      (TS_SERVE_CONFIG was removed because ${TS_CERT_DOMAIN} is not always
#       substituted in the entrypoint, causing connection refused on :443)
#   3. start.sh waits for Tailscale registration before configuring serve
#   4. .env includes placeholders for OPENAI_API_KEY / ANTHROPIC_API_KEY
#      (required because the default model is openai/gpt-5.5)
# ==============================================================================
# USAGE
# ------------------------------------------------------------------------------
#   chmod +x sprout.sh
#   ./sprout.sh
#   cd openclaw-stack
#   nano .env                       # token, auth key, provider API key
#   ./start.sh                      # starts + configures tailscale serve
#
# After the first start:
#   - Open https://<TS_HOSTNAME>.<your-tailnet>.ts.net from a device on the
#     tailnet.
#   - In the form:
#       WebSocket URL: wss://<TS_HOSTNAME>.<your-tailnet>.ts.net/
#       Gateway Token: the OPENCLAW_GATEWAY_TOKEN value from .env
#       (leave Password blank)
#   - You will be asked to approve the device. From the host terminal:
#       ./approve-device.sh <UUID-shown-by-the-dashboard>
# ==============================================================================

# -------- 0. Parameters --------
STACK_DIR="${STACK_DIR:-openclaw-stack}"
TZ_VALUE="${TZ_VALUE:-America/Santiago}"
TS_HOSTNAME="${TS_HOSTNAME:-openclaw-docker}"
DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-openclaw_net}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.30.10.0/24}"
TS_FIXED_IP="${TS_FIXED_IP:-172.30.10.10}"
OPENCLAW_FIXED_IP="${OPENCLAW_FIXED_IP:-172.30.10.20}"
REDIS_FIXED_IP="${REDIS_FIXED_IP:-172.30.10.30}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"

DEFAULT_OPENCLAW_GATEWAY_TOKEN="CHANGE_THIS_LONG_SECURE_TOKEN"
DEFAULT_TS_AUTHKEY="tskey-auth-xxxxxxxxxxxxxxxx"

echo "[i] Creating OpenClaw stack in: $STACK_DIR"

mkdir -p "$STACK_DIR"/{nginx,openclaw-data,redis-data,tailscale/state}
cd "$STACK_DIR"

# ------------------------------------------------------------------------------
# .env
# ------------------------------------------------------------------------------
if [[ ! -f ".env" ]]; then
  cat > .env <<EOF_ENV
# ==============================================================================
# OpenClaw stack — sensitive variables
# ==============================================================================

TZ=${TZ_VALUE}

# Generate your own with:
#   openssl rand -base64 48
OPENCLAW_GATEWAY_TOKEN=${DEFAULT_OPENCLAW_GATEWAY_TOKEN}

# Tailscale auth key (https://login.tailscale.com/admin/settings/keys)
# It is advisable to use a reusable tagged key (e.g. tag:docker)
# For test environments that you destroy/recreate, --ephemeral avoids orphaned nodes
TS_AUTHKEY=${DEFAULT_TS_AUTHKEY}

TS_HOSTNAME=${TS_HOSTNAME}

# --- AI provider (OpenClaw default: openai/gpt-5.5) ---
# Add at least one based on the model you intend to use.
OPENAI_API_KEY=
ANTHROPIC_API_KEY=
EOF_ENV
  echo "[✓] .env created"
else
  echo "[i] .env already exists — it will not be overwritten"
fi

# ------------------------------------------------------------------------------
# openclaw-data/openclaw.json
# ------------------------------------------------------------------------------
cat > openclaw-data/openclaw.json <<EOF_JSON
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,

    "trustedProxies": [
      "127.0.0.1",
      "::1",
      "${TS_FIXED_IP}",
      "${DOCKER_SUBNET}"
    ],

    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true,
      "allowedOrigins": [
        "http://localhost",
        "http://127.0.0.1",
        "http://${TS_HOSTNAME}",
        "https://${TS_HOSTNAME}"
      ]
    }
  }
}
EOF_JSON

echo "[✓] openclaw-data/openclaw.json created"

# ------------------------------------------------------------------------------
# nginx/openclaw.conf
# ------------------------------------------------------------------------------
cat > nginx/openclaw.conf <<'EOF_NGINX'
# ==============================================================================
# Internal reverse proxy to OpenClaw
# The "openclaw" upstream is resolved through Docker's internal DNS on openclaw_net
# (inherited from the Tailscale network namespace)
# ==============================================================================

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name _;

    client_max_body_size 50M;

    location / {
        proxy_pass http://openclaw:18789;

        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  $server_port;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /healthz { proxy_pass http://openclaw:18789/healthz; }
    location /readyz  { proxy_pass http://openclaw:18789/readyz;  }
}
EOF_NGINX

echo "[✓] nginx/openclaw.conf created"

# ------------------------------------------------------------------------------
# docker-compose.yml
# ------------------------------------------------------------------------------
cat > docker-compose.yml <<EOF_COMPOSE
# ==============================================================================
# OpenClaw stack — dedicated Docker network + Tailscale as the single entry point
# ==============================================================================

services:

  redis:
    image: redis:7-alpine
    container_name: openclaw-redis
    restart: unless-stopped

    command:
      - redis-server
      - --appendonly
      - "yes"

    volumes:
      - ./redis-data:/data

    networks:
      ${DOCKER_NETWORK_NAME}:
        ipv4_address: ${REDIS_FIXED_IP}

  openclaw:
    image: alpine/openclaw:${OPENCLAW_VERSION}
    container_name: openclaw
    restart: unless-stopped

    env_file:
      - .env

    environment:
      TZ: \${TZ}
      OPENCLAW_GATEWAY_TOKEN: \${OPENCLAW_GATEWAY_TOKEN}
      OPENAI_API_KEY: \${OPENAI_API_KEY:-}
      ANTHROPIC_API_KEY: \${ANTHROPIC_API_KEY:-}
      REDIS_URL: redis://redis:6379
      HOST: 0.0.0.0
      PORT: 18789

    volumes:
      - ./openclaw-data:/home/node/.openclaw

    depends_on:
      - redis

    expose:
      - "18789"

    networks:
      ${DOCKER_NETWORK_NAME}:
        ipv4_address: ${OPENCLAW_FIXED_IP}

  tailscale:
    image: tailscale/tailscale:latest
    container_name: openclaw-tailscale
    restart: unless-stopped

    hostname: \${TS_HOSTNAME}

    # NOTE: TS_SERVE_CONFIG is NOT used because \${TS_CERT_DOMAIN} is not always
    # substituted in the entrypoint. start.sh configures serve through the CLI.
    environment:
      TS_AUTHKEY: \${TS_AUTHKEY}
      TS_HOSTNAME: \${TS_HOSTNAME}
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: "true"
      TS_EXTRA_ARGS: "--accept-dns=false"

    volumes:
      - ./tailscale/state:/var/lib/tailscale

    depends_on:
      - openclaw

    networks:
      ${DOCKER_NETWORK_NAME}:
        ipv4_address: ${TS_FIXED_IP}

  nginx:
    image: nginx:alpine
    container_name: openclaw-nginx
    restart: unless-stopped

    # Shares Tailscale's network namespace:
    #   - listens on :80 inside that namespace
    #   - tailscale serve routes HTTPS:443 -> 127.0.0.1:80 (configured in start.sh)
    #   - resolves "openclaw" through the inherited openclaw_net DNS
    network_mode: "service:tailscale"

    volumes:
      - ./nginx/openclaw.conf:/etc/nginx/conf.d/default.conf:ro

    depends_on:
      - tailscale
      - openclaw

networks:
  ${DOCKER_NETWORK_NAME}:
    name: ${DOCKER_NETWORK_NAME}
    driver: bridge
    ipam:
      config:
        - subnet: ${DOCKER_SUBNET}
EOF_COMPOSE

echo "[✓] docker-compose.yml created"

# ------------------------------------------------------------------------------
# Helper scripts
# ------------------------------------------------------------------------------

cat > start.sh <<'EOF_START'
#!/usr/bin/env bash
set -euo pipefail

# Guardrail: do not start with placeholder tokens
if grep -qE 'CHANGE_THIS|tskey-auth-xxxx' .env; then
  echo "[error] Edit .env: OPENCLAW_GATEWAY_TOKEN and/or TS_AUTHKEY still use placeholder values." >&2
  exit 1
fi

echo "[i] Pulling images..."
docker compose pull

echo "[i] Starting stack..."
docker compose up -d

# Wait for Tailscale to register with the tailnet
echo "[i] Waiting for Tailscale registration (may take up to 30s)..."
for i in $(seq 1 30); do
  if docker compose exec -T tailscale tailscale status 2>/dev/null | grep -q "$(grep TS_HOSTNAME .env | cut -d= -f2)"; then
    echo "[✓] Tailscale registered"
    break
  fi
  sleep 2
done

# Configure tailscale serve through the CLI (automatically resolves the FQDN)
echo "[i] Configuring tailscale serve..."
docker compose exec -T tailscale tailscale serve reset 2>/dev/null || true
docker compose exec -T tailscale tailscale serve --bg --https=443 http://127.0.0.1:80

echo
echo "[i] Stack status:"
docker compose ps

echo
echo "[i] Public URL on your tailnet:"
docker compose exec -T tailscale tailscale serve status

echo
echo "[i] Next steps:"
echo "    1) Open the URL above from a device on the tailnet"
echo "    2) Connect with:"
echo "         WebSocket URL: wss://<your-fqdn>/"
echo "         Token: \$(grep OPENCLAW_GATEWAY_TOKEN .env | cut -d= -f2)"
echo "    3) Approve the device pairing:"
echo "         ./approve-device.sh <UUID-shown-by-the-dashboard>"
EOF_START
chmod +x start.sh

cat > stop.sh <<'EOF_STOP'
#!/usr/bin/env bash
set -euo pipefail
docker compose down
EOF_STOP
chmod +x stop.sh

cat > restart.sh <<'EOF_RESTART'
#!/usr/bin/env bash
set -euo pipefail
docker compose down
exec ./start.sh
EOF_RESTART
chmod +x restart.sh

cat > recreate.sh <<'EOF_RECREATE'
#!/usr/bin/env bash
set -euo pipefail
docker compose down --remove-orphans
docker compose up -d --force-recreate
exec ./start.sh
EOF_RECREATE
chmod +x recreate.sh

cat > logs.sh <<'EOF_LOGS'
#!/usr/bin/env bash
set -euo pipefail
docker compose logs -f
EOF_LOGS
chmod +x logs.sh

cat > logs-openclaw.sh <<'EOF_LOGS_OC'
#!/usr/bin/env bash
set -euo pipefail
docker compose logs -f openclaw
EOF_LOGS_OC
chmod +x logs-openclaw.sh

cat > logs-tailscale.sh <<'EOF_LOGS_TS'
#!/usr/bin/env bash
set -euo pipefail
docker compose logs -f tailscale
EOF_LOGS_TS
chmod +x logs-tailscale.sh

cat > approve-device.sh <<'EOF_APPROVE'
#!/usr/bin/env bash
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "[i] Devices pending approval:"
  docker compose exec openclaw openclaw devices list
  echo
  echo "Usage: ./approve-device.sh <uuid>"
  exit 0
fi

docker compose exec openclaw openclaw devices approve "$1"
EOF_APPROVE
chmod +x approve-device.sh

cat > inspect.sh <<'EOF_INSPECT'
#!/usr/bin/env bash
set -euo pipefail

echo "[i] Containers:"
docker compose ps
echo

echo "[i] Internal IPs:"
for c in openclaw openclaw-redis openclaw-tailscale; do
  printf "  %-22s " "$c"
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c" 2>/dev/null || echo "(not running)"
done
echo

echo "[i] Tailscale serve status:"
docker compose exec -T tailscale tailscale serve status 2>/dev/null || echo "(serve not configured)"
echo

echo "[i] Tailscale node status:"
docker compose exec -T tailscale tailscale status 2>/dev/null | head -10 || echo "(tailscale did not respond)"
EOF_INSPECT
chmod +x inspect.sh

cat > health.sh <<'EOF_HEALTH'
#!/usr/bin/env bash
set -euo pipefail

echo "[i] Health (through internal nginx):"
docker compose exec tailscale wget -qO- http://127.0.0.1:80/healthz || true
echo

echo "[i] Readiness (through internal nginx):"
docker compose exec tailscale wget -qO- http://127.0.0.1:80/readyz || true
echo
EOF_HEALTH
chmod +x health.sh

# ------------------------------------------------------------------------------
# README
# ------------------------------------------------------------------------------
cat > README.txt <<EOF_README
OpenClaw stack — end-to-end validated version

Architecture:
  tailnet --HTTPS--> tailscale (serve) --> nginx :80 --> openclaw :18789

  - Dedicated Docker network: ${DOCKER_NETWORK_NAME} (${DOCKER_SUBNET})
  - Fixed IPs: tailscale=${TS_FIXED_IP}  openclaw=${OPENCLAW_FIXED_IP}  redis=${REDIS_FIXED_IP}
  - Nginx shares Tailscale's network namespace
  - tailscale serve configured through the CLI (not through a file, avoiding
    \${TS_CERT_DOMAIN} substitution issues in the entrypoint)
  - Does not depend on the host IP/LAN

Before starting:
  1) Edit .env and replace:
       OPENCLAW_GATEWAY_TOKEN   (openssl rand -base64 48)
       TS_AUTHKEY               (https://login.tailscale.com/admin/settings/keys)
       OPENAI_API_KEY or ANTHROPIC_API_KEY (depending on the model to use)

Commands:
  ./start.sh           — pull + up + configure tailscale serve
  ./stop.sh            — stop everything
  ./restart.sh         — down + start (reconfigures tailscale serve)
  ./recreate.sh        — force-recreate all containers
  ./logs.sh            — combined logs
  ./logs-openclaw.sh   — OpenClaw logs only
  ./logs-tailscale.sh  — Tailscale logs only
  ./inspect.sh         — internal IPs + Tailscale status + serve status
  ./health.sh          — /healthz and /readyz through internal nginx
  ./approve-device.sh  — list/approve Control UI devices

First start:
  cd ${STACK_DIR}
  ./start.sh
  # copy the URL displayed at the end and open it in a tailnet browser
  # in the form: WebSocket URL = wss://<that-url-with-wss-and-a-trailing-slash>/
  # token = the value from .env
  # Connect -> you will be asked to approve device pairing:
  ./approve-device.sh <UUID>
  # Reconnect in the browser -> ready

Portability:
  - macOS / WSL2 / Raspberry Pi 64-bit / Ubuntu Server
  - Tailscale userspace mode: does not require /dev/net/tun or NET_ADMIN
  - If the ${DOCKER_SUBNET} subnet conflicts with your LAN:
      DOCKER_SUBNET=172.31.10.0/24 \\
      TS_FIXED_IP=172.31.10.10 \\
      OPENCLAW_FIXED_IP=172.31.10.20 \\
      REDIS_FIXED_IP=172.31.10.30 \\
      ./sprout.sh

Versioning:
  To pin the OpenClaw version (recommended for production):
      OPENCLAW_VERSION=v1.2.3 ./sprout.sh

Troubleshooting:
  - "Gateway start blocked: missing gateway.mode"
       openclaw-data/openclaw.json already includes "mode": "local" — this should not happen.
  - "Tailscale node name -1 suffix"
       An orphaned node with the same name exists. Delete it at
       https://login.tailscale.com/admin/machines and run ./recreate.sh
  - "WebSocket disconnected (1006)" with no activity in the logs
       Make sure to use wss:// (not ws://) and no port in the URL.
  - "Mixed Content blocked" in the browser console
       Same issue as above — wss://, not ws://
  - "Device pairing required"
       Expected for each new browser. ./approve-device.sh <UUID>
EOF_README

echo "[✓] README.txt created"
echo
echo "[✓] Stack generated in ./${STACK_DIR}"
echo
echo "[!] Before starting, edit:"
echo "    ${STACK_DIR}/.env  — OPENCLAW_GATEWAY_TOKEN, TS_AUTHKEY, provider API key"
echo
echo "[i] To start:"
echo "    cd ${STACK_DIR}"
echo "    ./start.sh"
