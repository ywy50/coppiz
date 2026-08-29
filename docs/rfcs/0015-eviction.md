# RFC 0015 - eviction of dead members: the leader evicts, and the dead-leader case

## Status

Discussion - opened 2026-08-29. Addresses [OQ 20](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Eviction ships as `membership.evict_after_ms` (default 0 = never): the
leader writes a `leave` for a member `unreachable` for the timer. An
evicted member's entries stay; only its seniority and its seat in
`max_members` go. The open part: who evicts under `configured` when the
leader itself is the dead member?

**Decision to make.** Who may write an eviction `leave`, and what happens
when the dead member is the one who would evict?

**Why now.** Eviction is shipped and its default is safe (never). The
dead-leader corner is the difference between "eviction works" and
"eviction is a leader's privilege that dies with the leader".

**Drivers.** Any acceptable option must:

- keep `leave` a chain fact written by an existing member (RFC 0002's
  admission authority: the chain records membership changes as entries);
- keep eviction a leader action - a follower evicting would fork the
  membership view;
- not invent a vote (PRD 0003: election is a pure function, no protocol).

**Out of scope.** Seniority on rejoin (OQ 4, RFC 0013). Key rotation
(OQ 22, RFC 0017).

## Current state

The leader writes eviction `leave`s after `evict_after_ms` of
`unreachable` (PRD 0003). Under `configured` + `stall`, a partitioned
non-authority side refuses writes - including eviction - by design. The
failure detector marks a member `unreachable` after
`cluster.suspect_after_ms`; the surviving members see the leader's state
in their fold.

## Options considered

### Option A - eviction is a leader action; the dead leader is replaced first (out-of-the-box)

- **What it is:** eviction stays a leader action. When the leader is the
  dead member, the cluster first elects (the mode's normal path: under
  `seniority` or `configured` with a live authority, the next-in-line
  becomes leader and then evicts), then evicts. Under `configured` +
  `stall` where the dead leader was the only authority, nobody is elected
  and nobody evicts - the cluster is stalled by design, and the eviction
  waits for the operator (OQ 5/RFC 0014's offline path) or the leader's
  return.
- **Pros:** no new rule; the existing election path decides; the
  dead-leader corner reduces to "the new leader does it".
- **Cons:** under `configured` + `stall` with a sole dead authority, dead
  members are never evicted automatically - but that cluster refuses
  writes anyway by design.
- **Cost to adopt:** the docs must say eviction is the current leader's
  job; no fold change.
- **Cost to leave:** none.
- **Evidence:** the shipped election and eviction paths (PRD 0003).

### Option B - any member may evict an `unreachable` member

- **What it is:** a member that observes another `unreachable` past the
  timer writes the `leave` itself.
- **Pros:** eviction survives a dead leader without an election.
- **Cons:** two members evicting concurrently write two `leave`s (both
  chain facts - the second is a no-op, but the admitter's discretion
  disappears); a partitioned follower could evict a member it merely
  cannot hear - eviction becomes a liveness-disagreement weapon (OQ 1's
  model: a member can harm only its own stream - this lets one member
  harm another's seat).
- **Cost to adopt:** a fold rule change; a trust-model weakening.
- **Cost to leave:** none.
- **Evidence:** OQ 1's trust model; RFC 0002's admission authority.

### Option C - eviction is operator-only

- **What it is:** no timer; an operator command writes the eviction
  `leave`.
- **Pros:** the dead-leader case disappears (the operator is never
  unreachable); eviction is fully deliberate.
- **Cons:** a dead member keeps its seat and seniority until an operator
  acts; the timer's automatic recovery is gone (OQ 4/RFC 0013's option C
  family).
- **Cost to adopt:** remove or disable the timer path.
- **Cost to leave:** none.
- **Evidence:** the shipped timer.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** the docs state eviction is the current leader's job.

### Medium term (3-12 months)

- **If A and a stalled `configured` cluster needs eviction:** the offline
  path (RFC 0014) is the answer.

## Recommendation

**Recommended option:** A - eviction is the current leader's action; when
the leader is the dead member, the normal election path replaces it first
and the new leader evicts. Under `configured` + `stall` with a sole dead
authority, the cluster is stalled by design and eviction waits for the
operator.

**Confidence:** 7/10

**Why this confidence.** A reuses the election path and keeps eviction a
leader privilege; what would move it: a deployment that needs automatic
eviction in the stalled `configured` corner (which would argue for C's
operator path or B's relaxation). What would sink it: evidence that B's
liveness-disagreement weapon is actually exploitable in practice - the
reason to avoid it.

**Rationale.** B weakens the trust model (one member can evict another
based on its own liveness view); C removes the timer's value; A keeps the
rule simple and the corner explicit.

**Reversibility.** A to C is disabling the timer; A to B is a fold rule
with the trust cost.

## Open questions

- None beyond the documentation wording.

## Next steps / action items

- [ ] Document that eviction is the current leader's action and that the
      stalled `configured` corner waits for the operator.
- [ ] Write the ADR once decided; update OQ 20's status.

## References

- [OQ 20](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - eviction, the
  failure detector, and the election path.
- [RFC 0014](0014-offline-reconfigure.md) - the offline path for the
  stalled corner.
