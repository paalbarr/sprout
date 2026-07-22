#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# sprout.sh  (0.4 — operativo)
# ------------------------------------------------------------------------------
# Genera un stack Docker Compose portable con:
#
#   - OpenClaw    (alpine/openclaw)         — gateway + dashboard
#   - Redis       (redis:7-alpine)          — caché / estado
#   - Nginx       (nginx:alpine)            — reverse proxy interno
#   - Tailscale   (tailscale/tailscale)     — único punto de ingreso al tailnet
#
# Arquitectura:
#
#   tailnet ──HTTPS──► tailscale (serve) ──► nginx :80 ──► openclaw :18789
#                       └─ comparte network namespace con nginx ─┘
#
#   Red Docker propia con subnet e IPs fijas. No depende del IP/LAN del host.
#   Se alcanza siempre en: https://<TS_HOSTNAME>.<tu-tailnet>.ts.net
#
# Fixes incorporados respecto a la versión anterior:
#   1. openclaw.json incluye "mode": "local" (sin esto el gateway no arranca)
#   2. tailscale serve se configura vía CLI dentro de start.sh
#      (eliminamos TS_SERVE_CONFIG porque ${TS_CERT_DOMAIN} no siempre
#       se sustituye en el entrypoint, causando connection refused a :443)
#   3. start.sh espera a que Tailscale registre antes de configurar serve
#   4. .env incluye placeholders para OPENAI_API_KEY / ANTHROPIC_API_KEY
#      (necesarios porque el modelo default es openai/gpt-5.5)
# ==============================================================================
# USO
# ------------------------------------------------------------------------------
#   chmod +x sprout.sh
#   ./sprout.sh
#   cd openclaw-stack
#   nano .env                       # token, auth key, API key del proveedor
#   ./start.sh                      # arranca + configura tailscale serve
#
# Después del primer arranque:
#   - Abre https://<TS_HOSTNAME>.<tu-tailnet>.ts.net desde un dispositivo
#     del tailnet
#   - En el formulario:
#       WebSocket URL: wss://<TS_HOSTNAME>.<tu-tailnet>.ts.net/
#       Gateway Token: el valor de OPENCLAW_GATEWAY_TOKEN del .env
#       (Password queda vacío)
#   - Te pedirá aprobar el dispositivo. Desde la terminal del host:
#       ./approve-device.sh <UUID-que-mostró-el-dashboard>
# ==============================================================================

# -------- 0. Parámetros --------
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

echo "[i] Creando stack OpenClaw en: $STACK_DIR"

mkdir -p "$STACK_DIR"/{nginx,openclaw-data,redis-data,tailscale/state}
cd "$STACK_DIR"

# ------------------------------------------------------------------------------
# .env
# ------------------------------------------------------------------------------
if [[ ! -f ".env" ]]; then
  cat > .env <<EOF_ENV
# ==============================================================================
# OpenClaw stack — variables sensibles
# ==============================================================================

TZ=${TZ_VALUE}

# Generar uno propio con:
#   openssl rand -base64 48
OPENCLAW_GATEWAY_TOKEN=${DEFAULT_OPENCLAW_GATEWAY_TOKEN}

# Tailscale auth key (https://login.tailscale.com/admin/settings/keys)
# Conviene usar una key reutilizable y con tag (ej. tag:docker)
# Para pruebas que destruyes/recreas, usar --ephemeral evita nodos huérfanos
TS_AUTHKEY=${DEFAULT_TS_AUTHKEY}

TS_HOSTNAME=${TS_HOSTNAME}

# --- Proveedor de IA (OpenClaw default: openai/gpt-5.5) ---
# Agrega al menos uno según el modelo que vayas a usar.
OPENAI_API_KEY=
ANTHROPIC_API_KEY=
EOF_ENV
  echo "[✓] .env creado"
else
  echo "[i] .env ya existe — no se sobreescribe"
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

echo "[✓] openclaw-data/openclaw.json creado"

# ------------------------------------------------------------------------------
# nginx/openclaw.conf
# ------------------------------------------------------------------------------
cat > nginx/openclaw.conf <<'EOF_NGINX'
# ==============================================================================
# Reverse proxy interno hacia OpenClaw
# El upstream "openclaw" se resuelve via DNS interno de Docker en openclaw_net
# (heredado del network namespace de Tailscale)
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

