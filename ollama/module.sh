#!/bin/sh
# ==============================================================================
# garden/ollama/module.sh — lifecycle implementation for the "ollama" module.
# ==============================================================================
set -eu

OLLAMA_SERVICE="ollama"

#
# Pulls the Ollama Docker image.
#
# Arguments:
#   None
#
# Returns:
#   0 on success, non-zero if the image pull fails.
#
module_install() {
  log_info "[ollama] Pulling image..."
  compose_cmd pull "${OLLAMA_SERVICE}"
}

#
# Ensures the persistent model-cache directory exists before the container
# mounts it.
#
# Arguments:
#   None
#
# Returns:
#   0 on success.
#
module_configure() {
  log_info "[ollama] Ensuring persistent data directory exists..."
  mkdir -p modules/ollama/data
}

#
# Starts the Ollama container and waits for its API to accept requests.
#
# Arguments:
#   None
#
# Returns:
#   0 once the API responds; non-zero if it does not within ~60s.
#
module_provision() {
  log_info "[ollama] Starting container..."
  compose_cmd up -d "${OLLAMA_SERVICE}"

  log_info "[ollama] Waiting for the API to become available..."
  attempt=1
  while [ "${attempt}" -le 30 ]; do
    if compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list >/dev/null 2>&1; then
      log_info "[ollama] API is reachable."
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done

  log_error "[ollama] API did not become available in time."
  return 1
}

# No module_register hook: "ollama" is pure infrastructure and integrates
# nothing into OpenClaw by itself (SPR-001 §8.3 — module_register is an
# optional hook; mandatory only for modules that register a capability with
# dependent components, e.g. an AI-inference provider).

#
# Confirms the Ollama API is still reachable.
#
# Arguments:
#   None
#
# Returns:
#   0 if healthy, non-zero otherwise.
#
module_validate() {
  log_info "[ollama] Validating API availability..."
  if ! compose_cmd exec -T "${OLLAMA_SERVICE}" ollama list >/dev/null 2>&1; then
    log_error "[ollama] API is not reachable."
    return 1
  fi
  log_info "[ollama] Ollama is operational."
  return 0
}

#
# Stops and removes the Ollama container. Model data is preserved on disk
# (modules/ollama/data) so re-installing does not re-download models.
#
# Arguments:
#   None
#
# Returns:
#   0 (best-effort; a missing container is not an error).
#
module_remove() {
  log_info "[ollama] Stopping and removing container..."
  compose_cmd rm -sf "${OLLAMA_SERVICE}" || true
  log_warn "[ollama] modules/ollama/data was preserved. Delete it manually to reset the model cache."
}
