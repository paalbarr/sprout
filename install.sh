#!/bin/sh
# ==============================================================================
# install.sh (0.8.4 — Garden-based module system)
# ------------------------------------------------------------------------------
# Generates two things, side by side in the current directory:
#
#   ./stack/    the portable Docker Compose Core (OpenClaw, Redis, Tailscale,
#               Nginx) plus every file the Module Manager needs (.env, state/,
#               modules/, garden/, HELP.md, and the lifecycle scripts
#               start.sh, stop.sh, restart.sh, recreate.sh, logs.sh, auth.sh,
#               token.sh, send.sh, inspect.sh, health.sh, help.sh, and the engine
#               itself, ./stack/core).
#   ./sprout    a thin dispatcher placed next to install.sh. It is the single
#               entry point for everything below — it `cd`s into ./stack
#               internally, so nothing ever requires the user to `cd` there.
#
# Also placed next to install.sh, for quick access to what's inside OpenClaw's
# own data without ever going into ./stack: ./workspace and ./agents (symlinks
# to stack/openclaw-data/workspace and .../agents) and ./conf/openclaw.json
# (symlink to stack/openclaw-data/openclaw.json).
#
# Core services (generated unconditionally):
#   - OpenClaw    (alpine/openclaw)         — gateway + dashboard
#   - Redis       (redis:7-alpine)          — cache / state
#   - Nginx       (nginx:alpine)            — internal reverse proxy
#   - Tailscale   (tailscale/tailscale)     — single entry point to the tailnet
#
# Command list:
#
#   ./sprout help [-o]                             # local docs; -o shows the extended online docs
#   ./sprout start | stop | restart | recreate    # lifecycle
#   ./sprout logs [service]                        # follow logs
#   ./sprout inspect | health                      # status
#   ./sprout auth [uuid]                           # Control UI device pairing
#   ./sprout token [regen]                         # show, or regenerate, the gateway token
#   ./sprout send onboard <params>                 # non-interactive passthrough to openclaw onboard
#   ./sprout update                                # refresh the Garden index cache
#   ./sprout search [query]                        # list modules published in the Garden
#   ./sprout info <module>                         # show one module's Garden metadata
#   ./sprout install <module>                      # resolve deps -> download -> provision
#   ./sprout remove  <module>                      # stop and deregister <module>
#   ./sprout list                                  # installed modules and their Runtime status
#   ./sprout status  [module]                      # Runtime status, or one module's status
#   ./sprout doctor                                 # re-validate every READY module
#
# On first ./sprout start, the Core asks the Garden which module is marked
# `bootstrap: true` and installs it, together with its full dependency graph,
# through the exact same lifecycle any other module uses. No module identity
# is hard-coded in the Core.
#
# To see Shell and develpment conventions see the file DEVELOPMENT.md in main repository
#
# Dependencies: sh, docker, docker compose, sed, awk, grep, git (used by the
# Garden Client to clone module sources), and optionally openssl (falls back
# to /dev/urandom, see generate_secret()).
# ==============================================================================
set -eu

SPROUT_VERSION="0.8.4"

# -------- Banner — printed before any generation logic runs. --------
printf '\n\n'
cat <<'EOF_LOGO'
███████╗██████╗ ██████╗  ██████╗ ██╗   ██╗████████╗
██╔════╝██╔══██╗██╔══██╗██╔═══██╗██║   ██║╚══██╔══╝
███████╗██████╔╝██████╔╝██║   ██║██║   ██║   ██║
╚════██║██╔═══╝ ██╔══██╗██║   ██║██║   ██║   ██║
███████║██║     ██║  ██║╚██████╔╝╚██████╔╝   ██║
╚══════╝╚═╝     ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝
EOF_LOGO
echo "v${SPROUT_VERSION}"
echo

# -------- 0. Logging ("[LEVEL] 🌱 Message.") --------
log_info() { printf '[INFO]  🌱 %s\n' "$1"; }
log_warn() { printf '[WARN]  🌱 %s\n' "$1" >&2; }
log_error() { printf '[ERROR] 🌱 %s\n' "$1" >&2; }
log_fatal() {
  printf '[FATAL] 🌱 %s\n' "$1" >&2
  exit 1
}

# -------- 1. Parameters --------
STACK_DIR="${STACK_DIR:-stack}"
TZ_VALUE="${TZ_VALUE:-America/Santiago}"
TS_HOSTNAME="${TS_HOSTNAME:-openclaw-docker}"
DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-sprout-stack}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.30.10.0/24}"
TS_FIXED_IP="${TS_FIXED_IP:-172.30.10.10}"
OPENCLAW_FIXED_IP="${OPENCLAW_FIXED_IP:-172.30.10.20}"
REDIS_FIXED_IP="${REDIS_FIXED_IP:-172.30.10.30}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"

# Garden Client defaults. Any Garden is just a git repository with an
# index.yaml at the root of a given branch — point these at a fork or a
# private/enterprise Garden without touching the Core.
GARDEN_REPOSITORY="${GARDEN_REPOSITORY:-https://github.com/paalbarr/sprout.git}"
GARDEN_BRANCH="${GARDEN_BRANCH:-garden}"

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

log_info "Preparing installation"
log_info "Checking dependencies"

deps_missing=0

check_dependency() {
  bin="$1"
  if command -v "${bin}" >/dev/null 2>&1; then
    log_info "${bin} ... OK"
  else
    log_error "${bin} ... NOT FOUND 😞"
    deps_missing=1
  fi
}

check_dependency sed
check_dependency awk
check_dependency grep
check_dependency git
check_dependency docker

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  log_info "docker compose ... OK"
else
  log_error "docker compose ... NOT FOUND 😞"
  deps_missing=1
fi

if command -v openssl >/dev/null 2>&1; then
  log_info "openssl ... OK (optional)"
else
  log_warn "openssl ... not found (optional — falls back to /dev/urandom)"
fi

if [ "${deps_missing}" -eq 1 ]; then
  log_fatal "One or more required dependencies are missing. Install them and re-run ./install.sh. 😞"
fi

log_info "Dependencies ok 😄"

log_info "Creating stack"

mkdir -p "${STACK_DIR}/nginx"
mkdir -p "${STACK_DIR}/openclaw-data"
# workspace/ and agents/ are normally created by OpenClaw itself on first
# run (they live under its mounted config dir). Pre-creating them here
# means the base-folder symlinks generated later (./workspace, ./agents)
# are valid immediately after ./install.sh, instead of dangling until the
# first ./sprout start.
mkdir -p "${STACK_DIR}/openclaw-data/workspace"
mkdir -p "${STACK_DIR}/openclaw-data/agents"
mkdir -p "${STACK_DIR}/redis-data"
mkdir -p "${STACK_DIR}/tailscale/state"
mkdir -p "${STACK_DIR}/state"
mkdir -p "${STACK_DIR}/modules"
mkdir -p "${STACK_DIR}/garden"
cd "${STACK_DIR}"

# ------------------------------------------------------------------------------
# .env — the single source of truth for every variable value used across
# docker-compose.yml, docker-compose.modules.yml, and any module's own
# compose.yaml. Modules downloaded from the Garden are static files (see
# download_module() in ./sprout) — they are never re-templated by the Core,
# so they read every value they need through Docker Compose's own ${VAR}
# interpolation against this file.
# ------------------------------------------------------------------------------
if [ ! -f ".env" ]; then
  log_info "Generating OPENCLAW_GATEWAY_TOKEN..."
  generated_gateway_token="$(generate_secret 48)"

  cat > .env <<EOF_ENV
# ==============================================================================
# OpenClaw stack — sensitive + Runtime configuration variables
# Read directly by docker compose (all *.yml files in this project) and by
# ./core (Garden Client + Module Manager) and modules/*/module.sh.
# ==============================================================================

TZ=${TZ_VALUE}

