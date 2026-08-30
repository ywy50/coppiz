# Bug - the merge settle rule bricks the reopen for a pre-merge checkpoint

## TL;DR

- **What failed:** `applyCheckpoint`'s settle guard refuses a checkpoint
  whose slot timestamp is within `merge.settle_ms` of the merge's. A
  checkpoint slotted *before* the merge has a timestamp before the merge's,
  so the inequality holds forever - any fold holding the merge refuses the
  checkpoint permanently.
- **Impact:** the merged survivor cannot reopen: `Node.open` folds the
  control chain first (the merge sets `last_merge`), then each data journal
  - a journal holding a pre-merge checkpoint is refused with
  `MergeSettling` and the open fails. Backfilling/joining members hit the
  same refusal on the data page and loop forever. Availability brick on
  restart.
- **Resolution:** Resolved - the settle window now applies only to
  checkpoints whose slot postdates the merge; a pre-merge checkpoint folds
  (its expire_through cannot reach the re-slotted losing-branch entries).

## Status

Resolved.

## Symptom and impact

`applyCheckpoint` (chain.zig):

```zig
if (cluster.last_merge) |merge| {
    const settle = ...merge.settle_ms...;
    if (sl.slot_ts_ms < merge.slot_ts_ms +| settle) return error.MergeSettling;
}
```

The rule compares the checkpoint's *own slot timestamp* against the merge's.
A checkpoint slotted before the merge has `T1 < T2 = merge.slot_ts`, so
`T1 < T2 + settle` always holds. Live, the checkpoint broadcasts and folds
while `last_merge == null`, so the leader accepts it. Re-folds fold in the
opposite order: the control chain first (setting `last_merge`), then each
data journal - a pre-merge checkpoint is refused forever.

## Reproduction

A cluster with TTL cleanup enabled (so checkpoints emit) that merges within
`merge.settle_ms` of a checkpoint on some journal; restart the survivor -
`Node.open` fails. Not committed as a test because the fix is the test.

## Root cause

The settle rule's timestamp comparison has no "this checkpoint predates the
merge" branch: anything before `merge.ts + settle` is refused, including
everything before the merge itself.

## Resolution

Fixed: the guard now returns early for a checkpoint whose slot predates the
merge (`sl.slot_ts_ms < merge.slot_ts_ms`) - it was authored before the
heal, so its `expire_through` cannot reach the re-slotted losing-branch
entries the window protects. Within a chain, position order equals
timestamp order (slots are timestamp-monotone), so the discriminator is
sound and cross-chain comparisons are avoided.

## Verification

- The settle tests now cover both shapes: a pre-merge checkpoint folds; a
  post-merge checkpoint inside the window is refused; a late one is
  accepted (journal/chain.zig and cluster/epoch.zig).
- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: src/journal/chain.zig (`applyCheckpoint`)
- Fix: this report's resolving commit
