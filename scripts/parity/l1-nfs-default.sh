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

# L1 harness: preferred kernel install is NFS-capable (CONTAINER_PREFERRED_KERNEL=nfs).
# Does not build a kernel or mount NFS (CR 06 parked). Asserts CLI/docs/doctor contract.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { printf '[l1-nfs-default] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[l1-nfs-default] %s\n' "$*"; }

[[ -f "${ROOT}/scripts/install-nfs-kernel.sh" ]] || fail "missing install-nfs-kernel.sh"
[[ -f "${ROOT}/scripts/install-recommended-kernel.sh" ]] || fail "missing install-recommended-kernel.sh"
[[ -x "${ROOT}/scripts/install-nfs-kernel.sh" ]] || chmod +x "${ROOT}/scripts/install-nfs-kernel.sh"
[[ -x "${ROOT}/scripts/install-recommended-kernel.sh" ]] || chmod +x "${ROOT}/scripts/install-recommended-kernel.sh"

# Default preference in the wrapper script is nfs.
grep -q 'CONTAINER_PREFERRED_KERNEL:-nfs' "${ROOT}/scripts/install-recommended-kernel.sh" \
  || fail "install-recommended-kernel.sh must default CONTAINER_PREFERRED_KERNEL to nfs"

# KernelSet encodes the same default.
grep -q 'return "nfs"' "${ROOT}/Sources/ContainerCommands/System/Kernel/KernelSet.swift" \
  || fail "KernelSet.preferredKernelPreference must default to nfs"

# system start prefers NFS path.
grep -q 'installPreferredNFSKernel' "${ROOT}/Sources/ContainerCommands/System/SystemStart.swift" \
  || fail "SystemStart must call installPreferredNFSKernel when preference is nfs"

# Doctor + annotate point at preferred path.
grep -q 'CONTAINER_PREFERRED_KERNEL=nfs' "${ROOT}/Sources/Plugins/ContainerCompose/main.swift" \
  || fail "compose doctor nfs-kernel message must mention CONTAINER_PREFERRED_KERNEL=nfs"
grep -q 'CONTAINER_PREFERRED_KERNEL=nfs' "${ROOT}/Sources/Services/RuntimeLinux/Server/RuntimeService.swift" \
  || fail "annotateNFSKernelError must mention CONTAINER_PREFERRED_KERNEL=nfs"

# Docs claim sentence surface.
grep -q 'stock preferred' "${ROOT}/docs/volumes.md" \
  || grep -q 'preferred NFS-capable' "${ROOT}/docs/volumes.md" \
  || fail "docs/volumes.md must describe preferred NFS-capable install"

# Makefile targets exist.
grep -q 'install-recommended-kernel:' "${ROOT}/Makefile" || fail "Makefile missing install-recommended-kernel"
grep -q 'install-nfs-kernel:' "${ROOT}/Makefile" || fail "Makefile missing install-nfs-kernel"

ok "L1_NFS_DEFAULT_OK"
