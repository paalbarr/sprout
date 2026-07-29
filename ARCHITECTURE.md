# 🎯 SPR-003 — Sprout Architecture Model Explained

| Field | Value |
|-------|-------|
| **Document ID** | SPR-003 |
| **Version** | 2.0 |
| **Status** | Final |
| **Authors** | Pablo Albarrán |
| **Audience** | Core maintainers, module developers, infrastructure engineers, contributors, AI coding agents |
| **Last Updated** | 2026-07-29 |

---

## Important notice

`install.sh` generates a self-contained OpenClaw stack, split into two parts
in the current directory:

- `./stack/` — the portable Docker Compose Core (OpenClaw, Redis, Tailscale,
  Nginx) plus everything the Garden Client + Module Manager needs. Default
  location; override with `STACK_DIR` when running the script.
- `./sprout` — a thin dispatcher placed **next to** `install.sh`, one level
  above `./stack/`. It is the single entry point for every command below.
  It `cd`s into `./stack` internally, so the user never has to — everything
  is run from the base folder.

# 1. Two-tier CLI architecture

Sprout is split into a thin root dispatcher and the engine it drives. Nothing
in `./sprout` itself talks to Docker or the Garden — it only forwards.

```text
./sprout <command>
   │
   ├── lifecycle commands (start, stop, restart, recreate, logs, inspect,
   │   health, auth, token, send, help)
   │        │
   │        └── cd stack/ && exec ./<command>.sh   (standalone scripts)
   │
   └── Garden + Module Manager commands (update, search, info, install,
       remove, list, status, doctor)
            │
            └── cd stack/ && exec ./core <command>  (the engine)
```

`./stack/core` also exposes one internal-only command, `resolve-bootstrap`,
used exclusively by `start.sh` — it is not in the root dispatcher's `case`
statement and is not meant to be typed by hand.

Every lifecycle script (`start.sh`, `stop.sh`, …) and `core` itself define
their own `log_info`/`log_warn`/`log_error`/`log_fatal` and `compose_cmd()`
helpers, so each is a fully standalone POSIX `sh` script that keeps working
even if copied out and run on its own — nothing depends on `install.sh` at
runtime.

# 2. Network model

The generated Compose project creates a dedicated bridge network
(`172.30.10.0/24` by default) with fixed addresses for the Core services:

