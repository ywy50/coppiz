# PRD 0003 - Membership and leadership: seniority, configured authorities, and scaling 1 → n

## Status

Draft - 2026-08-21. Depends on [PRD 0001](0001-journal-core.md) (control
kinds `genesis`, `join`, `leave`, `epoch`, `merge`; slots; chain) and
[PRD 0004](0004-settings.md) (`leadership.*` settings and the
`reconfigurable` gate). The unspoofable-join mechanism it relies on is argued
as [RFC 0002](../rfcs/0002-how-join-order-is-made-unspoofable.md); this PRD
states the design the RFC recommends and will follow the RFC's decision.

Phases 1–3 shipped 2026-08-27, on the RFC's decision ([ADR
0005](../adrs/0005-join-order-is-slot-position.md), option A): the pure
membership fold, the election function, and the epoch/merge rules, plus the
deterministic simulator that drives them (OQ 27).
Source of truth: `src/cluster/membership.zig`, `src/cluster/election.zig`,
`src/cluster/epoch.zig`, the `join`/`leave`/`epoch`/`merge` rules wired into
`src/journal/chain.zig`, and `src/sim/sim.zig` (the deterministic simulator). OQ 58 (concurrent-join ordering) and OQ 33 (settings at merge) resolved
with the drafted defaults (admitter receipt order; losing-side `settings`
re-slotted as no-ops).

Phases 4–6 shipped 2026-08-27, on OQ 19 decided
(own binary framing over one TCP connection): the replication wire
(`src/net/` - framing, the message set, and a transport seam with a TCP and
an in-memory hub implementation, so the same loop runs under both), and the
node loop (`src/cluster/node.zig` - failure detector, election → epoch,
admission with `allowlist`/`open`/`prompt`, forward/broadcast/backfill, and
the partition/merge with the OQ 44 re-fold discipline).

The `coppiz serve`
CLI with every command falling back to the wire when the data directory is
locked, and the e2e matrix of *Acceptance criteria* below (process-level (a)
(d) (e); (b) and (c) in-process over the hub transport with real stores and
real loops).

