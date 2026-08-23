# PRD 0002 — TTL and staleness: the only two mutations

## Status

Draft — 2026-08-21. Depends on [PRD 0001](0001-ledger-core.md) (entries,
slots, control kinds, `checkpoint`) and [PRD 0004](0004-settings.md) (where
the `ttl.*` / `stale.*` settings live and how they change). Source of truth
once shipped: `src/ledger/expiry.zig` (pure expiry/stale predicates, host
tested) and the `checkpoint` validation rule in `src/ledger/chain.zig`.

## Problem

An append-only ledger that every member holds in full grows forever. The brief
(2026-08-21) asks for two controlled exceptions to immutability, both
configurable per ledger:

- **TTL on entries** — an entry may carry a time-to-live; when it is reached
  the ledger either *deletes* the entry or *marks it stale*, by setting; and
  enforcement itself is a setting: off, only for entries that carry a TTL, or
  for every entry in the ledger (the "schema").
- **Author-marked staleness** — a member may mark *its own* entries stale, and
  only its own; stale entries are then cleaned up like expired ones.

The hard part is not the predicate; it is doing either *deterministically* on
N members with N clocks while keeping the hash chain verifiable. If each
member deleted on its own clock, two members would hold different ledgers and
the chain would break at the first deleted slot. The design below makes
deletion a ledger event, so every member deletes the same thing at the same
chain position.

## Goals

1. Per-ledger setting selects TTL enforcement: `off`, `per_entry`, or `all`.
2. Per-ledger setting selects what expiry does: `mark_stale` or `delete`.
3. An author can mark one of its own entries stale; no member can mark
   another's (enforced by validation on every member, not by the API).
4. Every member removes exactly the same payloads at exactly the same chain
   position; the chain stays verifiable after removal.
5. Reads hide stale and expired entries by default and can opt into seeing
   them while they physically remain.
6. Expiry never depends on a follower's clock; a skewed follower cannot see a
   different ledger.

## Non-goals

- **No un-stale.** A stale mark is itself an append-only fact. If an author
  wants the content back, it appends it again (new entry id).
- **No per-entry override of the ledger's expiry action.** An entry says how
  long it lives; the ledger says what happens then. Mixing the two per entry
  would be a schema addition, taken on only if a consumer needs it.
- **No secure erasure.** Delete drops the payload from live segments; it does
  not scrub disk blocks or backups.
- **No leader-side staleness in v1.** Only the author. Extending it to the
  leader or an operator role is [open question 6](../open-questions.md).

## Design

**Three states, one direction.** An entry is `live`, then possibly `stale`
(by author mark or by TTL under `mark_stale`), then possibly `removed` (by
`checkpoint`). No arrow points backwards.

```
live ──author `stale` entry──▶ stale ──checkpoint (if stale.cleanup=delete)──▶ removed
live ──ttl reached, action=mark_stale──▶ stale ──checkpoint (if stale.cleanup=delete)──▶ removed
live ──ttl reached, action=delete──▶ expired ──checkpoint──▶ removed
```

**The time basis is the slot, never the author.** An entry's expiry instant is
`slot_ts_ms + effective_ttl_ms`. `slot_ts_ms` is stamped by the leader at
sequencing (PRD 0001) and is monotone in the chain, so every member computes
the same instant from the same bytes. `author_ts_ms` is never consulted.

**Effective TTL** is a pure function of the entry and the ledger settings:

| `ttl.enforce` | entry `ttl_ms = 0` | entry `ttl_ms > 0` |
|---|---|---|
| `off` | never expires | never expires (the field is kept, ignored) |
| `per_entry` | never expires | expires at `slot_ts_ms + min(ttl_ms, ttl.max_ms)` |
| `all` | expires at `slot_ts_ms + ttl.default_ms` | expires at `slot_ts_ms + min(ttl_ms, ttl.max_ms)` |

`ttl.max_ms` (0 = unbounded) caps a requested TTL under both `all` and
`per_entry` — a larger ask is clamped to it — so the schema owner can bound
retention without forcing expiry. A ledger under
`all` with `ttl.default_ms = 0` is a validation error in the `settings` entry
(PRD 0004), because it would mean "everything expires immediately".

