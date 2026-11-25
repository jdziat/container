# CTO decision: remaining parity backlog (2026-11-18)

_Plan: [2026-11-18-remaining-parity-backlog.plan.md](2026-11-18-remaining-parity-backlog.plan.md)_  
_Contract: [parity-matrix.md](../parity-matrix.md), [compose-support-matrix.md](../compose-support-matrix.md)_

## Decision

**Working-tree CTO GO** for the implementable scope of the 2026-11-18 remaining-parity backlog (P0 validate, P1 compose leftovers, P3 bridge/CLI expansions, P4 NFS productize messaging).

Evidence: compose corpus 01–07 green; T0 green; `--hostname` smoke (`myuts`); nitpick critical cleared and Id/Name lookup hardened; residual warnings/errors are expert-withheld, pre-existing interim networking (N1/N2), or intentional sequential compose topo.

**NO-GO** remains for claiming unqualified drop-in Docker, full Engine API, complete network DNS (#1809), or live NIC hotplug.

## Packet results

| ID | Result | Evidence |
|----|--------|----------|
| V1 | pass | `scripts/parity/t3-compose-corpus.sh` — fixtures 01–07 OK including auto `nfs-guest-server.sh` |
| V2 | pass / optional | T0 core loop run after kernel/runtime swap |
| V3 / K1–K3 | pass (docs) | `docs/volumes.md` NFS kernel install story; ENODEV annotate in `RuntimeService`; guest nfsd in CI docs |
| V4 | pass (iterated) | Nitpick iterated; critical cleared; remaining findings are residual/pre-existing or expert-withheld. Logs: `/tmp/nitpick-remaining-parity.log`, `/tmp/nitpick-remaining-parity2.log` |
| C1 | pass | `compose pull` / `compose images` |
| C2 | pass / wontfix | `cap_add`/`cap_drop` done; `devices` honest `wontfix` (per-VM) |
| C3 / E2 | pass | `--hostname` UTS (separate from network Name); smoke `hostname` → `myuts` |
| C4 | pass | `stop_grace_period` → `--stop-timeout` + `down -t` |
| C5 | pass | Corpus `07-completed`; foreground run for completed deps |
| E1 | pass (interim+) | Bridge curated GET/POST/DELETE networks + volumes; build still 501 |
| N1 | residual | Bare-name hosts injection remains `done (interim)` pending #1809 |
| N2 | residual | `network connect` remains `done (interim)` pending VZ/Containerization NIC hot-add |
| E3 | out of scope | In-core `/var/run/docker.sock` unchanged |

## Honesty residuals (named)

1. **#1809 full DNS** — hosts injection only; do not claim Docker-like DNS.
2. **Live network hotplug** — connect/disconnect still need `--restart` while running.
3. **Engine build route** — still 501; networks/volumes curated subset only.
4. **Official NFS kernel packaging** — install path documented; release artifact still operator-built from Containerization `kernel/`.
5. **`domainname`** — `done` (`--domainname` → resolv.conf domain/search + FQDN hosts).

## Promotion language

Allowed: “remaining-parity backlog implementable packets are ready at their matrix statuses.”  
Forbidden: “drop-in Docker,” “full Engine,” “complete network DNS,” or promoting interim rows to unqualified `done`.
