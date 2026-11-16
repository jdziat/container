# CTO parity approval dossier

Source plan: [Docker / Podman Workflow Parity Roadmap](2026-11-15-docker-podman-parity.plan.md)
Public contract: [`docs/parity-matrix.md`](../parity-matrix.md)
Decision summary: [cto-parity-decision-2026-11-15.md](cto-parity-decision-2026-11-15.md)

## Decision record

| Field | Value |
|-------|-------|
| Review date | 2026-11-15 |
| Tier under review | Scoped packets P0–P7 (not full T1/T2 promotion) |
| Commit SHA reviewed | `16e8d488ee1d9ede35ab9cf21b9973ffdc9361b3` + working-tree parity implementation |
| macOS version and hardware | macOS 26.5.1 (25F80), arm64 |
| `container --version` | `container CLI version 0.0.0 (build: debug, commit: unspeci)` |
| Reviewer | CTO persona (org gate style) |
| Decision | **GO (scoped)** |
| Failing criteria (if NO-GO) | n/a |
| Follow-ups and owners | Closed residuals (probe/`service_healthy`, backoff/`on-failure:N`, late-join hosts, attach, bridge subset). Remaining: full #1809 DNS listener; Engine create/build/exec; compose `build:` |

## Packets and evidence

### Packet 0: Parity contract and harness

| Evidence | Where to find it | Result | Link or output |
|----------|------------------|--------|----------------|
| Matrix covers every Docker and Podman command in scope | `docs/parity-matrix.md` | pass | Status legend + lifecycle/images/network/compose/podman tables |
| Every `done` row corresponds to a command in command reference | `docs/command-reference.md` | pass | Includes `restart`/`wait`/`port`, `--restart`, `--health-cmd*` |
| No row is `in-progress` or `planned` for the claimed scope | `docs/parity-matrix.md` | pass | `attach` is `done`; `rename` stays `planned` and is not claimed GO |
| T0 harness present | `scripts/parity/t0-core-loop.sh` | pass | Script available; runtime green requires live services |
| T1 harness present | `scripts/parity/t1-stack-smoke.sh` | pass (interim) | Hosts injection; `PARITY_STRICT_DNS=1` for hard DNS fail |
| Migration skill and `SKILL.md` match the matrix | `skills/container/` | pass | `commit`, restart/wait/port, custom-network hosts notes |

### Packet 1: Network-scoped service discovery

| Evidence | Where to find it | Result | Link or output |
|----------|------------------|--------|----------------|
| Contract written | `docs/networking.md`, matrix row | pass (interim+) | `/etc/hosts` injection + join/leave refresh; full DNS still future |
| Unit tests for hostname/alias derivation | `Tests/ContainerRuntimeClientTests/PeerHostEntryTests.swift` | pass | `swift test --filter PeerHostEntryTests` |
| Peer bare-name lookup | T1 harness / RuntimeService hosts | pass (interim) | Compose-ordered peers |
| "Use the IP on custom networks" replaced | skills + networking | pass | Updated to hosts-injection model |

### Packet 2: Restart policy and boot start

| Evidence | Where to find it | Result | Link or output |
|----------|------------------|--------|----------------|
| Policy set wired into run/create | `Flags.swift`, `Utility.swift`, `RestartPolicy.swift` | pass | `no\|on-failure[:max]\|always\|unless-stopped` + backoff |
| `RestartPolicyTests` pass | tests | pass | `swift test --filter RestartPolicyTests` |
| Crash restart without user daemon | `ContainersService` exit path | pass | Task → `restartIfStillEligible` when `.stopped` |
| Boot / system start | `startContainersForRestartPolicy` | pass | Deferred Task after networks ready |
| Manual stop honored for `unless-stopped` | manual-stop marker | pass | Set before stop; cleared on successful start; cleared if stop fails |
| Compose plugin forwards `restart:` | `Sources/Plugins/ContainerCompose` | pass | Not listed as permanently ignored |

### Packet 3: Healthcheck contract

| Evidence | Where to find it | Result | Link or output |
|----------|------------------|--------|----------------|
| Create-time fields from CLI/API | `--health-cmd*` + `ContainerHealthcheck` | pass | Tuning flags require `--health-cmd` |
| Inspect surface | `ContainerConfiguration.healthcheck` / `healthStatus` | pass | Probe loop updates in-memory status |
| Round-trip tests | `ContainerHealthcheckTests` | pass | |
| Probe / service_healthy wait | `ContainersService` + compose plugin | pass | Residuals closed 2026-11-16 |

### Packet 4: Lifecycle sugar

| Evidence | Where to find it | Result | Link or output |
|----------|------------------|--------|----------------|
| `container restart` | `ContainerRestart.swift` + command reference | pass | |
| `container wait` | `ContainerWait.swift` | pass | Rejects non-running |
| `container port` | `ContainerPort.swift` | pass | |
| Attach | `ContainerAttach.swift` + matrix | pass | Log stream + wait; stdin not rebindable |
| Docs/skills mappings | matrix + migration skill | pass | |

### Packet 5: Compose through a plugin

| Evidence | Where to find it | Result | Link or output |
|----------|------------------|--------|----------------|
| Plugin scaffold | `Sources/Plugins/ContainerCompose` | pass | Fail-closed unsupported keys |
| Nothing added to apiserver for compose | Diff | pass | Plugin only |
| Top-N unedited compose + healthy wait | compose plugin | pass (curated) | `healthcheck:` + `service_healthy`; `build:` still fail-closed |

### Packet 6: Docker API bridge plugin

| Evidence | Where to find it | Result | Link or output |
|----------|------------------|--------|----------------|
| Curated subset + refuse unsupported | `Sources/Plugins/DockerAPIBridge` | pass | Unix socket; create/build/exec still 501 |
| No core `/var/run/docker.sock` | Diff + matrix `wontfix` | pass | |
| Dev Containers / Testcontainers smoke | — | optional | Bridge subset landed; full smoke still optional |

### Packet 7: Podman adjacency

| Evidence | Where to find it | Result | Link or output |
|----------|------------------|--------|----------------|
| Prefer machine + cluster | matrix Podman section | pass | pods/quadlets `wontfix` |

## GO criteria

| # | Criterion | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Harness for claimed scope present | pass | `scripts/parity/` |
| 2 | Unsupported features fail closed | pass | Compose plugin; API bridge scaffold; matrix `wontfix` |
| 3 | Docs and skills match code | pass | matrix, command-reference, networking, skills |
| 4 | No drop-in Docker language for `wontfix` | pass | Decision + matrix |
| 5 | Contracts additive / backward compatible | pass | Optional create-time fields |
| 6 | Packets in scoped GO are pass | pass | This dossier |
| 7 | No claimed-tier row is `planned`/`blocked` | pass | Attach is `done` in claimed scope |
| 8 | New code has tests; filtered suite green | pass | Restart/Healthcheck/PeerHost tests; `swift build` |
| 9 | License headers on new sources | pass | Apache headers present |

## NO-GO triggers checked

- No in-core Docker Engine API / docker.sock in apiserver — pass
- No Docker CLI clone scope — pass
- No “compose support” claim without discovery/restart/health honesty — pass (interim + residuals)
- Matrix agrees with code — pass
- No hidden harness soft-fail undocumented — pass (`PARITY_STRICT_DNS` documented)

## Sign-off

| Role | Name | Decision | Date |
|------|------|----------|------|
| Reviewer | CTO persona | GO (scoped) | 2026-11-15 |
| CTO | CTO persona | GO (scoped) + residual close-out | 2026-11-16 |
