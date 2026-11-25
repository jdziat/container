#!/bin/bash
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

# Parity T2: drop-in `docker` shim verbs (#79).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
DOCKER_BIN="${DOCKER_BIN:-${ROOT}/bin/docker}"
IMAGE="${PARITY_IMAGE:-alpine:latest}"
SUFFIX="$$"
NAME="parity-shim-${SUFFIX}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

cleanup() {
    CONTAINER_BIN="${CONTAINER_BIN}" "${DOCKER_BIN}" rm -f "${NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v "${CONTAINER_BIN}" >/dev/null || fail "container missing: ${CONTAINER_BIN}"
[[ -x "${DOCKER_BIN}" ]] || fail "docker shim missing: ${DOCKER_BIN} (install scripts/docker → bin/docker)"
"${CONTAINER_BIN}" system status >/dev/null 2>&1 || fail "container system not running"

export CONTAINER_BIN

"${DOCKER_BIN}" pull "${IMAGE}" >/dev/null || fail "docker pull"
pass "docker pull"

"${DOCKER_BIN}" images >/dev/null || fail "docker images"
pass "docker images"

cid="$("${DOCKER_BIN}" run -d --name "${NAME}" "${IMAGE}" sleep 60)" || fail "docker run"
cid="$(printf '%s\n' "${cid}" | tail -1 | tr -d '[:space:]')"
[[ -n "${cid}" ]] || fail "docker run produced empty id"
pass "docker run -> ${cid}"

# Default list columns show Id (UUID), not Name — match either.
"${DOCKER_BIN}" ps | grep -Eq "${NAME}|${cid}" || fail "docker ps missing ${NAME}/${cid}"
pass "docker ps"

out="$("${DOCKER_BIN}" exec "${NAME}" echo shim-ok)" || fail "docker exec"
[[ "${out}" == *shim-ok* ]] || fail "docker exec output '${out}'"
pass "docker exec"

"${DOCKER_BIN}" rm -f "${NAME}" >/dev/null || fail "docker rm"
pass "docker rm"

pass "docker shim e2e complete"
