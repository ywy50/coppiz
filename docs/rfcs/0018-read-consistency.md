# RFC 0018 - read consistency: local reads and the leader-head check

## Status

Discussion - opened 2026-08-29. Addresses OQ 31 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Reads are local: every member holds the group's journals in full, so a
read never leaves the process. The question is what consistency that
buyer's view has: "read your own writes" is guaranteed for the local
member that wrote, but a consumer reading another member may be behind the
leader, and after a partition the members may disagree until the merge.

**Decision to make.** What consistency does the read API promise, and does
a consumer that needs more (a linearizable read) get a mechanism for it?

**Why now.** The read API is the surface hosts depend on; the promise
shapes what a claim/lease consumer can build on it (clanker's board fold
is tolerant; a claim store is not).

**Drivers.** Any acceptable option must:

- keep reads local by default: the "a read never leaves the process"
  property (PRD 0001) is a core cost advantage;
- make the consistency story checkable: a consumer must be able to know
  whether its view is current, not guess;
- not add a round-trip to the common case: the mechanism is opt-in.

**Out of scope.** The service API's read semantics (RFC 0007's wrapper
reuses whatever the library provides).

## Current state

`readRange`/`follow` read the local fold at the local head (PRD 0001).
The leader's head is known from the fold (the leader is the newest slot in
the local view) but nothing asks the leader for confirmation. A follower
can be behind the leader by a broadcast or two; after a partition the
sides differ until the merge re-folds.

## Options considered

### Option A - read-your-own-writes, documented (status quo)

- **What it is:** the read API promises: a consumer sees every entry the
  local member has folded, including its own writes (the author's own
  append returns only after the slot folds back locally). A read may lag
  the leader by the replication window; the API documents that.
- **Pros:** nothing changes; reads stay local; the promise is honest.
- **Cons:** a claim/lease consumer cannot know if its view is current
  without extra work; "lagging by a broadcast or two" is not a crisp
  bound.
- **Cost to adopt:** documentation.
- **Cost to leave:** none.
- **Evidence:** the shipped read path (PRD 0001).

### Option B - linearizable read as an opt-in call (out-of-the-box)

- **What it is:** a `readLinearizable` (or `headAtLeader`) call: ask the
  leader for its head, wait until the local fold reaches it, then read.
  The mechanism is a head query on the existing wire; the read itself
  stays local.
- **Pros:** the claim/lease consumer gets a crisp guarantee on demand;
  the common case (A) is untouched; the mechanism reuses the wire's head
  exchange.
- **Cons:** a round-trip on the calls that use it; "the leader's head at
  query time" is still a point-in-time view, not a serializable one (two
  linearizable reads can interleave with writes - but that is the same
  guarantee most single-writer systems offer).
- **Cost to adopt:** the head query plus the wait-until-folded logic;
  small.
- **Cost to leave:** none.
- **Evidence:** the wire already carries head information in the hello
  and sync exchanges.

### Option C - serializable reads via the leader

- **What it is:** every read goes to the leader (or takes a leader-stamped
  snapshot).
- **Pros:** the strongest guarantee.
- **Cons:** destroys the "reads never leave the process" property - the
  core cost advantage (PRD 0001); every read pays a round-trip.
- **Cost to adopt:** a read-path redesign.
- **Cost to leave:** none.
- **Evidence:** PRD 0001's read-path rationale.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A/B:** the promise is documented; B is a small addition when a
  consumer needs it.

### Medium term (3-12 months)

- **If B and a claim/lease consumer appears:** the call is built and
  tested; the guarantee is pinned by a test.

## Recommendation

**Recommended option:** A for the default promise, with B (the opt-in
linearizable read: ask the leader for its head, wait, then read locally)
as the mechanism for consumers that need it. C is rejected - it trades
away the local-read property.

**Confidence:** 7/10

**Why this confidence.** A is honest and free; B's mechanism is small and
reuses the wire. What would move it: a consumer demonstrating that the
lag window breaks a real workload (which would make B the default for
that consumer). What would sink B: the head query proving too expensive
for the reads that need it.

**Rationale.** The local read is the property that makes every member a
reader (PRD 0001). B adds the crisp guarantee exactly where a consumer
asks for it, without taxing the common case; C would tax everything.

**Reversibility.** B is additive.

## Open questions

- Does the leader-head query need to be on the operator channel (the wire
  client) or is it a member-to-member exchange? (implementation; the
  embedded host's read path would use the member-to-member form)

## Next steps / action items

- [ ] Document the read promise in PRD 0001's read path.
- [ ] Add the opt-in linearizable read when the first claim-like consumer
      appears.
- [ ] Write the ADR once decided; update OQ 31's status.

## References

- OQ 31 (historical) - the question this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) - the local read path.
