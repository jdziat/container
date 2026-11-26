# Compose support matrix (Docker-matched)

Status values match [parity-matrix.md](parity-matrix.md). This page is the Compose-key contract for `container compose`.

## CLI surface

| Docker Compose | `container compose` | Status | Notes |
|----------------|---------------------|--------|-------|
| `up` | `compose up [SERVICE...]` | `done` | Always detached (`-d` accepted). Named services start with their `depends_on` chain; `--no-deps` starts only the named ones. `--scale SERVICE=N` (capped at 3), `--no-start`, `--no-build`, `--pull always\|missing\|never`, `--force-recreate` and `--remove-orphans` act. `--wait` blocks until each service is running (and healthy, where it has a healthcheck), with `--wait-timeout` (default 300s). Services are built on every `up` unless `--no-build` |
| `down` | `compose down` | `done` | Stops/deletes project containers + default network. `-v` removes declared named volumes; `-t` sets the minimum stop timeout. |
| `config` | `compose config` | `done` | Validates and prints plan summary |
| `doctor` | `compose doctor` | `done` | Preflight loud edges (aliases, single-writer volumes, devices, NFS, docker.sock); `--strict` fails on warn |
| `ps` | `compose ps` | `done` | Lists containers with compose project labels |
| `logs` | `compose logs` | `done` | Forwards to `container logs` |
| `exec` | `compose exec` | `done` | Forwards to `container exec` |
| `run` | `compose run` | `done` | One-off service container |
| `build` | `compose build` | `done` | Runs `container build` for services with `build:` |
| `pull` / `images` | `compose pull` / `compose images` | `done` | Thin wrappers over `image pull` / planned image list. `pull --ignore-pull-failures` accepted. |
| `stop` / `start` / `restart` / `rm` / `kill` / `pause` / `unpause` | same names | `done` | Act on the project's containers (all, or the named services). `stop`/`restart` take `-t`; `rm` takes `-f`/`-s`; `kill` takes `-s`. |
| `top` / `port` / `create` | same names | `done` | `top` runs `ps aux` in the guest; `create` plans and creates without starting. |
| `cp` / `watch` | - | `wontfix` | Not implemented. Use `container copy`. |
| Global `-f FILE` / `-p NAME` / `--profile` / `--env-file` / `--project-directory` | before the subcommand (`compose -f x.yml up`) | `done` | Hoisted behind the subcommand by the plugin entrypoint, so `logs -f` still means follow. Attached forms (`-fx.yml`, `-pname`) work. |
| Several `-f` files | `-f base.yml -f override.yml` | `done` | Merged in order by the Compose Spec rules: maps merge, later scalars win, `command`/`entrypoint` replace, `ports`/`dns`/`env_file`/`expose` append, `volumes`/`devices`/`secrets` merge by target/source. Relative paths resolve against the **first** file's directory (or `--project-directory`). `extends: file:` is relative to that same directory |
| Default files | no `-f` | `done` | `compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml` in that order, plus the matching `*.override.*`. `COMPOSE_FILE` (`:` separated, or `COMPOSE_PATH_SEPARATOR`) is used when no `-f` is given |
| `COMPOSE_PROJECT_NAME` | env or `.env` | `done` | Precedence: `-p`, `COMPOSE_PROJECT_NAME`, top-level `name:`, directory name |

## Top-level keys

| Key | Status | Notes |
|-----|--------|-------|
| `services` | `done` | Required |
| `name` | `done` | Project name |
| `version` | `done` | Accepted, ignored |
| `networks` | `done` | Creates named networks; default project network always used |
| `volumes` | `done` | Named volumes created on up |
| `configs` | `done` | File-based only |
| `secrets` | `done` | File-based only |
| `x-*` | `done` | Ignored by design |
| `extensions` / Swarm-only | `wontfix` | |

## Service keys

