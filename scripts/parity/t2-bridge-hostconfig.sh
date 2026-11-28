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

# Engine bridge HostConfig contract: the bridge must HONOR what the per-VM model supports and
# REJECT (400, naming the key) what it cannot, never silently ignore. A caller that sends
# HostConfig.CapAdd and gets 201 believes it was applied.
#
# Equally important: real clients send a full HostConfig of DEFAULTS on every create, so
# defaults must be accepted or every client breaks.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
BRIDGE_BIN="${BRIDGE_BIN:-${ROOT}/.build/arm64-apple-macosx/debug/container-docker-api-bridge}"
IMAGE="${PARITY_IMAGE:-alpine:3.20}"
SUFFIX="$$"
SOCK="${TMPDIR:-/tmp}/parity-hostcfg-${SUFFIX}.sock"
NET="parity-hcnet-${SUFFIX}"
WORK="$(mktemp -d)"

failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

cleanup() {
    [[ -n "${bridge_pid:-}" ]] && { kill "${bridge_pid}" >/dev/null 2>&1 || true; wait "${bridge_pid}" 2>/dev/null || true; }
    # `create` runs inside $(...), a subshell, so it cannot record names in a shared array.
    # Clean up by this run's unique name prefix instead.
    "${CONTAINER_BIN}" ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^hc-.*-${SUFFIX}\$" \
        | while read -r n; do "${CONTAINER_BIN}" delete -f "${n}" >/dev/null 2>&1; done
    "${CONTAINER_BIN}" network delete "${NET}" >/dev/null 2>&1
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
# create <name> <json-body>  -> prints HTTP status; response body in ${WORK}/c.json
create() { api -o "${WORK}/c.json" -w '%{http_code}' -X POST "http://localhost/containers/create?name=$1" -H 'Content-Type: application/json' -d "$2"; }
msg() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("message",""))' "${WORK}/c.json"; }

"${BRIDGE_BIN}" serve --socket "${SOCK}" >"${WORK}/bridge.log" 2>&1 &
bridge_pid=$!
for _ in $(seq 1 50); do [[ -S "${SOCK}" ]] && break; sleep 0.1; done
[[ -S "${SOCK}" ]] || { cat "${WORK}/bridge.log" >&2; echo "bridge socket not created" >&2; exit 2; }
"${CONTAINER_BIN}" image pull "${IMAGE}" >/dev/null 2>&1

# 1. A real client's full default HostConfig is accepted.
DEFAULTS='{"Binds":null,"ContainerIDFile":"","LogConfig":{"Type":"","Config":{}},"NetworkMode":"default","PortBindings":{},"RestartPolicy":{"Name":"","MaximumRetryCount":0},"AutoRemove":false,"VolumeDriver":"","VolumesFrom":null,"CapAdd":null,"CapDrop":null,"Dns":[],"DnsOptions":[],"DnsSearch":[],"ExtraHosts":null,"GroupAdd":null,"IpcMode":"","Cgroup":"","Links":null,"OomScoreAdj":0,"PidMode":"","Privileged":false,"PublishAllPorts":false,"ReadonlyRootfs":false,"SecurityOpt":null,"UTSMode":"","UsernsMode":"","ShmSize":0,"Isolation":"","CpuShares":0,"Memory":0,"NanoCpus":0,"CgroupParent":"","BlkioWeight":0,"CpuPeriod":0,"CpuQuota":0,"CpusetCpus":"","CpusetMems":"","Devices":[],"DeviceCgroupRules":null,"MemoryReservation":0,"MemorySwap":0,"OomKillDisable":false,"PidsLimit":-1,"ConsoleSize":[0,0],"MemorySwappiness":-1,"Ulimits":null,"CpuCount":0,"CpuPercent":0,"Init":null}'
code="$(create "hc-default-${SUFFIX}" "{\"Image\":\"${IMAGE}\",\"Cmd\":[\"sleep\",\"120\"],\"HostConfig\":${DEFAULTS}}")"
[[ "${code}" == "201" ]] && pass "a full default HostConfig (real-client shape) is accepted" || fail "default HostConfig rejected: HTTP ${code} $(msg)"

# 2. Unsupported non-default values are rejected, naming every offending key.
code="$(create "hc-bad-${SUFFIX}" "{\"Image\":\"${IMAGE}\",\"HostConfig\":{\"PidsLimit\":50,\"SecurityOpt\":[\"seccomp=unconfined\"],\"PidMode\":\"host\"}}")"
text="$(msg)"
if [[ "${code}" == "400" && "${text}" == *PidsLimit* && "${text}" == *SecurityOpt* && "${text}" == *PidMode* ]]; then
    pass "unsupported HostConfig values are rejected, naming each key"
