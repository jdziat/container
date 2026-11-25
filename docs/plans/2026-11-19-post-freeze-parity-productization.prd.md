# PRD: Post-freeze parity productization

_Date: 2026-11-19_  
_Semanta: agent `parity-designer`; org recall wrong-scope for this repo — design grounded in local CTO stamps + four-lens brainstorm._

## Problem

Job-catalog Docker parity (ex-Swarm) is **achieved**. A living “remaining parity” backlog still invites forever-chase: N2 hotplug, CR VMM shine, bridge OpenAPI growth, and Desktop density ask for work that is either architecture-bound or a **new product bet**. Meanwhile the only real open packaging residual (NFS-capable kernel not in `--recommended`) and migrant UX surprises (global aliases, single-writer volumes, interim `--restart`) are underspecified as shippable packs.

## Users

- Maintainers writing release notes and support answers after the freeze
- Developers migrating Compose stacks (WordPress / Nextcloud / Immich / Traefik-shaped) who hit loud edges
- Optional later: teams wanting a **named** expansion claim (extra bridge routes or Testcontainers/Dev Containers smokes)

## Current state (observed)

- Freeze **GO**: [cto-job-catalog-parity-achieved-2026-11-19.md](cto-job-catalog-parity-achieved-2026-11-19.md); catalog [docs/docker-job-catalog.md](../docker-job-catalog.md); completed PRD [2026-11-19-job-catalog-docker-parity.prd.md](2026-11-19-job-catalog-docker-parity.prd.md).
- Guest NFS **runtime** is `done` (corpus `06-nfs`, fail-closed annotate). **K1 packaging** still operator-built via `scripts/install-nfs-kernel.sh` — not bundled in `--recommended` ([2026-11-18-remaining-parity-backlog.plan.md](2026-11-18-remaining-parity-backlog.plan.md) P4; [cto-remaining-parity-go-2026-11-18.md](cto-remaining-parity-go-2026-11-18.md) residual #4).
- Loud edges: global exact alias uniqueness; RW named-volume single-writer; Compose `devices` `wontfix`; bridge outside-matrix HTTP 501; `network connect`/`disconnect` `done (interim)` with `--restart`.
- Socket Recipes A/B/C documented; Testcontainers / Dev Containers **document-only** until a separate scoped claim (CTO forbids zero-config claim).
- CR VMM: opt-in / build-gated; default `vz`; Alpine-on-CR vsock accept timeout ([2026-11-19-crvirtualization-integration.pointer.md](2026-11-19-crvirtualization-integration.pointer.md)) — **not** a Docker-parity menu item.
- Prior backlog [2026-11-18-remaining-parity-backlog.plan.md](2026-11-18-remaining-parity-backlog.plan.md) is **superseded** by this PRD for open work; implementable catalog rows are closed.

## Proposal

Treat post-freeze work as **productization packs** under a closed SKU — not a new parity scoreboard.

1. **SKU:** “Job-catalog full Docker parity (ex-Swarm)” stays the finished claim.
2. **Pack A — NFS kernel first-class:** ship / install an NFS-capable guest kernel as a supported path (default or clearly first-class), not a side quest.
3. **Pack B — Migrant UX dialect:** one “VM lifecycle” language + Compose preflight that surfaces alias / volume / devices / NFS / sock landmines before create.
4. **Pack C — Gated expansions (optional):** named packs for bridge-route growth and/or Testcontainers–Dev Containers harnesses — each with harness gate + CTO language before any claim.
5. **Terminus:** end “remaining parity” as a live genre; promote `network connect --restart` to the permanent per-VM contract for this track; keep E3 / Swarm / devices / full OpenAPI / CR-as-parity as non-goals.

## In scope

- Terminate / supersede the 2026-11-18 remaining-parity backlog as an open implementation list
- NFS kernel release/install productization (K1) with CI retention of K2/K3
- Compose preflight / doctor (or dry-run) for known loud edges
- Unified copy for interim/refuse edges (connect `--restart`, 501, devices, volume, alias, NFS kernel)
- Optional expansion-pack **definitions** (bridge routes; TC/DC client smokes) with acceptance gates
- Docs/release-note language updates for the closed SKU + packs

## Out of scope

- Reopening the job catalog as unfinished debt
- Live NIC hotplug (N2) / spare-NIC work
- In-core apiserver `/var/run/docker.sock` (E3)
- Host `devices`, Swarm, `deploy` / `extends`
- Unqualified “full Engine API” / filling OpenAPI
- Making CR the default VMM or claiming CR as Docker parity
- Desktop shared-VM density / balloon reclaim as a done claim
- Moby-in-VM second lane

## Functional requirements

1. **SKU freeze held.** Release and support materials cite the job-catalog stamp; residuals are loud edges or named packs, never “parity incomplete.”
2. **NFS Pack A.** An operator (or release) path installs an NFS-capable kernel without requiring undocumented `make` archaeology; stock `--recommended` either includes NFS or documents the first-class alternate with one command; missing-`nfs` guest still fail-closes via `annotateNFSKernelError`.
3. **UX Pack B.** A Compose-facing preflight lists at least: global alias clash risk, RW multi-attach named volume, `devices`, unsupported Traefik-shaped sock/`security_opt` keys already fail-closed, NFS kernel readiness when mounts need it. Messaging shares one “VM / guest restart or host kernel step” dialect with connect `--restart` and bridge 501 adjacency.
4. **Expansion Pack C (optional, gated).** Any new Engine bridge route or TC/DC implement claim ships only as a named pack with: printed matrix/docs update, harness evidence, and CTO-allowed claim sentence. Outside-matrix 501 remains success until that pack lands.
5. **Terminus.** This PRD closes the remaining-parity backlog genre; N2 and E3 are permanent non-goals for post-freeze productization (reopen only via a **new** PRD).

## Non-functional requirements

- Claims language must not violate [cto-job-catalog-parity-achieved-2026-11-19.md](cto-job-catalog-parity-achieved-2026-11-19.md).
- Prefer fail-closed and actionable refuse over silent Desktop-shaped partial success.
- Per-container VM model remains the architecture bound (aliases global; named volumes single-writer; NICs create-time).
- Kernel packaging must keep signing / size / version skew with Containerization `kernel/` honest in docs.

## Acceptance criteria

- Remaining-parity backlog plan carries a **superseded** banner pointing here; suggested sequence no longer soft-schedules N2 as next parity work.
- Pack A: documented one-command (or release-bundled) NFS kernel path; `make compose-parity` / `06-nfs` still green when that kernel is active; missing-kernel path still annotated.
- Pack B: preflight surfaces the production-corpus landmines in [scripts/parity/compose-production/README.md](../../scripts/parity/compose-production/README.md) before create; connect/NFS/volume/alias/devices copy reviewed for one dialect.
- Pack C: if deferred, Open Questions record “not shipping”; if shipping, each pack has harness + claim sentence before docs say “supported.”
- No new claim of zero-config Testcontainers/Dev Containers, full Engine API, hotplug, or CR-default.

## Success measures

- Support can answer “are we Docker-parity?” with the SKU name + one residuals page
- NFS Compose users stop failing solely because `--recommended` lacked `nfs`
- Migrants hit landmines in preflight more often than at mid-`up` surprise
- No new unbounded Engine-route backlog without a pack name

## Risks

| Risk | Mitigation |
|------|------------|
| “Full Docker parity” heard without SKU qualifier | Keep forbidden language list in release notes; link stamp |
| NFS second kernel size/signing/version skew | Explicit alternate artifact + CI after kernel bumps |
| Preflight feels “not Docker” | Opt-in doctor / warn-then-fail; mirror existing fail-closed keys |
| Pack C silently reopens forever-OpenAPI | Hard gate: harness + CTO sentence or no merge |
| Interim connect treated as defect | Document restart-as-API as permanent contract in this track |

## Brainstorm synthesis (Semanta workflow)

Four fresh lenses + inventory (local evidence only; org Semanta recall wrong-scope).

| Rank | Direction | Why |
|------|-----------|-----|
| 1 | **Post-freeze productization packs** (this PRD) | Feasibility (NFS K1, optional bridge/TC), UX (preflight + dialect), product (SKU + gated packs), contrarian (terminus + restart-as-API) all converge |
| 2 | Bridge-only expansion | Feasible but reopens OpenAPI pressure without migrant UX / NFS packaging |
| 3 | CR VMM as next parity | Rejected: vsock incomplete; not Docker-parity |

Agreement: catalog closed; N2/E3/OpenAPI/devices/Swarm stay out; K1 + honesty UX are the real leftovers.  
Disagreement: whether bridge expansion or TC/DC should be Pack C first (left as Open Question Q2).

## Implementation roadmap

### T1: Terminate remaining-parity backlog
**Status:** Done  
**Depends on:** None  
**In scope:**
- Banner on [2026-11-18-remaining-parity-backlog.plan.md](2026-11-18-remaining-parity-backlog.plan.md): superseded by this PRD; N2 not sequenced as next parity
- Cross-link from [docs/docker-job-catalog.md](../docker-job-catalog.md) “after freeze” residuals → this PRD
**Out of scope:**
- Changing matrix row statuses for catalog jobs
**Surfaces touched:** `docs/plans/2026-11-18-remaining-parity-backlog.plan.md`, `docs/docker-job-catalog.md`  
**Interfaces:** Docs-only; freeze claim language unchanged  
**Verification:** Grep shows superseded banner; no soft “N2 next” sequence in that plan  
**Next command:** `/eg-new-feature` implement T2 from `docs/plans/2026-11-19-post-freeze-parity-productization.prd.md`

### T2: NFS kernel Pack A
**Status:** Done  
**Depends on:** T1  
**In scope:**
- First-class install/release path for NFS-capable guest kernel (bundle or clearly primary alternate to `--recommended`)
- Keep `install-nfs-kernel.sh` + `annotateNFSKernelError` + `06-nfs` green
- Update `docs/volumes.md` / install docs for the chosen shipping shape
**Out of scope:**
- Host NFS mount; changing guest NFS rewrite semantics; CR VMM
**Surfaces touched:** `scripts/install-nfs-kernel.sh`, release/Makefile install hooks, `docs/volumes.md`, optionally packaging under `resources/`  
**Interfaces:** `container system kernel set --binary …`; guest `/proc/filesystems` contains `nfs` after install  
**Verification:** Documented one-command path; `make compose-parity` with `06-nfs`; intentional missing-kernel still annotated  
**Next command:** `/eg-new-feature` implement T2 from `docs/plans/2026-11-19-post-freeze-parity-productization.prd.md`

### T3: Compose preflight + UX dialect Pack B
**Status:** Done  
**Depends on:** T1  
**In scope:**
- Compose doctor / dry-run / config extension listing loud edges before create
- Align refuse copy for alias clash, exclusive named volume, devices, NFS kernel, connect `--restart`
- Doc note for isolation-by-convention (sequential stacks / tear down) from production corpus README
**Out of scope:**
- Inventing multi-writer named volumes or live NIC hotplug; changing global alias policy
**Surfaces touched:** `Sources/Plugins/ContainerCompose/`, loud-edge strings in API/runtime, `skills/container/references/docker-migration.md`, compose-production README  
**Interfaces:** CLI or compose subcommand behavior TBD in implementation; must fail-closed or warn with explicit codes matching matrix honesty  
**Verification:** Fixture or unit covering alias + multi-writer + devices preflight; migration skill dialect pass  
**Next command:** `/eg-new-feature` implement T3 from `docs/plans/2026-11-19-post-freeze-parity-productization.prd.md`

### T4: Expansion Pack C gate (docs + harness skeleton)
**Status:** Done  
**Depends on:** T1  
**In scope:**
- Written pack template: name, routes/clients covered, harness, allowed claim sentence, still-501 remainder
- Decide Q2 (bridge-first vs TC/DC-first) or leave “packs defined, none shipped”
- If shipping one pack: matrix/README + harness evidence in the same change
**Out of scope:**
- Unbounded OpenAPI fill; in-core docker.sock; zero-config Desktop discovery claim
**Surfaces touched:** `Sources/Plugins/DockerAPIBridge/`, `docs/docker-job-catalog.md`, optional `scripts/parity/t2-*`  
**Interfaces:** Printed `docker-api-bridge support` remains the contract until a pack lands; 501 outside it  
**Verification:** Pack template merged; any shipped pack has green harness + CTO-allowed claim; no forbidden language  
**Next command:** `/eg-new-feature` implement T4 from `docs/plans/2026-11-19-post-freeze-parity-productization.prd.md`

### T5: CTO language pass for packs
**Status:** Done  
**Depends on:** T2, T3, T4  
**In scope:**
- Short stamp or release-note section: SKU + Pack A/B status + Pack C shipped-or-not
- Forbidden language unchanged; add “restart-as-API” as intentional for connect
**Out of scope:**
- Reopening catalog jobs J1–J4
**Surfaces touched:** `docs/plans/` CTO stamp or release notes; catalog residuals section  
**Interfaces:** Claims text only  
**Verification:** Stamp review against achievement forbidden list  
**Next command:** `/eg-new-feature` implement T5 from `docs/plans/2026-11-19-post-freeze-parity-productization.prd.md`

## Open questions

1. **NFS shipping shape:** **Resolved** — keep stock Kata `--recommended`; ship NFS as first-class **alternate** (`make install-nfs-kernel` / `install-container-nfs-kernel`).
2. **Pack C priority:** **Resolved** — define both packs; **ship neither** until demand; bridge corpus preferred if one ships later ([expansion-pack-template.md](expansion-pack-template.md)).
3. **Preflight default:** **Resolved** — separate `compose doctor` only (optional `--strict`); do not change `compose up` default.

## Sources

- [docs/docker-job-catalog.md](../docker-job-catalog.md)
- [2026-11-19-job-catalog-docker-parity.prd.md](2026-11-19-job-catalog-docker-parity.prd.md)
- [cto-job-catalog-parity-achieved-2026-11-19.md](cto-job-catalog-parity-achieved-2026-11-19.md)
- [2026-11-18-remaining-parity-backlog.plan.md](2026-11-18-remaining-parity-backlog.plan.md)
- [cto-remaining-parity-go-2026-11-18.md](cto-remaining-parity-go-2026-11-18.md)
- [docs/parity-matrix.md](../parity-matrix.md)
- [docs/compose-support-matrix.md](../compose-support-matrix.md)
- [docs/volumes.md](../volumes.md)
- [scripts/parity/compose-production/README.md](../../scripts/parity/compose-production/README.md)
- [2026-11-19-crvirtualization-integration.pointer.md](2026-11-19-crvirtualization-integration.pointer.md)
- Semanta brainstorm lenses: feasibility, UX, product honesty, contrarian (2026-11-19)

## Handoff

Implement via `/eg-new-feature` starting at **T1** (or T2/T3 in parallel after T1). Do not auto-start implementation from this PRD alone.
