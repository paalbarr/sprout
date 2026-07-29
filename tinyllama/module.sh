#!/bin/sh
# ==============================================================================
# garden/tinyllama/module.sh — lifecycle implementation for the "tinyllama"
# module: the Garden's reference Bootstrap Module (SPR-001 §7, §8.3).
#
# Downloaded and sourced (". modules/tinyllama/module.sh", never executed) by
# the generated ./sprout CLI inside provision_one_module() — it runs in the
# same shell process as the Core and can freely call log_info / log_warn /
# log_error / log_fatal / compose_cmd(), exactly like garden/ollama/module.sh.
#
# depends: [ollama] in module.yaml means ./sprout always provisions "ollama"
# to READY before this module's own lifecycle starts (SPR-001 §7.1) — so
# every function below can assume the "ollama" service is already running
# and reachable.
#
# This module owns no container of its own (no compose.yml): it operates
# against the already-running "ollama" service to (1) pull the TinyLlama
# model and (2) register it as an OpenClaw provider. Per SPR-001 §8.3:
# "every Bootstrap Module that provides local AI inference capabilities
# SHALL automatically provision and register one or more model providers
# into the OpenClaw Runtime as part of its lifecycle" — that is exactly
# module_provision() + module_register() below.
# ==============================================================================
set -eu

OLLAMA_SERVICE="ollama"

# env_value <KEY> — reads KEY=value from .env (first match, empty if
# absent). Read directly instead of relying on exported shell vars, since
# ./sprout does not (and should not) export .env's contents into its own
# process.
env_value() {
  sed -n "s/^$1=//p" .env 2>/dev/null | head -n 1
}

# tinyllama_model — the model this module pulls and registers. Reads
# OLLAMA_DEFAULT_MODEL from .env so it stays overridable without editing
# this file, but always falls back to "tinyllama" — this module's one job.
tinyllama_model() {
  value="$(env_value OLLAMA_DEFAULT_MODEL)"
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "tinyllama"
  fi
}

tinyllama_base_url() {
  value="$(env_value OLLAMA_BASE_URL)"
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "http://ollama:11434"
  fi
}

