# Compose parity corpus

Fixtures for `scripts/parity/t3-compose-corpus.sh`.

| Fixture | Intent |
|---------|--------|
| `01-redis-app` | Two services, depends_on, named volume, short ports |
| `02-wordpress-mysql` | Classic stack: env, volumes, long-form ports |
| `03-traefik-whoami` | Extra project network + labels |
| `04-bind-named` | Bind + named volume mix (Nextcloud-like) |
| `05-build-envfile` | `build:`, `env_file`, working_dir, labels |
| `06-nfs` | `driver: nfs` against in-guest server (`nfs-guest-server.sh`) or `COMPOSE_NFS_*` |
| `07-completed` | `depends_on: service_completed_successfully`, hostname, `cap_add`, `stop_grace_period` |
| `08-wordpress` | Production-shaped WP + MariaDB + Redis; HTTP 302 install page |
| `09-nextcloud` | Production-shaped Nextcloud + Postgres + Redis (shared virtiofs named-volume plane; cron optional) |
| `10-immich` | Immich-shaped stack with project `.env` `${VAR}` interpolation; ML on profile `ml` (R4 supported; `COMPOSE_ENABLE_IMMICH=1` default in CR compose e2e) |

Run: `make compose-parity` or `bash scripts/parity/t3-compose-corpus.sh`.

Skip production-shaped fixtures (08–10) with `COMPOSE_SKIP_PRODUCTION=1`. Default wall clock is 1200s (`COMPOSE_CORPUS_TIMEOUT`).

NFS needs a guest kernel with NFS client support and (for the helper) `nfsd`. Build from
Containerization `kernel/` and `container system kernel set --binary … --force`. See
[volumes.md NFS mounts](../../../docs/volumes.md#nfs-mounts). The corpus auto-starts
`nfs-guest-server.sh` when `COMPOSE_NFS_*` is unset (no host `nfsd`/sudo).
