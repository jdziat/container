#!/usr/bin/env bash
# L4 harness: Recipe B is the first-class path for docker.sock consumers.
# Proves doctor/docs contract + bridge serve on a *docker.sock-named* path (Recipe B shape
# without requiring root /var/run). Full privileged /var/run/docker.sock needs sudo locally.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
BRIDGE_BIN="${BRIDGE_BIN:-}"
FIX="${ROOT}/scripts/parity/compose-doctor/loud-edges.yaml"
SOCK_DIR="$(mktemp -d -t l4-recipe-b.XXXXXX)"
SOCK="${SOCK_DIR}/docker.sock"
BRIDGE_LOG="$(mktemp -t l4-bridge.XXXXXX)"
bridge_pid=""

fail() { printf '[l4-recipe-b] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[l4-recipe-b] %s\n' "$*"; }

cleanup() {
  if [[ -n "${bridge_pid}" ]]; then
    kill "${bridge_pid}" >/dev/null 2>&1 || true
    wait "${bridge_pid}" 2>/dev/null || true
  fi
  rm -rf "${SOCK_DIR}" "${BRIDGE_LOG}"
}
trap cleanup EXIT

# Docs / doctor contract
grep -q 'Recipe B' "${ROOT}/Sources/Plugins/DockerAPIBridge/README.md" \
  || fail "bridge README missing Recipe B"
grep -q '/var/run/docker.sock' "${ROOT}/docs/docker-job-catalog.md" \
  || fail "job catalog missing /var/run/docker.sock Recipe B"
grep -q 'install-engine-sock' "${ROOT}/docs/docker-job-catalog.md" \
  || fail "job catalog missing install-engine-sock Recipe B path"
[[ -x "${ROOT}/scripts/install-engine-sock.sh" ]] \
  || fail "scripts/install-engine-sock.sh missing or not executable"
grep -q 'Recipe B' "${ROOT}/Sources/Plugins/ContainerCompose/main.swift" \
  || fail "compose doctor must mention Recipe B for docker-sock"

if [[ -x "${CONTAINER_BIN}" ]]; then
  out="$("${CONTAINER_BIN}" compose doctor -f "${FIX}" -p l4-sock 2>&1)" || true
  printf '%s\n' "${out}" | grep -Fq "[docker-sock]" || fail "doctor missing [docker-sock]"
  printf '%s\n' "${out}" | grep -Fq "Recipe B" \
    || fail "live doctor lacks Recipe B (rebuild/install compose plugin: make container)"
  ok "doctor docker-sock → Recipe B"
else
  fail "CONTAINER_BIN=${CONTAINER_BIN} missing; build with make cli/container before L4"
fi

# Locate bridge binary
if [[ -z "${BRIDGE_BIN}" ]]; then
  for c in \
    "${ROOT}/.build/arm64-apple-macosx/debug/container-docker-api-bridge" \
    "${ROOT}/.build/arm64-apple-macosx/release/container-docker-api-bridge" \
    "${ROOT}/bin/container-docker-api-bridge"
  do
    if [[ -x "${c}" ]]; then BRIDGE_BIN="${c}"; break; fi
  done
fi

if [[ -z "${BRIDGE_BIN}" || ! -x "${BRIDGE_BIN}" ]]; then
  ok "skip bridge serve (no bridge binary); docs/doctor contract OK"
  ok "L4_RECIPE_B_OK"
  exit 0
fi

# Recipe B shape: socket basename docker.sock (path under tmp avoids root).
"${BRIDGE_BIN}" serve --socket "${SOCK}" >"${BRIDGE_LOG}" 2>&1 &
bridge_pid=$!
for _ in $(seq 1 50); do
  [[ -S "${SOCK}" ]] && break
  sleep 0.1
done
[[ -S "${SOCK}" ]] || { cat "${BRIDGE_LOG}" >&2; fail "bridge did not create ${SOCK}"; }

ping="$(curl -sS --unix-socket "${SOCK}" http://localhost/_ping)" || fail "_ping curl failed"
[[ "${ping}" == "OK" ]] || fail "_ping expected OK, got '${ping}'"
ok "bridge serve on …/docker.sock (Recipe B shape) _ping=OK"
ok "L4_RECIPE_B_OK"
