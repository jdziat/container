# Docker / Podman parity remediation plan

_Date: 2026-11-24_
_Status: proposed_
_Basis: audit of the working tree and the built `container` binary — **not** the docs._
_Supersedes nothing; corrects the status claims in [parity-terminus-support.md](../parity-terminus-support.md)._

## Why this plan exists

The repo currently claims **"job-catalog full Docker parity (ex-Swarm): achieved"**
([docker-job-catalog.md](../docker-job-catalog.md), 2026-11-19) and
**"Beyond-terminus: shipped"**
([2026-11-21-reopen-supported-surfaces.prd.md](2026-11-21-reopen-supported-surfaces.prd.md)).
Both stamps rest on harnesses that mostly `grep` source text, and neither has been re-checked
against the tree since the 2026-11-21 wave.

This audit re-verified every headline claim against the code and the built binary. The result is
not "parity is a little overstated". It is that **the uncommitted parity wave does not compile
without an undocumented env var** (`HEAD` builds clean; the 77-file working tree does not), the
headline `docker` drop-in breaks on the first `--format` template a real script uses, and at
least three docs contradict each other and the code about the same feature.

That distinction matters for sequencing. The breakage is in the wave that carries the
beyond-terminus claims (R1/R2/R3/R6, the GUI, the swarm stub), so this plan is about making that
wave land honestly — not about repairing a shipped release.

The gap that matters for users is not "we are missing Engine route N". It is that a person who
runs `docker ps --format '{{.Names}}'` or `docker compose up --build` gets an error, and the
project's own docs say that works.

## Audit evidence (reproducible)

Each row was run in this checkout on 2026-11-24.

| # | Claim in docs | What actually happens | Evidence |
|---|---------------|-----------------------|----------|
| A1 | The wave ships as a working package | `swift build` fails with 3 errors on the working tree. `HEAD` (before the wave) builds clean, so the breakage is uncommitted. | `RuntimeService.swift:885,971,1691`: `VZVirtualMachineInstance` has no `hotplugNetwork`/`unplugNetwork`; `LinuxContainer.Configuration` has no `devices` |
| A2 | R1 "live NIC hotplug on CR **and** VZ" is Done | Compiles only under `CONTAINER_VMM_CR=1`; the VZ symbols do not exist upstream at pin `containerization 0.54.0` | `grep -rn 'func hotplugNetwork' .build/checkouts/containerization` → 0 hits; present in `../virtualization.framework/Vendor/...` only |
| A3 | R2 "host `devices` unrestricted" is Done | Same 3rd error — the guest device path only exists in the CR fork | `RuntimeService.swift:1691` |
| B1 | Drop-in Docker CLI is `done` | `container info` crashes with `Can't read a value from a parsable argument definition` | `Info.swift:34` builds `SystemStatus()` without initializing `@Option prefix` / `@Option format` |
| B2 | `ps` supports `--format` | Rejects Go templates; only `json|table|yaml|toml` | `container ps --format '{{.Names}}'` → `The value '{{.Names}}' is invalid` |
| B3 | `logs` matches Docker flags | `--tail` unknown; only `-n` | `container logs --tail 5 x` → `Error: Unknown option '--tail'` |
| B4 | `ps` supports Docker filters | `--filter` unknown | `container ps --filter status=running` → `Error: Unknown option '--filter'` |
| B5 | `run` supports common Docker flags | 12 flags rejected | `--privileged --sysctl --add-host --pids-limit --security-opt --expose --mac-address --pid --ipc --log-driver --gpus --stop-signal` |
| B6 | `bin/docker` shim covers the day loop | `history`, `import`, `search`, `context`, `builder` unhandled | shim `case` has no arms; falls through to `container <verb>` which does not exist |
| C1 | Compose subset is `done` | 12 of the 12 common lifecycle verbs absent | `compose restart/start/stop/pause/unpause/rm/top/port/cp/create/kill/watch` |
| C2 | Compose flags | `--build --wait -v --force-recreate --no-deps --scale --rm -t --tail --format` all unknown | `container compose up --build` → `Unknown option '--build'` |
| C2b | `compose logs` is `done` | **The command cannot parse at all** — duplicate `-f` short flag between `SharedOptions.file` and `Logs.follow` | `container compose logs web` → `Validation failed for 'Logs': Multiple (2) Option or Flag arguments are named "-f"` |
| C3 | Compose `devices` are "allowlist-only, fail closed" | Code is **unrestricted by default** | `Parser.swift:1194` "Unrestricted by default (R2). Set `CONTAINER_DEVICE_ALLOWLIST_ONLY=1`…" |
| D1 | In-core `/var/run/docker.sock` default | Docs disagree with each other | `parity-matrix.md:93` "not default" vs `parity-terminus-support.md:32` "default on"; code defaults `enginePrivilegedSock = true` |
| D2 | Bridge `/containers/create` (HostConfig subset) | 14 HostConfig keys silently ignored | `NetworkMode ExtraHosts Dns ShmSize Init SecurityOpt PidMode IpcMode Ulimits Sysctls CapAdd CapDrop Privileged Devices` → 0 occurrences in `BridgeServer.swift` |
| D3 | Bridge covers the curated surface | No restart, prune, tag, push, archive, attach | route table has no `/containers/{id}/restart`, no `/containers/prune`, no `/images/{name}/tag` or `/push` |
| E1 | R6 "first-party GUI" Done | 198-line SwiftUI list; framebuffer is a `Text` placeholder | `ContainerGUI/main.swift:171` `Text("CRVirtualMachineView host active")`; no `NSViewRepresentable` anywhere |
| E2 | Swarm F1b `done (interim)` | In-memory dict, no orchestration, no task scheduling | `SwarmControlPlane.swift` — 164 lines, `[String: [String: Any]]` |

