# Parity terminus — support one-pager

> **Under re-verification (2026-11-25).** The "achieved" and "shipped" statements below
> were produced by harnesses that mostly `grep` source text and that no CI job ran. An audit
> against the built binaries found real gaps and several claims the code could not back; see
> [plans/2026-11-24-parity-remediation.plan.md](plans/2026-11-24-parity-remediation.plan.md).
> Behavioral evidence now lives in `make parity-behavioral`
> (`scripts/parity/cli-surface.sh`, `t2-docker-corpus.sh`, `t2-bridge-*.sh`). Where this page and
> [parity-matrix.md](parity-matrix.md) disagree, the matrix is current.

_Date: 2026-11-20_ (_updated 2026-11-21_)

One page for support and release notes after the full-parity push. This is the
closed SKU story; **open product goals** live in
[beyond-terminus](plans/2026-11-21-beyond-terminus-goals.prd.md). New desires
need a **named PRD**, not “parity incomplete.”

## What is frozen / proven

| Lane | Claim | Evidence |
|------|-------|----------|
| **SKU (VMM)** | Stock build uses Apple Virtualization (VZ). CR is opt-in: build with `CONTAINER_VMM_CR=1` (links the sibling CRVirtualization fork) | [docker-job-catalog.md](docker-job-catalog.md); `CONTAINER_VMM_BACKEND=vz` for Apple VF |
| **CR carrier** | Same frozen jobs J1–J4 + curated compose (build `CONTAINER_VMM_CR=1`) | CR catalog/compose e2e scripts |
| **Pack A / L1 — NFS kernel** | Preferred install (`CONTAINER_PREFERRED_KERNEL=nfs`) | `make install-recommended-kernel`; `make l1-nfs-default` |
| **Pack B — migrant UX** | Compose doctor + VM-lifecycle dialect | `container compose doctor` (+ `--strict`) |
| **Pack C — expansions** | **R5 shipped** (C1 corpus + C2 client smoke) | `make bridge-corpus-parity`; `make t2-client-smoke`; [pack-c plan](plans/2026-11-21-pack-c-expansions.plan.md) |

CTO stamps: [productization](plans/cto-post-freeze-productization-2026-11-20.md),
[beyond-terminus GO](plans/cto-beyond-terminus-go-2026-11-21.md),
[wave validation](plans/cto-beyond-terminus-wave-validation-2026-11-21.md),
[ABC full-parity review](plans/cto-abc-full-parity-review-2026-11-21.md),
[ABC residuals recheck](plans/cto-abc-residuals-recheck-2026-11-21.md).

## Language allowed

- A Docker-style CLI and a curated Docker Engine API subset (Unix socket) for common single-host container, image, volume and network workflows; the documented Compose subset; in-guest DNS for bare service names. Not: "full Docker parity", "parity achieved", "drop-in replacement" without "for the documented subset".
- A stock build uses Apple Virtualization (VZ). CR requires a `CONTAINER_VMM_CR=1` build; the installed `vmm-backend` sidecar now says `cr` only for such builds
- Preferred NFS-capable kernel; Recipe B (`install-engine-sock.sh`) for sock consumers;
  network-scoped aliases; shared virtiofs named volumes (default)
- Compose `extends` supported; host `devices` unrestricted (R2; allowlist opt-out); live NIC hotplug in `CONTAINER_VMM_CR=1` builds only (R1; the stock build restarts the container); in-core `/var/run/docker.sock` default on (R3). `container-gui` (R6) is an early list/start/stop/logs shell with no framebuffer host and is not a supported surface.

## Language forbidden

- “Full Docker Desktop,” unqualified “full Engine OpenAPI,” Swarm as supported
- Calling Pack C “full Engine OpenAPI” without matrix bounds

## Loud edges → beyond-terminus status

> The `make l1-…/l2-…/l3-…/f2-…/f3-…/f4-…/f5-…/c3-…` evidence below is **static** (it greps source and docs for symbols and comments, and passes when the build is broken). It records where code exists, not that behavior works. Behavioral evidence is `make parity-behavioral`.


| Edge | Status | Evidence |
|------|--------|----------|
| NFS kernel | **L1 shipping** | `make l1-nfs-default` |
| Named volume multi-writer | **L2 shipping** | virtiofs default (strategy lock); `--opt backend=block` exclusive |
| Exact aliases | **L3 shipping** | per-network; `make l3-network-scoped-aliases` |
| docker.sock consumers | **L4 Recipe B**; **R3 / F5 default on** | In-core `/var/run/docker.sock` default; opt-out `CONTAINER_INCORE_DOCKER_SOCK=0`; `make f5-incore-sock` |
| Bridge outside matrix 501 | **L6 gated** | Phase 0 demand; corpus harness |
| Compose `extends` | **F2 shipping** | `make f2-compose-extends` |
| Host `devices` unrestricted | **R2 Done** | `make f3-devices-unrestricted`; allowlist via `CONTAINER_DEVICE_ALLOWLIST_ONLY=1` |
| Connect live NIC hotplug | **R1 CR build only** | CR spare net rebind + VZ attachment swap; `make f4-vz-net-hotplug` (+ live `f4-vz-net-hotplug-live.sh`) |
| Immich compose `10` | **R4 Done** | `COMPOSE_ENABLE_IMMICH=1` default; HTTP 200 gate; `scripts/container-cr-compose-e2e.sh` |
| First-party GUI | **R6 in-progress** (no framebuffer host) | `container-gui`; `scripts/parity/r6-container-gui.sh` → `R6_CONTAINER_GUI_OK` |
| CR-as-default | **F6 CR builds only** | Makefile writes `vmm-backend` = `cr` only when `CONTAINER_VMM_CR=1`; otherwise `vz` |

## CR compose corpus

Default CR fixtures: `01/02/03/04/05/07/08/09` + `10-immich` (`COMPOSE_ENABLE_IMMICH=1` default).
`06-nfs` via `COMPOSE_ENABLE_NFS=1` (Pack A green).

## Stop here (SKU)

SKU freeze held historically. Reopen track:
[reopen-supported-surfaces](plans/2026-11-21-reopen-supported-surfaces.prd.md).
OpenAPI + Swarm stay out.
