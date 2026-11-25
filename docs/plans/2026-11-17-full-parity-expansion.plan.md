# Full parity expansion (2026-11-17)

Reopens items that were `wontfix` / `alias` and schedules them for Docker/Podman parity.

## Newly in scope

| Item | Matrix status | Notes |
|------|---------------|-------|
| Drop-in Docker CLI (#79) | `done (interim)` | Aliases: `ps`, top-level `images`, `--net`≡`--network`. Not full drop-in; many Docker-only flags remain. |
| Full Engine API / docker.sock (#66, #1925) | `done (interim)` / sock `planned` | Bridge: create/exec/pause/unpause/changes subsets + optional `--socket /var/run/docker.sock`. Build/networks/volumes and full shapes still open. |
| `container system prune` | `done` | Unified prune; `--all`, `--volumes` |
| `network connect` / `disconnect` | `done (interim)` | Config update; `--restart` for running. Live hotplug blocked until Containerization/VZ spare-NIC or NIC hot-add (attachments fixed at VM create). |
| `rename` (Name≠Id) | `done` | Stable UUID Id + mutable Name |
| `pause` / `unpause` | `done` | Per-container VM suspend/resume via Virtualization pause/resume |
| `diff` | `done` | Rootfs EXT4 inventory vs image snapshot (A/C/D) |
| `update` | `done` | `--cpus` / `--memory` / `--restart` |
| `events` | `done` | Lifecycle JSON event stream |
| `history` | `done` | `container image history` |

Still **out of scope** unless separately requested: Swarm, Podman `pod`, Quadlet, Podman-only flags.

## Suggested order

1. ~~`system prune`~~ (landed)
2. `image history` (read-only OCI)
3. `events` (local pub/sub from ContainersService)
4. `rename` (schema + inspect Name≠Id)
5. `network connect`/`disconnect`
6. `update` (resource limits)
7. ~~Engine API create/exec + sock bind option~~ (interim; build/full Engine still open)
8. ~~Drop-in CLI flag aliases~~ (interim: `ps`, `images`, `--net`; more aliases as needed)
9. ~~`pause`/`unpause`, `diff`~~ (landed)

## Honesty rule

Do not claim “full parity” or “drop-in Docker” until the corresponding matrix rows are `done`. `planned` means scheduled, not available.
