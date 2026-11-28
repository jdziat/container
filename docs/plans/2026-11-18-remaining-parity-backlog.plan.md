# Remaining Docker parity backlog (post Compose+NFS)

> **SUPERSEDED (2026-11-19).** Open post-freeze work lives in
> [2026-11-19-post-freeze-parity-productization.prd.md](2026-11-19-post-freeze-parity-productization.prd.md).
> Job-catalog freeze is achieved; do **not** treat this file as a live implementation backlog.
> **N2** (live NIC hotplug) and **E3** (in-core docker.sock) stay permanent non-goals for that track —
> not “next parity.” Historical P0–P3 implement rows are closed by the freeze stamp; residual **K1**
> (NFS kernel packaging) is Pack A in the new PRD.

_Date: 2026-11-18_  
_Semanta: agent `parity-planner`; org recall had no container-project memories (index drift / other repos); backlog sourced from `docs/parity-matrix.md`, `docs/compose-support-matrix.md`, CTO stamps._

## Current posture

| Track | Status |
|-------|--------|
| Scoped lifecycle + images + volumes | Mostly `done` |
| Compose + guest NFS | `done` (kernel NFS-enabled; corpus + `nfs-guest-server.sh`) |
| Network DNS (#1809) | `done` — hosts injection + in-guest hosts-dns (nslookup) |
| Network hotplug | `done (interim)` — connect needs restart (N2 residual) |
| Engine API bridge | `done` — curated support matrix; outside routes 501 by contract |
| Docker CLI drop-in (#79) | `done` — `bin/docker` shim + top-level aliases |
| Compose pull/images/caps/hostname/grace/completed | `done` (devices `wontfix`) |
| Swarm / Podman pods / Quadlet | `wontfix` |

Allowed language (see `cto-full-parity-dns-engine-cli-2026-11-18.md`): drop-in Docker CLI, curated full Engine bridge, complete guest DNS. Still forbidden: claiming Swarm or routes outside the bridge support matrix.

**Job-catalog freeze (2026-11-19):** Nearest honest “full Docker parity (ex-Swarm)” is defined by
[docs/docker-job-catalog.md](../docker-job-catalog.md) and
[2026-11-19-job-catalog-docker-parity.prd.md](2026-11-19-job-catalog-docker-parity.prd.md).
For that freeze: **N2** (live NIC hotplug / spare-NIC), **E3** (in-core docker.sock), unqualified
full Engine OpenAPI, Swarm, and host `devices` remain **non-goals**. Optional bridge route
expansions are separate scoped work after the printed support matrix freeze — not implied debt
from this backlog. DNS (#1809) is matrix `done` (hosts + hosts-dns); do not treat N1 as open
catalog debt.

---

## P0 — Validate (honesty / CI)

| ID | Work | Why | Gate |
|----|------|-----|------|
| V1 | `make compose-parity` green on clean tree with NFS kernel + auto `nfs-guest-server.sh` | Corpus must not depend on manual env | Harness exit 0 including `06-nfs` |
| V2 | Re-run T0/T1 (+ optional `PARITY_STRICT_DNS=1`) after NFS kernel swap | Kernel change can regress networking | Scripts green |
| V3 | Document/ship NFS-enabled kernel path (default install vs Kata debug) | Stock Kata debug lacks `nfs` in `/proc/filesystems` | Docs + install story |
| V4 | Nitpick + unit/integration smoke on compose/NFS/runtime rewrite | Catch `addr=`→`server:/export` regressions | Nitpick fail-on warning; Parser NFS tests |

---

## P1 — Implement (Compose language leftovers)

| ID | Work | Matrix | Notes |
|----|------|--------|-------|
| C1 | `compose pull` / `compose images` thin wrappers | `planned` → `done` | Cheap; maps to `container image pull` / `images` |
| C2 | `devices` / `cap_add` / `cap_drop` (and related fail-closed keys as needed) | `planned` → `done` or stay fail-closed with explicit wontfix | Engine already has `--cap-add`; wire compose |
| C3 | Real `--hostname` / UTS hostname (and `domainname` if cheap) | `done` | Hostname via `--hostname`; domainname via `--domainname` → resolv.conf domain/search + FQDN hosts |
| C4 | `stop_grace_period` → stop timeout if not fully wired | Check; stamp honestly | |
| C5 | `depends_on: service_completed_successfully` corpus coverage | Code exists; harness light | Add fixture if missing |

---

## P2 — Implement (close interim networking)

| ID | Work | Matrix | Blocker |
|----|------|--------|---------|
| N1 | Network-scoped DNS (#1809) | `done` (hosts + hosts-dns) | Closed for job-catalog freeze; further DNS work is separate |
| N2 | Live `network connect` / `disconnect` hotplug | stays `done (interim)` | Deferred: needs VZ/Containerization NIC hot-add; not catalog debt |

---

## P3 — Implement (Engine bridge + CLI)

| ID | Work | Matrix | Notes |
|----|------|--------|-------|
| E1 | Bridge: build / networks / volumes routes (curated) | `done` in printed support matrix | Freeze; further routes are opt-in scoped expansions |
| E2 | More Docker CLI flag aliases (#79), esp. `--hostname` | CLI row `done` | Extra aliases optional polish only |
| E3 | In-core `/var/run/docker.sock` | out of scope unless reopened | Keep plugin sock default; see job-catalog Recipe B |

---

## P4 — Productize NFS (optional but recommended)

| ID | Work | Notes |
|----|------|-------|
| K1 | Official NFS-capable kernel artifact in release/install | `scripts/install-nfs-kernel.sh` builds Containerization `kernel/` and runs `container system kernel set`; docs in `volumes.md`. Release tarball still operator-built (not bundled in `--recommended`). |
| K2 | Fail-closed error when guest has no `nfs` fs | `RuntimeService.annotateNFSKernelError` → actionable message pointing at install script + volumes.md |
| K3 | Keep `nfs-guest-server.sh` in CI/parity docs | No host `nfsd`/sudo required |

---

## Suggested sequence

```text
SUPERSEDED — see 2026-11-19-post-freeze-parity-productization.prd.md
(T1 terminus → Pack A NFS / Pack B UX / optional Pack C expansions).
Do not sequence N2 hotplug as next parity work in this track.
```

Historical (pre-freeze) sequence, kept for archaeology only:

```text
V1–V4 (validate) 
  → C1, C3/E2 (quick UX wins)
  → C2, C5
  → N1 (DNS) then N2 (hotplug) if upstream allows
  → E1 (bridge expansion) in parallel once API surface agreed
  → K1–K3 whenever packaging allows
```

## Explicit non-goals (unchanged)

- Docker Swarm multi-node `deploy`
- Podman pods / Quadlet / Podman-only flags
- Arbitrary volume plugins beyond local + NFS
- Claiming full Engine or drop-in Docker while interim rows remain

## CTO gate rule

Promote a row to `done` only with harness or test evidence in the same change. Interim rows need a named residual in the Notes column.
