# RFC 0028 - cross-group routing and read semantics

## Status

Discussion - opened 2026-08-29. Addresses [OQ 51](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

In PRD 0006, an append to a journal another group owns is forwarded to
the owner. A read of a non-owned journal either forwards (one round-trip,
fresh) or hits a follower copy (local, lagging). The open questions: which
is the default, and what does `write.ack` mean across groups - "owner
slotted" or "local forwarded"?

**Decision to make.** The default read path for a non-owned journal, and
what an acknowledged write guarantees across groups.

**Why now.** The semantics shape the API contract (the API takes a
journal id and never assumes the local group owns it - PRD 0005) and the
wire's ack meaning.

**Drivers.** Any acceptable option must:

- keep the append contract honest: the writer must know whether its ack
  means the owner sequenced it (PRD 0001's ack semantics, OQ 3's thread);
- keep reads useful: the local-read property (RFC 0018) should extend to
  follower copies where possible;
- not hide routing: a consumer must be able to tell a forwarded read
  from a local one.

**Out of scope.** The grouping unit (RFC 0026). Parity reads (RFC 0027).

## Current state

Nothing of the overlay is implemented. The append path is drafted as
forward-to-owner; follower copies are drafted as read-only replicas
backfilled like syncing members (PRD 0006).

## Options considered

### Option A - forward by default; ack = owner slotted (out-of-the-box)

- **What it is:** a read of a non-owned journal forwards to the owner by
  default (fresh, one round-trip); a follower copy is the explicit
  opt-in for readers that accept lag. `write.ack` means "the owner
  slotted" - the same meaning as inside a group (OQ 3's shipped slot
  ack).
- **Pros:** the default read is always fresh; the ack keeps its meaning
  (no cross-group ambiguity); the follower copy is an optimization the
  reader chooses.
- **Cons:** every non-owned read pays a round-trip unless the reader
  opted into a copy; the owner is load-bearing for reads, not just
  writes.
- **Cost to adopt:** the forward path and the ack wiring.
- **Cost to leave:** none.
- **Evidence:** PRD 0006's draft; OQ 3's shipped slot-ack.

### Option B - follower copy by default; forward on request

- **What it is:** a non-owned read hits the local follower copy by
  default (local, possibly lagging); a forward is the explicit fresh-read
  option.
- **Pros:** local reads for the common case; the round-trip is opt-in.
- **Cons:** the default read can be stale without the reader knowing -
  the trap RFC 0018's promise exists to avoid; the "read your own
  writes" guarantee breaks across groups (a write forwarded then read
  locally may not have landed in the copy).
- **Cost to adopt:** the copy-maintenance machinery as the default path.
- **Cost to leave:** none.
- **Evidence:** RFC 0018's consistency reasoning.

### Option C - ack = local forwarded; owner confirm optional

- **What it is:** the writer's ack means "the owner received it", not
  "the owner slotted it"; a stronger ack is a separate request.
- **Pros:** faster acks for latency-sensitive writers.
- **Cons:** the ack's meaning changes by group - the ambiguity OQ 3
  exists to kill; a writer that thinks it is durable when the owner only
  queued it is a silent data-loss trap.
- **Cost to adopt:** an ack contract change.
- **Cost to leave:** none.
- **Evidence:** OQ 3's thread.

## Implications by horizon

### Short term (PRD 0006 phase 2)

- **If A:** forward default, ack = owner slotted.

### Medium term

- **If copy maintenance is cheap:** B's ergonomics become an option, but
  the default stays A's freshness.

## Recommendation

**Recommended option:** A - forward by default with the ack meaning
"owner slotted", and follower copies as an explicit opt-in for
lag-tolerant readers. C is rejected (the ack meaning must not change by
group); B's staleness-by-default is the trap RFC 0018 warns about.

**Confidence:** 7/10

**Why this confidence.** A keeps every contract unambiguous (fresh reads,
one ack meaning); what would move it: a consumer whose read pattern makes
the round-trip dominant, arguing for B with a staleness indicator.

**Rationale.** The ack is the durability promise - it must mean the same
thing everywhere. The read default follows the same principle: fresh by
default, lag as an explicit choice.

**Reversibility.** Phase 2; a policy choice.

## Open questions

- Does the follower copy expose its lag (e.g. "as of slot X") so an
  opt-in reader can decide? (implementation; the natural extension of
  RFC 0018's promise)

## Next steps / action items

- [ ] Record the semantics in PRD 0006 phase 2.
- [ ] Write the ADR once decided; update OQ 51's status.

## References

- [OQ 51](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0006](../prds/0006-scaling-to-groups-sharding-and-parity.md) - the
  routing draft.
- [RFC 0018](0018-read-consistency.md) - the read promise this extends.
- [OQ 3](../open-questions.md) - the ack thread this inherits.
