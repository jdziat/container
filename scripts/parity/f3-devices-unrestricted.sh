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

# R2: unrestricted devices (allowlist only when CONTAINER_DEVICE_ALLOWLIST_ONLY=1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { printf '[f3-devices] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[f3-devices] %s\n' "$*"; }

PARSER="${ROOT}/Sources/Services/ContainerAPIService/Client/Parser.swift"
grep -q 'CONTAINER_DEVICE_ALLOWLIST_ONLY' "$PARSER" || fail "Parser missing ALLOWLIST_ONLY opt-out"
grep -q 'Unrestricted by default' "$PARSER" || fail "Parser missing unrestricted claim"
COMPOSE="${ROOT}/Sources/Plugins/ContainerCompose/main.swift"
grep -q 'CONTAINER_DEVICE_ALLOWLIST_ONLY' "$COMPOSE" || fail "Compose missing ALLOWLIST_ONLY"
RUNTIME="${ROOT}/Sources/Services/RuntimeLinux/Server/RuntimeService.swift"
grep -q 'R2: unrestricted host devices' "$RUNTIME" || fail "RuntimeService missing device mounts"
grep -q 'st_rdev' "$RUNTIME" || fail "RuntimeService missing rdev/mknod-equivalent mapping"
grep -q 'USB mass-storage' "$RUNTIME" || fail "RuntimeService missing USB mass-storage note"
ok "F3_DEVICES_UNRESTRICTED_OK"
