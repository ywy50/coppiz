# Bug - an ordinary failover leaves `becomeLoser` truncating a committed suffix

## TL;DR

- **What failed:** `branch_start` and `common_tail` were set by every new
  epoch and never cleared, and `becomeLoser`'s only guard was
  `common_tail == null`. A member whose sole history was an ordinary failover
  therefore truncated its chain back to the slot before that failover the
  first time it lost a later divergence.
- **Impact:** committed, cluster-wide slots dropped from a member's store,
  followed by a re-sync of them from the survivor. Where the survivor has
  compacted that range (`ttl.retain = none`), it cannot serve them back.
- **Resolution:** fixed. `becomeLoser` takes the divergence's epoch and acts
  only when its own branch opened at or after it; both facts are cleared when
  a merge ends.

## Status

Resolved. Found by reading `src/cluster/node.zig`; no investigation record.

## Symptom and impact

`branch_start` is "the first slot of my current branch", `common_tail` "the
last slot before it". Three sites write them, all on folding a *new* epoch:
`appendEpoch` (this member elected), `slotAndBroadcast` (an epoch entry it
slotted), and `onSlot` (a peer's live epoch record). Nothing read
`branch_start` at all, and nothing ever wrote either of them back to null.

An epoch is not a branch. An ordinary failover, which every member folds and
agrees on, sets exactly the same facts a partition would. So after one
failover every member in the cluster carries a `common_tail` pointing at the
slot before it, indefinitely.

`becomeLoser` then reads that value as if it described a branch:

```zig
if (self.common_tail == null) return; // no branch: just behind
...
try self.node.store.truncate(self.node.control.journal_id, self.common_tail.?);
```

A member that later loses a divergence it has no branch in - it never elected,
it is simply behind the side that did - truncates its control journal to that
stale tail, re-folds, and re-syncs. `onMergeAck` does the same to every data
journal. Both discard slots the whole cluster committed.

## Reproduction

Reliable, as a unit test in `src/cluster/node.zig`:
`an ordinary failover is not a branch: becomeLoser truncates nothing`. It
builds a solo founder, performs one ordinary failover to epoch 2, and hands
`becomeLoser` a peer branch epoch of 3 - an epoch this member never reached.

Expected: nothing happens. Actual, before the fix: the control head dropped
out of epoch 2 back into epoch 1 and `syncing` was set. The test's
`expectEqual(head_before, cn.node.control.head.?)` failed with
`expected 2, found 1` on the head's `epoch` field. Verified by neutralising
the new guard on the fixed tree and re-running.

## Root cause

Two facts about the same state, both true before this change:

1. The branch facts are set by an epoch, not by a divergence, so they exist
   on members that have no branch.
2. Nothing clears them, so they outlive whatever they described.

`becomeLoser` had no third fact to check against, because the divergence's own
epoch was never passed down from `onDivergence`/`onMergeOffer`.

## Resolution

`becomeLoser(conn_id, peer_branch_epoch)`. Both callers already hold that
number: `onDivergence` takes it as an argument, and `onMergeOffer` reads
`offer.branch_head.epoch`. The guard is
`branch_start.epoch >= peer_branch_epoch`.

That relation holds for both shapes a partition takes, which is why it is the
test rather than equality:

- *Symmetric* - both sides elect. Each opens the same next epoch number off
  the same prefix, so the two are equal.
- *Asymmetric* - only the loser elects; the survivor keeps leading the epoch
  both sides shared, so its records carry the lower epoch. This is the shape
  `e2e (b)` exercises, and an equality test breaks it: the merge never
  converges.

A `branch_start` *below* the peer's branch epoch means the peer elected an
epoch this member never reached. That is being behind, not being branched,
and the heartbeat gap catch-up in `onHeartbeat` is what recovers it.

Both facts are also cleared where a merge ends and the branch stops existing:
in `onMergeAck` once control and data are back at the common prefix, and in
`mergeNextData` once the survivor has re-slotted the last branch.

## Verification

- The new unit test fails as quoted above with the guard removed and passes
  with it.
- It also asserts the positive direction: a peer branch epoch of 1 against
  this member's epoch-2 branch (the asymmetric shape) does truncate, sets
  `syncing`, and records `merging_to`.
- `e2e (b): partition a 2-member seniority cluster, write on both sides,
  heal, merge` passes. It is the regression guard for the merge itself, and
  it is what caught the too-strict first version of this guard.
- `zig build test`: green.

## Follow-up

One shape is still not handled correctly, and was not before this change
either: a side that fails over *twice* during one partition. Its
`branch_start` moves to the second election and its `common_tail` to a slot
inside its own branch, so `becomeLoser` truncates too little rather than too
much. The guard admits it (`>=` holds), leaving the pre-existing behaviour
untouched. Recording it rather than widening this change; it needs the
branch's opening epoch to be sticky for the life of the branch, which is a
different fix.

## References

- Investigation: none
- Code: `src/cluster/node.zig` (`becomeLoser`, `onDivergence`,
  `onMergeOffer`, `onMergeAck`, `mergeNextData`, `appendEpoch`,
  `slotAndBroadcast`, `onSlot`)
- Related: [2026-08-29 - `onMergeAck` truncates every data journal for any peer that asks](2026-08-29-merge-ack-unauthenticated.md)
- Fix: this commit
