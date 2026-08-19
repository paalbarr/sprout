#!/bin/sh
# ==============================================================================
# garden/qwen3-4b-instruct/module.sh — lifecycle implementation for the
# "qwen3-4b-instruct" module.
# ==============================================================================
set -eu

OLLAMA_SERVICE="ollama"
CUSTOM_PROVIDER_ID="ollama-qwen3-4b-instruct"

# Placeholder value for `openclaw models auth paste-api-key`. Ollama's
# OpenAI-compatible endpoint does not check the Authorization header at
# all, but OpenClaw's generic custom-api-key auth path still requires an
# auth profile to exist on file for the provider — a custom provider-id
# (anything other than the literal "ollama") does not get the synthetic,
# no-key auth that OpenClaw's native ollama plugin gets automatically.
# Confirmed 2026-08-17 against a real stack: without this, agent runs fail
# with "No API key found for provider '<id>' ... missing-provider-auth"
# even though onboard itself completed successfully.
PLACEHOLDER_API_KEY="ollama-local-no-key-needed"

# env_value <KEY> — reads KEY=value from .env (first match, empty if
# absent). Same helper as garden/tinyllama/module.sh; read directly instead
# of relying on exported shell vars, since ./sprout does not (and should
# not) export .env's contents into its own process.
env_value() {
  sed -n "s/^$1=//p" .env 2>/dev/null | head -n 1
}

# qwen3_4b_instruct_model — the model this module pulls and registers.
# Reads QWEN3_4B_INSTRUCT_MODEL from .env so it stays overridable without
# editing this file (e.g. to pin a different quantization), but always
# falls back to "qwen3:4b-instruct". Deliberately its own env var, not
# tinyllama's OLLAMA_DEFAULT_MODEL, since that name implies "the" default
# model and this module is explicitly meant to add a model, not replace it.
qwen3_4b_instruct_model() {
  value="$(env_value QWEN3_4B_INSTRUCT_MODEL)"
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "qwen3:4b-instruct"
  fi
}

qwen3_4b_instruct_base_url() {
  value="$(env_value OLLAMA_BASE_URL)"
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "http://ollama:11434"
  fi
}

# qwen3_4b_instruct_ctx — context window (tokens) to bake into the derived
# tag built by module_provision(). Reads QWEN3_4B_INSTRUCT_NUM_CTX from
# .env, falls back to 16384 (matches the OLLAMA_CONTEXT_LENGTH default in
# garden/ollama/compose.yaml, though — see the header note — that env var
# alone does NOT work for this specific model; this is the value that
# actually takes effect).
qwen3_4b_instruct_ctx() {
  value="$(env_value QWEN3_4B_INSTRUCT_NUM_CTX)"
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "16384"
  fi
}

# qwen3_4b_instruct_ctx_tag — the local Ollama tag this module actually
# registers with OpenClaw and validates/removes. Built by module_provision()
# from the base tag (qwen3_4b_instruct_model) via `ollama create`, with
# num_ctx (qwen3_4b_instruct_ctx) baked into its own Modelfile — see header
# note for why this indirection exists (the base tag's own Modelfile pins
# num_ctx to 4096, which overrides the server-wide OLLAMA_CONTEXT_LENGTH
# env var; only a model's own num_ctx reliably takes effect).
qwen3_4b_instruct_ctx_tag() {
  value="$(env_value QWEN3_4B_INSTRUCT_CTX_TAG)"
  if [ -n "${value}" ]; then
    echo "${value}"
  else
    echo "qwen3-4b-instruct-ctx"
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
  log_info "[qwen3-4b-instruct] No separate image to install (uses the 'ollama' module's engine)."
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
  log_info "[qwen3-4b-instruct] Nothing to configure ahead of provisioning."
  return 0
}