echo "[✓] nginx/openclaw.conf creado"

# ------------------------------------------------------------------------------
# docker-compose.yml
# ------------------------------------------------------------------------------
cat > docker-compose.yml <<EOF_COMPOSE
# ==============================================================================
# OpenClaw stack — red Docker propia + Tailscale como único punto de ingreso
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

    # NOTA: NO usamos TS_SERVE_CONFIG porque \${TS_CERT_DOMAIN} no siempre
    # se sustituye en el entrypoint. start.sh configura serve via CLI.
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

    # Comparte el network namespace de Tailscale:
    #   - escucha en :80 dentro de ese namespace
    #   - tailscale serve hace HTTPS:443 -> 127.0.0.1:80 (configurado en start.sh)
    #   - resuelve "openclaw" via el DNS de openclaw_net que hereda
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

echo "[✓] docker-compose.yml creado"

# ------------------------------------------------------------------------------
# Helper scripts
# ------------------------------------------------------------------------------

cat > start.sh <<'EOF_START'
#!/usr/bin/env bash
set -euo pipefail

# Guardrail: no arrancar con tokens placeholder
if grep -qE 'CHANGE_THIS|tskey-auth-xxxx' .env; then
  echo "[error] Edita .env: OPENCLAW_GATEWAY_TOKEN y/o TS_AUTHKEY siguen con valores placeholder." >&2
  exit 1
fi

echo "[i] Pull de imágenes..."
docker compose pull

echo "[i] Levantando stack..."
docker compose up -d

# Esperar a que tailscale registre en el tailnet
echo "[i] Esperando registro de Tailscale (puede tardar hasta 30s)..."
for i in $(seq 1 30); do
  if docker compose exec -T tailscale tailscale status 2>/dev/null | grep -q "$(grep TS_HOSTNAME .env | cut -d= -f2)"; then
    echo "[✓] Tailscale registrado"
    break
  fi
  sleep 2
done

# Configurar tailscale serve via CLI (auto-resuelve el FQDN)
echo "[i] Configurando tailscale serve..."
docker compose exec -T tailscale tailscale serve reset 2>/dev/null || true
docker compose exec -T tailscale tailscale serve --bg --https=443 http://127.0.0.1:80

echo
echo "[i] Estado del stack:"
docker compose ps

echo
echo "[i] URL pública en tu tailnet:"
docker compose exec -T tailscale tailscale serve status

echo
echo "[i] Próximos pasos:"
echo "    1) Abre la URL de arriba en un dispositivo del tailnet"
echo "    2) Conecta con:"
echo "         WebSocket URL: wss://<tu-fqdn>/"
echo "         Token: \$(grep OPENCLAW_GATEWAY_TOKEN .env | cut -d= -f2)"
echo "    3) Aprueba el device pairing:"
echo "         ./approve-device.sh <UUID-mostrado-en-dashboard>"
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
  echo "[i] Dispositivos pendientes de aprobación:"
  docker compose exec openclaw openclaw devices list
  echo
  echo "Uso: ./approve-device.sh <uuid>"
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

echo "[i] IPs internas:"
for c in openclaw openclaw-redis openclaw-tailscale; do
  printf "  %-22s " "$c"
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c" 2>/dev/null || echo "(no corriendo)"
done
echo

echo "[i] Tailscale serve status:"
docker compose exec -T tailscale tailscale serve status 2>/dev/null || echo "(serve no configurado)"
echo

echo "[i] Tailscale node status:"
docker compose exec -T tailscale tailscale status 2>/dev/null | head -10 || echo "(tailscale no respondió)"
EOF_INSPECT
chmod +x inspect.sh

cat > health.sh <<'EOF_HEALTH'
#!/usr/bin/env bash
set -euo pipefail

echo "[i] Health (vía nginx interno):"
docker compose exec tailscale wget -qO- http://127.0.0.1:80/healthz || true
echo

