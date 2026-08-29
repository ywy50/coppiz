# RFC 0034 - failure-detector timings and the leader lease

## Status

Discussion - opened 2026-08-29. Addresses OQ 37 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Heartbeat 1 s and suspect at 5 s are placeholders. The design half: is
there a leader *lease* - the old leader stops slotting when it cannot hear
a majority of its last-known members - or does it keep slotting until it
sees a newer epoch? Without a lease, a leader partitioned from everyone
keeps writing on its own branch - the AP behaviour.

**Decision to make.** Whether a leader lease exists, and what the
placeholder timings' settlement path is.

**Why now.** The timings are on the record as placeholders (PRD 0003);
the lease is the one design question among them, and it changes what
"partition" means for the leader's own writes.

**Drivers.** Any acceptable option must:

- stay consistent with the AP posture (OQ 2 resolved: `seniority` with
  merge on heal) - a lease that stops the leader from writing is a CP
  intrusion unless it is the mode's choice;
- keep election a pure function (PRD 0003): liveness is the input, and
  the lease must not introduce a new protocol;
- keep the timings' derivation measured, not guessed.

**Out of scope.** The timings' *values* (a measurement, not a decision -
OQ 37's placeholder note).

## Current state

A leader slots until it sees a newer epoch; a partitioned leader keeps
writing on its branch, and merge reconciles on heal (PRD 0003). The
failure detector runs on heartbeats over the mesh; the timings are
placeholders.

## Options considered

### Option A - no lease; slot until a newer epoch (status quo)

- **What it is:** the leader's right to write ends only when it sees an
  epoch it did not author. A partitioned leader keeps slotting its own
  branch.
- **Pros:** the AP posture intact (OQ 2); no new mechanism; merge is the
  reconciliation.
- **Cons:** a leader partitioned from everyone writes an unbounded
  branch until heal - the branch is then merged, so the cost is the
  merge size, not correctness.
- **Cost to adopt:** none.
- **Cost to leave:** none.
- **Evidence:** the shipped epoch/merge semantics; OQ 2's resolution.

### Option B - a leader lease: stop when a majority is unheard

- **What it is:** the leader stops slotting when it cannot hear a
  majority of its last-known members, even without seeing a newer epoch.
- **Pros:** bounds the partition branch; a lone leader cannot write
  unboundedly.
- **Cons:** it is the CP posture (refuse writes rather than risk two
  leaders) - the opposite of OQ 2's resolved AP default; a "majority of
  last-known members" is a liveness query the pure-function election
  does not have (it needs a quorum count - a protocol addition); the
  merge already bounds the branch at heal.
- **Cost to adopt:** a new liveness rule and its partition semantics.
- **Cost to leave:** none.
- **Evidence:** OQ 2's resolution; PRD 0003's pure election.

### Option C - lease as a mode setting (out-of-the-box)

- **What it is:** the no-lease behavior is the default (A); a
  `leadership.lease = on` setting gives CP-inclined clusters the B
  behavior, selectable per cluster like the other modes.
- **Pros:** both postures available without changing the default; the
  mode machinery already exists.
- **Cons:** B's protocol cost (the majority liveness query) must be
  paid for the setting to exist; the interaction with `configured` +
  `stall` (which already refuses writes without a live authority) needs
  spelling out.
- **Cost to adopt:** the setting and the liveness rule.
- **Cost to leave:** none.
- **Evidence:** the settings machinery (PRD 0004).

## Implications by horizon

### Short term

- **If A:** the timings' settlement is measurement-only (OQ 54).

### Medium term

- **If C:** a CP-inclined cluster opts in; the default stays AP.

## Recommendation

**Recommended option:** A - no lease; the leader slots until it sees a
newer epoch, and the partition branch is bounded by the merge at heal.
C (a lease as an opt-in setting) is the shape if a cluster wants CP
behavior, but it is not the default and carries B's liveness-query cost.
The timings themselves are a measurement question (OQ 54), not a
decision.

**Confidence:** 7/10

**Why this confidence.** A is the resolved AP posture's natural reading
and needs no new mechanism; what would move it: a consumer whose merge
branches are unacceptably large (arguing for C).

**Rationale.** A lease is a quorum liveness rule - the CP answer to a
question OQ 2 already answered AP. The merge bounds the damage; the
opt-in setting (C) serves the clusters that want the other posture
without changing the default.

**Reversibility.** A to C is a setting; A to B would change the default.

## Open questions

- If C is built, how does its majority query interact with
  `configured` + `stall` (which already refuses without a live
  authority)? (implementation)

## Next steps / action items

- [ ] Record the timings' measurement in OQ 54's list.
- [ ] Write the ADR once decided; update OQ 37's status.

## References

- OQ 37 (historical) - the question this RFC addresses.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - the epochs and
  the failure detector.
- [OQ 2](../prds/0003-membership-and-leadership.md) - the resolved AP default.
- [OQ 54](../research/0007-tier-number-measurements.md) - the measurement list for the timings.
