#!/usr/bin/env bash
# F5 gate: in-core /var/run/docker.sock is default-on (opt-out via CONTAINER_INCORE_DOCKER_SOCK=0).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { printf '[f5-sock] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[f5-sock] %s\n' "$*"; }

CFG="${ROOT}/Sources/ContainerPersistence/ContainerSystemConfig.swift"
grep -q 'CONTAINER_INCORE_DOCKER_SOCK' "$CFG" || fail "ContainerSystemConfig missing INCORE env"
grep -q 'enginePrivilegedSock' "$CFG" || fail "enginePrivilegedSock missing"
grep -q 'wantsInCoreDockerSock' "$CFG" || fail "wantsInCoreDockerSock helper missing"
API="${ROOT}/Sources/APIServer/APIServer+Start.swift"
grep -q 'spawnInCoreDockerSock' "$API" || fail "APIServer missing spawnInCoreDockerSock"
grep -q 'privileged-sock' "$API" || fail "APIServer missing privileged-sock spawn"
START="${ROOT}/Sources/ContainerCommands/System/SystemStart.swift"
grep -q 'CONTAINER_INCORE_DOCKER_SOCK' "$START" \
  || fail "SystemStart must pass through CONTAINER_INCORE_DOCKER_SOCK"
# Default must be on (R3 reopen).
grep -q 'enginePrivilegedSock: Bool = true' "$CFG" \
  || fail "enginePrivilegedSock must default true"
grep -q 'raw == "0"' "$CFG" || fail "wantsInCoreDockerSock must honor CONTAINER_INCORE_DOCKER_SOCK=0 opt-out"

ok "F5_INCORE_SOCK_OK"