# Auto-generated at stack creation (openssl rand -base64 48, or a POSIX
# /dev/urandom fallback — see generate_secret() in install.sh). Rotate with:
#   openssl rand -base64 48
OPENCLAW_GATEWAY_TOKEN=${generated_gateway_token}

# Tailscale auth key (https://login.tailscale.com/admin/settings/keys)
# Left as a placeholder on purpose: ./start.sh asks for it interactively on
# first run (hidden input), writes it here, and retries until Tailscale
# registers. A reusable tagged key (e.g. tag:docker) is recommended so
# ./recreate.sh does not burn a fresh single-use key every time.
TS_AUTHKEY=${DEFAULT_TS_AUTHKEY}

TS_HOSTNAME=${TS_HOSTNAME}

# --- AI provider passthrough (OpenClaw default: openai/gpt-5.5) ---
# Add at least one based on the model you intend to use, or install a
# local-inference module from the Garden (see ./sprout search) — no
# external key needed for those.
OPENAI_API_KEY=
ANTHROPIC_API_KEY=

# --- Network + versions (used by docker-compose.yml). Modules read their
# own configuration independently — see each module's own module.yaml/
# compose.yaml/module.sh; the Core does not pre-seed module-specific
# variables here. ---
DOCKER_NETWORK_NAME=${DOCKER_NETWORK_NAME}
DOCKER_SUBNET=${DOCKER_SUBNET}
TS_FIXED_IP=${TS_FIXED_IP}
OPENCLAW_FIXED_IP=${OPENCLAW_FIXED_IP}
REDIS_FIXED_IP=${REDIS_FIXED_IP}
OPENCLAW_VERSION=${OPENCLAW_VERSION}

# --- Garden Client ---
# Where ./sprout fetches garden/index.yaml and module sources from. Point
# this at a fork or a private Garden to use a different module catalog.
GARDEN_REPOSITORY=${GARDEN_REPOSITORY}
GARDEN_BRANCH=${GARDEN_BRANCH}
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
# `openclaw config set`/hot reload). Re-running ./install.sh must NEVER
# clobber a live config — that includes provider registrations made by
# modules during their Register phase.
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
# The "openclaw" upstream is resolved through Docker's internal DNS on the
# Core network (inherited from the Tailscale network namespace)
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
# docker-compose.yml — Core (Runtime infrastructure only; no capability-
# specific service is ever defined here). Fully static: every value comes
# from .env through Docker Compose's native ${VAR} interpolation, so
# re-running ./install.sh always regenerates byte-identical output for the
# same .env. Module services live in docker-compose.modules.yml, assembled
# by ./sprout from modules/<name>/compose.yaml.
# ------------------------------------------------------------------------------
cat > docker-compose.yml <<'EOF_COMPOSE'
# ==============================================================================
# OpenClaw stack — dedicated Docker network + Tailscale as the single entry point
# Core services only. Module services live in docker-compose.modules.yml and are
# merged in by ./sprout and ./start.sh (docker compose -f ... -f ...).
# All values below are read from .env via Docker Compose interpolation.
# ==============================================================================

services:

  redis:
    image: redis:7-alpine
    container_name: sprout-redis
    restart: unless-stopped

    command:
      - redis-server
      - --appendonly
      - "yes"

    volumes:
      - ./redis-data:/data

    networks:
      sprout_net:
        ipv4_address: ${REDIS_FIXED_IP}

  openclaw:
    image: alpine/openclaw:${OPENCLAW_VERSION}
    container_name: sprout-openclaw
    restart: unless-stopped

    env_file:
      - .env

    environment:
      TZ: ${TZ}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
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
      sprout_net:
        ipv4_address: ${OPENCLAW_FIXED_IP}

  tailscale:
    image: tailscale/tailscale:latest
    container_name: sprout-tailscale
    restart: unless-stopped

    hostname: ${TS_HOSTNAME}

    # NOTE: TS_SERVE_CONFIG is NOT used because ${TS_CERT_DOMAIN} is not always
    # substituted in the entrypoint. start.sh configures serve through the CLI.
    environment:
      TS_AUTHKEY: ${TS_AUTHKEY}
      TS_HOSTNAME: ${TS_HOSTNAME}
      TS_STATE_DIR: /var/lib/tailscale
      TS_USERSPACE: "true"
      TS_EXTRA_ARGS: "--accept-dns=false"

    volumes:
      - ./tailscale/state:/var/lib/tailscale

    depends_on:
      - openclaw

    networks:
      sprout_net:
        ipv4_address: ${TS_FIXED_IP}

  nginx:
    image: nginx:alpine
    container_name: sprout-nginx
    restart: unless-stopped

    # Shares Tailscale's network namespace:
    #   - listens on :80 inside that namespace
    #   - tailscale serve routes HTTPS:443 -> 127.0.0.1:80 (configured in start.sh)
    #   - resolves "openclaw" through the inherited sprout_net DNS
    network_mode: "service:tailscale"

    volumes:
      - ./nginx/openclaw.conf:/etc/nginx/conf.d/default.conf:ro

    depends_on:
      - tailscale
      - openclaw

networks:
  # "sprout_net" is the fixed, internal Compose reference key used by every
  # compose file in this project (core and modules alike) — it never changes.
  # The *actual* Docker network name is controlled independently through
  # DOCKER_NETWORK_NAME (.env), via the "name:" override below.
  sprout_net:
    name: ${DOCKER_NETWORK_NAME}
    driver: bridge
    ipam:
      config:
        - subnet: ${DOCKER_SUBNET}
EOF_COMPOSE

log_info "docker-compose.yml created"

# ------------------------------------------------------------------------------
# docker-compose.modules.yml — assembled from installed modules' service
# fragments (modules/<name>/compose.yaml). Starts as an empty overlay; ./sprout
# install/remove regenerate it. Never edited by hand.
# ------------------------------------------------------------------------------
cat > docker-compose.modules.yml <<'EOF_MODULES_COMPOSE'
# ==============================================================================
# Generated overlay — DO NOT EDIT BY HAND.
# Regenerated by ./sprout on every `install` / `remove`. One service block per
# READY or provisioning module, sourced verbatim from modules/<name>/compose.yaml
# (modules without their own container, e.g. a model bootstrap module, define
# no compose.yaml and contribute nothing here).
# ==============================================================================
services: {}
EOF_MODULES_COMPOSE

log_info "docker-compose.modules.yml created (empty overlay)"

# ------------------------------------------------------------------------------
# state/runtime.yaml, state/modules.yaml — Runtime is the source of truth,
# owned exclusively by ./sprout; nothing else writes here. bootstrap_module
# starts empty on purpose: the Core does not hard-code which module
# bootstraps the Runtime — it asks the Garden the first time ./start.sh
# runs, via `./sprout resolve-bootstrap`, and persists the answer here.
# ------------------------------------------------------------------------------
cat > state/runtime.yaml <<'EOF_RUNTIME'
status: NEW
core_status: READY
bootstrap_module:
bootstrap_status: PENDING
EOF_RUNTIME

cat > state/modules.yaml <<'EOF_MODULES_STATE'
modules:
EOF_MODULES_STATE

log_info "state/runtime.yaml and state/modules.yaml created"

# garden/ starts empty: the first `./sprout update` (run automatically by
# `./sprout install`/`./sprout search`/`./sprout info`/`./start.sh` if the
# cache is missing) clones GARDEN_REPOSITORY@GARDEN_BRANCH and populates
# garden/index.yaml. Cached so the Runtime keeps working offline afterwards.
log_info "garden/ created (empty — populated by the first 'sprout update')"

# ------------------------------------------------------------------------------
# core — Garden Client + Module Manager. Every capability lifecycle operation
# (Resolve -> Install -> Configure -> Provision -> Register -> Validate) goes
# through this entrypoint. Modules are never invoked directly by the user,
# and the Core never embeds a module's implementation. Not meant to be typed
# by hand — the root ./sprout dispatcher (generated at the very end of this
# script, outside ./stack) forwards module/Garden commands here.
# ------------------------------------------------------------------------------
cat > core <<'EOF_CORE_CLI'
#!/bin/sh
# ==============================================================================
# core — Garden Client + Module Manager
# ==============================================================================
set -eu

