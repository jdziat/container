#!/usr/bin/env bash
# C3 gate: container Sources expose RuntimeService → CRVirtualMachineInstance.hotplug.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { printf '[c3-blk-hotplug] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[c3-blk-hotplug] %s\n' "$*"; }

SVC="${ROOT}/Sources/Services/RuntimeLinux/Server/RuntimeService.swift"
grep -q 'hotplugBlock' "$SVC" || fail "RuntimeService.hotplugBlock missing"
grep -q 'cr.hotplug(' "$SVC" || fail "RuntimeService must call cr.hotplug("
grep -q 'hotplugBlock' "${ROOT}/Sources/Services/Runtime/RuntimeClient/RuntimeRoutes.swift" \
  || fail "RuntimeRoutes.hotplugBlock missing"
grep -q 'hotplugBlock' "${ROOT}/Sources/Services/Runtime/RuntimeClient/RuntimeClient.swift" \
  || fail "RuntimeClient.hotplugBlock missing"
grep -q 'hotplugBlock' "${ROOT}/Sources/Plugins/RuntimeLinux/RuntimeLinuxHelper+Start.swift" \
  || fail "RuntimeLinuxHelper route registration missing"

ok "C3_BLK_HOTPLUG_OK"
