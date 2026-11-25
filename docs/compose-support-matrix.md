# Compose support matrix (Docker-matched)

Status values match [parity-matrix.md](parity-matrix.md). This page is the Compose-key contract for `container compose`.

## CLI surface

| Docker Compose | `container compose` | Status | Notes |
|----------------|---------------------|--------|-------|
| `up` | `compose up` | `done` | Always detached; `-d`, `--build`, `--wait` accepted (builds and `depends_on` health waits always happen). `--force-recreate`, `--remove-orphans` act; `--no-deps` is accepted but all services start. `--scale` is not supported (use `deploy.replicas`). |
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
| Global `-f FILE` / `-p NAME` / `--profile` | before the subcommand (`compose -f x.yml up`) | `done` | Hoisted behind the subcommand by the plugin entrypoint, so `logs -f` still means follow. Repeating `-f` to merge files is rejected; use `extends`. |

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

## Mount types (engine)

| Type | Status | Notes |
|------|--------|-------|
| bind / virtiofs | `done` | |
| volume | `done` | Named + anonymous |
| tmpfs | `done` | |
| nfs | `done` | Guest NFS; corpus `06-nfs` via `nfs-guest-server.sh` + NFS-enabled kernel |