**Soft expiry: what a reader sees.** A read at local time `now` hides an entry
whose expiry instant ≤ `now - ttl.grace_ms`. This is the one place a local
clock is used, and it only affects *visibility on this member*, never bytes.
`grace_ms` (default 0; [open question 9](../open-questions.md)) lets an
operator tolerate skew between the leader that stamped the slot and the
member that reads it. Under `mark_stale`, an expired entry reads as stale;
under `delete`, as expired; `include_stale` / `include_expired` show either.

**Hard removal: the `checkpoint` control entry.** Only the leader appends it,
and it names a slot: `expire_through = (epoch, seq)`. Its meaning is: *every
entry slotted at or before this position whose expiry instant is ≤ this
checkpoint's own `slot_ts_ms`, plus every entry marked stale at or before it
(when `stale.cleanup = delete`), is removed.* The set is computed by the fold,
so it is identical on every member; the leader's clock chose the instant, but
it chose it once, in the chain. A member that was down during the checkpoint
applies it when it backfills the slot — it cannot apply it early and cannot
skip it.

Removal means the payload bytes are dropped from the segment (rewritten on
the next compaction pass) and the entry reads as `removed`. What stays is the
setting `ttl.retain`:

| `ttl.retain` | What survives removal | Chain after removal |
|---|---|---|
| `header` (default) | the entry header (with `payload_hash`) and its slot | fully verifiable: `entry_hash` is over the header, the slot references it, the chain never notices |
| `none` | only the slot, with the entry hash | the slot chain still verifies; the entry's author and id are no longer readable locally, only its hash |

`header` is the default because it keeps "who wrote something here, and when"
answerable after the content is gone, which is what an audit of a
self-modifying system needs, and costs 164 bytes per removed entry — the
draft header layout of [PRD 0001](0001-ledger-core.md) summed. `none` is
for ledgers where volume dominates. Removing a *slot* is never allowed — it
would break the chain — so the ledger's slot count only grows; the cost of that
is [open question 24](../open-questions.md).

**Who triggers a checkpoint.** The leader, on a cadence: `checkpoint.every_ms`
(default 60 s) or when `checkpoint.pending_bytes` of removable payload has
accumulated, whichever first; and never with an empty removal set (no
checkpoint spam on an idle ledger). A ledger under `ttl.enforce = off` with
`stale.cleanup = keep` never checkpoints. Cadence defaults are [open
question 10](../open-questions.md).