| Service | Container name | Default address | Role |
| --- | --- | --- | --- |
| `tailscale` | `sprout-tailscale` | `172.30.10.10` | Tailnet identity and the only external ingress |
| `openclaw` | `sprout-openclaw` | `172.30.10.20` | OpenClaw gateway and Control UI (port `18789`, not published) |
| `redis` | `sprout-redis` | `172.30.10.30` | Redis state store |
| `nginx` | `sprout-nginx` | — (shares Tailscale's namespace) | Internal reverse proxy |

Two independent names control the network:

- `sprout_net` — the **fixed** internal Compose YAML key used in every
  compose file across Core and modules alike. It never changes, so modules
  never need to know or care what the real Docker network is called.
- `DOCKER_NETWORK_NAME` (`.env`, default `sprout-stack`) — the **actual**
  Docker network name, applied through a `name:` override on the
  `sprout_net` key. This split avoids relying on `${VAR}` interpolation
  working inside YAML *keys* (only reliably supported in *values*).

Nginx uses `network_mode: "service:tailscale"`, so it shares Tailscale's
network namespace. It listens only on port `80` in that namespace;
`tailscale serve` (configured by `start.sh` through the Tailscale CLI, not
through Compose's `TS_SERVE_CONFIG`, which isn't always substituted
correctly) exposes it as HTTPS on port `443` to the tailnet. The Compose
file publishes no host ports at all.

Module containers (e.g. `sprout-ollama`) join the same `sprout_net` network
via their own `compose.yaml` fragment, without fixed addresses — they are
reachable by every other container through Docker's built-in service-name
DNS instead.

# 3. Garden module system

A **Garden** is just a git repository with an `index.yaml` at the root of a
given branch. `GARDEN_REPOSITORY`/`GARDEN_BRANCH` (`.env`, default the
project's own repo, branch `garden`) point the Garden Client at it — a fork
or a private/enterprise Garden works without touching the Core at all.

## 3.1 Index format

```yaml
modules:
  - name: tinyllama
    version: 1.0.0
    description: ...
    repository: https://github.com/paalbarr/sprout.git
    branch: garden
    path: tinyllama
    bootstrap: true
    depends:
      - ollama
  - name: ollama
    version: 1.0.0
    description: ...
    repository: https://github.com/paalbarr/sprout.git
    branch: garden
    path: ollama
```

This is a Sprout-owned contract, not arbitrary YAML: 2-space indent per
`- name:` list item, 4-space indent for that module's own fields, 6-space
indent for `depends:` items. `garden_flat()` (a hand-rolled `awk` parser
inside `core`) is the exact contract this file must satisfy — there is no
general YAML library dependency.

| Field | Meaning |
| --- | --- |
| `name` | Unique module identifier |
| `version` | Informational only — the Core provisions whatever the pinned branch/path currently contains |
| `description` | Shown by `search`/`info` |
| `repository` | Git URL the module's files are cloned from (may differ per module) |
| `branch` | Branch to clone (defaults to `main` if omitted) |
| `path` | Directory inside that branch containing `module.yaml`, optionally `compose.yaml`, and `module.sh` (defaults to the module name if omitted) |
| `bootstrap` | `true` on exactly one module — the Core provisions it, and its full dependency graph, automatically on the first `./sprout start` |
| `depends` | Other modules (by name) that must reach `READY` before this one is provisioned |

## 3.2 Dependency resolution

`resolve_install_order()` computes the install order for a target module in
two passes, both implemented iteratively with temp files (no recursive
shell functions — POSIX `sh` has no variable scoping, so a recursive
resolver would silently corrupt in-flight state):

1. **BFS closure** — starting from the target, walks `depends:` edges
   breadth-first to collect every reachable module into a `seen` set.
2. **Round-based topological sort** — repeatedly places every not-yet-placed
   module whose dependencies are all already placed, until no more progress
   is made. Anything left unplaced means the Garden index has a circular
   dependency, and installation aborts with the unresolved modules listed.

## 3.3 Module lifecycle

`provision_one_module()` drives one module through, in order:

**Resolve → Install → Configure → Provision → Register (optional) → Validate**

| Phase | Hook | Notes |
| --- | --- | --- |
| Install | `module_install()` | Typically pulls the module's Docker image |
| Configure | `module_configure()` | Local prep (e.g. creating a data directory) before the container starts |
| Provision | `module_provision()` | Starts the container / does the actual work; `docker-compose.modules.yml` is regenerated right before this and before Install |
| Register | `module_register()` — **optional** | Only for modules that integrate a capability into OpenClaw (e.g. registering an inference provider). Modules without one (like `ollama`, pure infrastructure) skip this step entirely |
| Validate | `module_validate()` | Confirms the module is actually healthy before it's marked `READY` |
| Remove | `module_remove()` | Used by `./sprout remove`, not part of install |

Module status, tracked in `state/modules.yaml`, moves through:
`NOT_INSTALLED → RESOLVING → INSTALLING → CONFIGURING → PROVISIONING →
[REGISTERING] → VALIDATING → READY`, or `FAILED` if any phase returns
non-zero — `log_fatal` aborts immediately, so a module never gets recorded
`READY` on a partial success.

`module.sh` is **sourced** (`. modules/<name>/module.sh`), never executed,
directly into the Core's own shell process — so its hooks can freely call
`log_info`/`log_warn`/`log_error`/`log_fatal` and `compose_cmd()` exactly as
the Core does. Between modules, all lifecycle function names are `unset -f`
first, so a module without e.g. `module_register` can't accidentally
inherit one left over from a previously-sourced module in the same run.

## 3.4 Module compose fragments

A module's `compose.yaml` (not `.yml` — the Core only looks for `.yaml`) may
be written either as:

- a bare service fragment (starts directly with `  <service>:`), or
- a full standalone compose file (has its own top-level `services:` key).

`regenerate_modules_compose()` accepts either: it strips any leaked
top-level `services:` line, then normalizes indentation (relative to the
smallest indent found) so the service key always lands correctly nested
under the single `services:` line the Core writes — regardless of whether
the module author indented at 0, 2, or 4 spaces, and regardless of CRLF
line endings. Modules that don't need their own container (e.g. one that
rides entirely on another module's engine) simply ship no `compose.yaml` —
this is expected, not an error, though the Core logs a warning naming the
module so a *missing but expected* file is still traceable instead of
surfacing only as a cryptic Docker "no such service" error downstream.

`docker-compose.modules.yml` is regenerated from every module **not** in
`NOT_INSTALLED` state (so a `FAILED` module's fragment stays in the overlay
for retry/debugging until explicitly `remove`d), and is merged with the
Core's own `docker-compose.yml` via `docker compose -f ... -f ...` — never
edited by hand.

## 3.5 Reference Garden content

Published under `garden/` in this repository (branch `garden`):

- **`ollama`** — pure infrastructure. Owns the Ollama container (no fixed
  IP — reachable as `ollama` via Docker's service-name DNS), no dependencies,
  no `module_register` hook.
- **`tinyllama`** — the reference bootstrap module (`bootstrap: true`,
  `depends: [ollama]`). Owns no container of its own; it pulls the
  TinyLlama model into the already-running `ollama` service and registers
  it as an OpenClaw provider via `openclaw onboard --auth-choice
  custom-api-key` (the `--auth-choice ollama` flow doesn't respect
  `OLLAMA_HOST` and always probes `127.0.0.1`), then restores
  `gateway.bind` (onboard's quickstart flow forces it to loopback) and
  disables tool-calling for that model (small local models reject any
  request carrying a tools schema).

# 4. Generated project layout

```text
.
├── install.sh                    # the generator (this stays after running)
├── sprout                        # root dispatcher — the single entry point
├── workspace/                    # symlink -> stack/openclaw-data/workspace
├── agents/                       # symlink -> stack/openclaw-data/agents
├── conf/
│   └── openclaw.json             # symlink -> stack/openclaw-data/openclaw.json
└── stack/
    ├── .env                              # sensitive + Runtime config; created only when absent
    ├── docker-compose.yml                # Core services, network, fixed addresses, volumes
    ├── docker-compose.modules.yml        # generated overlay of installed modules' services
    ├── HELP.md                           # static local docs shown by `./sprout help`
    ├── core                              # Garden Client + Module Manager engine
    ├── start.sh                          # pull images, start services, resolve/provision bootstrap
    ├── stop.sh                           # stop the Compose stack (Core + modules)
    ├── restart.sh                        # stop, then start.sh
    ├── recreate.sh                       # force-recreate every container, then start.sh
    ├── logs.sh                           # stream logs from any/all services (Core or modules)
    ├── auth.sh                           # list/approve Control UI device pairing
    ├── token.sh                          # show, or regenerate, OPENCLAW_GATEWAY_TOKEN
    ├── send.sh                           # non-interactive passthrough to `openclaw onboard`
    ├── inspect.sh                        # container/IP/Tailscale/module status
    ├── health.sh                         # healthz/readyz + module doctor
    ├── help.sh                           # backs `./sprout help [-o]`
    ├── nginx/
    │   └── openclaw.conf                 # reverse proxy + WebSocket + health passthrough
    ├── openclaw-data/                    # OpenClaw's own mounted config dir (persistent)
    │   ├── openclaw.json                 # gateway settings; OpenClaw owns this after first start
    │   ├── workspace/                    # agent read/write area (its own bind mount)
    │   └── agents/                       # per-agent state, auth profiles
    ├── redis-data/                       # Redis append-only data (persistent)
    ├── tailscale/
    │   └── state/                        # Tailscale node state (persistent)
    ├── modules/
    │   └── <name>/                       # downloaded module.yaml / compose.yaml / module.sh
    ├── garden/
    │   └── index.yaml                    # cached Garden index (refreshed by `./sprout update`)
    └── state/
        ├── runtime.yaml                  # overall status + bootstrap_module/bootstrap_status
        ├── modules.yaml                  # per-module {name, version, status, updated}
        ├── HOWTO_ONLINE.md               # cache for `./sprout help -o` (never touches HELP.md)
        └── logs/
            └── <module>.log              # last install attempt for that module, overwritten each time
```

# 5. Generated files and responsibilities

| File | Created or updated | Purpose |
| --- | --- | --- |
| `.env` | Created only if missing | Timezone, gateway token, Tailscale auth key, hostname, AI provider keys, network/version settings, Garden repository/branch. |
| `docker-compose.yml` | Recreated on each run | Core services (OpenClaw, Redis, Tailscale, Nginx), network, fixed addresses, volumes. Byte-identical output for the same `.env`. |
| `docker-compose.modules.yml` | Regenerated on every `install`/`remove` | Overlay of every non-`NOT_INSTALLED` module's `compose.yaml`. |
| `openclaw-data/openclaw.json` | Created only if missing | Local gateway mode, LAN binding, trusted proxies, allowed Control UI origins. Never clobbered afterwards — OpenClaw itself owns it once running. |
| `nginx/openclaw.conf` | Recreated on each run | Proxies HTTP/WebSocket to `openclaw:18789`; exposes `/healthz` and `/readyz` internally. |
| `core` | Recreated on each run | The Garden Client + Module Manager engine. |
| `HELP.md` | Recreated on each run | Static command reference, always matching this version's actual command set. |
| `start.sh` / `stop.sh` / `restart.sh` / `recreate.sh` | Recreated on each run | Core lifecycle. |
| `logs.sh` / `auth.sh` / `token.sh` / `send.sh` / `inspect.sh` / `health.sh` / `help.sh` | Recreated on each run | Lifecycle utilities, described in §6. |
| `./workspace`, `./agents`, `./conf/openclaw.json` | Created (`-f`, refreshed on every re-run) | Quick-access symlinks — see §7. |
| `state/logs/<module>.log` | Overwritten on every install attempt for that module | Install trace — see §8. |

# 6. Command reference

| Command | Backed by | Purpose |
| --- | --- | --- |
| `./sprout help [-o]` | `help.sh` | Shows local `HELP.md`; `-o` fetches and shows the extended online `HOWTO.md` instead (cached separately, never overwrites `HELP.md`) |
| `./sprout start` \| `stop` \| `restart` \| `recreate` | `start.sh` etc. | Lifecycle |
| `./sprout logs [service...]` | `logs.sh` | Follow logs for any Core service and/or installed module, or all of them with no arguments |
| `./sprout inspect` | `inspect.sh` | Containers, internal IPs, Tailscale serve/node status, module status |
| `./sprout health` | `health.sh` | `/healthz` + `/readyz` through internal Nginx, plus `./core doctor` |
| `./sprout auth [uuid]` | `auth.sh` | Lists pending Control UI device pairings, or approves one by UUID |
| `./sprout token [regen]` | `token.sh` | Shows the current `OPENCLAW_GATEWAY_TOKEN`, or generates a fresh one and recreates `openclaw` |
| `./sprout send onboard <params>` | `send.sh` | Non-interactive passthrough to `openclaw onboard` inside the container (`--non-interactive` always forced). Strict allowlist — only `onboard`; anything else is refused with a pointer to run it manually against the container |
| `./sprout update` | `core update` | Refreshes the cached Garden index |
| `./sprout search [query]` | `core search` | Lists modules published in the Garden |
| `./sprout info <module>` | `core info` | Shows one module's Garden metadata + current Runtime status |
| `./sprout install <module>` | `core install` | Resolves the dependency graph, downloads, and provisions `<module>` (and every unmet dependency) |
| `./sprout remove <module>` | `core remove` | Stops `<module>` and removes it from the Runtime |
| `./sprout list` | `core list` | Every known module and its current status |
| `./sprout status [module]` | `core status` | Full Runtime state, or one module's status |
| `./sprout doctor` | `core doctor` | Re-validates every `READY` module |

On the first `./sprout start`, the Core asks the Garden which module is
`bootstrap: true` (`core resolve-bootstrap`, persisted to
`state/runtime.yaml`) and installs it — together with its full dependency
graph — through the exact same lifecycle any other module uses. No module
identity is hard-coded in the Core.

# 7. Quick-access symlinks

Three symlinks are created next to `./sprout`, so the parts of OpenClaw's
own data a developer actually cares about are reachable without ever
entering `./stack/`:

| Symlink | Target | What it is |
| --- | --- | --- |
| `./workspace` | `stack/openclaw-data/workspace` | The agent's own read/write area |
| `./agents` | `stack/openclaw-data/agents` | Per-agent state, incl. `auth-profiles.json` |
| `./conf/openclaw.json` | `stack/openclaw-data/openclaw.json` | Gateway behavior config |

Deliberately symlinks, not additional Docker bind mounts: both `workspace`
and `agents` already live inside `openclaw-data`, which is already bind
mounted into the container (`./openclaw-data:/home/node/.openclaw`) — a
symlink is pure host-side convenience with zero Docker Desktop file-sharing
implications, and there is exactly one canonical copy of each directory
(no risk of two mounts drifting out of sync). `install.sh` pre-creates
`openclaw-data/workspace` and `openclaw-data/agents` (normally created by
OpenClaw itself at runtime) so these symlinks resolve immediately, not only
after the first `./sprout start`. All three use relative targets, so they
keep working if the whole project folder is moved or renamed as a unit, and
`ln -sf` means re-running `./install.sh` refreshes them harmlessly.

# 8. Per-module install logs

Every `./sprout install <module>` attempt writes a fresh trace to
`state/logs/<module>.log` — truncated and overwritten at the start of each
attempt (no versioning, no accumulation across retries). The path is logged
as the very first line written, and again at the end, whether the attempt
succeeded or failed:

- On success: `<module> is READY.` followed by `Install log saved to:
  state/logs/<module>.log`.
- On failure: `log_fatal` mirrors its message into the log file before
  exiting, then prints the log's location to the terminal — so the last
  thing before an install error is always where to go read the full trace.

Implementation note: `log_info`/`log_warn`/`log_error`/`log_fatal` inside
`core` write to the terminal as before, and additionally mirror the same
line into `state/logs/<module>.log` whenever a module install is in
progress (an internal `MODULE_LOG_FILE` variable, empty outside of an
active install).

# 9. Dependency checks

`install.sh` checks its own prerequisites before generating anything,
printing one line per component:

| Dependency | Required? | Behavior if missing |
| --- | --- | --- |
| `sed`, `awk`, `grep`, `git`, `docker` | Required | Generation aborts (`log_fatal`) if any is missing |
| `docker compose` (v2 plugin) | Required | Checked via `docker compose version`; same abort behavior |
| `openssl` | Optional | Falls back to a POSIX `/dev/urandom` read (`dd` + `od`) for `generate_secret()`; if neither is available, falls back further to a low-entropy time/pid-derived value with a loud warning — not cryptographically safe |

`git` is also required at runtime by the Garden Client (`core`) independently
of this startup check, since module/index downloads happen well after
`install.sh` has finished.

# 10. Persistent data

Preserved across `docker compose down` and container recreation:

- `openclaw-data/` — OpenClaw configuration and application state, including
  `workspace/` and `agents/` (each also reachable via the base-folder
  symlinks in §7).
- `redis-data/` — Redis append-only persistence.
- `tailscale/state/` — the registered Tailscale node identity and state.
- `state/` — Runtime and per-module status (`runtime.yaml`, `modules.yaml`),
  the cached Garden index reference, the online-docs cache, and per-module
  install logs (`state/logs/`).
- `modules/` — each installed module's downloaded `module.yaml`/
  `compose.yaml`/`module.sh`, re-downloaded fresh on every `install` but not
  otherwise touched.

Deleting any of these resets the corresponding component. Keep `.env`
private — it holds `OPENCLAW_GATEWAY_TOKEN`, `TS_AUTHKEY`, and provider API
keys.

# 11. Request flow

1. A client already connected to the tailnet opens the Tailscale HTTPS URL
   (`./sprout start` prints it, prefixed 🚀, once `tailscale serve` is
   configured).
2. Tailscale terminates the tailnet-facing HTTPS connection and forwards
   traffic to `127.0.0.1:80` through `tailscale serve`.
3. Nginx (sharing Tailscale's network namespace) forwards HTTP/WebSocket
   traffic to `openclaw:18789` through Docker's internal service DNS on
   `sprout_net`.
4. OpenClaw reads/writes runtime state through Redis.
5. The Control UI device-pairing flow is completed with `./sprout auth
   <uuid>`.

# 12. Configuration inputs

Environment variables read by `install.sh` before generation — set them to
change the generated configuration without hand-editing `docker-compose.yml`
afterwards:

| Variable | Default | Effect |
| --- | --- | --- |
| `STACK_DIR` | `stack` | Output directory for the generated stack |
| `TZ_VALUE` | `America/Santiago` | Timezone stored in `.env` |
| `TS_HOSTNAME` | `openclaw-docker` | Tailscale node hostname |
| `DOCKER_NETWORK_NAME` | `sprout-stack` | Actual Docker network name (the `sprout_net` Compose key stays fixed) |
| `DOCKER_SUBNET` | `172.30.10.0/24` | Docker network subnet |
| `TS_FIXED_IP` | `172.30.10.10` | Tailscale container address |
| `OPENCLAW_FIXED_IP` | `172.30.10.20` | OpenClaw container address |
| `REDIS_FIXED_IP` | `172.30.10.30` | Redis container address |
| `OPENCLAW_VERSION` | `latest` | OpenClaw image tag |
| `GARDEN_REPOSITORY` | this project's repo | Git URL the Garden index and default module sources are fetched from |
| `GARDEN_BRANCH` | `garden` | Branch holding `index.yaml` and module content |

Example:

```bash
STACK_DIR=my-openclaw \
OPENCLAW_VERSION=v1.2.3 \
GARDEN_REPOSITORY=https://github.com/myorg/my-garden.git \
./install.sh
```