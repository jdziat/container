# CTO stamp — post-freeze parity productization

_Date: 2026-11-20_

## Verdict

**GO** to treat post job-catalog work as **productization packs** under the closed SKU
**“Job-catalog full Docker parity (ex-Swarm)”**, per
[2026-11-19-post-freeze-parity-productization.prd.md](2026-11-19-post-freeze-parity-productization.prd.md).

This does **not** reopen the catalog, Swarm, host `devices`, live NIC hotplug, full Engine
OpenAPI, in-core `/var/run/docker.sock`, or CR-as-default VMM.

## Pack status

| Pack | Status | Evidence |
|------|--------|----------|
| **SKU / terminus (T1)** | Done | Remaining-parity backlog superseded; catalog cross-link |
| **A — NFS kernel** | Done (first-class **alternate**) | `make install-nfs-kernel` / `install-container-nfs-kernel`; `docs/volumes.md#nfs-mounts`; annotate points at install |
| **B — Compose preflight** | Done | `container compose doctor` (+ `--strict`); VM-lifecycle dialect on connect `--restart` |
| **C — Expansion packs** | Defined, **none shipped** | [expansion-pack-template.md](expansion-pack-template.md) |
| **CR carrier (opt-in)** | Proven (2026-11-20) | J1–J4 + curated compose under `CONTAINER_VMM_CR=1`; see [parity-terminus-support.md](../parity-terminus-support.md) |

## Language allowed

- Existing achievement phrases (job-catalog full Docker parity ex-Swarm; curated bridge; complete guest DNS)
- “First-class NFS-capable kernel alternate” via `make install-nfs-kernel`
- “restart-as-API” for `network connect` / `disconnect` on running containers (permanent per-VM contract for this track)
- “Compose doctor preflight” for loud edges

## Language still forbidden

- Unqualified “full Engine API” / bit-identical Docker Desktop
- Swarm, host `devices`, live NIC hotplug as done
- Zero-config Testcontainers / Dev Containers without a shipped Pack C claim
- Calling Pack C “defined” packs “supported” without harness + claim sentence

## Residuals (not catalog debt at freeze)

- Stock `--recommended` kernel may still omit `nfs` — use Pack A alternate
- Exact aliases globally unique; named volume single-writer; bridge outside-matrix 501
- Pack C packs remain opt-in until shipped under the template gate

_Update 2026-11-21:_ a subset of those residuals are **open product goals** in
[2026-11-21-beyond-terminus-goals.prd.md](2026-11-21-beyond-terminus-goals.prd.md)
(active: L1–L4, L6, F2, F5). OpenAPI + Swarm stay out. CR corpus / CR-default / devices /
hotplug are **parked** until explicitly reopened. This stamp’s freeze history is unchanged.
