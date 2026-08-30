# Bug - a suspected member is never redialed: the suspect branch shadows the dial branch

## TL;DR

- **What failed:** the tick's per-member chain is suspect -> heartbeat -> dial
  (`if/else-if`). Once a member is `.lost`, its `last_heard_ms` is frozen, so
  the suspect branch fires every tick and re-stamps `dial_at_ms = now +
  backoff` - pushing the dial out each time and keeping the dial branch
  unreachable.
- **Impact:** a member partitioned away longer than `cluster.suspect_after_ms`
  is never redialed by the healthy side (and symmetrically by itself). The
  two halves of a split cluster each elect their own leader and keep
  serving divergent writes indefinitely - the merge never engages because
  the connection is never re-established. Split brain with no recovery.
- **Resolution:** Resolved - the suspect branch now fires only on the
  member->lost transition, leaving a lost member's scheduled redial alone.

## Status

Resolved.

## Symptom and impact

The tick's member loop (`node.zig`, `onTick`):

```zig
if (ms.last_heard_ms != 0 and now -| ms.last_heard_ms >= suspect_after) {
    if (ms.conn_id) |cid| self.closeConn(cid);
    ms.conn_id = null;
    ms.state = .lost;
    ms.dial_at_ms = now + ms.backoff_ms;   // re-stamped every tick
} else if (ms.conn_id != null) {
    ... heartbeat ...
} else if (ms.dial_at_ms != 0 and now >= ms.dial_at_ms) {
    ... dial ...
}
```

`last_heard_ms` is only updated by hello/heartbeat, so a lost member's
suspect condition stays true every tick; each fire re-stamps
`dial_at_ms = now + backoff`, and the dial branch (an `else if` below) never
runs. The `dial_at_ms` assignment in the suspect branch is dead code that
permanently defers the redial. With the defaults (heartbeat 1 s, suspect
5 s), the redials that fire before suspicion (at ~250/750/1750/3750 ms) stop
after ~4-5 s, and no further dial is ever spawned - even after the network
recovers.

Impact: any member whose conn is down longer than `suspect_after` is never
reconnected. Both sides elect their own leaders and keep writing; the merge
machinery never engages because there is no connection. The existing tests
mask it: `e2e (b)` reconnects via `seed_peers`, `embed-cluster` partitions
for less than the suspect window, and the loop sim reconnects by fiat.

## Reproduction

Two members, no seed peers, `cluster.suspect_after_ms` low: cut the link,
wait past the suspect window, restore the link - the healthy side never
dials; only a restart of the lower-id member (which dials first) heals it.

## Root cause

The failure detector and the redial scheduler occupy one `if/else-if` chain,
and the detector's branch never releases the scheduler: a lost member stays
"suspect" forever (frozen `last_heard_ms`), so the dial branch is
unreachable. The design intent (per the comments and the
redial-backoff-never-resets fix) is that a member is suspected *before* the
redial, then redialed - the code made the redial impossible.

## Resolution

Fixed: the suspect branch now fires only on the member->lost transition
(`ms.state != .lost` in its condition), closing the conn and scheduling the
redial once; a lost member then falls through to the dial branch on later
ticks, and `onDialFailed` keeps re-arming it with the backoff ratchet until
the connection lands. A brief blip (shorter than `suspect_after`) behaves
exactly as before - no transition, no lost state.

## Verification

- Regression test "a suspected member's scheduled redial is not pushed out
  by the suspect branch": a member with a stale heartbeat and a scheduled
  dial keeps the exact scheduled time across two ticks, and lands in
  `.lost` - before the fix the dial was re-stamped to `now + backoff` each
  tick.
- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: `src/cluster/node.zig` (`onTick`'s member loop, `onDialFailed`,
  `onPeerGone`)
- Fix: this report's resolving commit