RUNTIME_FILE="state/runtime.yaml"
MODULES_STATE_FILE="state/modules.yaml"
MODULES_DIR="modules"
GARDEN_DIR="garden"
GARDEN_INDEX_FILE="${GARDEN_DIR}/index.yaml"
COMPOSE_BASE="docker-compose.yml"
COMPOSE_MODULES="docker-compose.modules.yml"
MODULES_LOG_DIR="state/logs"

# MODULE_LOG_FILE — when provision_one_module() is actively running for a
# module, this points at that module's own install-trace log
# (state/logs/<module>.log). Every log_info/warn/error/fatal call below
# mirrors its line into that file too, in addition to the terminal, so the
# whole lifecycle (Install->Configure->Provision->Register->Validate, or
# wherever it failed) ends up in one place. Empty outside of a module run.
MODULE_LOG_FILE=""

log_to_module_file() {
  if [ -n "${MODULE_LOG_FILE}" ]; then
    printf '%s\n' "$1" >> "${MODULE_LOG_FILE}"
  fi
}

log_info() {
  printf '[INFO]  🌱 %s\n' "$1"
  log_to_module_file "[INFO]  🌱 $1"
}
log_warn() {
  printf '[WARN]  🌱 %s\n' "$1" >&2
  log_to_module_file "[WARN]  🌱 $1"
}
log_error() {
  printf '[ERROR] 🌱 %s\n' "$1" >&2
  log_to_module_file "[ERROR] 🌱 $1"
}
log_fatal() {
  printf '[FATAL] 🌱 %s\n' "$1" >&2
  log_to_module_file "[FATAL] 🌱 $1"
  if [ -n "${MODULE_LOG_FILE}" ]; then
    printf '[INFO]  🌱 Install log saved to: %s\n' "${MODULE_LOG_FILE}" >&2
  fi
  exit 1
}

compose_cmd() {
  docker compose -f "${COMPOSE_BASE}" -f "${COMPOSE_MODULES}" "$@"
}

# env_value <KEY> — reads KEY=value from .env (first match, empty if absent).
# Read directly rather than exporting .env into this process, so ./core
# never leaks secrets (TS_AUTHKEY, OPENCLAW_GATEWAY_TOKEN, provider keys)
# into its own environment or any child process it does not explicitly need
# them in.
#
# NOTE (value-returning helper — no logging): every function in this file
# whose result is captured via $(...) must never call log_info, since INFO
# goes to stdout and would corrupt the captured value. Only top-level
# command handlers (cmd_*, provision_one_module, etc.) log.
env_value() {
  sed -n "s/^$1=//p" .env 2>/dev/null | head -n 1
}

garden_repository() {
  value="$(env_value GARDEN_REPOSITORY)"
  if [ -n "${value}" ]; then echo "${value}"; else echo "https://github.com/paalbarr/sprout.git"; fi
}

garden_branch() {
  value="$(env_value GARDEN_BRANCH)"
  if [ -n "${value}" ]; then echo "${value}"; else echo "garden"; fi
}

require_git() {
  command -v git >/dev/null 2>&1 || log_fatal "git is required to reach the Garden. Install git and retry."
}

# -------- Temp workspace (no mktemp dependency, to avoid a non-POSIX tool).
# Every clone goes through new_tmp_dir() so cleanup_tmp_dirs() (EXIT trap)
# can remove it even on failure. ----------------------------------------------
tmp_dir_counter=0
new_tmp_dir() {
  tmp_dir_counter=$((tmp_dir_counter + 1))
  dir="${TMPDIR:-/tmp}/core-garden-$$-${tmp_dir_counter}"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  printf '%s' "${dir}"
}

cleanup_tmp_dirs() {
  rm -rf "${TMPDIR:-/tmp}"/core-garden-$$-* 2>/dev/null || true
}
trap cleanup_tmp_dirs EXIT

usage() {
  cat <<'EOF_USAGE'
Usage: ./core <command> [args]

Called through the root ./sprout dispatcher in normal use.

Garden commands (discovery — read-only, never touch the Runtime):
  update              Refresh the local Garden index cache (garden/index.yaml)
  search  [query]     List modules published in the Garden index
  info    <module>    Show a module's Garden metadata and local Runtime status

Runtime commands (Module Manager — drive the module lifecycle):
  install <module>    Resolve dependencies, download, and provision <module>
  remove  <module>    Stop <module> and remove it from the Runtime
  list                List installed modules and their current status
  status  [module]    Show Runtime status, or a single module's status
  doctor              Re-validate every READY module

Internal (used by start.sh):
  resolve-bootstrap   Ask the Garden which module is bootstrap:true and
                       persist it to state/runtime.yaml (idempotent)
EOF_USAGE
}

# ==============================================================================
# Garden Client — discovery, index caching, module download. Garden holds
# metadata only; it is never part of the Runtime.
# ==============================================================================

# garden_update — clones GARDEN_REPOSITORY at GARDEN_BRANCH and caches its
# root index.yaml as garden/index.yaml. Called automatically by
# ensure_garden_index() the first time it is needed; safe to re-run any
# time — it never modifies the Runtime, only the local cache.
garden_update() {
  require_git
  repo="$(garden_repository)"
  branch="$(garden_branch)"
  log_info "Fetching Garden index from ${repo} (branch: ${branch})..."

  clone_dir="$(new_tmp_dir)"
  if ! git clone --quiet --depth 1 --single-branch --branch "${branch}" "${repo}" "${clone_dir}" 2>"${clone_dir}.err"; then
    cat "${clone_dir}.err" >&2 2>/dev/null || true
    rm -rf "${clone_dir}" "${clone_dir}.err"
    log_fatal "Could not clone ${repo} (branch ${branch}). Check GARDEN_REPOSITORY/GARDEN_BRANCH in .env and network access."
  fi
  rm -f "${clone_dir}.err"

  if [ ! -f "${clone_dir}/index.yaml" ]; then
    rm -rf "${clone_dir}"
    log_fatal "${repo}@${branch} has no index.yaml at its root — not a valid Garden."
  fi

  mkdir -p "${GARDEN_DIR}"
  cp "${clone_dir}/index.yaml" "${GARDEN_INDEX_FILE}"
  rm -rf "${clone_dir}"
  log_info "Garden index cached at ${GARDEN_INDEX_FILE}."
}

ensure_garden_index() {
  [ -f "${GARDEN_INDEX_FILE}" ] || garden_update
}

# garden_flat — flattens garden/index.yaml into "<module>|<field>|<value>"
# lines, one per field (multiple lines for "depends" when a module has more
# than one dependency). Reference format:
#
#   modules:
#     - name: tinyllama
#       version: 1.0.0
#       description: ...
#       repository: https://github.com/paalbarr/sprout.git
#       branch: garden
#       path: tinyllama
#       bootstrap: true
#       depends:
#         - ollama
#
# A hand-rolled awk parser is used instead of a YAML library so the Garden
# Client has no dependency beyond POSIX awk/sed/grep. It only needs to
# support this one flat, fixed-indentation shape — Garden's index.yaml is a
# Sprout-owned contract, not arbitrary YAML.
garden_flat() {
  [ -f "${GARDEN_INDEX_FILE}" ] || log_fatal "No Garden index cached. Run './sprout update' first."
  awk '
    /^  - name: / {
      name = $0
      sub(/^  - name: /, "", name)
      print name "|name|" name
      depends_mode = 0
      next
    }
    /^    depends:[ ]*$/ {
      depends_mode = 1
      next
    }
    depends_mode == 1 && /^      - / {
      v = $0
      sub(/^      - /, "", v)
      print name "|depends|" v
      next
    }
    /^    [A-Za-z_][A-Za-z0-9_]*: / {
      depends_mode = 0
      line = $0
      sub(/^    /, "", line)
      colon = index(line, ": ")
      if (colon > 0) {
        key = substr(line, 1, colon - 1)
        val = substr(line, colon + 2)
        print name "|" key "|" val
      }
      next
    }
  ' "${GARDEN_INDEX_FILE}"
}

