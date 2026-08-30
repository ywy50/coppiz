# Bug - a three-member merge strands the losing branch's follower

## TL;DR

- **What failed:** after a three-member partition heals and merges, the
  losing side's *leader* converges on the survivor and the losing side's
  *follower* does not. It keeps its dead branch and goes on naming its old
  leader.
- **Impact:** a silently divergent member. It serves reads from a chain the
  cluster has discarded, and it is a member in every other member's fold.
- **Resolution:** Resolved - a member that folds a new epoch without
  authoring it (a follower) never recorded its branch facts, so
  `becomeLoser` refused to act. The folding paths now record them; the
  losing follower converges like the losing leader.

## Status

Resolved - the branch facts (`branch_start`/`common_tail`) are now recorded
whenever a member folds a new epoch, from any path. Reproduced 2026-08-30
by the new loop simulator; the root cause below was established by tracing
the deterministic scenario. This is the failure PRD 0003's *Status* has
carried as a known issue since 2026-08-27:

> a **three-member partition that elects a second leader does not reliably
> converge on heal** - the survivor's branch fetch or the losers' re-sync
> can stall without retry (the two-member merge, e2e (b), converges; three
> members - two losers - surfaced a stall).

It was found then from `examples/embed-cluster`, where it was timing
dependent. It is now deterministic.

## Symptom and impact

Three members, `seniority`, node 0 the founder and senior. Node 0 is cut off;
nodes 1 and 2 keep each other, so their side elects node 1 and node 2 folds
node 1's epoch. Both sides write. The links come back.

Two separate things then go wrong, and only the second is this report.

**Reconnecting alone converges nothing.** Ten ticks with the links restored
leave node 0 on its epoch-1 branch and nodes 1 and 2 on their epoch-2 one.
Heartbeats carry the peer's advertised head (`MemberState.head`), and nothing
compares it against this member's own, so no divergence is detected until a
record fails `prev_slot_hash`. This is *by construction* rather than a
defect - the merge is broadcast-driven - but it means a healed cluster with
no writer stays forked indefinitely. Recorded here because the scenario pins
it and because it is what makes the next part observable.

**A write after the heal starts the merge, and it finishes for one of the
two losers.** After one settings write:

| node | role | epoch after heal | value |
|---|---|---|---|
| 0 | survivor (senior) | 1 | 21 (its own) |
| 1 | losing branch's leader | 1 | 21 (converged) |
| 2 | losing branch's follower | 2 | 99 (its dead branch) |

Node 1 discarded its branch, re-folded node 0's chain and now names node 0 as
leader; its fold hashes equal to node 0's. Node 2 is still on epoch 2 and
still names node 1 - a member no other member believes is leader - as its
own. Nothing in thirty further ticks moves it.

Why node 2 is not pulled across is **not established**. It is connected to
node 0, and a record from node 0 that does not chain to node 2's head should
reach `onDivergence`, compute node 0 as the survivor and drive
`becomeLoser`. Something between those two facts does not happen; this
report deliberately stops at what was observed rather than guessing.

## Reproduction

`LoopWorld: a three-member partition elects a second leader and heals` in
`src/sim/sim.zig`, run by `zig build test`.

The scenario is deterministic: `LoopWorld` drives three real
`cluster.ClusterNode`s over real stores with no threads and no sockets, so
the ordering of every frame and every tick is fixed. The final assertions
pin the *current* behaviour on purpose, so that whatever fixes this fails
there and has to update the scenario and this report together.

## Root cause

Established by tracing the deterministic scenario (temporary prints on the
divergence/merge paths): node 2 reaches `onDivergence` with node 0 as the
winner, `becomeLoser` is called, and it returns at `branch_start orelse
return` - node 2 has **no branch facts**.

The branch facts are set only where a member *authors* a new epoch
(`appendEpoch`, unconditional) - never where it *folds* one:

- `onSlot` and `slotAndBroadcast` both compared the epoch slot's number
  against the fold's epoch **after** `applyReplicated` had already advanced
  it (`ep.number` equals the slot's epoch, so `sl.epoch > ep.number` is
  always false) - the blocks were dead code.
- `onSyncPage` (backfill) had no block at all, so a follower whose only
  knowledge of the new term came from a sync page - the sim's node 2 -
  carried a folded epoch 2 with no `branch_start`.

`becomeLoser`'s guard then bails, and nothing else moves the member: the
survivor's merge re-slot broadcasts keep hitting `BadPrevHash` and re-enter
`onDivergence` -> `becomeLoser` -> the same early return, every tick. The
losing *leader* (node 1) converges because it authored its own epoch and so
has facts.

The earlier "what is ruled in and out" list holds; the missing piece was
the branch-facts setter, not the loser machinery.

## Resolution

Fixed in `src/cluster/node.zig`:

- `onSlot` and `slotAndBroadcast` now capture the pre-apply epoch number and
  compare against it (`ep.number > prev_epoch_number`), and use the
  pre-apply head (`prev_head != null`) instead of the post-apply head - so a
  genuinely new term recorded by a live broadcast sets the facts, while a
  re-slotted epoch (which carries the current number and never advances the
  fold) still does not.
- `onSyncPage` records the same facts when it folds an epoch on the control
  chain, so a member that learns its branch only from backfill is no longer
  stranded.

The `LoopWorld` scenario's final assertions now pin the converged state:
all three members' folds hash equal, node 2 names node 0 as leader at
epoch 1 with the survivor's settings value (previously it pinned the
strand).

## Verification

n/a - not resolved. The reproduction is verified: `zig build test` green with
the scenario asserting the state above.

## Follow-up

- The heartbeat carries `head` and no code compares it to the local head. A
  cheap convergence trigger for a healed-but-idle cluster would be to notice
  a peer whose advertised head cannot be reached from ours. That is a design
  choice, not an obvious fix, and is not made here.
- PRD 0003's *Status* asked for "the simulator over the loop (OQ 27's second
  half) and a deterministic scenario before it can be pinned". Both now
  exist; this report is what they produced.

## References

- Code: `src/cluster/node.zig` (`onDivergence`, `becomeLoser`,
  `doMergeControl`, `onHeartbeat`), `src/sim/sim.zig` (`LoopWorld`)
- PRD: [PRD 0003](../../prds/0003-membership-and-leadership.md) *Status*
  (the known issue) and *Partition and merge*;
  [PRD 0005](../../prds/0005-embedding-the-library-as-the-product.md), where
  it was first seen
- Fix: none yet
