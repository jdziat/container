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
| **B. Selecting and merging** | `up SERVICE...` with dependency closure, and `--no-deps` | **done** (13 unit tests) |
| | `up --scale svc=N`, `--no-start`, `--pull`, `--no-build` honored | **done** (unit-tested; live checks in the corpus, not yet run) |
| | `up --wait` really waits (running, and healthy where a healthcheck exists) | **done**, verified live (run 45902573808) |
| | Several `-f` files merged in order; `compose.override.yaml` auto-loaded; default file discovery | **done** (32 tests) |
| | `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME`, `--env-file`, `--project-directory` | **done** |
| | External networks/volumes (plain-key naming, existence check); network `ipam`, `internal`, `labels`, labeled create and label-scoped `down` | **done** (16 unit tests); verified live: label scoping, external attach/never-removed/missing-fails, `ipam` subnet. **`internal: true` has no live check** |
| **C. Verbs** | `cp`, `ls`, `version`, `wait`, `push`, `export` | **done**; live-verified: `cp` round trip, `ls`, `version`, `wait`, `export`. **`push` has no live check** (needs a registry) |
| | `ps` (`-a`, `--services`, `--status`, `--format json`); `logs` for all services, `--no-log-prefix`; `exec`/`run` flags; `run` starts dependencies | **done**; live-verified: `ps` (`--services`, `--format json`, `--status exited`, one-off hiding), `logs` prefixing and `--no-log-prefix`, `exec`/`run` with `-e`, `run` starting dependencies and not publishing ports. **Not live-checked:** `exec -d/-u/-w/--index`, `run -d/-u/-w/--entrypoint/-p`. `logs --since/--until/--timestamps` not possible: the engine's `logs` has no such flags |
| | `config` (`--services`, `--volumes`, `--format json`, `-q`); `down --rmi`; global `--dry-run` | **done**; live-verified: `--dry-run` changes nothing, `config --services`, `config --format json`. **`down --rmi` and `config -q`/`--volumes` have no live check.** `config` prints a summary, **not Docker's normalized YAML** |
| | `watch` | **decided: `wontfix`** (see below) |
| **D. Gate** | T3 corpus (`t3-compose-corpus.sh`) in `make parity-behavioral` | **done**: fixtures 01-05 and 07 pass live. **Not run:** 06-nfs (kernel install fails on the runner) and 08-10 production fixtures (opt-in, heavy image pulls). Fixed on the way: T3 and `f2-compose-extends.sh` passed `-f` after the subcommand; a lint now fails any harness that does |
| | New fixtures exercising the Tier A-C keys and verbs | The Tier A-C live checks live in `t2-docker-corpus.sh` (94 checks) rather than as T3 fixtures |

## Decisions and known divergences

- **`tty` / `stdin_open`:** not mapped to `-t`/`-i`. A detached run closes the process's stdio after start,
  so a bare `sh` exits regardless, and `-t -i` fails without a real terminal. They are accepted with a
  warning; use `sleep infinity` (or similar) to keep a container alive.
- **`cpus` / `mem_limit`:** whole CPUs and whole MiB; fractional values round **up** with a warning.
- **`replicas` / `scale`:** capped at 3 (existing interim limit), with a warning.
- **Unquoted YAML booleans:** `FOO: yes` is read as `true` (Docker keeps `"yes"`). Pre-existing; documented in the matrix, not fixed.
- **`up` without `-d`:** still detaches (documented). Foreground log-following is not planned in this pass.
- **`watch`:** `wontfix`. It needs a file watcher plus sync, rebuild and restart rules, and there is no way
  to verify those here; a half-working `watch` is worse than none. Use `up --build` on change.
- **`compose run` ports:** the service's `ports:` are no longer published by `run` unless `--service-ports`
  (Docker's behavior). Earlier versions published them, so a script that relied on that must add the flag.
- **`compose exec` TTY:** allocated only when stdin and stdout are both terminals (Docker allocates by default),
  so piped output is not corrupted.
- **`compose logs` ordering:** several containers are read concurrently and interleave by arrival.
- **`compose config`:** a summary, not Docker's normalized YAML. Writing a faithful normalizer is a separate piece
  of work: the planner does not retain the merged document, so it would need to.

## Live verification (first complete pass)

Run 45902573808 on `f9823ea`, on the dedicated `ghrunner` runner: **94 of 94** docker-corpus checks, T3 fixtures
01-05 and 07, and the bridge streams, hostconfig and lifecycle suites all passed. (The job later reported a failure
in its log-upload step: `ETIMEDOUT` reaching GitHub's artifact service. The parity step itself succeeded.)

It took four live runs to get there. Each failure hid the next, and none could have been seen without a real system:

| Run | Failing | Cause |
|---|---|---|
| 1 (`4644130`) | 6 | `run`/`exec` let ArgumentParser claim the guest command's `-c`; use `.captureForPassthrough` |
| 2 (`4a75ee6`) | 4 | `run` created a dependency that already existed (name conflict); reuse, start or create per dependency |
| 3 (`a69b496`) | 3 | one-off name `<project>_<service>_run_<uuid>` was 79 characters against the engine's 63 limit. This predates the branch (`b1bee7a`): **`compose run` had never worked** |
| 4 (`28773f3`) | 3 | a one-off took aliases the project's own container already holds; one-offs now publish none |

**Still not verified:** the CR build (`CONTAINER_VMM_CR=1`), NFS (06), the production fixtures (08-10),
`internal: true` networks, `push`, `down --rmi`, and the `exec`/`run` flags listed above.
