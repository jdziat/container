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

# R1 live: network connect prefers hotplug (no stop+start) on VZ or CR.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
fail() { printf '[f4-live] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[f4-live] %s\n' "$*"; }
[[ -x "$CONTAINER_BIN" ]] || fail "missing $CONTAINER_BIN"

json_from_inspect() {
  # Debug builds print a warning on stdout before JSON; keep from the array marker.
  "$CONTAINER_BIN" inspect "$1" 2>/dev/null | sed -n '/^\[/,$p'
}

BACKEND="${CONTAINER_VMM_BACKEND:-vz}"
export CONTAINER_VMM_BACKEND="$BACKEND"
export CONTAINER_NET_HOTPLUG=1
export CONTAINER_NET_HOTPLUG_STRICT="${CONTAINER_NET_HOTPLUG_STRICT:-1}"
# Stay under VZ's 4-NIC ceiling (1 primary + spares).
export CONTAINER_VZ_NIC_SPARES="${CONTAINER_VZ_NIC_SPARES:-2}"
"$CONTAINER_BIN" system start --timeout 90 >/dev/null 2>&1 || true

NET="f4net-$$"
CTR="f4ctr-$$"
"$CONTAINER_BIN" network delete "$NET" >/dev/null 2>&1 || true
"$CONTAINER_BIN" delete -f "$CTR" >/dev/null 2>&1 || true
"$CONTAINER_BIN" network create "$NET" >/dev/null
id=$("$CONTAINER_BIN" run -d --name "$CTR" alpine:3.20 sleep 600)
ok "started $id backend=$BACKEND"

# Record primary IP; hotplug must not bounce the VM (IP should stay stable).
ip1=$(json_from_inspect "$CTR" | python3 -c 'import json,sys
d=json.load(sys.stdin)[0]
nets=d.get("status",{}).get("networks") or []
print(nets[0].get("ipv4Address") or "" if nets else "")')

"$CONTAINER_BIN" network connect "$NET" "$CTR"

net_count=$(json_from_inspect "$CTR" | python3 -c 'import json,sys
d=json.load(sys.stdin)[0]
cfg=len(d.get("configuration",{}).get("networks") or [])
st=len(d.get("status",{}).get("networks") or [])
print(max(cfg, st))')
[[ "$net_count" -ge 2 ]] || fail "expected ≥2 networks after connect, got $net_count"

# Guest must show eth1 with an address (live hotplug, not config-only).
eth1=$("$CONTAINER_BIN" exec "$CTR" ip addr show eth1 2>/dev/null | sed '/Warning/d' || true)
echo "$eth1" | grep -q 'inet ' || fail "eth1 missing inet after connect: $eth1"

ip2=$(json_from_inspect "$CTR" | python3 -c 'import json,sys
d=json.load(sys.stdin)[0]
nets=d.get("status",{}).get("networks") or []
print(nets[0].get("ipv4Address") or "" if nets else "")')
[[ -n "$ip1" && "$ip1" == "$ip2" ]] || fail "primary IP changed after connect ($ip1 -> $ip2); likely restart fallback"

# Secondary disconnect should not require restart under hotplug.
"$CONTAINER_BIN" network disconnect "$NET" "$CTR"
state=$("$CONTAINER_BIN" list -a 2>/dev/null | awk -v n="$id" '$0 ~ n {print; exit}' || true)
echo "$state" | grep -qi running || fail "container not running after disconnect: $state"

ip3=$(json_from_inspect "$CTR" | python3 -c 'import json,sys
d=json.load(sys.stdin)[0]
nets=d.get("status",{}).get("networks") or []
print(nets[0].get("ipv4Address") or "" if nets else "")')
[[ -n "$ip1" && "$ip1" == "$ip3" ]] || fail "primary IP changed after disconnect ($ip1 -> $ip3); likely restart fallback"

"$CONTAINER_BIN" delete -f "$CTR" >/dev/null 2>&1 || true
"$CONTAINER_BIN" network delete "$NET" >/dev/null 2>&1 || true
ok "F4_VZ_NET_HOTPLUG_LIVE_OK backend=$BACKEND"
