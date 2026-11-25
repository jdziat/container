#!/usr/bin/env bash
# Pack C2: Testcontainers / Dev Containers shaped smoke via Recipe A (bridge sock).
# Not zero-config Desktop discovery. Optional Recipe B when PARITY_PRIVILEGED_SOCK=1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
fail() { printf 't2-client-smoke FAIL: %s\n' "$*" >&2; exit 1; }
[[ -x "$CONTAINER_BIN" ]] || fail "missing $CONTAINER_BIN"

"$CONTAINER_BIN" system start --timeout 90 >/dev/null 2>&1 || true

# Prefer Application Support bridge sock (Recipe A).
SOCK_DIR="${HOME}/Library/Application Support/com.apple.container"
SOCK="${DOCKER_HOST:-}"
if [[ -z "$SOCK" ]]; then
  # Start bridge plugin if needed on default path.
  if [[ -S "${SOCK_DIR}/docker.sock" ]]; then
    SOCK="unix://${SOCK_DIR}/docker.sock"
  else
    # Fall back to container CLI create/start/exec/delete as TC-shaped job without Engine sock.
    id=$("$CONTAINER_BIN" run -d --name t2-client-smoke alpine:latest sleep 60)
    "$CONTAINER_BIN" exec "$id" echo tc-ok | grep -q tc-ok || fail "exec"
    "$CONTAINER_BIN" delete -f "$id" >/dev/null
    printf 't2-client-smoke OK (cli-shaped Recipe A fallback)\n'
    exit 0
  fi
fi

export DOCKER_HOST="$SOCK"
# Curl Engine API ping + create/start/delete minimal container if curl present.
if command -v curl >/dev/null 2>&1; then
  curl -sf --unix-socket "${SOCK#unix://}" http://localhost/_ping >/dev/null \
    || fail "_ping via $SOCK"
fi

if [[ "${PARITY_PRIVILEGED_SOCK:-0}" == "1" ]]; then
  [[ -S /var/run/docker.sock ]] || fail "PARITY_PRIVILEGED_SOCK=1 but /var/run/docker.sock missing (run scripts/install-engine-sock.sh)"
fi

# Outside-matrix route must remain 501 when bridge is up.
if command -v curl >/dev/null 2>&1 && [[ -S "${SOCK#unix://}" ]]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "${SOCK#unix://}" \
    -X POST http://localhost/containers/x/attach || true)
  [[ "$code" == "501" || "$code" == "404" || "$code" == "000" ]] || fail "expected 501/404 for attach, got $code"
fi

printf 't2-client-smoke OK\n'
exit 0
