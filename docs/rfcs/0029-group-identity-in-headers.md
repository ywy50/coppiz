# RFC 0029 - what group identity the core headers carry now

## Status

Discussion - opened 2026-08-29. Addresses [OQ 52](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

The core headers' group identity: segment headers carry the journal id and
the sequencing group id; entry headers carry the journal id but no group
id; slot headers carry neither - the slot's `leader` member id implies the
group via that group's chain. The question: is the implication enough for
a verifier in another group, or should the slot carry the group id
explicitly (16 more bytes per slot, forever)?

**Decision to make.** What group identity do the entry and slot headers
carry, before the format freeze.

**Why now.** The format freeze is PRD 0001 phase 1 - this is the last
decision on the table before slots become permanent.

**Drivers.** Any acceptable option must:

- let a verifier in another group validate a slot without a side channel:
  the group of the slot's leader must be derivable or explicit;
- keep the per-slot cost in view: 16 bytes per slot, forever, is the
  price of explicitness;
- not break the single-group case: the current headers are already
  correct there (the group is the cluster).

**Out of scope.** The segment header (already carries the group id - the
drafted shape is accepted). The grouping unit (RFC 0026).

## Current state

Segment header: journal id + sequencing group id (shipped shape). Entry
header: journal id, no group. Slot header: `leader` member id, no group.
A verifier derives the group from the leader's membership in the
federation's chains (PRD 0006: groups exchange control chains).

## Options considered

### Option A - implication via the leader's chain (status quo)

- **What it is:** the slot's `leader` member id names the member; that
  member belongs to exactly one group (its membership chain); a verifier
  with that group's control chain resolves the group.
- **Pros:** no per-slot cost; the existing headers suffice.
- **Cons:** a verifier must hold (or fetch) the leader's group control
  chain before validating - a dependency on the federation's chain
  exchange; if a member id could be ambiguous across groups, the
  implication breaks (member ids are key-derived and globally unique -
  PRD 0003 - so it cannot).
- **Cost to adopt:** none.
- **Cost to leave:** none - the format is unfrozen.
- **Evidence:** PRD 0006's chain-exchange design; member-id uniqueness.

### Option B - explicit group id in the slot header

- **What it is:** add the sequencing group id (16 bytes) to every slot.
- **Pros:** a verifier needs no chain lookup - the group is in the
  header.
- **Cons:** 16 bytes per slot, forever; redundant with the leader's
  membership (which is unique).
- **Cost to adopt:** the header grows; every slot, everywhere.
- **Cost to leave:** none.
- **Evidence:** the slot layout (PRD 0001).

### Option C - entry header carries the group id

- **What it is:** the entry (not the slot) carries the group id, since
  the entry's owner group is its home.
- **Pros:** the journal's home is explicit per entry.
- **Cons:** entries move (re-slot, ownership transfer - PRD 0006) while
  their id stays; an entry's group in the header would be the *current*
  one, which the chain already records - redundant, and wrong across a
  transfer unless updated (entries are immutable - the header cannot
  change).
- **Cost to adopt:** the header grows; the immutability rule conflicts.
- **Cost to leave:** none.
- **Evidence:** entry immutability (ADR 0002).

## Implications by horizon

### Short term (the format freeze)

- **If A:** nothing changes; the headers stay as shipped.

### Medium term (federation)

- **If A:** the verifier's chain lookup is part of federation validation
  (PRD 0006 already drafts it).

## Recommendation

**Recommended option:** A - keep the headers as shipped; the slot's
`leader` implies the group via that member's unique membership chain, and
the federation already exchanges control chains for validation. B is
redundant (member ids are globally unique); C conflicts with entry
immutability.

**Confidence:** 8/10

**Why this confidence.** Member-id uniqueness (PRD 0003) makes the
implication sound, and PRD 0006 already builds on chain exchange. What
would move it: a federation design where a verifier cannot hold the
leader's control chain - which would argue B.

**Rationale.** The 16-byte-per-slot cost buys information the chain
already provides uniquely; the only requirement (a verifier can validate
without a side channel) is met by the shipped chain exchange.

**Reversibility.** Before the freeze, free; after, a format change.

## Open questions

- None - the decision rides on member-id uniqueness, which is settled.

## Next steps / action items

- [ ] Record the decision at the format freeze (PRD 0001's status).
- [ ] Write the ADR once decided; update OQ 52's status.

## References

- [OQ 52](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) - the headers and the freeze.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - member-id
  uniqueness.
- [PRD 0006](../prds/0006-scaling-to-groups-sharding-and-parity.md) - the
  chain exchange the implication uses.
