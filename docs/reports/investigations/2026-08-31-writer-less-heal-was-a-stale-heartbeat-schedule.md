# Investigation - the writer-less heal was a stale heartbeat schedule, not a missing merge step

## TL;DR

- **Question:** why does the sync that `onHeartbeat`'s head comparison
  requests not carry a post-heal divergence through to a merge? PRD 0003
  recorded that step as the thing that is missing.
- **Finding:** it does carry it through. Nothing was missing. The two
  joiners never heartbeated the survivor inside the window at all, because
  each had armed its heartbeat schedule for that peer from the *schema
  default* (1000 ms) before it had folded the chain that sets
  `cluster.heartbeat_ms` to 0, and 200 sub-millisecond simulator ticks never
  reach a schedule 1000 ms out.
- **Resolution:** the scenario now runs on a clock the world owns, and
  asserts that a writer-less heal converges. The stale schedule is a defect
  in its own right and is fixed separately.

## Status

Resolved 2026-08-31. It supersedes the narrowed question left open by
[the post-heal window proved nothing](2026-08-31-no-writer-heal-window-proved-nothing.md)
and the matching sentence in
[PRD 0003](../../prds/0003-membership-and-leadership.md)'s status.

## Trigger and scope

`src/sim/sim.zig`, *LoopWorld: a three-member partition elects a second
leader and heals*. After both cut links are restored the scenario ran 200
ticks with `cluster.heartbeat_ms = 0` - a heartbeat due on every tick - and
asserted that the cluster was still on two branches, node 0 on its epoch-1
chain and nodes 1 and 2 on their epoch-2 one.

The claim carried forward from that assertion was that the head comparison's
sync does not reach a merge, so only a record failing `prev_slot_hash` starts
a heal. That is what this investigation set out to explain.

## Evidence

All observations are from `std.debug.print` probes added to
`src/cluster/node.zig` and `src/sim/sim.zig`, run through the `src/root.zig`
test binary, and reverted afterwards. The world's clock referred to below is
the seam this change adds: `cluster.ElapsedClock`, with `LoopWorld` advancing
`tick_advance_ms` per tick from a base of 1,000,000 ms.

**1. Observed - node 0 receives no heartbeat inside the window.** A probe at
the entry of `onHeartbeat`, at each of its four early returns, and at the
`sendHeartbeat` call site printed four sends and four receives per tick. Node
0 sent two (one to each peer) and nodes 1 and 2 sent one each - to each
other. No line showed a heartbeat arriving at node 0, and none showed an
early return: nothing was sent to it to return from.

**2. Observed - the two joiners' schedule for node 0 is 450 ms in the
future.** A probe over `onTick`'s member loop, at the first window tick
(world clock 1,000,575):

```
node 1, member 0: state=.member conn=4 lh=1000550 nhb=1001025 hb_ms=0
node 1, member 2: state=.member conn=3 lh=1000550 nhb=1000550 hb_ms=0
```

`nhb` is `MemberState.next_heartbeat_ms`. For node 2 it equals `now`, so a
heartbeat is due every tick as the setting asks. For node 0 it is 1,001,025 -
`base + 41 * 25`, which is 1000 ms after the joiner's *first* tick at
1,000,025. `hb_ms` reads 0 at that point, so the 1000 came from somewhere
else.

**3. Observed - the joiner reads the schema default before it has a chain.**
The same probe on the first tick of a fresh joiner:

```
now=1000100 state=.member conn=2 lh=1000000 nhb=0 hb_ms=1000 sa=5000 head=null syncing=true
```

`head=null`: the fold has no chain, so `settingU64("cluster.heartbeat_ms",
1000)` returns the default rather than the cluster's value. `onTick` sends
the one heartbeat that is due and arms the next for `now + 1000`. On the very
next tick the same probe reads `head=(1,3)` and `hb_ms=100`, and `nhb` is
still the value armed under 1000.

**4. Reproduced - the window converges once the clock moves.** With
`tick_advance_ms = 25`, node 0's head goes from `(1,5)` to `(1,8)` on window
tick 18 - it authored the `merge` entry and re-slotted the losing branch -
and all three folds hash-equal by tick 21. `base + 41 * 25 = 1,001,025` is
the tick the stale schedule comes due on, which is tick 18 of the window.

**5. Reproduced - with the clock frozen nothing happens.** With
`tick_advance_ms = 0` the same run leaves node 0 at `(1,5)` and nodes 1 and 2
at `(2,2)` for all 200 ticks, with no `requestSync` call logged in any of
them.

**6. Inferred - this is what the real clock did too.** Before this change
`elapsedMs` read `std.Io.Timestamp.now`. The simulator drives ticks as fast
as it can, so 200 of them span well under 1000 ms of real time and the stale
schedule never came due. That is inference from the same arithmetic, not a
separate measurement.

## Hypotheses and tests

- **The sync request is issued and its response does not reach a merge**
  (the recorded explanation). Rejected by observation 1: no sync was
  requested, because no heartbeat arrived to request one. Observation 4 shows
  that when one does arrive, the merge completes with nobody writing.
- **The sync watchdog is what unblocks it** - `sync_response_timeout_ms` is
  5000 ms and 200 ticks at 25 ms is exactly 5000. Rejected: convergence
  happens at tick 18, 450 ms in, and no `sync_in_flight` release was logged.
- **The handshake `restore` runs does not record the connection on the
  admitter's side.** Rejected by observation 2: `conn=4` is set, and
  `last_heard_ms` tracks the peer. Only the send schedule is stale.

## Finding

`onTick` arms `MemberState.next_heartbeat_ms` to `now + heartbeat_ms` at the
moment it sends, and re-reads the setting only when that instant arrives. A
member with no chain has no folded settings, so its first arming uses the
schema default of 1000 ms. Folding the chain a tick later lowers
`cluster.heartbeat_ms` but does not re-arm the schedule, so the member stays
silent towards that peer for the rest of the old interval.

In this scenario the two joiners were therefore not heartbeating the founder
for the first second of their lives, and the window that meant to test the
heartbeat path ran entirely inside that second. The head comparison in
`onHeartbeat`, the sync it requests, and the merge that sync leads to all
work: a healed cluster with no writer converges.

The record this corrects had already been corrected once, for a different
cadence artefact, by the 2026-08-31 investigation linked above. Both times
the window's length was measured in ticks and its precondition in
milliseconds, and nothing tied the two together. The simulator now owns
elapsed time, so a scenario states the cadence it depends on and gets it.

## Resolution or handoff

The scenario asserts convergence without a write, over a clock
`LoopWorld.tick_advance_ms` advances. PRD 0003's status no longer says the
step from the sync to the merge is missing.

The stale schedule is a separate defect with a consequence beyond the
simulator - a cluster whose `cluster.suspect_after_ms` is under 1000 ms
suspects and disconnects every member it admits, because the newcomer beats
at the default interval - and is reported and fixed on its own.

## References

- Related bug: none at the time of writing; the stale heartbeat schedule is
  reported separately.
- Code: `src/cluster/node.zig` (`onTick`, `onHeartbeat`, `ElapsedClock`),
  `src/sim/sim.zig` (`LoopWorld`)
- Logs or run: probe output quoted above; probes reverted.
