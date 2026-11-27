# Compose support matrix (Docker-matched)

Status values match [parity-matrix.md](parity-matrix.md). This page is the Compose-key contract for `container compose`.

## CLI surface

| Docker Compose | `container compose` | Status | Notes |
|----------------|---------------------|--------|-------|
| `up` | `compose up [SERVICE...]` | `done` | Always detached (`-d` accepted). Named services start with their `depends_on` chain; `--no-deps` starts only the named ones. `--scale SERVICE=N` (capped at 3), `--no-start`, `--no-build`, `--pull always\|missing\|never`, `--force-recreate` and `--remove-orphans` act. `--wait` blocks until each service is running (and healthy, where it has a healthcheck), with `--wait-timeout` (default 300s). Services are built on every `up` unless `--no-build` |
| `down` | `compose down` | `done` | Stops/deletes project containers + default network. `-v` removes declared named volumes; `-t` sets the minimum stop timeout; `--rmi local\|all` removes the images compose built (`local`) or every service image (`all`), after validating the value so a typo cannot leave a half-done `down`. A failed image removal (for example an image another container still uses) is reported and does not fail the command. |
| `config` | `compose config` | `done` | Validates and prints a plan summary. **Not Docker's normalized YAML**: scripts that parse `docker compose config` output will not work. `--services` and `--volumes` list names, `-q` only validates, `--format json` prints name/network/volumes/networks/services (image, replicas, environment, depends_on) |
| `doctor` | `compose doctor` | `done` | Preflight loud edges (aliases, single-writer volumes, devices, NFS, docker.sock); `--strict` fails on warn |
| `ps` | `compose ps [SERVICE...]` | `done` | Project containers (by label) with NAME, IMAGE, SERVICE, STATUS. Default shows running only and hides `compose run` one-offs; `-a` shows everything. `--status` (repeatable) accepts Docker's `exited` as well as this engine's `stopped`. `--services`, `-q`, `--format json` (Docker's `Name`/`Service`/`State` field names; fewer fields than Docker) |
| `logs` | `compose logs [SERVICE...]` | `done` | All services by default, each line prefixed `name  \| `, `--no-log-prefix` to drop it. `-f` and `--tail N`. No `--since`, `--until` or `--timestamps` (the engine's `logs` has none). Replicas are read concurrently, so lines from different containers interleave by arrival, not by timestamp |
| `exec` | `compose exec` | `done` | `-d`, `-e`, `-u`, `-w`, `--index N`, `-T`. A TTY is allocated only when stdin and stdout are both terminals (Docker allocates one by default), so piped output is not corrupted. No `--privileged` |
| `run` | `compose run` | `done` | One-off container, always removed on exit. Starts the service's `depends_on` chain first unless `--no-deps`. `-d`, `-e`, `-u`, `-w`, `--entrypoint` (`""` clears it), `-p`, `--name`, `-l`, `-T`. **The service's own `ports:` are not published** unless `--service-ports` (as in Docker; earlier versions published them). One-offs carry `com.docker.compose.oneoff=True`. No `-v`, `--no-TTY` is accepted but a TTY is never allocated by `run` |
| `build` | `compose build` | `done` | Runs `container build` for services with `build:` |
| `pull` / `images` | `compose pull` / `compose images` | `done` | Thin wrappers over `image pull` / planned image list. `pull --ignore-pull-failures` accepted. |
| `stop` / `start` / `restart` / `rm` / `kill` / `pause` / `unpause` | same names | `done` | Act on the project's containers (all, or the named services). `stop`/`restart` take `-t`; `rm` takes `-f`/`-s`; `kill` takes `-s`. |
| `top` / `port` / `create` | same names | `done` | `top` runs `ps aux` in the guest; `create` plans and creates without starting. |
| `cp` | `compose cp SERVICE:SRC DEST` / `compose cp SRC SERVICE:DEST` | `done` | Wraps `container copy`. Exactly one side must be a service; `--index N` picks the replica. Refuses a service with no container of this project. No `-a`/`-L` |
| `ls` | `compose ls` | `done` | Projects found from container labels. `-a` includes projects with nothing running, `-q`, `--format json`. The config-files column is empty for containers created by an older plugin |
| `version` | `compose version` | `done` | Prints the `container` CLI version; `--short` |
| `wait` | `compose wait [SERVICE...]` | `done` | Blocks until the containers stop (wraps `container wait`). Fails if none exist |
| `push` | `compose push [SERVICE...]` | `done` | Pushes each service's `image:`. Refuses a service that only has the local `<project>_<service>` build tag, with a message saying to set `image:`. **`--scheme http\|https` is not a Docker flag**: Docker reads insecure registries from the daemon config, which this engine lacks, so a plain-HTTP registry needs it per push (default https). The value is checked before anything is pushed |
| `export` | `compose export SERVICE` | `done` | Wraps `container export`; `--index N`, `-o FILE` |
| Global `--dry-run` | `compose --dry-run <verb>` | `done` | Reads state (`list`, `inspect`) and prints each `container ...` command that would change something, running none of them. Anything that is not a known read is treated as a change, so a verb added later is printed, not run. `--wait` and `depends_on` health waits are skipped, since nothing started. Docker's output format differs |
| `watch` | - | `wontfix` | Needs a file watcher plus sync, rebuild and restart rules that cannot be verified here; a half-working `watch` is worse than none. Use `up --build` (or `build` then `up`) on change |
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
| `networks` | `done` | Created as `<project>_<key>` (or `name:`) and labeled with the project. `internal: true` -> `--internal`; `ipam.config[].subnet` -> `--subnet` / `--subnet-v6` (one of each; `gateway`, `ip_range`, `aux_addresses` and non-default IPAM drivers are rejected); `labels` and `driver_opts` are passed through. Only the `bridge` driver exists. **`external: true`** networks are never created or removed, are looked up by `name:` or their plain key (not project-prefixed), and `up` fails with `network X declared as external, but could not be found` if absent. `down` removes only networks carrying this project's label, so a network an older plugin made without one is left in place (delete it with `container network delete`) |
| `volumes` | `done` | Named volumes created on up (labeled with the project). **`external: true`** volumes are never created or removed, are looked up by `name:` or their plain key (not project-prefixed), and `up` fails with `volume X declared as external, but could not be found` if absent |
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
