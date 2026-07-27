#!/bin/sh
# ==============================================================================
# sprout.sh  (0.7 — module-aware, POSIX compliant)
# ------------------------------------------------------------------------------
# Generates a portable Docker Compose stack, plus a self-contained Module
# management system, conforming to:
#
#   SPR-001  Sprout Architecture Specification  (Core / Runtime / Module lifecycle)
#   SPR-002  Sprout Coding Standards            (POSIX.1-2024, /bin/sh only)
#   SPR-003  Sprout Architecture Model Explained (network model, layout, flow)
#
# Core services (generated unconditionally):
#
#   - OpenClaw    (alpine/openclaw)         — gateway + dashboard
#   - Redis       (redis:7-alpine)          — cache / state
#   - Nginx       (nginx:alpine)            — internal reverse proxy
#   - Tailscale   (tailscale/tailscale)     — single entry point to the tailnet
#
# Bootstrap Module (provisioned automatically on first ./start.sh, through the
# same lifecycle any future module uses — see SPR-001 §8.3):
#
#   - Ollama      (ollama/ollama)           — local inference runtime
#     └─ TinyLlama pulled automatically as the default bootstrap model
#
# Architecture:
#
#   tailnet ──HTTPS──► tailscale (serve) ──► nginx :80 ──► openclaw :18789
#                       └─ shares a network namespace with nginx ─┘
#
#   openclaw ──HTTP──► ollama :11434  (internal Docker network only, no host port)
#
#   Dedicated Docker network with a subnet and fixed IPs. It does not depend on
#   the host IP/LAN. It is always reachable at:
#   https://<TS_HOSTNAME>.<your-tailnet>.ts.net
#
# Module management (new in 0.7):
#
#   Every capability beyond the core stack is delivered as a Module, following
#   the Resolve -> Install -> Configure -> Provision -> Register -> Validate
#   -> READY lifecycle defined in SPR-001 §8.3/§9. Modules are never
#   provisioned by hand; they are always driven through the generated
#   `./sprout` CLI:
#
#       ./sprout install <module>     # run the full lifecycle for <module>
#       ./sprout remove  <module>     # stop and deregister <module>
#       ./sprout list                 # show available / installed modules
#       ./sprout status  [module]     # show Runtime / module state
#       ./sprout doctor                # re-validate every READY module
#
#   The stack ships with one bundled module (ollama) acting as the reference
#   implementation and as the official Bootstrap Module. Additional modules
#   can be added by creating a `modules/<name>/` directory that follows the
#   same manifest + lifecycle-script contract (see modules/ollama/ for the
#   canonical example).
#
# POSIX compliance (SPR-002):
#
#   - Every generated script uses #!/bin/sh and `set -eu` (POSIX has no
#     `pipefail`; pipelines that must fail loudly check $? explicitly).
#   - No bash arrays, no [[ ]], no (( )), no `local`, no brace expansion,
#     no `function` keyword, no backtick command substitution.
#   - Command substitution: $(...). Variable expansion: always quoted.
#   - Logging follows the "[LEVEL] [COMPONENT] Message." format from SPR-002
#     §16 in every generated script, including this generator.
# ==============================================================================
# USAGE
# ------------------------------------------------------------------------------
#   chmod +x sprout.sh
#   ./sprout.sh
#   cd openclaw-stack
#   nano .env                       # token, auth key, provider API key
#   ./start.sh                      # starts core stack + auto-provisions ollama
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
#
# Module management, once the stack is running:
#   ./sprout list                   # ollama [READY]  (bootstrapped automatically)
#   ./sprout status ollama
#   ./sprout doctor
# ==============================================================================
set -eu

# -------- 0. Logging (SPR-002 §16 — "[LEVEL] [COMPONENT] Message.") --------
log_info() { printf '[INFO]  [Sprout] %s\n' "$1"; }
log_warn() { printf '[WARN]  [Sprout] %s\n' "$1" >&2; }
log_error() { printf '[ERROR] [Sprout] %s\n' "$1" >&2; }
log_fatal() {
  printf '[FATAL] [Sprout] %s\n' "$1" >&2
  exit 1
}

# -------- 1. Parameters --------
STACK_DIR="${STACK_DIR:-openclaw-stack}"
TZ_VALUE="${TZ_VALUE:-America/Santiago}"
TS_HOSTNAME="${TS_HOSTNAME:-openclaw-docker}"
DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-openclaw_net}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.30.10.0/24}"
TS_FIXED_IP="${TS_FIXED_IP:-172.30.10.10}"
OPENCLAW_FIXED_IP="${OPENCLAW_FIXED_IP:-172.30.10.20}"
REDIS_FIXED_IP="${REDIS_FIXED_IP:-172.30.10.30}"
OLLAMA_FIXED_IP="${OLLAMA_FIXED_IP:-172.30.10.40}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
OLLAMA_VERSION="${OLLAMA_VERSION:-latest}"
OLLAMA_DEFAULT_MODEL="${OLLAMA_DEFAULT_MODEL:-tinyllama}"

DEFAULT_TS_AUTHKEY="tskey-auth-xxxxxxxxxxxxxxxx"

# generate_secret <byte_count>
# Prefers `openssl rand -base64`; falls back to a pure-POSIX /dev/urandom
# read (dd + od, both POSIX utilities) when openssl is not installed. As a
# last resort (no openssl, no /dev/urandom) derives a low-entropy value from
# time/pid and warns loudly, since that path is NOT cryptographically safe.
generate_secret() {
  byte_count="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "${byte_count}" | tr -d '\n'
    return 0
  fi
  if [ -r /dev/urandom ]; then
    dd if=/dev/urandom bs="${byte_count}" count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n'
    return 0
  fi
  log_warn "openssl and /dev/urandom are both unavailable — falling back to a low-entropy token. Replace OPENCLAW_GATEWAY_TOKEN by hand before exposing this stack."
  weak_seed="$(date +%s 2>/dev/null)$$$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "sprout-fallback")"
  printf '%s' "${weak_seed}" | cksum | tr -d ' \n'
}

log_info "Creating OpenClaw stack in: ${STACK_DIR}"

mkdir -p "${STACK_DIR}/nginx"
mkdir -p "${STACK_DIR}/openclaw-data"
mkdir -p "${STACK_DIR}/redis-data"
mkdir -p "${STACK_DIR}/tailscale/state"
mkdir -p "${STACK_DIR}/state"
mkdir -p "${STACK_DIR}/modules/ollama/data"
cd "${STACK_DIR}"

