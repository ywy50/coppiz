# RFC 0012 - backpressure: a slow follower must not slow the writers

## Status

Discussion - opened 2026-08-29. Addresses OQ 28 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Under a fast leader, a slow follower cannot keep up with the broadcast. The
leader must decide what it does with that follower: buffer (bounded by
what?), drop it to backfill, or slow every writer. Nothing is drafted yet.

**Decision to make.** What happens to a member that falls behind the
broadcast rate - and who pays for its slowness?

**Why now.** The loop already has the pieces (per-follower send state, the
sync/backfill path, the failure detector) but no explicit policy. The
policy determines whether a single slow member can stall the cluster's
writes - the failure mode OQ 28 exists to name.

**Drivers.** Any acceptable option must:

- keep acknowledged writes fast: a writer's `append` must not wait on a
  slow follower's socket (PRD 0001 G3 is about the writer's own durability,
  not peers' delivery);
- not lose the slow follower's data silently: it must either catch up
  (backfill) or be marked `unreachable` and reconciled on heal;
- bound memory: whatever the leader buffers must be bounded by a setting,
  not by the follower's speed (OQ 61's memory bound applies).

**Out of scope.** Network congestion control for the wire itself; the
queue-drain shape (RFC 0004, decided separately).

## Current state

The leader broadcasts each slot to every member over its connection;
`broadcastToMembers` writes to each follower's socket. There is no
per-follower send queue with a bound - a follower that stops reading
eventually blocks the leader's write path on its socket. The sync path
(backfill from any member, chain-verified) exists and is the recovery
mechanism. The failure detector marks a member `unreachable` after
`cluster.suspect_after_ms` of silence, which today is about heartbeats,
not about broadcast progress.

## Options considered

### Option A - bounded per-follower window; overflow = disconnect to backfill (out-of-the-box)

- **What it is:** the leader keeps a bounded per-follower send window (a
  setting, e.g. `cluster.follower_buffer` in slots or bytes). A follower
  that keeps up consumes the window; one that falls behind fills it; at
  the bound, the leader closes that follower's connection, marks it
  behind, and lets the existing sync path bring it back (backfill from
  any member, so the leader is not even the only source). The writers are
  never blocked; the slow follower pays with a resync.
- **Pros:** bounded memory (the window is a setting); the slow member
  pays, not the writers; reuses the shipped backfill path; the failure
  detector's role is unchanged (the follower is `unreachable`-ish while
  resyncing).
- **Cons:** a resync is heavier than keeping up (pages, re-verification);
  the window size is a new knob whose value wants a measurement; a
  follower that oscillates (keep-up, drop, resync, keep-up) churns.
- **Cost to adopt:** the bounded window in the broadcast path plus the
  disconnect-and-resync policy; no format or loop change.
- **Cost to leave:** the current unbounded blocking stays - a single slow
  follower can stall the leader today.
- **Evidence:** the shipped sync path (backfill from any member, PRD 0003);
  OQ 61's memory bound.

### Option B - slow every writer (global pacing)

- **What it is:** the leader throttles all appends to the slowest
  follower's rate.
- **Pros:** the follower always keeps up; no resync.
- **Cons:** one slow member caps the whole cluster's throughput - the
  exact failure mode OQ 28 exists to prevent; a deliberately slow member
  becomes a denial-of-service on the group (OQ 1's model has no defense
  against that).
- **Cost to adopt:** trivial; the damage is the point.
- **Cost to leave:** none.
- **Evidence:** the OQ 28 premise; OQ 1's trust model.

### Option C - unbounded buffering

- **What it is:** the leader queues everything for a slow follower.
- **Pros:** the follower always catches up from the buffer.
- **Cons:** unbounded memory (violates OQ 61); a follower that never
  catches up leaks the leader's memory until the process dies.
- **Cost to adopt:** none.
- **Cost to leave:** the leak is the risk.
- **Evidence:** OQ 61's bound requirement.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** the bounded window lands; a slow follower resyncs instead of
  stalling the writers.

### Medium term (3-12 months)

- **If A:** the window size is measured under a real follower mix (OQ 54's
  suite); the oscillating-follower case gets a simulator scenario (OQ 27).

### Long term (12+ months)

- **If A then gossip (RFC 0011, C):** the window policy carries over; a
  star's single hub makes the bound more important.

## Recommendation

**Recommended option:** A - a bounded per-follower send window, with
overflow meaning "disconnect that follower and let backfill bring it
back". The slow follower pays; the writers never block; the memory is
bounded by a setting.

**Confidence:** 6/10

**Why this confidence.** A reuses the shipped sync path and satisfies
every driver; what would move it up is a measurement of a real slow
follower's resync cost (is a page-based resync cheap enough to prefer over
a bigger window?) and the window-size value. What would sink it: a
deployment where resync is so expensive that oscillation makes the
follower permanently behind - which would argue for a larger window, not
for B.

**Rationale.** B makes one member able to stall the group - the opposite
of the question's point - and C is unbounded memory. A is the only option
that bounds memory, keeps writers fast, and reuses an existing path.

**Reversibility.** A is a loop policy; reversible without format change.

## Open questions

- What is the default window size (slots/bytes) before measurement? The
  provisional value should be generous enough that only a genuinely stuck
  follower hits it (e.g. a few seconds of the expected broadcast rate).
- Does the disconnect-and-resync policy need the follower marked
  `unreachable`, or a distinct "resyncing" state? (PRD 0003's member
  states)

## Next steps / action items

- [ ] Add the bounded window to the broadcast path with the provisional
      setting; add the disconnect-and-resync policy.
- [ ] Add the slow-follower scenario to the simulator's list (OQ 27).
- [ ] Write the ADR once decided; update OQ 28's status.

## References

- OQ 28 (historical) - the question this RFC addresses.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - the broadcast,
  sync and failure-detector paths the policy uses.
- [OQ 61](../research/0009-memory-bound.md) - the per-process memory bound the window
  must respect.
- [RFC 0011](0011-topology-past-32.md) - the star topology the policy
  will run under past 32 members.