#
# Waits for the Ollama API (owned by the "ollama" module), pulls the base
# qwen3:4b-instruct model into it (~2.7GB download), then builds a local
# derived tag on top of it with a larger num_ctx explicitly baked in (see
# header note: the base tag's own Modelfile pins num_ctx to 4096, which
# silently overrides the server-wide OLLAMA_CONTEXT_LENGTH env var, so this
# derived tag is the only reliable way to get more context for this model).
#
# Arguments:
#   None
#
# Returns:
#   0 on success, non-zero if the API never becomes reachable, the pull
#   fails, or building the derived tag fails.
#
module_provision() {
  model_name="$(qwen3_4b_instruct_model)"
  ctx_tag="$(qwen3_4b_instruct_ctx_tag)"
  ctx_size="$(qwen3_4b_instruct_ctx)"

  log_info "[qwen3-4b-instruct] Waiting for the Ollama API (via the 'ollama' module)..."
  attempt=1
  while [ "${attempt}" -le 30 ]; do
    if compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  if [ "${attempt}" -gt 30 ]; then
    log_error "[qwen3-4b-instruct] Ollama API did not become available. Is the 'ollama' module installed and READY?"
    return 1
  fi

  log_info "[qwen3-4b-instruct] Pulling model: ${model_name} (this can take a while depending on your connection)..."
  if ! compose_cmd exec -T "${OLLAMA_SERVICE}" ollama pull "${model_name}"; then
    log_error "[qwen3-4b-instruct] Failed to pull ${model_name}."
    return 1
  fi

  # Confirmed 2026-08-18 against a real stack (https://github.com/ollama/ollama/issues/10829):
  # ${model_name}'s own published Modelfile bakes in "PARAMETER num_ctx
  # 4096", which silently overrides OLLAMA_CONTEXT_LENGTH — reproduced here
  # across three separate container recreates with that env var set to
  # 8192, then 16384; n_ctx stayed pinned at 4096 every time. Writing the
  # Modelfile content via printf (module.sh's own shell, correct variable
  # expansion) and piping it as stdin to `sh -c "cat > <path>"` inside the
  # container avoids nested-quoting problems with exec'ing a shell string
  # directly; `ollama create -f` itself only documented as taking a file
  # path, not stdin, hence writing to a temp file first rather than piping
  # straight into `ollama create -f -` (unconfirmed whether that's
  # supported).
  modelfile_path="/tmp/qwen3-4b-instruct.Modelfile"
  log_info "[qwen3-4b-instruct] Building '${ctx_tag}' — a local copy of ${model_name} with num_ctx=${ctx_size} baked in (works around ${model_name}'s own Modelfile pinning num_ctx to 4096, which overrides OLLAMA_CONTEXT_LENGTH)..."
  if ! printf 'FROM %s\nPARAMETER num_ctx %s\n' "${model_name}" "${ctx_size}" \
      | compose_cmd exec -T "${OLLAMA_SERVICE}" sh -c "cat > ${modelfile_path}"; then
    log_error "[qwen3-4b-instruct] Failed to write the derived Modelfile inside the 'ollama' container."
    return 1
  fi
  if ! compose_cmd exec -T "${OLLAMA_SERVICE}" ollama create "${ctx_tag}" -f "${modelfile_path}"; then
    log_error "[qwen3-4b-instruct] Failed to build '${ctx_tag}' from ${model_name} via 'ollama create'."
    return 1
  fi
  log_info "[qwen3-4b-instruct] '${ctx_tag}' built successfully (num_ctx=${ctx_size})."
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
  base_url="$(qwen3_4b_instruct_base_url)"
  model_name="$(qwen3_4b_instruct_model)"
  ctx_tag="$(qwen3_4b_instruct_ctx_tag)"

  if ! openclaw_is_healthy; then
    log_warn "[qwen3-4b-instruct] openclaw is unhealthy — restarting once before continuing."
    compose_cmd restart openclaw
    wait_openclaw_healthy 30 || {
      log_error "[qwen3-4b-instruct] openclaw is still unhealthy after a restart."
      compose_cmd logs --tail 30 openclaw 2>&1 || true
      return 1
    }
    log_info "[qwen3-4b-instruct] openclaw recovered."
  fi

  models_before="$(openclaw_models_status)"

  log_info "[qwen3-4b-instruct] Registering ${ctx_tag} (derived from ${model_name} with a larger num_ctx baked in) with OpenClaw as provider '${CUSTOM_PROVIDER_ID}' (openclaw onboard --auth-choice custom-api-key)..."
  onboard_out="onboard_result.json"
  onboard_err="onboard_err.log"
  if ! compose_cmd exec -T openclaw openclaw onboard \
      --non-interactive \
      --accept-risk \
      --auth-choice custom-api-key \
      --custom-provider-id "${CUSTOM_PROVIDER_ID}" \
      --custom-base-url "${base_url}/v1" \
      --custom-model-id "${ctx_tag}" \
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
    log_error "[qwen3-4b-instruct] openclaw onboard failed:"
    cat "${onboard_err}" >&2 2>/dev/null || true
    cat "${onboard_out}" >&2 2>/dev/null || true
    rm -f "${onboard_out}" "${onboard_err}"
    return 1
  fi
  rm -f "${onboard_out}" "${onboard_err}"
  log_info "[qwen3-4b-instruct] onboard completed."

  log_info "[qwen3-4b-instruct] Restoring gateway.bind=lan (onboard's quickstart flow forces loopback)..."
  if ! compose_cmd exec -T openclaw openclaw config set gateway.bind lan >/dev/null 2>&1; then
    log_error "[qwen3-4b-instruct] Failed to restore gateway.bind=lan."
    return 1
  fi

  # Custom provider-ids don't get OpenClaw's automatic synthetic auth (only
  # the literal "ollama" provider does) — without this, the agent fails at
  # runtime with "No API key found for provider ... missing-provider-auth"
  # even though onboard above completed successfully. Piped via stdin with
  # -T (no pty) since paste-api-key is an interactive "paste a value"
  # prompt with no --key/--value flag; Ollama never validates the value.
  log_info "[qwen3-4b-instruct] Registering a placeholder auth profile for '${CUSTOM_PROVIDER_ID}' (Ollama does not validate API keys, but OpenClaw's custom-api-key auth path requires one on file)..."
  if ! printf '%s\n' "${PLACEHOLDER_API_KEY}" | compose_cmd exec -T openclaw openclaw models auth paste-api-key --provider "${CUSTOM_PROVIDER_ID}" >/dev/null 2>&1; then
    log_error "[qwen3-4b-instruct] Failed to register a placeholder auth profile for '${CUSTOM_PROVIDER_ID}' via 'openclaw models auth paste-api-key'."
    return 1
  fi

  # Denies all tools for this provider/model on top of the larger num_ctx
  # baked into ${ctx_tag} — see the file header for the full story
  # (OpenClaw's default tool profile alone added ~18K tokens of
  # tool/function-calling schema to every request; even after cutting that
  # out, ~7.4K tokens of base system prompt still didn't fit in Ollama's
  # 4096-token default, which is why ${ctx_tag} exists at all). Kept even
  # with more headroom now available, since this model's tool-calling
  # reliability is not the point of a small local fallback model; the
  # OAuth/API-key providers keep full tool access via the untouched global
  # tools.profile.
  log_info "[qwen3-4b-instruct] Disabling tool-calling for ${CUSTOM_PROVIDER_ID}/${ctx_tag} (kept small and predictable; ${ctx_tag}'s larger num_ctx is there for conversation history, not tool schemas)..."
  if ! compose_cmd exec -T openclaw openclaw config set tools.byProvider \
      "{\"${CUSTOM_PROVIDER_ID}/${ctx_tag}\":{\"profile\":\"minimal\",\"deny\":[\"*\"]}}" \
      --strict-json --merge >/dev/null 2>&1; then
    log_error "[qwen3-4b-instruct] Failed to set tools.byProvider for ${CUSTOM_PROVIDER_ID}/${ctx_tag}."
    return 1
  fi

  log_info "[qwen3-4b-instruct] Restarting openclaw to apply gateway.bind + auth + tools.byProvider..."
  compose_cmd restart openclaw
  wait_openclaw_healthy 30 || {
    log_error "[qwen3-4b-instruct] openclaw did not come back up after restart."
    compose_cmd logs --tail 30 openclaw 2>&1 || true
    return 1
  }

  models_after="$(openclaw_models_status)"

  if ! echo "${models_after}" | grep -qi "qwen3"; then
    log_error "[qwen3-4b-instruct] 'qwen3' not found in 'openclaw models status' after onboard — registration did not actually take effect."
    return 1
  fi

  # Coexistence check: if tinyllama was registered before this ran, it must
  # still be there. This is the concrete, checkable version of "did adding
  # qwen3-4b-instruct silently overwrite the existing model" — see header
  # note.
  if echo "${models_before}" | grep -qi "tinyllama" && ! echo "${models_after}" | grep -qi "tinyllama"; then
    log_error "[qwen3-4b-instruct] 'tinyllama' was present in 'openclaw models status' before this run and is GONE after registering qwen3-4b-instruct."
    log_error "[qwen3-4b-instruct] This means the two models do NOT coexist the way this module assumed — registering qwen3-4b-instruct overwrote tinyllama's provider config instead of adding alongside it."
    log_error "[qwen3-4b-instruct] NOT marking this module READY. Check 'docker compose exec openclaw openclaw models status' and 'openclaw config get' to see what's actually configured, and re-onboard tinyllama manually if needed."
    return 1
  fi

  log_info "[qwen3-4b-instruct] openclaw registered and healthy."
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
  model_name="$(qwen3_4b_instruct_model)"
  ctx_tag="$(qwen3_4b_instruct_ctx_tag)"

  log_info "[qwen3-4b-instruct] Validating base model availability..."
  if ! compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list 2>/dev/null | grep -qi "${model_name}"; then
    log_error "[qwen3-4b-instruct] ${model_name} not found in Ollama after provisioning."
    return 1
  fi
  log_info "[qwen3-4b-instruct] ${model_name} is available in Ollama."

  log_info "[qwen3-4b-instruct] Validating derived context-window tag availability..."
  if ! compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list 2>/dev/null | grep -qi "${ctx_tag}"; then
    log_error "[qwen3-4b-instruct] ${ctx_tag} not found in Ollama — the derived num_ctx tag was not built (or was removed) after provisioning."
    return 1
  fi
  log_info "[qwen3-4b-instruct] ${ctx_tag} is available in Ollama."

  log_info "[qwen3-4b-instruct] Validating openclaw is healthy..."
  if ! openclaw_is_healthy; then
    log_error "[qwen3-4b-instruct] openclaw is not healthy."
    return 1
  fi

  log_info "[qwen3-4b-instruct] Validating gateway.bind was not left on loopback..."
  gw_bind="$(openclaw_config_get gateway.bind)"
  if [ "${gw_bind}" != "lan" ]; then
    log_error "[qwen3-4b-instruct] gateway.bind is '${gw_bind}', expected 'lan' — nginx/Tailscale access would be broken."
    return 1
  fi

  log_info "[qwen3-4b-instruct] Checking openclaw's registered models..."
  models_now="$(openclaw_models_status)"
  if echo "${models_now}" | grep -qi "qwen3"; then
    log_info "[qwen3-4b-instruct] openclaw reports a qwen3 provider as configured."
  else
    log_error "[qwen3-4b-instruct] Could not confirm a qwen3 provider in 'openclaw models status' output."
    return 1
  fi

  log_info "[qwen3-4b-instruct] Confirming '${CUSTOM_PROVIDER_ID}' is not listed under Missing auth..."
  if echo "${models_now}" | grep -A20 "^Missing auth" | grep -q "${CUSTOM_PROVIDER_ID}"; then
    log_error "[qwen3-4b-instruct] '${CUSTOM_PROVIDER_ID}' still shows up under 'Missing auth' in 'openclaw models status' — the placeholder auth profile did not take. Agent runs against this model would fail with 'missing-provider-auth'."
    return 1
  fi

  log_info "[qwen3-4b-instruct] Confirming tinyllama (if previously installed) is still registered..."
  if compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list 2>/dev/null | grep -qi "tinyllama"; then
    if ! echo "${models_now}" | grep -qi "tinyllama"; then
      log_error "[qwen3-4b-instruct] tinyllama is still pulled in Ollama but missing from 'openclaw models status' — its OpenClaw registration appears to have been lost."
      return 1
    fi
    log_info "[qwen3-4b-instruct] tinyllama is still registered alongside qwen3-4b-instruct."
  fi

  return 0
}

