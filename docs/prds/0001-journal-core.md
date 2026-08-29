# PRD 0001 - Journal core: append-only entries, slots, and the hash chain

## Status

Shipped (single-member core) - 2026-08-27. Draft 2026-08-21; the
single-member phases 1–4 are implemented and tested (`zig build test`, 261
tests). Source of truth: `src/journal/` - `entry.zig` and `slot.zig`
(codecs, hashes, sign/verify), `chain.zig` (fold and validation), `expiry.zig`
(PRD 0002 predicates), `segment.zig` and `store.zig` (on-disk segments,
CRC, torn-tail recovery, compaction), `queue.zig` (unslotted queue),
`journal.zig` (the single-member node), `src/settings/` (schema, fold,
validation), `src/config/local.zig` (`coppiz.toml`), `src/main.zig` (the
tier-0 CLI).

The format magics are coppiz-derived (`CPPZ` entry, `CPSG`
segment, `CPST` seal, `CPPQ` queue), not the draft's `SPNE`.

This PRD is the data model every other PRD builds on: [0002](0002-ttl-and-staleness.md)
(TTL and staleness), [0003](0003-membership-and-leadership.md) (membership,
leadership), [0004](0004-settings.md) (settings), [0005](0005-embedding-the-library-as-the-product.md)
(embedding). Terms are defined once in [the glossary](../glossary.md).

Acceptance criteria on one member: **G3** (byte flips and removed slots
detected at open, named by position - store CRC scan plus fold chain
refusal), **G4** (kill -9 mid-append, no acknowledged write lost - torn-tail
truncation unit tests plus a process-level e2e that truncates the segment
tail and reopens), **G5** (entry/segment/queue `version + 1` refused),
**G6** (`journal.max_entry_bytes`, `cluster.max_journals`, and the queue
bound each tripped by a test), **G7** (a member cannot forge another's
entry - signature negative test).

**G1** and **G2** (two members,
byte-identical journals; hash-equal folds) need the replication transport,
which phase 5 defers to PRD 0003; the fold-determinism hash is tested
single-member.

Implementation decisions recorded at the format freeze: one chain per
journal with a cluster control journal (OQ 7 resolved); `author_seq` is
monotone, gaps allowed (OQ 11 resolved); the `create_journal` control kind
carries a new journal's id, name and initial settings (OQ 34, leader-only
in v1) and there is no drop - a journal's end state is *frozen*,
`journal.allow_append = false`, which refuses new `data` with
`journal_frozen` while `settings`, `stale` and `checkpoint` still fold, so
the entries expire away and the freeze can be lifted
([RFC 0019](../rfcs/0019-journal-lifecycle.md) option A; whether a
`drop_journal` kind is ever added stays open there); `join`/`leave`/`epoch`/`merge` fold since PRD 0003 phases 1–3
(2026-08-27, [ADR 0005](../adrs/0005-join-order-is-slot-position.md)) -
until then they were refused as unimplemented. Snapshots are deferred (OQ
17); the unslotted queue bound is local config with a provisional default
(OQ 55).

## Problem

A Zig program that wants a replicated, durable, append-only log today has
two choices: run infrastructure beside itself (etcd, a database cluster, a
replication daemon), or write files and hope. There is no library that a Zig
program embeds the way it embeds SQLite - open a directory, append, read -
whose replication, election and cleanup are already inside, and which grows
from one process to a fleet without an operator standing up a cluster first.

clanker's RFC 0019 surveyed seventeen candidates - stores and log/CRDT
libraries alike - and confirmed that gap; the
operator's direction (2026-08-19, clarified 2026-08-21) was to found the
missing store as its own public, general-purpose project, with clanker as its
first host rather than its owner. This is it.

The constraints that shape the core, taken from the brief (2026-08-21, with
the clarification of the same day) and from RFC 0019's drivers:

- **Append-only.** Entries are never edited in place. The only mutations are
  the two [PRD 0002](0002-ttl-and-staleness.md) allows - TTL expiry and an
  author marking its own entry stale - and both are opt-in per journal and
  off by default.
- **Every member of a group holds the group's journals in full.** A member that
  loses every peer still has everything its group owns; a peer that dies
  strands nothing but its own unreplicated tail. "Group" and "cluster" are
  the same thing at this level; [PRD 0006](0006-scaling-to-groups-sharding-and-parity.md)
  is where a journal may be owned by one group among many, and it lists what
  this PRD must get right now for that to stay possible.
