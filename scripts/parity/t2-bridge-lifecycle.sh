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

# Engine bridge lifecycle routes: restart, start-by-name, tag, push (501), and SCOPED prune.
#
# SAFETY: prune removes every unused container/volume/network on the system when unscoped.
# This harness therefore (1) only ever calls prune with a label filter naming a label unique to
# this run, (2) plants an UNLABELED decoy volume and network first and fails if either vanishes,
# and (3) asserts that an unknown filter key is a 400 rather than a silent unscoped prune.
# Never add an unscoped prune call here: a live test of one once deleted a developer's volumes.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
BRIDGE_BIN="${BRIDGE_BIN:-${ROOT}/.build/arm64-apple-macosx/debug/container-docker-api-bridge}"
IMAGE="${PARITY_IMAGE:-alpine:3.20}"
SUFFIX="$$"
SOCK="${TMPDIR:-/tmp}/parity-life-${SUFFIX}.sock"
RUNLABEL="parity.run=${SUFFIX}"
CTR="life-ctr-${SUFFIX}"
STOPPED="life-stopped-${SUFFIX}"
VOL="life-vol-${SUFFIX}"
NET="life-net-${SUFFIX}"
DECOY_VOL="life-decoy-vol-${SUFFIX}"
DECOY_NET="life-decoy-net-${SUFFIX}"
TAGREF="localhost/life-tag-${SUFFIX}"
WORK="$(mktemp -d)"

failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

cleanup() {
    [[ -n "${bridge_pid:-}" ]] && { kill "${bridge_pid}" >/dev/null 2>&1 || true; wait "${bridge_pid}" 2>/dev/null || true; }
    # One name per call: a multi-argument delete stops at the first name that is already gone
    # (the pruned ones), which would leak the decoys that are meant to survive the test.
    for n in "${CTR}" "${STOPPED}"; do "${CONTAINER_BIN}" delete -f "${n}" >/dev/null 2>&1; done
    for n in "${VOL}" "${DECOY_VOL}"; do "${CONTAINER_BIN}" volume delete "${n}" >/dev/null 2>&1; done
    for n in "${NET}" "${DECOY_NET}"; do "${CONTAINER_BIN}" network delete "${n}" >/dev/null 2>&1; done
    "${CONTAINER_BIN}" image delete "${TAGREF}:v9" >/dev/null 2>&1
    rm -rf "${WORK}" "${SOCK}"
}
trap cleanup EXIT

[[ -x "${BRIDGE_BIN}" ]] || { echo "missing ${BRIDGE_BIN}" >&2; exit 2; }
"${CONTAINER_BIN}" system status >/dev/null 2>&1 || { echo "container system is not running" >&2; exit 2; }

# Isolation guard: verify the RUNNING apiserver's app root, not just an environment variable.
# An exported CONTAINER_APP_ROOT does not make a running system isolated, and these harnesses
# create and remove containers/volumes/networks. (A live test once deleted a developer's volumes.)
# `make parity-behavioral` starts a system on an isolated root; PARITY_ALLOW_REAL_SYSTEM=1 overrides.
if [[ "${PARITY_ALLOW_REAL_SYSTEM:-0}" != "1" ]]; then
    live_root="$("${CONTAINER_BIN}" system status 2>/dev/null | awk '$1=="paths.appRoot"{print $2}')"
    if [[ -z "${CONTAINER_APP_ROOT:-}" || "${live_root%/}" != "${CONTAINER_APP_ROOT%/}" ]]; then
        echo "refusing to run: the running system's app root is '${live_root}', not the isolated '${CONTAINER_APP_ROOT:-<unset>}'." >&2
        echo "Use 'make parity-behavioral', or set PARITY_ALLOW_REAL_SYSTEM=1 if you accept the risk." >&2
        exit 2
    fi
fi

# A stale bridge binary predates the prune scoping and would run an UNSCOPED prune.
if [[ -n "$(find "${ROOT}/Sources/Plugins/DockerAPIBridge" "${ROOT}/Sources/ContainerResource" -name '*.swift' -newer "${BRIDGE_BIN}" 2>/dev/null | head -1)" ]]; then
    echo "bridge binary is older than its sources; rebuild it (swift build --product container-docker-api-bridge)" >&2
    exit 2
