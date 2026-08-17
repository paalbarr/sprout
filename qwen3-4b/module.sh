#!/bin/sh
# ==============================================================================
# garden/qwen3-4b/module.sh — lifecycle implementation for the "qwen3-4b"
# module.
# ==============================================================================
set -eu

OLLAMA_SERVICE="ollama"
CUSTOM_PROVIDER_ID="ollama-qwen3-4b"

# env_value <KEY> — reads KEY=value from .env (first match, empty if
# absent). Same helper as garden/tinyllama/module.sh; read directly instead
# of relying on exported shell vars, since ./sprout does not (and should
# not) export .env's contents into its own process.
env_value() {
  sed -n "s/^$1=//p" .env 2>/dev/null | head -n 1
}

# qwen3_4b_model — the model this module pulls and registers. Reads
# QWEN3_4B_MODEL from .env so it stays overridable without editing this
# file (e.g. to pin a different quantization), but always falls back to
# "qwen3:4b" — this module's one job. Deliberately its own env var, not
# tinyllama's OLLAMA_DEFAULT_MODEL, since that name implies "the" default
# model and this module is explicitly meant to add a model, not replace it.
qwen3_4b_model() {
  value="$(env_value QWEN3_4B_MODEL)"
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "qwen3:4b"
  fi
}

qwen3_4b_base_url() {
  value="$(env_value OLLAMA_BASE_URL)"
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "http://ollama:11434"
  fi
}

