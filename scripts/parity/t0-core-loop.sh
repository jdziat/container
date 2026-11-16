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

# Parity harness, tier T0 (core loop): pull an image, run a command, list, remove.
# See docs/parity-matrix.md.
#
# Prerequisites:
#   - Apple silicon Mac running macOS 26 or later.
#   - The `container` CLI on PATH (or set CONTAINER_BIN to its path).
#   - The container system services are running: `container system start`.
#   - Network access to pull `alpine:latest` from the default registry (or set
#     PARITY_IMAGE to an image that is already local or mirrored).
#
# Usage: scripts/parity/t0-core-loop.sh
#
# Exits 0 when every step passes and non-zero on the first failure. Containers
# created by this script are removed on exit, including on failure.

set -euo pipefail

CONTAINER_BIN="${CONTAINER_BIN:-container}"
IMAGE="${PARITY_IMAGE:-alpine:latest}"
NAME="parity-t0-$$"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

cleanup() {
    "${CONTAINER_BIN}" delete --force "${NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v "${CONTAINER_BIN}" >/dev/null 2>&1 || fail "'${CONTAINER_BIN}' not found on PATH"
"${CONTAINER_BIN}" system status >/dev/null 2>&1 || fail "container system services are not running; run 'container system start'"

# 1. pull
"${CONTAINER_BIN}" image pull "${IMAGE}" || fail "image pull ${IMAGE}"
pass "image pull ${IMAGE}"

# 2. run: the foreground process output and exit status propagate to the caller
expected="parity-t0-hello"
actual="$("${CONTAINER_BIN}" run --rm "${IMAGE}" echo "${expected}")" || fail "run echo exited non-zero"
[[ "${actual}" == "${expected}" ]] || fail "run echo: expected '${expected}', got '${actual}'"
pass "run --rm echo"

status=0
"${CONTAINER_BIN}" run --rm "${IMAGE}" sh -c 'exit 3' || status=$?
[[ "${status}" -eq 3 ]] || fail "run exit status: expected 3, got ${status}"
pass "run propagates exit status"

# 3. ls: a detached container shows up in `list`, and in `list --all` once stopped
"${CONTAINER_BIN}" run -d --name "${NAME}" "${IMAGE}" sleep 300 >/dev/null || fail "run -d ${NAME}"
"${CONTAINER_BIN}" ls --quiet | grep -qx "${NAME}" || fail "ls: ${NAME} not listed while running"
pass "ls shows running container"

"${CONTAINER_BIN}" exec "${NAME}" echo exec-ok >/dev/null || fail "exec in ${NAME}"
pass "exec"

"${CONTAINER_BIN}" stop --time 1 "${NAME}" >/dev/null || fail "stop ${NAME}"
if "${CONTAINER_BIN}" ls --quiet | grep -qx "${NAME}"; then
    fail "ls: ${NAME} still listed after stop without --all"
fi
"${CONTAINER_BIN}" ls --all --quiet | grep -qx "${NAME}" || fail "ls --all: ${NAME} not listed after stop"
pass "ls --all shows stopped container"

# 4. rm
"${CONTAINER_BIN}" rm "${NAME}" >/dev/null || fail "rm ${NAME}"
if "${CONTAINER_BIN}" ls --all --quiet | grep -qx "${NAME}"; then
    fail "rm: ${NAME} still listed after delete"
fi
pass "rm"

echo "T0 core loop: all steps passed"
