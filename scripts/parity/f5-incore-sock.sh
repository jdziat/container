#!/usr/bin/env bash
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

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
