# CTO stamp — DNS / Engine / CLI (2026-11-19 refresh)

## Verdict

**GO** for claiming:

1. **Complete guest network-scoped DNS** (#1809)
2. **Drop-in Docker CLI** via `bin/docker` shim + aliases (#79)
3. **Curated full Engine API bridge** for the printed support matrix (#66 / #1925 plugin path)

## Evidence

| Claim | Matrix | Evidence |
|-------|--------|----------|
| Complete guest DNS (#1809) | Bare service name → `done` | hosts-dns + hosts injection; `PARITY_STRICT_DNS=1 scripts/parity/t1-stack-smoke.sh` (nslookup=ok) |
| Drop-in Docker CLI (#79) | CLI row → `done` | `bin/docker` from `scripts/docker`; `scripts/parity/t2-docker-shim.sh` |
| Engine API bridge | bridge + sock rows → `done` | Curated support matrix; `scripts/parity/t2-bridge-e2e.sh` (create/exec/pause/networks/volumes/images) |

## Bounds (honest)

- Engine routes **outside** `docker-api-bridge support` return **501** by contract — that is the product surface, not an interim gap.
- In-core apiserver bind of `/var/run/docker.sock` remains out of scope; the plugin `--socket` path is the supported sock story.
- Swarm / Podman pods / Quadlet remain `wontfix`.
- Live NIC hotplug for `network connect` on running containers remains `done (interim)`.

## Language now allowed

- “Drop-in Docker CLI” (shim + aliased verbs)
- “Full Engine API” **only** as “full curated Engine bridge per support matrix”
- “Complete network DNS” for guest bare-name discovery
