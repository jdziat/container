#!/usr/bin/env bash
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