### The harness problem (root cause of the drift)

`docs/parity-matrix.md` says a row "moves to `done` only when the command ships and is covered by a
test or harness step." In practice the harness step is often a `grep` for a comment:

| Harness | Lines | Nature |
|---------|-------|--------|
| `f4-vz-net-hotplug.sh` | 18 | 5 `grep`s for `nicSpares`, a comment, and an env var |
| `f3-devices-unrestricted.sh` | 17 | 6 `grep`s for comment text like `'Unrestricted by default'` |
| `c3-blk-hotplug.sh` | 18 | 5 `grep`s for a symbol name |
| `f5-incore-sock.sh` | 23 | 8 `grep`s for symbol names and `enginePrivilegedSock: Bool = true` |
| `l1-nfs-default.sh` | 42 | 9 `grep`s across source and docs |
| `l2-shared-volumes.sh` | 41 | 7 `grep`s + an `awk` over one function body |
| `r6-container-gui.sh` | 20 | `grep`s for a string that is a `Text` placeholder, then checks the binary is Mach-O |

None of these execute a container. `make l2-shared-volumes` passes while the package does not
compile. And **no CI workflow invokes any `scripts/parity/` harness** — `grep -rn scripts/parity
.github/` returns nothing, so even the greps are opt-in and manual.

This is the single most important finding: the measurement apparatus reports success
independently of behavior. Every downstream status stamp inherits that.

## Remediation plan

Ordered by dependency, not by glamour. Nothing below reopens Swarm or full Engine OpenAPI.

### P0 — Restore truth (block everything else)

| ID | Work | Done when |
|----|------|-----------|
| P0.1 | **Make the wave compile without an env var.** Gate the VZ hotplug calls and the `czConfig.devices` path behind `#if CONTAINER_VMM_CR` (they depend on fork-only symbols), or vendor the needed upstream patches. Add a compile-time shim so the non-CR path fails at runtime with a clear message instead of at build time. | `swift build` and `swift build --build-tests` exit 0 with no env vars set |
| P0.2 | **Fix `container info`.** Give `Info` its own `@Option prefix` / `@Option format` (or construct `SystemStatus` through `parse`), and audit every wrapper that does `var x = Command(); x.field = …`. | `container info`, `container info --format json` exit 0 |
| P0.3 | **Decide the VMM story and make docs match.** Either CR-only is the supported configuration (then `parity-matrix` must stop saying VZ) or the fork is upstreamed. Record the choice in `docs/plans/2026-11-21-l2-strategy-lock.md` style. | One claim sentence, consistent in `parity-matrix`, `parity-terminus-support`, `docker-job-catalog` |
| P0.4 | **Make harnesses behavioral.** Rewrite the grep harnesses in the table above to actually run `container` against a live system and assert observable output. Where a behavior cannot be exercised in CI (VZ hotplug needs a VM), mark the row `blocked (manual harness)` rather than `done`. | No row is `done` on the strength of a source `grep` |
| P0.5 | **Wire parity into CI.** Add a workflow job (macOS runner, `make install-kernel`) that runs T0/T1/T3 and the bridge e2e; nightly if too slow for PRs. | `.github/workflows/` references `scripts/parity/`; green on `main` |
| P0.6 | **Reconcile the contradictions.** Fix `parity-matrix.md:93` vs `parity-terminus-support.md:32` on docker.sock; fix `compose-support-matrix.md` `devices` to match `Parser.swift` (unrestricted default, allowlist opt-in). | `grep` for "not default" and "allowlist-only" returns only correct statements |