openclaw_is_healthy() {
  # Uses openclaw's own CLI ('openclaw health' — confirmed in `openclaw
  # --help`) instead of wget: the openclaw image is Node-based and does not
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

#
# No separate image to install: this module rides on the already-provisioned
# "ollama" service's engine (guaranteed READY by the "depends: [ollama]"
# entry in module.yaml before this function ever runs).
#
# Arguments:
#   None
#
# Returns:
#   0 always.
#
module_install() {
  log_info "[tinyllama] No separate image to install (uses the 'ollama' module's engine)."
  return 0
}

#
# Nothing to generate ahead of provisioning — the model name is read
# directly from .env at provision/register/validate time.
#
# Arguments:
#   None
#
# Returns:
#   0 always.
#
module_configure() {
  log_info "[tinyllama] Nothing to configure ahead of provisioning."
  return 0
}

#
# Waits for the Ollama API (owned by the "ollama" module) and pulls the
# TinyLlama model into it.
#
# Arguments:
#   None
#
# Returns:
#   0 on success, non-zero if the API never becomes reachable or the pull
#   fails.
#
module_provision() {
  model_name="$(tinyllama_model)"

  log_info "[tinyllama] Waiting for the Ollama API (via the 'ollama' module)..."
  attempt=1
  while [ "${attempt}" -le 30 ]; do
    if compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  if [ "${attempt}" -gt 30 ]; then
    log_error "[tinyllama] Ollama API did not become available. Is the 'ollama' module installed and READY?"
    return 1
  fi

  log_info "[tinyllama] Pulling model: ${model_name}"
  compose_cmd exec -T "${OLLAMA_SERVICE}" ollama pull "${model_name}"
}

# Register (SPR-001 §8.3/§8.4): "For AI inference modules, Register SHALL
# automatically create or update the corresponding OpenClaw provider
# configuration." A Bootstrap Module must not reach READY until this
# succeeds — invoked between Provision and Validate by ./sprout.
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
#
# Arguments:
#   None
#
# Returns:
#   0 on success, non-zero if onboarding or the follow-up config writes fail.
#
module_register() {
  base_url="$(tinyllama_base_url)"
  model_name="$(tinyllama_model)"

  if ! openclaw_is_healthy; then
    log_warn "[tinyllama] openclaw is unhealthy — restarting once before continuing."
    compose_cmd restart openclaw
    wait_openclaw_healthy 30 || {
      log_error "[tinyllama] openclaw is still unhealthy after a restart."
      compose_cmd logs --tail 30 openclaw 2>&1 || true
      return 1
    }
    log_info "[tinyllama] openclaw recovered."
  fi

  log_info "[tinyllama] Registering ${model_name} with OpenClaw (openclaw onboard --auth-choice custom-api-key)..."
  onboard_out="onboard_result.json"
  onboard_err="onboard_err.log"
  if ! compose_cmd exec -T openclaw openclaw onboard \
      --non-interactive \
      --accept-risk \
      --auth-choice custom-api-key \
      --custom-provider-id ollama \
      --custom-base-url "${base_url}/v1" \
      --custom-model-id "${model_name}" \
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
    log_error "[tinyllama] openclaw onboard failed:"
    cat "${onboard_err}" >&2 2>/dev/null || true
    cat "${onboard_out}" >&2 2>/dev/null || true
    rm -f "${onboard_out}" "${onboard_err}"
    return 1
  fi
  rm -f "${onboard_out}" "${onboard_err}"
  log_info "[tinyllama] onboard completed."

  log_info "[tinyllama] Restoring gateway.bind=lan (onboard's quickstart flow forces loopback)..."
  if ! compose_cmd exec -T openclaw openclaw config set gateway.bind lan >/dev/null 2>&1; then
    log_error "[tinyllama] Failed to restore gateway.bind=lan."
    return 1
  fi

  log_info "[tinyllama] Disabling tool-calling for ollama/${model_name} (unsupported by this model)..."
  if ! compose_cmd exec -T openclaw openclaw config set tools.byProvider \
      "{\"ollama/${model_name}\":{\"profile\":\"minimal\",\"deny\":[\"*\"]}}" \
      --strict-json --merge >/dev/null 2>&1; then
    log_error "[tinyllama] Failed to set tools.byProvider for ollama/${model_name}."
    return 1
  fi

  log_info "[tinyllama] Restarting openclaw to apply gateway.bind + tools.byProvider..."
  compose_cmd restart openclaw
  wait_openclaw_healthy 30 || {
    log_error "[tinyllama] openclaw did not come back up after restart."
    compose_cmd logs --tail 30 openclaw 2>&1 || true
    return 1
  }
  log_info "[tinyllama] openclaw registered and healthy."
}

#
# Confirms the model is present in Ollama, OpenClaw is healthy, gateway.bind
# was not left on loopback, and the provider shows up in OpenClaw's model
# list.
#
# Arguments:
#   None
#
# Returns:
#   0 if every check passes, non-zero otherwise.
#
module_validate() {
  model_name="$(tinyllama_model)"

  log_info "[tinyllama] Validating model availability..."
  if ! compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list 2>/dev/null | grep -q "${model_name}"; then
    log_error "[tinyllama] ${model_name} not found in Ollama after provisioning."
    return 1
  fi
  log_info "[tinyllama] ${model_name} is available in Ollama."

  log_info "[tinyllama] Validating openclaw is healthy..."
  if ! openclaw_is_healthy; then
    log_error "[tinyllama] openclaw is not healthy."
    return 1
  fi

  log_info "[tinyllama] Validating gateway.bind was not left on loopback..."
  gw_bind="$(openclaw_config_get gateway.bind)"
  if [ "${gw_bind}" != "lan" ]; then
    log_error "[tinyllama] gateway.bind is '${gw_bind}', expected 'lan' — nginx/Tailscale access would be broken."
    return 1
  fi

  log_info "[tinyllama] Checking openclaw's registered model..."
  if compose_cmd exec -T openclaw openclaw models status 2>/dev/null | grep -qi "ollama/${model_name}"; then
    log_info "[tinyllama] openclaw reports ollama/${model_name} as configured."
  else
    log_warn "[tinyllama] Could not confirm ollama/${model_name} in 'openclaw models status' output — check manually with: docker compose exec openclaw openclaw models status"
  fi

  return 0
}

#
# Removes the TinyLlama model from Ollama. Does not touch the "ollama"
# module itself or its data directory (SPR-001 §8.1 — Independent: modules
# never reach into another module's files/state).
#
# Arguments:
#   None
#
# Returns:
#   0 (best-effort; a missing model or a stopped "ollama" service is not a
#   fatal error here).
#
module_remove() {
  model_name="$(tinyllama_model)"
  log_info "[tinyllama] Removing ${model_name} from Ollama..."
  compose_cmd exec -T "${OLLAMA_SERVICE}" ollama rm "${model_name}" 2>/dev/null || log_warn "[tinyllama] Could not remove ${model_name} (is the 'ollama' module still running?)."
}
