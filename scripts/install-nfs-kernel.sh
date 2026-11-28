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

# Build and install a Containerization NFS-enabled guest kernel.
#
# This is the **stock / preferred** kernel install path for NFS users
# (CONTAINER_PREFERRED_KERNEL=nfs, default). The historic Kata
# `container system kernel set --recommended` tarball often omits `nfs` from
# /proc/filesystems; guest NFS mounts then fail with ENODEV and RuntimeService
# annotates that case pointing here.
#
# Preferred entrypoints (all install this NFS-capable kernel when preference is nfs):
#   make install-recommended-kernel   # respects CONTAINER_PREFERRED_KERNEL (default nfs)
#   make install-nfs-kernel           # always NFS-capable
#   install-container-nfs-kernel      # when installed from the package
#   ./scripts/install-nfs-kernel.sh
#   ./scripts/install-recommended-kernel.sh
#
# Usage:
#   CONTAINERIZATION_ROOT=/path/to/containerization ./scripts/install-nfs-kernel.sh
#   # or, if sibling checkout exists:
#   ./scripts/install-nfs-kernel.sh
#
# Env:
#   CONTAINERIZATION_ROOT  Checkout with kernel/ (default: ../containerization next to this repo)
#   CONTAINER_BIN          container CLI (default: bin/container in this repo, else PATH)
#   ARCH                   arm64|amd64 (default: host)
#   FORCE                  1 to pass --force (default: 1)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CZ_ROOT="${CONTAINERIZATION_ROOT:-${ROOT}/../containerization}"
CONTAINER_BIN="${CONTAINER_BIN:-}"
FORCE="${FORCE:-1}"

log() { printf '[install-nfs-kernel] %s\n' "$*"; }
fail() { printf '[install-nfs-kernel] FAIL: %s\n' "$*" >&2; exit 1; }

if [[ -z "${CONTAINER_BIN}" ]]; then
  if [[ -x "${ROOT}/bin/container" ]]; then
    CONTAINER_BIN="${ROOT}/bin/container"
  else
    CONTAINER_BIN="$(command -v container)"
  fi
fi

arch_default() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64) echo amd64 ;;
    *)
      printf 'unsupported host arch %s (set ARCH=arm64|amd64)\n' "$(uname -m)" >&2
      return 1
      ;;
  esac
}
ARCH="${ARCH:-$(arch_default)}" || fail "could not determine ARCH"
case "${ARCH}" in
  arm64|aarch64) ARCH=arm64 ;;
  amd64|x86_64) ARCH=amd64 ;;
  *) fail "unsupported ARCH=${ARCH} (use arm64|amd64)" ;;
esac

[[ -x "${CONTAINER_BIN}" ]] || fail "missing container binary (${CONTAINER_BIN})"
[[ -d "${CZ_ROOT}/kernel" ]] || fail "CONTAINERIZATION_ROOT=${CZ_ROOT} has no kernel/ — clone apple/containerization and set CONTAINERIZATION_ROOT"

log "building NFS-enabled kernel in ${CZ_ROOT}/kernel (arch=${ARCH})"
make -C "${CZ_ROOT}/kernel" "ARCH=${ARCH}"

# Preferred artifact names from Containerization kernel build (arch-specific only).
candidates=(
  "${CZ_ROOT}/kernel/vmlinux-${ARCH}"
  "${CZ_ROOT}/kernel/bin/vmlinux-${ARCH}"
  "${CZ_ROOT}/kernel/out/vmlinux-${ARCH}"
)
binary=""
for c in "${candidates[@]}"; do
  if [[ -f "${c}" ]]; then
    binary="${c}"
    break
  fi
done
[[ -n "${binary}" ]] || fail "built kernel binary not found under ${CZ_ROOT}/kernel (looked for vmlinux-${ARCH})"

force_flag=()
if [[ "${FORCE}" == "1" ]]; then
  force_flag=(--force)
fi

log "installing ${binary} via ${CONTAINER_BIN} system kernel set --arch ${ARCH}"
"${CONTAINER_BIN}" system kernel set --arch "${ARCH}" --binary "${binary}" "${force_flag[@]}"
log "done. Verify in a guest: grep -w nfs /proc/filesystems"
log "See docs/volumes.md#nfs-mounts"
