#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# sprout.sh
# ------------------------------------------------------------------------------
# Creates a portable Docker Compose environment for:
#
#   - OpenClaw
#   - Redis
#   - Nginx reverse proxy
#   - Tailscale container
#   - Watchtower
#
# This version includes fixes for:
#
#   Proxy headers detected from untrusted address.
#   Connection will not be treated as local.
#   Configure gateway.trustedProxies to restore local client detection behind your proxy.
#
# The fix is implemented by:
#   1) Creating an explicit OpenClaw config file: openclaw-config/openclaw.json
#   2) Configuring gateway.trustedProxies
#   3) Using a fixed Docker bridge subnet and a fixed Nginx container IP
#   4) Mounting the config file into the OpenClaw container
#   5) Sending proper proxy headers from Nginx
#
# ==============================================================================
#
# USAGE
# ------------------------------------------------------------------------------
#
# 1) Make executable:
#
#      chmod +x sprout.sh
#
# 2) Run:
#
#      ./sprout.sh
#
# 3) Edit environment variables:
#
#      nano openclaw-stack/.env
#
# 4) Review OpenClaw gateway config:
#
#      nano openclaw-stack/openclaw-config/openclaw.json
#
# 5) Start environment:
#
#      cd openclaw-stack
#      ./start.sh
#
# 6) View logs:
#
#      ./logs.sh
#
# 7) Validate health:
#
#      ./health.sh
#
# 8) If OpenClaw still reports an untrusted proxy, inspect Nginx IP:
#
#      ./inspect-nginx-ip.sh
#
#    Then add that exact IP to:
#
#      openclaw-config/openclaw.json -> gateway.trustedProxies
#
#    Restart:
#
#      ./restart.sh
#
# ------------------------------------------------------------------------------
# USAGE EXAMPLES
# ------------------------------------------------------------------------------
#
# Change published port:
#
#   OPENCLAW_PORT=8081 ./sprout.sh
#
# Change timezone:
#
#   TZ_VALUE=UTC ./sprout.sh
#
# Change stack directory:
#
#   STACK_DIR=my-openclaw ./sprout.sh
#
# Change Tailscale hostname:
#
#   TS_HOSTNAME=openclaw-rpi5 ./sprout.sh
#
# Change Docker subnet:
#
#   DOCKER_SUBNET=172.31.10.0/24 ./sprout.sh
#
# Change fixed Nginx IP:
#
#   NGINX_FIXED_IP=172.31.10.10 ./sprout.sh
#
# Add LAN and Tailscale origins:
#
#   LAN_IP=192.168.1.50 TAILSCALE_IP=100.101.102.103 ./sprout.sh
#
# ------------------------------------------------------------------------------
# PLATFORM PORTABILITY
# ------------------------------------------------------------------------------
#
# 1) macOS
#    - Requires Docker Desktop.
#    - Run from Terminal, iTerm or VS Code terminal.
#    - Typical path:
#
#         ~/openclaw-stack
#
#    - Port 8080 is usually available.
#    - Tailscale runs in container mode for portability.
#
# 2) Windows
#    - Recommended: WSL2 Ubuntu.
#    - Run this script INSIDE WSL2, not from CMD or PowerShell.
#    - Recommended path:
#
#         ~/openclaw-stack
#
#      Avoid:
#
#         /mnt/c/...
#
#      because filesystem performance and permissions may be problematic.
#
#    - Docker Desktop with WSL2 integration is required.
#
# 3) Raspberry Pi 5
#    - Requires Raspberry Pi OS Lite 64-bit.
#    - Verify:
#
#         uname -m
#
#      Expected:
#
#         aarch64
#
#    - SSD/NVMe recommended instead of microSD.
#    - Configure swap if RAM is limited.
#    - Docker images must support ARM64.
#
# 4) Ubuntu Server
#    - Requires Docker Engine + Docker Compose plugin.
#    - Recommended for lightweight production deployments.
#    - Non-root Docker user recommended.
#
# ------------------------------------------------------------------------------
# PORTABILITY VARIABLES
# ------------------------------------------------------------------------------
#
# STACK_DIR:
#   Stack installation directory.
#
# TZ_VALUE:
#   Timezone.
#
# OPENCLAW_PORT:
#   Local published HTTP port.
#
# TS_HOSTNAME:
#   Tailscale node hostname.
#
# LAN_IP:
#   Optional LAN IP included in gateway.controlUi.allowedOrigins.
#
# TAILSCALE_IP:
#   Optional Tailscale IP included in gateway.controlUi.allowedOrigins.
#
# DOCKER_NETWORK_NAME:
#   Docker bridge network name.
#
# DOCKER_SUBNET:
#   Docker bridge subnet. Change if it conflicts with your LAN/VPN.
#
# NGINX_FIXED_IP:
#   Fixed Nginx container IP. Must belong to DOCKER_SUBNET.
#   This IP is added to gateway.trustedProxies.
#
# Relative paths:
#
#   ./openclaw-data
#   ./redis-data
#   ./tailscale
#   ./openclaw-config
#
# are intentionally used for platform portability.
#
# ==============================================================================