### P1 — Make the `docker` drop-in actually drop in

The shim and the CLI currently diverge on the flags real scripts use. This is the difference
between "I can try it" and "I can swap the alias".

| ID | Work | Done when |
|----|------|-----------|
| P1.1 | **`--format` Go-template support** for `ps`, `images`, `inspect`, `stats`, `volume list`, `network list`, `history`, `system df`. Add a small `{{.Field}}` / `{{json .}}` / `table` renderer alongside the existing `ListFormat`. | `docker ps --format '{{.Names}}\t{{.Status}}'` works |
| P1.2 | **`--filter`** on `ps` and `images` (`status=`, `name=`, `label=`, `ancestor=`, `dangling=`, `reference=`). The backend already has `ContainerListFilters` (ids/status/labels) — this is mostly CLI parsing plus a name filter. | `docker ps --filter status=exited -q` works |
| P1.3 | **`logs --tail`** (and `--since` / `--until` if the log store supports it) as aliases alongside `-n`. | `docker logs --tail 100 -f <id>` works |
| P1.4 | **`run` flag pass-through**: `--privileged`, `--sysctl`, `--add-host`, `--pids-limit`, `--security-opt`, `--expose`, `--mac-address`, `--pid`, `--ipc`, `--log-driver`, `--gpus`, `--stop-signal`. Map to `ContainerConfiguration` where the model already has the field (`sysctls`, `stopSignal`, `devices`, `capAdd/Drop`); accept-and-warn for the ones the per-VM model genuinely cannot honor (`--pid host`, `--ipc host`, `--gpus all`). | `container run --help` lists them; warn-only ones print one clear line |
| P1.5 | **Shim completeness**: `history`→`image history`, `search`→explicit unsupported message, `context`→`DOCKER_HOST` guidance, `builder`→`builder` plugin, `import`→`image load`, plus `container container ls` / `volume ls` / `network ls` passthrough. | `t2-docker-shim.sh` exercises each and asserts a non-error |
| P1.6 | **Extend the shim harness** to a real migration corpus: run a handful of one-liners from `skills/container/references/docker-migration.md` verbatim under `bin/docker` and fail on any `Unknown option`. | Corpus green; doc snippets are executable |

### P2 — Compose lifecycle parity

`compose up/down/ps/logs/exec/run/build/config/doctor` is a real subset, but `docker compose`
users reach for `restart`, `stop`, `start`, `rm`, and `-v`/`--build`/`--wait` constantly.

| ID | Work | Done when |
|----|------|-----------|
| P2.1 | Add `compose stop`, `start`, `restart`, `rm`, `pause`, `unpause`, `kill` — thin wrappers over `container` verbs filtered by project label, mirroring the existing `logs`/`exec` pattern. | Each runs against corpus fixture `01-redis-app` |
| P2.2 | Add `compose top`, `port`, `cp`, `create`, `watch` — `top`/`port`/`cp` are one-liners over existing verbs; `create` reuses the up planner without start; `watch` is lowest priority. | Documented in `compose-support-matrix.md` in the same change |
| P2.3 | Add flags: `down -v/--volumes`, `down -t`, `up --build`, `up --wait`, `up --force-recreate`, `up --no-deps`, `up --scale`, `run --rm`, `logs --tail`, `ps --format`, `pull --ignore-pull-failures`, `build --no-cache`. | Each flag exercised in `t3-compose-corpus.sh` |
| P2.3b | **Fix `compose logs` — it cannot parse today.** `SharedOptions.file` claims `-f` and `Logs.follow` claims `-f`; ArgumentParser rejects the whole subcommand. Give the shared option a non-conflicting short name (or none) and keep `-f` for follow. | `container compose logs -f <svc>` and `container compose logs <svc>` both parse and run |
| P2.4 | Make `compose-support-matrix.md` generated-or-checked: a test asserts every documented key/flag exists in the parser, and every parser key appears in the doc. | Drift fails CI (see P0.5) |
| P2.5 | **Smoke-parse every subcommand.** A unit test that instantiates `Application.parseAsRoot` for each subcommand path, so a duplicate flag or an uninitialized wrapper fails the build instead of shipping. This would have caught both C2b and B1. | Test covers every command in `Application.groupedSubcommands` |

