# RFC 0032 - the archival checkpoint: bounding slot growth

## Status

Discussion - opened 2026-08-29. Addresses [OQ 24](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Under `retain = none` a removed entry still costs one slot (~170 bytes)
forever, because removing a slot breaks the chain. A long-lived,
high-churn journal needs an *archival checkpoint*: a leader-signed root
over a chain prefix that lets members drop the slots behind it while
keeping verifiability from the root. It is a second chain-level mechanism
and out of v1.

**Decision to make.** What the archival checkpoint is (its shape), and the
trigger for building it.

**Why now.** It is the only mechanism that bounds slot growth, and it is
a format-level thing - the cheap time to decide its shape is before the
format family freezes (the mechanism itself stays out of v1).

**Drivers.** Any acceptable option must:

- keep verifiability: a member that dropped the archived prefix must be
  able to prove the chain it has is consistent from the root;
- stay a chain event: the archive is a leader-signed fact every member
  folds, like a checkpoint (PRD 0002);
- not confuse itself with a snapshot (RFC 0022): the archive drops
  history; the snapshot summarizes a fold.

**Out of scope.** Snapshot serving (RFC 0022). The slot-growth
*measurement* (the trigger).

## Current state

No archive mechanism. A checkpoint removes payloads (and under
`retain = none`, headers) but never slots; the slot sequence grows
forever (PRD 0002, ADR 0002's consequence).

## Options considered

### Option A - a leader-signed root over a prefix (status quo drafted)

- **What it is:** the leader appends an *archive* control entry naming a
  prefix end (a slot position) and a root hash over that prefix; every
  member folds it, drops the slots behind the prefix, and keeps the root
  as the new chain origin. Verification of later slots chains to the
  root.
- **Pros:** the drafted shape; a chain event like every other control
  entry; bounded slot growth.
- **Cons:** a second chain-level mechanism (the OQ's own note); the root
  must cover the prefix's content in a way later verifiers can check -
  the exact hash design is the subtle part; an archived prefix is gone
  for consumers that fold from the start (they must start from a root).
- **Cost to adopt:** the control entry, the root construction, and the
  re-origin semantics.
- **Cost to leave:** slot growth is unbounded.
- **Evidence:** the OQ 24 draft; ADR 0002's growth consequence.

### Option B - keep the chain whole; rely on segment-level garbage collection

- **What it is:** drop *archived segments* (whole sealed segments behind
  a checkpoint) and keep a segment-level hash list instead of a
  per-slot chain.
- **Pros:** reuses the sealed-segment concept (PRD 0001).
- **Cons:** the chain is per-slot by design (RFC 0002's seniority is a
  slot position); a segment-level chain changes the verification unit -
  effectively the same new mechanism with a different granularity, plus
  it complicates the per-slot guarantees.
- **Cost to adopt:** the same as A with a different unit.
- **Cost to leave:** none.
- **Evidence:** PRD 0001's chain and segments.

### Option C - the measurement trigger (out-of-the-box)

- **What it is:** the decision is "A when measured": the mechanism's
  shape is A, but it is built only when a consumer's slot-growth
  measurement says the cost binds (the OQ's own "measure slot growth on
  the first consumer").
- **Pros:** nothing speculative is built; the shape is recorded.
- **Cons:** the shape decision is made now, the build waits - the format
  freeze must not preclude A (the archive entry kind must be reserved).
- **Cost to adopt:** the format reservation.
- **Cost to leave:** none.
- **Evidence:** the OQ's trigger wording.

## Implications by horizon

### Short term (v1 / format freeze)

- **If A/C:** the archive control kind is reserved in the format; the
  build waits for the measurement.

### Medium term

- **If a high-churn consumer appears:** the measurement (slot growth per
  consumer) sets the build priority.

## Recommendation

**Recommended option:** C - the shape is A (a leader-signed root over a
prefix, folded as a control entry, re-origin semantics), reserved in the
format now, and built when a consumer's slot-growth measurement says it
binds. B is rejected - it changes the verification unit for no gain over
A.

**Confidence:** 6/10

**Why this confidence.** A is the only shape that keeps verifiability and
bounded growth together; the trigger is the OQ's own. What would move it:
the first high-churn consumer's measurement. What would sink it: a
consumer that must fold from genesis forever (archive-incompatible
consumers).

**Rationale.** Slot growth is unbounded today; A bounds it as a chain
event; the trigger decides when the complexity is worth paying. The
format reservation is the only v1 cost.

**Reversibility.** A is a format addition; reserving the kind now keeps
the door open.

## Open questions

- The root construction: a Merkle root over the prefix, or a hash chain
  of the archived head? (implementation; the verifiability argument
  rides on it)

## Next steps / action items

- [ ] Reserve the archive control kind in the format freeze.
- [ ] Record the slot-growth measurement in OQ 54's list.
- [ ] Write the ADR once decided; update OQ 24's status.

## References

- [OQ 24](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0002](../prds/0002-ttl-and-staleness.md) / ADR 0002 - the growth
  consequence.
- [RFC 0022](0022-snapshot-format.md) - the sibling (snapshot) mechanism.
- [OQ 54](../open-questions.md) - the measurement list.
