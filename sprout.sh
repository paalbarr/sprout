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
# 4) Start environment:
#
#      cd openclaw-stack
#      ./start.sh
#
# 5) View logs:
#
#      ./logs.sh
#
# 6) Validate health:
#
#      ./health.sh
#
# 7) Stop environment:
#
#      ./stop.sh
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
# ------------------------------------------------------------------------------
# PLATFORM PORTABILITY
# ------------------------------------------------------------------------------
#
# 1) macOS
#    - Requires Docker Desktop.
#    - Run from Terminal, iTerm or VSCode terminal.
#    - Typical path:
#
#         ~/openclaw-stack
#
#    - Port 8080 is usually available.
#    - Tailscale may also run natively if Docker networking causes issues.
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
# Relative paths:
#
#   ./openclaw-data
#   ./redis-data
#   ./tailscale
#
# are intentionally used for platform portability.
#
# Tailscale:
#
#   TS_USERSPACE=true improves compatibility across:
#     - macOS Docker Desktop
#     - WSL2
#     - Linux
#     - Raspberry Pi
#
# ==============================================================================

STACK_DIR="${STACK_DIR:-openclaw-stack}"
TZ_VALUE="${TZ_VALUE:-America/Santiago}"
OPENCLAW_PORT="${OPENCLAW_PORT:-8080}"
TS_HOSTNAME="${TS_HOSTNAME:-openclaw-docker}"

echo "[i] Creating OpenClaw Docker environment in: $STACK_DIR"

mkdir -p "$STACK_DIR"/{nginx,openclaw-data,redis-data,tailscale}
cd "$STACK_DIR"

if [[ ! -f ".env" ]]; then
  cat > .env <<EOF
# ==============================================================================
# OpenClaw Stack Environment Variables
# ==============================================================================

TZ=${TZ_VALUE}

# IF YOU WANT, CHANGE BEFORE STARTING
# YOU CAN CREATE A NEW TOKEN USING openssl rand -base64 48
OPENCLAW_GATEWAY_TOKEN=GzOVAq118GIkIVH7mgyQl/WezX0gSlpjo6C4JiUzl1MdDFtlMs2kzYcQvDdFiUVt

# CHANGE BEFORE STARTING
# YOU CAN CREATE A NEW KEY HERE https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY=tskey-auth-ksjYVR4Rub11CNTRL-gcSrcvn9UwY41rZnwL9vvYK2ZyiygWid

TS_HOSTNAME=${TS_HOSTNAME}
EOF
  echo "[✓] .env file created"
else
  echo "[i] Existing .env detected, skipping overwrite"
fi

cat > nginx/openclaw.conf <<'EOF'
# ==============================================================================
# Nginx Reverse Proxy Configuration for OpenClaw
# ------------------------------------------------------------------------------
# Portability notes:
#
# - Uses Docker Compose service names.
# - Avoids absolute paths.
# - Works across:
#     - macOS
#     - Windows WSL2
#     - Raspberry Pi
#     - Ubuntu Server
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
EOF

echo "[✓] Nginx configuration created"

cat > docker-compose.yml <<EOF
# ==============================================================================
# OpenClaw Portable Docker Compose Stack
# ------------------------------------------------------------------------------
# Designed for:
#
#   - macOS Docker Desktop
#   - Windows WSL2 + Docker Desktop
#   - Raspberry Pi OS Lite 64-bit
#   - Ubuntu Server
#
# Portability considerations:
#
# 1) Relative paths improve migration between platforms.
#
# 2) host networking is intentionally avoided because:
#      - Docker Desktop behaves differently from Linux
#      - portability would be reduced
#
# 3) Tailscale uses userspace networking for compatibility.
#
# 4) Nginx publishes configurable HTTP port.
#
# 5) ARM64 support is required for Raspberry Pi.
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

      # Allow Control UI access from any origin.
      # Useful for portable deployments across macOS, Windows, Raspberry Pi,
      # Ubuntu Server, LAN IPs and Tailscale IPs.
      gateway.bind: "lan"
      gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback: "true"
      gateway.controlUi.allowedOrigins: '["http://localhost:8080","http://127.0.0.1:8080","http://openclaw-docker:8080"]'

    volumes:
      - ./openclaw-data:/home/node/.openclaw

    depends_on:
      - redis

    expose:
      - "18789"

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
EOF

echo "[✓] docker-compose.yml created"

cat > start.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

docker compose pull
docker compose up -d
docker compose ps
EOF
chmod +x start.sh

cat > stop.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

docker compose down
EOF
chmod +x stop.sh

cat > logs.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

docker compose logs -f
EOF
chmod +x logs.sh

cat > health.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "[i] Health:"
curl -fsS http://localhost:${OPENCLAW_PORT}/healthz || true
echo

echo "[i] Readiness:"
curl -fsS http://localhost:${OPENCLAW_PORT}/readyz || true
echo
EOF
chmod +x health.sh

cat > README.txt <<EOF
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

Commands:

  ./start.sh
      Start stack

  ./stop.sh
      Stop stack

  ./logs.sh
      Follow logs

  ./health.sh
      Validate health endpoints

URLs:

  Local:
      http://localhost:${OPENCLAW_PORT}

  Health:
      http://localhost:${OPENCLAW_PORT}/healthz

  Readiness:
      http://localhost:${OPENCLAW_PORT}/readyz

Portability Notes:

  - Use WSL2 on Windows.
  - Use 64-bit OS on Raspberry Pi.
  - Use Docker Desktop on macOS.
  - Relative paths are intentionally used.
  - Tailscale runs in container mode for portability.
EOF

echo "[✓] Environment generated successfully"
echo
echo "[!] Edit:"
echo "    $STACK_DIR/.env"
echo
echo "[i] Start with:"
echo "    cd $STACK_DIR"
echo "    ./start.sh"
