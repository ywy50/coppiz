# Bug - a joiner heartbeats at the schema default, so a cluster with a short suspect window disconnects every member it admits

## TL;DR

- **What failed:** `onTick` arms `MemberState.next_heartbeat_ms` from
  `cluster.heartbeat_ms` at the moment it sends and re-reads the setting only
  when that instant arrives. A member with no chain yet reads the schema
  default of 1000 ms, so it arms a second out; folding the chain a tick later
  lowers the setting and leaves the armed instant where it was.
- **Impact:** in a cluster whose `cluster.suspect_after_ms` is under 1000 ms,
  the admitter suspects the member it has just admitted and closes the
  connection - so the newcomer loses the peer it was backfilling from, and
  with `membership.evict_after_ms` set it is evicted from the chain. A live
  lowering of `cluster.heartbeat_ms` had the same lag for every member.
- **Resolution:** fixed - a schedule armed under a longer interval is
  re-armed on the next tick rather than waited out.

## Status

Resolved 2026-08-31. The cause was established by
[the writer-less heal was a stale heartbeat schedule](../investigations/2026-08-31-writer-less-heal-was-a-stale-heartbeat-schedule.md),
which traced a simulator result to it; this report is the defect that
investigation found.

## Symptom and impact

`src/cluster/node.zig`, `onTick`:

```zig
const heartbeat_ms = self.settingU64("cluster.heartbeat_ms", 1000);
…
} else if (ms.conn_id != null) {
    if (now >= ms.next_heartbeat_ms) {
        self.sendHeartbeat(ms) catch {};
        ms.next_heartbeat_ms = now + heartbeat_ms;
    }
}
```

`settingU64` reads the folded control settings. A joiner's first tick runs
before its backfill has folded anything - `node.control.head` is `null` - so
the call returns the *default*, not the cluster's value, and the member arms
`now + 1000`.

Measured on a two-member `LoopWorld` cluster whose genesis sets
`cluster.heartbeat_ms = 100` and `cluster.suspect_after_ms = 500`, with the
world advancing 100 ms a tick. The joiner's first tick:

```
now=1000100 state=.member conn=2 lh=1000000 nhb=0 hb_ms=1000 sa=5000 head=null syncing=true
```

and its second, one tick later, after the fold has landed:

```
now=1000200 state=.member conn=2 lh=1000100 nhb=1001100 hb_ms=100 sa=500 head=(1,3) syncing=true
```

`hb_ms` and `sa` are now the cluster's, but `nhb` is still the instant armed
under the default - 900 ms away. The founder's view of the joiner over the
same ticks:

```
now=1000200 … lh=1000100 nhb=1000200
now=1000600 … lh=1000100      <- suspect: 1000600 - 1000100 >= 500
now=1000700 state=.lost conn=null
```

The founder heard one heartbeat, at 1,000,100, and nothing for the 500 ms
that followed, so it suspected the joiner, closed the connection and set
`.lost`. The joiner then heard nothing from the founder either and suspected
it in turn at 1,001,000. With `membership.evict_after_ms = 2000` both went on
to evict the other from their own chain.

The cluster cannot grow under such a configuration: every newcomer is
disconnected roughly one suspect window after its `join` slots, before it can
finish backfilling.

`cluster.suspect_after_ms` defaults to 5000, so the shipped defaults do not
hit it. Both timings are placeholders on the record at
[RFC 0034](../../rfcs/0034-leader-lease.md), and PRD 0003 offers them as
ordinary live-changeable settings, so a sub-second window is a configuration
the design invites rather than an abuse of it.

The second face of the same defect needs no joiner: `cluster.heartbeat_ms` is
live-changeable, and lowering it left every member on the old interval until
the already-armed instant passed. Lowering `heartbeat_ms` and
`suspect_after_ms` together - the natural way to tighten failure detection -
therefore made every member suspect every other one once, immediately.

## Reproduction

`src/sim/sim.zig`, *LoopWorld: a joiner adopts the cluster's heartbeat
cadence before it is suspected*: two members, genesis with
`cluster.heartbeat_ms = 100` and `cluster.suspect_after_ms = 500`,
`tick_advance_ms = 100`, joined by handshake, then 40 ticks asserting that
neither side regards the other as lost.

- Expected: neither is ever suspected; both hold two members.
- Actual (before the fix): the founder regards the joiner as lost from the
  sixth tick on, and the joiner regards the founder as lost from the tenth.

The scenario is only expressible since the simulator took the clock over
(`cluster.ElapsedClock`, `LoopWorld.tick_advance_ms`). On the real monotonic
clock a tick spans microseconds, so no cadence measured in milliseconds is
ever reached and the bug is invisible.

## Root cause

The interval is a *setting*, read from a fold that changes under the loop,
but the schedule derived from it was treated as immutable until it expired.
Nothing tied the pending wait back to the setting it was computed from, so
every path that shortens the interval - folding a chain for the first time,
or an operator lowering the value - was honoured only after a delay of the
*old* interval.

## Resolution

The heartbeat branch also fires when the pending wait exceeds the current
interval:

```zig
const waiting = ms.next_heartbeat_ms -| now;
if (now >= ms.next_heartbeat_ms or waiting > heartbeat_ms) { … }
```

A schedule armed under a longer interval is therefore re-armed on the next
tick, and steady state is untouched: with the interval unchanged the pending
wait is at most the interval itself, so the added condition is false.

The complementary case needs nothing: a *raised* interval only pushes the
next beat out, which the existing comparison already does at the next send.

## Verification

`zig build test` (the merge gate: unit tests plus the fmt, 100-column,
test-registration, refAllDecls-pairing and gate-coverage lint gates), green.

The new scenario fails on the parent commit with the founder suspecting the
joiner, and passes with the fix. The three-member scenario's post-heal window
also tightens: the merge it waits for used to need the stale schedule to
expire first, 18 ticks in.

## Follow-up

The same read-once-then-cache shape applies to `ms.dial_at_ms` and
`seed_retry`, both of which are computed from constants rather than settings,
so no setting can shrink under them. `next_checkpoint_ms` is computed from
`checkpoint.every_ms`, which *is* a live setting, and lowering it is honoured
only after the pending interval - not reported here because the consequence
is one late checkpoint rather than a member falling out of the cluster.

## References

- Investigation: [2026-08-31 - the writer-less heal was a stale heartbeat schedule, not a missing merge step](../investigations/2026-08-31-writer-less-heal-was-a-stale-heartbeat-schedule.md)
- Code: `src/cluster/node.zig` (`onTick`), `src/sim/sim.zig` (`LoopWorld`)
- Fix: this commit
