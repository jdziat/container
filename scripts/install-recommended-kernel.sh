#!/usr/bin/env bash
# Install the preferred guest kernel.
#
# Default CONTAINER_PREFERRED_KERNEL=nfs installs the NFS-capable Containerization
# kernel (stock path for NFS / Compose users). Set CONTAINER_PREFERRED_KERNEL=kata
# (or stock|recommended) for the historic Kata debug --recommended tarball.
#
# Entrypoints:
#   make install-recommended-kernel
#   ./scripts/install-recommended-kernel.sh
#   make install-nfs-kernel   # always NFS-capable, ignores preference
#
# See docs/volumes.md#nfs-mounts
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREF="${CONTAINER_PREFERRED_KERNEL:-nfs}"
PREF="$(printf '%s' "${PREF}" | tr '[:upper:]' '[:lower:]')"

log() { printf '[install-recommended-kernel] %s\n' "$*"; }
fail() { printf '[install-recommended-kernel] FAIL: %s\n' "$*" >&2; exit 1; }

case "${PREF}" in
  nfs|"")
    log "CONTAINER_PREFERRED_KERNEL=${PREF:-nfs}: installing NFS-capable kernel (stock path)"
    exec "${ROOT}/scripts/install-nfs-kernel.sh" "$@"
    ;;
  kata|stock|recommended)
    CONTAINER_BIN="${CONTAINER_BIN:-}"
    if [[ -z "${CONTAINER_BIN}" ]]; then
      if [[ -x "${ROOT}/bin/container" ]]; then
        CONTAINER_BIN="${ROOT}/bin/container"
      else
        CONTAINER_BIN="$(command -v container)" || fail "missing container binary"
      fi
    fi
    [[ -x "${CONTAINER_BIN}" ]] || fail "missing container binary (${CONTAINER_BIN})"
    log "CONTAINER_PREFERRED_KERNEL=${PREF}: installing Kata stock --recommended kernel"
    # Force kata path inside KernelSet so we do not recurse into this script.
    CONTAINER_PREFERRED_KERNEL=kata exec "${CONTAINER_BIN}" system kernel set --recommended "$@"
    ;;
  *)
    fail "unknown CONTAINER_PREFERRED_KERNEL=${PREF} (use nfs|kata|stock|recommended)"
    ;;
esac