else
    fail "unsupported HostConfig: HTTP ${code} ${text}"
fi
code="$(create "hc-host-${SUFFIX}" "{\"Image\":\"${IMAGE}\",\"HostConfig\":{\"NetworkMode\":\"host\"}}")"
[[ "${code}" == "400" ]] && pass "NetworkMode=host is rejected" || fail "NetworkMode=host: HTTP ${code}"
code="$(create "hc-nonet-${SUFFIX}" "{\"Image\":\"${IMAGE}\",\"HostConfig\":{\"NetworkMode\":\"no-such-net-${SUFFIX}\"}}")"
[[ "${code}" == "404" ]] && pass "NetworkMode naming a missing network is 404" || fail "missing network: HTTP ${code}"
code="$(create "hc-badip-${SUFFIX}" "{\"Image\":\"${IMAGE}\",\"HostConfig\":{\"ExtraHosts\":[\"x:not-an-ip\"]}}")"
[[ "${code}" == "400" ]] && pass "malformed ExtraHosts is a 400, not a 500" || fail "bad ExtraHosts: HTTP ${code}"

# 3. Supported keys take effect inside the guest.
"${CONTAINER_BIN}" network create "${NET}" >/dev/null 2>&1
CTR="hc-mapped-${SUFFIX}"
body="{\"Image\":\"${IMAGE}\",\"Cmd\":[\"sleep\",\"120\"],\"HostConfig\":{\"NetworkMode\":\"${NET}\",\"ExtraHosts\":[\"db.internal:10.9.8.7\"],\"Sysctls\":{\"net.ipv4.ip_forward\":\"1\"},\"CapAdd\":[\"NET_ADMIN\"],\"Privileged\":true,\"Dns\":[\"1.1.1.1\"]},\"NetworkingConfig\":{\"EndpointsConfig\":{\"${NET}\":{\"Aliases\":[\"svc-alias\"]}}}}"
code="$(create "${CTR}" "${body}")"
if [[ "${code}" != "201" ]]; then fail "mapped create: HTTP ${code} $(msg)"; else
    cid="$(python3 -c 'import json; print(json.load(open("'"${WORK}"'/c.json"))["Id"])')"
    python3 -c 'import json,sys; w=json.load(open(sys.argv[1])).get("Warnings") or []; sys.exit(0 if any("Privileged" in x for x in w) else 1)' "${WORK}/c.json" \
        && pass "Privileged:true is accepted AND reported in the create Warnings" || fail "Privileged:true produced no Warning"
    api -X POST "http://localhost/containers/${cid}/start" -o /dev/null; sleep 3
    ex() { "${CONTAINER_BIN}" exec "${CTR}" "$@" 2>&1 | grep -v '^Warning! Running debug'; }
    [[ "$(ex grep -c 10.9.8.7 /etc/hosts)" == "1" ]] && pass "ExtraHosts reaches /etc/hosts" || fail "ExtraHosts not in guest /etc/hosts"
    [[ "$(ex cat /proc/sys/net/ipv4/ip_forward)" == "1" ]] && pass "Sysctls applied in the guest" || fail "Sysctls not applied"
    # With the in-guest hosts-dns helper, resolv.conf is 127.0.0.1 and the helper forwards to
    # the configured nameserver, exactly as for `container run --dns`.
    [[ "$(ex ps)" == *"--forward 1.1.1.1"* ]] && pass "Dns becomes the hosts-dns forward target" || fail "Dns not applied"
    "${CONTAINER_BIN}" inspect "${CTR}" 2>&1 | python3 -c '
import json,sys
raw=sys.stdin.read(); d=json.loads(raw[raw.index("["):])[0]
nets=d["configuration"]["networks"]
assert len(nets)==1 and nets[0]["network"]=="'"${NET}"'", nets
assert "svc-alias" in nets[0]["options"]["aliases"], nets
assert d["configuration"]["capAdd"], "capAdd empty"
' && pass "NetworkMode attaches the named network with its aliases; CapAdd persisted" || fail "network attachment/aliases/capAdd"
fi

printf '\nbridge hostconfig: %d failure(s)\n' "${failures}"
((failures == 0)) && echo "T2_BRIDGE_HOSTCONFIG_OK" || exit 1
