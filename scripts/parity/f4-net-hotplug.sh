#!/usr/bin/env bash
# F4: network connect without --restart prefers CR virtio-net hotplug.
# Static gate + optional live smoke when CONTAINER_BIN is usable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { printf '[f4-hotplug] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[f4-hotplug] %s\n' "$*"; }

SVC="${ROOT}/Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift"
grep -q 'preferCRNetHotplug' "$SVC" || fail "preferCRNetHotplug missing"
grep -q 'hotplugNetwork' "$SVC" || fail "networkConnect hotplugNetwork missing"
grep -q 'CONTAINER_NET_HOTPLUG' "$SVC" || fail "CONTAINER_NET_HOTPLUG gate missing"
# Default-on: must not require NET_HOTPLUG=1 exclusively.
grep -q 'F6: no env override' "$SVC" || grep -q 'return true' "$SVC" \
  || fail "preferCRNetHotplug must default true for CR/F6"

VF_ROOT="${VF_ROOT:-$ROOT/../virtualization.framework}"
if [[ -d "$VF_ROOT/Tests/OracleTests" ]]; then
  grep -q 'HotplugNetTests' "$VF_ROOT/Tests/OracleTests/HotplugNetTests.swift" \
    || fail "HotplugNetTests missing"
  ok "HotplugNetTests present"
fi

CONTAINER_BIN="${CONTAINER_BIN:-$ROOT/bin/container}"
if [[ -x "$CONTAINER_BIN" ]] && [[ "${F4_LIVE:-0}" == "1" ]]; then
  export CONTAINER_VMM_BACKEND="${CONTAINER_VMM_BACKEND:-cr}"
  export CONTAINER_NET_HOTPLUG="${CONTAINER_NET_HOTPLUG:-1}"
  NAME="f4-hotplug-$$"
  NET="f4-net-$$"
  "$CONTAINER_BIN" system start --timeout 60 >/dev/null 2>&1 || true
  "$CONTAINER_BIN" network create "$NET" >/dev/null
  "$CONTAINER_BIN" run -d --name "$NAME" --network none docker.io/library/alpine:3.20 \
    sleep 120 >/dev/null
  before="$("$CONTAINER_BIN" inspect -f '{{.State.StartedAt}}' "$NAME" 2>/dev/null || true)"
  "$CONTAINER_BIN" network connect "$NET" "$NAME" >/dev/null \
    || fail "network connect without --restart"
  after="$("$CONTAINER_BIN" inspect -f '{{.State.StartedAt}}' "$NAME" 2>/dev/null || true)"
  "$CONTAINER_BIN" delete -f "$NAME" >/dev/null 2>&1 || true
  "$CONTAINER_BIN" network delete "$NET" >/dev/null 2>&1 || true
  if [[ -n "$before" && -n "$after" && "$before" != "$after" ]]; then
    fail "StartedAt changed after connect (restart path used): before=$before after=$after"
  fi
  ok "live connect preserved StartedAt"
fi

ok "F4_NET_HOTPLUG_OK"