The fold infers a re-slot from its author and epoch
(`chain.zig applyControl`), so a merged chain replays identically after a
restart without a side channel. The embedded-host write API shipped with
it (`cluster.ClusterNode.localAppend`, PRD 0005 step 1). Remaining: the
simulator driving the loop itself (OQ 27's second half), and the open
questions the matrix names.

Known issue, found 2026-08-27 while exercising the loop from
`examples/embed-cluster`: a **three-member partition that elects a second
leader does not reliably converge on heal** - the survivor's branch fetch
or the losers' re-sync can stall without retry (the two-member merge, e2e
(b), converges; three members - two losers - surfaced a stall). The e2e
matrix's (b) is two-member; the three-member merge needs the simulator over
the loop (OQ 27's second half) and a deterministic scenario before it can
be pinned. Reported rather than silently worked around: the embed-cluster
example's partition stays short enough to avoid the election.

One implementation note the simulator pinned down ([OQ 44](0002-ttl-and-staleness.md)):
a merge converges only if every node **re-folds from the last common slot** -
the losing branch's entries re-slot as no-ops for the *survivor's* fold, but
cannot undo what the loser already folded (a settings change, a join), so
the loser must discard its branch and fold the merged chain from the common
prefix. That is a fold *discipline* the node loop must implement; it is not
a fold rule.

## Problem

The brief (2026-08-21) asks for a store that runs as one process and scales
from there without a redeploy - and names the failure of the usual answer:
Raft-style quorum needs an odd count and a majority, so two instances cannot
elect, and one instance is a degenerate cluster. Instead of quorum, the brief
asks for leader election modes an operator can reason about at every size:

- **seniority** - whoever joined the journal earliest leads; the order of
  joining must be automatically detected and *unspoofable* by any member.
- **configured authorities** - the config names who leads in case of conflict
  (by id, address or DNS name); for two members, name one; for one member, it
  is its own; for six members, name an odd subset.
- **combined** - authorities filter who is eligible; seniority (or "who has
  the latest entries, and definitely the full state") orders within them.
- **live reconfiguration** - a setting decides whether the leadership mode may
  change while running; when it may, the cluster moves between modes and
  sizes without stopping.

What quorum buys, and what giving it up costs, has to be stated plainly:
quorum is what prevents two leaders during a partition. Without it, two
halves of a partitioned cluster can each elect the senior member *they can
see*. The design below accepts that for the append-only case - two leaders
cannot conflict over content, only over order - and heals order with a
deterministic merge. Where an operator cannot accept two leaders (a strict
single sequencer), the `configured` mode with `fallback = stall` gives up
availability instead, and that is the CP/AP choice made per cluster rather
than baked in. The default is open question 2.

## Goals

1. One member with no peers is a complete cluster and its own leader, with
   nothing to configure beyond its identity.
2. A second member joins a running first member without restarting it, and
   leadership is well-defined at sizes 1, 2, 3, 4 … under every mode.
3. `seniority`: the leader is the live, fully-synced member with the earliest
   join position; no member can present an earlier join position than the one
   the chain records.
4. `configured`: the leader is the first live, fully-synced member on the
   operator's authority list; what happens when none is reachable is a
   setting.
5. `combined`: the authority list filters eligibility and a tiebreak orders
   within it; a member that lacks the full state is never eligible.
6. When `leadership.reconfigurable = true`, the mode and the authority list
   change by a live `settings` entry and take effect at the next epoch; when
   `false`, such an entry is refused by every member.
7. A partition that produced two leaders heals into one chain with no entry
   lost, deterministically, on every member.

## Non-goals

- **No quorum-based mode in v1.** A Raft-style `quorum` mode for clusters that
  want strict single-leadership at n ≥ 3 is on the [roadmap](../ROADMAP.md),
  not in this PRD; the modes here are what make 1 and 2 and even counts work.
- **No automatic discovery.** Peers come from config or from a `join` the
  operator admitted; coppiz does not multicast or scan.
- **No Byzantine tolerance.** A member that signs with its own key and follows
  the protocol is trusted for what it authors; the chain stops it lying about
  *others* or about *history*, not about its own future entries. See PRD 0001
  non-goals and [open question 1](../rfcs/0009-trust-model.md).

## Design

**Identity.** A member is an Ed25519 keypair plus a 128-bit member id derived
from the public key (so the id cannot be chosen to collide). The private key
lives in the member's data directory (`member.key`), never in the journal. The
public key is in the journal - in `genesis` for the founder and in the `join`
entry for everyone else - which is how every member verifies every signature
without a side channel.

**Join is an entry, so join order is the chain.** A member's *seniority* is
the slot of its `join` control entry (the founder's is the `genesis` slot,
seniority rank 0). This is the whole answer to "cannot be spoofed" (RFC 0002):

- The joining member does not write its own `join`. An *existing* member -
  the admitter, normally the leader - writes it, after admission, naming the
  newcomer's id, public key and address. The newcomer's first authored entry
  can only come after that slot, because until then no member holds its key
  and every signature it produces is refused.
- The slot is leader-signed and hash-chained. To claim an earlier seniority a
  member would have to produce a chain prefix that every other member's copy
  contradicts; the chain hash at any later slot pins it.
- Seniority is read by folding the chain, identically on every member. There
  is no "join timestamp" field anyone reports about themselves;
  `author_ts_ms` on the `join` entry is the admitter's clock and is
  informational only. Order comes from position, never from time.

**Admission** (borrowed from clanker PRD 0011, which already solved this for
its mesh): `cluster.admission = allowlist | prompt | open`. `allowlist`
admits a dial whose public key matches a `[[peers]]` entry; `prompt` queues it
for `coppiz admit <id>`; `open` admits anyone who can reach the port (for
loopback and lab use, warned about by `coppiz doctor`). Admission is the
cluster's trust boundary; once the `join` is slotted the member is as trusted
as any other. How the allowlist learns the key out of band is [open question
21](../rfcs/0016-allowlist-key-learning.md).

**Member states.** `joining` (admitted, `join` not yet slotted) → `syncing`
(slotted, backfilling to the head) → `member` (at head within
`sync.lag_slots`, layer and value [open question
56](../rfcs/0038-sync-knobs-layer.md)) ↔ `unreachable` (failure detector lost it) →
`left` (a `leave` entry). Only `member` is leader-eligible. `syncing` is the brief's
"definitely has the full state" made a state, not a heuristic: at head of
the chain (the sync path refuses compacted records, open question
43).

**Leave and seniority.** A `leave` entry - by the member itself, or by the
leader evicting a member that has been `unreachable` for
`membership.evict_after_ms` (0 = never; default never, [open question
20](../rfcs/0015-eviction.md)) - ends that member's seniority. If the same key
rejoins, it gets a new `join` slot and therefore the *newest* seniority. A
member that merely restarts or drops off the network keeps its seniority: its
`join` slot did not move. So seniority resets only on `leave`, which is a
chain event, never on absence ([open question 4](../rfcs/0013-seniority-on-rejoin.md)).

**Failure detection.** Every member heartbeats every other over the
replication connection (`cluster.heartbeat_ms`, default 1 s); a member missed
for `cluster.suspect_after_ms` (default 5 s) is `unreachable`. Both timings
are placeholders, on the record at [OQ 37](../rfcs/0034-leader-lease.md) together
with the leader-lease question they feed. A leader that
becomes `unreachable` triggers an election on every member that noticed.

Full
mesh is the v1 topology and inherits clanker's reasoning for a small cap
(`cluster.max_members`, default 32); the leader-star or gossip topology for
larger clusters is [open question 25](../rfcs/0011-topology-past-32.md). The cap is per
**group**: past it, the system scales by more groups, not a bigger one
([PRD 0006](0006-scaling-to-groups-sharding-and-parity.md)), and a member
keeps per-member state only for its own group.

**This cluster is a group.** Everything in this PRD - membership fold,
`leader(...)`, epochs, merge - is written over an abstract member type so the
same functions elect among *groups* when clusters federate (PRD 0006 G3). A
group's identity is its genesis hash; its representative at the next level
is whoever its own chain currently names leader.

**Election: a pure function, not a protocol.** Given the folded state and this
member's view of who is live, `leader(mode, settings, members, liveness)`
returns one member id. Because it is deterministic over the *same inputs*,
every member that agrees on liveness agrees on the leader; members that
disagree on liveness are by definition partitioned and handled by epochs and
merge below. There is no vote exchange; the chain already did the hard part.

| `leadership.mode` | Eligible set | Order within eligible | Works at n = 1 | n = 2 | even n |
|---|---|---|---|---|---|
| `seniority` | live `member`s | earliest `join` slot first | yes (self) | yes; on partition both sides lead (AP, merge heals) | yes |
| `configured` | live `member`s whose id **or** address matches `authorities[]` | list order | yes (list self, or empty list = self) | yes; name one, the other stalls or falls back | yes; name an odd subset, list order breaks ties |
| `combined` | as `configured` | `tiebreak`: `seniority` (default) or `freshest` | yes | yes | yes |

`authorities[]` entries are member ids, or addresses/DNS names that a
member's `join` entry advertised; an address match is resolved to the member
id at fold time, so a DNS rename is a `settings` change, not an identity
change. `fallback = stall | seniority` (default `stall`) says what
`configured`/`combined` do when no authority is live: stall refuses writes
(the CP answer, and what makes "two members, one named leader" a strict
single sequencer), `seniority` degrades to the seniority mode for the
duration (the AP answer).

`tiebreak = freshest` orders eligible members by the highest `(epoch, seq)`
they have *acknowledged*, then by seniority. It is evaluated once, at
election, and frozen for the epoch - it is not re-evaluated on every append,
or the leader would flap. Because `syncing` members are never eligible, every
candidate under `freshest` already has the full state up to its head; the
tiebreak only prefers the one that saw the most before the old leader went.
Its exact semantics are open question 12.

**Epochs.** A new leader's first act is to append an `epoch` control entry:
`{epoch: prev + 1, reason: leader_lost | mode_change | merge | manual,
leader: self}`. This reason list is tier-1's; the federation overlay of
[PRD 0006](0006-scaling-to-groups-sharding-and-parity.md) adds
`ownership_transfer`, which a journal's new owner appends when it continues
the adopted chain after a transfer.

Slots in the new epoch start at `seq = 1`. Every member
validates that the claimed leader is what `leader(...)` returns for *their*
fold and liveness; a member that disagrees does not accept the epoch and
keeps its previous view - that is a partition, by definition, and merge
resolves it. Each branch advances its own epoch counter by one per leader
change, so two concurrent leaders produce two epochs with the same number on
different branches, which the merge rule orders.

**Partition and merge.** Under `seniority` (or any mode with
`fallback = seniority`), a partition yields one leader per side, each in its
own epoch, each slotting its own side's entries. On heal, members exchange
heads; the side whose leader ranks higher under the mode (earlier seniority,
or earlier in `authorities[]`) is the *surviving branch*. Its leader appends a
`merge` control entry naming the other branch's epoch and head, then re-slots
every entry of the other branch, in that branch's order, after the `merge`.
Entries are unchanged (same bytes, same ids); only their slots are new.

The
other branch's slots remain readable as history on members that had them and
are delivered as an archived branch to members that did not, so a chain
verifier can still check them. The rule is deterministic - any member given
both heads computes the same survivor and the same re-slot order - so even
members that were on neither side converge. What readers see: an entry's
`(epoch, seq)` can change exactly once, at merge, and only for entries
written on the losing side during the partition; its entry id never changes.
Readers that need a stable handle use entry ids ([PRD 0001](0001-journal-core.md)).

The cost, stated: a writer on the losing side that asked for `write.ack =
slotted` got a slot that later moved. `slotted` therefore means "ordered
within an epoch", not "ordered forever", unless the cluster runs a mode that
forbids two leaders (`configured` + `stall`). This is the trade the brief
accepted by rejecting quorum at n = 2, written down so it is not
rediscovered.

**Live reconfiguration.** `leadership.mode`, `authorities[]`, `tiebreak`, and
`fallback` are ordinary [PRD 0004](0004-settings.md) settings, and like every
setting they change by a `settings` entry the leader appends. The gate is
`leadership.reconfigurable`:

- `true` - the `settings` entry is accepted; the current leader appends it,
  then appends an `epoch` with `reason = mode_change` and the leader the new
  mode selects (which may be itself). The handover is one slot wide: the old
  leader stops slotting after the `epoch` entry and forwards to the new one.
- `false` - every member refuses a `settings` entry that touches
  `leadership.*`, `invalid_settings: leadership frozen`. The only way to
  change the mode is the offline procedure in [open question
  5](../rfcs/0014-offline-reconfigure.md): stop every member, run `coppiz reconfigure` on
  one, which appends the entry and an epoch locally, then restart the rest so
  they backfill it - *that* is still a chain event, so no member can be
  running a different mode than the chain says.

Flipping `reconfigurable` itself follows the same rule: from `false` it can
only be flipped offline; from `true` it can be flipped live (to `false`),
which is the operator locking the cluster down after it reached its intended
shape. This is the brief's "scale 1 → n seamlessly" in practice: start one
member under `seniority` with `reconfigurable = true`, add members, switch to
`configured` once the topology is known, then freeze.

**Settings table for this PRD** (cluster-level, PRD 0004):

| Key | Values | Default | Live-changeable |
|---|---|---|---|
| `leadership.mode` | `seniority`, `configured`, `combined` | `seniority` | only if `reconfigurable` |
| `leadership.authorities` | list of member id / address | `[]` | only if `reconfigurable` |
| `leadership.tiebreak` | `seniority`, `freshest` | `seniority` | only if `reconfigurable` |
| `leadership.fallback` | `stall`, `seniority` | `stall` | only if `reconfigurable` |
| `leadership.reconfigurable` | bool | `true` | from `true` → `false` live; `false` → `true` offline only |
| `cluster.admission` | `allowlist`, `prompt`, `open` | `allowlist` | yes |
| `cluster.max_members` | u16 | 32 | yes |
| `cluster.max_journals` | u32 | unset ([OQ 55](0001-journal-core.md)) | yes |
| `cluster.heartbeat_ms` | u64 | 1000 | yes |
| `cluster.suspect_after_ms` | u64 | 5000 | yes |
| `membership.evict_after_ms` | u64 | 0 (never) | yes |
| `merge.settle_ms` | u64 | 30000 ([OQ 60](../research/0008-merge-settle-default.md)) | yes |

**Dependencies.** PRD 0001 (chain, control kinds, backfill), PRD 0004
(settings entries, the frozen-key refusal), RFC 0002 (decision on the
join-order mechanism), clanker PRD 0011 (admission modes, reused as design).

**Implementation.**

1. `src/cluster/membership.zig` - pure fold of `genesis`/`join`/`leave` into
   the member table with seniority and state; validation rules for each.
   Shipped 2026-08-27.
2. `src/cluster/election.zig` - pure `leader(mode, settings, members,
   liveness)`; table tests for every mode at n = 1, 2, 3, 4, 6 with every
   liveness subset. Shipped 2026-08-27.
3. `src/cluster/epoch.zig` - `epoch` validation and the merge rule: given two
   heads, compute survivor and re-slot order; property test that any member
   given both heads computes the same result. Shipped 2026-08-27, with the
   deterministic simulator (OQ 27, `src/sim/sim.zig`)
   as the phase-3 acceptance harness - its scenarios are the first slice of
   the e2e matrix below.
4. `src/net/` - framing, heartbeats, forward/broadcast/backfill
   (open question 19 decides HTTP vs own framing).
5. `src/cluster/node.zig` - the loop: failure detector → election → epoch;
   admission; the reconfigure handover.
6. E2E: (a) 1 → 2 → 3 members joined live, leader correct at each step under
   each mode; (b) partition a 2-member `seniority` cluster, write on both
   sides, heal, assert one chain with every entry and identical fold on both;
   (c) same under `configured` + `stall`, assert the non-authority side
   refused writes; (d) live mode change with `reconfigurable = true`, refusal
   with `false`; (e) a member replays a forged earlier `join` and every
   other member refuses it.

## Failure modes

| Condition | Behaviour |
|---|---|
| Leader becomes unreachable | each member that notices runs `leader(...)`; the new leader appends `epoch`; writers forwarded to the old leader time out and retry at the new one |
| Two members both believe they lead | by construction they are partitioned; each slots its side; merge on heal |
| `configured`, no authority live, `fallback = stall` | `append` returns `no_leader`; reads, follows and backfill continue |
| A `join` arrives for a key already a member | refused `already_member`; a key that `left` may rejoin with new seniority |
| A member presents a chain whose `join` slots differ from ours | its chain fails `prev_slot_hash` at the first divergence; the branch the mode's ranking makes the loser (*Partition and merge*, above) is archived, never accepted as truth |
| `settings` touches `leadership.*` while `reconfigurable = false` | refused by every member, `leadership frozen` |
| Newcomer cannot reach any member to backfill | stays `syncing`; never eligible; retries with backoff |
| Authority list names an address no member advertised | that entry matches nobody; `coppiz doctor` warns; election skips it |
| All members restart simultaneously | each folds its chain; the senior/live authority becomes leader as soon as liveness is established; nothing is written until then |

## Acceptance criteria

- [ ] (G1) `coppiz` started in an empty directory is leader of a one-member
  cluster and accepts appends with no config but its data directory.
- [ ] (G2) E2E (a) passes for `seniority`, `configured`, `combined`.
- [ ] (G3) E2E (e): a forged earlier `join` is refused by every member; the
  fold's seniority table matches the chain on every member.
- [ ] (G4) E2E (c): under `configured` + `stall`, the non-authority side of a
  partition refuses writes and rejoins without a merge.
- [ ] (G5) A `syncing` member is never returned by `leader(...)` in any
  liveness subset (table test).
- [ ] (G6) E2E (d) in both `reconfigurable` states.
- [ ] (G7) E2E (b): after heal, both members hold one chain, every entry id
  written on either side resolves, and the folds hash-equal.

## Open questions / future work

- The default mode at n = 2 and whether AP-with-merge or CP-with-stall is
  what an operator expects out of the box was settled with the shipped
  default: `seniority`, with `configured` + `stall` available per cluster
  as the CP alternative (OQ 2).
- Seniority on rejoin ([RFC 0013](../rfcs/0013-seniority-on-rejoin.md),
  OQ 4), the offline reconfigure procedure
  ([RFC 0014](../rfcs/0014-offline-reconfigure.md), OQ 5), eviction
  ([RFC 0015](../rfcs/0015-eviction.md), OQ 20) and topology past 32
  ([RFC 0011](../rfcs/0011-topology-past-32.md), OQ 25) are explored in
  their RFCs; `freshest` semantics shipped with election-time freezing
  (OQ 12).
- A `quorum` mode for n ≥ 3 clusters that want Raft guarantees is roadmap;
  it would be a fourth value of `leadership.mode`, selectable live like the
  others, which is the payoff of making the mode a setting.