openclaw_is_healthy() {
  # Uses openclaw's own CLI ('openclaw health') instead of wget — same
  # reasoning as garden/tinyllama/module.sh: the openclaw image is
  # Node-based and does not necessarily ship wget/curl.
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

# openclaw_config_get <path> — same helper as tinyllama/module.sh: runs
# `openclaw config get <path>` and returns just the value, stripping the
# CLI's banner/blank-line output.
openclaw_config_get() {
  compose_cmd exec -T openclaw openclaw config get "$1" 2>/dev/null | tr -d '\r' | awk 'NF{last=$0} END{print last}'
}

# openclaw_models_status — raw `openclaw models status` output, used both
# to check this module's own registration and, in module_register(), as a
# before/after snapshot to detect whether some *other* already-configured
# model (e.g. tinyllama) silently disappeared.
openclaw_models_status() {
  compose_cmd exec -T openclaw openclaw models status 2>/dev/null || true
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
  log_info "[qwen3-4b] No separate image to install (uses the 'ollama' module's engine)."
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
  log_info "[qwen3-4b] Nothing to configure ahead of provisioning."
  return 0
}

#
# Waits for the Ollama API (owned by the "ollama" module) and pulls the
# qwen3:4b model into it (~2.7GB download).
#
# Arguments:
#   None
#
# Returns:
#   0 on success, non-zero if the API never becomes reachable or the pull
#   fails.
#
module_provision() {
  model_name="$(qwen3_4b_model)"

  log_info "[qwen3-4b] Waiting for the Ollama API (via the 'ollama' module)..."
  attempt=1
  while [ "${attempt}" -le 30 ]; do
    if compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  if [ "${attempt}" -gt 30 ]; then
    log_error "[qwen3-4b] Ollama API did not become available. Is the 'ollama' module installed and READY?"
    return 1
  fi

  log_info "[qwen3-4b] Pulling model: ${model_name} (this can take a while depending on your connection)..."
  compose_cmd exec -T "${OLLAMA_SERVICE}" ollama pull "${model_name}"
}

# Register (SPR-001 §8.3/§8.4): "For AI inference modules, Register SHALL
# automatically create or update the corresponding OpenClaw provider
# configuration." A Bootstrap Module must not reach READY until this
# succeeds — invoked between Provision and Validate by ./sprout.
#
# Snapshots `openclaw models status` before and after the onboard call
# specifically to catch the failure mode this module was designed around:
# registering this model accidentally wiping out an already-configured one
# (see the header note on why CUSTOM_PROVIDER_ID is distinct from
# tinyllama's "ollama"). If that ever happens anyway — e.g. because
# openclaw's config format changes — this is what turns it into a loud
# failure instead of a silent config loss.
#
# Arguments:
#   None
#
# Returns:
#   0 on success, non-zero if onboarding fails, or if a previously-present
#   model disappeared from openclaw's models status as a side effect.
#
module_register() {
  base_url="$(qwen3_4b_base_url)"
  model_name="$(qwen3_4b_model)"

  if ! openclaw_is_healthy; then
    log_warn "[qwen3-4b] openclaw is unhealthy — restarting once before continuing."
    compose_cmd restart openclaw
    wait_openclaw_healthy 30 || {
      log_error "[qwen3-4b] openclaw is still unhealthy after a restart."
      compose_cmd logs --tail 30 openclaw 2>&1 || true
      return 1
    }
    log_info "[qwen3-4b] openclaw recovered."
  fi

  models_before="$(openclaw_models_status)"

  log_info "[qwen3-4b] Registering ${model_name} with OpenClaw as provider '${CUSTOM_PROVIDER_ID}' (openclaw onboard --auth-choice custom-api-key)..."
  onboard_out="onboard_result.json"
  onboard_err="onboard_err.log"
  if ! compose_cmd exec -T openclaw openclaw onboard \
      --non-interactive \
      --accept-risk \
      --auth-choice custom-api-key \
      --custom-provider-id "${CUSTOM_PROVIDER_ID}" \
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
    log_error "[qwen3-4b] openclaw onboard failed:"
    cat "${onboard_err}" >&2 2>/dev/null || true
    cat "${onboard_out}" >&2 2>/dev/null || true
    rm -f "${onboard_out}" "${onboard_err}"
    return 1
  fi
  rm -f "${onboard_out}" "${onboard_err}"
  log_info "[qwen3-4b] onboard completed."

  log_info "[qwen3-4b] Restoring gateway.bind=lan (onboard's quickstart flow forces loopback)..."
  if ! compose_cmd exec -T openclaw openclaw config set gateway.bind lan >/dev/null 2>&1; then
    log_error "[qwen3-4b] Failed to restore gateway.bind=lan."
    return 1
  fi

  log_info "[qwen3-4b] Restarting openclaw to apply the new provider configuration..."
  compose_cmd restart openclaw
  wait_openclaw_healthy 30 || {
    log_error "[qwen3-4b] openclaw did not come back up after restart."
    compose_cmd logs --tail 30 openclaw 2>&1 || true
    return 1
  }

  models_after="$(openclaw_models_status)"

  if ! echo "${models_after}" | grep -qi "qwen3"; then
    log_error "[qwen3-4b] 'qwen3' not found in 'openclaw models status' after onboard — registration did not actually take effect."
    return 1
  fi

  # Coexistence check: if tinyllama was registered before this ran, it must
  # still be there. This is the concrete, checkable version of "did adding
  # qwen3-4b silently overwrite the existing model" — see header note.
  if echo "${models_before}" | grep -qi "tinyllama" && ! echo "${models_after}" | grep -qi "tinyllama"; then
    log_error "[qwen3-4b] 'tinyllama' was present in 'openclaw models status' before this run and is GONE after registering qwen3-4b."
    log_error "[qwen3-4b] This means the two models do NOT coexist the way this module assumed — registering qwen3-4b overwrote tinyllama's provider config instead of adding alongside it."
    log_error "[qwen3-4b] NOT marking this module READY. Check 'docker compose exec openclaw openclaw models status' and 'openclaw config get' to see what's actually configured, and re-onboard tinyllama manually if needed."
    return 1
  fi

  log_info "[qwen3-4b] openclaw registered and healthy."
}

#
# Confirms the model is present in Ollama, OpenClaw is healthy, gateway.bind
# was not left on loopback, the provider shows up in OpenClaw's model list,
# and (repeat of the check in module_register, kept here too since
# module_validate is SPR-001's actual final gate before READY) that
# tinyllama — if it existed — is still present.
#
# Arguments:
#   None
#
# Returns:
#   0 if every check passes, non-zero otherwise.
#
module_validate() {
  model_name="$(qwen3_4b_model)"

  log_info "[qwen3-4b] Validating model availability..."
  if ! compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list 2>/dev/null | grep -qi "qwen3"; then
    log_error "[qwen3-4b] ${model_name} not found in Ollama after provisioning."
    return 1
  fi
  log_info "[qwen3-4b] ${model_name} is available in Ollama."

  log_info "[qwen3-4b] Validating openclaw is healthy..."
  if ! openclaw_is_healthy; then
    log_error "[qwen3-4b] openclaw is not healthy."
    return 1
  fi

  log_info "[qwen3-4b] Validating gateway.bind was not left on loopback..."
  gw_bind="$(openclaw_config_get gateway.bind)"
  if [ "${gw_bind}" != "lan" ]; then
    log_error "[qwen3-4b] gateway.bind is '${gw_bind}', expected 'lan' — nginx/Tailscale access would be broken."
    return 1
  fi

  log_info "[qwen3-4b] Checking openclaw's registered models..."
  models_now="$(openclaw_models_status)"
  if echo "${models_now}" | grep -qi "qwen3"; then
    log_info "[qwen3-4b] openclaw reports a qwen3 provider as configured."
  else
    log_error "[qwen3-4b] Could not confirm a qwen3 provider in 'openclaw models status' output."
    return 1
  fi

  log_info "[qwen3-4b] Confirming tinyllama (if previously installed) is still registered..."
  if compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list 2>/dev/null | grep -qi "tinyllama"; then
    if ! echo "${models_now}" | grep -qi "tinyllama"; then
      log_error "[qwen3-4b] tinyllama is still pulled in Ollama but missing from 'openclaw models status' — its OpenClaw registration appears to have been lost."
      return 1
    fi
    log_info "[qwen3-4b] tinyllama is still registered alongside qwen3-4b."
  fi

  return 0
}

#
# Removes the qwen3:4b model from Ollama. Does not touch the "ollama"
# module itself, its data directory, or any other model (SPR-001 §8.1 —
# Independent: modules never reach into another module's files/state).
#
# Arguments:
#   None
#
# Returns:
#   0 (best-effort; a missing model or a stopped "ollama" service is not a
#   fatal error here).
#
module_remove() {
  model_name="$(qwen3_4b_model)"
  log_info "[qwen3-4b] Removing ${model_name} from Ollama..."
  compose_cmd exec -T "${OLLAMA_SERVICE}" ollama rm "${model_name}" 2>/dev/null || log_warn "[qwen3-4b] Could not remove ${model_name} (is the 'ollama' module still running?)."
  log_warn "[qwen3-4b] This does not remove the '${CUSTOM_PROVIDER_ID}' entry from openclaw's config — clean that up manually with 'openclaw configure' if desired."
}