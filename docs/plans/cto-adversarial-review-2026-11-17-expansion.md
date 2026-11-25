# CTO adversarial review: full parity expansion (2026-11-17)

_Date: 2026-11-17_  
_Plan: [2026-11-17-full-parity-expansion.plan.md](2026-11-17-full-parity-expansion.plan.md)_  
_Contract: [parity-matrix.md](../parity-matrix.md)_

## Scope under review

Implement the full parity expansion plan: drop-in CLI aliases, Engine bridge create/exec + optional sock, unified prune (already done), network connect/disconnect, rename (Name≠Id), pause/unpause, diff, update, events, history — with nitpick showing no errors and no severe warnings, gated behind a CTO GO.

## Adversarial checks

1. Matrix honesty: every expansion-track row is `done` or `done (interim)` with notes that match code; no `planned` rows left on the expansion checklist.
2. No false “drop-in Docker” / “full Engine API” claims for interim surfaces.
3. Pause is VM suspend/resume; stop from paused forces cleanup if resume fails.
4. Diff is EXT4 inventory vs image snapshot (A/C/D).
5. Bridge create/exec are practical subsets; events stream closes chunked body on poll failure; exec start is claimed atomically.
6. Nitpick `review -fail-on warning` on the working tree must EXIT 0 with no warning+ findings.

## Result

**GO (working tree).** `nitpick review -repo . -fail-on warning -dry-run -full` — EXIT 0, **no findings** (`/tmp/nitpick-review7.log`, 2026-11-17). Matrix expansion checklist rows are `done` / `done (interim)`. Decision + dossier updated: [cto-parity-decision-2026-11-15.md](cto-parity-decision-2026-11-15.md), [cto-parity-approval.md](cto-parity-approval.md). Release-train SHA GO still requires commit.
