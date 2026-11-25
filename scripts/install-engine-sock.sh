#!/usr/bin/env bash
# F5 / Recipe B: bind the Docker API bridge on /var/run/docker.sock (privileged).
#
# Prefer this install path when tools hardcode /var/run/docker.sock (Traefik-shaped
# mounts, docker-outside-of-docker). Requires sudo (or equivalent) to create the path.
# Socket mode is 0600 (bridge chmods after bind).
#
# Usage:
#   sudo ./scripts/install-engine-sock.sh
#   CONTAINER_ENGINE_SOCK=/var/run/docker.sock sudo -E ./scripts/install-engine-sock.sh
#
# Env:
#   CONTAINER_ENGINE_SOCK  Socket path (default: /var/run/docker.sock)
#   BRIDGE_BIN             Path to container-docker-api-bridge (auto-detected)
#   FOREGROUND             1 to run in foreground (default: background + pid file)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCK="${CONTAINER_ENGINE_SOCK:-/var/run/docker.sock}"
FOREGROUND="${FOREGROUND:-0}"
PID_FILE="${ENGINE_SOCK_PID_FILE:-/var/run/container-docker-api-bridge.pid}"
LOG_FILE="${ENGINE_SOCK_LOG_FILE:-/var/log/container-docker-api-bridge.log}"

log() { printf '[install-engine-sock] %s\n' "$*"; }
fail() { printf '[install-engine-sock] FAIL: %s\n' "$*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 && "${SOCK}" == "/var/run/docker.sock" ]]; then
  fail "binding ${SOCK} typically requires root; re-run with sudo"
fi

BRIDGE_BIN="${BRIDGE_BIN:-}"
if [[ -z "${BRIDGE_BIN}" ]]; then
  for c in \
    "${ROOT}/.build/arm64-apple-macosx/debug/container-docker-api-bridge" \
    "${ROOT}/.build/arm64-apple-macosx/release/container-docker-api-bridge" \
    "${ROOT}/.build/x86_64-apple-macosx/debug/container-docker-api-bridge" \
    "${ROOT}/.build/x86_64-apple-macosx/release/container-docker-api-bridge" \
    "${ROOT}/bin/container-docker-api-bridge" \
    "/usr/local/libexec/container/plugins/docker-api-bridge/bin/container-docker-api-bridge" \
    "$(command -v container-docker-api-bridge 2>/dev/null || true)"
  do
    if [[ -n "${c}" && -x "${c}" ]]; then BRIDGE_BIN="${c}"; break; fi
  done
fi
[[ -n "${BRIDGE_BIN}" && -x "${BRIDGE_BIN}" ]] || fail "container-docker-api-bridge not found; build the DockerAPIBridge plugin first"

log "starting bridge: ${BRIDGE_BIN} serve --socket ${SOCK}"
export DOCKER_HOST="unix://${SOCK}"

if [[ "${FOREGROUND}" == "1" ]]; then
  exec "${BRIDGE_BIN}" serve --socket "${SOCK}"
fi

mkdir -p "$(dirname "${PID_FILE}")" "$(dirname "${LOG_FILE}")" 2>/dev/null || true
"${BRIDGE_BIN}" serve --socket "${SOCK}" >>"${LOG_FILE}" 2>&1 &
echo $! >"${PID_FILE}"
log "listening on unix://${SOCK} (pid $(cat "${PID_FILE}"))"
log "export DOCKER_HOST=unix://${SOCK}"
log "Recipe B — see docs/docker-job-catalog.md#socket-recipes"