echo "[i] Readiness (vía nginx interno):"
docker compose exec tailscale wget -qO- http://127.0.0.1:80/readyz || true
echo
EOF_HEALTH
chmod +x health.sh

# ------------------------------------------------------------------------------
# README
# ------------------------------------------------------------------------------
cat > README.txt <<EOF_README
OpenClaw stack — versión validada end-to-end

Arquitectura:
  tailnet --HTTPS--> tailscale (serve) --> nginx :80 --> openclaw :18789

  - Red Docker propia: ${DOCKER_NETWORK_NAME} (${DOCKER_SUBNET})
  - IPs fijas: tailscale=${TS_FIXED_IP}  openclaw=${OPENCLAW_FIXED_IP}  redis=${REDIS_FIXED_IP}
  - Nginx comparte network namespace de tailscale
  - tailscale serve configurado por CLI (no por archivo, evita issue de
    sustitución de \${TS_CERT_DOMAIN} en el entrypoint)
  - No depende del IP/LAN del host

Antes de arrancar:
  1) Edita .env y reemplaza:
       OPENCLAW_GATEWAY_TOKEN   (openssl rand -base64 48)
       TS_AUTHKEY               (https://login.tailscale.com/admin/settings/keys)
       OPENAI_API_KEY o ANTHROPIC_API_KEY (según el modelo a usar)

Comandos:
  ./start.sh           — pull + up + configurar tailscale serve
  ./stop.sh            — bajar todo
  ./restart.sh         — down + start (reconfigura tailscale serve)
  ./recreate.sh        — recrear forzado todos los containers
  ./logs.sh            — logs combinados
  ./logs-openclaw.sh   — logs solo de openclaw
  ./logs-tailscale.sh  — logs solo de tailscale
  ./inspect.sh         — IPs internas + estado tailscale + serve status
  ./health.sh          — /healthz y /readyz vía nginx interno
  ./approve-device.sh  — listar/aprobar dispositivos del Control UI

Primer arranque:
  cd ${STACK_DIR}
  ./start.sh
  # copia la URL que muestra al final, abre en navegador del tailnet
  # en el formulario: WebSocket URL = wss://<esa-url-pero-con-wss-y-slash-final>/
  # token = el de .env
  # Connect -> te pedirá aprobar device pairing:
  ./approve-device.sh <UUID>
  # Reconnect en el navegador -> listo

Portabilidad:
  - macOS / WSL2 / Raspberry Pi 64-bit / Ubuntu Server
  - Userspace mode en Tailscale: no requiere /dev/net/tun ni NET_ADMIN
  - Si la subnet ${DOCKER_SUBNET} choca con tu LAN:
      DOCKER_SUBNET=172.31.10.0/24 \\
      TS_FIXED_IP=172.31.10.10 \\
      OPENCLAW_FIXED_IP=172.31.10.20 \\
      REDIS_FIXED_IP=172.31.10.30 \\
      ./sprout.sh

Versionado:
  Para fijar la versión de OpenClaw (recomendado en producción):
      OPENCLAW_VERSION=v1.2.3 ./sprout.sh

Troubleshooting:
  - "Gateway start blocked: missing gateway.mode"
       openclaw-data/openclaw.json ya incluye "mode": "local" — no debería pasar.
  - "Tailscale node name -1 suffix"
       Hay un nodo huérfano con el mismo nombre. Bórralo en
       https://login.tailscale.com/admin/machines y corre ./recreate.sh
  - "WebSocket disconnected (1006)" con logs sin actividad
       Asegúrate de usar wss:// (no ws://) y sin puerto en la URL.
  - "Mixed Content blocked" en consola del navegador
       Mismo caso anterior — wss://, no ws://
  - "Device pairing required"
       Esperado en cada navegador nuevo. ./approve-device.sh <UUID>
EOF_README

echo "[✓] README.txt creado"
echo
echo "[✓] Stack generado en ./${STACK_DIR}"
echo
echo "[!] Antes de arrancar edita:"
echo "    ${STACK_DIR}/.env  — OPENCLAW_GATEWAY_TOKEN, TS_AUTHKEY, API key del proveedor"
echo
echo "[i] Para arrancar:"
echo "    cd ${STACK_DIR}"
echo "    ./start.sh"
