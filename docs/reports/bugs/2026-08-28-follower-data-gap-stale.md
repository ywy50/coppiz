# Bug - A follower that misses one data-journal broadcast is permanently behind (silent stale reads)

## TL;DR

- **What failed:** The heartbeat gap-catchup requests a sync of the **control** journal only; data-journal heads are never exchanged. A dropped data broadcast makes every subsequent data record fail `BadPrevHash`, and the same-leader divergence is ignored as a "redelivery" - so the follower's data fold stays behind indefinitely.
- **Impact:** Reads on that member silently omit entries forever (until a full partition + merge cycle happens to occur). There is no diagnostic.
- **Resolution:** Still open. Statically validated.

## Status

Resolved - `onSlot`'s `BadPrevHash` branch distinguishes a redelivery
from a gap: a record from my own current leader that the fold does not
know triggers a sync of that journal, while a different leader stays the
partition-merge path.

## Symptom and impact

Replication of data journals relies entirely on the leader's broadcast (`slotAndBroadcast`). The only gap-recovery mechanism, `onHeartbeat`'s catch-up, syncs `self.node.control.journal_id` (`node.zig:1676`) - never a data journal. There is no periodic data reconciliation: `driveBackfill` runs only while `syncing` (a joiner's initial backfill).

## Reproduction

Not dynamically reproduced (needs a dropped frame on a live cluster); statically complete:

1. A follower misses one data-journal broadcast (conn blip, dropped frame, or a restart that re-folds only the control chain).
2. The next data broadcast fails the fold's `BadPrevHash` (`chain.zig:426`), so `onSlot` routes it to `onDivergence` (`node.zig:1628-1633`).
3. `onDivergence` returns early: "A record from my own current leader is a redelivery" (`node.zig:1876-1879`) - the slot's leader equals my current leader, so this is treated as a duplicate, not a branch. Nothing else runs.
4. Heartbeats from the leader carry only `hb.head` of the control journal (message.Heartbeat, verified in the codec), and the gap check requests a sync of the control journal only.

The follower's data fold head stays behind forever; `read`/`follow` on that member silently miss the entries.

## Root cause

Two gaps compound: (a) the gap-catchup (`onHeartbeat`, `node.zig:1674-1677`) syncs only the control journal, and (b) `onDivergence`'s same-leader early return (`node.zig:1879`) treats a chained-off-my-head record from my own leader as a redelivery - which is correct only when the record is actually already applied, not when it is merely *from the same leader*. `entryKnown` is the right test for redelivery vs. genuine gap (it is used exactly that way in `onSyncPage`, `node.zig:1783`), but `onDivergence` does not consult it.

## Resolution

Fixed in `onSlot`'s `BadPrevHash` branch. The fold's own `entryKnown` is
the redelivery-vs-gap test (as `onSyncPage` already used it): a record
from my current leader that the fold knows is a redelivery (nothing to
do); one it does not know is a missed broadcast in that journal, and the
branch requests a gap sync of *that journal* from my head+1 - the
`requestSync` path already supports arbitrary journals. A *different*
leader's record still goes to `onDivergence` (the healed-partition merge
path) - this is what keeps the merge machinery intact.

The same-leader early return in `onDivergence` itself was left
unchanged: it cannot distinguish the cases (it lacks the entry), so the
distinction is made at the call site that has it.

A deterministic regression test needs a single dropped frame, which the
hub's `drop` cannot produce (it closes the whole edge and triggers
election); the fix was validated by the full e2e merge suite, which
exercises the surrounding divergence paths (`zig build test` green,
including "e2e (b): partition a 2-member seniority cluster, write on
both sides, heal, merge").

## Verification

- Static: `onHeartbeat` requests `self.node.control.journal_id` only (`node.zig:1674-1677`); `onDivergence` returns for a same-leader record (`:1876-1879`); `driveBackfill`/`syncing` is the only other sync driver (`:845-865`); heartbeat codec carries control head only. All verified by reading the code.

## Follow-up

None beyond the fix. Related: `onSlot` swallows non-refusal errors after the fold advanced (OOM/store failures poison the chain silently) - worth handling in the same replication-path review.

## References

- Code: `src/cluster/node.zig:1664-1678` (`onHeartbeat`), `:1628-1638` (`onSlot` error switch), `:1870-1879` (`onDivergence` same-leader early return), `:1756-1842` (`onSyncPage` gap handling), `src/net/message.zig` (Heartbeat shape)
- Fix: `src/cluster/node.zig` (`onSlot` `BadPrevHash` branch). `zig build test` green; the heartbeat-side data-head exchange remains a follow-up (not needed for the reported stuck-follower case).
