#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
fail() { printf '[f3-live] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[f3-live] %s\n' "$*"; }
[[ -x "$CONTAINER_BIN" ]] || fail "missing $CONTAINER_BIN"
"$CONTAINER_BIN" system start --timeout 90 >/dev/null 2>&1 || true
NAME="f3-dev-$$"
"$CONTAINER_BIN" delete -f "$NAME" >/dev/null 2>&1 || true
out=$(CONTAINER_VMM_BACKEND=cr "$CONTAINER_BIN" run --rm --name "$NAME" --device /dev/null:/dev/host-null alpine:3.20 \
  sh -c 'ls -la /dev/host-null; test -e /dev/host-null && echo F3_DEVICE_OK') || fail "run --device failed"
echo "$out" | grep -q F3_DEVICE_OK || { echo "$out" >&2; fail "guest missing /dev/host-null"; }
# Parser must accept unrestricted non-allowlist paths (e.g. /dev/stdout is not a device - skip)
ok "F3_DEVICES_LIVE_OK"