**Author-marked staleness.** A `stale` control entry's payload names one
target entry id `(author, author_seq)` in the same ledger. Validation (PRD
0001, run by every member) refuses it unless `stale.author == target.author`.
There is no API-level check to bypass: a member that hand-builds a `stale`
for someone else's entry produces an entry every other member refuses, and the
refusal names `not_author`. A `stale` for an already-stale or removed entry is
accepted and a no-op (idempotent, so a retried mark is harmless). What happens
to stale entries afterwards is `stale.cleanup = delete | keep` — `delete` lets
the next checkpoint remove them (the brief's "which then get removed/cleanup
as well"), `keep` leaves them hidden-but-present forever.

**Settings table for this PRD** (all per ledger, stored as PRD 0004
`settings` entries; every one is live-changeable because changing them never
invalidates history — a tightened TTL applies from the next checkpoint,
a loosened one stops future removals):

| Key | Values | Default | Meaning |
|---|---|---|---|
| `ttl.enforce` | `off`, `per_entry`, `all` | `per_entry` | which entries expire |
| `ttl.default_ms` | u64 | 0 | TTL applied under `all` to entries without one |
| `ttl.max_ms` | u64 | 0 (unbounded) | cap on a requested TTL |
| `ttl.action` | `mark_stale`, `delete` | `mark_stale` | what expiry does |
| `ttl.retain` | `header`, `none` | `header` | what a removal keeps |
| `ttl.grace_ms` | u64 | 0 | read-side skew tolerance |
| `stale.who` | `author` | `author` | who may mark; the only value in v1, present so the schema can grow |
| `stale.cleanup` | `delete`, `keep` | `delete` | whether checkpoints remove stale entries |
| `checkpoint.every_ms` | u64 | 60000 | leader cadence |
| `checkpoint.pending_bytes` | u64 | 64 MiB | early trigger |

**Interaction with merges (PRD 0003).** A checkpoint appended by one side of
a partition names slots of *its* epoch. After a merge, the surviving chain
contains both sides' checkpoints; each removes only what its own fold says it
removes, so nothing is removed twice and nothing that the other side slotted
later is touched. A checkpoint is never emitted for slots newer than the last
`merge` until `merge.settle_ms` has passed — the conservative rule that
keeps a just-healed cluster from deleting the other side's fresh writes on a
clock it did not stamp.

**Dependencies.** PRD 0001 (`checkpoint`, `stale` kinds; fold), PRD 0003
(leader, merge), PRD 0004 (settings entries).

**Implementation.**

1. `src/ledger/expiry.zig` — pure: `effectiveTtl(entry, settings)`,
   `expiresAt(slot, entry, settings)`, `visibleAt(now, …)`,
   `removalSet(fold, checkpoint)`. Table tests over the enforce × entry-ttl
   matrix and the three-state transitions.
2. `chain.zig` validation rules for `stale` (`not_author`, idempotent) and
   `checkpoint` (leader only; `expire_through` ≤ checkpoint's own slot; not
   inside `merge.settle_ms`).
3. `store.zig` payload drop + compaction pass honouring `ttl.retain`.
4. Leader cadence in the node (with PRD 0003's leader loop).
5. E2E: three members, `ttl.action = delete`, entries with 1 s TTL; assert
   all three remove the same set at the same slot and the chain verifies on
   each.

## Failure modes

| Condition | Behaviour |
|---|---|
| `stale` names another author's entry | refused by every member, `not_author`; the author's `author_seq` is still consumed (the entry exists, it is just refused a slot) — [open question 11](../open-questions.md) |
| `stale` names an unknown entry id | held like any gap (PRD 0001); refused `unknown_target` if the target never arrives within `sync.gap_timeout_ms` ([OQ 56](../open-questions.md)) |
| Follower clock far ahead of the leader | follower hides entries early (soft); bytes unaffected; `grace_ms` is the knob |
| Follower clock far behind | follower shows expired entries until a checkpoint removes them; bytes unaffected |
| Leader clock jumps forward | expiry instants pass early for entries slotted afterwards; nothing retroactive — earlier slots keep their stamps |
| `settings` sets `ttl.enforce = all` with `ttl.default_ms = 0` | refused at validation, `invalid_settings` |
| Checkpoint arrives for a slot the member does not have yet | applied after backfill reaches it; never before |
| Member was down across several checkpoints | each applied in order during backfill; end state identical to a member that was up |

## Acceptance criteria

- [ ] (G1, G2) For every cell of the enforce × action matrix, a test asserts
  the resulting state of an entry with and without a TTL after expiry.
- [ ] (G3) A hand-built `stale` for another member's entry is refused by
  every member with `not_author`; the author's own is accepted.
- [ ] (G4) Three members under `delete` remove the same payload set at the
  same checkpoint slot and each chain verifies afterwards, under both
  `retain` values.
- [ ] (G5) Default reads hide stale/expired; `include_*` shows them until
  removal.
- [ ] (G6) Skewing one follower's clock by ±1 h changes what it *shows*, not
  what it *stores*; its ledger hash equals the others'.

## Open questions / future work

- Whether `stale.who` should grow `leader` or an operator role, and what
  authorizes it ([OQ 6](../open-questions.md)).
- `grace_ms` default and whether it should be derived from observed skew
  ([OQ 9](../open-questions.md)).
- Checkpoint cadence defaults ([OQ 10](../open-questions.md)).
- Slot count grows forever even under `retain = none`; whether an
  *archival checkpoint* (a signed root that lets old slots be archived) is
  needed, and when ([OQ 24](../open-questions.md)).
