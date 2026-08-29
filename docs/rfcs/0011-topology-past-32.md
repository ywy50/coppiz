# RFC 0011 - topology past 32 members: leader-star first, gossip later

## Status

Discussion - opened 2026-08-29. Addresses OQ 25 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Full mesh is O(n²) connections: every member dials every other, and each
pair runs heartbeats and a backfill channel. clanker's research named 32 as
the point where "the surveyed products earn their weight" - the cap v1
shipped with (`cluster.max_members`, default 32). Past that cap the system
grows by more groups (PRD 0006), so a topology change is only needed inside
a group that must exceed 32 - or for the federation level, where a
"group" is the member.

**Decision to make.** What connects members when a group grows past the
full-mesh cap: leader-star, gossip (SWIM-style), or a hybrid?

**Why now.** Nothing approaches 32, so the decision is a contract: which
topology the loop is written to tolerate, so the change is a connection
policy, not a loop rewrite. The loop already assumes "a member can hear
from any member" (forward/broadcast/backfill from any peer).

**Drivers.** Any acceptable option must:

- keep the loop's existing assumption: a member may hear the same slot
  from any peer (the broadcast and backfill paths already dedup);
- preserve the failure detector's meaning: a member is `unreachable` when
  it cannot hear the member(s) it should hear - the topology defines who
  that is;
- not grow the per-member connection count with the group size beyond the
  cap it replaces.

**Out of scope.** The federation level (groups as members) - it reuses
whatever the member topology is. Cross-group discovery (OQ 53).

## Current state

Every member dials every other (the lower id dials the higher, one dialer
per pair); heartbeats run over every connection; backfill pages come from
any member (PRD 0003 *Failure detection*). `cluster.max_members` caps the
group; past it, more groups. The full mesh is O(n²) connections per group.

## Options considered

### Option A - keep full mesh, raise the cap

- **What it is:** the shipped topology; the cap is the control knob.
- **Pros:** nothing changes; O(n²) is the price of "any member can hear
  anything".
- **Cons:** the connection count and heartbeat volume grow quadratically;
  the cap exists precisely because this stops scaling.
- **Cost to adopt:** none.
- **Cost to leave:** none.
- **Evidence:** the shipped loop; the cap.

### Option B - leader-star: followers connect to the leader, backfill from any (out-of-the-box)

- **What it is:** each follower keeps one connection to the leader (plus
  occasional backfill connections to any peer when it is behind). The
  leader is the hub for broadcast; followers forward through it. Backfill
  stays "from any member" (the existing path), so a follower catching up
  is not limited to the leader.
- **Pros:** O(n) connections; reuses the existing forward/broadcast and
  backfill-from-any paths; the failure detector's job simplifies (a
  follower that cannot hear the leader is partitioned).
- **Cons:** the leader is a single point for broadcast - the exact
  serialization point the design already has for slotting, so this is a
  real but acceptable concentration; a partitioned leader side must still
  elect (the star must not make a side leaderless); follower-to-follower
  direct writes route through the leader (they already do - forwards).
- **Cost to adopt:** a connection policy in the dialer (followers dial the
  leader; leaders dial all) plus the election-under-star semantics;
  no format or loop change.
- **Cost to leave:** a policy change.
- **Evidence:** the existing forward/broadcast and backfill-from-any
  paths; PRD 0003's failure-detector design.

### Option C - gossip (SWIM-style membership with fan-out)

- **What it is:** members exchange membership/liveness via periodic gossip
  with a few peers (fan-out); connections are not a full mesh, and
  membership changes propagate probabilistically.
- **Pros:** scales beyond leader-star; no single hub; proven in large
  systems.
- **Cons:** liveness becomes probabilistic (suspect → confirm takes
  rounds); a deterministic `leader(...)` over gossip liveness is harder
  (two members may briefly disagree on who is live - the partition
  definition blurs); a real protocol to build and test.
- **Cost to adopt:** a new failure-detection and membership-gossip
  protocol - the largest of the three.
- **Cost to leave:** none.
- **Evidence:** SWIM literature; the deterministic fold's need for crisp
  liveness (PRD 0003).

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** the cap stays; nothing changes.

### Medium term (3-12 months)

- **If B:** the dialer policy and election-under-star semantics land;
  groups past 32 become possible without a protocol rewrite.

### Long term (12+ months)

- **If B then C:** gossip replaces star only if a group approaches the
  hundreds; the star is the bridge.

## Recommendation

**Recommended option:** B - leader-star as the step past the full-mesh cap,
with backfill-from-any preserved, and gossip (C) documented as the later
option if a single group ever approaches hundreds of members.

**Confidence:** 6/10

**Why this confidence.** B reuses the shipped paths and the failure
detector's meaning stays crisp; what would move it up is a real group at
or near 32 showing the star's election-under-partition behavior. What
would sink it: a group that must exceed ~100 members, where the star's
hub concentration becomes the bottleneck C exists to avoid.

**Rationale.** A's O(n²) is why the cap exists; C's probabilistic liveness
fights the deterministic fold's need for crisp partitions; B is the
smallest change that removes the quadratic term while keeping every
existing path, and C remains available behind a measured need.

**Reversibility.** B is a connection policy; reversible without format
change.

## Open questions

- Does a star's "follower cannot hear the leader" partition elect
  correctly on the follower side under every mode (seniority vs
  configured)? (simulator scenario, OQ 27)
- Is OQ 54's connection-count measurement the trigger for B (at what
  member count does the mesh start costing)? (the benchmark harness)

## Next steps / action items

- [ ] Add the star-election scenario to the simulator's list (OQ 27).
- [ ] Record the connection-count trigger in OQ 54's measurement list.
- [ ] Write the ADR once decided; update OQ 25's status.

## References

- OQ 25 (historical) - the question this RFC addresses.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - the failure
  detector, the full mesh, and the 32 cap.
- [PRD 0006](../prds/0006-scaling-to-groups-sharding-and-parity.md) - the
  growth path past the cap (more groups).
