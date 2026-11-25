# CTO adversarial review: scoped Docker/Podman parity (working tree)

_Date: 2026-11-17_  
_Contract: [parity-matrix.md](../parity-matrix.md)_  
_Decision: [cto-parity-decision-2026-11-15.md](cto-parity-decision-2026-11-15.md)_  
_Dossier: [cto-parity-approval.md](cto-parity-approval.md)_

## Attack surface

Tried to break the claim that **scoped workflow parity** holds for packets P0–P7 on this working tree:

1. Any matrix **data** row still `planned` / `in-progress` / `blocked`
2. False `done` claims vs code
3. Drop-in Docker / full Engine API / privileged DNS language
4. Fail-open compose or API bridge routes that should 501 / fail closed
5. Safety bugs in the uncommitted parity harden (attach, hosts merge, cleanup hook)

## Method

- Matrix audit: every data-row status is `done` / `done (interim)` / `alias` / `plugin` / `wontfix` (`rename` → `wontfix`)
- `nitpick review -full -fail-on warning` on the working tree — EXIT 0, **no findings** (`/tmp/nitpick-plain-final8.txt`)
- Adversarial nitpick with blocking-gap-only instruction — EXIT 0, **no findings** (`/tmp/nitpick-cto-final8.txt`)
- Compile/unit evidence on this tree: `swift build --product container`; `RuntimeCleanupHookTests` 6/6
- Prior local suite on the harden line: `make test` 1093; `make integration` 297+111 (2026-11-17)

## Verdict

**Working-tree validation PASS** for scoped workflow parity. No blocking gaps found.

Still **forbidden** to claim: drop-in Docker, full Engine API, complete network DNS. Bare-name discovery remains `done (interim)` pending #1809. Record a release-train SHA **GO** only after this harden is committed.
