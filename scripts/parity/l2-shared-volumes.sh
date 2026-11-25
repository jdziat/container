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

# L2 harness: default named volumes use shared virtiofs plane (strategy lock).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { printf '[l2-volumes] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[l2-volumes] %s\n' "$*"; }

[[ -f "${ROOT}/docs/plans/2026-11-21-l2-strategy-lock.md" ]] || fail "missing L2 strategy lock"
grep -q 'Default local named volumes use a shared host-directory virtiofs plane' \
  "${ROOT}/docs/plans/2026-11-21-l2-strategy-lock.md" \
  || fail "strategy lock no longer asserts virtiofs default"
grep -q 'isSharedVirtiofsVolume' "${ROOT}/Sources/ContainerResource/Container/Filesystem.swift" \
  || fail "Filesystem.isSharedVirtiofsVolume missing"
grep -q 'validateExclusiveNamedVolumes' \
  "${ROOT}/Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift" \
  || fail "ContainersService.validateExclusiveNamedVolumes missing"
grep -q 'createVolumeDataDirectory\|format: "directory"' \
  "${ROOT}/Sources/Services/ContainerAPIService/Server/Volumes/VolumesService.swift" \
  || fail "VolumesService directory/virtiofs backend missing"
# Default path must return false (directory), not true (block).
grep -q 'return false' \
  "${ROOT}/Sources/Services/ContainerAPIService/Server/Volumes/VolumesService.swift" \
  || fail "VolumesService missing directory-default return"
# Fail closed if someone reverts to unconditional `return true` as the default arm.
if awk '
  /private static func usesBlockBackend/,/^    }$/ {
    if ($0 ~ /return true/ && $0 !~ /size|journal|block|ext4/) hit=1
    if ($0 ~ /\/\/ Explicit size\/journal/ || $0 ~ /return false/) def=1
  }
  END { exit (def ? 0 : 1) }
' "${ROOT}/Sources/Services/ContainerAPIService/Server/Volumes/VolumesService.swift"; then
  :
else
  fail "usesBlockBackend default arm is not directory (return false)"
fi
grep -q 'shared virtiofs' "${ROOT}/docs/volumes.md" || fail "volumes.md missing shared virtiofs docs"
grep -q 'Default.*virtiofs\|default local named volumes share via the virtiofs\|Default (shared virtiofs)' \
  "${ROOT}/docs/volumes.md" \
  || fail "volumes.md must claim virtiofs as default"

ok "L2_SHARED_VOLUMES_OK"