- **Scale 1 → n without a redeploy.** One process is a complete, working
  journal and is its own leader. Adding the second, third, sixth member must
  not require an odd count, a quorum, or a restart of the first.
- **Tamper-evident.** A member must not be able to rewrite history, and in
  particular must not be able to falsify *when it joined* (PRD 0003 depends on
  join order). clanker's improve ledger has already had a prefix silently
  rewritten once by a defective writer (RFC 0019 open question 14), which is
  the concrete argument for a hash chain even under a single operator.
- **Embeddable, batteries included.** A Zig library with no libc requirement
  beyond what the host links and no infrastructure beside it: storage,
  replication, election and cleanup are inside the library, so a host that
  links it has everything ([ADR 0001](../adrs/0001-zig-0-16-standard-library-only-for-the-core.md),
  [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md),
  [RFC 0001](../rfcs/0001-library-first-or-service-first.md)). clanker's single
  static musl binary is the strictest known host, not the only one.
- **Slim at size 1, expandable by settings.** Every mechanism is absent or
  trivial for one process and is switched on as members are added; nothing
  has to be redeployed to grow.

## Goals

1. An entry, once accepted, is replicated byte-identically to every member and
   is readable by its stable id `(author, author_seq)` forever, or until a
   PRD 0002 policy removes it.
2. Every member folds the same journal to the same state: same entries, same
   order, same settings, same membership - deterministically, from the log
   alone.
3. Any member can detect a rewritten, reordered, or truncated prefix at read
   time, and can prove which member authored any entry.
4. A single process with no peers is a complete journal: append, read, follow,
   restart, all without network.
5. The on-disk format and the wire format are versioned, and a reader refuses
   a version it does not know rather than misreading it.
6. Entry size, journal count, and per-process memory are bounded by settings,
   not by what the host happens to allow. (The memory bound has no key in the
   drafted schema and no criterion below - [OQ 61](../research/0009-memory-bound.md).)

## Non-goals

- **No in-place update, no delete-by-request.** A "delete" is a PRD 0002
  expiry or stale-mark; there is no `delete(id)`. This is what keeps
  replication consensus-free for data entries (see Design, *Why append-only
  is what makes this small*).