garden_field() {
  # $1 = module name, $2 = field name
  garden_flat | awk -F'|' -v n="$1" -v f="$2" '$1==n && $2==f {print $3; exit}'
}

garden_depends() {
  # $1 = module name — prints one dependency name per line (may be empty)
  garden_flat | awk -F'|' -v n="$1" '$1==n && $2=="depends" {print $3}'
}

garden_module_exists() {
  garden_flat | awk -F'|' -v n="$1" '$1==n && $2=="name" {found=1} END{exit !found}'
}

garden_all_modules() {
  garden_flat | awk -F'|' '$2=="name" {print $1}'
}

find_bootstrap_module() {
  garden_flat | awk -F'|' '$2=="bootstrap" && $3=="true" {print $1; exit}'
}

# download_module <module> — fetches module.yaml/compose.yaml/module.sh from
# the repository/branch/path declared for <module> in the cached Garden
# index and replaces modules/<module>/ with the downloaded copy. Each module
# may live in its own repository/branch — the index is the only thing that
# must live at GARDEN_REPOSITORY@GARDEN_BRANCH.
download_module() {
  require_git
  module="$1"
  garden_module_exists "${module}" || log_fatal "Module '${module}' is not published in the Garden index. Try './sprout search'."

  repo="$(garden_field "${module}" repository)"
  branch="$(garden_field "${module}" branch)"
  path="$(garden_field "${module}" path)"
  [ -n "${repo}" ] || log_fatal "Garden index entry for '${module}' has no 'repository' field."
  [ -n "${branch}" ] || branch="main"
  [ -n "${path}" ] || path="${module}"

  log_info "Downloading '${module}' from ${repo} (branch: ${branch}, path: ${path})..."
  clone_dir="$(new_tmp_dir)"
  if ! git clone --quiet --depth 1 --single-branch --branch "${branch}" "${repo}" "${clone_dir}" 2>"${clone_dir}.err"; then
    cat "${clone_dir}.err" >&2 2>/dev/null || true
    rm -rf "${clone_dir}" "${clone_dir}.err"
    log_fatal "Could not clone ${repo} (branch ${branch}) for module '${module}'."
  fi
  rm -f "${clone_dir}.err"

  if [ ! -d "${clone_dir}/${path}" ]; then
    rm -rf "${clone_dir}"
    log_fatal "Path '${path}' does not exist in ${repo}@${branch} (module '${module}')."
  fi

  rm -rf "${MODULES_DIR:?}/${module}"
  mkdir -p "${MODULES_DIR}/${module}"
  cp -R "${clone_dir}/${path}/." "${MODULES_DIR}/${module}/"
  rm -rf "${clone_dir}"

  [ -f "${MODULES_DIR}/${module}/module.yaml" ] || log_fatal "Downloaded module '${module}' is missing module.yaml — not a valid module."
  [ -f "${MODULES_DIR}/${module}/module.sh" ] || log_fatal "Downloaded module '${module}' is missing module.sh — not a valid module."
  chmod +x "${MODULES_DIR}/${module}/module.sh"

  log_info "'${module}' downloaded to ${MODULES_DIR}/${module}/."
}

# resolve_install_order <target> — writes the dependency-first install order
# for <target> (itself included, no duplicates) to "${order_file}", one
# module per line. Implemented iteratively (BFS closure + round-based
# topological sort) rather than recursively: POSIX sh functions have no
# `local` variables, so a recursive resolver silently clobbers a caller's
# in-flight "current module" on every nested call. Rejects circular
# dependencies.
resolve_install_order() {
  target="$1"
  seen_file="$2"
  order_file="$3"
  queue_file="$4"

  : > "${seen_file}"
  : > "${order_file}"
  : > "${queue_file}"

  garden_module_exists "${target}" || log_fatal "Module '${target}' is not published in the Garden index."
  echo "${target}" >> "${seen_file}"
  echo "${target}" >> "${queue_file}"

  # Breadth-first closure: collect every module reachable through "depends".
  while [ -s "${queue_file}" ]; do
    current="$(head -n 1 "${queue_file}")"
    tail -n +2 "${queue_file}" > "${queue_file}.next"
    mv "${queue_file}.next" "${queue_file}"

    # Word splitting is required here: garden_depends prints one bare
    # module name per line, joined by IFS whitespace on assignment to $deps.
    deps="$(garden_depends "${current}")"
    for dep in ${deps}; do
      garden_module_exists "${dep}" || log_fatal "Module '${current}' depends on '${dep}', which is not published in the Garden index."
      if ! grep -qxF "${dep}" "${seen_file}" 2>/dev/null; then
        echo "${dep}" >> "${seen_file}"
        echo "${dep}" >> "${queue_file}"
      fi
    done
  done

  # Round-based topological sort: repeatedly place every not-yet-placed
  # module whose dependencies are all already placed, until no progress is
  # made. Whatever remains unplaced is part of a dependency cycle.
  total="$(wc -l < "${seen_file}" | tr -d ' ')"
  placed="0"
  progress="yes"
  while [ "${progress}" = "yes" ] && [ "${placed}" -lt "${total}" ]; do
    progress="no"
    while IFS= read -r m <&9; do
      [ -n "${m}" ] || continue
      grep -qxF "${m}" "${order_file}" 2>/dev/null && continue
      deps="$(garden_depends "${m}")"
      all_ready="yes"
      for d in ${deps}; do
        grep -qxF "${d}" "${order_file}" 2>/dev/null || { all_ready="no"; break; }
      done
      if [ "${all_ready}" = "yes" ]; then
        echo "${m}" >> "${order_file}"
        progress="yes"
      fi
    done 9< "${seen_file}"
    placed="$(wc -l < "${order_file}" | tr -d ' ')"
  done

  if [ "${placed}" -lt "${total}" ]; then
    log_error "Circular dependency detected in the Garden index. Unresolved modules:"
    sort "${seen_file}" > "${seen_file}.sorted"
    sort "${order_file}" > "${order_file}.sorted"
    comm -23 "${seen_file}.sorted" "${order_file}.sorted" >&2 || true
    log_fatal "Cannot install '${target}' until the Garden index's dependency graph is acyclic."
  fi
}

# ==============================================================================
# Runtime state helpers (state/runtime.yaml, state/modules.yaml). ./sprout
# is the exclusive writer.
# ==============================================================================

module_state_line() {
  grep -F "name: $1," "${MODULES_STATE_FILE}" 2>/dev/null || true
}

module_state_status() {
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

  tmp_file="${MODULES_STATE_FILE}.tmp"
  grep -v -F "name: $1," "${MODULES_STATE_FILE}" > "${tmp_file}" 2>/dev/null || true
  if ! grep -q '^modules:' "${tmp_file}" 2>/dev/null; then
    printf 'modules:\n' > "${tmp_file}"
  fi
  mv "${tmp_file}" "${MODULES_STATE_FILE}"
  echo "${entry}" >> "${MODULES_STATE_FILE}"
}

module_state_remove() {
  tmp_file="${MODULES_STATE_FILE}.tmp"
  grep -v -F "name: $1," "${MODULES_STATE_FILE}" > "${tmp_file}" 2>/dev/null || true
  mv "${tmp_file}" "${MODULES_STATE_FILE}"
}

runtime_get_bootstrap_module() {
  sed -n 's/^bootstrap_module: \(.*\)$/\1/p' "${RUNTIME_FILE}"
}

runtime_get_bootstrap_status() {
  sed -n 's/^bootstrap_status: \(.*\)$/\1/p' "${RUNTIME_FILE}"
}

runtime_set_bootstrap_module() {
  tmp_file="${RUNTIME_FILE}.tmp"
  sed "s/^bootstrap_module:.*/bootstrap_module: $1/" "${RUNTIME_FILE}" > "${tmp_file}"
  mv "${tmp_file}" "${RUNTIME_FILE}"
}

