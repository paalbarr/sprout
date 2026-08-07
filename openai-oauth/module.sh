#!/bin/sh
# ==============================================================================
# garden/openai-oauth/module.sh — lifecycle implementation for the
# "openai-oauth" module.
#
# Downloaded and sourced (". modules/openai-oauth/module.sh", never executed)
# by the generated ./sprout CLI inside provision_one_module() — it therefore
# runs in the same shell process as the Core and can freely call the
# functions ./sprout already defines: log_info / log_warn / log_error /
# log_fatal and compose_cmd() (SPR-001 §8.3 — modules are never invoked
# directly by users).
#
# Scope: this module owns no container of its own (no compose.yml). It
# operates against the already-running "openclaw" service to register
# OpenAI/ChatGPT as a provider using the native "Sign in with ChatGPT"
# OAuth device-code flow — i.e. an auth profile, not an API key. Named
# "openai-oauth" (not "chatgpt") to sit cleanly next to a separate,
# API-key-based "openai" provider module, per SPR-001 §8.3: "For AI
# inference modules, Register SHALL automatically create or update the
# corresponding OpenClaw provider configuration."
#
# ⚠ STATUS: a real run on 2026-08-07 (`./sprout install openai-oauth`) with
# --auth-choice "openai-oauth" (a guess) silently walked through every
# prompt as "keep current values" — no device-code/URL/ChatGPT sign-in was
# ever printed, and the existing ollama/tinyllama config was left
# untouched, while still exiting 0. module_validate()'s hard failure on a
# missing "openai" entry in `openclaw models status` was the only thing
# that caught it.
#
# The real value was then confirmed against the actual
# `openclaw onboard --help` output from the running stack (2026-08-07):
# it's "openai-device-code" (listed among --auth-choice's enum, alongside
# "openai-api-key" for the key-based flow and plain "openai" for something
# else entirely — device-code is the one that matches "Sign in with
# ChatGPT"). --non-interactive/--accept-risk were added below to skip the
# same boilerplate prompts tinyllama's onboard call skips (existing-config
# confirmation, model check, channels) — device-code auth itself is not a
# "prompt" in the --non-interactive sense, it's a required step of that
# --auth-choice, so it should still print its URL/code and block for
# approval. This fix has NOT yet been re-run end-to-end against the real
# stack — the previous run only proved the old value was wrong.
# ==============================================================================
set -eu

OPENCLAW_SERVICE="openclaw"

# Confirmed against `openclaw onboard --help` (2026-08-07): this is the
# --auth-choice value for the OpenAI/ChatGPT OAuth device-code flow.
AUTH_CHOICE="${OPENAI_OAUTH_AUTH_CHOICE:-openai-device-code}"

# Max time (seconds) to wait for the user to approve the device-code login
# from another browser/device.
AUTH_TIMEOUT="${OPENAI_OAUTH_TIMEOUT:-300}"

#
# No separate image/binary to install: this module rides on the already
# -running "openclaw" service's own CLI.
#
# Arguments:
#   None
#
# Returns:
#   0 always.
#
module_install() {
  log_info "[openai-oauth] No separate image to install (uses the 'openclaw' service's own CLI)."
  return 0
}

#
# Nothing to generate ahead of provisioning — the OAuth flow is entirely
# driven by `openclaw onboard` at provision time.
#
# Arguments:
#   None
#
# Returns:
#   0 always.
#
module_configure() {
  log_info "[openai-oauth] Nothing to configure ahead of provisioning."
  return 0
}

#
# Runs the "Sign in with ChatGPT" device-code flow inside the openclaw
# container. Idempotent: if a valid auth profile already exists for this
# provider, `openclaw onboard` is expected to no-op or refresh it rather
# than fail (confirm this against your stack — see TODO above).
#
# The user needs a ChatGPT Plus, Pro, Team or Business account, with device
# code authorization enabled in their ChatGPT security settings, to
# complete this.
#
# Arguments:
#   None
#
# Returns:
#   0 on success, non-zero if sign-in fails or times out.
#
module_provision() {
  log_info "[openai-oauth] Starting device-code sign-in (openclaw onboard --auth-choice ${AUTH_CHOICE})..."
  log_info "[openai-oauth] Follow the URL/code openclaw prints below. It will wait up to ${AUTH_TIMEOUT}s for approval."

  # No -T: device-code output (URL + short code) needs to reach the user
  # live in their terminal, not get swallowed. --non-interactive skips the
  # same boilerplate prompts tinyllama's onboard call skips; it should not
  # skip the device-code exchange itself, which is a required step of this
  # --auth-choice rather than an interactive prompt.
  if ! compose_cmd exec "${OPENCLAW_SERVICE}" openclaw onboard \
      --non-interactive \
      --accept-risk \
      --auth-choice "${AUTH_CHOICE}" \
      --flow quickstart \
      --skip-channels \
      --skip-skills \
      --skip-ui \
      --skip-hooks \
      --skip-search \
      --skip-health \
      --no-install-daemon; then
    log_error "[openai-oauth] openclaw onboard failed or device-code sign-in was not approved in time."
    return 1
  fi

  log_info "[openai-oauth] Restoring gateway.bind=lan (onboard's quickstart flow forces loopback)..."
  if ! compose_cmd exec -T "${OPENCLAW_SERVICE}" openclaw config set gateway.bind lan >/dev/null 2>&1; then
    log_error "[openai-oauth] Failed to restore gateway.bind=lan."
    return 1
  fi
}

