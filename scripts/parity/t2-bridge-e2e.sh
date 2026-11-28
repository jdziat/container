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

# Parity expansion: docker-api-bridge create/start/exec/pause/unpause/changes/delete.
# Prerequisites: container system running; bridge binary buildable.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
BRIDGE_BIN="${BRIDGE_BIN:-${ROOT}/.build/arm64-apple-macosx/debug/container-docker-api-bridge}"
IMAGE="${PARITY_IMAGE:-alpine:latest}"
SUFFIX="$$"
NAME="parity-bridge-${SUFFIX}"
SOCK="${TMPDIR:-/tmp}/parity-bridge-${SUFFIX}.sock"
BRIDGE_LOG="$(mktemp -t parity-bridge.XXXXXX)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

cleanup() {
    if [[ -n "${bridge_pid:-}" ]]; then
        kill "${bridge_pid}" >/dev/null 2>&1 || true
        wait "${bridge_pid}" 2>/dev/null || true
    fi
    rm -f "${SOCK}" "${BRIDGE_LOG}"
    "${CONTAINER_BIN}" delete --force "${NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

curl_unix() {
    local method="$1" path="$2"
    shift 2
    curl -sS -X "${method}" --unix-socket "${SOCK}" "http://localhost${path}" "$@"
}

command -v "${CONTAINER_BIN}" >/dev/null || fail "'${CONTAINER_BIN}' not found"
"${CONTAINER_BIN}" system status >/dev/null 2>&1 || fail "container system not running"
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
  'Labels': {'parity.bridge': '1'},
}))")
create_resp="$(curl_unix POST "/containers/create?name=${NAME}" \
    -H 'Content-Type: application/json' -d "${create_body}")"
cid="$(python3 -c "import json,sys; print(json.load(sys.stdin)['Id'])" <<<"${create_resp}")"
[[ -n "${cid}" ]] || { echo "${create_resp}" >&2; fail "create missing Id"; }
pass "create ${NAME} -> ${cid}"

curl_unix POST "/containers/${cid}/start" -o /dev/null -w '%{http_code}' | grep -qE '^(204|200)$' \
    || fail "start ${cid}"
pass "start"

# Give the VM a moment to come up before exec/pause.
sleep 2

exec_body='{"Cmd":["echo","bridge-exec-ok"],"AttachStdout":true,"AttachStderr":true}'
exec_resp="$(curl_unix POST "/containers/${cid}/exec" -H 'Content-Type: application/json' -d "${exec_body}")"
eid="$(python3 -c "import json,sys; print(json.load(sys.stdin)['Id'])" <<<"${exec_resp}")"
[[ -n "${eid}" ]] || { echo "${exec_resp}" >&2; fail "exec create missing Id"; }
# start may return 200 with body or 204; either is success for this subset
curl_unix POST "/exec/${eid}/start" -H 'Content-Type: application/json' -d '{"Detach":false,"Tty":false}' >/dev/null \
    || fail "exec start ${eid}"
pass "exec"

code="$(curl_unix POST "/containers/${cid}/pause" -o /dev/null -w '%{http_code}')"
[[ "${code}" == "204" || "${code}" == "200" ]] || fail "pause HTTP ${code}"
pass "pause"

code="$(curl_unix POST "/containers/${cid}/unpause" -o /dev/null -w '%{http_code}')"
[[ "${code}" == "204" || "${code}" == "200" ]] || fail "unpause HTTP ${code}"
pass "unpause"

changes="$(curl_unix GET "/containers/${cid}/changes")"
python3 -c "import json,sys; json.load(sys.stdin)" <<<"${changes}" || fail "changes not JSON: ${changes}"
pass "changes"

code="$(curl_unix DELETE "/containers/${cid}?force=1" -o /dev/null -w '%{http_code}')"
[[ "${code}" == "204" || "${code}" == "200" ]] || fail "delete HTTP ${code}"
pass "delete"

# Curated image + network + volume surface (Engine bridge expansion).
nets="$(curl_unix GET /networks)"
python3 -c "import json,sys; assert isinstance(json.load(sys.stdin), list)" <<<"${nets}" \
    || fail "GET /networks not a JSON list"
pass "GET /networks"

net_name="parity-brnet-${SUFFIX}"
net_body=$(python3 -c "import json; print(json.dumps({'Name': '${net_name}', 'Driver': 'nat'}))")
net_resp="$(curl_unix POST /networks/create -H 'Content-Type: application/json' -d "${net_body}")"
python3 -c "import json,sys; j=json.load(sys.stdin); assert j.get('Id') or j.get('Name'), j" <<<"${net_resp}" \
    || { echo "${net_resp}" >&2; fail "POST /networks/create"; }
pass "POST /networks/create"

vols="$(curl_unix GET /volumes)"
python3 -c "import json,sys; j=json.load(sys.stdin); assert 'Volumes' in j or isinstance(j, list)" <<<"${vols}" \
    || fail "GET /volumes shape"
pass "GET /volumes"

vol_name="parity-brvol-${SUFFIX}"
vol_body=$(python3 -c "import json; print(json.dumps({'Name': '${vol_name}'}))")
vol_code="$(curl_unix POST /volumes/create -H 'Content-Type: application/json' -d "${vol_body}" -o /tmp/parity-vol-create.$$ -w '%{http_code}')"
[[ "${vol_code}" == "201" || "${vol_code}" == "200" ]] || { cat /tmp/parity-vol-create.$$ >&2; fail "POST /volumes/create HTTP ${vol_code}"; }
rm -f /tmp/parity-vol-create.$$
pass "POST /volumes/create"

img_create_code="$(curl_unix POST "/images/create?fromImage=${IMAGE}" -o /tmp/parity-img-create.$$ -w '%{http_code}')"
[[ "${img_create_code}" == "200" ]] || { cat /tmp/parity-img-create.$$ >&2; fail "POST /images/create HTTP ${img_create_code}"; }
rm -f /tmp/parity-img-create.$$
pass "POST /images/create"

# Best-effort cleanup of bridge-created resources (ignore failures).
curl_unix DELETE "/networks/${net_name}" >/dev/null 2>&1 || true
curl_unix DELETE "/volumes/${vol_name}" >/dev/null 2>&1 || true

pass "bridge e2e complete"
