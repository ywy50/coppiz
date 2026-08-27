<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" alt="coppiz" width="420">
  </picture>
</p>

<p align="center">
  <em>A replicated, append-only store in Zig you embed like SQLite — from one
  process to a fleet, with no quorum, no sidecar, and optional TTL for
  rolling-window state.</em>
</p>

<p align="center">
  <img alt="Zig" src="https://img.shields.io/badge/Zig-0.16.0-%23f7a41d">
  <img alt="standard library only" src="https://img.shields.io/badge/std%20library%20only-no%20dependencies-%23f7a41d">
  <img alt="platforms" src="https://img.shields.io/badge/platform-linux%20%7C%20macOS-lightgrey">
</p>

## Quick start

The only prerequisite is a Zig 0.16 toolchain — its minimum version is pinned
in `build.zig.zon`; nothing else needs installing.

**Run the node.** One process is a complete journal; `init` writes the member
key and the genesis into a data directory, then append, read and head:

```bash
rm -rf ./data
zig build run -- init --dir ./data --journal main
zig-out/bin/coppiz append --dir ./data --journal main --payload "hello"
zig-out/bin/coppiz read --dir ./data --journal main
zig-out/bin/coppiz head --dir ./data --journal main
```

**Or embed the library.** The API is pre-1.0 — [PRD
0005](docs/prds/0005-embedding-the-library-as-the-product.md) pins the shape,
names will move. The SQLite case: a data directory, an allocator, an `std.Io`,
and a node:

```zig
const std = @import("std");
const coppiz = @import("coppiz");

var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_state.allocator();
var io_state = std.Io.Threaded.init(gpa, .{});
const io = io_state.io();
const data_dir = try std.Io.Dir.cwd().openDir(io, "data/coppiz", .{ .iterate = true });

try coppiz.journal.init(gpa, io, data_dir, &.{}, "events", coppiz.journal.wallClock);
const node = try coppiz.journal.Node.open(gpa, io, data_dir, .{});
defer node.deinit();

const events = node.journalIdByName("events").?;
_ = try node.append(events, "hello coppiz", 0);

var found = false;
try node.readRange(events, null, null, false, false, &found, struct {
    fn on(s: *bool, _: *const coppiz.journal.slot.Slot, _: ?*const coppiz.journal.entry.Entry) anyerror!void {
        s.* = true;
    }
}.on);
```

`zig build docs` regenerates `docs/configuration.md` from the settings schema.
Read the design, in order, with `cat docs/README.md`. Everything below is
detail.

## Status

**Shipped (2026-08-27): the single-member core and the pure cluster core.**
One process is a complete journal — append, read, follow, restart — with
settings, TTL and checkpoint cleanup in the chain. On top of that sits the
cluster core of [PRD 0003](docs/prds/0003-membership-and-leadership.md) as
pure logic: the membership fold (seniority is a join's slot position,
[RFC 0002](docs/rfcs/0002-how-join-order-is-made-unspoofable.md),
[ADR 0005](docs/adrs/0005-join-order-is-slot-position.md)), the election
function, and the epoch/merge rules — driven by a deterministic simulator
([OQ 27](docs/open-questions.md)) that partitions, crashes and reorders
in-memory nodes against them. Next is the node loop and the replication wire
(PRD 0003 phases 4–6; the wire format is [OQ 19](docs/open-questions.md));
the order everything ships in is [docs/ROADMAP.md](docs/ROADMAP.md). The
product is named `coppiz` ([ADR
0004](docs/adrs/0004-the-product-is-named-coppiz.md)).

## Overview

**What it is.** coppiz is a replicated, append-only store for Zig programs: a
library you link and give a data directory, with storage, replication,
election and cleanup inside it — nothing to install or run beside it. Entries
are signed, hash-chained, and replicated in full to every member of the
group. One process is a complete, working store (the SQLite shape); a fleet
needs no quorum, no odd member count, and no redeploy; and past one group the
same code composes groups instead of growing one ([ADR
0003](docs/adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md),
[PRD 0006](docs/prds/0006-scaling-to-groups-sharding-and-parity.md)).

**How it works, at a glance.** The design rests on one separation and one
rule ([PRD 0001](docs/prds/0001-journal-core.md)):

- **Entry versus slot.** An *entry* is what an author writes — immutable,
  author-signed, identified by `(author, author_seq)`. A *slot* is where the
  journal put it — `(epoch, seq)`, assigned and signed by the leader of that
  epoch, hash-chained to the previous slot. Content never changes; order can
  heal after a partition by re-slotting unchanged entries.
- **Everything the journal knows about itself is in the chain.** Membership,
  leadership terms, settings, and cleanup are control entries in the same
  chain as data, validated by every member with the same pure rule and folded
  deterministically into state. That is what makes join order unspoofable
  ([RFC 0002](docs/rfcs/0002-how-join-order-is-made-unspoofable.md)),
  settings impossible to disagree on
  ([PRD 0004](docs/prds/0004-settings.md)), and expiry deterministic across N
  clocks ([PRD 0002](docs/prds/0002-ttl-and-staleness.md)).
- **Writes go through the leader; reads are always local.** Every member
  holds the group's journals in full, so a read never leaves the process:

