# 📖 Daily Commands

The following helper scripts are generated automatically inside the `openclaw-stack` directory.

| Command | Description |
|---------|-------------|
| `./start.sh` | Pull Docker images, start the stack and configure `tailscale serve`. |
| `./stop.sh` | Stop all running containers. |
| `./restart.sh` | Restart the complete stack and reconfigure Tailscale Serve. |
| `./recreate.sh` | Recreate all containers from scratch. Useful after configuration changes. |
| `./logs.sh` | Show combined logs from every service. |
| `./logs-openclaw.sh` | Show only OpenClaw logs. |
| `./logs-tailscale.sh` | Show only Tailscale logs. |
| `./inspect.sh` | Display container status, internal IP addresses and Tailscale information. |
| `./health.sh` | Verify the OpenClaw health and readiness endpoints. |
| `./approve-device.sh` | List pending devices or approve a new browser pairing. |

---

# 🔍 Troubleshooting

## ⚠️ Gateway does not start

**Message**

```text
Gateway start blocked: missing gateway.mode
```

**Solution**

Sprout already generates `openclaw.json` with:

```json
"mode": "local"
```

If you modified the configuration manually, regenerate the stack or restore the original file.

---

## ⚠️ Tailscale node already exists

**Message**

```text
node name already exists
```

or

```text
suffix -1 added
```

**Solution**

A machine with the same hostname already exists in your Tailnet.

Delete the old node from:

https://login.tailscale.com/admin/machines

Then recreate the environment:

```bash
./recreate.sh
```

---

## ⚠️ Browser cannot connect

**Message**

```text
WebSocket disconnected (1006)
```

**Solution**

Verify that the WebSocket URL is exactly:

```text
wss://<your-tailnet-host>/
```

- Use **wss://**
- Do **not** use `ws://`
- Do **not** specify a port
- Keep the trailing `/`

---

## ⚠️ Mixed Content blocked

**Message**

```text
Mixed Content
```

**Solution**

This usually means the browser is trying to connect through an insecure WebSocket.

Always use:

```text
wss://<your-tailnet-host>/
```

Never:

```text
ws://...
```

---

## ⚠️ Device pairing required

This is expected whenever a new browser connects.

List pending devices:

```bash
./approve-device.sh
```

Approve a device:

```bash
./approve-device.sh <device-uuid>
```

Reconnect the browser after approval.

---

## ⚠️ Placeholder values detected

If Sprout refuses to start because placeholder values are still present, edit:

```text
openclaw-stack/.env
```

Replace:

- `OPENCLAW_GATEWAY_TOKEN`
- `TS_AUTHKEY`

and provide at least one provider API key:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`

---

# 💡 Useful Tips

- Use `./inspect.sh` whenever you are unsure about the current stack status.
- Use `./logs-openclaw.sh` first when debugging OpenClaw issues.
- Use `./logs-tailscale.sh` for connectivity or Tailnet-related problems.
- If something looks inconsistent after changing configuration files, `./recreate.sh` is usually the fastest way to start with a clean environment.