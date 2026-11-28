# Production-shaped Compose workloads

Automated via corpus fixtures `08-wordpress`, `09-nextcloud`, `10-immich`
(`make compose-parity`). These YAML files remain for manual / exploratory runs.

| Stack | Source pattern | Result |
|-------|----------------|--------|
| `wordpress-mariadb-redis.yaml` | Classic self-hosted WP + MariaDB + Redis | **Pass** — `compose up`, `service_healthy` waits, HTTP 302; service-name DNS (`db`/`redis`) via aliases |
| `nextcloud-postgres-redis.yaml` | Core of [heyvaldemar Nextcloud+Traefik](https://github.com/heyvaldemar/nextcloud-traefik-letsencrypt-docker-compose) minus Traefik/LE/`docker.sock`/`security_opt` | **Pass path** — app+db+redis; shared RW named volumes use the virtiofs directory plane (B-Wave 3 / L2). Corpus `09-nextcloud` omits cron but multi-writer is allowed. |
| Immich release `docker-compose.yml` | [immich-app/immich](https://github.com/immich-app/immich) | **Pass** (corpus `10-immich`) — `${VAR}` / `.env` interpolation + `healthcheck: {disable: false}` without `test`; ML on profile `ml`. Postgres needs a named volume + `PGDATA` subdir (virtiofs bind chown fails; named volumes include `lost+found`). |

## Gaps found while testing

1. **`inspect` omitted live `healthStatus`** (CLI decode forced `.none`) — broke Compose `depends_on: service_healthy`. Fixed in `ContainerConfiguration` encode/decode + durable Bundle strip.
2. **`container_name` ≠ service name** had no service-name DNS alias — peers could not resolve `db`. Fixed: compose adds `alias=<service>` when names differ.
3. **Exact aliases are globally unique** across networks — two projects cannot both publish alias `redis` while both run. Create refuses with an actionable message; run stacks sequentially (corpus does). Preflight: `container compose doctor`.
4. **Named volume sharing** — default local volumes are host directories via virtiofs (multi-writer). Block-image volumes (`--opt backend=block`) stay exclusive. Preflight: `compose doctor` INFO `[named-volume-single-writer]`.
5. **Compose `${ENV}` interpolation** from project `.env` — implemented for compose YAML text (`$VAR`, `${VAR}`, `${VAR:-default}`, `$$`).
6. Upstream Traefik production files often need `security_opt`, `docker.sock`, `external` networks — fail closed / unsupported. `compose doctor` warns on `docker.sock` binds.

**Isolation-by-convention:** tear down one stack before starting another that reuses bare aliases (`db` / `redis`); do not expect Desktop multi-project density on the per-container VM model.

## Run

```bash
export CONTAINER_CLI="$(pwd)/bin/container"
bin/container compose -f scripts/parity/compose-production/wordpress-mariadb-redis.yaml -p prod-wordpress up
# browse http://127.0.0.1:18080/
bin/container compose -f scripts/parity/compose-production/wordpress-mariadb-redis.yaml -p prod-wordpress down
```

Run Nextcloud **after** tearing down WordPress (global `redis`/`postgres` alias uniqueness).
