# Bug - Control/checkpoint writes fold before the store write: an I/O error leaves the fold one record ahead and the chain unreopenable

## TL;DR

- **What failed:** `checkpointForBroadcast` (and the control-append paths) apply the entry to the in-memory fold *before* `store.append`; the tier-0 data path does the opposite. If the store write fails (ENOSPC/EIO), the fold is permanently one record ahead of the store - the next write chains from a phantom head, and reopen fails `BadPrevHash`.
- **Impact:** A transient I/O error during a checkpoint (or control append) silently poisons the chain; on the cluster path `onSlot` swallows the error, so the member keeps serving a fold the store cannot reproduce.
- **Resolution:** **Reopened 2026-08-31.** The record claimed a fix via a `storeThenFold` helper that does not exist in the tree and never has; the ordering is unchanged. Statically validated, both then and on reopening.

## Status

**Reopened 2026-08-31.** The record was marked `Resolved` while its own
TL;DR still read "Still open", and the fix it described cannot be found. See
*Reopened - what was checked* below for the evidence. Treat the defect as
live.

## Symptom and impact

The two orderings:

- Tier-0 data append (`journal.zig:257-267`): queue → `slotFor` → **`store.append` → `fold.applyData`** (store first).
- `checkpointForBroadcast` (`journal.zig:391-392`): **`fold.applyData` → `store.append`** (fold first).

If the second ordering's `store.append` fails, the fold has advanced but the store has not. The next record is slotted from the fold head (one past the phantom), so the store physically holds records N-1, N+1 with N missing. On reopen, `foldJournal` hits N+1's `prev_slot_hash` against N-1's head hash → `BadPrevHash` → the node refuses to open (manual truncate needed). On the cluster path this is worse: `onSlot`'s error switch (`node.zig:1821-1824`) treats everything but `BadPrevHash` as "the chain's rules decide", so a follower whose store write failed keeps the fold-ahead-of-store state and later serves the gapped chain in sync pages.

## Reproduction

Not dynamically reproduced (needs an injected store I/O failure); statically certain. The ordering asymmetry is unambiguous, and the reopen failure follows from the same `checkChainContinuity` rule the rest of the fold relies on.

## Root cause

The fold-then-store ordering on the control/checkpoint paths inverts the tier-0 store-then-fold discipline, and `onSlot`'s error handling does not distinguish a refused entry (fold untouched) from a write failure (fold advanced, store not).

## Reopened - what was checked

Checked at `e45bba2` (2026-08-31), by reading and by search:

- `grep -rn storeThenFold src/ docs/` matches **only this report's own
  Resolution paragraph**. No such function exists anywhere under `src/`, and
  `git log --all -S storeThenFold -- src/` returns no commit, so it was never
  added and later removed either.
- `appendControl` (`src/journal/journal.zig`) still folds first: it runs
  `applyControl` / `applyData` (and, for a `checkpoint`,
  `compactAfterCheckpoint`) and only then reaches
  `store.appendRecord` / `store.append`. The ordering the report describes as
  fixed is the ordering the tree has.
- No rollback of the store to a previous head exists on that path, and no
  test named for a refused-settings reopen was found.

So the *Resolution* below describes work that was not done. It is kept
verbatim rather than deleted, because the record's value now includes knowing
that it was wrong: a `Resolved` row in the inventory hides live work exactly
as effectively as a missing row would.

What is *not* claimed here: why the record says otherwise. It may have
described an intended change, or a change that was reverted; no attempt was
made to reconstruct that, and the reader should not infer one.

## Resolution (as originally recorded - not implemented)

Fixed: self-authored writes (`appendControl`, `checkpointForBroadcast`) are store-then-fold via `storeThenFold`, with a store rollback to the previous head when the fold refuses; regression test covers the refused-settings reopen.

## Verification

- Static, original: both orderings read and compared; `onSlot`'s error switch
  read.
- Static, 2026-08-31: the search and the re-read above. Nothing dynamic; the
  defect needs a failing `store.append` (ENOSPC/EIO) to observe, which no
  fixture in the tree can produce yet - the smallest next step for whoever
  takes this is a `std.Io` seam or a full disk, not another reading.

## Follow-up

Related storage-path crash-window: an interrupted `compact` (reported separately).

## References

- Code: `src/journal/journal.zig:257-267` (tier-0 order), `:391-392` (`checkpointForBroadcast`), `src/cluster/node.zig:1821-1824` (`onSlot` error switch)
- Fix: none
