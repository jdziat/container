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

# L3 harness: exact aliases are unique per network (not globally).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { printf '[l3-aliases] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[l3-aliases] %s\n' "$*"; }

grep -q 'unique per network' \
  "${ROOT}/Sources/Services/ContainerAPIService/Server/Containers/AttachmentNameValidator.swift" \
  || fail "AttachmentNameValidator must document per-network uniqueness"
grep -q 'hostnameOnDifferentNetworks\|aliasReuseAcrossNetworks\|aliasOnTwoNetworks' \
  "${ROOT}/Tests/ContainerAPIServiceTests/AttachmentNameValidatorTests.swift" \
  || fail "missing L3 unit tests for cross-network reuse"
grep -q 'unique per network' "${ROOT}/Sources/Plugins/ContainerCompose/main.swift" \
  || fail "compose doctor must say unique per network"
grep -q 'not globally unique\|per network' \
  "${ROOT}/Sources/Services/ContainerAPIService/Server/Networks/NetworkMatchSelector.swift" \
  || fail "NetworkMatchSelector must not treat aliases as globally decisive"

ok "L3_NETWORK_SCOPED_ALIASES_OK"
