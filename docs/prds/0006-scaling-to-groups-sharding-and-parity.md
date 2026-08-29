# PRD 0006 - Scaling 1 → n → groups: recursive groups, sharding, and parity

## Status

Draft - 2026-08-21, from the operator's big-picture statement of the same
day. This PRD is **mostly later work**, and that is the point of writing it
now: it names what the core (PRDs 0001–0004) must get right *today* so that
the overlay can be added without redesign, and it parks everything else
behind measured triggers. Nothing here ships before the single-group system
is green. Source of truth once shipped: `src/federation/` (group membership,
routing, parity) - a name chosen now so no one puts it in `src/cluster/`.

## Problem

The big picture, in the operator's words (2026-08-21): natural scalability
from 1 to n, "no matter if even or uneven number"; fast and very slim to get
started; and still running efficiently at 1,000, 10,000 or 100,000
instances.

Past a certain size the flat design cannot do that - a full mesh
is O(n²) connections and every member holding every byte is O(n) copies of
everything - so the operator's later overlay is: **group** instances, where
each group is *exactly the system built now* with its own leader election
inside; make a group the leader for a specific part of the journal
(sharding); and, to save space, break the journal down across groups with
**data parity** instead of full copies. Groups use the same leadership
modes and concurrency model as members do, so no particular group count is
required - confirmed 2026-08-21, [OQ 49](../open-questions.md) resolved.

The risk this PRD exists to prevent: a core that quietly assumes "one
cluster, one chain, every member has everything" in a place that is
expensive to change - an id format, a header, a validation rule, a routing
assumption in the API. Those assumptions are cheap to avoid now and
prohibitive after the on-disk and wire formats freeze.

## Goals

1. Getting started costs one dependency, one directory, one process, and
   an append at size 1 is a local disk write, not a network round-trip.
2. A group of 2–32 members is the fully designed system (PRDs 0001–0004);
   the even/uneven property holds inside it.
3. Groups compose recursively: a cluster of groups is the same system with
   groups as members, so the membership, election and settings machinery is
   reused rather than reinvented at the next level.
4. A journal (or a range of one) can be *owned* by one group - that group's
   leader sequences it, that group's members replicate it in full - and
   other groups route to it rather than copy it.
5. A journal can optionally be stored with parity across groups, so k of m
   groups can reconstruct it, trading copies for reconstruction cost.
6. Per-member cost grows with the size of *its group* and the number of
   *groups*, never with the total instance count: no member keeps per-member
   state for 100,000 peers.
7. Every step is a settings change on a running system, never a redeploy
   ([PRD 0004](0004-settings.md)).

## Non-goals

- **No global total order across groups.** Each owned journal has its chain;
  there is no cross-group chain in v1 of the overlay. A consumer that needs
  one puts its data in one journal.
- **No automatic rebalancing of journals between groups in the first
  overlay release.** Ownership moves by an operator-visible settings change.
- **No cross-group transactions.** Append-only, one journal, one group.
- **Nothing here before the single-group system is green and measured.**

## Design

### Scale tiers

The same binary and the same settings schema at every tier; what changes is
which mechanisms are switched on. Numbers are the *design intent* - where a
mechanism is expected to be needed - not measurements; the first
measurements replace them ([OQ 54](../open-questions.md)).

| Tier | Instances | Topology | What is new at this tier | PRD |
|---|---|---|---|---|
| 0 | 1 | none | a directory; own leader; no listener | 0001, 0002, 0004 |
| 1 | 2–32 | one group, full mesh | membership, election, replication, merge | 0003 |
| 2 | 32–~1,000 | several groups; each a tier-1 group | group membership, journal ownership, routing | this PRD, phase 1–2 |
| 3 | ~1,000–100,000 | groups of groups | recursive membership; leader-star or gossip inside large groups | this PRD, phase 3; OQ 25 |
| parity | any, with tier ≥ 2 | - | k-of-m storage across groups for selected journals | this PRD, phase 4 |

### A group is the system

A **group** is a cluster as PRD 0003 defines it: its own `genesis`, its own
members with seniority, its own leader under its own `leadership.mode`, its
own chains. Nothing in a group knows it is part of something larger except
one thing: its **group identity** (a 128-bit id derived from its genesis
hash) and, when federated, the address of the **federation** it belongs to.

A **federation** is a cluster whose members are groups. It is run by the
same code: the federation's `genesis` is written by the founding group, a
group joins with a `join` entry authored by an existing member group, group
seniority is that slot, and the federation's leader - the group whose leader
speaks for it - is chosen by the same `leader(mode, settings, members,
liveness)` function over groups. A group is *represented* in the federation
by its current leader; when the group's leader changes, the representative
changes, the group's seniority does not. The federation holds one control
journal: group membership, journal ownership, and federation-level settings.

