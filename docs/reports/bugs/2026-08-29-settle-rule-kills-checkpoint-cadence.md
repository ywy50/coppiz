# Bug - The now-live merge settle rule kills the leader's checkpoint cadence: `MergeSettling` is fatal to the loop after every heal

## TL;DR

- **What failed:** The sweep-1 fix made the settle rule live (`applyCheckpoint` now reads `cluster.last_merge`). The leader's checkpoint cadence is its only automatic caller, and it treats the refusal as fatal: `checkpointForBroadcast` → `driveCheckpoints` → `onTick` → `catch self.fatal()` - the serving loop stops.
- **Impact:** Right after a healed merge, the leader crash-loops (or exits) whenever a checkpoint is due with a non-empty removal set within `merge.settle_ms` - the worst possible moment.
- **Resolution:** Fixed. `driveCheckpoints` continues on `MergeSettling` and
  keeps the journal due so the next tick retries.

## Status

Resolved - `driveCheckpoints` continues on `error.MergeSettling` and keeps
the journal due so the next tick retries; a regression test in `node.zig`
drives a leader through a settle window without the loop dying.

## Symptom and impact

Pre-fix the rule was dead (`self.last_merge` was never set on a data fold), so the cadence could never see `MergeSettling`. The fix (`chain.zig:703-706`) activated a refusal path whose only caller is fatal. After any merge, for a data journal with `ttl.enforce`/`stale.enforce` enabled and entries that expired during the partition (non-empty removal set), the next checkpoint attempt refuses, `onTick` errors, and the loop calls `self.fatal()` - `coppiz serve` exits. On restart the fold re-folds the merge entry, so the same state re-triggers it: a crash-loop until the `settle_ms` window (default 30 s) passes.

## Reproduction

Not dynamically reproduced (needs a merge + an expirable journal); statically complete:

1. `checkpointForBroadcast` (`journal.zig:353-396`): computes the removal set; non-empty → `try fold.applyData(&self.control, &sl, &en)` (`:391`) → `applyCheckpoint` → `error.MergeSettling` when `sl.slot_ts_ms < merge.slot_ts_ms +| settle` (`chain.zig:703-706`).
2. `driveCheckpoints` calls it with `try` (`node.zig:1055`).
3. `onTick` calls `driveCheckpoints` with `try` (`node.zig:895`).
4. The loop: `.tick => self.onTick() catch self.fatal()` (`node.zig:608`).

The empty-set guard (`journal.zig:386-389`) means the refusal only fires when there *is* something to remove - exactly the post-partition state the settle rule exists to protect.

## Root cause

The cadence and the settle rule were designed against each other but never connected: `driveCheckpoints` has no `MergeSettling` handling (it should defer the checkpoint, not die), and the rule's refusal is indistinguishable from a fold corruption to the caller.

## Resolution

Fixed. `driveCheckpoints` catches `error.MergeSettling` from
`checkpointForBroadcast`, puts `next_checkpoint_ms` to now so the journal
stays due (the pending-bytes path has already recorded `last_scan_head`),
and continues to the next journal. Other errors still propagate to
`onTick` → `fatal()`. The settle rule itself is unchanged.

## Verification

- Static: the full error path verified hop by hop (`journal.zig:391` → `node.zig:1055` → `:895` → `:608`); the empty-set guard confirms the trigger is a real removal set.
- Dynamic: `driveCheckpoints skips MergeSettling instead of stopping the loop` in `src/cluster/node.zig` folds a real merge, enables TTL, makes a checkpoint due inside `settle_ms` (time-due and pending-bytes), asserts the call returns and no checkpoint lands, then advances past `settle_ms` and asserts the checkpoint emits.

## Follow-up

Related merge-path defects reported separately (data re-slot refusals, unclamped re-slot timestamps).

## References

- Code: `src/journal/journal.zig:353-396` (`checkpointForBroadcast`), `src/journal/chain.zig:703-706` (settle rule), `src/cluster/node.zig:1013+` (`driveCheckpoints`), `:895` (`onTick`), `:608` (fatal)
- Fix: `src/cluster/node.zig` (`driveCheckpoints`). Regression test in the
  same file.
