# CTO GO — Compose + NFS Docker parity (2026-11-18)

## Verdict: GO (with honesty bounds)

Evidence required by the plan:

| Gate | Evidence |
|------|----------|
| Compose key contract | `docs/compose-support-matrix.md` |
| Corpus harness | `scripts/parity/t3-compose-corpus.sh`, `make compose-parity` — **2026-11-18: fixtures 01–05 OK; 06-nfs SKIP without `COMPOSE_NFS_*`** |
| NFS model | Guest `Filesystem.FSType.nfs` → `Mount.any(type: "nfs")`; Parser unit test `testMountNfsDockerShape` |
| NFS e2e validation | **Green (2026-11-18).** Built/installed Containerization `vmlinux-arm64` (`6.18.5-cz-*`, `nfs`/`nfsd` in `/proc/filesystems`). In-guest server via `scripts/parity/nfs-guest-server.sh` (`--cap-add SYS_ADMIN`). Docker-shaped `--mount type=nfs,source=/export,addr=…,nfsvers=3` and Compose `06-nfs` read `nfs-parity-ok`. Runtime rewrites `addr=` → `server:/export` + `nolock`. Matrix: `done`. |
| Matrix stamps | `docs/parity-matrix.md` compose + NFS rows → `done` |
| Docs / skills | `docs/volumes.md`, `skills/container/references/docker-migration.md`, `skills/container/SKILL.md` |

## Bounds (not “drop-in Compose” forever)

- Swarm `deploy` multi-node: `wontfix`
- Hostname guest UTS: interim via Name / labels; network `alias=` for dotted names
- Guest kernel must register NFS (`nfs` in `/proc/filesystems`); use Containerization NFS-enabled kernel (not stock Kata debug)
- Corpus `06-nfs` auto-starts `nfs-guest-server.sh` when `COMPOSE_NFS_*` unset; or point at any reachable export
- In-guest `nfsd` needs `--cap-add SYS_ADMIN` to mount `/proc/fs/nfsd`

## Non-goals unchanged

Podman pods/Quadlet, arbitrary volume plugins beyond local + NFS.
