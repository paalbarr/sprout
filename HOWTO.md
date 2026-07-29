# 📖 Daily Commands

This is the extended documentation shown by `./sprout help -o`. All commands
below run through `./sprout`, from the base folder — no need to enter any
subdirectory.

| Command | Description |
|---------|-------------|
| `./sprout start` | Pull Docker images, start the stack and configure `tailscale serve`. |
| `./sprout stop` | Stop all running containers. |
| `./sprout restart` | Restart the complete stack and reconfigure Tailscale Serve. |
| `./sprout recreate` | Recreate all containers from scratch. Useful after configuration changes. |
| `./sprout logs [service]` | Show combined logs, or just one service's (e.g. `openclaw`, `tailscale`). |
| `./sprout inspect` | Display container status, internal IP addresses, Tailscale information, and installed modules. |
| `./sprout health` | Verify the OpenClaw health/readiness endpoints and validate installed modules. |
| `./sprout auth` | List pending devices or approve a new browser pairing. |
| `./sprout token [regen]` | Show, or regenerate, the OpenClaw gateway token. |
| `./sprout send onboard <params>` | Non-interactive passthrough to `openclaw onboard` inside the container. |
| `./sprout help [-o]` | Show this command reference; `-o` fetches the latest online version. |

Module management (e.g. installing local-inference capabilities like Ollama)
is also available through `./sprout` — see `./sprout help` for the full list.

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

If you modified `stack/openclaw-data/openclaw.json` (also reachable at
`./conf/openclaw.json`) by hand and broke it: this file is only created when
missing, so re-running `./install.sh` alone will **not** restore it. Fix it
directly, or delete it first and then re-run `./install.sh` to regenerate a
clean copy.

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
./sprout recreate
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
./sprout auth
```

Approve a device:

```bash
./sprout auth <device-uuid>
```

Reconnect the browser after approval.

---

## ⚠️ Placeholder values detected

**Message**

```text
[INPUT] 🌱 TS_AUTHKEY:
```

**Solution**

`./sprout start` asks for a Tailscale auth key interactively (hidden input)
the first time, if `stack/.env` still has the default placeholder. Generate a
**reusable** key at:

https://login.tailscale.com/admin/settings/keys

and paste it in when prompted — it's saved to `stack/.env` automatically. You
can also set `TS_AUTHKEY` in `stack/.env` yourself ahead of time to skip the
prompt.

`OPENCLAW_GATEWAY_TOKEN` is generated automatically and does not need to be
replaced. Provide at least one provider API key in `stack/.env`, unless
you're using a local-inference module instead (see `./sprout search`):

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`

---

# 💡 Useful Tips

- Use `./sprout inspect` whenever you are unsure about the current stack status.
- Use `./sprout logs openclaw` first when debugging OpenClaw issues.
- Use `./sprout logs tailscale` for connectivity or Tailnet-related problems.
- If something looks inconsistent after changing configuration files, `./sprout recreate` is usually the fastest way to start with a clean environment.