```
client ─append─▶ local member ──forward──▶ leader ──(slot, entry)──▶ every member
                    │ unslotted queue         │ assigns (epoch, seq),       │ validates chain + signatures,
                    │ (durable)               │ stamps slot_ts_ms, signs    │ appends, folds
                    ◀──────────────── read / follow: always local ─────────┘
```

- **Leadership without quorum.** There is no vote: `leader(mode, settings,
  members, liveness)` is a pure function every member evaluates over its
  fold. `seniority` (earliest join — unspoofable, because join order *is*
  chain position), an operator's `configured` authority list (name one of
  two members, or an odd subset of six), or `combined` — all well-defined at
  1, 2, and any even count, and switchable at runtime when the cluster
  allows it. A partition under `seniority` yields a leader per side and a
  deterministic merge on heal
  ([PRD 0003](docs/prds/0003-membership-and-leadership.md)).
- **Scaling by recursion.** A cluster is a group. Past `max_members` the
  system grows by more groups, not a bigger one: groups elect with the same
  function, a journal is owned by one group and routed from the others, and
  cold segments can be stored k-of-m across groups
  ([PRD 0006](docs/prds/0006-scaling-to-groups-sharding-and-parity.md)).

## What it is meant to be

- **Append-only entries**, author-signed and hash-chained, replicated in
  full to every member of its group. No update, no delete; the only
  mutations are TTL expiry and an author marking *its own* entries stale,
  both opt-in per journal and off by default
  ([ADR 0002](docs/adrs/0002-entries-are-immutable-ttl-and-author-staleness-are-the-only-mutations.md),
  [PRD 0002](docs/prds/0002-ttl-and-staleness.md)).
- **TTL with policy**: enforcement off, per entry, or for every entry in the
  journal; expiry marks stale or deletes; deletion is deterministic across
  members because it is itself a journal event
  ([PRD 0002](docs/prds/0002-ttl-and-staleness.md)).
- **Settings live in the journal**, not in per-member config files, so two
  members cannot run different rules on one journal
  ([PRD 0004](docs/prds/0004-settings.md)).
- **Batteries included**: storage, replication, failure detection, election
  and cleanup are inside the library; no coordinator, daemon or broker beside
  it, at any size
  ([ADR 0003](docs/adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)).
- **Embeddable first**: a Zig library any host links, with the standalone
  `coppiz` node built from the same tree for hosts that would rather talk to a
  process; clanker is the first host
  ([PRD 0005](docs/prds/0005-embedding-the-library-as-the-product.md),
  [RFC 0001](docs/rfcs/0001-library-first-or-service-first.md)).

## Who it is for

Any program that needs a durable, replicated, append-only record shared
across processes or machines, and finds the existing answers don't fully
cut it: the server-shaped stores (etcd, Postgres, NATS) want a cluster stood
up first; the Raft stores (rqlite, dqlite) want a quorum and an odd member
count, so two nodes can't elect; the gossip/CRDT stores converge but don't
order. coppiz is for the gap between "write files and hope" and "run
infrastructure" — slim at size 1, expandable by settings as members are
added ([ADR 0003](docs/adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)).
clanker is the first host; it is not the customer.

## Build and test

`zig build test` is today's merge gate ([OQ 45](docs/open-questions.md)): it
builds and runs the unit tests plus the analysis gates — formatting (`zig fmt
--check --ast-check`), the 100-column cap, test registration and forced
declaration analysis, and gate-coverage completeness:

```bash
zig build test
```

Run the analysis gates alone:

```bash
zig build lint
```

## Where things are

The full design lives in `docs/` — this table is the map; the detail is in
the records, not here.

| Path | What |
|---|---|
| [docs/README.md](docs/README.md) | architecture overview and the documentation taxonomy |
| [docs/prds/](docs/prds/) | what each part is meant to be |
| [docs/rfcs/](docs/rfcs/) | decisions still open, with recommendations |
| [docs/adrs/](docs/adrs/) | decisions made |
| [docs/research/](docs/research/) | evidence, with read dates |
| [docs/open-questions.md](docs/open-questions.md) | the numbered register of what is unsettled |
| [docs/glossary.md](docs/glossary.md) | every term, defined once |
| [docs/ROADMAP.md](docs/ROADMAP.md) | what ships in what order |
| [CHANGELOG.md](CHANGELOG.md), [RELEASES.md](RELEASES.md) | consumer-visible changes; version and release policy |
| `src/journal/`, `src/settings/`, `src/config/` | the single-member core: codecs, chain, segments, store, schema, local config |
| `src/cluster/`, `src/sim/` | membership, election, epochs and merge (pure); the deterministic simulator |
| `src/root.zig`, `src/main.zig` | the library; the node binary |

## Origin

coppiz was founded from clanker's
[RFC 0019](https://github.com/maci0/clanker/blob/main/docs/rfcs/0019-shared-state-store.md)
("the spine"),
which surveyed seventeen candidates (stores and log/CRDT libraries alike),
found no general-purpose Zig-native
replicated store, and recorded the decision to build one as a standalone
public project for anyone with the same problem. What that survey
established, and what coppiz inherits from it, is in
[research 0001](docs/research/0001-evidence-carried-from-the-state-store-survey.md);
how clanker itself would embed it is one worked example in
[PRD 0005](docs/prds/0005-embedding-the-library-as-the-product.md).
