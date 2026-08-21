# RFC 0002 — How join order is made unspoofable

## Status

Discussion — opened 2026-08-21. Blocks [PRD 0003](../prds/0003-membership-and-leadership.md)'s
`seniority` mode; the PRD is drafted on option A below and will follow this
RFC's decision.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

**Decision to make.** By what mechanism does every member agree on the order
in which members joined, such that no member can present itself as having
joined earlier than it did?

**Why now.** The brief (2026-08-21) makes "who joined earliest leads" a
first-class election mode precisely because it works at n = 1 and n = 2 where
quorum does not — and states the requirement that it "cannot be spoofed by any
member to falsify their join date". Leadership is the most valuable thing a
member can gain by lying, so this mechanism is the security core of the mode.

**Drivers.**

1. Agreement: every member must compute the same order from the same data,
   offline, without asking anyone.
2. Unforgeability: a member cannot improve its own position, alone or with the
   cooperation of a minority.
3. No external authority: the mode exists for clusters with no configured
   leader list (that is `configured` mode's job).
4. Cheap: evaluated on every election and every `join` validation.
5. Survives restarts, partitions and merges without the order changing.

**Out of scope.** Who *admits* a member (PRD 0003 admission). Whether
seniority resets on rejoin ([OQ 4](../open-questions.md)).

## Current state

No implementation. The naive design — each member reports its own join
timestamp and the earliest wins — is the status quo to beat and is option E.

## Options considered

### Option A — Join is a chain entry; seniority is its slot position

- **What it is:** a member's `join` is a control entry written by an
  *existing* member (the admitter) and sequenced by the leader into the
  hash-chained, leader-signed slot sequence ([PRD 0001](../prds/0001-ledger-core.md)).
  Seniority = the `(epoch, seq)` of that slot; the founder's is the `genesis`
  slot. Time plays no part; order is position.
- **Maturity:** the mechanism is the ledger itself — nothing additional.
  Append-only logs as membership records is how Raft handles configuration
  changes (membership entries in the log) and how permissioned ledgers record
  enrolment.
- **How it would fit:** PRD 0003 as drafted. Validation of `join` on every
  member; seniority read from the fold.
- **Pros:** drivers 1–5 all met by properties the chain already has. A member
  cannot write its own `join` (no member holds its key until the `join` is
  slotted, so anything it signs before is refused). It cannot move its `join`
  earlier: that requires a different chain prefix, which every other member's
  `prev_slot_hash` contradicts. A minority cannot help it: their copies are
  also contradicted by the majority's and by any archived branch. No clocks.
  Free at election time (one table lookup in the fold).
- **Cons:** the *admitter* decides the position by deciding when to write
  the `join` — an admitting leader can delay a newcomer to slot a friend
  first. This is inherent to any admission scheme and is bounded: the
  admitter can only reorder *concurrent* joins, never place anyone before an
  already-slotted member. During a partition, two branches may each admit
  members; merge re-slots the losing branch's joins *after* the survivor's,
  so a member admitted on the losing side ends up junior to everyone admitted
  on the winning side during the partition — deterministic, but possibly
  surprising. Both are documented in PRD 0003.
- **Cost to adopt:** zero beyond PRD 0001.
- **Cost to leave:** the `join` kind and the seniority fold; low.
- **Evidence:** design reasoning over PRD 0001's chain properties; Raft's
  membership-change-as-log-entry (Ongaro & Ousterhout, *In Search of an
  Understandable Consensus Algorithm*, §6) — `unverified` here in the sense
  that the paper was not reopened for this RFC; the claim is well known.

### Option B — Leader-issued join certificates with timestamps

- **What it is:** the leader signs a certificate `(member, pubkey, joined_at)`
  at admission; members present certificates; earliest `joined_at` leads.
- **Pros:** works without a total order; a certificate is self-contained.
- **Cons:** trusts the issuing leader's clock and honesty — a leader can
  back-date a friend; a member cannot verify a certificate it was not present
  for without the chain anyway; certificate revocation on `leave` needs its
  own mechanism; two leaders during a partition issue incomparable
  certificates with comparable-looking timestamps, so merge has no
  deterministic rule.
- **Cost to adopt:** a certificate format, store, and revocation list — all
  things the chain already is.
- **Evidence:** design reasoning.

### Option C — Timestamp gossip with agreement (median / quorum of witnesses)

- **What it is:** every member records when it *saw* each newcomer; the
  agreed join time is the median of witnesses' observations.
- **Pros:** no single authority.
- **Cons:** a witness can lie about what it saw; at n = 2 the median is one
  of the two opinions, so it solves nothing at exactly the size the mode
  exists for; clock-based, so skew is part of the answer; still needs a
  deterministic tiebreak that is not time.
- **Evidence:** design reasoning.

### Option D — Seniority from an external authority (DNS / config order)

- **What it is:** order is the `authorities[]` list.
- **Cons:** this *is* `configured` mode (PRD 0003); it answers a different
  need and is not automatic (driver 3).

### Option E — Status quo: self-reported join time

- **What it is:** each member states its own join time; earliest wins.
- **Pros:** trivial.
- **Cons:** spoofable by construction; fails the brief's requirement in one
  sentence.

### Option F — Out of the box: verifiable delay

- **What it is:** seniority is proven by work — a verifiable delay function
  output chained from genesis, so an earlier position literally takes longer
  to have computed.
- **Cons:** proves elapsed computation, not join order; a member with a
  faster machine is "older"; wasteful; answers the question the chain answers
  for free.
- **Evidence:** design reasoning; rejected lead kept deliberately.

## Implications by horizon

### Short term (0–3 months)

- **If A:** nothing extra to build; seniority falls out of PRD 0001's fold.
- **If B/C:** a parallel membership mechanism beside the chain.

### Medium term (3–12 months)

- **If A:** admitter-ordering and partition-merge surprises are the support
  questions; both are documented and deterministic.
- **If B:** clock-trust incidents; revocation bugs.

### Long term (12+ months)

- **If A:** the chain remains the single source of truth for membership,
  which keeps the `quorum` mode (roadmap) implementable as log-based
  configuration change in the Raft style.

## Recommendation

**Recommended option:** A — join is a chain entry; seniority is slot position.

**Confidence:** 8/10

**Why this confidence.** Raises: an adversarial test (PRD 0003 e2e (e)) where
a member replays a forged earlier `join` and every member refuses it; a
partition test where joins on both sides merge deterministically. Sinks: a
requirement that joins be orderable *across* a partition by real time rather
than by branch (that would need B's timestamps and their trust problem);
finding that admitter delay is abused in practice.

**Rationale.** A is the only option that needs no clock, no extra authority
and no extra store, and it is the only one that is unforgeable against a
minority rather than merely against an outsider. Its weaknesses — admitter
ordering of concurrent joins and branch ordering at merge — are bounded and
deterministic, which B and C's are not.

**Reversibility.** Low cost either way while the format is unfrozen; after
1.0, seniority semantics are a compatibility promise.

## Open questions

- Should concurrent `join`s within one leader's batch be ordered by the
  admitter's receipt order or by newcomer id, to remove the admitter's
  discretion entirely? (the operator; cheap to decide either way)
- Seniority on rejoin ([OQ 4](../open-questions.md)).

## Next steps / action items

- [ ] Comment period: the operator, before PRD 0003 phase 1.
- [ ] Write PRD 0003 e2e (e) as the acceptance test of this decision.
- [ ] Write the ADR once decided.

## References

- [PRD 0001](../prds/0001-ledger-core.md) — chain, slots, control kinds.
- [PRD 0003](../prds/0003-membership-and-leadership.md) — the mode this
  serves.
- Raft membership changes as log entries — Ongaro & Ousterhout 2014, §6
  (not reopened for this RFC).
