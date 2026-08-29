# RFC 0009 - the trust model: crash faults and tamper evidence, not BFT

## Status

Discussion - opened 2026-08-29. Addresses OQ 1 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

The brief requires join order to be unspoofable "by any member" - a
partial-distrust requirement - while clanker's research rejected BFT on a
single-operator premise. The design as drafted authenticates every member
(signatures, chain) and defends against a member lying about *others* or
about *history*, but not against a member that follows the protocol and
writes garbage, nor against a coalition.

**Decision to make.** Is the line "one operator, authenticated members,
defective-not-malicious writers" (PRD 0001's non-goal) the trust model, and
what exactly does a member remain able to harm within it?

**Why now.** Every PRD assumes the line; none states the boundary of what a
member can do to the cluster. A merge rule or a `quorum` mode would change
what the line protects, so the model should be on the record before either.

**Drivers.** Any acceptable option must:

- keep join order unspoofable "by any member" (the brief's explicit
  requirement);
- keep the single-operator premise that clanker's research used to reject
  BFT - or justify reopening it;
- bound the blast radius: a defective member should be able to harm only
  what it authors, not other members' data or the chain.

**Out of scope.** Byzantine fault tolerance as a mechanism (PBFT-style
consensus). Wire encryption and key rotation (OQ 23, OQ 22) are separate
questions.

## Current state

The chain authenticates and signs everything: entries are author-signed,
slots leader-signed, and the fold refuses a forged or reordered prefix on
every member (PRD 0001). A member cannot impersonate another, cannot
rewrite history, and cannot fake its join position (RFC 0002, ADR 0005).
The failure modes treat writers as defective, not malicious: "one operator,
authenticated members, defective-not-malicious writers" (PRD 0001
non-goals, OQ 1).

## Options considered

### Option A - the drafted model: crash faults + tamper evidence (status quo)

- **What it is:** the cluster assumes one operator and authenticated
  members. A member is trusted for what it authors: it can write garbage
  into its own stream, mark its own entries stale, or leave. It cannot
  touch another member's stream, cannot rewrite the chain, and cannot
  forge its seniority. A coalition of members is outside the model.
- **Maturity:** shipped; every validation rule implements it.
- **How it would fit:** the model gets stated on the record, and the
  boundaries (below) get written into the docs.
- **Pros:** matches the brief's actual requirement (unspoofable join
  order), matches clanker's single-operator premise, and needs no new
  machinery.
- **Cons:** a compromised host that follows the protocol can still corrupt
  its own stream or refuse to participate (leave); a buggy build can
  produce garbage only its own authors see. No protection against a
  second operator.
- **Cost to adopt:** documentation only.
- **Cost to leave:** none.
- **Evidence:** the shipped chain and validation rules; clanker's research
  option R (single-operator premise, carried in research 0001).

### Option B - harden the boundary: a member can harm only its own stream

- **What it is:** Option A plus explicit limits on the self-harm: a
  per-author entry budget (OQ 61's memory/bytes bounds), refusal
  semantics for a member that floods, and the leave/stale rules as the
  only self-directed mutations. The cluster's job is to bound the damage,
  not to prevent it.
- **Pros:** turns the model's one real weakness (a garbage writer) into a
  bounded resource question; reuses the bounds OQ 55/61 already track.
- **Cons:** adds enforcement work; the flood bound is a measurement
  question (what rate is abusive) not a design one.
- **Cost to adopt:** the bounds from OQ 55/61 plus a rate rule.
- **Cost to leave:** the model stays Option A until the bounds exist.
- **Evidence:** OQ 55, OQ 61 (the size and memory bounds already drafted).

### Option C - full BFT (out-of-the-box alternative)

- **What it is:** PBFT-style consensus so a minority of malicious members
  cannot stall or corrupt the cluster.
- **Pros:** the strongest guarantee; a second operator becomes viable.
- **Cons:** clanker's research rejected it on the single-operator premise
  (research 0001); it would replace the append-only-no-consensus property
  that is the whole design's foundation (ADR 0002: replication needs no
  consensus because content never conflicts); orders of magnitude more
  machinery for a threat nobody has named.
- **Cost to adopt:** a redesign of the core.
- **Cost to leave:** none.
- **Evidence:** research 0001's BFT verdict; ADR 0002's consensus-free
  rationale.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** the model is documented; the merge rule and a future `quorum`
  mode are read against it.

### Medium term (3-12 months)

- **If B:** the per-author bounds land with OQ 55/61; the model's blast
  radius is then explicitly bounded.

### Long term (12+ months)

- **If a second operator ever appears:** that is the trigger to reopen BFT
  (option C) - the single-operator premise is the load-bearing
  assumption.

## Recommendation

**Recommended option:** A, stated as: *the cluster assumes one operator
and authenticated members; a member can harm only what it authors, and
nothing it does can falsify another member's stream, the chain's history,
or its own seniority.* Adopt B's bounds (per-author budgets) as they land,
and treat a second operator as the only condition that reopens C.

**Confidence:** 8/10

**Why this confidence.** The brief's requirement (unspoofable join order)
is fully met by A, and the only named threats - a compromised host, a
buggy build, a second operator - are each handled (self-harm bounds, B;
premise change, C). What would move it: a concrete threat model naming a
protocol-following attacker that A does not cover. What would sink it: a
requirement for multi-operator deployment.

**Rationale.** A is the only option consistent with the brief, the
research, and ADR 0002's consensus-free foundation. B strengthens the one
soft spot without changing the model; C abandons the foundation for a
threat nobody has named.

**Reversibility.** A to B is additive. A to C is a superseding decision
that reverses the core's consensus-free property.

## Open questions

- Is a per-author flood bound (Option B's rate rule) worth its enforcement
  cost before a consumer demonstrates a runaway writer? (measurement; a
  consumer)

## Next steps / action items

- [ ] Record the model in PRD 0001's non-goals and the glossary (trust
      model term).
- [ ] Read the merge rule and any future `quorum` mode against it.
- [ ] Write the ADR once decided; update OQ 1's status.

## References

- OQ 1 (historical) - the question this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) - the trust non-goal.
- [ADR 0002](../adrs/0002-entries-are-immutable-ttl-and-author-staleness-are-the-only-mutations.md) -
  the consensus-free foundation the model rests on.
- [RFC 0002](../rfcs/0002-how-join-order-is-made-unspoofable.md) / ADR 0005 -
  the brief's "unspoofable by any member" requirement, satisfied.
- research 0001 - clanker's BFT verdict (single-operator premise).