# ------------------------------------------------------------------------------
# .env
# ------------------------------------------------------------------------------
if [ ! -f ".env" ]; then
  log_info "Generating OPENCLAW_GATEWAY_TOKEN..."
  generated_gateway_token="$(generate_secret 48)"

  cat > .env <<EOF_ENV
# ==============================================================================
# OpenClaw stack — sensitive variables
# ==============================================================================

TZ=${TZ_VALUE}

# Auto-generated at stack creation (openssl rand -base64 48, or a POSIX
# /dev/urandom fallback — see generate_secret() in sprout.sh). Rotate with:
#   openssl rand -base64 48
OPENCLAW_GATEWAY_TOKEN=${generated_gateway_token}

# Tailscale auth key (https://login.tailscale.com/admin/settings/keys)
# Left as a placeholder on purpose: ./start.sh asks for it interactively on
# first run (hidden input), writes it here, and retries until Tailscale
# registers. A reusable tagged key (e.g. tag:docker) is recommended so
# ./recreate.sh does not burn a fresh single-use key every time.
TS_AUTHKEY=${DEFAULT_TS_AUTHKEY}

TS_HOSTNAME=${TS_HOSTNAME}

# --- AI provider (OpenClaw default: openai/gpt-5.5) ---
# Add at least one based on the model you intend to use. The bootstrap module
# (ollama + tinyllama) is provisioned automatically and needs no key.
OPENAI_API_KEY=
ANTHROPIC_API_KEY=

# --- Bootstrap module (ollama) ---
# OLLAMA_HOST is the standard variable name Ollama clients (including the
# openclaw CLI's --auth-choice ollama) read to find the server. Keep
# OLLAMA_BASE_URL too — same value — for our own scripts/logging.
OLLAMA_HOST=http://ollama:11434
OLLAMA_BASE_URL=http://ollama:11434
OLLAMA_DEFAULT_MODEL=${OLLAMA_DEFAULT_MODEL}
EOF_ENV
  log_info ".env created"
else
  log_info ".env already exists — it will not be overwritten"
fi

# ------------------------------------------------------------------------------
# openclaw-data/openclaw.json
# ------------------------------------------------------------------------------
# Only created if missing: OpenClaw itself owns this file after first start
# (gateway.*, models, tools, etc. all get written here by `openclaw onboard`/
# `openclaw config set`/hot reload). Re-running ./sprout.sh must NEVER
# clobber a live config — that includes provider registrations like Ollama.
if [ ! -f "openclaw-data/openclaw.json" ]; then
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
  log_info "openclaw-data/openclaw.json created"
else
  log_info "openclaw-data/openclaw.json already exists — it will not be overwritten"
fi

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

log_info "nginx/openclaw.conf created"

# ------------------------------------------------------------------------------
# docker-compose.yml (Core — Runtime infrastructure, never module-specific)
# ------------------------------------------------------------------------------
cat > docker-compose.yml <<EOF_COMPOSE
# ==============================================================================
# OpenClaw stack — dedicated Docker network + Tailscale as the single entry point
# Core services only. Module services live in docker-compose.modules.yml and are
# merged in by ./sprout and ./start.sh (docker compose -f ... -f ...).
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
      OLLAMA_HOST: \${OLLAMA_HOST:-}
      OLLAMA_BASE_URL: \${OLLAMA_BASE_URL:-}
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

log_info "docker-compose.yml created"

# ------------------------------------------------------------------------------
# docker-compose.modules.yml — assembled from installed modules' service
# fragments (modules/<name>/compose.yml). Starts as an empty overlay; ./sprout
# install/remove regenerate it. Never edited by hand.
# ------------------------------------------------------------------------------
cat > docker-compose.modules.yml <<'EOF_MODULES_COMPOSE'
# ==============================================================================
# Generated overlay — DO NOT EDIT BY HAND.
# Regenerated by ./sprout on every `install` / `remove`. One service block per
# READY or provisioning module, sourced from modules/<name>/compose.yml.
# ==============================================================================
services: {}
EOF_MODULES_COMPOSE

log_info "docker-compose.modules.yml created (empty overlay)"

# ------------------------------------------------------------------------------
# state/runtime.yaml, state/modules.yaml — Runtime is the source of truth
# (SPR-001 §6.2, §9). Owned exclusively by ./sprout; nothing else writes here.
# ------------------------------------------------------------------------------
cat > state/runtime.yaml <<EOF_RUNTIME
status: NEW
core_status: READY
bootstrap_module: ollama
bootstrap_status: PENDING
EOF_RUNTIME

cat > state/modules.yaml <<'EOF_MODULES_STATE'
modules:
EOF_MODULES_STATE

log_info "state/runtime.yaml and state/modules.yaml created"

# ------------------------------------------------------------------------------
# modules/ollama — bundled reference module and official Bootstrap Module
# (SPR-001 §2.5, §8.3): installs Ollama, pulls TinyLlama, registers the local
# provider. Provisioned through the exact same lifecycle as any future module.
# ------------------------------------------------------------------------------
cat > modules/ollama/module.yaml <<EOF_OLLAMA_MANIFEST
name: ollama
version: 1.0.0
description: Local inference runtime (Ollama) with automatic TinyLlama bootstrap model.
author: Sprout Contributors
repository: https://github.com/ollama/ollama
depends:
provides: local-inference
bootstrap: true
default_model: ${OLLAMA_DEFAULT_MODEL}
healthcheck: http://ollama:11434/api/tags
EOF_OLLAMA_MANIFEST

# Service fragment merged into docker-compose.modules.yml by ./sprout.
# Kept isolated on the same Docker network, no host port published — reachable
# by openclaw only, at http://ollama:11434 (matches OLLAMA_BASE_URL in .env).
cat > modules/ollama/compose.yml <<EOF_OLLAMA_COMPOSE
  ollama:
    image: ollama/ollama:${OLLAMA_VERSION}
    container_name: openclaw-ollama
    restart: unless-stopped

    volumes:
      - ./modules/ollama/data:/root/.ollama

    expose:
      - "11434"

    networks:
      ${DOCKER_NETWORK_NAME}:
        ipv4_address: ${OLLAMA_FIXED_IP}
EOF_OLLAMA_COMPOSE

