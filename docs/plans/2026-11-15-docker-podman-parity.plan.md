# Docker / Podman Workflow Parity Roadmap

_Last updated: 2026-11-15_  
_Author posture: CTO gate (packets, contracts-first, fail-closed, evidence-backed GO)_  
_Semanta: workflow Plan phase; decision remembered; handoff `container-docker-podman-parity-2026-11-15`_

## Verdict

Chase **workflow parity** for macOS Apple Silicon developers replacing Docker Desktop or Podman Machine — not a Docker CLI shape clone, and not an in-core Docker Engine API.

Upstream already closed or deferred the wrong definitions of “parity”:

- [apple/container#79](https://github.com/apple/container/issues/79) — Docker CLI parameter compatibility: **no plans to change**
- [apple/container#66](https://github.com/apple/container/issues/66) — Docker Engine API on `/var/run/docker.sock`: **not planned in core** (plugin/bridge path encouraged)

Parity is therefore measured by **jobs developers can finish** with OCI images, multi-service stacks, and ecosystem tools — with honest, fail-closed gaps where the per-VM architecture makes Docker semantics impossible or undesirable.

## Problem

`container` already covers the day-1 loop (run, build, pull/push, exec, logs, volumes, registry). Downstream tools (Compose plugins, Aspire/DCP, Dev Containers, Testcontainers, Wrangler) still bounce off a short list of runtime gaps: network-scoped service discovery, restart policy, healthchecks, and a Docker-compatible management API.

Without a written contract, every session re-litigates “are we trying to be Docker?” and downstream authors guess which gaps are temporary vs permanent.

## Approach

1. Define **tiers** of parity and a public matrix (`done` / `alias` / `plugin` / `wontfix` / `blocked`).
2. Ship **runtime contracts** that unblock multi-service stacks before CLI sugar or plugins.
3. Prefer the existing **plugin architecture** for Compose and any Docker-API bridge; keep `container-apiserver` focused on VM/network/image truth.
4. Promote only with a **harness** that proves the claimed tier; unsupported features fail closed with stable errors.

## Users

- **Primary:** macOS Apple Silicon developers migrating from Docker Desktop / Colima / Podman Machine for local Linux containers.
- **Secondary:** Tool authors (Compose plugins, IDEs, orchestrators) that need stable create-time contracts and inspect surfaces.
- **Non-user for this track:** production datacenter Linux engines; Intel Mac shared-VM workflows.

## Success metrics

| Metric | Signal |
|--------|--------|
| T0 harness | Core single-container scripts green in CI |
| T1 stack | Unedited 3-service compose (image + ports + volumes + `db` hostname) up/down without sudo host DNS |
| Restart | `unless-stopped` / `on-failure` survive crash and reboot without a hand-rolled LaunchAgent |
| Health | `depends_on: condition: service_healthy` honored |
| Ecosystem (optional T2) | One Dev Containers or Testcontainers smoke against a **plugin** Docker-API bridge |
| Honesty | Matrix + docs/skills match code; no “drop-in docker” claims for `wontfix` items |

## Parity tiers

| Tier | Meaning | Status (2026-11-15) |
|------|---------|---------------------|
| **T0 Core loop** | run / build / pull / push / exec / logs / cp / inspect / volumes / registry | Mostly green |
| **T1 Multi-service stacks** | bare service DNS, restart, healthcheck, compose | **Critical gap** |
| **T2 Ecosystem** | Testcontainers / Dev Containers / Wrangler via socket API | External bridges only (e.g. Socktainer) |
| **T3 Ops sugar** | `restart` / `wait` / `attach` / `port` / `events` / `system prune` | Partial / missing |
| **T4 Podman-shaped** | pods, quadlets, generate kube | Prefer `container machine` + `container cluster`; do not clone Podman |

### Current surface (anchor)

Already strong vs Docker for daily use (see `docs/command-reference.md` and `skills/container/references/docker-migration.md`):

- Lifecycle: `run`, `create`, `start`, `stop`, `kill`, `delete`/`rm`, `exec`, `logs`, `inspect`, `stats`, `export`, `commit`
- Images: `build`, `image` pull/push/tag/save/load/prune/inspect
- Volumes, networks (macOS 26+), registry login, system df/logs/status
- Differentiating: per-container lightweight VMs, `container machine`, `container cluster`, `--publish-socket`, `--ssh`, `--rosetta`, `--virtualization`

Known gaps that block T1/T2 (sources: migration skill, [#1809](https://github.com/apple/container/issues/1809), [#2142](https://github.com/apple/container/issues/2142), [#1846](https://github.com/apple/container/issues/1846), Aspire/DCP notes):

- Custom-network / Compose-style **bare-name** DNS discovery
- `--restart` / boot auto-start (implementation idle pending maintainer direction)
- Healthcheck create + inspect + compose conditions
- No first-party `container compose` (community plugins exist)
- No first-party Docker Engine API (plugin path only)
- Lifecycle sugar: `restart`, `wait`, attach-to-running, `port`, `rename`, `pause`, `events`, unified `system prune`
- Skill drift: migration doc still says no `commit` while CLI documents `container commit`

## Non-goals

- Docker CLI plural command names and flag-for-flag compatibility
- In-core Docker Engine API / binding `/var/run/docker.sock` inside `container-apiserver`
- Docker Swarm
- Intel Mac / single shared Linux VM architecture
- In-tree Docker Desktop–class GUI
- Claiming full Podman CLI parity (pods, quadlets, etc.) when `machine` + `cluster` cover the jobs

## Packet plan

Dependency graph:

```text
P0 contract ─┬─► P1 DNS ──► P3 health ──► P5 compose plugin
             ├─► P2 restart ─────────────► P5
             ├─► P4 lifecycle sugar
             └─► P6 API bridge (parallel, optional)
                        P7 Podman adjacency (selective, later)
```

### Packet 0 — Parity contract + harness

**Goal.** One authoritative matrix and a CI harness so “parity” is never a vibes claim.

**Deliverables**

- Public matrix: Docker / Podman command → `container` equivalent → status (`done` / `alias` / `plugin` / `wontfix` / `blocked`) + issue/PR links
- CI “parity suite” (~20 scripts): single-container loop, 3-service stack smoke, reboot/resume where testable
- Sync `skills/container/references/docker-migration.md` and `skills/container/SKILL.md` with current CLI (notably `commit`)

**Exit gate.** Matrix is the only place parity is claimed; skill docs match `docs/command-reference.md`.

### Packet 1 — Network-scoped service discovery ([#1809](https://github.com/apple/container/issues/1809))

**Goal.** Unedited compose connection strings: peer resolves `db` on the project network without sudo host DNS.

**Context.** Domain-qualified names and `alias=` on the configured DNS domain work on `default` after `container system dns create` (see `docs/networking.md`). Custom-network Compose-style bare names remain the ecosystem blocker. Related: [#856](https://github.com/apple/container/issues/856), [#1839](https://github.com/apple/container/issues/1839); draft stacks discussed under #1810/#1813/#1815; hosts-file interim prototypes noted on #1809.

**Deliverables**

- Create-time contract: network-scoped names/aliases, uniqueness rules, late-join refresh vs honest hosts-file limitation
- Runtime + tests: peer `nslookup db` / HTTP to `http://db` on a custom network
- Docs: replace “use IP on custom networks” with the supported discovery model

**Exit gate.** Aspire/DCP-class DNS blockers clear; compose plugins can keep service names in env URLs.

**Priority.** Highest leverage packet.

### Packet 2 — Restart policy + boot start ([#2142](https://github.com/apple/container/issues/2142), [#286](https://github.com/apple/container/issues/286), [#1258](https://github.com/apple/container/pull/1258), [#1201](https://github.com/apple/container/pull/1201))

**Goal.** Containers come back after crash and after reboot without every user reinventing LaunchAgents.

**Blocker.** Maintainer direction call (single PR vs stacked branches; whether `always` implies start-on-`system start` vs separate `--system-start`). Implementation work exists; ambiguity is the idle state.

**Deliverables**

- Create-time API/CLI policy: `no` | `on-failure` | `always` | `unless-stopped` (exact set TBD with maintainers)
- Runtime supervisor for crash restart
- Boot / `container system start` semantics (flag or implied — decided explicitly)
- Document LaunchDaemon patterns only as interim, not as the product answer

**Exit gate.** Policy survives reboot; crash restart without a user daemon; compose plugins stop listing `restart:` as permanently ignored.

### Packet 3 — Healthcheck contract

**Goal.** Ready-or-not is a runtime fact, not a shell loop in every compose wrapper.

**Deliverables**

- Create-time healthcheck fields + `inspect` status surface
- Compose `depends_on: condition: service_healthy` via plugin once inspect is stable
- Fail closed if probe binary missing from the image

**Exit gate.** Three-service stack waits on healthy DB before app start.

**Depends on.** Packet 1 for realistic multi-service proof; can land API surface in parallel with Packet 2.

### Packet 4 — Lifecycle sugar

**Goal.** Common Docker scripts port with ≤1 edit per command.

**In scope**

- `container restart`
- `container wait`
- Attach to already-running containers (today: unsupported on running)
- `container port` (or documented inspect equivalent that tools can parse)
- Optional: `rename`

**Defer / skip until VM-honest story**

- `pause` / `unpause`
- `diff`
- `events` (nice-to-have; not T1)
- Unified `docker system prune` equivalent (four prunes already exist)

**Exit gate.** Documented mappings; integration tests for restart/wait/attach.

### Packet 5 — Compose via plugin (not core)

**Goal.** `container compose up/down/logs` as a first-class **plugin** path, consistent with maintainer preference ([#1846](https://github.com/apple/container/issues/1846), discussion [#194](https://github.com/apple/container/discussions/194)).

**Deliverables**

- Official or blessed plugin packaging against released `ContainerAPIClient`
- Curated Compose subset; unsupported keys listed **before** first run (fail closed / warn by policy)
- Depends on Packets 1–3 so `restart:` and service DNS are real, not forever ignored

**Exit gate.** Top-N public compose files up/down/logs without rewriting connection strings.

**Out of scope for core.** Reimplementing Compose inside `container-apiserver`.

### Packet 6 — Docker API bridge plugin (optional T2)

**Goal.** Ecosystem tools that require Engine API work against a **plugin** compatibility daemon, not core.

**Deliverables**

- Documented supported Engine API subset (create/start/inspect/logs/exec/stop/rm, images, binds, ports, platform)
- Refuse unsupported routes with stable errors
- Smoke: one Dev Containers or Testcontainers path

**Reference.** Community Socktainer / Podman Desktop Apple container extension; [#1925](https://github.com/apple/container/issues/1925).

**Exit gate.** Published support matrix for the bridge; smoke green. No claim of full Engine API.

### Packet 7 — Podman adjacency (selective)

**Goal.** Cover Podman *jobs*, not Podman CLI surface.

**Prefer**

- `container machine` as Lima/Colima/Podman-machine replacement
- `container cluster` for kube-shaped local orchestration (`generate kube`–class needs)

**Only add** pod-like grouping if Packets 1–5 still leave a measured hole.

## Near-term bets (this quarter)

1. **Land or close #1809** — unblocks compose ecosystem more than any CLI alias.
2. **Answer #2142 direction** — merges beat new design docs.
3. **Publish Packet 0 matrix** so downstream tools stop guessing.
4. **Fix migration skill drift** so agents stop teaching wrong gaps (`commit`, etc.).

## Promotion gates (CTO)

**GO** for a claimed tier only when:

1. Packet 0 harness is green for that tier
2. Unsupported features fail closed with stable, documented errors
3. Docs + skills match code
4. No “parity” / “drop-in docker” language for `wontfix` items
5. Cross-packet contracts (DNS, restart, health) are additive and backward compatible within the major version rules in `README.md`

**NO-GO** if the plan expands into in-core Docker API, CLI clone scope, or unmeasured “compose support” that ignores discovery/restart/health.

## Evidence anchors (read before re-litigating)

| Topic | Anchor |
|-------|--------|
| CLI mapping / gaps | `skills/container/references/docker-migration.md`, `docs/command-reference.md` |
| DNS / aliases | `docs/networking.md`, `docs/architecture/dns.md`, #1809 |
| Restart tracker | #2142, #286, PRs #1258 / #1201 |
| Compose | #1846, discussion #194; community plugins |
| Engine API | #66 (not planned core), #1925, Socktainer |
| Architecture limits | `docs/technical-overview.md` (per-VM model, memory ballooning) |
| Cluster / kube | `docs/cluster.md` |

## Open tasks

- [ ] Socialize Packet 0 parity contract matrix (tiers + non-goals) with maintainers
- [ ] Unblock #1809 network-scoped DNS / bare service names
- [ ] Maintainer direction call on #2142 restart policy PR stack
- [ ] Sync skills migration docs with current CLI
- [ ] (Optional) `semanta ingest` this repo if durable graph memory for `container` is desired — project was not in org index at plan time

## Changelog

| Date | Change |
|------|--------|
| 2026-11-15 | Initial CTO roadmap from Semanta-workflow Plan phase |
