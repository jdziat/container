# PRD: Reopen supported surfaces (hotplug / devices / Immich / Pack C / sock / GUI)

_Date: 2026-11-21_  
_Status: shipped_  
_Parent:_ [beyond-terminus-goals](2026-11-21-beyond-terminus-goals.prd.md)  
_Reopens:_ terminus parked items + F5 default-off + Pack C growth + first-party GUI

## Claim sentence (allowed)

> Ship **supported** (harnessed) VZ live NIC hotplug, unrestricted host `devices`, Immich compose corpus green, Pack C expansions, default in-core `/var/run/docker.sock`, and a first-party management GUI — without claiming full Docker Desktop, full Engine OpenAPI, or Swarm-as-supported.

## Forbidden claims

- “Full Docker Desktop,” unqualified “full Engine OpenAPI,” Swarm as supported
- Bit-identical Moby hijack / Apple VF bit-identical

## Work packets

| ID | Work | Acceptance |
|----|------|------------|
| **R1** | VZ live NIC hotplug | Running `network connect` / `disconnect` on VZ backend swaps `VZNetworkDevice.attachment` (spare slots at create); no stop+start on happy path; harness `make f4-vz-net-hotplug` |
| **R2** | Unrestricted host devices | Lift F3 allowlist (opt-out `CONTAINER_DEVICE_ALLOWLIST_ONLY=1`); map host char/block nodes into guest via virtiofs + guest `mknod` from host `rdev`; USB devices via VZ USB when path is a USB device; compose/`run --device` any absolute char/block path; harness `make f3-devices-unrestricted` |
| **R3** | In-core docker.sock **default on** | `enginePrivilegedSock` default `true`; `CONTAINER_INCORE_DOCKER_SOCK=0` opts out; Recipe A Application Support sock remains available; update `f5-incore-sock.sh` + catalog |
| **R4** | Immich `10` green | `COMPOSE_FIXTURES` includes `10-immich` (or `COMPOSE_ENABLE_IMMICH=1` default-on); health/running gate; pass-matrix row |
| **R5** | Pack C expansions | C1 corpus stays green; C2 `t2-client-smoke` shipped + Makefile; pack plan status → shipped; terminus claim |
| **R6** | First-party GUI | macOS app (`ContainerGUI` / `container-gui`) listing containers, start/stop, logs pane, and optional VM framebuffer via `CRVirtualMachineView` when CR+GPU; smoke launch harness |

## Sequence

1. R3 (sock default) — small, unlocks TC/IDE discovery  
2. R2 (devices) — API + guest mapping  
3. R1 (VZ hotplug) — Vendor containerization spare NICs + RuntimeService VZ path  
4. R5 (Pack C2) — harness already sketched  
5. R4 (Immich) — density / volume / health burn-down  
6. R6 (GUI) — AppKit/SwiftUI shell on ContainerClient  

## Exit gate

All six packets have harness evidence + terminus/beyond-terminus rows flipped from parked/interim to **supported**; forbidden-language grep clean.
