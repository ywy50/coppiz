# RFC 0030 - membership and discovery at 10^5

## Status

Discussion - opened 2026-08-29. Addresses OQ 53 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

At the federation scale, a new instance must find *a* member of *some*
group to join: seed lists in local config (drafted), a directory journal
in the federation, or DNS. And it must choose which group to join
(operator-assigned, nearest, smallest).

**Decision to make.** How does a new instance discover a first member and
choose its group, at the tier-2/3 scale where seed lists stop scaling?

**Why now.** PRD 0006 phase 1 is where the overlay starts; the discovery
mechanism is its bootstrap.

**Drivers.** Any acceptable option must:

- stay inside the library (ADR 0003): no external discovery service;
- keep bootstrap minimal: a fresh instance should need one address, not a
  fleet;
- keep the group choice operator-controllable: placement is a policy
  (PRD 0006's ownership), not a guess.

**Out of scope.** Cross-group routing (RFC 0028). The group count
question (OQ 49, resolved).

## Current state

Seed lists in local config are drafted (the same mechanism a member uses
at tier 1). Nothing of the federation is implemented.

## Options considered

### Option A - seed lists, operator-assigned group (status quo)

- **What it is:** local config names one or more seed addresses and the
  group to join; the instance dials a seed, is admitted, and lands in the
  assigned group.
- **Pros:** the tier-1 mechanism, unchanged; placement is the operator's
  explicit decision; zero new machinery.
- **Cons:** at 10^5 instances, "one address" becomes "the operator
  maintains seed lists" - the scaling problem OQ 53 names; a dead seed
  list strands a fleet of fresh instances.
- **Cost to adopt:** none (drafted).
- **Cost to leave:** none.
- **Evidence:** the tier-1 seed mechanism (PRD 0003).

### Option B - a directory journal in the federation (out-of-the-box)

- **What it is:** the federation holds a control journal naming groups and
  their representatives; a fresh instance dials *one* well-known address
  (the federation's or any group's), reads the directory, and picks a
  group.
- **Pros:** one address to know; the directory is chain data (no external
  service); the group choice can be policy (smallest, nearest) over real
  data.
- **Cons:** the directory must be seeded itself (where does the *first*
  address come from? still config/DNS); the "smallest/nearest" policy
  needs the directory to carry size/location facts.
- **Cost to adopt:** the directory journal and the read-the-directory
  bootstrap.
- **Cost to leave:** none.
- **Evidence:** the federation's control journal (PRD 0006).

### Option C - DNS

- **What it is:** SRV records or a DNS lookup name a group's members.
- **Pros:** well-understood, operator-managed.
- **Cons:** DNS is an external infrastructure coppiz does not control -
  the ADR 0003 boundary; it names *members*, not *groups*, so the choice
  policy is still missing.
- **Cost to adopt:** external.
- **Cost to leave:** none.
- **Evidence:** ADR 0003's boundary.

## Implications by horizon

### Short term (PRD 0006 phase 1)

- **If A:** the seed mechanism is the bootstrap; group assignment is
  operator config.

### Medium term

- **If B:** the directory journal lands when seed lists demonstrably stop
  scaling; the first address still comes from config/DNS.

## Recommendation

**Recommended option:** A for the first federation releases - seed lists
with operator-assigned groups, the shipped tier-1 mechanism - with B (the
federation's directory journal) as the scaling answer when seed
maintenance hurts, keeping the *first* address in config/DNS either way.
C is rejected (external infrastructure, no group policy).

**Confidence:** 6/10

**Why this confidence.** A is zero-cost and B is the natural growth of
the federation's own control journal; the trigger (seed maintenance
hurting) is real but unmeasured at this scale. What would move it: the
first multi-group deployment's bootstrap experience.

**Rationale.** Discovery is bootstrap: the minimum is one address.
A supplies it with the shipped mechanism; B upgrades the directory when
the fleet outgrows seed lists; placement stays operator policy in both.

**Reversibility.** Phase 1; A to B is additive.

## Open questions

- Does the directory carry group size/location for the choice policy, or
  is placement always operator-assigned? (implementation; the policy
  needs the facts)

## Next steps / action items

- [ ] Record the bootstrap in PRD 0006 phase 1.
- [ ] Write the ADR once decided; update OQ 53's status.

## References

- OQ 53 (historical) - the question this RFC addresses.
- [PRD 0006](../prds/0006-scaling-to-groups-sharding-and-parity.md) - the
  federation's control journal.
- [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md) -
  the no-external-infrastructure boundary.
