# CTO stamp — F3 host devices allowlist (GO)

_Date: 2026-11-21_  
_Scope:_ Compose `devices` / `container run --device` **allowlist-only** interim  
_Inputs:_ [compose-support-matrix.md](../compose-support-matrix.md), [parity-matrix.md](../parity-matrix.md)

## 1. Verdict

**GO** for allowlist-only host device acceptance.

## 2. Contract

- Default allowlist: `/dev/null`, `/dev/zero`, `/dev/urandom`, `/dev/tty`
- Extend with comma-separated `CONTAINER_DEVICE_ALLOWLIST` (absolute host paths)
- Fail closed on any other host path with a clear error
- Compose maps `devices:` → `container run --device`
- Guest already provides the default chardevs; mapping is persisted for inspect/parity (no full host device remount / PCI passthrough)

## 3. Forbidden reopen

Arbitrary host device passthrough, GPU/USB/block remount as “done”, or claiming Docker Desktop device density.

## 4. Claim sentence

> “Compose `devices` and `run --device` accept an allowlisted subset (`/dev/null`, `/dev/zero`, `/dev/urandom`, `/dev/tty`; extend via `CONTAINER_DEVICE_ALLOWLIST`); other host devices fail closed — `done (interim)`.”
