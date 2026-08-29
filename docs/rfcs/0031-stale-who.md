# RFC 0031 - who may mark stale beyond the author

## Status

Discussion - opened 2026-08-29. Addresses [OQ 6](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

The brief is explicit: only the author may mark its own entries stale. The
schema key `stale.who` exists so `leader` or an operator role can be added
later. The question: is there a use case (cleaning up after a dead member)
strong enough to add one?

**Decision to make.** Does `stale.who` stay `author`-only in v1, or is a
`leader`/operator role added?

**Why now.** The schema key is already in the schema with only `author`
valid; adding a value later is a schema addition, not a format break - but
the trust model (RFC 0009) should name the answer.

**Drivers.** Any acceptable option must:

- keep the brief's rule unless a real case overrides it;
- stay inside the trust model (RFC 0009): a member can harm only its own
  stream - a `leader` stale-mark would let one member hide another's
  entries.

**Out of scope.** TTL-based staleness (PRD 0002, separate cause).

## Current state

`stale.who` accepts `author` only (PRD 0002); validation refuses a
`stale` whose author is not the target's author (`not_author`). A member
that leaves or dies leaves its entries live-forever (unless TTL covers
them) - the "cleanup after a dead member" case is real.

## Options considered

### Option A - author-only (status quo)

- **What it is:** `stale.who` stays `author`; a dead member's entries are
  cleaned by TTL or left as history.
- **Pros:** the brief's rule; the trust model's blast radius holds (no one
  can hide another's entries).
- **Cons:** a dead member's stale entries persist; the operator cannot
  clean them without the member.
- **Cost to adopt:** none.
- **Cost to leave:** none.
- **Evidence:** the brief; the shipped validation.

### Option B - add `leader`

- **What it is:** the leader may mark any member's entries stale.
- **Pros:** a dead member's junk can be cleaned.
- **Cons:** the leader can hide any member's entries - a compromised
  leader (RFC 0009's model) gains the one self-harm-boundary crossing the
  model names; "cleanup after a dead member" is better served by eviction
  (RFC 0015) plus TTL.
- **Cost to adopt:** a schema value and a validation rule change.
- **Cost to leave:** none.
- **Evidence:** RFC 0009's trust model; RFC 0015's eviction.

### Option C - operator-only stale marks

- **What it is:** a distinct operator role (RFC 0017's operator key) may
  mark stale.
- **Pros:** the cleanup case is served without giving the leader new
  power.
- **Cons:** the operator key is deferred (RFC 0017); until it exists this
  is unavailable.
- **Cost to adopt:** the operator-key mechanism.
- **Cost to leave:** none.
- **Evidence:** RFC 0017.

## Implications by horizon

### Short term (v1)

- **If A:** nothing changes.

### Medium term

- **If C is built (RFC 0017):** operator stale marks become available as
  a schema value.

## Recommendation

**Recommended option:** A for v1 - `stale.who` stays `author`; a dead
member's entries are handled by eviction (RFC 0015) and TTL. If an
operator-cleanup need survives those, C (an operator-role value) is the
shape, tied to RFC 0017's operator key - not B, which crosses the trust
model's boundary.

**Confidence:** 8/10

**Why this confidence.** A preserves the brief's rule and the trust
model; the cleanup case has two other answers. What would move it: a
consumer whose dead-member junk is genuinely unmanageable by TTL and
eviction.

**Rationale.** B is the one change that lets a member hide another's
entries - exactly the boundary RFC 0009 draws. The cleanup case is real
but has cheaper answers; C is the honest future shape.

**Reversibility.** A to C is a schema value; B would need a validation
change and a trust-model revision.

## Open questions

- None beyond RFC 0017's timing.

## Next steps / action items

- [ ] Record the v1 answer in PRD 0002's schema note.
- [ ] Write the ADR once decided; update OQ 6's status.

## References

- [OQ 6](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0002](../prds/0002-ttl-and-staleness.md) - the `stale.who` key.
- [RFC 0009](0009-trust-model.md) - the boundary B would cross.
- [RFC 0015](0015-eviction.md) - the cleanup path for dead members.
