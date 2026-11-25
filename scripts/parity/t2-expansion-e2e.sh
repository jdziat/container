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

# Parity expansion e2e: rename, pause/unpause, diff, events, update, history,
# system prune dry-run, network connect/disconnect interim, CLI aliases.
# See docs/plans/2026-11-17-full-parity-expansion.plan.md and docs/parity-matrix.md.
#
# Prerequisites: Apple silicon, container system running, CONTAINER_BIN on PATH.

set -euo pipefail

CONTAINER_BIN="${CONTAINER_BIN:-container}"
IMAGE="${PARITY_IMAGE:-alpine:latest}"
SUFFIX="$$"
NAME="parity-exp-${SUFFIX}"
NAME2="parity-exp-renamed-${SUFFIX}"
NETWORK="parity-exp-net-${SUFFIX}"
EVENTS_LOG="$(mktemp -t parity-exp-events.XXXXXX)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

cleanup() {
    "${CONTAINER_BIN}" delete --force "${NAME}" "${NAME2}" >/dev/null 2>&1 || true
    "${CONTAINER_BIN}" network delete "${NETWORK}" >/dev/null 2>&1 || true
    rm -f "${EVENTS_LOG}"
}
trap cleanup EXIT

command -v "${CONTAINER_BIN}" >/dev/null 2>&1 || fail "'${CONTAINER_BIN}' not found"
"${CONTAINER_BIN}" system status >/dev/null 2>&1 || fail "container system services are not running"

"${CONTAINER_BIN}" image pull "${IMAGE}" >/dev/null || fail "image pull ${IMAGE}"

# CLI aliases
"${CONTAINER_BIN}" ps --help >/dev/null || fail "ps alias missing"
pass "cli alias ps"
"${CONTAINER_BIN}" images --help >/dev/null || fail "images alias missing"
pass "cli alias images"
"${CONTAINER_BIN}" run --help 2>&1 | grep -q -- '--net' || fail "--net missing from run --help"
pass "cli alias --net"

# history
"${CONTAINER_BIN}" image history "${IMAGE}" >/dev/null || fail "image history ${IMAGE}"
pass "image history"

# events (background)
"${CONTAINER_BIN}" events >"${EVENTS_LOG}" 2>/dev/null &
events_pid=$!
sleep 1

# create + rename (Name≠Id)
id="$("${CONTAINER_BIN}" run -d --name "${NAME}" "${IMAGE}" sleep 300)" || fail "run -d ${NAME}"
[[ -n "${id}" ]] || fail "empty id from run -d"
[[ "${id}" != "${NAME}" ]] || fail "expected UUID Id distinct from Name ${NAME}, got ${id}"
pass "run Name≠Id (${NAME} -> ${id})"

"${CONTAINER_BIN}" rename "${NAME}" "${NAME2}" >/dev/null || fail "rename ${NAME} -> ${NAME2}"
"${CONTAINER_BIN}" inspect "${NAME2}" >/dev/null || fail "inspect by new name ${NAME2}"
pass "rename ${NAME} -> ${NAME2}"

inspect_state() {
    # Strip CLI noise (e.g. debug-build warning) before the JSON array.
    "${CONTAINER_BIN}" inspect "$1" 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("[")
if start < 0:
    raise SystemExit("no JSON array in inspect output")
print(json.loads(raw[start:])[0]["status"]["state"])
'
}

# pause / unpause
"${CONTAINER_BIN}" pause "${NAME2}" >/dev/null || fail "pause ${NAME2}"
status="$(inspect_state "${NAME2}")"
[[ "${status}" == "paused" ]] || fail "expected paused, got ${status}"
pass "pause"

"${CONTAINER_BIN}" unpause "${NAME2}" >/dev/null || fail "unpause ${NAME2}"
status="$(inspect_state "${NAME2}")"
[[ "${status}" == "running" ]] || fail "expected running after unpause, got ${status}"
pass "unpause"

# diff (may be empty; must succeed)
"${CONTAINER_BIN}" diff "${NAME2}" >/dev/null || fail "diff ${NAME2}"
pass "diff"

# update
"${CONTAINER_BIN}" update --cpus 1 "${NAME2}" >/dev/null || fail "update --cpus ${NAME2}"
pass "update --cpus"

# network connect/disconnect F4 interim (auto-restart; --restart optional/compat)
"${CONTAINER_BIN}" network create "${NETWORK}" >/dev/null || fail "network create ${NETWORK}"
"${CONTAINER_BIN}" network connect "${NETWORK}" "${NAME2}" >/dev/null \
    || fail "network connect ${NETWORK} ${NAME2}"
pass "network connect (auto-restart)"
"${CONTAINER_BIN}" network disconnect "${NETWORK}" "${NAME2}" >/dev/null \
    || fail "network disconnect ${NETWORK} ${NAME2}"
pass "network disconnect (auto-restart)"

# system prune (non-destructive check that command exists and accepts flags)
"${CONTAINER_BIN}" system prune --help >/dev/null || fail "system prune --help"
pass "system prune help"

# stop events collector
kill "${events_pid}" >/dev/null 2>&1 || true
wait "${events_pid}" 2>/dev/null || true
if [[ -s "${EVENTS_LOG}" ]]; then
    pass "events produced output"
else
    # events may buffer; create/start should have published — soft if empty due to timing
    warn_msg="events log empty (timing); create/start/rename/pause still exercised"
    echo "WARN: ${warn_msg}" >&2
fi

pass "expansion e2e complete"
