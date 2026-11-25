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

# Engine bridge STREAM contract: asserts on the actual bytes a Docker client (Testcontainers,
# docker-java, Dev Containers) reads, not just on HTTP status. t2-bridge-e2e.sh only checks
# that exec/start does not error, which is how these bugs went unnoticed:
#   - exec/start returned only an exit code and never streamed stdout/stderr
#   - /logs concatenated the VM kernel boot log into the container's logs, unframed
#   - /events was double-chunk-encoded and replayed all history instead of streaming from now
#
# Needs a running container system and a built container-docker-api-bridge.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
BRIDGE_BIN="${BRIDGE_BIN:-${ROOT}/.build/arm64-apple-macosx/debug/container-docker-api-bridge}"
IMAGE="${PARITY_IMAGE:-alpine:3.20}"
SUFFIX="$$"
NAME="parity-streams-${SUFFIX}"
SOCK="${TMPDIR:-/tmp}/parity-streams-${SUFFIX}.sock"
WORK="$(mktemp -d)"

failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

cleanup() {
    [[ -n "${bridge_pid:-}" ]] && { kill "${bridge_pid}" >/dev/null 2>&1 || true; wait "${bridge_pid}" 2>/dev/null || true; }
    "${CONTAINER_BIN}" delete -f "${NAME}" >/dev/null 2>&1 || true
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

api() { curl -sS --unix-socket "${SOCK}" "$@"; }

# Decode Docker's multiplexed stream from stdin into JSON: {"frames":[[type,"text"],...],"trailing":N}
demux() {
    python3 -c '
import json, struct, sys
d = sys.stdin.buffer.read(); i = 0; frames = []
while i + 8 <= len(d):
    t, _, _, _, n = struct.unpack(">BBBBI", d[i:i+8])
    frames.append([t, d[i+8:i+8+n].decode(errors="replace")]); i += 8 + n
print(json.dumps({"frames": frames, "trailing": len(d) - i}))'
}

# jq-free JSON assertion: py_assert '<expr over j>' <<<json
py_assert() { python3 -c "import json,sys; j=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"; }

"${BRIDGE_BIN}" serve --socket "${SOCK}" >"${WORK}/bridge.log" 2>&1 &
bridge_pid=$!
for _ in $(seq 1 50); do [[ -S "${SOCK}" ]] && break; sleep 0.1; done
[[ -S "${SOCK}" ]] || { cat "${WORK}/bridge.log" >&2; echo "bridge socket not created" >&2; exit 2; }

"${CONTAINER_BIN}" image pull "${IMAGE}" >/dev/null 2>&1
"${CONTAINER_BIN}" run -d --name "${NAME}" "${IMAGE}" sh -c 'echo log-A; echo log-B; echo log-C; sleep 300' >/dev/null 2>&1 \
    || { echo "could not start fixture container" >&2; exit 2; }
sleep 3

exec_stream() { # $1 = JSON array for Cmd; writes body to ${WORK}/exec.bin, prints exec id
    local eid
    eid="$(api -X POST "http://localhost/containers/${NAME}/exec" -H 'Content-Type: application/json' \
        -d "{\"Cmd\":$1,\"AttachStdout\":true,\"AttachStderr\":true}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Id"])')"
    api -m 20 -X POST "http://localhost/exec/${eid}/start" -H 'Content-Type: application/json' \
        -d '{"Detach":false,"Tty":false}' -D "${WORK}/exec.hdr" -o "${WORK}/exec.bin"
    printf '%s' "${eid}"
}

# --- exec: stdout and stderr are streamed, separated, and correctly framed ---------------------
eid="$(exec_stream '["sh","-c","echo out-line; echo err-line 1>&2; echo out-two"]')"
demuxed="$(demux <"${WORK}/exec.bin")"
py_assert 'j["trailing"]==0 and [1,"out-line\nout-two\n"] in j["frames"] and [2,"err-line\n"] in j["frames"]' <<<"${demuxed}" \
    && pass "exec streams stdout (type 1) and stderr (type 2) with 8-byte frames" \
    || fail "exec stream wrong: ${demuxed}"
grep -qi 'content-type: application/vnd.docker.multiplexed-stream' "${WORK}/exec.hdr" \
    && pass "exec Content-Type is the multiplexed stream" || fail "exec Content-Type: $(grep -i content-type "${WORK}/exec.hdr")"
api "http://localhost/exec/${eid}/json" | py_assert 'j["ExitCode"]==0 and j["Running"] is False' \
    && pass "exec exit code readable after the stream ends" || fail "exec inspect after stream"

# --- exec: non-zero exit and empty output ------------------------------------------------------
eid="$(exec_stream '["sh","-c","exit 7"]')"
api "http://localhost/exec/${eid}/json" | py_assert 'j["ExitCode"]==7' \
    && pass "exec propagates a non-zero exit code" || fail "exec exit 7 not propagated"
eid="$(exec_stream '["true"]')"
[[ ! -s "${WORK}/exec.bin" ]] && pass "exec with no output yields an empty body" || fail "exec 'true' produced bytes"

# --- logs: container stdio only (no boot log), framed, tail honored ----------------------------
logs="$(api "http://localhost/containers/${NAME}/logs?stdout=1" | demux)"
py_assert 'j["trailing"]==0 and j["frames"]==[[1,"log-A\nlog-B\nlog-C\n"]]' <<<"${logs}" \
    && pass "logs are framed stdio only; the VM boot log does not leak in" \
    || fail "logs wrong (boot log leak or unframed): ${logs:0:200}"
api "http://localhost/containers/${NAME}/logs?stdout=1&tail=1" | demux | py_assert 'j["frames"]==[[1,"log-C\n"]]' \
    && pass "logs tail=1 returns the last line" || fail "logs tail=1"
api "http://localhost/containers/${NAME}/logs?tail=0" | demux | py_assert 'j["frames"]==[]' \
    && pass "logs tail=0 returns nothing" || fail "logs tail=0"

# --- events: clean JSON lines, from 'now', no historical replay -------------------------------
( api -N -m 6 "http://localhost/events" -o "${WORK}/events.bin" >/dev/null 2>&1 & )
sleep 1
"${CONTAINER_BIN}" pause "${NAME}" >/dev/null 2>&1; "${CONTAINER_BIN}" unpause "${NAME}" >/dev/null 2>&1
sleep 6
python3 - "${WORK}/events.bin" <<'PY' && pass "events: clean JSON lines, only live events (pause, unpause)" || fail "events stream shape"
import json, sys
raw = open(sys.argv[1], "rb").read().decode()
lines = [l for l in raw.split("\n") if l.strip()]
assert lines, "no events received"
assert all(l.startswith("{") for l in lines), "non-JSON line (double chunk framing?): %r" % [l for l in lines if not l.startswith("{")][:2]
actions = [json.loads(l)["Action"] for l in lines]
assert actions == ["pause", "unpause"], "expected only live events, got %r" % actions
PY

printf '\nbridge streams: %d failure(s)\n' "${failures}"
((failures == 0)) && echo "T2_BRIDGE_STREAMS_OK" || exit 1