STACK_DIR="${STACK_DIR:-openclaw-stack}"
TZ_VALUE="${TZ_VALUE:-America/Santiago}"
OPENCLAW_PORT="${OPENCLAW_PORT:-8080}"
TS_HOSTNAME="${TS_HOSTNAME:-openclaw-docker}"
LAN_IP="${LAN_IP:-192.168.1.100}"
TAILSCALE_IP="${TAILSCALE_IP:-100.x.x.x}"
DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-openclaw_net}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.30.10.0/24}"
NGINX_FIXED_IP="${NGINX_FIXED_IP:-172.30.10.10}"
OPENCLAW_FIXED_IP="${OPENCLAW_FIXED_IP:-172.30.10.20}"
REDIS_FIXED_IP="${REDIS_FIXED_IP:-172.30.10.30}"

# Placeholder token only. Replace in .env before starting.
DEFAULT_OPENCLAW_GATEWAY_TOKEN="CHANGE_THIS_LONG_SECURE_TOKEN"
DEFAULT_TS_AUTHKEY="tskey-auth-xxxxxxxxxxxxxxxx"

echo "[i] Creating OpenClaw Docker environment in: $STACK_DIR"

mkdir -p "$STACK_DIR"/{nginx,openclaw-data,redis-data,tailscale,openclaw-config}
cd "$STACK_DIR"

# ------------------------------------------------------------------------------
# .env
# ------------------------------------------------------------------------------

if [[ ! -f ".env" ]]; then
  cat > .env <<EOF_ENV
# ==============================================================================
# OpenClaw Stack Environment Variables
# ==============================================================================

TZ=${TZ_VALUE}

# CHANGE BEFORE STARTING
# Generate a new token with:
#   openssl rand -base64 48
OPENCLAW_GATEWAY_TOKEN=${DEFAULT_OPENCLAW_GATEWAY_TOKEN}

# CHANGE BEFORE STARTING
# Create a Tailscale auth key at:
#   https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY=${DEFAULT_TS_AUTHKEY}

TS_HOSTNAME=${TS_HOSTNAME}
EOF_ENV
  echo "[✓] .env file created"
else
  echo "[i] Existing .env detected, skipping overwrite"
fi

# ------------------------------------------------------------------------------
# OpenClaw explicit config: trusted proxies + allowed origins
# ------------------------------------------------------------------------------

cat > openclaw-config/openclaw.json <<EOF_JSON
{
  "gateway": {
    "bind": "lan",
    "port": 18789,

    "trustedProxies": [
      "127.0.0.1",
      "::1",
      "${NGINX_FIXED_IP}",
      "10.0.0.0/8",
      "172.16.0.0/12",
      "192.168.0.0/16"
    ],

    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true,
      "allowedOrigins": [
        "http://localhost:${OPENCLAW_PORT}",
        "http://127.0.0.1:${OPENCLAW_PORT}",
        "http://${TS_HOSTNAME}:${OPENCLAW_PORT}",
        "http://openclaw-docker:${OPENCLAW_PORT}",
        "http://${LAN_IP}:${OPENCLAW_PORT}",
        "http://${TAILSCALE_IP}:${OPENCLAW_PORT}"
      ]
    }
  }
}
EOF_JSON

echo "[✓] OpenClaw config created: openclaw-config/openclaw.json"

# ------------------------------------------------------------------------------
# Nginx reverse proxy
# ------------------------------------------------------------------------------

cat > nginx/openclaw.conf <<'EOF_NGINX'
# ==============================================================================
# Nginx Reverse Proxy Configuration for OpenClaw
# ------------------------------------------------------------------------------
# Important for OpenClaw local client detection:
#
# OpenClaw validates proxy headers. Therefore Nginx must be listed in
# gateway.trustedProxies in openclaw-config/openclaw.json.
# ==============================================================================

