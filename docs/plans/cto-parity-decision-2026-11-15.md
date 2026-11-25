# CTO decision: Docker/Podman parity implementation

_Date: 2026-11-15 (residuals closed 2026-11-16; complete scoped GO 2026-11-17)_  
_Reviewer: CTO persona (org gate style)_  
_Plan: [2026-11-15-docker-podman-parity.plan.md](2026-11-15-docker-podman-parity.plan.md)_  
_Contract: [parity-matrix.md](../parity-matrix.md)_  
_Dossier: [cto-parity-approval.md](cto-parity-approval.md)_

## Decision

**Working-tree CTO GO (scoped P0–P7 + full parity expansion track against the matrix)** — every matrix row in the claimed tiers and the 2026-11-17 expansion checklist is `done`, `done (interim)`, `alias`, `plugin`, or honest `wontfix`. Bare-name resolution remains `done (interim)` pending #1809. Nitpick `review -fail-on warning` on this working tree: **no findings** (`/tmp/nitpick-review7.log`, 2026-11-17). A release-train **SHA GO** still requires committing this harden and stamping the resulting SHA.

**NO-GO** remains for claiming a full privileged network DNS listener, a complete Engine API, or unqualified “drop-in Docker.” Full network-scoped DNS (#1809 long-term) is still the preferred successor to hosts injection.

## Evidence

| Packet | Result | Evidence |
|--------|--------|----------|
| P0 matrix + harness | pass | `docs/parity-matrix.md`, `scripts/parity/t0-core-loop.sh`, `scripts/parity/t1-stack-smoke.sh`, skills + command reference + networking sync |
| P1 DNS (#1809 interim) | pass (interim+) | Bootstrap `/etc/hosts` peers + late-join/leave refresh via staged `install` as root; managed peer markers preserve other hosts lines; self identity excluded from managedIPs |
| P2 restart policy | pass | `--restart` including `on-failure[:max]`, exponential backoff, crash Task + cancel on stop, boot start, manual-stop marker |
| P3 healthcheck | pass | Create-time contract + guest probe loop updates in-memory `healthStatus`; compose translates `healthcheck:` and waits on `service_healthy` |
| P4 lifecycle sugar | pass | `restart` / `wait` / `port` / `attach`; `start -a` on running streams logs and waits; `rename` is `done` (Name≠Id) |
| P5 compose plugin | pass | Curated fail-closed subset; `restart:`, `healthcheck:`, `depends_on: condition: service_healthy` |
| P6 API bridge | pass (interim) | Unix-socket curated Engine routes plus create/exec/pause/unpause/changes subsets; build/networks/volumes still 501 |
| P7 Podman adjacency | pass (docs) | Matrix points at `machine` + `cluster`; no Podman CLI clone |

## Build / test / nitpick

- Filtered suites on this working tree: `swift test --filter RuntimeCleanupHookTests` — 6/6 pass; `swift build --product container` — pass (2026-11-17)
- Prior full suite on the same harden line: `make test` 1093 pass; `make integration` warmup + 297 concurrent + 111 serial (2026-11-17); also `RestartPolicyTests`, `ContainerHealthcheckTests`, `PeerHostEntryTests`
- `nitpick review -full -fail-on warning` on this working tree — EXIT 0, no findings (`/tmp/nitpick-review7.log`, 2026-11-17 expansion)
- Prior scoped harden: `nitpick review -full -fail-on warning` EXIT 0 (`/tmp/nitpick-plain-final8.txt`); adversarial note in `cto-adversarial-review-2026-11-17.md` / `cto-adversarial-review-2026-11-17-expansion.md`

## Residuals closed

1. Guest healthcheck probe loop + compose `service_healthy` wait — done
2. Restart backoff + `on-failure:N` — done
3. Late-join hosts refresh — done (full DNS listener still future)
4. Docker API bridge curated subset — done; create/exec/pause/unpause/changes interim landed (build/networks/volumes still 501)
5. `attach` / `start -a` on running — done (stdin to init not rebindable)
6. Hosts merge self-identity preservation under concurrent peer refresh — done
7. Runtime cleanup hook child reap (`pkill -P` + direct SIGKILL) — done
8. `rename` disposition — `done` (stable UUID Id + mutable Name)

## Still out of scope / future

- Privileged network-scoped DNS listener (#1809 full)
- Compose `build:` execution
- Swarm, Podman `pod`, Quadlet, Podman-only flags
- Full Engine create/build/exec shapes; in-core apiserver `docker.sock` bind

## Expanded track (2026-11-17)

Shipped against [2026-11-17-full-parity-expansion.plan.md](2026-11-17-full-parity-expansion.plan.md) and `docs/parity-matrix.md`:

| Item | Matrix status |
|------|---------------|
| Drop-in Docker CLI (#79) | `done (interim)` (`ps`, `images`, `--net`) |
| Engine bridge create/exec + optional sock | `done (interim)` |
| `container system prune` | `done` |
| `network connect` / `disconnect` | `done (interim)` |
| `rename` (Name≠Id) | `done` |
| `pause` / `unpause` | `done` |
| `diff` | `done` |
| `update` | `done` |
| `events` | `done` |
| `history` | `done` |

## Promotion language

Allowed: “scoped workflow parity for listed matrix rows at their stated status,” including compose healthy wait, attach-to-running (log stream), `system prune`, Name≠Id rename, pause/diff, and `done (interim)` bare-name hosts / CLI aliases / Engine bridge subsets.  
Forbidden until the matching rows are unqualified `done`: “drop-in Docker,” “full Engine API,” “complete network DNS,” or describing `done (interim)` rows as full drop-in.
