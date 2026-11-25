# PRD: Job-catalog Docker parity (ex-Swarm)

## Problem

Mac users and scripts expect Docker Desktop’s single-node day — CLI, Compose, and Engine-API clients — to finish without a second toolchain. `container` already covers most of that surface on a per-container VM model, but “full parity” is easy to oversell: live NIC hotplug, host `devices`, full Engine OpenAPI, and shared-VM density are not Docker clones. Without a freeze definition, work expands forever and dual toolchains remain the rational default whenever a shim surprises someone.

## Users

- Developers running day-to-day `docker` / Compose workflows on Apple silicon
- Teams using Testcontainers, Dev Containers, or IDE Docker integrations via a socket
- Maintainers deciding what “drop-in” / “full” language is allowed to claim

## Current state (observed)

- Workflow parity scoreboard: [docs/parity-matrix.md](../parity-matrix.md). Lifecycle, images, volumes, networks (create/ls/…), Compose plugin, curated Engine bridge, and `bin/docker` shim are largely `done`.
- Allowed claims (CTO): complete guest DNS; drop-in Docker CLI; curated full Engine bridge per printed support matrix. 501 outside that matrix is product surface. Live NIC hotplug stays `done (interim)`. Swarm / pods / Quadlet `wontfix`. See [cto-full-parity-dns-engine-cli-2026-11-18.md](cto-full-parity-dns-engine-cli-2026-11-18.md).
- Loud edges already exist: Compose fail-closed unknown keys; `devices` / Swarm `deploy` / `extends` `wontfix`; bridge HTTP 501 JSON; `network connect` on running containers requires `--restart`.
- Sock story: plugin `docker-api-bridge`; default Application Support socket; optional privileged `--socket /var/run/docker.sock`; in-core apiserver bind out of scope.
- Architecture bound: per-container Virtualization VM; NICs fixed at create; VZ does not expose live NIC hot-add ([technical-overview.md](../technical-overview.md), `ContainersService.networkConnect`).
- Doc drift (observed): bridge README still says build out of scope while code/`support` lists `POST /build`; `skills/container/SKILL.md` still calls CLI/bridge interim in places; migration doc still labels DNS interim while matrix marks bare-name DNS `done`.
- Related plans (overlap, not replaced): [2026-11-18-remaining-parity-backlog.plan.md](2026-11-18-remaining-parity-backlog.plan.md), [2026-11-15-docker-podman-parity.plan.md](2026-11-15-docker-podman-parity.plan.md). This PRD **narrows strategy** to job-catalog + loud edges + socket recipes; it does not reopen Swarm, devices, full Engine, Moby-in-VM, or in-core docker.sock.

## Proposal

Define “nearest full Docker parity (excluding Swarm)” as a **finished job catalog** for Mac single-node workflows, with **loud edges** at structural limits and **socket/context recipes** for ecosystem clients — not bit-identical Engine or Docker Desktop density.

Success is: published jobs complete under harness; unsupported paths refuse early with the same story as the matrix; users can retarget Docker-shaped tools via documented `DOCKER_HOST` / context / optional privileged sock without claiming zero-config Desktop replacement.

## In scope

- Product definition of the Mac job catalog and freeze criteria
- Honesty alignment of docs/skills/README with matrix + CTO stamps
- Socket migration recipes (Application Support, privileged `/var/run/docker.sock`, docker context) plus Testcontainers / Dev Containers extras **as documentation** unless Open Questions promote them to implement claims
- Loud-edge consistency (compose fail-closed, bridge 501, connect `--restart`, devices wontfix messaging)
- Harness gates already named by the matrix (T0–T3-compose, T2 bridge/shim)

## Out of scope

- Docker Swarm / multi-node `deploy`
- Host `devices` passthrough
- Live NIC hotplug (VZ/Containerization NIC hot-add) and spare-NIC implementation
- Full Engine OpenAPI / unqualified “full Engine API”
- In-core apiserver bind of `/var/run/docker.sock`
- Moby/dockerd second lane in a shared Linux VM
- Podman pods, Quadlet, Podman-only flags
- Guaranteeing shared-VM memory/density parity (document ballooning limits only)

## Functional requirements

1. **Job catalog.** Publish a single, maintained catalog of Mac jobs that define “full” for this PRD: (a) core CLI loop, (b) multi-service Compose stack with bare-name DNS on custom networks, (c) `bin/docker` shim day loop, (d) curated Engine bridge jobs listed by `docker-api-bridge support`.
2. **Loud edges.** Structural non-goals remain fail-closed or 501 with actionable copy pointing at matrix status (`wontfix`, `done (interim)`, outside support matrix).
3. **Socket recipes.** Document three first-class paths: `DOCKER_HOST` → Application Support sock; optional privileged `/var/run/docker.sock`; `docker context create/use` with absolute `unix://` URL. Document coexistence (default non-`/var/run` sock is intentional).
4. **Client extras (docs).** Document Testcontainers `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` / optional `HOST_OVERRIDE` / Ryuk caveats, and Dev Containers `DOCKER_HOST` / context / docker-outside-of-docker mount expectations — without claiming zero-config unless Open Question Q1 chooses implement.
5. **Honesty sweep.** Remove contradictory “interim / build out of scope” language where matrix/CTO already allow `done` / curated `/build`.
6. **Freeze rule.** After catalog + harness green + honesty sweep, further Engine routes are **opt-in expansions** with harness evidence — not implied debt. 501 outside the printed matrix remains success.