fi

api() { curl -sS --unix-socket "${SOCK}" "$@"; }
http() { api -o "${WORK}/r.json" -w '%{http_code}' "$@"; }
# URL-encode a filters JSON for the query string.
filters() { python3 -c 'import json,sys,urllib.parse; print(urllib.parse.quote(json.dumps({"label":[sys.argv[1]]})))' "$1"; }
exists_vol() { "${CONTAINER_BIN}" volume list 2>&1 | grep -q "^$1[[:space:]]"; }
exists_net() { "${CONTAINER_BIN}" network list 2>&1 | grep -q "^$1[[:space:]]"; }
uptime_of() { "${CONTAINER_BIN}" exec "${CTR}" cat /proc/uptime 2>&1 | grep -v '^Warning! Running debug' | awk '{print int($1)}'; }

"${BRIDGE_BIN}" serve --socket "${SOCK}" >"${WORK}/bridge.log" 2>&1 &
bridge_pid=$!
for _ in $(seq 1 50); do [[ -S "${SOCK}" ]] && break; sleep 0.1; done
[[ -S "${SOCK}" ]] || { cat "${WORK}/bridge.log" >&2; echo "bridge socket not created" >&2; exit 2; }
"${CONTAINER_BIN}" image pull "${IMAGE}" >/dev/null 2>&1

"${CONTAINER_BIN}" run -d --name "${CTR}" "${IMAGE}" sleep 300 >/dev/null 2>&1 || { echo "could not start fixture" >&2; exit 2; }
sleep 4

# --- restart and start, addressed by NAME (Docker clients use names as often as IDs) -----------
# Age the guest well past the settle time so a restart that did nothing cannot look like one.
sleep 12
before="$(uptime_of)"
code="$(http -X POST "http://localhost/containers/${CTR}/restart")"; sleep 4
after="$(uptime_of)"
if [[ "${code}" == "204" && "${before}" -ge 12 && "${after}" -lt "${before}" ]]; then
    pass "restart by name returns 204 and really restarts the guest (uptime ${before}s -> ${after}s)"
else
    fail "restart by name: HTTP ${code}, uptime ${before}s -> ${after}s ($(cat "${WORK}/r.json" | head -c 160))"
fi
"${CONTAINER_BIN}" stop -t 1 "${CTR}" >/dev/null 2>&1
code="$(http -X POST "http://localhost/containers/${CTR}/start")"; sleep 3
state="$("${CONTAINER_BIN}" inspect -f '{{.State}}' "${CTR}" 2>&1 | tail -1)"
[[ "${code}" == "204" && "${state}" == "running" ]] && pass "start by name works on a stopped container" || fail "start by name: HTTP ${code} state=${state} ($(head -c 160 "${WORK}/r.json"))"
code="$(http -X POST "http://localhost/containers/${CTR}/start")"
[[ "${code}" == "304" ]] && pass "start on a running container is 304 (Docker semantics)" || fail "start running: HTTP ${code}"