Its entries are signed by the representing leader's member key, and
validation accepts a group's entry only from a member the group's own chain
currently names leader - which is checkable because the group's membership
chain is readable by the federation (groups exchange their control chains,
not their data).

This recursion is what makes the even/uneven question disappear at the
group level too: a federation of 2 groups elects under `seniority` or
`configured` exactly as 2 members do. An uneven group count would be needed
only under a future majority-vote `quorum` mode at the federation level;
under the three shipped modes it is not (OQ 49, resolved 2026-08-21).

What *is* different one level up is that a group's liveness and leadership
are derived, not direct, and two rules follow. **Validation looks into the
group's chain:** a federation entry signed by group B's representative is
accepted only if B's own membership chain, as the validator last saw it,
names that member B's leader - otherwise any member of B could speak for B.
Groups therefore exchange their *control* chains (membership, epochs), which
are small, never their data.

**Representative churn must not read as
death:** a group re-electing internally is briefly silent at the federation
level, so `federation.suspect_after_ms` must exceed a group's internal
election time (`cluster.suspect_after_ms` plus one epoch handover), or a
healthy group is marked unreachable every time its leader rotates.

### Ownership: a group is leader for part of the journal space

The unit of ownership is a **journal** (the chain-per-journal choice in
[OQ 7](../open-questions.md) is what makes this clean: a journal is a
self-contained chain that can live in one group). The federation's control
journal maps `journal id → owning group`. Inside the owning group, nothing is
different from tier 1: that group's leader sequences, its members hold the
full chain. Other groups hold *no copy* of that journal - they hold the map.

A consumer anywhere appends to journal L by handing the entry to its local
member; the local member looks up L's owner, forwards to that group's
leader, and returns when the owner acknowledges (the `write.ack` setting is
honoured by the owning group). Reads of a journal the local group does not
own are forwarded the same way, or served from a **follower copy** the local
group has chosen to keep (a read-only replica, backfilled like any syncing
member, never sequencing) - the per-journal setting `replicate.followers`
names which groups keep one.