### P3 — Close the Engine bridge's silent gaps

The bridge's *design* (curated subset, 501 outside it) is sound and should stay. The problem is
that `/containers/create` accepts a body containing `HostConfig.CapAdd` and silently drops it,
which is worse than 501 — the caller believes it was honored.

| ID | Work | Done when |
|----|------|-----------|
| P3.1 | **Reject-don't-ignore**: for every `HostConfig` key the bridge does not map, return `400` with the key named, unless it is on an explicit "known-benign" list (`LogConfig` etc.). | Testcontainers clients get a diagnosable error, not a silent no-op |
| P3.2 | Map the keys the model already supports: `Dns`, `ShmSize`, `Init`, `CapAdd`/`CapDrop`, `Devices`, `Sysctls`, `Ulimits`, `ExtraHosts`. | Round-trip test per key |
| P3.3 | Add high-value missing routes: `POST /containers/{id}/restart`, `POST /containers/{id}/update`, `POST /containers/prune`, `POST /images/{name}/tag`, `POST /images/{name}/push`, `GET /system/df`. | `docker-api-bridge support` lists them; e2e covers them |
| P3.4 | `POST /exec/{id}/start` currently returns `{"StatusCode":n}` with no streamed stdout. Any client that reads exec output (Testcontainers `execInContainer`, most CI) sees nothing. Implement the Docker multiplex stream. | `docker exec` over the socket returns command output |
| P3.5 | Add `GET /containers/{id}/archive` + `PUT` (used by `docker cp` and several test frameworks) — or document it as permanently 501 and remove `cp` from any drop-in claim. | Decision recorded; matrix updated |

### P4 — Honesty pass on the rest

| ID | Work |
|----|------|
| P4.1 | `container-gui`: either implement the framebuffer host (`NSViewRepresentable` over the CR/VZ display) or demote R6 to `in-progress` and drop the placeholder `Text`. A green harness must not key off a UI string. |
| P4.2 | `SwarmControlPlane`: keep the 501 stance for Swarm as a *product* decision, but stop printing a fake `JoinTokens`/`swarm` object that implies orchestration. Either return `501` with a clear message or label every response `"in-memory stub"`. |
| P4.3 | Rewrite the status stamps: `docker-job-catalog.md` "achieved" and `parity-terminus-support.md` "shipped" get a dated **superseded / under re-verification** banner pointing here. |
| P4.4 | `skills/container/references/docker-migration.md` and `skills/container/SKILL.md`: every snippet must be covered by P1.6's executable corpus or deleted. |

## What this plan deliberately does not do

- Reopen Swarm as orchestration, or full Engine OpenAPI.
- Promise bit-identical Docker Desktop.
- Fix the per-container-VM memory-density limit (an architecture property, documented in
  `technical-overview.md`).
- Implement Podman pods or Quadlet.

Those stay `wontfix`/non-goal. The difference is that after this plan, `wontfix` will be the
*honest* reason a row is missing, rather than one of several competing reasons including "it says
`done` but the flag errors".

## Sequencing

```
P0.1 ─┬─> P0.2 ──> P1.* ──> P1.6 corpus
      │
      └─> P0.4/P0.5 (harness + CI) ──> P2.4 (doc drift gate)
                     │
                     └─> P3.*
P0.3 (VMM decision) ──> unblocks P4.1
P0.6 ──> P4.3
```

P0.1 is a hard gate: nothing can be verified, and no harness can be trusted, until the wave
builds without an undocumented env var. P0.4 and P0.5 should land in the same wave, because a
behavioral harness that CI never runs will drift again exactly the way the greps did.

Note that P0.1 alone does not unblock the *claims* — it only unblocks verification. If the
fork-only symbols are simply gated out, then R1 on VZ and R2 on VZ become runtime-unsupported,
and P0.3 must demote those rows rather than leave them `done`.

## First three commits

1. **`fix: build without CONTAINER_VMM_CR`** — gate the fork-only symbols; add a regression job
   that runs `swift build` with a clean environment. (P0.1)
2. **`fix(cli): container info argument decoding`** — plus a unit test that constructs and runs
   every top-level alias command. (P0.2)
3. **`test(parity): replace source greps with behavioral harnesses; run in CI`** — rewrite
   `f4`/`f3`/`c3`/`f5`/`l1`/`l2`/`r6`, add the workflow. (P0.4, P0.5)

After those three, the status table in `parity-matrix.md` becomes trustworthy enough to plan
against, and P1/P2/P3 can be sequenced by user demand.