# --- tag / push -----------------------------------------------------------------------------
code="$(http -X POST "http://localhost/images/${IMAGE}/tag?repo=${TAGREF}&tag=v9")"
if [[ "${code}" == "201" ]] && "${CONTAINER_BIN}" images 2>&1 | grep -q "life-tag-${SUFFIX}"; then pass "images tag creates the tag"; else fail "images tag: HTTP ${code}"; fi
[[ "$(http -X POST "http://localhost/images/${IMAGE}/tag")" == "400" ]] && pass "tag without repo is 400" || fail "tag without repo"
[[ "$(http -X POST "http://localhost/images/no-such-image:zzz/tag?repo=x")" == "404" ]] && pass "tag of an unknown image is 404" || fail "tag unknown image"
[[ "$(http -X POST "http://localhost/images/${IMAGE}/push")" == "501" ]] && pass "push is an explicit 501 (no registry credentials reach the bridge)" || fail "push is not 501"

# --- CANARY: malformed or unknown filters must be a 400 before ANY prune is attempted -----------
# If this fails the bridge would degrade a bad filter into an unscoped prune, so abort immediately.
canary_fail=0
for route in containers volumes networks; do
    for raw in '{"until":["24h"]}' '{"label":[]}' '{"label":"k=v"}' '{"label":[""]}' '{"label":[7]}'; do
        enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${raw}")"
        c="$(http -X POST "http://localhost/${route}/prune?filters=${enc}")"
        [[ "${c}" == "400" ]] || { fail "CANARY ${route}/prune filters=${raw}: HTTP ${c} (expected 400)"; canary_fail=1; }
    done
done
[[ "$(http -X POST "http://localhost/volumes/prune")" == "400" ]] || { fail "CANARY unscoped volumes/prune was not refused"; canary_fail=1; }
if ((canary_fail)); then echo "aborting before any scoped prune: the bridge does not reject unsafe filters" >&2; exit 1; fi
pass "canary: malformed/unknown/empty filters and unscoped volume prune are all refused with 400"

# --- SCOPED prune, with unlabeled decoys that must survive ---------------------------------------
"${CONTAINER_BIN}" volume create --label "${RUNLABEL}" "${VOL}" >/dev/null 2>&1 || fail "could not create labeled volume"
"${CONTAINER_BIN}" volume create "${DECOY_VOL}" >/dev/null 2>&1
"${CONTAINER_BIN}" network create --label "${RUNLABEL}" "${NET}" >/dev/null 2>&1 || fail "could not create labeled network"
"${CONTAINER_BIN}" network create "${DECOY_NET}" >/dev/null 2>&1
"${CONTAINER_BIN}" run --name "${STOPPED}" --label "${RUNLABEL}" "${IMAGE}" true >/dev/null 2>&1
F="$(filters "${RUNLABEL}")"

code="$(http -X POST "http://localhost/containers/prune?filters=${F}")"
if [[ "${code}" == "200" ]] && grep -q "ContainersDeleted" "${WORK}/r.json"; then
    "${CONTAINER_BIN}" ps -a --format '{{.Names}}' 2>&1 | grep -qx "${STOPPED}" && fail "scoped containers/prune left the matching stopped container" || pass "scoped containers/prune removed the matching stopped container"
    "${CONTAINER_BIN}" ps --format '{{.Names}}' 2>&1 | grep -qx "${CTR}" && pass "scoped containers/prune left the running container alone" || fail "running container was removed"
else fail "containers/prune: HTTP ${code}"; fi

code="$(http -X POST "http://localhost/volumes/prune?filters=${F}")"
if [[ "${code}" == "200" ]] && ! exists_vol "${VOL}" && exists_vol "${DECOY_VOL}"; then
    pass "scoped volumes/prune removed the labeled volume and spared the unlabeled decoy"
else fail "volumes/prune: HTTP ${code}; labeled-present=$(exists_vol "${VOL}" && echo yes || echo no) decoy-present=$(exists_vol "${DECOY_VOL}" && echo yes || echo no)"; fi

code="$(http -X POST "http://localhost/networks/prune?filters=${F}")"
if [[ "${code}" == "200" ]] && ! exists_net "${NET}" && exists_net "${DECOY_NET}" && exists_net default; then
    pass "scoped networks/prune removed the labeled network and spared the decoy and the builtin"
else fail "networks/prune: HTTP ${code}; decoy-present=$(exists_net "${DECOY_NET}" && echo yes || echo no) default-present=$(exists_net default && echo yes || echo no)"; fi

# An unknown filter key must be rejected, never degrade to an unscoped prune.
BAD="$(python3 -c 'import json,urllib.parse; print(urllib.parse.quote(json.dumps({"until":["24h"]})))')"
for route in containers volumes networks; do
    code="$(http -X POST "http://localhost/${route}/prune?filters=${BAD}")"
    [[ "${code}" == "400" ]] && pass "${route}/prune with an unsupported filter is a 400, not an unscoped prune" || fail "${route}/prune unsupported filter: HTTP ${code}"
done
exists_vol "${DECOY_VOL}" && exists_net "${DECOY_NET}" && pass "decoys survived every prune call" || fail "a decoy was deleted: an unscoped prune ran"

printf '\nbridge lifecycle: %d failure(s)\n' "${failures}"
((failures == 0)) && echo "T2_BRIDGE_LIFECYCLE_OK" || exit 1
