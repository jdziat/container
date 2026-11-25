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

# Smoke Pack B: compose doctor surfaces loud edges without starting services.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
FIX="${ROOT}/scripts/parity/compose-doctor/loud-edges.yaml"

fail() { printf 'compose-doctor-smoke FAIL: %s\n' "$*" >&2; exit 1; }
[[ -x "${CONTAINER_BIN}" ]] || fail "missing ${CONTAINER_BIN} (build with make container)"

out="$("${CONTAINER_BIN}" compose doctor -f "${FIX}" -p doctor-smoke 2>&1)" || true
printf '%s\n' "${out}"

# Require the full loud-edge set in one pass (not partial success).
# Match bracketed codes from `SEVERITY [code] message` so substrings cannot collide.
missing=()
for code in named-volume-single-writer nfs-kernel docker-sock; do
  printf '%s\n' "${out}" | grep -Fq "[${code}]" || missing+=("${code}")
done
printf '%s\n' "${out}" | grep -Eq '\[(alias-clash-in-file|vm-lifecycle)\]' || missing+=("alias-clash-or-vm-lifecycle")
((${#missing[@]} == 0)) || fail "missing findings: ${missing[*]}"

# --strict must exit non-zero when warn findings exist (nfs-kernel / docker-sock),
# and still emit the named-volume code (INFO for shared virtiofs plane).
strict_out="$("${CONTAINER_BIN}" compose doctor -f "${FIX}" -p doctor-smoke --strict 2>&1)" && fail "expected --strict to fail on warn findings"
printf '%s\n' "${strict_out}" | grep -Fq "[named-volume-single-writer]" || fail "--strict failed without named-volume-single-writer diagnostic"
printf '%s\n' "${out}" | grep -Eq 'INFO \[named-volume-single-writer\]' \
  || fail "named-volume-single-writer should be INFO (shared virtiofs plane)"

printf 'compose-doctor-smoke OK\n'
