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

# Pack C1 bridge corpus: stats (one-shot), rename, top + assert outside route still 501.
# Starts container system if needed. Prerequisites: buildable bridge binary.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
BRIDGE_BIN="${BRIDGE_BIN:-${ROOT}/.build/arm64-apple-macosx/debug/container-docker-api-bridge}"
IMAGE="${PARITY_IMAGE:-alpine:latest}"
SUFFIX="$$"
NAME="parity-corpus-${SUFFIX}"
RENAMED="${NAME}-renamed"
SOCK="${TMPDIR:-/tmp}/parity-bridge-corpus-${SUFFIX}.sock"
BRIDGE_LOG="$(mktemp -t parity-bridge-corpus.XXXXXX)"
STARTED_SYSTEM=0

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

cleanup() {
    if [[ -n "${bridge_pid:-}" ]]; then
        kill "${bridge_pid}" >/dev/null 2>&1 || true
        wait "${bridge_pid}" 2>/dev/null || true
    fi
    rm -f "${SOCK}" "${BRIDGE_LOG}"
    "${CONTAINER_BIN}" delete --force "${NAME}" >/dev/null 2>&1 || true
    "${CONTAINER_BIN}" delete --force "${RENAMED}" >/dev/null 2>&1 || true
    if [[ "${STARTED_SYSTEM}" -eq 1 ]]; then
        "${CONTAINER_BIN}" system stop >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

curl_unix() {
    local method="$1" path="$2"
    shift 2
    curl -sS -X "${method}" --unix-socket "${SOCK}" "http://localhost${path}" "$@"
}

command -v "${CONTAINER_BIN}" >/dev/null || fail "'${CONTAINER_BIN}' not found"

if ! "${CONTAINER_BIN}" system status >/dev/null 2>&1; then
    "${CONTAINER_BIN}" system start >/dev/null || fail "container system start failed"
    STARTED_SYSTEM=1
    for _ in $(seq 1 60); do
        "${CONTAINER_BIN}" system status >/dev/null 2>&1 && break
        sleep 0.5
    done
    "${CONTAINER_BIN}" system status >/dev/null 2>&1 || fail "container system did not become ready"
fi

[[ -x "${BRIDGE_BIN}" ]] || fail "bridge binary missing: ${BRIDGE_BIN} (build container-docker-api-bridge)"

"${CONTAINER_BIN}" image pull "${IMAGE}" >/dev/null || fail "pull ${IMAGE}"

"${BRIDGE_BIN}" serve --socket "${SOCK}" >"${BRIDGE_LOG}" 2>&1 &
bridge_pid=$!
for _ in $(seq 1 50); do
    [[ -S "${SOCK}" ]] && break
    sleep 0.1
done
[[ -S "${SOCK}" ]] || { cat "${BRIDGE_LOG}" >&2; fail "bridge socket not created"; }

ping="$(curl_unix GET /_ping)"
[[ "${ping}" == "OK" ]] || fail "_ping expected OK, got '${ping}'"
pass "_ping"

create_body=$(python3 -c "import json; print(json.dumps({
  'Image': '${IMAGE}',
  'Cmd': ['sleep', '300'],
  'HostConfig': {},
  'Labels': {'parity.bridge.corpus': '1'},
}))")
create_resp="$(curl_unix POST "/containers/create?name=${NAME}" \
    -H 'Content-Type: application/json' -d "${create_body}")"
cid="$(python3 -c "import json,sys; print(json.load(sys.stdin)['Id'])" <<<"${create_resp}")"
[[ -n "${cid}" ]] || { echo "${create_resp}" >&2; fail "create missing Id"; }
pass "create ${NAME} -> ${cid}"

curl_unix POST "/containers/${cid}/start" -o /dev/null -w '%{http_code}' | grep -qE '^(204|200)$' \
    || fail "start ${cid}"
pass "start"
sleep 2

# --- shipped corpus routes ---
stats="$(curl_unix GET "/containers/${cid}/stats?stream=0")"
python3 -c "
import json,sys
j=json.load(sys.stdin)
assert 'memory_stats' in j and 'cpu_stats' in j, j
assert 'usage' in j['memory_stats'], j
" <<<"${stats}" || { echo "${stats}" >&2; fail "GET stats one-shot shape"; }
pass "GET /containers/{id}/stats (one-shot)"

top="$(curl_unix GET "/containers/${cid}/top?ps_args=-ef")"
python3 -c "
import json,sys
j=json.load(sys.stdin)
assert isinstance(j.get('Titles'), list) and j['Titles'], j
assert isinstance(j.get('Processes'), list), j
" <<<"${top}" || { echo "${top}" >&2; fail "GET top shape"; }
pass "GET /containers/{id}/top"

code="$(curl_unix POST "/containers/${cid}/rename?name=${RENAMED}" -o /dev/null -w '%{http_code}')"
[[ "${code}" == "204" || "${code}" == "200" ]] || fail "rename HTTP ${code}"
inspect="$(curl_unix GET "/containers/${cid}/json")"
python3 -c "
import json,sys
j=json.load(sys.stdin)
assert j.get('Name') in ('/${RENAMED}', '${RENAMED}'), j.get('Name')
" <<<"${inspect}" || { echo "${inspect}" >&2; fail "rename did not update Name"; }
pass "POST /containers/{id}/rename"

# --- still outside matrix ---
attach_body="$(mktemp -t parity-attach.XXXXXX)"
attach_code="$(curl_unix POST "/containers/${cid}/attach?stdout=1&stdin=0&stream=1" \
    -o "${attach_body}" -w '%{http_code}' || true)"
[[ "${attach_code}" == "501" ]] || { cat "${attach_body}" >&2; fail "attach expected 501, got ${attach_code}"; }
python3 -c "
import json,sys
j=json.load(sys.stdin)
msg=j.get('message','')
assert '501' in msg or 'outside the curated' in msg or 'support' in msg, j
" <<<"$(cat "${attach_body}")" || { cat "${attach_body}" >&2; fail "attach 501 body missing curated contract message"; }
rm -f "${attach_body}"
pass "POST /containers/{id}/attach still 501"

curl_unix DELETE "/containers/${cid}?force=1" -o /dev/null >/dev/null || true
pass "bridge corpus complete"