server {
    listen 80;
    server_name _;

    client_max_body_size 50M;

    location / {
        proxy_pass http://openclaw:18789;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;

        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /healthz {
        proxy_pass http://openclaw:18789/healthz;
    }

    location /readyz {
        proxy_pass http://openclaw:18789/readyz;
    }
}
EOF_NGINX

echo "[✓] Nginx configuration created"

# ------------------------------------------------------------------------------
# Docker Compose
# ------------------------------------------------------------------------------

cat > docker-compose.yml <<EOF_COMPOSE
# ==============================================================================
# OpenClaw Portable Docker Compose Stack
# ------------------------------------------------------------------------------
# Includes a fixed Docker bridge network so Nginx always has a known IP address.
# That IP is added to gateway.trustedProxies in openclaw-config/openclaw.json.
# ==============================================================================

services:

  redis:
    image: redis:7-alpine
    container_name: openclaw-redis
    restart: unless-stopped

    command:
      - redis-server
      - --appendonly
      - yes

    volumes:
      - ./redis-data:/data

    networks:
      openclaw_net:
        ipv4_address: ${REDIS_FIXED_IP}

  openclaw:
    image: ghcr.io/openclaw/openclaw:latest
    container_name: openclaw
    restart: unless-stopped

    env_file:
      - .env

    environment:
      TZ: \${TZ}
      OPENCLAW_GATEWAY_TOKEN: \${OPENCLAW_GATEWAY_TOKEN}
      REDIS_URL: redis://redis:6379
      HOST: 0.0.0.0
      PORT: 18789

      # These are kept as fallback environment values.
      # The canonical config is mounted from ./openclaw-config/openclaw.json.
      gateway.bind: "lan"
      gateway.trustedProxies: '["127.0.0.1","::1","${NGINX_FIXED_IP}","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"]'
      gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback: "true"
      gateway.controlUi.allowedOrigins: '["http://localhost:${OPENCLAW_PORT}","http://127.0.0.1:${OPENCLAW_PORT}","http://${TS_HOSTNAME}:${OPENCLAW_PORT}","http://openclaw-docker:${OPENCLAW_PORT}","http://${LAN_IP}:${OPENCLAW_PORT}","http://${TAILSCALE_IP}:${OPENCLAW_PORT}"]'

    volumes:
      - ./openclaw-data:/home/node/.openclaw
      - ./openclaw-config/openclaw.json:/home/node/.openclaw/openclaw.json:ro

    depends_on:
      - redis

    expose:
      - "18789"

    networks:
      openclaw_net:
        ipv4_address: ${OPENCLAW_FIXED_IP}

  nginx:
    image: nginx:alpine
    container_name: openclaw-nginx
    restart: unless-stopped

    depends_on:
      - openclaw

    volumes:
      - ./nginx/openclaw.conf:/etc/nginx/conf.d/default.conf:ro

    ports:
      - "${OPENCLAW_PORT}:80"

    networks:
      openclaw_net:
        ipv4_address: ${NGINX_FIXED_IP}

  tailscale:
    image: tailscale/tailscale:latest
    container_name: openclaw-tailscale
    restart: unless-stopped

    hostname: \${TS_HOSTNAME}

    environment:
      TS_AUTHKEY: \${TS_AUTHKEY}
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: "true"
      TS_EXTRA_ARGS: --accept-dns=false

    volumes:
      - ./tailscale:/var/lib/tailscale

    depends_on:
      - nginx

    networks:
      - openclaw_net

  watchtower:
    image: containrrr/watchtower
    container_name: openclaw-watchtower
    restart: unless-stopped

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

    command:
      - --cleanup
      - --schedule
      - "0 0 4 * * *"

    networks:
      - openclaw_net

networks:
  openclaw_net:
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

docker compose pull
docker compose up -d
docker compose ps
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
docker compose up -d
docker compose ps
EOF_RESTART
chmod +x restart.sh

cat > recreate.sh <<'EOF_RECREATE'
#!/usr/bin/env bash
set -euo pipefail

docker compose down --remove-orphans
docker compose up -d --force-recreate
docker compose ps
EOF_RECREATE
chmod +x recreate.sh

cat > logs.sh <<'EOF_LOGS'
#!/usr/bin/env bash
set -euo pipefail

docker compose logs -f
EOF_LOGS
chmod +x logs.sh

cat > logs-openclaw.sh <<'EOF_LOGS_OPENCLAW'
#!/usr/bin/env bash
set -euo pipefail

docker compose logs -f openclaw
EOF_LOGS_OPENCLAW
chmod +x logs-openclaw.sh

cat > health.sh <<EOF_HEALTH
#!/usr/bin/env bash
set -euo pipefail

echo "[i] Health:"
curl -fsS http://localhost:${OPENCLAW_PORT}/healthz || true
echo

echo "[i] Readiness:"
curl -fsS http://localhost:${OPENCLAW_PORT}/readyz || true
echo
EOF_HEALTH
chmod +x health.sh

cat > inspect-nginx-ip.sh <<'EOF_INSPECT_NGINX'
#!/usr/bin/env bash
set -euo pipefail

docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' openclaw-nginx
EOF_INSPECT_NGINX
chmod +x inspect-nginx-ip.sh

cat > verify-config.sh <<'EOF_VERIFY_CONFIG'
#!/usr/bin/env bash
set -euo pipefail

echo "[i] OpenClaw mounted config inside container:"
docker compose exec openclaw sh -lc 'ls -l /home/node/.openclaw/openclaw.json && cat /home/node/.openclaw/openclaw.json' || true

echo
echo "[i] Nginx container IP:"
docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' openclaw-nginx || true
EOF_VERIFY_CONFIG
chmod +x verify-config.sh

cat > README.txt <<EOF_README
OpenClaw Portable Docker Environment

Supported platforms:
  - macOS Docker Desktop
  - Windows WSL2 + Docker Desktop
  - Raspberry Pi OS Lite 64-bit
  - Ubuntu Server

Before starting:
  1) Edit .env
  2) Replace OPENCLAW_GATEWAY_TOKEN
  3) Replace TS_AUTHKEY with a valid Tailscale auth key
  4) Review openclaw-config/openclaw.json
  5) Adjust gateway.controlUi.allowedOrigins if needed

