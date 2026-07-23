# 🎯 Sprout Architecture

`sprout.sh` creates a self-contained OpenClaw stack in a local directory. The
default target is `./openclaw-stack`; override it with `STACK_DIR` when running
the script.

### Network model

The generated Compose project creates a dedicated bridge network named
`openclaw_net` by default (`172.30.10.0/24`). It assigns fixed addresses to
the core services:

| Service | Default address | Role |
| --- | --- | --- |
| `tailscale` | `172.30.10.10` | Tailnet identity and the only external ingress |
| `openclaw` | `172.30.10.20` | OpenClaw gateway and Control UI |
| `redis` | `172.30.10.30` | Redis state store |

Nginx uses `network_mode: "service:tailscale"`, so it shares Tailscale's
network namespace. Nginx listens only on port `80` in that namespace;
`tailscale serve` exposes it as HTTPS on port `443` to the tailnet. The Compose
file publishes no host ports.

## Generated project layout

Running the script produces the following structure. Persistent directories
are marked with **(persistent)**.

```text
openclaw-stack/
├── .env                         # Sensitive runtime settings; created only when absent
├── docker-compose.yml           # Services, network, fixed addresses, and volumes
├── README.txt                   # Operational guide generated with the stack
├── start.sh                     # Pull images, start services, and configure tailscale serve
├── stop.sh                      # Stop the Compose stack
├── restart.sh                   # Stop and start the stack again
├── recreate.sh                  # Force-recreate containers, then run start.sh
├── logs.sh                      # Stream logs from all services
├── logs-openclaw.sh             # Stream OpenClaw logs only
├── logs-tailscale.sh            # Stream Tailscale logs only
├── inspect.sh                   # Show container, network, and Tailscale status
├── health.sh                    # Request /healthz and /readyz through internal Nginx
├── approve-device.sh            # List or approve OpenClaw Control UI devices
├── nginx/
│   └── openclaw.conf            # Nginx proxy and WebSocket configuration
├── openclaw-data/               # OpenClaw configuration and state **(persistent)**
│   └── openclaw.json            # Gateway settings and trusted proxy configuration
├── redis-data/                  # Redis append-only data **(persistent)**
└── tailscale/
    └── state/                   # Tailscale node state **(persistent)**
```

## Generated files and responsibilities

| File | Created or updated by Sprout | Purpose |
| --- | --- | --- |
| `.env` | Created only if missing | Holds timezone, gateway token, Tailscale auth key, hostname, and AI provider keys. |
| `docker-compose.yml` | Recreated on each run | Defines OpenClaw, Redis, Tailscale, Nginx, volumes, and the isolated bridge network. |
| `openclaw-data/openclaw.json` | Recreated on each run | Configures local gateway mode, LAN binding, trusted proxies, and allowed Control UI origins. |
| `nginx/openclaw.conf` | Recreated on each run | Proxies HTTP and WebSocket traffic to OpenClaw and exposes health endpoints internally. |
| `start.sh` | Recreated on each run | Validates placeholders, starts the stack, waits for Tailscale, and runs `tailscale serve`. |
| `README.txt` | Recreated on each run | Provides stack-specific setup, operation, portability, and troubleshooting guidance. |
| Other helper scripts | Recreated on each run | Provide lifecycle, logs, inspection, health, and device-approval commands. |

## Persistent data

The script preserves the following directories across `docker compose down` and
container recreation:

- `openclaw-data/` for OpenClaw configuration and application state.
- `redis-data/` for Redis append-only persistence.
- `tailscale/state/` for the registered Tailscale node identity and state.

Deleting these directories resets their respective components. Keep `.env`
private: it contains authentication credentials and provider API keys.

## Request flow

1. A client already connected to the tailnet opens the Tailscale HTTPS URL.
2. Tailscale terminates the tailnet-facing HTTPS connection and forwards traffic
   to `127.0.0.1:80` through `tailscale serve`.
3. Nginx forwards HTTP and WebSocket traffic to `openclaw:18789` through Docker
   service discovery.
4. OpenClaw reads or writes runtime state through Redis.
5. The Control UI device-pairing flow is completed with `approve-device.sh`.

## Configuration inputs

The script accepts environment variables before execution. These change the
generated configuration without requiring manual edits to `docker-compose.yml`.

| Variable | Default | Effect |
| --- | --- | --- |
| `STACK_DIR` | `openclaw-stack` | Output directory for the generated stack. |
| `TZ_VALUE` | `America/Santiago` | Timezone stored in `.env`. |
| `TS_HOSTNAME` | `openclaw-docker` | Tailscale node hostname. |
| `DOCKER_NETWORK_NAME` | `openclaw_net` | Dedicated Docker network name. |
| `DOCKER_SUBNET` | `172.30.10.0/24` | Docker network subnet. |
| `TS_FIXED_IP` | `172.30.10.10` | Tailscale container address. |
| `OPENCLAW_FIXED_IP` | `172.30.10.20` | OpenClaw container address. |
| `REDIS_FIXED_IP` | `172.30.10.30` | Redis container address. |
| `OPENCLAW_VERSION` | `latest` | OpenClaw image tag. |

For example:

```bash
STACK_DIR=my-openclaw \
OPENCLAW_VERSION=v1.2.3 \
./sprout.sh
```
