# Bug — Control/checkpoint writes fold before the store write: an I/O error leaves the fold one record ahead and the chain unreopenable

## TL;DR

- **What failed:** `checkpointForBroadcast` (and the control-append paths) apply the entry to the in-memory fold *before* `store.append`; the tier-0 data path does the opposite. If the store write fails (ENOSPC/EIO), the fold is permanently one record ahead of the store — the next write chains from a phantom head, and reopen fails `BadPrevHash`.
- **Impact:** A transient I/O error during a checkpoint (or control append) silently poisons the chain; on the cluster path `onSlot` swallows the error, so the member keeps serving a fold the store cannot reproduce.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

The two orderings:

- Tier-0 data append (`journal.zig:257-267`): queue → `slotFor` → **`store.append` → `fold.applyData`** (store first).
- `checkpointForBroadcast` (`journal.zig:391-392`): **`fold.applyData` → `store.append`** (fold first).

If the second ordering's `store.append` fails, the fold has advanced but the store has not. The next record is slotted from the fold head (one past the phantom), so the store physically holds records N-1, N+1 with N missing. On reopen, `foldJournal` hits N+1's `prev_slot_hash` against N-1's head hash → `BadPrevHash` → the node refuses to open (manual truncate needed). On the cluster path this is worse: `onSlot`'s error switch (`node.zig:1821-1824`) treats everything but `BadPrevHash` as "the chain's rules decide", so a follower whose store write failed keeps the fold-ahead-of-store state and later serves the gapped chain in sync pages.

## Reproduction

Not dynamically reproduced (needs an injected store I/O failure); statically certain. The ordering asymmetry is unambiguous, and the reopen failure follows from the same `checkChainContinuity` rule the rest of the fold relies on.

## Root cause

The fold-then-store ordering on the control/checkpoint paths inverts the tier-0 store-then-fold discipline, and `onSlot`'s error handling does not distinguish a refused entry (fold untouched) from a write failure (fold advanced, store not).

## Resolution

Not yet fixed. Suggested direction: make every write path store-then-fold (or make the fold-apply reversible on a store error), and treat store-write failures in `onSlot` as fatal rather than swallowed. A regression test should fail `store.append` and assert the fold is unchanged.

## Verification

- Static: both orderings read and compared; `onSlot`'s error switch read.

## Follow-up

Related storage-path crash-window: an interrupted `compact` (reported separately).

## References

- Code: `src/journal/journal.zig:257-267` (tier-0 order), `:391-392` (`checkpointForBroadcast`), `src/cluster/node.zig:1821-1824` (`onSlot` error switch)
- Fix: none
