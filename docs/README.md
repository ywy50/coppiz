# coppiz — Reference Documentation

Product requirement docs live in [docs/prds/](prds/) ([index](prds/README.md), [template](prds/TEMPLATE.md));
the Done/Planned narrative is [docs/ROADMAP.md](ROADMAP.md).
Decisions that are still open live in [docs/rfcs/](rfcs/) ([index](rfcs/README.md), [template](rfcs/TEMPLATE.md)),
and the evidence they rest on in [docs/research/](research/) ([index](research/README.md), [template](research/TEMPLATE.md));
a decision that has been made is an [ADR](adrs/) ([index](adrs/README.md)).
Operational bugs and evidence-led investigations go in [docs/reports/](reports/),
recurring recovery procedures in [docs/runbooks/](runbooks/),
and what we learn from an external project in [docs/digests/](digests/).
Cross-cutting unknowns are numbered in [open-questions.md](open-questions.md);
terms are defined once in [glossary.md](glossary.md).
The operator's original brief (2026-08-21), quoted as "the brief" wherever a
record refers to it, is [qnd-notes.md](../qnd-notes.md) at the repository
root. Clarified the same day, in conversation: coppiz is for anyone facing
this class of problem, not for clanker specifically; it must be a library to
"just use" the way SQLite, dqlite or rqlite are, with everything built in and
no extra infrastructure; slim to start, expandable and naturally scalable.
That clarification is [ADR 0003](adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md).

The taxonomy is clanker's, deliberately: coppiz was founded by clanker's
[RFC 0019](https://github.com/maci0/clanker/blob/main/docs/rfcs/0019-shared-state-store.md)
("the spine") and the conventions are already proven there. Neither `rfc` nor `research` requires
the other, and a PRD is never a decision (that is an ADR) and never the
shipped narrative (that is the roadmap).

## Where to start

| You want to know | Read |
|---|---|
| what this is and why it exists | [PRD 0001 Problem](prds/0001-journal-core.md#problem), then [research 0001](research/0001-evidence-carried-from-clanker-rfc-0019.md) |
| the data model | [PRD 0001](prds/0001-journal-core.md) — entries, slots, chain, control entries |
| how cleanup works in an append-only store — opt-in, off by default | [PRD 0002](prds/0002-ttl-and-staleness.md), [ADR 0002](adrs/0002-entries-are-immutable-ttl-and-author-staleness-are-the-only-mutations.md) |
| who is leader at 1, 2, 6 members, and what a partition does | [PRD 0003](prds/0003-membership-and-leadership.md), [RFC 0002](rfcs/0002-how-join-order-is-made-unspoofable.md) |
| where settings live and why not in a config file | [PRD 0004](prds/0004-settings.md) |
| how a program embeds it, with clanker as the worked example | [PRD 0005](prds/0005-embedding-the-library-as-the-product.md), [RFC 0001](rfcs/0001-library-first-or-service-first.md) |
| how it gets to 1,000 or 100,000 instances | [PRD 0006](prds/0006-scaling-to-groups-sharding-and-parity.md) — groups, ownership, parity, and what the core must get right now |
| what is not decided | [open-questions.md](open-questions.md) |

## Architecture (implemented down to the pure core; the node loop is next)

coppiz is a replicated, append-only store written in Zig 0.16 with the
standard library only ([ADR 0001](adrs/0001-zig-0-16-standard-library-only-for-the-core.md)),
and everything a cluster needs ships inside the library
([ADR 0003](adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)).
Every member of a group holds the group's journals in full (past one
group, journals are owned and routed — see *Scaling by recursion* below).
The design rests on one separation and one rule:

**The separation: entry versus slot.** An *entry* is what an author writes —
immutable, author-signed, identified by `(author, author_seq)`. A *slot* is
where the journal put it — `(epoch, seq)`, assigned and signed by the leader of
that epoch, hash-chained to the previous slot. Content never changes; order
can heal after a partition by re-slotting unchanged entries. Readers that
need identity use entry ids; readers that need order use slots.

**The rule: everything the journal knows about itself is in the chain.**
Membership (`genesis`, `join`, `leave`), leadership terms (`epoch`,
`merge`), settings (`settings`), and cleanup (`stale`, `checkpoint`) are
control entries in the same chain as data, validated by every member with
the same pure rule, and folded deterministically into state. That one rule
is what makes join order unspoofable (seniority is a slot position, RFC
0002), settings impossible to disagree on (they are not per-member, PRD
0004), and expiry deterministic across N clocks (a checkpoint names the slot,
PRD 0002).

```
client ─append─▶ local member ──forward──▶ leader ──(slot, entry)──▶ every member
                    │ unslotted queue         │ assigns (epoch, seq),       │ validates chain + signatures,
                    │ (durable)               │ stamps slot_ts_ms, signs    │ appends, folds
                    ◀──────────────── read / follow: always local ─────────┘
```

**Leadership without quorum.** There is no vote. `leader(mode, settings,
members, liveness)` is a pure function every member evaluates over its fold;
members that agree on liveness agree on the leader, and members that do not
are partitioned. Three modes — `seniority` (earliest join slot), `configured`
(an operator list; name one of two, or an odd subset of six), `combined` —
all well-defined at n = 1, 2, and any even n. A partition under `seniority`
yields a leader per side and a deterministic merge on heal; `configured` with
`fallback = stall` refuses writes instead. Modes are settings, so a cluster
can start as one member and change mode as it grows, gated by
`leadership.reconfigurable` (PRD 0003).

**Scaling by recursion.** A cluster is a *group*. Past `max_members`, the
system grows by more groups, not a bigger one: a federation is a cluster
whose members are groups, elected by the same `leader(...)` function; a
journal is owned by one group and routed to from the others; sealed segments
can be stored k-of-m across groups. The core carries a short list of things
it must get right today for that to stay possible — globally unique journal
ids, chain per journal, self-describing segments, pure validation and
election, a reserved federation settings scope
([PRD 0006](prds/0006-scaling-to-groups-sharding-and-parity.md)).

**Source layout (planned).** `src/journal/` entry/slot codecs, chain, storage;
`src/cluster/` membership fold, election, epochs, merge, node loop;
`src/settings/` schema, validation, fold; `src/net/` framing, heartbeats,
backfill; `src/config/` local `coppiz.toml` parsing (PRD 0004); `src/cli/`
the node CLI and `src/api/` the optional service API (PRD 0005);
`src/root.zig` the library API; `src/main.zig` the node binary;
`src/federation/` (later) group membership, ownership, routing, parity.
Pure logic (codecs, fold, election, merge, expiry) is kept I/O-free so it
can be unit-tested and driven by a deterministic simulator
([OQ 27](open-questions.md)).

## Hosts

coppiz is a library any program links; the `coppiz` binary is that library
wrapped for programs that would rather talk to a process. Nothing in `src/`
knows about any particular host ([PRD 0005](prds/0005-embedding-the-library-as-the-product.md)).

clanker is the first host and the origin of the project. Its RFC 0019 (tier
1: a `ck_state` host channel in `serve`; tier 2 option T: this project)
defines the first integration. What clanker does today — per-session SQLite
written directly in-process, session event streams replicated to mesh peers
over loopback HTTP at `cursor + 1`, JSONL streams with no replication — and
how coppiz would slot in are worked through as the example host in PRD 0005.
Everything coppiz inherits from clanker's survey is listed with its read dates
in [research 0001](research/0001-evidence-carried-from-clanker-rfc-0019.md);
its sandbox and single-binary constraints are the strictest known host
constraints, which is why they are kept in view, not because they are the
target.