- **No queries beyond position, author, kind and time.** No secondary
  indexes, no SQL, no joins in v1. Consumers fold the journal into whatever
  view they need (clanker's board is exactly such a fold, ADR 0001 there).
- **No Byzantine fault tolerance.** Members are authenticated and their
  entries signed, so a member cannot *impersonate* another or forge history -
  but a correct majority is not defended against a malicious minority that
  follows the protocol. The trust model is "one operator, authenticated
  members, defective-not-malicious writers". Whether that is the right model
  is [open question 1](../rfcs/0009-trust-model.md).
- **No encryption at rest.** The host's disk is trusted. Wire encryption is
  [open question 23](../rfcs/0008-wire-encryption.md).
- **No multi-cluster federation in v1.** One cluster, its members, its
  journals; growing past one group is [PRD 0006](0006-scaling-to-groups-sharding-and-parity.md)'s
  later overlay, which rests on the format choices this PRD already makes
  (globally unique journal ids, chain per journal, self-describing segments).

## Design

**Two objects, not one: the entry and the slot.** The brief's requirements
pull in two directions. Tamper evidence and author-ownership want the
*content* to be immutable and author-signed. Leader election with partitions
([PRD 0003](0003-membership-and-leadership.md)) means a total order can be
*re-sequenced* when two leaders' histories merge. Making one object carry
both would force a choice between "entries are immutable" and "order can
heal". So:

- An **entry** is what an author writes: immutable, author-signed, identified
  by `(author, author_seq)`. Its bytes never change, on any member, ever.
- A **slot** is where the journal put it: `(epoch, seq)`, assigned by the leader
  of that epoch, leader-signed, hash-chained to the previous slot. A slot
  references an entry by hash. An entry normally occupies exactly one slot;
  after a partition merge it may be *re-slotted* - a new slot references the
  same, unchanged entry, and the old slot stays in the chain as history.

Readers that care about identity use entry ids. Readers that care about
order use slots. Both are stable in the sense that matters to them.

**Byte order.** Every multi-byte integer in every fixed layout of this
section - the entry header, the slot, and the segment record prefixes,
headers and index under Storage - is little-endian whatever the writing
host's native order; a codec encodes fields individually and never casts a
native struct onto its bytes.

**Entry layout** (fixed header, then payload; all integers little-endian;
sizes are the draft and may change before the first on-disk version is
frozen):

| Field | Size | Meaning |
|---|---|---|
| `magic` | 4 | `CPPZ` |
| `version` | 2 | entry format version; a reader refuses unknown values |
| `kind` | 2 | `data` or one of the control kinds below |
| `journal` | 16 | journal id: a *globally* unique 128-bit id (random at creation), never a per-cluster counter, so a journal keeps its id when its owning group changes (PRD 0006); the name is a setting |
| `author` | 16 | member id |
| `author_seq` | 8 | dense per-(author, journal) counter, starts at 1 |
| `author_ts_ms` | 8 | author's wall clock at write; informational, never used for ordering or expiry |
| `ttl_ms` | 8 | 0 = no TTL; see PRD 0002 for what enforcement does with it |
| `payload_len` | 4 | bytes following the header |
| `payload_hash` | 32 | SHA-256 of the payload |
| `signature` | 64 | Ed25519 over every header field above, by `author`'s key |
| `payload` | `payload_len` | opaque to coppiz; consumers define it |

`entry_hash` = SHA-256 of the whole header including signature; it is what a
slot references. A `stale` mark names its target by *entry id*
`(author, author_seq)`, not by this hash - the id carries the author, which
is what lets every member validate who marked ([PRD
0002](0002-ttl-and-staleness.md)).

**Slot layout** (the chain):

| Field | Size | Meaning |
|---|---|---|
| `epoch` | 8 | leadership term that assigned this slot (PRD 0003) |
| `seq` | 8 | dense within the epoch, starts at 1 |
| `slot_ts_ms` | 8 | the leader's clock at assignment; the *only* time basis PRD 0002 expiry uses; monotone non-decreasing within an epoch, clamped to ≥ the previous slot across epochs |
| `entry_hash` | 32 | the entry placed here |
| `prev_slot_hash` | 32 | hash of the previous slot in this journal; genesis slot uses zeros |
| `leader` | 16 | member id of the assigning leader |
| `signature` | 64 | Ed25519 over the fields above, by the leader's key |

`slot_hash` = SHA-256 over the slot. The chain is over slots, so the chain
covers order *and* content (via `entry_hash`) *and* who ordered it.

**Clock assumptions.** `slot_ts_ms` is the leader's wall clock and is the
only time basis PRD 0002's expiry uses; failure detection is the one path
that runs on monotonic time (the node loop measures suspect/evict windows
on the monotonic clock). The assumption is an NTP-disciplined clock, with
skew in seconds, not hours. Outside that assumption the consequences are
visibility-only, never divergence: a skewed leader makes entries read as
stale or expired early or late on other members, a backwards jump is
clamped so expiry is delayed, never advanced, and the folds still agree
(OQ 32, resolved).

**Control entries.** Everything the journal knows about itself is an entry in
the same chain, so it replicates by the same mechanism, is tamper-evident by
the same hash, and can be folded deterministically by every member:

| Kind | Author | Meaning | Defined in |
|---|---|---|---|
| `genesis` | the founder | creates the cluster and its first journal; carries initial settings and the founder's key | PRD 0003, 0004 |
| `join` | an existing member (the admitter) | admits a new member: id, public key, address. Its slot is the new member's seniority | PRD 0003 |
| `leave` | the leaving member, or the leader evicting it | removes a member; its seniority is gone | PRD 0003 |
| `epoch` | the new leader | opens a leadership term: why (`leader_lost`, `mode_change`, `merge`, or `manual` - the reason list PRD 0003 defines), who | PRD 0003 |
| `merge` | the surviving leader | imports another epoch's slots after a partition heals | PRD 0003 |
| `settings` | the leader | changes one or more settings; refused by validation when the setting is not live-changeable | PRD 0004 |
| `stale` | the target's author | marks one of the author's own entries stale | PRD 0002 |
| `checkpoint` | the leader | makes removal deterministic: "every member may now drop entries expired through slot X - and entries marked stale, when `stale.cleanup = delete`" | PRD 0002 |

A control entry is validated by every member on receipt, not only by the
leader. Validation is pure: a function of the entry, the slot, and the folded
state up to the previous slot. That is the mechanism behind "cannot be
spoofed": a `join` whose author is not a member, a `stale` whose author is not
the target's author, a `settings` touching a frozen key - each is refused by
*every* member independently, so a single bad member cannot push it through.

**Why append-only is what makes this small.** With no in-place update, two
entries never conflict: there is nothing to merge, only to order. Ordering
needs a leader; *content* does not. So a follower can accept an entry from
any author optimistically, hold it unslotted, and hand it to whoever is
leader; the worst case on leader change is that the entry waits. RFC 0019
option T established the single-writer half of this (an author's own stream
replicates with no consensus at all); the leader adds only the total order
across authors, and PRD 0003 is about who that leader is. There is no
two-phase commit anywhere.

**Write path.**

1. A client calls `append(journal, payload, ttl)` on its local member.
2. The member builds and signs the entry (`author_seq` = its last + 1),
   appends it to its **local unslotted queue** (durable, so a crash does not
   lose an acknowledged-as-accepted write), and forwards it to the leader.
   If the member *is* the leader, step 3 follows immediately.
3. The leader validates, assigns `(epoch, seq)`, stamps `slot_ts_ms`, signs
   the slot, appends both to its log, and broadcasts `(entry, slot)` to every
   member.
4. Each member validates the slot (chain, signature, leader is the current
   leader of that epoch), appends, and drops its copy of the entry from its
   unslotted queue - the author's because it queued it in step 2, a
   follower's because it accepted it optimistically (see *Why append-only is
   what makes this small*).
