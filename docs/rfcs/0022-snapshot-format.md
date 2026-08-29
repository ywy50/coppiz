# RFC 0022 - snapshot format: a serialized fold, served to joiners behind a trigger

## Status

Discussion - opened 2026-08-29. Addresses OQ 17 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Restart and join currently replay the whole chain from genesis. A snapshot
- a verified fold at a named slot - bounds that cost. The open questions:
is it a serialized fold state or a compacted chain copy, and when may a
member serve one to a joiner?

**Decision to make.** What a snapshot is (the format), and when it may be
served (the policy).

**Why now.** Nothing ships snapshots (PRD 0001 deferred them). The format
is a versioned, on-disk thing - deciding it before the format family
freezes is the cheap time.

**Drivers.** Any acceptable option must:

- be verifiable: a joiner must be able to trust a snapshot without
  trusting the peer (the chain's verification property, PRD 0001);
- not fork the fold: a snapshot is a fold state at a slot; applying it
  must produce exactly the state replaying to that slot would;
- keep the format versioned like the rest (entry, slot, segment, wire
  all carry versions, OQ 26).

**Out of scope.** Serving snapshots across the wire in v1 (the sync path
serves slots; snapshots are for restart and join later). The archival
checkpoint (OQ 24, RFC 0026) - a different mechanism.

## Current state

`Node.open` folds every chain from genesis (`foldAll`); a joiner backfills
slots from any member. The fold state is already a concrete struct
(`chain.FoldState` and the per-journal `JournalState`), and every record
is chain-verified. There is no snapshot file and no snapshot serving.

## Options considered

### Option A - serialized fold state (out-of-the-box)

- **What it is:** a versioned serialization of the fold state (members,
  settings, per-journal heads and entry tables) plus the slot it was
  taken at and the chain hashes up to it, so a loader verifies the
  snapshot's prefix against the chain before trusting it.
- **Pros:** the smallest file; restart is a decode, not a replay; the
  fold state is already a struct - serializing it is natural.
- **Cons:** the struct is the format - any fold change bumps the snapshot
  version; a joiner still needs the chain *after* the snapshot (the
  snapshot replaces genesis-to-slot, not the tail).
- **Cost to adopt:** the codec, the load-verify path, and the version
  coupling to the fold struct.
- **Cost to leave:** replay from genesis stays the only path.
- **Evidence:** the existing fold structs (PRD 0001).

### Option B - compacted chain copy

- **What it is:** a snapshot is the chain up to a slot, with payloads
  stripped (header-only records, the `retain = header` shape).
- **Pros:** reuses the segment codec and the chain verification exactly -
  no new format concept.
- **Cons:** it is not a snapshot, it is the chain minus payloads: restart
  still replays, and the size saving is bounded by the payload fraction.
- **Cost to adopt:** small; but it does not deliver the "restart does not
  replay" property.
- **Cost to leave:** none.
- **Evidence:** the `retain` shapes (PRD 0002).

### Option C - both: serialized fold for restart, slots for joiners

- **What it is:** A for local restart; joiners keep backfilling slots
  (the shipped path), with snapshots served only when a measured join
  cost says the slot path is too slow.
- **Pros:** the smallest change delivers the restart win; the join policy
  is gated on measurement (OQ 54's join/backfill time for a 1 GB
  journal).
- **Cons:** two code paths to keep; the serve policy is deferred.
- **Cost to adopt:** A plus the measured trigger.
- **Cost to leave:** none.
- **Evidence:** OQ 54's join/backfill measurement.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A/C:** nothing ships; the format is decided.

### Medium term (3-12 months)

- **If C:** restart uses the snapshot; join serving is gated on the
  measured cost.

## Recommendation

**Recommended option:** C - a serialized fold state (A) as the snapshot
format for restart, with join-serving of snapshots gated on a measured
join/backfill cost (the slot path stays the shipped behavior until then).
B is rejected - it does not deliver the property the feature exists for.

**Confidence:** 6/10

**Why this confidence.** The format choice is clear (A over B); the
policy half is gated on a measurement that does not exist yet. What would
move it: the OQ 54 measurement showing join cost. What would sink it: the
fold struct proving too churny to serialize stably.

**Rationale.** Restart is the immediate cost (every `open` replays);
joiners are rare and the slot path is shipped. A delivers the restart
win with the least new machinery; the serve policy waits for data.

**Reversibility.** The snapshot format is versioned like the rest (OQ 26);
adding serve later is additive.

## Open questions

- Does the snapshot need the full entry table, or only the fold's
  summary (heads, settings, members) with entries re-fetched from the
  chain? (implementation; the table is what makes reads cheap)

## Next steps / action items

- [ ] Decide the serialized-fold codec when the format family freezes.
- [ ] Record the join-cost trigger in OQ 54's measurement list.
- [ ] Write the ADR once decided; update OQ 17's status.

## References

- OQ 17 (historical) - the question this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) - the fold and the deferral.
- [OQ 54](../research/0007-tier-number-measurements.md) - the join/backfill measurement.
- [OQ 24](0032-archival-checkpoint.md) - the sibling chain-level
  mechanism (archival checkpoint, to become an RFC).