# Register (SPR-001 §8.3/§8.4): "For AI inference modules, Register SHALL
# automatically create or update the corresponding OpenClaw provider
# configuration." A Bootstrap Module must not reach READY until this
# succeeds — invoked between Provision and Validate by ./sprout.
#
# The actual provider config write happens inside module_provision() above,
# as part of `openclaw onboard` — same pattern as garden/tinyllama/module.sh.
# module_register() here restarts openclaw so the newly written provider
# config is actually picked up (tinyllama's module_register needed the same
# restart after its own config writes).
#
# Arguments:
#   None
#
# Returns:
#   0 on success, non-zero if openclaw does not come back up healthy.
#
module_register() {
  log_info "[openai-oauth] Restarting openclaw to apply the new provider configuration..."
  compose_cmd restart "${OPENCLAW_SERVICE}"

  attempt=1
  while [ "${attempt}" -le 30 ]; do
    if compose_cmd exec -T "${OPENCLAW_SERVICE}" openclaw health >/dev/null 2>&1; then
      log_info "[openai-oauth] openclaw is back up and healthy."
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done

  log_error "[openai-oauth] openclaw did not come back up healthy after restart."
  compose_cmd logs --tail 30 "${OPENCLAW_SERVICE}" 2>&1 || true
  return 1
}

#
# Confirms openclaw is healthy, gateway.bind was not left on loopback, and
# the OAuth provider actually shows up in openclaw's model/provider list.
#
# The last check below is the ONLY thing standing between "the onboard
# command exited 0" and "a provider was actually registered" — onboard can
# (and, on 2026-08-07, did) exit 0 while silently keeping the pre-existing
# config untouched if --auth-choice isn't recognized. Keep this fatal.
#
# Arguments:
#   None
#
# Returns:
#   0 if every check passes, non-zero otherwise.
#
module_validate() {
  log_info "[openai-oauth] Validating openclaw is healthy..."
  if ! compose_cmd exec -T "${OPENCLAW_SERVICE}" openclaw health >/dev/null 2>&1; then
    log_error "[openai-oauth] openclaw is not healthy."
    return 1
  fi

  log_info "[openai-oauth] Validating gateway.bind was not left on loopback..."
  gw_bind=$(compose_cmd exec -T "${OPENCLAW_SERVICE}" openclaw config get gateway.bind 2>/dev/null | tr -d '\r' | awk 'NF{last=$0} END{print last}')
  if [ "${gw_bind}" != "lan" ]; then
    log_error "[openai-oauth] gateway.bind is '${gw_bind}', expected 'lan' — nginx/Tailscale access would be broken."
    return 1
  fi

  log_info "[openai-oauth] Checking openclaw's registered auth profile..."
  if compose_cmd exec -T "${OPENCLAW_SERVICE}" openclaw models status 2>/dev/null | grep -qi "openai"; then
    log_info "[openai-oauth] openclaw reports an openai provider as configured."
  else
    # Fatal on purpose (SPR-001 §8.3: no READY until Register actually
    # succeeds) — see the STATUS note at the top of this file for why this
    # must not be softened back to a warning.
    log_error "[openai-oauth] No 'openai' provider found in 'openclaw models status' — the OAuth sign-in did not actually register a provider. AUTH_CHOICE='${AUTH_CHOICE}' is unconfirmed; run 'docker compose exec openclaw openclaw onboard --help' to find the real value."
    return 1
  fi

  return 0
}

#
# De-registers the OAuth provider. This does not (and cannot, from here)
# revoke the ChatGPT-side authorization — that has to be done from the
# user's ChatGPT security settings. This only removes openclaw's local
# auth profile/provider entry.
#
# Arguments:
#   None
#
# Returns:
#   0 (best-effort; a missing profile is not a fatal error here).
#
module_remove() {
  log_info "[openai-oauth] Removing the openai-oauth auth profile from openclaw..."
  compose_cmd exec -T "${OPENCLAW_SERVICE}" openclaw auth logout --provider "${AUTH_CHOICE}" 2>/dev/null \
    || log_warn "[openai-oauth] Could not remove the auth profile automatically — confirm the right command with 'openclaw auth --help' and remove it manually if needed."
  log_warn "[openai-oauth] This does not revoke access from ChatGPT's side. Revoke it manually in your ChatGPT account's security/connected-apps settings if desired."
}
