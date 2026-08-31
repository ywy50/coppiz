# Investigation - the post-heal window in the three-member scenario proved nothing

## TL;DR

- **Symptom traced:** the three-member scenario asserts that a healed
  cluster with no writer stays forked, and attributes it to heartbeats
  carrying a head "without anything comparing it".
- **Finding:** the attribution is wrong twice over. `onHeartbeat` does
  compare the peer's head and does request a sync when the peer is ahead.
  And inside that ten-tick window no heartbeat was sent or received at all,
  so the window could not have been evidence for any claim about
  heartbeats.
- **Result:** the conclusion survives, on better evidence. With a heartbeat
  due on every tick, 200 ticks after the heal leave the cluster on two
  branches. The window now runs that way and asserts it.

## Status

Resolved as an investigation 2026-08-31. The narrowed question it leaves -
why the sync the head comparison requests does not carry the divergence
through to a merge - is open, and recorded in PRD 0003 beside the existing
three-member issue.

## Symptom

`src/sim/sim.zig`, *LoopWorld: a three-member partition elects a second
leader and heals*, after restoring both cut links:

```
for (0..10) |_| try world.tick();

// Reconnecting is not enough on its own: after ten ticks with the links
// back up, node 0 is still on its epoch-1 branch and nodes 1 and 2 on
// their epoch-2 one. Heartbeats carry the peer's head and nothing
// compares it, so nothing detects the divergence until a record fails
// `prev_slot_hash`.
```

PRD 0003's status carries the same sentence: "the merge is broadcast-driven,
and heartbeats carry the peer's head without anything comparing it".

## What was measured

Three instrumented runs of the full suite, each a temporary `std.debug.print`
reverted afterwards.

**1. The comparison exists.** `onHeartbeat` reads:

```
ms.head = hb.head;
const my_head = self.node.control.head orelse ...;
ms.state = if (order(hb.head, my_head) != .lt) .member else .syncing;
// Gap catch-up: the peer is ahead of me.
if (order(hb.head, my_head) == .gt) {
    const conn = ms.conn_id orelse return;
    _ = self.requestSync(conn, self.node.control.journal_id, my_head.next()) ...
```

A probe on both arms fired 1,511 times across the suite: 22 in the `.gt`
arm, of which 13 issued a sync request and 9 were suppressed because one was
already in flight. The comparison is live code, not a dead branch.

**2. It never ran in the window.** Probes at the entry of `onHeartbeat`,
at each of its four early returns, and at the `sendHeartbeat` call, bracketed
by markers printed either side of the ten ticks: **zero lines of any kind**
between the markers. No heartbeat was sent, none was received, and no early
return was taken - there was nothing to return from.

The cause is the cadence. `onTick` gates sending on `cluster.heartbeat_ms`,
which is 1000 ms of *real* elapsed time (`elapsedMs` reads the monotonic
clock and has no seam - `LoopWorld`'s own doc comment says so). The
simulator drives ticks as fast as it can, so ten of them span microseconds
and no heartbeat is ever due. The window was measuring the heartbeat
interval, not the protocol.

**3. The conclusion holds anyway.** Re-running the scenario with
`cluster.heartbeat_ms = 0` in the genesis settings, so a heartbeat is due on
every tick, and polling for convergence over 200 ticks:

```
PRB no-writer converged=false
PRB node=0 epoch=1
PRB node=1 epoch=2
PRB node=2 epoch=2
```

Still two branches, with the whole suite green (342/342). Heartbeats flowing
freely for 200 ticks do not converge a healed cluster that nobody writes to.

## Conclusion

The scenario's claim was right and its stated reason was wrong. Because the
reason was wrong, the assertion did not test it: ten ticks at the default
cadence would have passed whatever the heartbeat path did, including if it
had converged the cluster perfectly.

What is actually pinned, now on evidence: the head comparison runs, requests
a sync when it sees a peer ahead, and that sync does not carry the
divergence through to a merge. The divergence is still only detected when a
record fails `prev_slot_hash`, which is why a write is what starts the heal.

## Changes made

- The window runs 200 ticks with `cluster.heartbeat_ms = 0` and asserts
  non-convergence, so it fails if the heartbeat path ever does converge a
  writer-less heal - which is the behaviour the sentence was reaching for.
- The comment and PRD 0003's status say what is true: the comparison exists,
  and what is missing is the step from it to a merge.

## Follow-up

Why the requested sync does not reach `onDivergence` is not established
here. It is the same region as the open report
[a three-member merge strands the losing branch's follower](../bugs/2026-08-30-three-member-merge-strands-the-losing-follower.md),
and is best taken up with it rather than guessed at: nothing in this
investigation licenses a change to the sync path.

The cadence trap is general. Any `LoopWorld` scenario that means to exercise
heartbeats, suspicion or eviction has to set the interval it depends on to
something a tick can reach, or it silently tests nothing. Only this scenario
was checked.