## Non-functional requirements

- Claims language must match [cto-full-parity-dns-engine-cli-2026-11-18.md](cto-full-parity-dns-engine-cli-2026-11-18.md).
- Prefer Colima-style coexistence (context/`DOCKER_HOST`) over requiring an auto-symlink to `/var/run/docker.sock`.
- No change to per-container VM isolation model.
- Dense / memory-heavy stacks: document Virtualization ballooning limits; do not treat restart-to-reclaim as a parity bug.

## Acceptance criteria

- [x] Job catalog page exists and links each job to matrix row + harness script.
- [x] `make compose-parity` and T0/T1/T2 harnesses green on the claimed jobs (2026-11-19: T0, `PARITY_STRICT_DNS=1` T1, T2 shim, T2 bridge, `make compose-parity` including `06-nfs` all exit 0 after hosts-dns exit fix + harness CONTAINER_CLI/NFS readiness).
- [x] Bridge README, migration skill, and `skills/container/SKILL.md` agree with `docs/parity-matrix.md` on CLI/bridge/DNS/`/build` status.
- [x] `docker-api-bridge support` remains the complete Engine contract; outside routes return HTTP 501 with stable JSON (`BridgeServer.writeUnsupported`).
- [x] Migration docs include the three sock recipes + absolute `unix://` + IDE/env inheritance note.
- [x] Running `network connect` without `--restart` still fails with an actionable interim message; with `--restart` applies on next start path as today.
- [x] Compose `devices` continues to fail closed with wontfix rationale.

## Success measures

- Maintainers can point to one catalog + freeze rule when asked “are we at full Docker parity (no Swarm)?”
- Dual-toolchain necessity is limited to documented loud edges (Swarm, devices, live hotplug, outside-matrix Engine routes, density), not surprise half-compat.
- Optional: reduction in “is this broken or unsupported?” reports after loud-edge copy lands (qualitative).

## Risks

- Buyers hear “full” / “drop-in” and still expect Desktop zero-config `/var/run` + full Engine.
- Growing the bridge from client failures without a freeze reopens forever roadmap.
- Doc-only Testcontainers/Dev Containers recipes may leave teams on dual toolchains if Ryuk / GUI discovery fails.
- Spare-NIC / VZ hotplug pressure may reopen N2 despite this PRD’s explicit deferral.

## Implementation roadmap

### T1: Honesty sweep (docs/skills vs matrix)
**Status:** Done
**Depends on:** None
**In scope:**
- Align `Sources/Plugins/DockerAPIBridge/README.md`, `skills/container/SKILL.md`, and `skills/container/references/docker-migration.md` with matrix/CTO on CLI, bridge, DNS, and curated `/build`
- Call out remaining true residuals (`network connect` interim; `domainname` if still interim; devices/Swarm wontfix)
**Out of scope:**
- New Engine routes; runtime behavior changes
**Surfaces touched:** `Sources/Plugins/DockerAPIBridge/README.md`, `skills/container/SKILL.md`, `skills/container/references/docker-migration.md`, optionally `docs/parity-matrix.md` cross-links only
**Interfaces:** Published status vocabulary remains `done` / `done (interim)` / `wontfix` / 501-outside-matrix
**Verification:** Grep/manual review: no “bridge interim” or “build out of scope” contradictions vs `BridgeServer.supportMatrix` and matrix rows; migration DNS wording matches matrix bare-name `done`
**Next command:** `/eg-new-feature` implement T1 from `docs/plans/2026-11-19-job-catalog-docker-parity.prd.md`

### T2: Publish the Mac job catalog + freeze rule
**Status:** Done
**Depends on:** T1
**In scope:**
- Add a short product doc (or matrix section) listing the four job families and freeze rule from Functional requirements 1 and 6
- Link each job to harness scripts under `scripts/parity/`
- Cross-link from parity matrix “Keeping this page honest”
**Out of scope:**
- New features; changing CTO-allowed marketing language beyond existing stamps
**Surfaces touched:** `docs/` (new or extended page), `docs/parity-matrix.md`
**Interfaces:** Catalog entries name: job id, user outcome, matrix row(s), harness command, loud-edge note if any
**Verification:** Catalog page renders complete set (CLI, Compose+DNS, shim, bridge); freeze rule states 501-outside-matrix is success; linked harness paths exist
**Next command:** `/eg-new-feature` implement T2 from `docs/plans/2026-11-19-job-catalog-docker-parity.prd.md`

