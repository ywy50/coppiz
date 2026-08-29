# Bug - The checkpoint merge-settle rule reads the data fold's `last_merge`, which is never set: `MergeSettling` can never fire

## TL;DR

- **What failed:** `applyCheckpoint` gates checkpoints on `self.last_merge`, but `last_merge` is only ever set on the *control* fold (by `applyMerge`). Data folds never see a merge entry, so their `last_merge` is always `null` and the settle rule is dead code.
- **Impact:** The [PRD 0002](../../prds/0002-ttl-and-staleness.md) / [OQ 60](../../open-questions.md#oq-60) protection - "a checkpoint must not delete the other side's fresh writes on a clock it did not stamp" - never runs: after a healed merge, the survivor can immediately checkpoint and remove the loser's re-slotted, stale-marked entries without the `merge.settle_ms` window.
- **Resolution:** Still open. Statically validated (complete setter enumeration).

## Status

Resolved - `applyCheckpoint` reads `cluster.last_merge` (the control
fold); the epoch test now folds a real merge entry instead of
hand-assigning the field.

## Symptom and impact

`error.MergeSettling` is referenced in the checkpoint path but unreachable in production. The only reason any test passes is that the epoch test hand-assigns the field (`epoch.zig:628`), which no fold path does. A leader's `driveCheckpoints` right after a merge can emit a checkpoint naming a re-slotted entry within `merge.settle_ms` (default 30 s) and the fold accepts it, deleting the other side's fresh writes.

## Reproduction

Not dynamically reproduced (needs a full heal + checkpoint sequence); statically airtight. Trace:

1. `applyMerge` (`epoch.zig:186-195`) is reachable only through `applyControl`'s `.merge` case (`chain.zig:339`) - i.e. only on the **control** fold. It sets `fold.last_merge` on that fold.
2. `applyCheckpoint` (`chain.zig:642-662`) runs on a **data** journal fold (`applyData`'s `.checkpoint` case, `chain.zig:418`). It reads `self.last_merge` - the data fold's field - which no code ever sets.
3. `applyData` refuses `.merge` as `WrongJournalType` (`chain.zig:420`), so a data fold can never acquire a `last_merge`.

Grep confirms `last_merge` has exactly one assignment in the tree (`epoch.zig:194`). The rule's own comment says the value should come from the cluster's fold ("`merge.settle_ms` is cluster-scoped, so the value comes from the cluster's fold") - the fold is passed in as `cluster`, which *does* carry `last_merge`; the code just reads the wrong one.

## Root cause

`chain.zig:659` reads `self.last_merge` (data fold, always `null`) instead of `cluster.last_merge` (the control fold that owns the merge facts). Single-line wiring error; the settle check itself, `sl.slot_ts_ms < merge.slot_ts_ms +| settle`, is sound.

## Resolution

Fixed as suggested: `applyCheckpoint` reads `cluster.last_merge` (the
control fold, which owns the merge facts) instead of `self.last_merge`
(a data fold, always `null`). The settle check itself was sound.

The epoch test at `epoch.zig:628` that hand-assigned the data fold's
field was rewritten to fold a real `merge` entry on the control chain
(`applyMerge` sets `cluster.last_merge`), then a data checkpoint within
`settle_ms` - `error.MergeSettling` fires through the real wiring.
A second, independent regression test lives in `chain.zig` ("a
checkpoint inside merge.settle_ms of a real merge entry is refused").

## Verification

- Static: single assignment site for `last_merge` (`epoch.zig:194`) reached only via the control fold's `.merge` case; `applyData` refuses `.merge`; `applyCheckpoint` reads `self.last_merge`. All verified by reading the code.
- The test at `epoch.zig:628` hand-assigns the field, confirming the rule only fires when the wiring is faked.

## Follow-up

None - contained fix. Note the same heal path also carries the reslotted `create_journal` refusal (reported separately); both stall or weaken the merge feature.

## References

- Code: `src/journal/chain.zig:642-662` (`applyCheckpoint`), `:659` (wrong fold), `src/cluster/epoch.zig:186-195` (`applyMerge`), `:628` (test hand-assignment)
- Fix: `src/journal/chain.zig` (`applyCheckpoint`), `src/cluster/epoch.zig` (test rewritten), `src/journal/chain.zig` (new test). `zig build test` green.