A journal that is too hot for one group is split by **range**: `journal id +
range key → group`, where the range key is a prefix of the author id (so
one author's stream stays in one group and `author_seq` stays dense). That
is the first form of sharding and is enough for the single-writer-per-stream
shape every known consumer has; arbitrary range splits are later.

Ownership moves by a federation `settings` entry (`journal.owner = group`);
the old owner freezes the chain at a slot, the new owner backfills to it,
appends an `epoch` with `reason = ownership_transfer`, and continues. The
old owner may keep a follower copy or drop it by its retention setting.

### Parity: copies versus reconstruction

Full replication inside a group is k = m: every member has everything. For
cold or large journals the operator's "break the journal down and have data
parity" is erasure coding across groups: segments of a journal's chain are
encoded into m fragments of which any k reconstruct, and each of m groups
stores one fragment (inside the group, that fragment is replicated as
usual).

Reads of a parity-stored range need k groups reachable; appends go
to the owning group's live head as before and are encoded into fragments
only once a segment is sealed (it is behind the head and will never change,
which is what append-only buys here). The chain is unaffected: fragments
are of sealed bytes whose slot hashes already exist, and a reconstructed
segment verifies against them.

Parity is a per-journal setting (`storage.parity = {k, m}`) applied to
sealed segments older than `storage.parity_after`; the live tail is always
fully replicated in the owning group. Reed–Solomon over GF(2⁸) is the
obvious code and is implementable with the standard library ([ADR
0001](../adrs/0001-zig-0-16-standard-library-only-for-the-core.md)); whether
it is the right choice is [OQ 50](../open-questions.md).

### What the core must get right now

These are the items PRDs 0001–0004 carry on this PRD's behalf. Each is
cheap today and a format break later.

| Now | Why | Where |
|---|---|---|
| Chain per journal, not per cluster | a journal is the unit of ownership and of parity; a cluster-wide chain could not be split | OQ 7 → resolve as per-journal |
| Journal ids are globally unique (128-bit, random or hash-derived), never small integers or per-cluster counters | a journal must keep its id when its owner changes or when a group joins a federation | PRD 0001 header |
| Member ids are derived from keys, group id from the genesis hash | identities must be meaningful outside the group that minted them | PRD 0003 |
| `author_seq` dense per `(author, journal)` and the author id is the range key | one author's stream is always in one group; range splits by author prefix need no renumbering | PRD 0001, this PRD |
| Validation is a pure function of `(slot, entry, folded state)` | the federation validates a group's control entries with the same function, over that group's chain | PRD 0001 |
| Election is a pure function over an abstract member set | the federation elects over groups by calling it with groups as members | PRD 0003 |
| Settings have a scope; add `federation` as a third scope alongside `cluster` and `journal` *now* so the schema does not need a breaking change | ownership map and federation mode live there | PRD 0004 |
| Per-member state is bounded by group size plus group count | no table keyed by every instance in the world | PRD 0003 failure detector; this PRD G6 |
| Backfill is from *any* member, paged, chain-verified | a follower copy in another group and a reconstructed parity segment both arrive this way | PRD 0001 |
| Sealed segments are immutable files with a known hash | the parity unit | PRD 0001 storage |
| The read/append API takes a journal id and never assumes the local group owns it | forwarding is an implementation detail, not an API change | PRD 0005 |
| Segment files carry the journal id and the owning group id in their header | a segment moved between groups (ownership transfer, parity reconstruction) is self-describing | PRD 0001 storage |

**Dependencies.** The whole single-group system green and measured (ROADMAP
steps 1–8); OQ 7, 25, 48, 50, 51, 52, 53 decided (OQ 49 already is).

**Implementation** (each phase behind a measured trigger named in the
roadmap):

1. `src/federation/membership.zig` - group identity, federation genesis and
   join, representative validation against the group's chain. Reuses
   `src/cluster/membership.zig` and `election.zig` unchanged by
   parameterising their member type. Trigger: a deployment that needs more
   than one group.
2. `src/federation/ownership.zig`, `src/federation/route.zig` - the owner
   map, forwarding, follower copies, ownership transfer. Trigger: same.
3. Range split by author prefix; leader-star or gossip inside large groups
   (OQ 25). Trigger: a group at `max_members`, or a journal too hot for one
   group.
4. `src/federation/parity.zig` - sealed-segment encoding, fragment
   placement, reconstruction on read. Trigger: storage cost measured as the
   binding constraint.
5. Federation-level simulator scenarios (OQ 27): group partition, ownership
   transfer mid-write, k-1 groups reachable.

## Failure modes

| Condition | Behaviour |
|---|---|
| Owning group entirely unreachable | appends to its journals return `owner_unreachable`; reads serve from a follower copy if one exists, else fail; other journals unaffected - a dead group strands only its own journals |
| Owning group's leader changes | the group's internal epoch handles it; forwarders retry at the new leader; the federation's representative updates on the next heartbeat; the federation does not suspect the group because its `suspect_after_ms` exceeds the group's election time |
| A non-leader member of a group signs a federation entry | refused `not_representative`: the validator's copy of that group's control chain does not name the signer as leader |
| Ownership transfer interrupted | the chain is frozen at a slot on the old owner; the new owner either completes backfill and opens its epoch, or the federation reverts the map entry; the slot is never sequenced by two owners because the freeze is a chain event |
| Fewer than k groups reachable for a parity range | reads of that range fail `insufficient_fragments`; the live tail and other ranges unaffected |
| A group forks internally (partition + merge) | invisible to the federation, which only sees the group's chain after merge; a federation entry signed by a leader the post-merge chain does not name is refused |
| Federation control journal partitions | it is a cluster: its own mode decides stall or two branches + merge |

## Acceptance criteria

- [ ] (G1) Size-1 append latency is measured as local disk write cost with
  no socket opened; reported with the first measurement set ([OQ
  54](../open-questions.md)).
- [ ] (G2) PRD 0003's acceptance criteria pass unchanged when the cluster
  is a member of a federation.
- [ ] (G3) Federation membership and election are the same source files as
  group membership and election (a test imports both and asserts they are
  the same functions over different member types).
- [ ] (G4) Two groups, one journal owned by each; a consumer on either group
  appends to and reads from both; the non-owning group holds no copy.
- [ ] (G5) A journal stored with `{k=2, m=3}` across three groups reads
  correctly with any one group down, and fails named with two down.
- [ ] (G6) Per-member memory and connection count, measured at 3 groups ×
  8 members, grow with group size and group count and not with instance
  count (a test asserts no table keyed by foreign members).
- [ ] (G7) Every transition above is a `settings` entry on a running system;
  no test restarts a process to change tier.

## Open questions / future work

All in [the register](../open-questions.md): grouping unit and range key
(OQ 48), the parity code and
its reconstruction cost (OQ 50), cross-group routing and read semantics
(OQ 51), what group identity the core headers must carry now (OQ 52),
membership and discovery at 10⁵ instances (OQ 53), and the measurements that
replace the tier numbers (OQ 54). OQ 49 (uneven group count) is resolved -
see *A group is the system* above.
