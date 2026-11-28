# CTO stamp — job-catalog Docker parity (ex-Swarm) achieved

_Date: 2026-11-19_

## Verdict

**GO** to claim **job-catalog full Docker parity (excluding Swarm)** for this tree, as defined by
[docs/docker-job-catalog.md](../docker-job-catalog.md) and
[2026-11-19-job-catalog-docker-parity.prd.md](2026-11-19-job-catalog-docker-parity.prd.md).

This is the nearest honest “full parity” under the per-container VM model. It is **not**
bit-identical Engine, Docker Desktop density, live NIC hotplug, host `devices`, or Swarm.

## Evidence

| Gate | Result |
|------|--------|
| J1 T0 | `scripts/parity/t0-core-loop.sh` exit 0 |
| J2 T1 | `PARITY_STRICT_DNS=1 scripts/parity/t1-stack-smoke.sh` exit 0 |
| J2 Compose | `make compose-parity` exit 0 including `06-nfs` |
| J3 Shim | `scripts/parity/t2-docker-shim.sh` exit 0 |
| J4 Bridge | `scripts/parity/t2-bridge-e2e.sh` exit 0 |
| Outside-matrix Engine | `POST /swarm/init` → HTTP 501 curated-contract JSON |
| `network connect` interim | Running connect without `--restart` refuses with actionable message |
| Compose `devices` | Fail closed (`wontfix`) |
| Docs honesty | Bridge README / skills / migration aligned with matrix; Recipe A/B/C present |

## Language allowed

- “Job-catalog full Docker parity (ex-Swarm)” / “nearest honest full Docker parity on Mac”
- Existing CTO-allowed phrases: drop-in Docker CLI; curated full Engine bridge per support matrix; complete guest DNS

## Language still forbidden

- Unqualified “full Engine API” / bit-identical Docker Desktop
- Swarm, host `devices`, live NIC hotplug as done
- Zero-config Testcontainers/Dev Containers without a separate scoped claim

## Residuals (loud edges, not catalog debt)

- `network connect` / `disconnect` on running containers: `done (interim)` (`--restart`)
- Compose `domainname`: `done` (`--domainname` → resolv.conf domain/search + FQDN hosts)
- Compose `devices` / Swarm / `deploy` / `extends`: `wontfix`
- Engine routes outside printed `docker-api-bridge support`: HTTP 501 by design
