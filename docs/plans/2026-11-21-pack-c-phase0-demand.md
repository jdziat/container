# Pack C1 — Phase 0 demand log

_Date: 2026-11-21_  
_Status:_ Phase 0 recorded; **no new bridge routes in this change** beyond what `t2-bridge-corpus.sh` already asserts.

## Demand entries

| Client / corpus | Blocking route (today) | Notes |
|-----------------|------------------------|-------|
| Internal bridge corpus (`t2-bridge-corpus.sh`) | Already covered: `GET …/stats` (one-shot), `POST …/rename`, `GET …/top` | Harness also asserts ≥1 outside route still **501** |
| (open) | — | Add a named external client failure before widening the matrix further |

## Gate

Per [2026-11-21-pack-c-expansions.plan.md](2026-11-21-pack-c-expansions.plan.md) and CTO stamp: do not ship additional Engine routes without a new demand row + matrix diff + harness update in the same change.

## L6 claim (this wave)

Corpus harness exists (`make bridge-corpus-parity`). Status remains **defined / corpus-ready**, not an OpenAPI fill.
