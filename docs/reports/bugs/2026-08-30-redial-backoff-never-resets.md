# Bug - a member's redial backoff ratchets to 8 s and never comes back down

## TL;DR

- **What failed:** `MemberState.backoff_ms` only ever doubled. Nothing reset
  it when the connection came back, so after a handful of blips every member
  sat permanently at the 8 s ceiling.
- **Impact:** that ceiling is above the default `cluster.suspect_after_ms`
  (5 s), so once a member reached it, any later disconnection - however
  brief - expired the suspect timer before the redial was even attempted.
  The member dropped out of `leader(...)`'s live set on every blip, which
  under `seniority` is leader churn and under `configured` + `stall` is a
  refused write.
- **Resolution:** fixed. `noteConnected` resets the delay to its floor on
  both paths that bind a connection to a member.

## Status

Resolved. Found by reading `src/cluster/node.zig`; no investigation record.

## Symptom and impact

Exponential backoff is a recovery delay, not a property of the peer. In
`src/cluster/node.zig` it was written as a one-way ratchet:

```zig
ms.dial_at_ms = self.elapsedMs() + ms.backoff_ms;
ms.backoff_ms = @min(ms.backoff_ms * 2, 8000);
```

That statement pair appeared in `onDialFailed` and in `closeConn`, and no
site anywhere in the file assigned `backoff_ms` any other value after the
`MemberState` was created. So the delay was monotonically non-decreasing for
the life of the process, and five drops (250 → 500 → 1000 → 2000 → 4000 →
8000) pinned it at the ceiling for good, regardless of how long the
connection stayed healthy afterwards.

The consequence is not just a slow redial. `cluster.suspect_after_ms`
defaults to 5000 ms and `max_redial_backoff_ms` is 8000 ms, so a member at
the ceiling cannot be redialled inside its own suspect window:

1. the connection drops; `closeConn` schedules the redial 8 s out and leaves
   `state` alone (the suspect timer owns that transition);
2. 5 s later `onTick` sees `now - last_heard_ms >= suspect_after` and sets
   `state = .lost`;
3. `runElection` now runs over a member set with that peer marked dead.

Under `leadership.mode = seniority` a lost senior member re-elects the
cluster; under `configured` + `stall` a lost authority stalls writes. Both
happen for a blip that a 250 ms redial would have covered without the
election ever noticing.

## Reproduction

`a member's redial backoff resets when its connection comes back` in
`src/cluster/node.zig`. It drives the real handlers on a single thread: three
`onDialFailed("peer")` calls widen the delay to 2000 ms, then a `hello_ack`
arrives on a connection for that member and the test asserts the delay is
back at `initial_redial_backoff_ms` with no redial pending.

Before the fix the test fails on the reset assertion with
`expected 250, found 2000`; the connection is bound, but the delay stays
where the failures left it.

## Root cause

`backoff_ms` had exactly two writers, both of them the doubling step. The
symmetric "the peer is reachable again, forget the recovery delay" write was
never written. Both places that bind a live connection to a member -
`onHello` (inbound: the peer dialed us) and `onHelloAck` (outbound: our dial
succeeded) - already set `conn_id`, `last_heard_ms` and `state`, and neither
touched the delay.

## Resolution

- `initial_redial_backoff_ms` (250) and `max_redial_backoff_ms` (8000) are
  named constants at module scope, with the relationship to
  `cluster.suspect_after_ms` written down beside them; the two magic numbers
  are gone.
- `scheduleRedial` holds the doubling step once, instead of the same two
  lines in two places.
- `noteConnected` resets the delay to its floor and clears `dial_at_ms`. It
  is called from `onHello` and from `onHelloAck` on the branch where the
  member is already known - a member created by those handlers gets the
  floor from the struct default.

The behaviour under sustained failure is unchanged: the delay still widens
to the same ceiling on repeated failures, which is what the ceiling is for.

## Verification

- The new test fails before the change (`expected 250, found 2000`) and
  passes after.
- `zig build test` green on the branch.

## Follow-up

The seed-dial retry in `onTick` is a separate mechanism with a flat 2000 ms
period and no backoff at all; it is not covered here.

## References

- Code: `src/cluster/node.zig` (`scheduleRedial`, `noteConnected`,
  `onDialFailed`, `closeConn`, `onHello`, `onHelloAck`)
- PRD: [PRD 0003](../../prds/0003-membership-and-leadership.md) *Failure
  detection*
- Fix: this PR