runtime_set_bootstrap_status() {
  tmp_file="${RUNTIME_FILE}.tmp"
  sed "s/^bootstrap_status:.*/bootstrap_status: $1/" "${RUNTIME_FILE}" > "${tmp_file}"
  mv "${tmp_file}" "${RUNTIME_FILE}"
}

# module_compose_file <module> — prints the path to the module's compose
# fragment (compose.yaml), if it shipped one; prints nothing otherwise.
module_compose_file() {
  if [ -f "${MODULES_DIR}/$1/compose.yaml" ]; then
    printf '%s' "${MODULES_DIR}/$1/compose.yaml"
  fi
}

# regenerate_modules_compose — rebuilds docker-compose.modules.yml from every
# module currently in any active lifecycle state (not NOT_INSTALLED), so
# `docker compose pull/up` can see the service as soon as install() needs it,
# and FAILED modules stay visible for retry/debugging until `remove`d.
regenerate_modules_compose() {
  echo "services:" > "${COMPOSE_MODULES}.new"
  wrote_any="no"
  # NOTE: loop variable is deliberately "cm" (compose-module), not "module".
  # This function is called from inside provision_one_module(), which keeps
  # its own module currently being provisioned in a global "module" variable
  # (this codebase avoids "local" for strict POSIX /bin/sh compliance, so
  # every variable here is effectively global). Reusing "module" as the loop
  # variable here silently clobbered that outer variable for the rest of
  # provision_one_module() once this function returned — every log line and
  # module_state_set call after the first regenerate_modules_compose() call
  # would then act on whatever module happened to sort last in
  # "${MODULES_DIR}"/*/, instead of the module actually being installed
  # (confirmed 2026-08-11: installing "openai-oauth" alongside an existing
  # "tinyllama" install caused every phase after the first to log
  # "...tinyllama..." and, critically, recorded the final READY state
  # against "tinyllama" instead of "openai-oauth", leaving the real module
  # stuck at INSTALLING forever despite installing correctly).
  for module_dir in "${MODULES_DIR}"/*/; do
    [ -d "${module_dir}" ] || continue
    cm="$(basename "${module_dir}")"
    status="$(module_state_status "${cm}")"
    [ "${status}" != "NOT_INSTALLED" ] || continue
    compose_file="$(module_compose_file "${cm}")"
    if [ -n "${compose_file}" ]; then
      # A module's compose.yaml can arrive in any indentation style: a bare
      # fragment already indented 2 spaces under an implied "services:", a
      # fragment with NO indentation at all (its service key starts at
      # column 0), or a full standalone compose file with its own
      # top-level "services:" (possibly preceded by comments/blank lines,
      # possibly CRLF). All three must nest correctly under the single
      # "services:" line already written above, or Docker Compose rejects
      # the whole file — either with a duplicate-key "services must be a
      # mapping" (full-file style) or a silently-unnested service (0-indent
      # style, which produces the exact same error since "services:" then
      # has nothing under it). So: drop any leaked top-level "services:"
      # line, find the smallest indentation among the remaining non-blank
      # lines, and re-indent everything relative to that, landing the
      # service key at exactly 2 spaces regardless of how it arrived.
      awk '
        { sub(/\r$/, "") }
        /^services:[ \t]*$/ { next }
        {
          lines[++n] = $0
          if ($0 !~ /^[ \t]*$/) {
            line = $0
            sub(/[^ \t].*$/, "", line)
            indent = length(line)
            if (seen == 0 || indent < min_indent) { min_indent = indent; seen = 1 }
          }
        }
        END {
          if (seen == 0) { exit }
          for (i = 1; i <= n; i++) {
            l = lines[i]
            if (l ~ /^[ \t]*$/) { print l; continue }
            print "  " substr(l, min_indent + 1)
          }
        }
      ' "${compose_file}" >> "${COMPOSE_MODULES}.new"
      wrote_any="yes"
    else
      # Not necessarily an error — some modules (e.g. one that only rides on
      # another module's engine) legitimately ship no compose file. But if
      # this module's own module_install() expects a container, this is
      # exactly why a later "docker compose pull/up <module>" would fail
      # with a cryptic "no such service" — surfacing it here up front makes
      # that failure traceable instead of silent.
      log_warn "${cm} has no compose.yaml in modules/${cm}/ — it will define no container. If it should have its own service, check the Garden entry (repository/branch/path) that downloaded it."
    fi
  done
  [ "${wrote_any}" = "yes" ] || echo "services: {}" > "${COMPOSE_MODULES}.new"
  mv "${COMPOSE_MODULES}.new" "${COMPOSE_MODULES}"
}

manifest_field() {
  # $1 = module, $2 = field — reads the locally downloaded module.yaml
  # (post-download), as opposed to garden_field() which reads the Garden
  # index (pre-download / not-yet-installed modules).
  sed -n "s/^$2: \(.*\)\$/\1/p" "${MODULES_DIR}/$1/module.yaml" 2>/dev/null | head -n 1
}

EOF_CORE_CLI
cat >> core <<'EOF_CORE_CLI'
# ==============================================================================
# Module Manager — runs the lifecycle for one module at a time. Dependency
# ordering across modules is handled by cmd_install(), which calls
# provision_one_module() once per module in the order resolve_install_
# order() computed.
# ==============================================================================

# provision_one_module <module> — Install->Configure->Provision->Register->
# Validate for a single module, already assumed to have every dependency
# already READY (the caller is responsible for ordering). Downloads the
# module fresh from the Garden every time it actually needs provisioning, so
# modules/<name>/ always reflects the Garden index it was resolved against.
provision_one_module() {
  module="$1"
  current_status="$(module_state_status "${module}")"
  if [ "${current_status}" = "READY" ]; then
    log_info "${module} is already READY. Skipping."
    return 0
  fi

  # Fresh log trace for this attempt: overwritten every time, never
  # versioned, so state/logs/<module>.log always reflects only the most
  # recent install attempt for that module.
  mkdir -p "${MODULES_LOG_DIR}"
  MODULE_LOG_FILE="${MODULES_LOG_DIR}/${module}.log"
  : > "${MODULE_LOG_FILE}"
  log_info "${module}: starting install attempt — trace: ${MODULE_LOG_FILE}"

  download_module "${module}"

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

  # Register: for AI-inference modules this creates or updates the
  # corresponding OpenClaw provider configuration. Optional hook for modules
  # with nothing to register (e.g. a pure infrastructure module like
  # "ollama" itself); mandatory in practice for AI-inference modules (e.g.
  # "tinyllama").
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

  if [ "${module}" = "$(runtime_get_bootstrap_module)" ]; then
    runtime_set_bootstrap_status "READY"
  fi

  log_info "${module} is READY."
  log_info "Install log saved to: ${MODULE_LOG_FILE}"
  MODULE_LOG_FILE=""
}

# ==============================================================================
# Commands
# ==============================================================================

cmd_install() {
  module="${1:-}"
  [ -n "${module}" ] || log_fatal "Usage: ./sprout install <module>"
  ensure_garden_index

  order_dir="$(new_tmp_dir)"
  log_info "Resolving dependency graph for ${module}..."
  resolve_install_order "${module}" "${order_dir}/seen" "${order_dir}/order" "${order_dir}/queue"

  # Read the resolved order from fd 9, not stdin (fd 0). provision_one_module
  # runs git/docker/module-defined commands that may themselves touch stdin
  # (e.g. a credential prompt, or a CLI probing whether it's attached to a
  # terminal); if this loop read from fd 0 like they do, any such read would
  # consume bytes meant for `read -r m` and silently desync the loop —
  # exactly the failure mode where the first module in a dependency chain
  # (e.g. ollama) installs fine and every module after it (e.g. tinyllama)
  # is never even attempted, with no error and nothing in its log.
  while IFS= read -r m <&9; do
    [ -n "${m}" ] || continue
    provision_one_module "${m}"
  done 9< "${order_dir}/order"
}

cmd_remove() {
  module="${1:-}"
  [ -n "${module}" ] || log_fatal "Usage: ./sprout remove <module>"
  status="$(module_state_status "${module}")"
  if [ "${status}" = "NOT_INSTALLED" ]; then
    log_info "${module} is not installed."
    return 0
  fi
  [ -f "${MODULES_DIR}/${module}/module.sh" ] || log_fatal "modules/${module}/module.sh not found locally — cannot run its remove phase. (Was modules/${module}/ deleted by hand?)"

  unset -f module_install module_configure module_provision module_register module_validate module_remove 2>/dev/null || true
  # shellcheck disable=SC1090
  . "${MODULES_DIR}/${module}/module.sh"
  log_info "Removing ${module}..."
  module_remove || log_warn "${module}: remove phase reported an error (continuing)."

  module_state_remove "${module}"
  regenerate_modules_compose

  if [ "${module}" = "$(runtime_get_bootstrap_module)" ]; then
    runtime_set_bootstrap_status "PENDING"
  fi

  log_info "${module} removed from the Runtime."
}

cmd_list() {
  printf '%-16s %-10s %s\n' "MODULE" "VERSION" "STATUS"
  for module_dir in "${MODULES_DIR}"/*/; do
    [ -d "${module_dir}" ] || continue
    module="$(basename "${module_dir}")"
    version="$(manifest_field "${module}" version)"
    status="$(module_state_status "${module}")"
    printf '%-16s %-10s %s\n' "${module}" "${version:-?}" "${status}"
  done
}

