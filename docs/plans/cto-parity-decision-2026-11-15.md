# CTO decision: Docker/Podman parity implementation

_Date: 2026-11-15 (residuals closed 2026-11-16)_  
_Reviewer: CTO persona (org gate style)_  
_Plan: [2026-11-15-docker-podman-parity.plan.md](2026-11-15-docker-podman-parity.plan.md)_  
_Contract: [parity-matrix.md](../parity-matrix.md)_  
_Dossier: [cto-parity-approval.md](cto-parity-approval.md)_

## Decision

**GO (scoped)** for packets **P0–P7** including residual close-outs below — subject to `nitpick review -fail-on warning` returning no errors or warnings.

**NO-GO** remains for claiming a full privileged network DNS listener, a complete Engine API, or “drop-in Docker.” Full network-scoped DNS (#1809 long-term) is still the preferred successor to hosts injection.

## Evidence

| Packet | Result | Evidence |
|--------|--------|----------|
| P0 matrix + harness | pass | `docs/parity-matrix.md`, `scripts/parity/t0-core-loop.sh`, `scripts/parity/t1-stack-smoke.sh`, skills + command reference + networking sync |
| P1 DNS (#1809 interim) | pass (interim+) | Bootstrap `/etc/hosts` peers + late-join/leave refresh via staged `install` as root; managed peer markers preserve other hosts lines |
| P2 restart policy | pass | `--restart` including `on-failure[:max]`, exponential backoff (1-based attempt persisted after successful restart start), crash Task + cancel on stop, boot start, manual-stop marker |
| P3 healthcheck | pass | Create-time contract + guest probe loop updates in-memory `healthStatus`; compose translates `healthcheck:` and waits on `service_healthy` |
| P4 lifecycle sugar | pass | `restart` / `wait` / `port` / `attach`; `start -a` on running streams logs and waits |
| P5 compose plugin | pass | Curated fail-closed subset; `restart:`, `healthcheck:`, `depends_on: condition: service_healthy` |
| P6 API bridge | pass (subset) | Unix-socket curated Engine routes (`/_ping`, containers list/inspect/logs/start/stop/kill/wait/delete, images list); other routes 501 |
| P7 Podman adjacency | pass (docs) | Matrix points at `machine` + `cluster`; no Podman CLI clone |

## Build / test / nitpick

- `swift build` (container, ContainerAPIService, container-runtime-linux, container-compose, container-docker-api-bridge) — green
- `swift test --filter RestartPolicyTests|ContainerHealthcheckTests|PeerHostEntryTests` — pass
- `nitpick review -full -fail-on warning` — **pass**: EXIT 0, Reviewed 17 file(s): no findings (2026-11-16)

## Residuals closed (2026-11-16)

1. Guest healthcheck probe loop + compose `service_healthy` wait — done
2. Restart backoff + `on-failure:N` — done
3. Late-join hosts refresh — done (full DNS listener still future)
4. Docker API bridge curated subset — done (create/build/exec still 501)
5. `attach` / `start -a` on running — done (stdin to init not rebindable)

## Still out of scope / future

- Privileged network-scoped DNS listener (#1809 full)
- Full Engine API / `/var/run/docker.sock` in core
- Compose `build:` execution
- `rename` / `pause` / `events` / unified system prune

## Promotion language

Allowed: “workflow parity for listed matrix rows,” including compose healthy wait and attach-to-running (log stream).  
Forbidden: “drop-in Docker,” “full Engine API,” “complete network DNS.”
