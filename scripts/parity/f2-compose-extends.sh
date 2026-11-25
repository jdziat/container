#!/usr/bin/env bash
# F2 harness: Compose extends merge is implemented (contract + optional plan smoke).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
FIX_DIR="$(mktemp -d -t f2-extends.XXXXXX)"
fail() { printf '[f2-extends] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[f2-extends] %s\n' "$*"; }
cleanup() { rm -rf "${FIX_DIR}"; }
trap cleanup EXIT

grep -q 'resolveExtends' "${ROOT}/Sources/Plugins/ContainerCompose/main.swift" \
  || fail "resolveExtends missing"
grep -q 'deepMergeComposeService' "${ROOT}/Sources/Plugins/ContainerCompose/main.swift" \
  || fail "deepMergeComposeService missing"
grep -q 'parseExtendsSpec' "${ROOT}/Sources/Plugins/ContainerCompose/main.swift" \
  || fail "parseExtendsSpec missing"

cat > "${FIX_DIR}/base.yaml" <<'EOF'
services:
  base:
    image: docker.io/library/alpine:3.20
    environment:
      FROM_BASE: "1"
      SHARED: base
    command: ["sh", "-c", "echo base && sleep 1"]
EOF

cat > "${FIX_DIR}/compose.yaml" <<'EOF'
services:
  app:
    extends:
      file: base.yaml
      service: base
    environment:
      SHARED: child
      FROM_CHILD: "1"
    command: ["sh", "-c", "echo app && sleep 1"]
EOF

# Static merge-bounds contract (child scalar wins; list env concatenates).
grep -q 'child' "${ROOT}/Sources/Plugins/ContainerCompose/main.swift" \
  || fail "deep-merge child-wins contract missing from compose sources"
grep -q 'concatenate\|concat' "${ROOT}/docs/compose-support-matrix.md" \
  || fail "compose-support-matrix must document list concat for extends"

if [[ -x "${CONTAINER_BIN}" ]]; then
  out="$("${CONTAINER_BIN}" compose config -f "${FIX_DIR}/compose.yaml" -p f2ext 2>&1)" \
    || fail "compose config failed on extends fixture: ${out}"
  if printf '%s\n' "${out}" | grep -qi 'extends.*not implemented\|unsupported.*extends'; then
    fail "extends still treated as unsupported: ${out}"
  fi
  # Child env wins on SHARED; both FROM_BASE and FROM_CHILD present after merge.
  printf '%s\n' "${out}" | grep -Eq 'SHARED[=:].*child|SHARED:[[:space:]]*child' \
    || fail "extends merge must keep child SHARED=child: ${out}"
  printf '%s\n' "${out}" | grep -Fq 'FROM_BASE' \
    || fail "extends merge must retain base env FROM_BASE: ${out}"
  printf '%s\n' "${out}" | grep -Fq 'FROM_CHILD' \
    || fail "extends merge must retain child env FROM_CHILD: ${out}"
  ok "compose config merge bounds (child wins / list concat)"
else
  fail "CONTAINER_BIN=${CONTAINER_BIN} missing; build with make cli/container before F2"
fi

ok "F2_COMPOSE_EXTENDS_OK"
