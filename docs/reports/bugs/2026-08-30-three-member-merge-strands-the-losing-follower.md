# Bug - a three-member merge strands the losing branch's follower

## TL;DR

- **What failed:** after a three-member partition heals and merges, the
  losing side's *leader* converges on the survivor and the losing side's
  *follower* does not. It keeps its dead branch and goes on naming its old
  leader.
- **Impact:** a silently divergent member. It serves reads from a chain the
  cluster has discarded, and it is a member in every other member's fold.
- **Resolution:** open. This report is the first deterministic
  reproduction; the cause is not yet established.

## Status

Open. Reproduced 2026-08-30 by the new loop simulator. This is the failure
PRD 0003's *Status* has carried as a known issue since 2026-08-27:

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

Not established. What is ruled in and out so far:

- It is not the transport: `LoopWorld` has no sockets, no reader threads and
  no timing.
- It is not the merge rule. The pure-function simulator's
  `three-member partition: the losing side's follower converges too` runs the
  same shape over `membership`/`election`/`epoch` and converges all three
  nodes, including the follower. So the rules are right and the loop's use
  of them is not.
- The losing *leader*'s path works end to end, so `becomeLoser`, the
  truncate, the re-fold and the re-sync are all functional. What is missing
  is whatever should put the follower on that path.

## Resolution

Open.

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
