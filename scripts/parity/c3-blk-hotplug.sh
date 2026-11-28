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