### T3: Socket and client migration recipes
**Status:** Done
**Depends on:** T2
**In scope:**
- Document three sock recipes + docker context ladder + absolute `unix://` + IDE/env inheritance
- Document Testcontainers and Dev Containers extras as recipes (not zero-config claims unless Q1 decides otherwise)
- Point bridge README and migration skill at the same recipe block
**Out of scope:**
- Auto-symlink installer; in-core docker.sock; Podman-mac-helper equivalent; implementing Ryuk-in-guest success
**Surfaces touched:** `Sources/Plugins/DockerAPIBridge/README.md`, `skills/container/references/docker-migration.md`, job catalog doc from T2
**Interfaces:** Recipe A Application Support + `DOCKER_HOST`; Recipe B privileged `--socket /var/run/docker.sock`; Recipe C `docker context create/use`; extras env vars named in research
**Verification:** A reader can follow Recipe A/B/C without reading source; coexistence warning present; no claim of auto `/var/run` ownership
**Next command:** `/eg-new-feature` implement T3 from `docs/plans/2026-11-19-job-catalog-docker-parity.prd.md`

### T4: Loud-edge message consistency
**Status:** Done
**Depends on:** T1
**In scope:**
- Ensure user-visible refuse paths for `network connect` (no `--restart`), Compose `devices`, and bridge outside-matrix 501 share the same story as the catalog (unsupported vs interim vs curated subset)
- Fix any copy that implies unfinished work for intentional 501/wontfix
**Out of scope:**
- Implementing live hotplug or devices; changing HTTP status codes
**Surfaces touched:** `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift` (message text only if needed), `Sources/Plugins/ContainerCompose/main.swift`, `Sources/Plugins/DockerAPIBridge/BridgeServer.swift`, related docs
**Interfaces:** Existing error channels; 501 JSON `message` remains stable and points at `docker-api-bridge support`
**Verification:** Manual or unit/integration asserts on key error strings; T2 harnesses still green
**Next command:** `/eg-new-feature` implement T4 from `docs/plans/2026-11-19-job-catalog-docker-parity.prd.md`

### T5: Declaration checklist (parity “full” for this PRD)
**Status:** Done
**Depends on:** T2, T3, T4
**In scope:**
- Short checklist maintainers run before saying job-catalog parity is complete (harness commands, honesty grep, recipe link check)
- Update remaining-parity backlog pointer: N2/E3/full Engine remain non-goals for this freeze; optional bridge expansions are separate
**Out of scope:**
- Expanding support matrix; spare-NIC design
**Surfaces touched:** job catalog doc, `docs/plans/2026-11-18-remaining-parity-backlog.plan.md` (pointer only)
**Interfaces:** Checklist items are boolean and command-backed
**Verification:** Checklist references only existing harnesses/docs; backlog pointer does not reopen out-of-scope items
**Next command:** `/eg-new-feature` implement T5 from `docs/plans/2026-11-19-job-catalog-docker-parity.prd.md`

## Open questions

1. **Client claim level:** Document-only recipes for Testcontainers/Dev Containers, or implement toward “default path works” (closer to OrbStack/Podman `/var/run` helper + Ryuk)? Suggested default: **document-only** (matches coexistence + this PRD).
2. **Bridge growth:** Freeze printed support matrix after honesty sweep, or allow corpus-driven expansions as separate tasks after T5? Suggested default: **freeze now; expansions are new scoped work**.
3. **Catalog location:** New `docs/docker-job-catalog.md` vs a section inside `docs/parity-matrix.md`? Suggested default: **new page + matrix link** (keeps matrix as status table).
4. **N2 spare-NIC:** Ever schedule a research spike, or leave permanently deferred until Apple ships VZ hot-add? Suggested default: **permanently deferred in this PRD**.

## Sources

- Local: [docs/parity-matrix.md](../parity-matrix.md), [docs/compose-support-matrix.md](../compose-support-matrix.md), [docs/technical-overview.md](../technical-overview.md), [docs/plans/cto-full-parity-dns-engine-cli-2026-11-18.md](cto-full-parity-dns-engine-cli-2026-11-18.md), [docs/plans/2026-11-18-remaining-parity-backlog.plan.md](2026-11-18-remaining-parity-backlog.plan.md), `Sources/Plugins/DockerAPIBridge/README.md`, `Sources/Plugins/DockerAPIBridge/BridgeServer.swift`, `skills/container/references/docker-migration.md`
- Research: Testcontainers alternate environments; Colima FAQ (`DOCKER_HOST` / context / symlink warning); OrbStack Docker install (context + optional `/var/run` symlink); Podman Desktop Docker compatibility / `DOCKER_HOST`; VS Code Dev Containers remote Docker / docker-outside-of-docker sock mount defaults

## Assumptions

- User-selected direction from brainstorm: job catalog + loud edges + socket recipes (not Socket Moat forever-chase, not Moby second lane).
- “Full parity with Docker excluding Swarm” means nearest honest Mac single-node workflow completion under the MicroVM model.
- Open Questions default to suggested answers unless the user overrides before implementation.
