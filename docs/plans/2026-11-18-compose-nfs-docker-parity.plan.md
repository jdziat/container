# Compose + NFS Docker parity (2026-11-18)

Docker Compose v2 / Compose Spec (single-engine, non-Swarm) and guest NFS matching Docker `--mount type=nfs`.

## Locked decisions

- Compose: Docker Compose v2 semantics; Podman-compatible when files are Docker-compatible.
- NFS: guest NFS client in each per-container VM (`Filesystem.FSType.nfs` → guest `mount -t nfs`).
- Honesty: matrix `done` only with harness evidence (`scripts/parity/t3-compose-corpus.sh`).

## Non-goals

- Swarm multi-node `deploy`
- Podman pods / Quadlet
- Arbitrary volume plugins beyond local + NFS

## Phases

0. Contract + corpus + harness
1. Compose language expansion
2. Guest NFS end-to-end
3. Compose UX (`ps`/`logs`/`exec`/`run`/`build`)
4. Corpus gate + matrix stamps
