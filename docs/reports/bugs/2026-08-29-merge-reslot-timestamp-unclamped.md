# Bug - Merge re-slots do not clamp the slot timestamp: a clock regression stalls the heal with `BadTimestamp`

## TL;DR

- **What failed:** The merge re-slot stamps `slot_ts_ms = self.nowMs()` unclamped, while the normal slot path clamps to the fold's `last_slot_ts_ms`. A leader clock that regressed between the last write and the heal produces a re-slotted record older than the fold's head, refused by `checkChainContinuity`.
- **Impact:** The heal stalls permanently under a backwards clock - the exact condition the clamp exists for.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

`reslot` (`node.zig:2397-2409`) writes `slot_ts_ms = self.nowMs()`; `slotFor` (the live path) clamps (`journal.zig:479`: `@max(now_ms, fold.last_slot_ts_ms)`). If the heal happens after a clock regression, the first re-slotted record's timestamp is below the fold's `last_slot_ts_ms`, and `checkChainContinuity` refuses `BadTimestamp` (`chain.zig:427-429`) - `doMergeData` errors, the merge aborts, and every retry (with the same regression) fails identically.

## Reproduction

Not dynamically reproduced; statically certain. The asymmetry between `reslot` and `slotFor` is unambiguous; the refusal follows from the standard continuity rule.

## Root cause

The re-slot path was written without the clamp the live path has. The clamp's purpose (the fold's timestamps must be monotone) applies equally to re-slots.

## Resolution

Not yet fixed. Suggested fix: clamp in `reslot` (`slot_ts_ms = @max(self.nowMs(), prev fold.last_slot_ts_ms)` - the caller has `fold` in scope). A regression test should heal with a regressed clock and expect the merge to complete.

## Verification

- Static: `reslot` (`node.zig:2397-2409`) vs `slotFor` clamp (`journal.zig:479`) read and compared.

## Follow-up

None. Low priority (narrow trigger).

## References

- Code: `src/cluster/node.zig:2397-2409` (`reslot`), `src/journal/journal.zig:479` (live clamp), `src/journal/chain.zig:427-429` (`BadTimestamp`)
- Fix: none