cmd_search() {
  query="${1:-}"
  ensure_garden_index
  printf '%-16s %-10s %-9s %s\n' "MODULE" "VERSION" "BOOTSTRAP" "DESCRIPTION"
  for module in $(garden_all_modules); do
    if [ -n "${query}" ]; then
      case "${module}" in
        *"${query}"*) : ;;
        *) continue ;;
      esac
    fi
    version="$(garden_field "${module}" version)"
    description="$(garden_field "${module}" description)"
    bootstrap="$(garden_field "${module}" bootstrap)"
    printf '%-16s %-10s %-9s %s\n' "${module}" "${version:-?}" "${bootstrap:-false}" "${description}"
  done
}

cmd_info() {
  module="${1:-}"
  [ -n "${module}" ] || log_fatal "Usage: ./sprout info <module>"
  ensure_garden_index
  garden_module_exists "${module}" || log_fatal "Module '${module}' is not published in the Garden index."

  echo "name:        ${module}"
  echo "version:     $(garden_field "${module}" version)"
  echo "description: $(garden_field "${module}" description)"
  echo "repository:  $(garden_field "${module}" repository)"
  echo "branch:      $(garden_field "${module}" branch)"
  echo "path:        $(garden_field "${module}" path)"
  bootstrap_flag="$(garden_field "${module}" bootstrap)"
  echo "bootstrap:   ${bootstrap_flag:-false}"
  depends_list="$(garden_depends "${module}" | tr '\n' ' ')"
  echo "depends:     ${depends_list:-(none)}"
  echo "runtime:     $(module_state_status "${module}")"
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
    [ -d "${module_dir}" ] || continue
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

# cmd_resolve_bootstrap — asks the Garden which module is bootstrap:true and
# persists it to state/runtime.yaml. Idempotent: a module.yaml already
# recorded in runtime.yaml is never overwritten, so switching Gardens after
# the first start does not silently re-point an already-provisioned Runtime.
# Deliberately does not `echo` the result: this command's whole invocation is
# captured verbatim by start.sh via a plain (uncaptured) call, then start.sh
# re-reads state/runtime.yaml directly — keeping the INFO-goes-to-stdout
# logging convention intact instead of special-casing this one command.
cmd_resolve_bootstrap() {
  current="$(runtime_get_bootstrap_module)"
  if [ -n "${current}" ]; then
    log_info "Bootstrap module already resolved: ${current}."
    return 0
  fi
  ensure_garden_index
  bootstrap="$(find_bootstrap_module)"
  [ -n "${bootstrap}" ] || log_fatal "The Garden index defines no module with 'bootstrap: true'."
  runtime_set_bootstrap_module "${bootstrap}"
  log_info "Bootstrap module resolved from Garden: ${bootstrap}."
}

command_name="${1:-}"
[ -n "${command_name}" ] || {
  usage
  exit 1
}
shift

# "logs" is not a core command: the root ./sprout dispatcher handles it
# directly through ./logs.sh, which works uniformly for Core services and
# installed modules alike (both are services in the same compose project) —
# no need to duplicate that here.
case "${command_name}" in
  update) garden_update ;;
  search) cmd_search "$@" ;;
  info) cmd_info "$@" ;;
  install) cmd_install "$@" ;;
  remove) cmd_remove "$@" ;;
  list) cmd_list "$@" ;;
  status) cmd_status "$@" ;;
  doctor) cmd_doctor ;;
  resolve-bootstrap) cmd_resolve_bootstrap ;;
  *)
    usage
    exit 1
    ;;
esac
EOF_CORE_CLI
chmod +x core

log_info "core (Garden Client + Module Manager) created"

# ------------------------------------------------------------------------------
# Helper scripts (Core lifecycle: start/stop/restart/recreate/logs/inspect/health)
# ------------------------------------------------------------------------------

cat > start.sh <<'EOF_START'
#!/bin/sh
set -eu

log_info() { printf '[INFO]  🌱 %s\n' "$1"; }
log_warn() { printf '[WARN]  🌱 %s\n' "$1" >&2; }
log_error() { printf '[ERROR] 🌱 %s\n' "$1" >&2; }
log_fatal() {
  printf '[FATAL] 🌱 %s\n' "$1" >&2
  exit 1
}

compose_cmd() {
  docker compose -f docker-compose.yml -f docker-compose.modules.yml "$@"
}

# Guardrail: OPENCLAW_GATEWAY_TOKEN is auto-generated by install.sh; this
# only fires if .env was hand-edited back to the placeholder.
if grep -q 'CHANGE_THIS' .env; then
  log_fatal "OPENCLAW_GATEWAY_TOKEN in .env still uses the placeholder value. Set it, or delete this directory and re-run ./install.sh from the base folder to regenerate it."
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
  printf '[INPUT] 🌱 A Tailscale auth key is needed to register this node.\n' > "${tty_dev}"
  printf '[INPUT] 🌱 Generate a REUSABLE one at: https://login.tailscale.com/admin/settings/keys\n' > "${tty_dev}"

  entered_key=""
  while [ -z "${entered_key}" ]; do
    printf '[INPUT] 🌱 TS_AUTHKEY: ' > "${tty_dev}"
    stty -echo < "${tty_dev}" 2>/dev/null || true
    IFS= read -r entered_key < "${tty_dev}"
    stty echo < "${tty_dev}" 2>/dev/null || true
    printf '\n' > "${tty_dev}"
    if [ -z "${entered_key}" ]; then
      printf '[WARN]  🌱 Empty value — try again.\n' > "${tty_dev}"
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

# Bootstrap module: the Core does not hard-code which module bootstraps the
# Runtime. It asks the Garden Client, persists the answer to
# state/runtime.yaml, then provisions it through the exact same lifecycle
# any future module uses, driven entirely by ./core.
./core resolve-bootstrap
bootstrap_module="$(sed -n 's/^bootstrap_module: \(.*\)$/\1/p' state/runtime.yaml)"
bootstrap_status="$(sed -n 's/^bootstrap_status: \(.*\)$/\1/p' state/runtime.yaml)"
if [ -n "${bootstrap_module}" ] && [ "${bootstrap_status}" != "READY" ]; then
  log_info "Provisioning bootstrap module: ${bootstrap_module}"
  ./core install "${bootstrap_module}"
else
  log_info "Bootstrap module already READY."
fi