Commands:

  ./start.sh
      Start stack

  ./stop.sh
      Stop stack

  ./restart.sh
      Restart stack

  ./recreate.sh
      Force recreate containers

  ./logs.sh
      Follow all logs

  ./logs-openclaw.sh
      Follow OpenClaw logs only

  ./health.sh
      Validate health endpoints

  ./inspect-nginx-ip.sh
      Show Nginx container IP

  ./verify-config.sh
      Verify that openclaw.json is mounted inside the OpenClaw container

URLs:

  Local:
      http://localhost:${OPENCLAW_PORT}

  Health:
      http://localhost:${OPENCLAW_PORT}/healthz

  Readiness:
      http://localhost:${OPENCLAW_PORT}/readyz

Trusted proxy fix:

  This stack assigns Nginx a fixed Docker IP:

      ${NGINX_FIXED_IP}

  That IP is included in:

      openclaw-config/openclaw.json
      gateway.trustedProxies

  This is intended to fix:

      Proxy headers detected from untrusted address.
      Connection will not be treated as local.
      Configure gateway.trustedProxies to restore local client detection behind your proxy.

If the error persists:

  1) Check the actual Nginx container IP:

       ./inspect-nginx-ip.sh

  2) Add that IP to:

       openclaw-config/openclaw.json -> gateway.trustedProxies

  3) Force recreate:

       ./recreate.sh

Origin troubleshooting:

  Error:
      origin not allowed

  Fix:
      Add the exact browser Origin to:

        openclaw-config/openclaw.json
        gateway.controlUi.allowedOrigins

  Examples:
      http://localhost:${OPENCLAW_PORT}
      http://127.0.0.1:${OPENCLAW_PORT}
      http://192.168.1.50:${OPENCLAW_PORT}
      http://100.x.x.x:${OPENCLAW_PORT}

Network portability:

  Default Docker subnet:
      ${DOCKER_SUBNET}

  If it conflicts with your LAN/VPN, regenerate with:

      DOCKER_SUBNET=172.31.10.0/24 NGINX_FIXED_IP=172.31.10.10 OPENCLAW_FIXED_IP=172.31.10.20 REDIS_FIXED_IP=172.31.10.30 ./sprout.sh
EOF_README

echo "[✓] Environment generated successfully"
echo
echo "[!] Edit before starting:"
echo "    $STACK_DIR/.env"
echo "    $STACK_DIR/openclaw-config/openclaw.json"
echo
echo "[i] Start with:"
echo "    cd $STACK_DIR"
echo "    ./start.sh"
echo
echo "[i] If the trusted proxy error persists, run:"
echo "    ./inspect-nginx-ip.sh"
echo "    ./verify-config.sh"