5. The client's `append` returns at one of two points, by setting
   (`write.ack = local | slotted`): when the local member has durably queued
   it, or when the slot is back. `local` is the AP behaviour (a partitioned
   member keeps working); `slotted` is the CP behaviour (a write is not
   acknowledged until it has a position). Default is [open question 3](../rfcs/0037-write-ack-layer.md);
   the shipped path has no `write.ack` knob - `node.append`, the wire append
   and `localAppend` all return at the slot.

**Read path.** Reads are always local - every member has everything. The
read API exposes: by slot range within an epoch, by entry id, by author, by
kind, from a cursor with follow (push new slots to a callback), and the
folded views (members, settings, leader). By default a read hides stale and
expired entries; `include_stale` and `include_expired` show them while they
are still physically present (PRD 0002).

**Backfill.** A member that was down, or has just joined, asks any member for
slots after its last known `(epoch, seq)`; pages are bounded by
`sync.page_bytes` (layer and value [OQ 56](../rfcs/0038-sync-knobs-layer.md)). The chain
lets it verify each page against the previous
slot hash without trusting the peer. A member is `syncing` until it has
reached the leader's head, and a `syncing` member is never leader-eligible
(PRD 0003) and never serves backfill pages past its own verified head.

**Storage.** One directory per member, one subdirectory per journal, segment
files of slots+entries in chain order, each record length-prefixed and
CRC-checked so a torn tail write is detected and truncated at startup, and
a sparse position→offset index per segment (position = `(epoch, seq)`;
`seq` alone cannot key it - it restarts at 1 every epoch).