echo
log_info "Stack status:"
compose_cmd ps

echo
echo "[INFO]  🚀 Available within your tailnet:"
compose_cmd exec -T tailscale tailscale serve status

echo
log_info "Module status:"
./core list

echo
log_info "Next steps (run from the base folder, next to ./sprout):"
echo "    1) Open the URL above from a device on the tailnet"
echo "    2) Connect with:"
echo "         WebSocket URL: wss://<your-fqdn>/"
echo "         Token: $(sed -n 's/^OPENCLAW_GATEWAY_TOKEN=//p' .env)"
echo "    3) Approve the device pairing:"
echo "         ./sprout auth <UUID-shown-by-the-dashboard>"
echo "    4) Manage modules any time with:"
echo "         ./sprout search | ./sprout list | ./sprout status | ./sprout install <module>"
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

# logs.sh [service...] — with no arguments, follows every service (Core +
# installed modules); with names, follows just those (docker compose logs -f
# accepts zero or more service names natively). One script instead of a
# separate logs-openclaw.sh/logs-tailscale.sh/logs-<module>.sh per service.
cat > logs.sh <<'EOF_LOGS'
#!/bin/sh
set -eu
docker compose -f docker-compose.yml -f docker-compose.modules.yml logs -f "$@"
EOF_LOGS
chmod +x logs.sh

cat > auth.sh <<'EOF_AUTH'
#!/bin/sh
set -eu

if [ $# -eq 0 ]; then
  echo "[INFO]  🌱 Devices pending approval:"
  docker compose -f docker-compose.yml -f docker-compose.modules.yml exec openclaw openclaw devices list
  echo
  echo "Usage: ./sprout auth <uuid>"
  exit 0
fi

docker compose -f docker-compose.yml -f docker-compose.modules.yml exec openclaw openclaw devices approve "$1"
EOF_AUTH
chmod +x auth.sh

# token.sh [regen] — with no arguments, prints the currently configured
# OPENCLAW_GATEWAY_TOKEN; with "regen", writes a fresh one to .env and
# recreates openclaw so it takes effect. Duplicates generate_secret() from
# install.sh on purpose: this script must keep working standalone, without
# depending on the generator that produced it.
cat > token.sh <<'EOF_TOKEN'
#!/bin/sh
set -eu

compose_cmd() {
  docker compose -f docker-compose.yml -f docker-compose.modules.yml "$@"
}

env_value() {
  sed -n "s/^$1=//p" .env 2>/dev/null | head -n 1
}

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
  weak_seed="$(date +%s 2>/dev/null)$$$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "sprout-fallback")"
  printf '%s' "${weak_seed}" | cksum | tr -d ' \n'
}

action="${1:-show}"

case "${action}" in
  show)
    echo "[INFO]  🌱 OPENCLAW_GATEWAY_TOKEN: $(env_value OPENCLAW_GATEWAY_TOKEN)"
    ;;
  regen)
    new_token="$(generate_secret 48)"
    env_tmp=".env.tmp"
    sed "s#^OPENCLAW_GATEWAY_TOKEN=.*#OPENCLAW_GATEWAY_TOKEN=${new_token}#" .env > "${env_tmp}"
    mv "${env_tmp}" .env
    echo "[WARN]  🌱 Any already-connected client will need this new token to reconnect."
    echo "[INFO]  🌱 OPENCLAW_GATEWAY_TOKEN: ${new_token}"
    echo "[INFO]  🌱 Recreating openclaw to apply it..."
    compose_cmd up -d --force-recreate openclaw
    ;;
  *)
    echo "Usage: ./sprout token [regen]" >&2
    exit 1
    ;;
esac
EOF_TOKEN
chmod +x token.sh

# send.sh — backs "./sprout send onboard <params>". A direct, non-interactive
# passthrough to `openclaw onboard` inside the container: send always writes
# one ready-made command line, it never runs the interactive wizard, which is
# why --non-interactive is forced regardless of what the caller passes.
# Strict allowlist on purpose — only "onboard" is known here. Every other
# openclaw subcommand (setup, configure, doctor, ...) is refused with a
# pointer to run it manually against the container instead, since those
# haven't been vetted for safe passthrough the way onboard has (see
# garden/tinyllama/module.sh's module_register for the kind of onboard
# quirks that ARE already accounted for).
cat > send.sh <<'EOF_SEND'
#!/bin/sh
set -eu

compose_cmd() {
  docker compose -f docker-compose.yml -f docker-compose.modules.yml "$@"
}

subcommand="${1:-}"

case "${subcommand}" in
  "")
    echo "Usage: ./sprout send onboard [params...]" >&2
    exit 1
    ;;
  onboard)
    shift
    compose_cmd exec openclaw openclaw onboard --non-interactive "$@"
    ;;
  *)
    echo "[WARN]  🌱 './sprout send' only supports 'onboard'. Other openclaw commands require manual intervention directly on the container:" >&2
    echo "    docker compose exec openclaw openclaw ${subcommand} ..." >&2
    exit 1
    ;;
esac
EOF_SEND
chmod +x send.sh

cat > inspect.sh <<'EOF_INSPECT'
#!/bin/sh
set -eu

compose_cmd() {
  docker compose -f docker-compose.yml -f docker-compose.modules.yml "$@"
}

echo "[INFO]  🌱 Containers:"
compose_cmd ps
echo

# Generic on purpose: container names are discovered from whatever is
# actually running (Core + installed modules), never hard-coded, so a new
# module never requires touching this script.
echo "[INFO]  🌱 Internal IPs:"
for cid in $(compose_cmd ps -q); do
  cname="$(docker inspect -f '{{.Name}}' "${cid}" 2>/dev/null | sed 's#^/##')"
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${cid}" 2>/dev/null)"
  printf "  %-22s %s\n" "${cname:-?}" "${ip:-(no IP)}"
done
echo

echo "[INFO]  🌱 Tailscale serve status:"
compose_cmd exec -T tailscale tailscale serve status 2>/dev/null || echo "(serve not configured)"
echo

echo "[INFO]  🌱 Tailscale node status:"
compose_cmd exec -T tailscale tailscale status 2>/dev/null | head -10 || echo "(tailscale did not respond)"
echo

echo "[INFO]  🌱 Modules:"
./core list
EOF_INSPECT
chmod +x inspect.sh

cat > health.sh <<'EOF_HEALTH'
#!/bin/sh
set -eu

compose_cmd() {
  docker compose -f docker-compose.yml -f docker-compose.modules.yml "$@"
}

echo "[INFO]  🌱 Health (through internal nginx):"
compose_cmd exec tailscale wget -qO- http://127.0.0.1:80/healthz || true
echo

echo "[INFO]  🌱 Readiness (through internal nginx):"
compose_cmd exec tailscale wget -qO- http://127.0.0.1:80/readyz || true
echo

echo "[INFO]  🌱 Module health:"
./core doctor
EOF_HEALTH
chmod +x health.sh

# HELP.md — the local command reference shown by "./sprout help". Fully
# static: generated once, right here, from this exact command set, and
# never touched by network activity. Re-running ./install.sh regenerates
# it, so it always matches whatever commands this version of the stack
# actually has.
cat > HELP.md <<'EOF_HELP_MD'
# Sprout — Command Reference

## Help
- `./sprout help [-o]` — Show this local reference. `-o` shows the extended
  online documentation (HOWTO.md from the project repository) instead —
  it does not replace or modify this file.

## Lifecycle
- `./sprout start | stop | restart | recreate`
- `./sprout logs [service...]` — Follow logs (Core services and/or installed modules)
- `./sprout inspect` — Internal IPs, Tailscale status, module status
- `./sprout health` — Health/readiness checks + module doctor
- `./sprout auth [uuid]` — List/approve Control UI device pairing
- `./sprout token [regen]` — Show, or regenerate, the OpenClaw gateway token
- `./sprout send onboard <params>` — Non-interactive passthrough to `openclaw onboard`
  inside the container. Only `onboard` is supported — other openclaw commands
  require manual intervention directly on the container.