| Key | Status | Notes |
|-----|--------|-------|
| `image` | `done` | Required unless `build:` produces a tag |
| `build` | `done` | Invokes `container build` |
| `command` / `entrypoint` | `done` | |
| `environment` / `env_file` | `done` | |
| `${VAR}` / `.env` interpolation | `done` | Compose-file text: `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:?err}`, `$$`; project `.env` then process env (corpus `10-immich`) |
| `ports` | `done` | Short-form and long-form |
| `volumes` | `done` | Short-form, long-form bind/volume/tmpfs/nfs |
| `depends_on` | `done` | `service_started`, `service_healthy`, `service_completed_successfully` (corpus `07-completed`) |
| `restart` | `done` | |
| `healthcheck` | `done` | `disable: true` / no `test` → no engine override (image HEALTHCHECK); corpus `10-immich` |
| `container_name` | `done` | |
| `labels` | `done` | Plus compose project labels |
| `working_dir` | `done` | |
| `user` | `done` | |
| `hostname` | `done` | Passed as `--hostname` (UTS); FQDN also kept as network alias when dotted |
| `domainname` | `done` | `--domainname` → resolv.conf domain/search + FQDN hosts alias; label kept for inspect |
| `shm_size` | `done` | |
| `profiles` | `done` | Active via `COMPOSE_PROFILES` / `--profile` |
| `tmpfs` | `done` | |
| `networks` | `done` | Extra attachments + aliases |
| `configs` / `secrets` | `done` | File bind mounts |
| `stop_grace_period` | `done` | Maps to `--stop-timeout` and `compose down` `-t` |
| `cap_add` / `cap_drop` | `done` | Maps to `--cap-add` / `--cap-drop` |
| `deploy` | `done (interim)` | Subset: `replicas` (create `service-1..N`, cap 3 with WARN) and `restart_policy.condition` (`none`→`no`, `on-failure`, `any`→`always`) → `--restart` when service-level `restart` is unset; other `deploy.*` keys ignored |
| `extends` | `done` | Same-file or `file:` relative to the compose project dir; deep-merge (child scalars win); `ports`/`volumes`/list env concatenate; env key conflicts → child wins |
| `devices` | `done (interim)` | **Unrestricted by default**: any absolute character or block device path maps to `run --device` (`Parser.devices`). Set `CONTAINER_DEVICE_ALLOWLIST_ONLY=1` for the old fail-closed allowlist (`/dev/null`, `/dev/zero`, `/dev/urandom`, `/dev/tty`; extend via `CONTAINER_DEVICE_ALLOWLIST`). Character devices are surfaced through a virtiofs file mount; the OCI `linux.devices` mknod path exists only in `CONTAINER_VMM_CR=1` builds. Superseded: [plans/cto-devices-allowlist-2026-11-21.md](plans/cto-devices-allowlist-2026-11-21.md) |
| `ulimits` | `done` | `nofile: 1024` or `{soft, hard}` -> `--ulimit` |
| `sysctls` | `done` | Mapping or `k=v` list -> `--sysctl` (set inside the guest) |
| `extra_hosts` | `done` | Mapping or list, `host:ip` or `host=ip` -> `--add-host`. `host-gateway` is rejected (use the gateway IP) |
| `dns` / `dns_search` / `dns_opt` | `done` | -> `--dns` / `--dns-search` / `--dns-option` |
| `stop_signal` | `done` | -> `--stop-signal` |
| `init` | `done` | -> `--init` |
| `read_only` | `done` | -> `--read-only` |
| `platform` | `done` | -> `--platform` |
| `cpus` | `done (interim)` | Whole CPUs only: a fractional value is rounded **up**, with a warning |
| `mem_limit` | `done` | Also `deploy.resources.limits.memory` (the service-level key wins). `512m`, `1g`, `1gb` or bytes; rounded up to whole MiB with a warning. `deploy.resources.limits.cpus` is read like `cpus` |
| `mac_address` | `done` | Applied to the service's first network |
| `pull_policy` | `done (interim)` | `always` pulls before start, `never` fails if the image is absent, `missing`/`build` are the default. `daily`, `weekly`, `every_*` are treated as `missing` with a warning |
| `scale` | `done (interim)` | Same as `deploy.replicas` (which wins if both are set); capped at 3 with a warning |
| `network_mode` | `wontfix` | `bridge`/`default` are accepted; `host`, `none`, `service:*`, `container:*` are rejected (each container is its own VM) |
| `links`, `external_links`, `volumes_from`, `group_add` | `wontfix` | Rejected with a reason. Use networks and service names, a shared named volume, or `user:` |
| `privileged`, `security_opt`, `pid`, `ipc`, `uts`, `cgroup`, `cgroup_parent`, `logging`, `expose`, `userns_mode`, `isolation`, `oom_score_adj`, `oom_kill_disable`, `cpu_shares`, `cpu_quota`, `cpu_period`, `cpu_rt_runtime`, `cpu_rt_period`, `cpuset`, `cpu_count`, `cpu_percent`, `mem_reservation`, `memswap_limit`, `mem_swappiness`, `blkio_config`, `pids_limit`, `runtime`, `storage_opt`, `annotations`, `develop` | `done (interim)` | Accepted with **no effect**: one warning is printed when the key is set to a non-default value, naming why. Nothing is silently dropped |
| `tty`, `stdin_open` | `done (interim)` | Accepted with a warning and **no effect**: a detached container's stdio is closed after start, so a bare `sh` still exits (use `sleep infinity`) |

## Mount types (engine)

| Type | Status | Notes |
|------|--------|-------|
| bind / virtiofs | `done` | |
| volume | `done` | Named + anonymous |
| tmpfs | `done` | |
| nfs | `done` | Guest NFS; corpus `06-nfs` via `nfs-guest-server.sh` + NFS-enabled kernel |

## Known divergences from Docker Compose

- **Unquoted YAML booleans:** `FOO: yes`, `on`, `off`, `no` are read as booleans, so `FOO` becomes `true`/`false`.
  Docker Compose keeps them as the strings `yes`/`on`/... Quote the value (`FOO: "yes"`) to be safe.
- **`up` detaches:** `compose up` always returns once the services are started (`-d` is accepted).
- **`tty` / `stdin_open`:** accepted with a warning and no effect; a detached container's stdio is closed after start.
- **Replicas are capped at 3** (`deploy.replicas`, `scale`).
- **`extends: file:`** and relative paths resolve against the first compose file's directory (or `--project-directory`).