#
# Removes both the derived num_ctx tag and the base qwen3:4b-instruct model
# from Ollama, AND deregisters the '${CUSTOM_PROVIDER_ID}' provider entry
# from OpenClaw's config (confirmed
# path: models.providers.<id>, via `openclaw config unset` — verified
# 2026-08-18 against a real stack with `openclaw config get
# models.providers`). Does not touch the "ollama" module itself, its data
# directory, or any other model (SPR-001 §8.1 — Independent: modules never
# reach into another module's files/state).
#
# Arguments:
#   None
#
# Returns:
#   0 (best-effort; a missing model, a missing config entry, or a stopped
#   "ollama"/"openclaw" service is not a fatal error here — the point is to
#   leave things as clean as possible, not to block removal on it).
#
module_remove() {
  model_name="$(qwen3_4b_instruct_model)"
  ctx_tag="$(qwen3_4b_instruct_ctx_tag)"

  # Remove the derived tag first (it's the one Ollama built FROM the base
  # tag — removing the base first would still leave the derived tag's own
  # blob references dangling until it's removed too, so this order just
  # keeps `ollama list` clean at every step rather than relying on GC order).
  log_info "[qwen3-4b-instruct] Removing ${ctx_tag} from Ollama..."
  compose_cmd exec -T "${OLLAMA_SERVICE}" ollama rm "${ctx_tag}" 2>/dev/null || log_warn "[qwen3-4b-instruct] Could not remove ${ctx_tag} (is the 'ollama' module still running?)."

  log_info "[qwen3-4b-instruct] Removing ${model_name} from Ollama..."
  compose_cmd exec -T "${OLLAMA_SERVICE}" ollama rm "${model_name}" 2>/dev/null || log_warn "[qwen3-4b-instruct] Could not remove ${model_name} (is the 'ollama' module still running?)."

  log_info "[qwen3-4b-instruct] Deregistering '${CUSTOM_PROVIDER_ID}' from openclaw's config..."
  unset_ok=0
  if compose_cmd exec -T openclaw openclaw config unset "models.providers.${CUSTOM_PROVIDER_ID}" >/dev/null 2>&1; then
    unset_ok=1
    log_info "[qwen3-4b-instruct] '${CUSTOM_PROVIDER_ID}' deregistered from models.providers."
  else
    log_warn "[qwen3-4b-instruct] Could not deregister '${CUSTOM_PROVIDER_ID}' automatically — clean it up manually with: openclaw config unset models.providers.${CUSTOM_PROVIDER_ID}"
  fi

  # `config unset` above only clears models.providers.<id> — confirmed
  # 2026-08-18 against a real stack that OpenClaw keeps a SEPARATE "default
  # model" pointer (shown as "Default: <provider>/<model>" in `openclaw
  # models status`) that survives a provider unset untouched. If it was
  # still pointing at this module's provider, agent runs would fail with
  # "missing-provider-auth" against a now-deregistered provider. Reset it to
  # tinyllama (this stack's bootstrap/always-present model) when available;
  # otherwise leave it and warn, since picking an arbitrary fallback here
  # would be a guess.
  log_info "[qwen3-4b-instruct] Checking whether the default model still points at '${CUSTOM_PROVIDER_ID}'..."
  default_line="$(compose_cmd exec -T openclaw openclaw models status 2>/dev/null | grep '^Default:' || true)"
  if echo "${default_line}" | grep -q "${CUSTOM_PROVIDER_ID}"; then
    log_warn "[qwen3-4b-instruct] Default model pointer still points at '${CUSTOM_PROVIDER_ID}' ('config unset' does not touch it) — resetting..."
    if compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list 2>/dev/null | grep -qi "tinyllama"; then
      if compose_cmd exec -T openclaw openclaw models set ollama/tinyllama >/dev/null 2>&1; then
        log_info "[qwen3-4b-instruct] Default model reset to ollama/tinyllama."
      else
        log_warn "[qwen3-4b-instruct] Failed to reset the default model — set one manually with: openclaw models set <provider>/<model>"
      fi
    else
      log_warn "[qwen3-4b-instruct] No tinyllama fallback found to reset the default model to — set one manually with: openclaw models set <provider>/<model>"
    fi
  fi

  if [ "${unset_ok}" = "1" ]; then
    compose_cmd restart openclaw >/dev/null 2>&1 || log_warn "[qwen3-4b-instruct] Could not restart openclaw after cleanup — stale entries may linger in memory until the next restart."
  fi
}