## Garden + Module Manager
- `./sprout update` — Refresh the local Garden index cache
- `./sprout search [query]` — List modules published in the Garden
- `./sprout info <module>` — Show a module's Garden metadata
- `./sprout install <module>` — Resolve dependencies, download, and provision <module>
- `./sprout remove <module>` — Stop <module> and remove it from the Runtime
- `./sprout list` — Installed modules and their current status
- `./sprout status [module]` — Runtime status, or one module's status
- `./sprout doctor` — Re-validate every READY module
EOF_HELP_MD

# help.sh — backs "./sprout help [-o]".
#   ./sprout help      cats the static HELP.md above. No network, ever.
#   ./sprout help -o   clones HOWTO.md from the project repository's "main"
#                       branch (not "garden", which only holds module
#                       content) and shows that instead, caching it to
#                       state/HOWTO_ONLINE.md for an offline fallback. It
#                       never touches HELP.md — the two coexist. The git
#                       activity itself is never shown to the user, only a
#                       one-line "checking for updates" notice.
cat > help.sh <<'EOF_HELP'
#!/bin/sh
set -eu

HELP_FILE="HELP.md"
ONLINE_CACHE="state/HOWTO_ONLINE.md"

env_value() {
  sed -n "s/^$1=//p" .env 2>/dev/null | head -n 1
}

mode="${1:-}"

if [ "${mode}" = "-o" ]; then
  repo_url="$(env_value GARDEN_REPOSITORY)"
  [ -n "${repo_url}" ] || repo_url="https://github.com/paalbarr/sprout.git"

  tmp_dir="${TMPDIR:-/tmp}/sprout-help-$$"
  cleanup() {
    rm -rf "${tmp_dir}"
  }
  trap cleanup EXIT

  echo "[INFO]  🌱 Checking for documentation updates..."

  fetched=0
  rm -rf "${tmp_dir}"
  if command -v git >/dev/null 2>&1 \
      && git clone --quiet --depth 1 --single-branch --branch main "${repo_url}" "${tmp_dir}" >/dev/null 2>&1 \
      && [ -f "${tmp_dir}/HOWTO.md" ]; then
    mkdir -p state
    cp "${tmp_dir}/HOWTO.md" "${ONLINE_CACHE}"
    fetched=1
  fi

  if [ "${fetched}" -eq 0 ]; then
    if [ -f "${ONLINE_CACHE}" ]; then
      echo "[WARN]  🌱 Could not reach the documentation repository — showing the last cached online copy." >&2
    else
      echo "[FATAL] 🌱 Could not download the online documentation and no cached copy exists." >&2
      exit 1
    fi
  fi

  echo
  cat "${ONLINE_CACHE}"
  exit 0
fi

if [ ! -f "${HELP_FILE}" ]; then
  echo "[FATAL] 🌱 ${HELP_FILE} not found. Re-run ./install.sh to regenerate it." >&2
  exit 1
fi

echo
cat "${HELP_FILE}"
EOF_HELP
chmod +x help.sh

log_info "Helper scripts created (start/stop/restart/recreate/logs/auth/token/send/inspect/health/help)"

log_info "Stack generated in ./${STACK_DIR}"

# ------------------------------------------------------------------------------
# ./sprout — the single entry point, written next to install.sh (one level
# above ${STACK_DIR}, not inside it). A thin dispatcher: every command `cd`s
# into ${STACK_DIR} internally, so the user never has to.
# ------------------------------------------------------------------------------
cd ..

cat > sprout <<EOF_SPROUT_WRAPPER
#!/bin/sh
set -eu

STACK_DIR="${STACK_DIR}"

log_fatal() {
  printf '[FATAL] 🌱 %s\n' "\$1" >&2
  exit 1
}

[ -d "\${STACK_DIR}" ] || log_fatal "'\${STACK_DIR}/' not found next to this script. Run ./install.sh first."

usage() {
  cat <<'EOF_USAGE'
Usage: ./sprout <command> [args]

Help:
  help    [-o]            Show the local command documentation; pass -o to view
                           the extended online documentation instead (does not
                           replace or refresh the local copy)

Lifecycle:
  start | stop | restart | recreate
  logs    [service...]   Follow logs (Core services and/or installed modules)
  inspect                 Internal IPs, Tailscale status, module status
  health                  Health/readiness checks + module doctor
  auth    [uuid]          List/approve Control UI device pairing
  token   [regen]         Show, or regenerate, the OpenClaw gateway token
  send    onboard <params>
                           Non-interactive passthrough to 'openclaw onboard'
                           inside the container. Only 'onboard' is supported —
                           other openclaw commands (setup, configure, doctor,
                           ...) require manual intervention on the container.

Garden + Module Manager:
  update                  Refresh the local Garden index cache
  search  [query]         List modules published in the Garden
  info    <module>        Show a module's Garden metadata
  install <module>        Resolve dependencies, download, and provision <module>
  remove  <module>        Stop <module> and remove it from the Runtime
  list                    Installed modules and their current status
  status  [module]        Runtime status, or one module's status
  doctor                  Re-validate every READY module
EOF_USAGE
}

command_name="\${1:-}"
[ -n "\${command_name}" ] || {
  usage
  exit 1
}
shift

case "\${command_name}" in
  help)           ( cd "\${STACK_DIR}" && exec ./help.sh "\$@" ) ;;
  start)          ( cd "\${STACK_DIR}" && exec ./start.sh ) ;;
  stop)           ( cd "\${STACK_DIR}" && exec ./stop.sh ) ;;
  restart)        ( cd "\${STACK_DIR}" && exec ./restart.sh ) ;;
  recreate)       ( cd "\${STACK_DIR}" && exec ./recreate.sh ) ;;
  logs)           ( cd "\${STACK_DIR}" && exec ./logs.sh "\$@" ) ;;
  inspect)        ( cd "\${STACK_DIR}" && exec ./inspect.sh ) ;;
  health)         ( cd "\${STACK_DIR}" && exec ./health.sh ) ;;
  auth)           ( cd "\${STACK_DIR}" && exec ./auth.sh "\$@" ) ;;
  token)          ( cd "\${STACK_DIR}" && exec ./token.sh "\$@" ) ;;
  send)           ( cd "\${STACK_DIR}" && exec ./send.sh "\$@" ) ;;
  update|search|info|install|remove|list|status|doctor)
    ( cd "\${STACK_DIR}" && exec ./core "\${command_name}" "\$@" )
    ;;
  *)
    usage
    exit 1
    ;;
esac
EOF_SPROUT_WRAPPER
chmod +x sprout

log_info "sprout (root dispatcher) created — run everything from this folder, no cd needed."

# ------------------------------------------------------------------------------
# Quick-access symlinks, next to ./sprout — so the folders/files OpenClaw
# itself cares about are reachable without ever going into ${STACK_DIR}:
#   ./workspace         -> ${STACK_DIR}/openclaw-data/workspace  (agent read/write area)
#   ./agents             -> ${STACK_DIR}/openclaw-data/agents     (per-agent state, auth profiles)
#   ./conf/openclaw.json -> ${STACK_DIR}/openclaw-data/openclaw.json (behavior config)
# Relative targets on purpose, so these keep working if the whole project
# folder is moved/renamed as a unit. -f so re-running ./install.sh refreshes
# them instead of failing if they already exist.
# ------------------------------------------------------------------------------
ln -sf "${STACK_DIR}/openclaw-data/workspace" workspace
ln -sf "${STACK_DIR}/openclaw-data/agents" agents
mkdir -p conf
ln -sf "../${STACK_DIR}/openclaw-data/openclaw.json" conf/openclaw.json
log_info "Quick-access links created: ./workspace, ./agents, ./conf/openclaw.json"
echo
log_info "Installation finished 😎"
echo
log_info "To start:"
echo "    ./sprout start"
echo
log_info "To help:"
echo "    ./sprout help"
echo