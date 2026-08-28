# PRD 0005 — Embedding: the library as the product, the node binary, and hosts (clanker first)

## Status

Shipped (steps 1–3) — 2026-08-27. Draft 2026-08-21, reframed the same day
after the operator clarified that coppiz is for anyone with this class of
problem, not for clanker specifically. Source of truth: `src/root.zig`
(library API), `src/main.zig` (node), `examples/` (one host per shape);
`src/api/` (a service API) is deferred behind the first non-Zig consumer
([ADR 0007](../adrs/0007-the-library-is-the-primary-surface.md)).

The embedded write path shipped with the cluster loop:
`cluster.ClusterNode.localAppend` runs a host's append through the loop —
durable queue, then the leader slots or the follower forwards — so a host
on a follower writes without touching the wire, and the entry replicates
like any other. The embedded *read* path followed: `localReadRange` routes
a host's synchronous read through the loop — the loop runs the range over
its own state (atomic with respect to its own mutations) and copies the
records, and the host's callback replays the copies on its own thread — so
a host thread never touches the folds while the loop runs. `examples/`
carries one host per shape — `embed-single` (size 1, no network),
`embed-cluster` (three embedded nodes in one process; a partition and
heal, with the host's writes readable throughout, read through the loop),
`sidecar` (a host speaking to a node over the wire, embedded and, since
the G2 pairing, against a real `coppiz serve` over TCP) — built by `zig
build examples` and each a test run by `zig build test`. A three-member
partition that elects a second leader does not yet merge reliably in the
node loop (its two-member merge is e2e-tested; the three-member case is
reported in PRD 0003's status).

## Problem

The bar is the one the brief names: SQLite, dqlite, rqlite — "you can just
use those libraries and all the implications are already built in", with no
extra infrastructure to set up. What makes SQLite easy to embed is specific:

- it is a library, linked into the host, with no process to run;
- its whole state is a file the host names;
- the API is small and synchronous from the caller's point of view;
- it needs no network, no identity, no configuration to be useful at size 1;
- several processes on one machine can open the same file.

A replicated journal cannot be *that* simple in every respect — it has peers,
a key, a listener — but it can be that simple *at size 1* and grow from there
by configuration of the same node ([ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)).
The last SQLite property, several processes on one file, is the one coppiz
does not inherit for free and is [OQ 47](../open-questions.md).

Who this is for: any program that needs a durable, replicated, append-only
record shared across processes or machines and finds that the existing
answers either need a cluster stood up first (etcd, Postgres, NATS), need a
quorum and an odd count (Raft stores), or converge without ordering (CRDT
stores) — research 0001 lists what was surveyed. clanker is the first such
host and the one whose constraints are best known; its specifics are an
*example* below, not the design.

## Goals

1. A Zig host adds coppiz as a `build.zig.zon` dependency and opens a journal
   with a data directory and nothing else; no peers means a one-member
   cluster.
2. The same library, wrapped, is the `coppiz` node binary: a host that does
   not want to link it runs it and speaks to it over a small API.
3. Nothing outside the library is required at any size (ADR 0003): no
   coordinator, daemon, broker or discovery service.
4. The library exposes follow/subscribe so a host can react to new slots
   without polling.
5. The host controls threading and I/O: the library spawns nothing the host
   did not ask for and does all I/O through the host's `std.Io`.
6. A host that must keep secrets and sockets out of part of itself (a
   sandbox, a plugin boundary) can do so: the library is reachable through a
   single in-process call that the host can gate however it likes.

## Non-goals

- **No language bindings in v1.** A C ABI for non-Zig hosts is roadmap; the
  node binary's API covers them meanwhile.
- **No ORM, no schema on payloads.** Payloads are bytes; a host's JSON lines
  go in as they are.
- **No host-specific code in the library.** Nothing in `src/` knows about
  clanker or any other host; host adapters live in the host.

## Design

**The library API** (sketch; names will move, shape should not):

```zig
const coppiz = @import("coppiz");

var node = try coppiz.Node.open(io, gpa, .{ .data_dir = "data/coppiz" });
defer node.close();

const journal = try node.journal("events");            // by name; creates if allowed
const id = try journal.append(payload, .{ .ttl_ms = 0, .ack = .slotted });
try journal.markStale(id);                            // only our own entries

var it = try journal.read(.{ .from = .{ .epoch = 0, .seq = 0 }, .include_stale = false });
while (try it.next()) |rec| { _ = rec.entry; _ = rec.slot; }

const sub = try journal.follow(cursor, onSlot, ctx);  // called on the host's io
_ = node.leader(); _ = node.members(); _ = journal.settings();
```

The API takes a journal by name or id and never assumes the local group owns
it: when a journal lives in another group ([PRD 0006](0006-scaling-to-groups-sharding-and-parity.md)),
`append` and `read` forward, and the host's code does not change.

`Node.open` with no `[[peers]]` and no listener is the SQLite case: a
one-member cluster, the process is its own leader, every call is local. The
listener, peers and admission are fields of the same `open` options or of
`coppiz.toml` in the data directory; adding them later is what turns the
embedded journal into a cluster member without changing the host's code.

**I/O and threads.** The library takes a `std.Io` from the host and does all
network and disk work through it. Heartbeats, backfill and the leader's
checkpoint cadence run on an `io.concurrent` worker the host starts by
calling `node.run()`, or on the host's own loop by calling `node.tick()`.
Nothing runs until the host says so — which is what lets a host with a rule
like "one process owns the sockets" keep it.

**One data directory, one process (v1).** `open` takes a flock on
`<data_dir>/lock`; a second process gets `locked`. This is the one SQLite
property coppiz does not have yet: SQLite lets N processes share one file
through file locks and a busy timeout, and a host that runs several short
processes on one machine (clanker's `run`s beside its `serve`) would expect
the same. The v1 answer is "the long-lived process owns the directory, the
short-lived ones talk to it", and [OQ 47](../open-questions.md) asks whether
coppiz should instead support multi-process opens natively.

**The node binary** is `src/main.zig`: the library plus a TOML config, a
CLI (`init`, `run`, `status`, `members`, `admit`, `deny`, `append`, `read`,
`follow`, `settings`, `reconfigure`, `migrate`, `doctor`). The service API
on a listen address is deferred behind the first non-Zig consumer
([ADR 0007](../adrs/0007-the-library-is-the-primary-surface.md)); its shape when
added is below, and the build makes both from one tree either way.
(`settings schema` is PRD 0004's;
`migrate` is the explicit on-disk format migration named in Failure modes.)

**Service API shape** (when added): HTTP/1.1 + JSON on a separate port from
replication, for non-Zig hosts, for short-lived processes beside a
long-lived node (the multi-process case above), and for operators. One
resource per journal, cursors as `epoch:seq`, follow as SSE. It is a thin
wrapper that calls the library — never a second implementation of any rule.

**Examples directory.** `examples/` carries one minimal host per shape, each
built by `zig build examples` and each a test: `embed-single/` (size 1, no
network), `embed-cluster/` (three embedded nodes in one test process,
partition and heal), `sidecar/` (a host speaking to a `coppiz` node). These
are the contract that the library serves hosts in general; a change that
breaks an example breaks the build.

### Example host: clanker

clanker is the first host and the origin of the project (its RFC 0019). What
it does today, read in its tree on 2026-08-21:

- Per-session state is one SQLite database per conversation
  (`state/sessions/<id>.db`, clanker ADR 0033 / PRD 0044), written **directly
  in-process** by whichever clanker process saves the session — `serve`,
  `run` or `repl` — through a vendored SQLite amalgamation
  (`vendor/sqlite/sqlite3.c`, `src/util/sqlite.zig`). Cross-process
  contention is SQLite's own file locking plus a 5 s busy timeout; `serve`
  additionally holds a per-session lock in-process to avoid a lost update
  between its own threads. There is no shared database reached over loopback.
- Loopback HTTP is clanker's **mesh replication wire**: an owning instance
  ships a session's append-only `events` stream to peers
  (`POST /api/sessions/<id>/events`, backfill with `GET …/events?after=`),
  and a peer accepts a record only at `cursor + 1` into a replica database
  under `state/mesh/<owner>/sessions/`. That is a single-author, cursor-checked,
  append-only stream — the exact shape of a coppiz journal with one author.
- Its other streams (`improvements.jsonl`, `token_stats.jsonl`,
  `autolearn.jsonl`, `reasoning.jsonl`) are JSONL files with no replication.
- Sandboxed WASM guests never touch SQLite or the network directly; they go
  through name-gated host functions (`ck_session`, planned `ck_state`).

How coppiz fits that host, two routes, both speaking to the same library:

| Route | How a guest reaches the journal | clanker change | Trade |
|---|---|---|---|
| **A. library inside `serve`, behind a host function** (clanker RFC 0019 option A + T) | guest calls `ck_state` (name-gated, like `ck_chat`); host calls the library in-process | one host channel + routes; coppiz as a dependency beside the already-vendored SQLite | single static binary kept; keys and sockets never in the sandbox; the path clanker's RFC recommends |
| **B. `coppiz` node beside clanker, guest or host speaks the service API** | a guest or native client speaks loopback HTTP to a `coppiz` process per instance ([RFC 0001](../rfcs/0001-library-first-or-service-first.md) option B) | `network_allow` to loopback | none to the harness — zero harness change, so it works for experiments today; but clanker's `network_allow` cannot scope a guest to one port, and a second daemon is what its PRD 0011 rules out |

What clanker would put in first: the event streams it already replicates by
hand (session `events`, and the JSONL streams that have no replication at
all) — single-author journals, which exercise replication and backfill without
exercising leadership under contention. The ~16 KB of contended documents
(goals, cards) next, as a journal folded into state, which is what clanker's
board already is (its ADR 0001). Session *transcripts* and blobs stay in
SQLite. The multi-process point above matters here: clanker's short-lived
`run`/`repl` processes write session files directly today, and under coppiz
v1 they would append through `serve` instead — or OQ 47 is answered.

**Dependencies.** All other PRDs; RFC 0001; ADR 0003. For the clanker
example: its RFC 0019 and stage-1 spike note.

**Implementation.**

1. `src/root.zig` — the public API surface over `src/journal/` and
   `src/cluster/`; `examples/embed-single/` built by `zig build examples`.
2. `examples/embed-cluster/` once PRD 0003 exists.
3. `src/main.zig` + `src/cli/` — the node CLI over the library;
   `examples/sidecar/`.
4. `src/api/` — the service API (deferred behind the first non-Zig
   consumer, [ADR 0007](../adrs/0007-the-library-is-the-primary-surface.md)).
5. First host integration, in that host's tree (for clanker: a branch that
   fetches coppiz, adds `ck_state`, routes one stream through it behind a
   flag, measured against its spike note's three journeys — burst, backfill,
   hostile wire).

## Failure modes

| Condition | Behaviour |
|---|---|
| Host opens a data directory another process holds | `open` fails `locked`; never two nodes on one directory (v1; OQ 47) |
| Host never calls `run()`/`tick()` | local appends work at size 1; with peers, nothing replicates and the failure detector never runs — `doctor` names it |
| Library version and on-disk version differ | `open` refuses unknown newer formats; older formats are migrated only by an explicit `coppiz migrate` |
| Service API reachable without auth | v1 binds loopback by default; a non-loopback bind without the auth setting is a startup warning ([OQ 38](../open-questions.md)) |

## Acceptance criteria

- [x] (G1) `examples/embed-single/` opens, appends, reads and follows with no
  config beyond a directory; builds from a fresh checkout with
  `zig build examples`.
- [x] (G2) The `coppiz` binary and `examples/sidecar/` replicate to each other
  (one embedded, one standalone) — proof that the two surfaces are one
  library. `examples/sidecar/` speaks the wire to an embedded node behind
  the hub (its own test) and, since 2026-08-28, to a real `coppiz serve`
  over loopback TCP (`zig-out/bin/sidecar --address … --key-dir …`); the
  TCP pairing is an e2e in the node binary's own tests.
- [x] (G3) A fresh checkout's `build.zig.zon` declares no dependencies and
  the examples run with no other process started (a test asserts the
  process table).
- [x] (G4) `follow` delivers a new slot to a callback without the host
  polling.
- [ ] (G5) No thread exists before `run()`; a test counts them. The library
  spawns nothing until a `ClusterNode.start()`; the size-1 path creates no
  threads at all. A thread-count test is future work.
- [ ] (G6) A host can reach every library call through one function it
  gates itself — the clanker branch's `ck_state` is the first proof, with
  no filesystem grant and no `network_allow` on the guest side.

## Open questions / future work

- Library-first or service-first — decided: option A ([ADR 0007](../adrs/0007-the-library-is-the-primary-surface.md);
  [RFC 0001](../rfcs/0001-library-first-or-service-first.md) decided, [OQ 15](../open-questions.md) resolved).
- Several processes on one data directory, SQLite-style ([OQ 47]).
- Which non-clanker hosts are the design targets, and what they need that
  clanker does not ([OQ 46]).
- Service API auth when bound off loopback ([OQ 38]).
- C ABI for non-Zig hosts — roadmap.
- Whether clanker's stage-1 spike code is extracted or the integration starts
  clean ([OQ 30]).