The per-journal
subdirectory is named for the journal's id in lowercase hex, never for its
name: the name is a mutable setting, and keying a directory by a chosen
string drags filesystem naming rules into journal identity - on
case-insensitive filesystems such as Windows NTFS and macOS's default APFS,
journals named `Foo` and `foo` would share one directory and one chain;
Windows refuses reserved device names (`con`, `nul`) and names ending in a
dot or space; a name carrying `/` or `\` escapes the member directory.
None of that is spellable in hex digits.

A segment's header carries the
format version, the journal id and the id of the group that sequenced it, so
a segment is self-describing when it moves between groups (ownership
transfer or parity reconstruction, PRD 0006); a **sealed** segment - one
behind the head that will never be appended to - has a recorded hash and is
the unit parity works on. The unslotted queue is its own
small append file, bounded by `sync.unslotted_max_bytes` (value and overflow
behaviour OQ 55).

Everything else - membership,
settings, leader, stale/expired sets - is folded from the log at open,
optionally from a snapshot (a verified fold at a named slot) to bound restart
time.
`fsync` policy is local config, not a chain setting
(`storage.fsync = every | batched | never`; PRD 0004's layer rule); the
default is `every` on the leader and `batched` on followers
([open question 14](../research/0003-fsync-default-measurement.md)).

**Multiple journals per cluster.** A cluster holds many journals; each has its
own id, name, chain, and PRD 0002 settings ("schema"). Membership and
leadership are cluster-level (one leader sequences all journals) in v1, to
keep one fold; per-journal leadership is [open question 8](../rfcs/0010-per-journal-leadership.md).
The chain is per journal, not per cluster, because a journal is the unit
PRD 0006 assigns to one group and encodes with parity - a cluster-wide chain
could not be split (open question 7 leans that way
for this reason). The count of journals is itself bounded by settings
(`cluster.max_journals`; value unset, OQ 55).

**Dependencies.**

- Zig 0.16 standard library only: `std.crypto.sign.Ed25519`,
  `std.crypto.hash.sha2.Sha256`, `std.hash.crc`, `std.Io`. No fetched
  dependencies in the core ([ADR 0001](../adrs/0001-zig-0-16-standard-library-only-for-the-core.md)).
- PRD 0003 for who is leader; PRD 0004 for where settings come from. The
  core can be built and tested single-member before either exists.

**Implementation phases** (files are proposals; the first commit that
creates them is the source of truth):

1. `src/journal/entry.zig`, `src/journal/slot.zig` - codecs, hashes, sign and
   verify, with unit tests and a fuzz test on the decoders (untrusted wire
   input). Pure, no I/O.
2. `src/journal/chain.zig` - fold and validation: given a verified prefix state
   and a `(slot, entry)` pair, accept or name the refusal. Pure. Table-driven
   tests for every control kind's validation rule.
3. `src/journal/segment.zig`, `src/journal/store.zig` - on-disk segments,
   CRC, torn-tail recovery, index, snapshot. Tests open a store, crash it
   mid-write (truncate the file), reopen, and assert the verified head.
4. `src/journal/journal.zig` - the single-member library API: open, append,
   read, follow. An e2e test runs the `coppiz` binary standalone.
5. Replication (forward, broadcast, backfill) lands with PRD 0003, since it
   needs a leader to exist.

## Failure modes

| Condition | Behaviour |
|---|---|
| Entry signature does not verify | refused by every member; the forwarding member is told `bad_signature`; never slotted |
| Slot signature does not verify, or `leader` is not the leader of `epoch` | refused; the member keeps its head and requests backfill from a different peer |
| `prev_slot_hash` mismatch | refused; the receiving member suspects its own history or the sender's and enters reconciliation (PRD 0003 *merge*); it does not overwrite |
| Torn write at the segment tail | truncated at open, logged; the entries lost were never acknowledged past `local` |
| Payload larger than `journal.max_entry_bytes` | refused at `append` with `too_large` before anything is written |
| Unknown entry or slot `version` | refused with `unsupported_version`; the member keeps running on what it can read |
| Author's `author_seq` has a gap | the slot is held, the leader requests the missing entries from the author; a gap that never fills is open question 11 |
| Disk full | `append` fails with the OS error; the member stops accepting writes but keeps serving reads and backfill |
| Clock on the leader jumps backwards | `slot_ts_ms` is clamped to the previous slot's value; expiry is delayed, never advanced |

## Acceptance criteria

- [ ] (G1) Two members, 10,000 appends from each, every member's journal is
  byte-identical and every entry id resolves on both.
- [ ] (G2) The fold of the same log on two members yields identical
  membership, settings, leader and stale/expired sets, checked by hash.
- [ ] (G3) Flipping one byte in a stored slot, entry, or payload, or removing
  a slot, is detected at open and named by position.
- [ ] (G4) A single member with no peers survives kill -9 mid-append with no
  acknowledged-`slotted` write lost.
- [ ] (G5) A store or frame with `version + 1` is refused with
  `unsupported_version`, not misread.
- [ ] (G6) `journal.max_entry_bytes`
  ([OQ 36](../research/0006-max-entry-size.md)); default unset there, like the other two's
  values at OQ 55), `cluster.max_journals`, and the
  `sync.unslotted_max_bytes` queue bound are enforced and each has a test
  that trips it.
- [ ] (G7) A member cannot produce a valid entry attributed to another member
  without that member's key (negative test, must fail verification).

## Open questions / future work

Unresolved questions live with the record that will settle them - decisions
in [the RFCs](../rfcs/), measurements in [the research notes](../research/).
The ones that belong to the core specifically:

- Snapshot format and when a member may serve a snapshot instead of slots
  to a joining peer ([RFC 0022](../rfcs/0022-snapshot-format.md), OQ 17).
- Archival checkpoints, so slot count can be bounded under `retain = none`
  ([RFC 0032](../rfcs/0032-archival-checkpoint.md), OQ 24).
- The `journal.max_entry_bytes` default and the large-payload shape
  ([research 0006](../research/0006-max-entry-size.md), OQ 36).