cat > modules/ollama/module.sh <<'EOF_OLLAMA_MODULE'
#!/bin/sh
# ==============================================================================
# modules/ollama/module.sh — lifecycle implementation for the "ollama" module.
# Sourced by ./sprout; never executed directly (SPR-001 §8.3).
# Implements: module_install, module_configure, module_provision,
#             module_register, module_validate, module_remove
# ==============================================================================
set -eu

OLLAMA_SERVICE="ollama"

# env_value <KEY> — reads KEY=value from .env (first match, empty if absent).
# Read directly rather than relying on exported shell vars, since ./sprout
# does not (and should not) export the contents of .env into its own process.
env_value() {
  sed -n "s/^$1=//p" .env | head -n 1
}

ollama_model() {
  value="$(env_value OLLAMA_DEFAULT_MODEL)"
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "tinyllama"
  fi
}

ollama_base_url() {
  value="$(env_value OLLAMA_BASE_URL)"
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "http://ollama:11434"
  fi
}

openclaw_is_healthy() {
  # Uses openclaw's own CLI ('openclaw health' — confirmed in `openclaw --help`)
  # instead of wget: the openclaw image is Node-based and does not
  # necessarily ship wget/curl, unlike the Alpine-based tailscale/nginx
  # images used elsewhere in this stack.
  compose_cmd exec -T openclaw openclaw health >/dev/null 2>&1
}

