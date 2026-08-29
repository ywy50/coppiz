# RFC 0010 - per-journal or cluster-level leadership?

## Status

Discussion - opened 2026-08-29. Addresses OQ 8 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

v1 ships cluster-level leadership: one leader sequences all journals, so
there is one fold, one failure detector, one epoch stream. Per-journal
leadership would spread load and isolate a hot journal, at the cost of N
elections and N failure detectors.

**Decision to make.** Is cluster-level leadership the standing design, with
per-journal leadership available only when a measured trigger shows the
single leader saturating?

**Why now.** The format and the fold are not frozen; per-journal leadership
would change what an `epoch` entry means (per-journal epochs), what the
failure detector tracks, and what a merge reconciles. Deciding the default
now, with the reopen trigger stated, costs nothing.

**Drivers.** Any acceptable option must:

- keep one fold: the fold is the deterministic state machine every member
  runs (PRD 0001), and N leader roles means N epoch streams per journal -
  a fold change;
- keep election and merge well-defined at n = 1, 2 and even n (PRD 0003's
  modes work at any size; a per-journal variant must too);
- not add machinery before a measured need (ADR 0003's "a mechanism that
  cannot be absent at size 1 needs a reason").

**Out of scope.** A `quorum` mode (roadmap). Hot-journal *isolation* via
routing (PRD 0006's ownership is the real answer to a hot journal: give it
its own group).

## Current state

`leader(mode, settings, members, liveness)` returns one member id for the
whole cluster; `epoch` is a cluster-level counter; every journal's slots
carry the cluster epoch. A hot journal slows the leader's whole write path
only insofar as the leader processes every journal's appends serially.

## Options considered

### Option A - cluster-level leadership (status quo)

- **What it is:** one leader sequences all journals; one epoch, one
  failure detector, one merge rule.
- **Pros:** the shipped shape; simplest fold; election and merge are
  single.
- **Cons:** one leader is the serialization point for every journal; a hot
  journal competes with cold ones for the same slotting loop.
- **Cost to adopt:** none.
- **Cost to leave:** per-journal epochs would be a format and fold change;
  cheap only while unfrozen.
- **Evidence:** the shipped `epoch` and `leader(...)` (PRD 0003).

### Option B - per-journal leadership

- **What it is:** each journal has its own leader, epoch and failure
  detector.
- **Pros:** load spread; a hot journal's leader is its own; a failure
  affects one journal.
- **Cons:** N elections and N failure detectors (the OQ's own cost); the
  fold tracks N epoch streams; merge must reconcile per-journal branches;
  admission and settings stay cluster-level, so the split is asymmetric.
- **Cost to adopt:** a fold and format change before freeze, or a
  compatible extension after.
- **Cost to leave:** high after freeze.
- **Evidence:** design reasoning; the PRD 0003 modes' single-epoch
  semantics.

### Option C - cluster-level now, per-journal behind a measured trigger (out-of-the-box)

- **What it is:** Option A as the shipped design, with the reopen
  condition stated: per-journal leadership is designed and built only when
  a single leader demonstrably saturates on a real workload. PRD 0006's
  ownership is the interim answer to a hot journal (move it to its own
  group).
- **Pros:** nothing speculative is built; the trigger is measurable (the
  leader's write-path utilization under a real journal mix); the
  ownership route already exists on the roadmap.
- **Cons:** if the trigger fires, the per-journal work is a format change
  done under pressure.
- **Cost to adopt:** none now; the trigger is a measurement (OQ 54's suite
  can carry it).
- **Cost to leave:** the same as A.
- **Evidence:** ADR 0003's size-1 rule; PRD 0006's ownership.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A/C:** nothing changes; the design is recorded.

### Medium term (3-12 months)

- **If C:** the measurement suite (research 0002) carries the trigger; a
  hot journal is handled by ownership.

### Long term (12+ months)

- **If the trigger fires:** per-journal leadership becomes a designed
  extension, gated on the format being extended deliberately.

## Recommendation

**Recommended option:** C - cluster-level leadership stands; per-journal
leadership is built only behind the measured trigger (a real single-leader
saturation), with PRD 0006 ownership as the interim answer to hot
journals.

**Confidence:** 7/10

**Why this confidence.** The trigger and the interim route are concrete;
what would move it up is a workload showing saturation (the measurement).
What would sink it: a consumer whose single hot journal is already at the
cap of one group, before ownership exists.

**Rationale.** A is the shipped, simplest correct shape; B's costs (N
elections, N epoch streams, per-journal merge) buy load spread nobody has
measured a need for; C gets the decision's benefit (no speculative
machinery) without foreclosing B.

**Reversibility.** C to B is a designed extension; B to A is a downgrade.

## Open questions

- Does the measurement trigger belong in OQ 54's suite (append-to-visible
  at a hot journal under a single leader)? (the benchmark harness)

## Next steps / action items

- [ ] Record the trigger in OQ 54's measurement list.
- [ ] Write the ADR once decided; update OQ 8's status.

## References

- OQ 8 (historical) - the question this RFC addresses.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - the election
  modes and the single-epoch fold.
- [PRD 0006](../prds/0006-scaling-to-groups-sharding-and-parity.md) - the
  ownership route for hot journals.
- [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md) -
  the size-1 rule.
