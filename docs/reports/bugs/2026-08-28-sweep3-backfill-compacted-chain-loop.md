# Bug — Backfill over a chain containing compacted (`retain = none`) records never terminates

## TL;DR

- **What failed:** `onSyncReq` skips slot-only (compacted) records without advancing the page cursor. A requester whose window spans a compacted record parks its cursor at the gap and re-requests it forever (`BadPrevHash` on the first post-gap record, cursor never advanced); a fully-compacted window is declared done with a permanent gap.
- **Impact:** A joiner backfilling a journal with `retain = none` compaction never finishes (stuck `syncing`, never a member), or completes with a chain the next broadcast can never close.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

`onSyncReq` (`node.zig:1936-1951`): the callback does `const e = en orelse return;` **without advancing `ctx.next`** — unlike the read path, which advances `next` from the served position. Two consequences:

1. **Compacted record mid-window:** the page serves the records before and after it; `next` is the last *served* position + 1, so the requester's cursor parks at the compacted slot. The requester folds the served records, then the first post-gap record arrives (or is re-requested): its `prev_slot_hash` chains to the compacted slot's hash, not the requester's head → `BadPrevHash` → same-leader divergence no-op → the cursor never advances. Every tick re-requests the same window and re-fails — infinite retry, `syncing` never clears.
2. **Fully-compacted window:** the page is empty → the cursor is removed → the journal is declared done with a permanent gap; the next broadcast for that journal re-triggers `requestSync` with the same empty-page result forever.

The skip itself is documented (OQ 43, `:1939`); the *consequence* — the requester's cursor never advancing — is not handled anywhere. (The already-reported `2026-08-29-wire-read-drops-compacted-slots` covers the read path; this is the sync/backfill path.)

## Reproduction

Not dynamically reproduced (needs a joiner over a compacted chain); statically certain from the cursor arithmetic.

## Root cause

`onSyncReq` drops the record without advancing `next`, and `onSyncPage` has no "the gap is at a compacted slot" case — the requester cannot progress past a record the server will never serve.

## Resolution

Not yet fixed. Suggested direction: advance `next` past skipped slot-only records (and surface the gap once), or serve the slot-only record itself (the fold has `advanceHead` for exactly this, `journal.zig:671-679`). A regression test should backfill a journal with a `retain = none` compaction and assert the joiner reaches head.

## Verification

- Static: `onSyncReq` callback (`node.zig:1936-1951`) and `onSyncPage` cursor handling (`:1979-1996, :2027`) read; `advanceHead` read as the intended shape.

## Follow-up

Related sync-path defect: the oversized-entry loop (2026-08-28-sweep3-oversized-entry-unreplicable) — both leave backfill non-terminating.

## References

- Code: `src/cluster/node.zig:1936-1951` (`onSyncReq`), `:1979-1996, :2027` (`onSyncPage`), `src/journal/journal.zig:671-679` (`advanceHead`)
- Fix: none
