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

# Parity harness, tier T1 (multi-service stack smoke): two named containers on a
# user-defined network that should be able to reach each other by service name.
# See docs/parity-matrix.md.
#
# Prerequisites:
#   - Apple silicon Mac running macOS 26 or later (user-defined networks need macOS 26).
#   - The `container` CLI on PATH (or set CONTAINER_BIN to its path).
#   - The container system services are running: `container system start`.
#   - `alpine:latest` is pullable or already local (override with PARITY_IMAGE).
#
# Usage: scripts/parity/t1-stack-smoke.sh
#
# Environment:
#   PARITY_STRICT_DNS=1   Treat a failure to resolve the peer's bare name as a hard
#                         failure. Without it the check is a soft failure (a WARN line
#                         and exit 0), because bare-name discovery on custom networks is
#                         tracked in https://github.com/apple/container/issues/1809 and
#                         has not landed everywhere yet.
#
# Exits non-zero if the network or either container cannot be created, if the
# containers cannot reach each other by IP, or (with PARITY_STRICT_DNS=1) if the
# name does not resolve. Everything this script creates is removed on exit.

set -euo pipefail

CONTAINER_BIN="${CONTAINER_BIN:-container}"
IMAGE="${PARITY_IMAGE:-alpine:latest}"
STRICT_DNS="${PARITY_STRICT_DNS:-0}"
SUFFIX="$$"
NETWORK="parity-t1-net-${SUFFIX}"
DB="db${SUFFIX}"
APP="app${SUFFIX}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

warn() {
    echo "WARN: $*" >&2
}

cleanup() {
    "${CONTAINER_BIN}" delete --force "${APP}" "${DB}" >/dev/null 2>&1 || true
    "${CONTAINER_BIN}" network delete "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v "${CONTAINER_BIN}" >/dev/null 2>&1 || fail "'${CONTAINER_BIN}' not found on PATH"
"${CONTAINER_BIN}" system status >/dev/null 2>&1 || fail "container system services are not running; run 'container system start'"

# Print a container's IPv4 address (without the prefix length) from `inspect` JSON.
container_ip() {
    "${CONTAINER_BIN}" inspect "$1" | python3 -c '
import json, sys
containers = json.load(sys.stdin)
networks = containers[0].get("status", {}).get("networks", [])
if not networks:
    sys.exit(1)
print(networks[0]["ipv4Address"].split("/")[0])
'
}

"${CONTAINER_BIN}" image pull "${IMAGE}" >/dev/null || fail "image pull ${IMAGE}"

# 1. network
"${CONTAINER_BIN}" network create "${NETWORK}" >/dev/null || fail "network create ${NETWORK}"
pass "network create ${NETWORK}"

# 2. two named containers on that network
"${CONTAINER_BIN}" run -d --name "${DB}" --network "${NETWORK}" "${IMAGE}" sleep 300 >/dev/null || fail "run ${DB}"
"${CONTAINER_BIN}" run -d --name "${APP}" --network "${NETWORK}" "${IMAGE}" sleep 300 >/dev/null || fail "run ${APP}"
pass "run ${DB} and ${APP} on ${NETWORK}"

db_ip="$(container_ip "${DB}")" || fail "could not read the IP address of ${DB} from 'container inspect'"
[[ -n "${db_ip}" ]] || fail "empty IP address for ${DB}"
pass "${DB} has address ${db_ip}"

# 3. baseline: reachability by IP must always work
"${CONTAINER_BIN}" exec "${APP}" ping -c 1 -W 2 "${db_ip}" >/dev/null || fail "${APP} cannot reach ${DB} by IP ${db_ip}"
pass "${APP} reaches ${DB} by IP"

# 4. bare-name resolution: the T1 goal (do not accept qualified names as a substitute).
if "${CONTAINER_BIN}" exec "${APP}" getent hosts "${DB}" >/dev/null 2>&1 ||
    "${CONTAINER_BIN}" exec "${APP}" nslookup "${DB}" >/dev/null 2>&1; then
    pass "${APP} resolves '${DB}'"
    resolved=1
fi

if [[ "${resolved:-0}" -ne 1 ]]; then
    if [[ "${STRICT_DNS}" == "1" ]]; then
        fail "${APP} cannot resolve '${DB}' on ${NETWORK} (see https://github.com/apple/container/issues/1809)"
    fi
    warn "${APP} cannot resolve '${DB}' on ${NETWORK}; bare-name discovery on custom networks is not available yet"
    warn "see https://github.com/apple/container/issues/1809; rerun with PARITY_STRICT_DNS=1 to make this fatal"
    exit 2
fi

echo "T1 stack smoke: passed (name resolution: ok)"
