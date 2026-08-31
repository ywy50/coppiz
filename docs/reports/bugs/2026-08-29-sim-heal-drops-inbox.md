# Bug - The simulator's `heal` discards losing-side messages still in inboxes

## TL;DR

- **What failed:** `heal` builds the losing branch from a side node's *folded* chain and then clears every node's inbox. A message broadcast by the losing leader that sits in a side-member's inbox (not yet folded) at heal time is silently dropped from the merged chain.
- **Impact:** Simulator-only: a scenario that appends on the losing side and calls `heal` without an intervening `tick` silently loses that message while still passing `assertConverged` (every node re-folds the same chain).
- **Resolution:** **Resolved 2026-08-31, after a false resolution on 2026-08-29.** The 2026-08-29 record claimed a fix that no commit ever contained; the defect was live until now. It is now fixed for real, with a regression test that was seen to fail on the parent commit.

## Status

Resolved 2026-08-31, after a false resolution on 2026-08-29.

Reopened and fixed in the same change. The record had been marked `Resolved`
on 2026-08-29 while its own TL;DR still read "Still open" and its References
still read "Fix: none", and the fix it described was not in the tree. See
*Reopened - what was checked* for the evidence and *Resolution* for what
actually shipped.

## Symptom and impact

`heal` (`sim.zig:589-600`): the merged chain is built from `tailOf(side)` = `partition_sides[side].items[0]`'s chain (only *folded* messages, `sim.zig:604-607`); then every node's `inbox` is cleared (`:596`) and re-folded from the merged chain. A broadcast in flight (in an inbox, not yet folded - `slotAndBroadcast` applies only to the author, `sim.zig:299-324`) at heal time never makes it into the merged chain. No test currently hits it (all shipped scenarios `tick` before `heal`), and `assertConverged` cannot catch it (all nodes share the same merged chain).

## Reproduction

Originally recorded as: not dynamically reproduced; statically certain. A
scenario that appends on the losing side and calls `heal` without an
intervening tick loses that message.

Now reproduced dynamically. The regression test
`sim.sim.test."heal folds pending inbox broadcasts into the branch it
merges"` partitions `{A} | {C,B}` - the losing side listed **follower
first**, so the node `tailOf` reads it through is not the node that authors
its writes - has B write, and heals with no intervening tick. On the parent
commit (`f6f37f2`) it fails at the final
`entryResolves(i, b_write_id)` with `TestUnexpectedResult`, while the
preconditions all hold: C's inbox is non-empty, the entry does not resolve on
C before the heal, `heal` returns without error, and `assertConverged`
passes. So the failure is the silent drop the report describes.

The set order matters for whether the loss is observable, which is worth
stating plainly: with the leader listed first, `tailOf` happens to read the
author's own chain, which does hold its unbroadcast write, and nothing is
lost. That is luck, not a guarantee - which is why the fix drains the
inboxes rather than choosing a different node to read.

## Root cause

Heal snapshots the folded chains instead of draining pending inboxes; inbox messages are treated as if they had never been broadcast.

## Reopened - what was checked

Checked at `9765d30` (2026-08-31), by reading and by search:

- `heal` in `src/sim/sim.zig` still went straight from `partition_head` to
  the common-prefix count and then to `sideLeader`/`tailOf`, with no inbox
  handling anywhere before the branches are built. The only `inbox` mention
  in the whole function is the `clearRetainingCapacity` in the re-fold loop -
  the drop point this report names.
- `git log --oneline 8893ae1..9765d30 -- src/sim/sim.zig` lists eight
  commits; none of them touches `heal`'s branch construction or adds an
  inbox drain.
- The commit that set `Status: Resolved` here is `8893ae1`
  ("docs(reports): mark the sweep fixes resolved (#116)"). `git show --stat
  8893ae1` lists **29 report files and no source file at all**: it changed
  four lines in this record (Status and Resolution) and touched nothing
  under `src/`.

So the *Resolution* recorded on 2026-08-29 describes work that was not done.
It is kept verbatim below rather than deleted, because the record's value now
includes knowing that it was wrong: a `Resolved` row in the inventory hides
live work exactly as effectively as a missing row would.

What is *not* claimed here: why the record said otherwise. It may have
described an intended change, or a change that was reverted; no attempt was
made to reconstruct that, and the reader should not infer one.

## Resolution (as recorded 2026-08-29 - not implemented)

Fixed: `heal` folds pending inbox broadcasts into the branches before building the merged chain; regression test appends on the losing side and heals immediately.

## Resolution

Fixed 2026-08-31. `heal` now runs `processInbox` over every live node before
it counts the common prefix or reads either side's branch, so a broadcast
that was sent but not yet delivered is folded into the side's chain rather
than discarded by the inbox clear further down.

Why `processInbox` and not a separate drain: it is exactly what a `tick`
does, so the fold and the epoch-liveness check a pending `epoch` entry goes
through are the same on both paths, and a heal cannot admit an entry a tick
would have dropped. It runs while the partition's links are still closed
(`reopenLinks` is the last thing `heal` does), and no cross-side message can
be in an inbox anyway: `partition` closes the links before either side sends
anything, and it refuses to start at all unless every live node is at the
same fold head.

The side effect is that `tailOf`'s premise - any live node on a side shares
that side's chain - is true at the moment the branches are read, rather than
true only when the scenario happened to tick first.

## Verification

- Static, original: `heal`/`tailOf`/`slotAndBroadcast` read; the
  inbox-clearing line (`sim.zig:596`) is the drop point.
- Static, 2026-08-31: the re-read and the `git log` recorded above.
- Dynamic, 2026-08-31: regression test "heal folds pending inbox broadcasts
  into the branch it merges" (`src/sim/sim.zig`). Seen to fail on the parent
  `f6f37f2` at the post-heal `entryResolves` and to pass with the fix.
- Full `zig build test --summary all` green - see the resolving PR for the
  quoted `Build Summary` line.

## Follow-up

Simulator-fidelity issue only; the shipped scenarios were unaffected, because
every one of them ticks before it heals.

Companion defect 2026-08-28-sweep3-sim-heal-crashed-leader carried the same
false-resolution pattern in the same function and was corrected the same way
one change earlier. Both came from `8893ae1`, a docs-only commit that flipped
29 reports to `Resolved`; a `Status` line is a claim about the tree, and the
only thing that settles it is a search of the tree.

## References

- Code: `src/sim/sim.zig` (`heal`, `processInbox`, `tailOf`, `slotAndBroadcast`)
- False resolution: `8893ae1` (docs-only, 29 reports)
- Companion: [2026-08-28-sweep3-sim-heal-crashed-leader.md](2026-08-28-sweep3-sim-heal-crashed-leader.md)
- Fix: this report's resolving commit