wait_openclaw_healthy() {
  # $1 = max attempts (2s apart)
  max_attempts="$1"
  attempt=1
  while [ "${attempt}" -le "${max_attempts}" ]; do
    if openclaw_is_healthy; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

# openclaw_config_get <path> — runs `openclaw config get <path>` and returns
# just the value: CLI output includes a banner line + blank line before it,
# so this keeps the last non-blank line of output.
openclaw_config_get() {
  compose_cmd exec -T openclaw openclaw config get "$1" 2>/dev/null | tr -d '\r' | awk 'NF{last=$0} END{print last}'
}

module_install() {
  log_info "[ollama] Pulling image..."
  compose_cmd pull "${OLLAMA_SERVICE}"
}

module_configure() {
  log_info "[ollama] Ensuring persistent data directory exists..."
  mkdir -p modules/ollama/data
}

module_provision() {
  ollama_model_name="$(ollama_model)"

  log_info "[ollama] Starting container..."
  compose_cmd up -d "${OLLAMA_SERVICE}"

  log_info "[ollama] Waiting for the API to become available..."
  attempt=1
  while [ "${attempt}" -le 30 ]; do
    if compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  if [ "${attempt}" -gt 30 ]; then
    log_error "[ollama] API did not become available in time."
    return 1
  fi

  log_info "[ollama] Pulling default model: ${ollama_model_name}"
  compose_cmd exec -T "${OLLAMA_SERVICE}" ollama pull "${ollama_model_name}"
}

# Register (SPR-001 §8.3/§8.4): "For AI inference modules, Register SHALL
# automatically create or update the corresponding OpenClaw provider
# configuration." A Bootstrap Module must not reach READY until this
# succeeds — invoked between Provision and Validate.
#
# This exact sequence was confirmed by hand against a running stack before
# being wired in here — each step exists because of a real failure mode:
#
#   1. `openclaw onboard --auth-choice ollama` looks like the obvious choice
#      (ollama is a listed --auth-choice), but its own Ollama-reachability
#      check ignores OLLAMA_HOST/-e env vars and always probes 127.0.0.1, so
#      it fails before writing anything — regardless of how OLLAMA_HOST is
#      set. `--auth-choice custom-api-key` with an explicit `--custom-base-url`
#      is the path that actually reaches Ollama and writes the provider config.
#   2. `--flow quickstart` forces `gateway.bind` to "loopback" as a side
#      effect, which breaks nginx/Tailscale access to the dashboard. Must be
#      restored to "lan" right after onboard.
#   3. TinyLlama (and small local models generally) reject ANY request that
#      includes a tools/function-calling schema with a 400. `tools.profile:
#      "minimal"` alone is not enough — it still includes `session_status`,
#      which is enough to trigger the rejection. `deny: ["*"]` on top of it
#      is what actually gets to zero tools. Scoped to `tools.byProvider` for
#      this model only, so every other provider/model keeps the global
#      `tools.profile` ("coding") untouched.
#   4. A full container restart is required at the end: `tools.*` is
#      documented as hot-reloadable, but an already-open Gateway session
#      kept using the old tool policy until openclaw was restarted.
module_register() {
  base_url="$(ollama_base_url)"
  ollama_model_name="$(ollama_model)"

  if ! openclaw_is_healthy; then
    log_warn "[ollama] openclaw is unhealthy — restarting once before continuing."
    compose_cmd restart openclaw
    wait_openclaw_healthy 30 || {
      log_error "[ollama] openclaw is still unhealthy after a restart."
      compose_cmd logs --tail 30 openclaw 2>&1 || true
      return 1
    }
    log_info "[ollama] openclaw recovered."
  fi

  log_info "[ollama] Registering Ollama with OpenClaw (openclaw onboard --auth-choice custom-api-key)..."
  onboard_out="onboard_result.json"
  onboard_err="onboard_err.log"
  if ! compose_cmd exec -T openclaw openclaw onboard \
      --non-interactive \
      --accept-risk \
      --auth-choice custom-api-key \
      --custom-provider-id ollama \
      --custom-base-url "${base_url}/v1" \
      --custom-model-id "${ollama_model_name}" \
      --custom-compatibility openai \
      --flow quickstart \
      --skip-channels \
      --skip-skills \
      --skip-ui \
      --skip-hooks \
      --skip-search \
      --skip-health \
      --no-install-daemon \
      --json > "${onboard_out}" 2> "${onboard_err}"; then
    log_error "[ollama] openclaw onboard failed:"
    cat "${onboard_err}" >&2 2>/dev/null || true
    cat "${onboard_out}" >&2 2>/dev/null || true
    rm -f "${onboard_out}" "${onboard_err}"
    return 1
  fi
  rm -f "${onboard_out}" "${onboard_err}"
  log_info "[ollama] onboard completed."

  log_info "[ollama] Restoring gateway.bind=lan (onboard's quickstart flow forces loopback)..."
  if ! compose_cmd exec -T openclaw openclaw config set gateway.bind lan >/dev/null 2>&1; then
    log_error "[ollama] Failed to restore gateway.bind=lan."
    return 1
  fi

  log_info "[ollama] Disabling tool-calling for ollama/${ollama_model_name} (unsupported by this model)..."
  if ! compose_cmd exec -T openclaw openclaw config set tools.byProvider \
      "{\"ollama/${ollama_model_name}\":{\"profile\":\"minimal\",\"deny\":[\"*\"]}}" \
      --strict-json --merge >/dev/null 2>&1; then
    log_error "[ollama] Failed to set tools.byProvider for ollama/${ollama_model_name}."
    return 1
  fi

  log_info "[ollama] Restarting openclaw to apply gateway.bind + tools.byProvider..."
  compose_cmd restart openclaw
  wait_openclaw_healthy 30 || {
    log_error "[ollama] openclaw did not come back up after restart."
    compose_cmd logs --tail 30 openclaw 2>&1 || true
    return 1
  }
  log_info "[ollama] openclaw registered and healthy."
}

module_validate() {
  ollama_model_name="$(ollama_model)"

  log_info "[ollama] Validating model availability..."
  if ! compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list 2>/dev/null | grep -q "${ollama_model_name}"; then
    log_error "[ollama] ${ollama_model_name} not found after provisioning."
    return 1
  fi
  log_info "[ollama] ${ollama_model_name} is available in Ollama."

  log_info "[ollama] Validating openclaw is healthy..."
  if ! openclaw_is_healthy; then
    log_error "[ollama] openclaw is not healthy."
    return 1
  fi

  log_info "[ollama] Validating gateway.bind was not left on loopback..."
  gw_bind="$(openclaw_config_get gateway.bind)"
  if [ "${gw_bind}" != "lan" ]; then
    log_error "[ollama] gateway.bind is '${gw_bind}', expected 'lan' — nginx/Tailscale access would be broken."
    return 1
  fi

  log_info "[ollama] Checking openclaw's registered model..."
  if compose_cmd exec -T openclaw openclaw models status 2>/dev/null | grep -qi "ollama/${ollama_model_name}"; then
    log_info "[ollama] openclaw reports ollama/${ollama_model_name} as configured."
  else
    log_warn "[ollama] Could not confirm ollama/${ollama_model_name} in 'openclaw models status' output — check manually with: docker compose exec openclaw openclaw models status"
  fi

  return 0
}

module_remove() {
  log_info "[ollama] Stopping and removing container..."
  compose_cmd rm -sf "${OLLAMA_SERVICE}" || true
  log_warn "[ollama] modules/ollama/data was preserved. Delete it manually to reset the model cache."
}
EOF_OLLAMA_MODULE
chmod +x modules/ollama/module.sh

log_info "modules/ollama (module.yaml, compose.yml, module.sh) created"

# ------------------------------------------------------------------------------
# sprout — Module management CLI (Core's Module Manager, SPR-001 §5.1/§9)
# ------------------------------------------------------------------------------
cat > sprout <<'EOF_SPROUT_CLI'
#!/bin/sh
# ==============================================================================
# sprout — Module management CLI
# Every capability lifecycle operation (Resolve -> Install -> Configure ->
# Provision -> Register -> Validate, SPR-001 §8.3/§9) goes through this
# entrypoint. Modules are never invoked directly by the user.
# ==============================================================================
set -eu

RUNTIME_FILE="state/runtime.yaml"
MODULES_STATE_FILE="state/modules.yaml"
MODULES_DIR="modules"
COMPOSE_BASE="docker-compose.yml"
COMPOSE_MODULES="docker-compose.modules.yml"

log_info() { printf '[INFO]  [Core] %s\n' "$1"; }
log_warn() { printf '[WARN]  [Core] %s\n' "$1" >&2; }
log_error() { printf '[ERROR] [Core] %s\n' "$1" >&2; }
log_fatal() {
  printf '[FATAL] [Core] %s\n' "$1" >&2
  exit 1
}

compose_cmd() {
  docker compose -f "${COMPOSE_BASE}" -f "${COMPOSE_MODULES}" "$@"
}

usage() {
  cat <<'EOF_USAGE'
Usage: ./sprout <command> [module]

Commands:
  install <module>   Run the full lifecycle for <module> and register it READY
  remove  <module>    Stop <module> and remove it from the Runtime
  list                List available modules and their current status
  status  [module]    Show Runtime status, or a single module's status
  doctor              Re-validate every READY module
EOF_USAGE
}

# -------- state/modules.yaml helpers (flow-style YAML, one line per module) --------

module_state_line() {
  # $1 = module name
  grep -F "name: $1," "${MODULES_STATE_FILE}" 2>/dev/null || true
}

module_state_status() {
  # $1 = module name -- prints status or "NOT_INSTALLED"
  line=$(module_state_line "$1")
  if [ -z "${line}" ]; then
    echo "NOT_INSTALLED"
    return 0
  fi
  echo "${line}" | sed -n 's/.*status: \([A-Z_]*\).*/\1/p'
}

module_state_set() {
  # $1 = name, $2 = version, $3 = status
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  entry="  - {name: $1, version: $2, status: $3, updated: \"${timestamp}\"}"

  if [ ! -f "${MODULES_STATE_FILE}" ]; then
    echo "modules:" > "${MODULES_STATE_FILE}"
  fi

  # Rebuild the file without the previous entry for this module, then append.
  tmp_file="${MODULES_STATE_FILE}.tmp"
  grep -v -F "name: $1," "${MODULES_STATE_FILE}" > "${tmp_file}" 2>/dev/null || true
  if ! grep -q '^modules:' "${tmp_file}" 2>/dev/null; then
    printf 'modules:\n' > "${tmp_file}"
  fi
  mv "${tmp_file}" "${MODULES_STATE_FILE}"
  echo "${entry}" >> "${MODULES_STATE_FILE}"
}

module_state_remove() {
  # $1 = module name
  tmp_file="${MODULES_STATE_FILE}.tmp"
  grep -v -F "name: $1," "${MODULES_STATE_FILE}" > "${tmp_file}" 2>/dev/null || true
  mv "${tmp_file}" "${MODULES_STATE_FILE}"
}

runtime_set_bootstrap_status() {
  # $1 = status
  tmp_file="${RUNTIME_FILE}.tmp"
  sed "s/^bootstrap_status:.*/bootstrap_status: $1/" "${RUNTIME_FILE}" > "${tmp_file}"
  mv "${tmp_file}" "${RUNTIME_FILE}"
}

# -------- docker-compose.modules.yml assembly --------

regenerate_modules_compose() {
  echo "services:" > "${COMPOSE_MODULES}.new"
  wrote_any="no"
  for module_dir in "${MODULES_DIR}"/*/; do
    module="$(basename "${module_dir}")"
    status="$(module_state_status "${module}")"
    # Include the module's service block for every state except
    # NOT_INSTALLED (no state entry at all). This covers the whole active
    # lifecycle (RESOLVING..READY) so `docker compose pull/up` can find the
    # service as soon as install() needs it, and also keeps FAILED modules
    # visible for retry/debugging until an explicit `remove` drops them.
    if [ "${status}" != "NOT_INSTALLED" ]; then
      if [ -f "${MODULES_DIR}/${module}/compose.yml" ]; then
        cat "${MODULES_DIR}/${module}/compose.yml" >> "${COMPOSE_MODULES}.new"
        wrote_any="yes"
      fi
    fi
  done
  if [ "${wrote_any}" = "no" ]; then
    echo "services: {}" > "${COMPOSE_MODULES}.new"
  fi
  mv "${COMPOSE_MODULES}.new" "${COMPOSE_MODULES}"
}

# -------- manifest helpers --------

manifest_field() {
  # $1 = module, $2 = field
  sed -n "s/^$2: \(.*\)$/\1/p" "${MODULES_DIR}/$1/module.yaml" | head -n 1
}

# -------- commands --------

cmd_install() {
  module="${1:-}"
  [ -n "${module}" ] || log_fatal "Usage: ./sprout install <module>"
  [ -d "${MODULES_DIR}/${module}" ] || log_fatal "Module not found in local Garden cache: ${module}"
  [ -f "${MODULES_DIR}/${module}/module.yaml" ] || log_fatal "Missing manifest: ${MODULES_DIR}/${module}/module.yaml"
  [ -f "${MODULES_DIR}/${module}/module.sh" ] || log_fatal "Missing lifecycle script: ${MODULES_DIR}/${module}/module.sh"

  current_status="$(module_state_status "${module}")"
  if [ "${current_status}" = "READY" ]; then
    log_info "${module} is already READY. Nothing to do."
    return 0
  fi

  version="$(manifest_field "${module}" version)"
  [ -n "${version}" ] || version="0.0.0"

  log_info "Resolving ${module}..."
  module_state_set "${module}" "${version}" "RESOLVING"

  # Clear any lifecycle functions left over from a previously sourced module
  # in this same invocation, so a module that doesn't define module_register
  # (optional hook) can't accidentally inherit one from another module.
  unset -f module_install module_configure module_provision module_register module_validate module_remove 2>/dev/null || true

  # shellcheck disable=SC1090
  . "${MODULES_DIR}/${module}/module.sh"

  log_info "Installing ${module}..."
  module_state_set "${module}" "${version}" "INSTALLING"
  regenerate_modules_compose
  module_install || {
    module_state_set "${module}" "${version}" "FAILED"
    log_fatal "${module}: install phase failed."
  }

  log_info "Configuring ${module}..."
  module_state_set "${module}" "${version}" "CONFIGURING"
  module_configure || {
    module_state_set "${module}" "${version}" "FAILED"
    log_fatal "${module}: configure phase failed."
  }

  log_info "Provisioning ${module}..."
  module_state_set "${module}" "${version}" "PROVISIONING"
  regenerate_modules_compose
  module_provision || {
    module_state_set "${module}" "${version}" "FAILED"
    log_fatal "${module}: provisioning phase failed."
  }

  # Register (SPR-001 §8.3/§8.4): integrates the capability into consumer
  # components — for AI inference modules this MUST create/update the
  # corresponding OpenClaw provider configuration. Optional hook for modules
  # that have nothing to register (e.g. a plain database with no OpenClaw
  # integration point); mandatory in practice for AI-inference modules.
  if command -v module_register >/dev/null 2>&1; then
    log_info "Registering ${module} capability with dependent components..."
    module_state_set "${module}" "${version}" "REGISTERING"
    module_register || {
      module_state_set "${module}" "${version}" "FAILED"
      log_fatal "${module}: register phase failed. ${module} was NOT marked READY."
    }
  else
    log_info "${module} defines no module_register hook — nothing to integrate."
  fi

  log_info "Validating ${module}..."
  module_state_set "${module}" "${version}" "VALIDATING"
  module_validate || {
    module_state_set "${module}" "${version}" "FAILED"
    log_fatal "${module}: validation failed. ${module} was NOT registered as READY."
  }

  log_info "Recording ${module} in the Runtime as READY..."
  module_state_set "${module}" "${version}" "READY"
  regenerate_modules_compose

  if [ "${module}" = "$(sed -n 's/^bootstrap_module: \(.*\)$/\1/p' "${RUNTIME_FILE}")" ]; then
    runtime_set_bootstrap_status "READY"
  fi

  log_info "${module} is READY."
}

cmd_remove() {
  module="${1:-}"
  [ -n "${module}" ] || log_fatal "Usage: ./sprout remove <module>"
  status="$(module_state_status "${module}")"
  if [ "${status}" = "NOT_INSTALLED" ]; then
    log_info "${module} is not installed."
    return 0
  fi

  unset -f module_install module_configure module_provision module_register module_validate module_remove 2>/dev/null || true
  # shellcheck disable=SC1090
  . "${MODULES_DIR}/${module}/module.sh"
  log_info "Removing ${module}..."
  module_remove || log_warn "${module}: remove phase reported an error (continuing)."

  module_state_remove "${module}"
  regenerate_modules_compose
  log_info "${module} removed from the Runtime."
}

cmd_list() {
  printf '%-16s %-10s %s\n' "MODULE" "VERSION" "STATUS"
  for module_dir in "${MODULES_DIR}"/*/; do
    module="$(basename "${module_dir}")"
    version="$(manifest_field "${module}" version)"
    status="$(module_state_status "${module}")"
    printf '%-16s %-10s %s\n' "${module}" "${version:-?}" "${status}"
  done
}

cmd_status() {
  module="${1:-}"
  if [ -z "${module}" ]; then
    echo "-- Runtime --"
    cat "${RUNTIME_FILE}"
    echo
    echo "-- Modules --"
    cmd_list
    return 0
  fi
  status="$(module_state_status "${module}")"
  echo "${module}: ${status}"
}

cmd_doctor() {
  exit_code=0
  for module_dir in "${MODULES_DIR}"/*/; do
    module="$(basename "${module_dir}")"
    status="$(module_state_status "${module}")"
    if [ "${status}" = "READY" ]; then
      unset -f module_install module_configure module_provision module_register module_validate module_remove 2>/dev/null || true
      # shellcheck disable=SC1090
      . "${MODULES_DIR}/${module}/module.sh"
      log_info "Validating ${module}..."
      if ! module_validate; then
        log_error "${module}: validation failed."
        exit_code=1
      fi
    fi
  done
  return "${exit_code}"
}

command_name="${1:-}"
[ -n "${command_name}" ] || {
  usage
  exit 1
}
shift

case "${command_name}" in
  install) cmd_install "$@" ;;
  remove) cmd_remove "$@" ;;
  list) cmd_list "$@" ;;
  status) cmd_status "$@" ;;
  doctor) cmd_doctor ;;
  *)
    usage
    exit 1
    ;;
esac
EOF_SPROUT_CLI
chmod +x sprout

log_info "sprout (module management CLI) created"

# ------------------------------------------------------------------------------
# Helper scripts (Core lifecycle: start/stop/restart/recreate/logs/inspect/health)
# ------------------------------------------------------------------------------

cat > start.sh <<'EOF_START'
#!/bin/sh
set -eu

log_info() { printf '[INFO]  [Runtime] %s\n' "$1"; }
log_warn() { printf '[WARN]  [Runtime] %s\n' "$1" >&2; }
log_error() { printf '[ERROR] [Runtime] %s\n' "$1" >&2; }
log_fatal() {
  printf '[FATAL] [Runtime] %s\n' "$1" >&2
  exit 1
}

compose_cmd() {
  docker compose -f docker-compose.yml -f docker-compose.modules.yml "$@"
}

# Guardrail: OPENCLAW_GATEWAY_TOKEN is auto-generated by sprout.sh; this only
# fires if .env was hand-edited back to the placeholder.
if grep -q 'CHANGE_THIS' .env; then
  log_fatal "OPENCLAW_GATEWAY_TOKEN in .env still uses the placeholder value. Set it, or delete .env and re-run ./sprout.sh to regenerate it."
fi

# Guardrail: this script must run from the stack directory (relative bind
# mounts below, e.g. ./tailscale/state, resolve against $PWD).
if [ ! -f "docker-compose.yml" ]; then
  log_fatal "docker-compose.yml not found in the current directory. Run this script from inside the stack directory (cd <STACK_DIR> && ./start.sh)."
fi

# Self-heal: recreate the Tailscale state bind-mount source if it is missing.
# A missing host directory here is the most common cause of tailscaled
# failing to persist its ServeConfig ("no such file or directory") later on.
if [ ! -d "tailscale/state" ]; then
  log_warn "tailscale/state was missing — recreating it. If containers were already running, run ./recreate.sh once this completes."
  mkdir -p tailscale/state
fi

# -------- TS_AUTHKEY: interactive prompt (hidden input) --------
# Reads from /dev/tty explicitly so it still works if stdin is redirected.
prompt_ts_authkey() {
  tty_dev="/dev/tty"
  if [ ! -e "${tty_dev}" ]; then
    log_fatal "No interactive terminal available to request TS_AUTHKEY. Set it in .env by hand, then re-run ./start.sh."
  fi

  printf '\n' > "${tty_dev}"
  printf '[INPUT] [Runtime] A Tailscale auth key is needed to register this node.\n' > "${tty_dev}"
  printf '[INPUT] [Runtime] Generate a REUSABLE one at: https://login.tailscale.com/admin/settings/keys\n' > "${tty_dev}"

  entered_key=""
  while [ -z "${entered_key}" ]; do
    printf '[INPUT] [Runtime] TS_AUTHKEY: ' > "${tty_dev}"
    stty -echo < "${tty_dev}" 2>/dev/null || true
    IFS= read -r entered_key < "${tty_dev}"
    stty echo < "${tty_dev}" 2>/dev/null || true
    printf '\n' > "${tty_dev}"
    if [ -z "${entered_key}" ]; then
      printf '[WARN]  [Runtime] Empty value — try again.\n' > "${tty_dev}"
    fi
  done

  env_tmp=".env.tmp"
  sed "s#^TS_AUTHKEY=.*#TS_AUTHKEY=${entered_key}#" .env > "${env_tmp}"
  mv "${env_tmp}" .env
  log_info "TS_AUTHKEY saved to .env."
}

# wait_for_tailscale_registration: polls up to 60s. Echoes "yes"/"no".
wait_for_tailscale_registration() {
  attempt=1
  while [ "${attempt}" -le 30 ]; do
    ts_hostname="$(sed -n 's/^TS_HOSTNAME=//p' .env)"
    if compose_cmd exec -T tailscale tailscale status 2>/dev/null | grep -q "${ts_hostname}"; then
      echo "yes"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  echo "no"
}

log_info "Pulling core images..."
compose_cmd pull redis openclaw tailscale nginx

log_info "Starting redis and openclaw..."
compose_cmd up -d redis openclaw

# -------- Tailscale: prompt / (re)connect / retry-until-registered --------
registered="no"
while [ "${registered}" != "yes" ]; do
  current_key="$(sed -n 's/^TS_AUTHKEY=//p' .env)"
  case "${current_key}" in
    "" | tskey-auth-xxxx*)
      prompt_ts_authkey
      ;;
  esac

  log_info "Starting Tailscale with the current key..."
  compose_cmd up -d --force-recreate tailscale

  log_info "Waiting for Tailscale registration (may take up to 60s)..."
  registered="$(wait_for_tailscale_registration)"

  if [ "${registered}" = "yes" ]; then
    log_info "Tailscale registered."
    # nginx shares tailscale's network namespace: recreate it too, or it
    # would keep pointing at the previous (now-replaced) container.
    log_info "Reattaching nginx to the Tailscale network namespace..."
    compose_cmd up -d --force-recreate nginx
  else
    log_warn "Tailscale did not register within 60s (commonly reported as ipn state NeedsLogin)."
    log_warn "Current IPN state:"
    compose_cmd exec -T tailscale tailscale status 2>&1 || true
    log_warn "This usually means the key was empty, expired, already used (single-use keys), or revoked."
    log_warn "Let's try again with a different key — press Ctrl+C to abort instead."
    env_tmp=".env.tmp"
    sed "s#^TS_AUTHKEY=.*#TS_AUTHKEY=#" .env > "${env_tmp}"
    mv "${env_tmp}" .env
  fi
done

# Configure tailscale serve through the CLI (automatically resolves the FQDN).
# Retried with backoff: once registered, the very first ServeConfig write to
# tailscaled's state store can still transiently fail on some hosts (Docker
# Desktop file sharing, or the container still settling right after `up`).
compose_cmd exec -T tailscale tailscale serve reset 2>/dev/null || true

serve_attempt=1
serve_ok="no"
while [ "${serve_attempt}" -le 5 ]; do
  if compose_cmd exec -T tailscale tailscale serve --bg --https=443 http://127.0.0.1:80 2>serve_err.log; then
    serve_ok="yes"
    break
  fi
  log_warn "tailscale serve attempt ${serve_attempt}/5 failed, retrying in 3s..."
  cat serve_err.log >&2 || true
  serve_attempt=$((serve_attempt + 1))
  sleep 3
done
rm -f serve_err.log

if [ "${serve_ok}" != "yes" ]; then
  log_error "Could not configure tailscale serve after 5 attempts (Tailscale IS registered, so this is a state-store write issue, not an auth issue)."
  log_error "Diagnostics — state directory as seen by the container:"
  compose_cmd exec -T tailscale ls -la /var/lib/tailscale 2>&1 || true
  log_error "Diagnostics — recent tailscale container logs:"
  compose_cmd logs --tail 20 tailscale 2>&1 || true
  log_fatal "Likely causes: (1) start.sh was not run from inside ${PWD##*/} — relative bind mounts resolve against \$PWD; (2) the host directory ./tailscale/state is not shared with Docker (check Docker Desktop file-sharing settings); (3) a stale/half-recreated container — try ./recreate.sh."
fi

# Bootstrap module (SPR-001 §2.5, §8.3): provisioned through the exact same
# lifecycle any future module uses, driven entirely by ./sprout.
bootstrap_module="$(sed -n 's/^bootstrap_module: \(.*\)$/\1/p' state/runtime.yaml)"
bootstrap_status="$(sed -n 's/^bootstrap_status: \(.*\)$/\1/p' state/runtime.yaml)"
if [ -n "${bootstrap_module}" ] && [ "${bootstrap_status}" != "READY" ]; then
  log_info "Provisioning bootstrap module: ${bootstrap_module}"
  ./sprout install "${bootstrap_module}"
else
  log_info "Bootstrap module already READY."
fi

echo
log_info "Stack status:"
compose_cmd ps

echo
log_info "Public URL on your tailnet:"
compose_cmd exec -T tailscale tailscale serve status

echo
log_info "Module status:"
./sprout list

echo
log_info "Next steps:"
echo "    1) Open the URL above from a device on the tailnet"
echo "    2) Connect with:"
echo "         WebSocket URL: wss://<your-fqdn>/"
echo "         Token: \$(sed -n 's/^OPENCLAW_GATEWAY_TOKEN=//p' .env)"
echo "    3) Approve the device pairing:"
echo "         ./approve-device.sh <UUID-shown-by-the-dashboard>"
echo "    4) Manage modules any time with:"
echo "         ./sprout list | ./sprout status | ./sprout install <module>"
EOF_START
chmod +x start.sh

cat > stop.sh <<'EOF_STOP'
#!/bin/sh
set -eu
docker compose -f docker-compose.yml -f docker-compose.modules.yml down
EOF_STOP
chmod +x stop.sh

cat > restart.sh <<'EOF_RESTART'
#!/bin/sh
set -eu
docker compose -f docker-compose.yml -f docker-compose.modules.yml down
exec ./start.sh
EOF_RESTART
chmod +x restart.sh

cat > recreate.sh <<'EOF_RECREATE'
#!/bin/sh
set -eu
docker compose -f docker-compose.yml -f docker-compose.modules.yml down --remove-orphans
docker compose -f docker-compose.yml -f docker-compose.modules.yml up -d --force-recreate
exec ./start.sh
EOF_RECREATE
chmod +x recreate.sh

cat > logs.sh <<'EOF_LOGS'
#!/bin/sh
set -eu
docker compose -f docker-compose.yml -f docker-compose.modules.yml logs -f
EOF_LOGS
chmod +x logs.sh

cat > logs-openclaw.sh <<'EOF_LOGS_OC'
#!/bin/sh
set -eu
docker compose -f docker-compose.yml -f docker-compose.modules.yml logs -f openclaw
EOF_LOGS_OC
chmod +x logs-openclaw.sh

cat > logs-tailscale.sh <<'EOF_LOGS_TS'
#!/bin/sh
set -eu
docker compose -f docker-compose.yml -f docker-compose.modules.yml logs -f tailscale
EOF_LOGS_TS
chmod +x logs-tailscale.sh

cat > logs-ollama.sh <<'EOF_LOGS_OLLAMA'
#!/bin/sh
set -eu
docker compose -f docker-compose.yml -f docker-compose.modules.yml logs -f ollama
EOF_LOGS_OLLAMA
chmod +x logs-ollama.sh

cat > approve-device.sh <<'EOF_APPROVE'
#!/bin/sh
set -eu

if [ $# -eq 0 ]; then
  echo "[INFO]  [Runtime] Devices pending approval:"
  docker compose -f docker-compose.yml -f docker-compose.modules.yml exec openclaw openclaw devices list
  echo
  echo "Usage: ./approve-device.sh <uuid>"
  exit 0
fi

docker compose -f docker-compose.yml -f docker-compose.modules.yml exec openclaw openclaw devices approve "$1"
EOF_APPROVE
chmod +x approve-device.sh

cat > inspect.sh <<'EOF_INSPECT'
#!/bin/sh
set -eu

compose_cmd() {
  docker compose -f docker-compose.yml -f docker-compose.modules.yml "$@"
}

echo "[INFO]  [Runtime] Containers:"
compose_cmd ps
echo

echo "[INFO]  [Runtime] Internal IPs:"
for c in openclaw openclaw-redis openclaw-tailscale openclaw-ollama; do
  printf "  %-22s " "$c"
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c" 2>/dev/null || echo "(not running)"
done
echo

echo "[INFO]  [Runtime] Tailscale serve status:"
compose_cmd exec -T tailscale tailscale serve status 2>/dev/null || echo "(serve not configured)"
echo

echo "[INFO]  [Runtime] Tailscale node status:"
compose_cmd exec -T tailscale tailscale status 2>/dev/null | head -10 || echo "(tailscale did not respond)"
echo

echo "[INFO]  [Runtime] Modules:"
./sprout list
EOF_INSPECT
chmod +x inspect.sh

cat > health.sh <<'EOF_HEALTH'
#!/bin/sh
set -eu

compose_cmd() {
  docker compose -f docker-compose.yml -f docker-compose.modules.yml "$@"
}

echo "[INFO]  [Runtime] Health (through internal nginx):"
compose_cmd exec tailscale wget -qO- http://127.0.0.1:80/healthz || true
echo

echo "[INFO]  [Runtime] Readiness (through internal nginx):"
compose_cmd exec tailscale wget -qO- http://127.0.0.1:80/readyz || true
echo

echo "[INFO]  [Runtime] Module health:"
./sprout doctor
EOF_HEALTH
chmod +x health.sh

# ------------------------------------------------------------------------------
# README
# ------------------------------------------------------------------------------
cat > README.txt <<EOF_README
OpenClaw stack — module-aware, POSIX shell reference implementation

Conforms to SPR-001 (Architecture), SPR-002 (Coding Standards, POSIX.1-2024),
SPR-003 (Architecture Model). Every script in this stack targets /bin/sh only.

Architecture:
  tailnet --HTTPS--> tailscale (serve) --> nginx :80 --> openclaw :18789
  openclaw --HTTP--> ollama :11434 (internal only, bootstrap module)

  - Dedicated Docker network: ${DOCKER_NETWORK_NAME} (${DOCKER_SUBNET})
  - Fixed IPs: tailscale=${TS_FIXED_IP}  openclaw=${OPENCLAW_FIXED_IP}  redis=${REDIS_FIXED_IP}  ollama=${OLLAMA_FIXED_IP}
  - Nginx shares Tailscale's network namespace
  - tailscale serve configured through the CLI (not through a file, avoiding
    \${TS_CERT_DOMAIN} substitution issues in the entrypoint)
  - Does not depend on the host IP/LAN

Before starting:
  1) Edit .env and replace:
       OPENCLAW_GATEWAY_TOKEN   (openssl rand -base64 48)
       TS_AUTHKEY               (https://login.tailscale.com/admin/settings/keys)
       OPENAI_API_KEY or ANTHROPIC_API_KEY (optional — the bootstrap module
       needs no external key)

Core commands:
  ./start.sh           — pull + up core stack + configure tailscale serve +
                          provision the bootstrap module (ollama + tinyllama)
  ./stop.sh            — stop everything (core + installed modules)
  ./restart.sh         — down + start (reconfigures tailscale serve)
  ./recreate.sh        — force-recreate all containers
  ./logs.sh            — combined logs
  ./logs-openclaw.sh   — OpenClaw logs only
  ./logs-tailscale.sh  — Tailscale logs only
  ./logs-ollama.sh     — Ollama logs only
  ./inspect.sh         — internal IPs + Tailscale status + module status
  ./health.sh          — /healthz, /readyz, and module doctor
  ./approve-device.sh  — list/approve Control UI devices

Module management:
  ./sprout list                — available modules and their status
  ./sprout status [module]     — Runtime status, or one module's status
  ./sprout install <module>    — run Resolve->Install->Configure->Provision->
                                  Register->Validate for <module>
  ./sprout remove  <module>    — stop and deregister <module>
  ./sprout doctor              — re-validate every READY module

  The stack ships with one bundled module: ollama (bootstrap). ./start.sh
  provisions it automatically on first run — no manual step required, and it
  registers itself as an OpenClaw provider (module_register) before it can
  reach READY, so OpenClaw is left ready to use it without any user action.
  To add a new capability, create modules/<name>/ with module.yaml,
  compose.yml, and module.sh following the contract in modules/ollama/
  (module_install, module_configure, module_provision, module_register
  [optional — required for AI-inference modules], module_validate,
  module_remove), then run ./sprout install <name>.

First start:
  cd ${STACK_DIR}
  ./start.sh
  # copy the URL displayed at the end and open it in a tailnet browser
  # in the form: WebSocket URL = wss://<that-url-with-wss-and-a-trailing-slash>/
  # token = the value from .env
  # Connect -> you will be asked to approve device pairing:
  ./approve-device.sh <UUID>
  # Reconnect in the browser -> ready
  # Ollama + tinyllama are already READY: ./sprout status ollama

Portability:
  - macOS / WSL2 / Raspberry Pi 64-bit / Ubuntu Server / Alpine / BusyBox
  - Every generated script is /bin/sh + POSIX.1-2024 only (SPR-002): no bash
    arrays, no [[ ]], no (( )), no local, no brace expansion.
  - Tailscale userspace mode: does not require /dev/net/tun or NET_ADMIN
  - If the ${DOCKER_SUBNET} subnet conflicts with your LAN:
      DOCKER_SUBNET=172.31.10.0/24 \\
      TS_FIXED_IP=172.31.10.10 \\
      OPENCLAW_FIXED_IP=172.31.10.20 \\
      REDIS_FIXED_IP=172.31.10.30 \\
      OLLAMA_FIXED_IP=172.31.10.40 \\
      ./sprout.sh

Versioning:
  To pin versions (recommended for production):
      OPENCLAW_VERSION=v1.2.3 OLLAMA_VERSION=0.4.0 OLLAMA_DEFAULT_MODEL=tinyllama ./sprout.sh

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
  - "ollama module stuck in PROVISIONING or FAILED"
       ./logs-ollama.sh to inspect the pull; ./sprout install ollama to retry
       (idempotent — safe to re-run).
EOF_README

log_info "README.txt created"
echo
log_info "Stack generated in ./${STACK_DIR}"
echo
log_warn "Before starting, edit:"
echo "    ${STACK_DIR}/.env  — OPENCLAW_GATEWAY_TOKEN, TS_AUTHKEY, provider API key"
echo
log_info "To start (also provisions the ollama + tinyllama bootstrap module):"
echo "    cd ${STACK_DIR}"
echo "    ./start.sh"