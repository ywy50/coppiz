# Bug — The now-live merge settle rule kills the leader's checkpoint cadence: `MergeSettling` is fatal to the loop after every heal

## TL;DR

- **What failed:** The sweep-1 fix made the settle rule live (`applyCheckpoint` now reads `cluster.last_merge`). The leader's checkpoint cadence is its only automatic caller, and it treats the refusal as fatal: `checkpointForBroadcast` → `driveCheckpoints` → `onTick` → `catch self.fatal()` — the serving loop stops.
- **Impact:** Right after a healed merge, the leader crash-loops (or exits) whenever a checkpoint is due with a non-empty removal set within `merge.settle_ms` — the worst possible moment.
- **Resolution:** Still open. Statically validated (fix regression).

## Status

Open. The rule itself is correct ([PRD 0002](docs/prds/0002-ttl-and-staleness.md), OQ 60); its only automatic caller treats its refusal as fatal.

## Symptom and impact

Pre-fix the rule was dead (`self.last_merge` was never set on a data fold), so the cadence could never see `MergeSettling`. The fix (`chain.zig:703-706`) activated a refusal path whose only caller is fatal. After any merge, for a data journal with `ttl.enforce`/`stale.enforce` enabled and entries that expired during the partition (non-empty removal set), the next checkpoint attempt refuses, `onTick` errors, and the loop calls `self.fatal()` — `coppiz serve` exits. On restart the fold re-folds the merge entry, so the same state re-triggers it: a crash-loop until the `settle_ms` window (default 30 s) passes.

## Reproduction

Not dynamically reproduced (needs a merge + an expirable journal); statically complete:

1. `checkpointForBroadcast` (`journal.zig:353-396`): computes the removal set; non-empty → `try fold.applyData(&self.control, &sl, &en)` (`:391`) → `applyCheckpoint` → `error.MergeSettling` when `sl.slot_ts_ms < merge.slot_ts_ms +| settle` (`chain.zig:703-706`).
2. `driveCheckpoints` calls it with `try` (`node.zig:1055`).
3. `onTick` calls `driveCheckpoints` with `try` (`node.zig:895`).
4. The loop: `.tick => self.onTick() catch self.fatal()` (`node.zig:608`).

The empty-set guard (`journal.zig:386-389`) means the refusal only fires when there *is* something to remove — exactly the post-partition state the settle rule exists to protect.

## Root cause

The cadence and the settle rule were designed against each other but never connected: `driveCheckpoints` has no `MergeSettling` handling (it should defer the checkpoint, not die), and the rule's refusal is indistinguishable from a fold corruption to the caller.

## Resolution

Not yet fixed. Suggested direction: in `driveCheckpoints`, treat `error.MergeSettling` as "skip this journal this tick" (the settle window will pass), rather than propagating to `fatal`. A regression test should merge, enable enforcement, and tick the leader past a checkpoint-due state within `settle_ms` without the loop dying.

## Verification

- Static: the full error path verified hop by hop (`journal.zig:391` → `node.zig:1055` → `:895` → `:608`); the empty-set guard confirms the trigger is a real removal set.

## Follow-up

Related merge-path defects reported separately (data re-slot refusals, unclamped re-slot timestamps).

## References

- Code: `src/journal/journal.zig:353-396` (`checkpointForBroadcast`), `src/journal/chain.zig:703-706` (settle rule), `src/cluster/node.zig:1013+` (`driveCheckpoints`), `:895` (`onTick`), `:608` (fatal)
- Fix: none
