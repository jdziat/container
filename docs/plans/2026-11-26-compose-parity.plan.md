# Compose parity plan

_Date: 2026-11-26_
_Status: in progress. The "Status" column below is updated as work lands._
_Parent: [2026-11-18-compose-nfs-docker-parity.plan.md](2026-11-18-compose-nfs-docker-parity.plan.md)
(Docker Compose v2 / Compose Spec, single engine, non-Swarm)._

## Goal

Close the distance between `container compose` and Docker Compose v2 for single-host use, and put the
T3 compose corpus into the behavioral gate so the claim has evidence.

**Ground rules (same as the Docker remediation plan):**
- A row is `done` only with a test that fails when the behavior regresses. Pure mappings are
  unit-tested through the real planner (`Tests/ContainerComposeTests`); live behavior is covered by
  the corpus run in the gate.
- Nothing is silently dropped. A key or flag the per-VM model cannot honor is either rejected with a
  reason or accepted with one warning, and the matrix says which.
- Tests are mutation-checked: reintroduce the bug and confirm the test goes red.
- Live checks never run against a shared container system (see `docs/live-gate-ci.md`).

## Non-goals

Swarm orchestration; `deploy` beyond `replicas`/`restart_policy`/`resources.limits`; multi-host;
Podman pods and Quadlet; volume plugins beyond local and NFS.

## Work

| Tier | Item | Status |
|------|------|--------|
| **A. Service keys** | `ulimits`, `sysctls`, `extra_hosts`, `dns*`, `stop_signal`, `init`, `read_only`, `platform`, `cpus`, `mem_limit`/`deploy.resources.limits`, `mac_address`, `pull_policy`, `scale` | **done** (25 unit tests) |
| | `network_mode`, `links`, `volumes_from`, `group_add`, lifecycle hooks: rejected with a reason | **done** |
| | 31 resource/namespace keys + `tty`/`stdin_open`: accepted with one warning, no effect | **done** |
| **B. Selecting and merging** | `up SERVICE...` with dependency closure, and `--no-deps` | todo |
| | `up --scale svc=N`, `--no-start`, `--pull`, `--build`/`--no-build` honored | todo |
| | `up --wait` really waits (running, and healthy where a healthcheck exists) | todo |
| | Several `-f` files merged in order; `compose.override.yaml` auto-loaded; default file discovery | **done** (32 tests) |
| | `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME`, `--env-file`, `--project-directory` | **done** |
| | External networks/volumes; network `ipam`, `internal`, `labels` | todo |
| **C. Verbs** | `cp`, `ls`, `version`, `wait`, `push`, `export` | todo |
| | `ps` (`-a`, `--services`, `--status`, `--format json`); `logs` for all services, `--since`, `--no-log-prefix`; `exec`/`run` flags | todo |
| | `config` (`--services`, `--volumes`, `--format`, `-q`); `down --rmi`; global `--dry-run` | todo |
| | `watch` | **decision pending** (see below) |
| **D. Gate** | T3 corpus (`t3-compose-corpus.sh`) in `make parity-behavioral`, with fixtures for the new keys | todo |

## Decisions and known divergences

- **`tty` / `stdin_open`:** not mapped to `-t`/`-i`. A detached run closes the process's stdio after start,
  so a bare `sh` exits regardless, and `-t -i` fails without a real terminal. They are accepted with a
  warning; use `sleep infinity` (or similar) to keep a container alive.
- **`cpus` / `mem_limit`:** whole CPUs and whole MiB; fractional values round **up** with a warning.
- **`replicas` / `scale`:** capped at 3 (existing interim limit), with a warning.
- **Unquoted YAML booleans:** `FOO: yes` is read as `true` (Docker keeps `"yes"`). Pre-existing; documented in the matrix, not fixed.
- **`up` without `-d`:** still detaches (documented). Foreground log-following is not planned in this pass.
- **`watch`:** needs file-sync, rebuild and restart semantics plus a watcher. It is only worth shipping
  if it can be verified; otherwise it stays `wontfix` with that reason recorded here.
