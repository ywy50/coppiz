# PRD 0005 — Embedding: the library as the product, the node binary, and hosts (clanker first)

## Status

Draft — 2026-08-21, reframed the same day after the operator clarified that
spine is for anyone with this class of problem, not for clanker specifically.
Depends on every other PRD for what is being exposed, and on
[RFC 0001](../rfcs/0001-library-first-or-service-first.md) for which surface
leads; [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)
fixes that nothing outside the library is ever required. Source of truth
once shipped: `src/root.zig` (library API), `src/main.zig` (node),
`examples/` (one host per shape), `src/api/` (service API if RFC 0001 keeps
one).

## Problem

The bar is the one the brief names: SQLite, dqlite, rqlite — "you can just
use those libraries and all the implications are already built in", with no
extra infrastructure to set up. What makes SQLite easy to embed is specific:

- it is a library, linked into the host, with no process to run;
- its whole state is a file the host names;
- the API is small and synchronous from the caller's point of view;
- it needs no network, no identity, no configuration to be useful at size 1;
- several processes on one machine can open the same file.

A replicated ledger cannot be *that* simple in every respect — it has peers,
a key, a listener — but it can be that simple *at size 1* and grow from there
by configuration of the same node ([ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)).
The last SQLite property, several processes on one file, is the one spine
does not inherit for free and is [OQ 47](../open-questions.md).

Who this is for: any program that needs a durable, replicated, append-only
record shared across processes or machines and finds that the existing
answers either need a cluster stood up first (etcd, Postgres, NATS), need a
quorum and an odd count (Raft stores), or converge without ordering (CRDT
stores) — research 0001 lists what was surveyed. clanker is the first such
host and the one whose constraints are best known; its specifics are an
*example* below, not the design.

## Goals

1. A Zig host adds spine as a `build.zig.zon` dependency and opens a ledger
   with a data directory and nothing else; no peers means a one-member
   cluster.
2. The same library, wrapped, is the `spine` node binary: a host that does
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
const spine = @import("spine");

var node = try spine.Node.open(io, gpa, .{ .data_dir = "data/spine" });
defer node.close();

const ledger = try node.ledger("events");            // by name; creates if allowed
const id = try ledger.append(payload, .{ .ttl_ms = 0, .ack = .slotted });
try ledger.markStale(id);                            // only our own entries

var it = try ledger.read(.{ .from = .{ .epoch = 0, .seq = 0 }, .include_stale = false });
while (try it.next()) |rec| { _ = rec.entry; _ = rec.slot; }

const sub = try ledger.follow(cursor, onSlot, ctx);  // called on the host's io
_ = node.leader(); _ = node.members(); _ = ledger.settings();
```

`Node.open` with no `[[peers]]` and no listener is the SQLite case: a
one-member cluster, the process is its own leader, every call is local. The
listener, peers and admission are fields of the same `open` options or of
`spine.toml` in the data directory; adding them later is what turns the
embedded ledger into a cluster member without changing the host's code.

**I/O and threads.** The library takes a `std.Io` from the host and does all
network and disk work through it. Heartbeats, backfill and the leader's
checkpoint cadence run on an `io.concurrent` worker the host starts by
calling `node.run()`, or on the host's own loop by calling `node.tick()`.
Nothing runs until the host says so — which is what lets a host with a rule
like "one process owns the sockets" keep it.

**One data directory, one process (v1).** `open` takes a flock on
`<data_dir>/lock`; a second process gets `locked`. This is the one SQLite
property spine does not have yet: SQLite lets N processes share one file
through file locks and a busy timeout, and a host that runs several short
processes on one machine (clanker's `run`s beside its `serve`) would expect
the same. The v1 answer is "the long-lived process owns the directory, the
short-lived ones talk to it", and [OQ 47](../open-questions.md) asks whether
spine should instead support multi-process opens natively.

**The node binary** is `src/main.zig`: the library plus a TOML config, a
CLI (`init`, `run`, `status`, `members`, `admit`, `deny`, `append`, `read`,
`follow`, `reconfigure`, `doctor`), and — if RFC 0001 keeps it — a service
API on a listen address. Which leads is that RFC's decision; the build makes
both from one tree either way.

**Service API shape** (if kept): HTTP/1.1 + JSON on a separate port from
replication, for non-Zig hosts, for short-lived processes beside a
long-lived node (the multi-process case above), and for operators. One
resource per ledger, cursors as `epoch:seq`, follow as SSE. It is a thin
wrapper that calls the library — never a second implementation of any rule.

**Examples directory.** `examples/` carries one minimal host per shape, each
built by `zig build examples` and each a test: `embed-single/` (size 1, no
network), `embed-cluster/` (three embedded nodes in one test process,
partition and heal), `sidecar/` (a host speaking to a `spine` node). These
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
  append-only stream — the exact shape of a spine ledger with one author.
- Its other streams (`improvements.jsonl`, `token_stats.jsonl`,
  `autolearn.jsonl`, `reasoning.jsonl`) are JSONL files with no replication.
- Sandboxed WASM guests never touch SQLite or the network directly; they go
  through name-gated host functions (`ck_session`, planned `ck_state`).

How spine fits that host, two routes, both speaking to the same library:

| Route | How a guest reaches the ledger | clanker change | Trade |
|---|---|---|---|
| **A. library inside `serve`, behind a host function** (clanker RFC 0019 option A + T) | guest calls `ck_state` (name-gated, like `ck_chat`); host calls the library in-process | one host channel + routes; spine as a dependency beside the already-vendored SQLite | single static binary kept; keys and sockets never in the sandbox; the path clanker's RFC recommends |
| **B. `spine` node beside clanker, guest or host speaks the service API** | `network_allow` to loopback, HTTP | none to the harness | zero harness change, so it works for experiments today; but clanker's `network_allow` cannot scope a guest to one port, and a second daemon is what its PRD 0011 rules out |

What clanker would put in first: the event streams it already replicates by
hand (session `events`, and the JSONL streams that have no replication at
all) — single-author ledgers, which exercise replication and backfill without
exercising leadership under contention. The ~16 KB of contended documents
(goals, cards) next, as a ledger folded into state, which is what clanker's
board already is (its ADR 0001). Session *transcripts* and blobs stay in
SQLite. The multi-process point above matters here: clanker's short-lived
`run`/`repl` processes write session files directly today, and under spine
v1 they would append through `serve` instead — or OQ 47 is answered.

**Dependencies.** All other PRDs; RFC 0001; ADR 0003. For the clanker
example: its RFC 0019 and stage-1 spike note.

**Implementation.**

1. `src/root.zig` — the public API surface over `src/ledger/` and
   `src/cluster/`; `examples/embed-single/` built by `zig build examples`.
2. `examples/embed-cluster/` once PRD 0003 exists.
3. `src/main.zig` + `src/cli/` — the node CLI over the library;
   `examples/sidecar/`.
4. `src/api/` — the service API (conditional on RFC 0001).
5. First host integration, in that host's tree (for clanker: a branch that
   fetches spine, adds `ck_state`, routes one stream through it behind a
   flag, measured against its spike note's three journeys — burst, backfill,
   hostile wire).

## Failure modes

| Condition | Behaviour |
|---|---|
| Host opens a data directory another process holds | `open` fails `locked`; never two nodes on one directory (v1; OQ 47) |
| Host never calls `run()`/`tick()` | local appends work at size 1; with peers, nothing replicates and the failure detector never runs — `doctor` names it |
| Library version and on-disk version differ | `open` refuses unknown newer formats; older formats are migrated only by an explicit `spine migrate` |
| Service API reachable without auth | v1 binds loopback by default; a non-loopback bind without the auth setting is a startup warning ([OQ 38](../open-questions.md)) |

## Acceptance criteria

- [ ] (G1) `examples/embed-single/` opens, appends, reads and follows with no
  config beyond a directory; builds from a fresh checkout with
  `zig build examples`.
- [ ] (G2) The `spine` binary and `examples/sidecar/` replicate to each other
  (one embedded, one standalone) — proof that the two surfaces are one
  library.
- [ ] (G3) A fresh checkout's `build.zig.zon` declares no dependencies and
  the examples run with no other process started (a test asserts the
  process table).
- [ ] (G4) `follow` delivers a new slot to a callback without the host
  polling.
- [ ] (G5) No thread exists before `run()`; a test counts them.
- [ ] (G6) A host can reach every library call through one function it
  gates itself — the clanker branch's `ck_state` is the first proof, with
  no filesystem grant and no `network_allow` on the guest side.

## Open questions / future work

- Library-first or service-first ([RFC 0001](../rfcs/0001-library-first-or-service-first.md), [OQ 15](../open-questions.md)).
- Several processes on one data directory, SQLite-style ([OQ 47]).
- Which non-clanker hosts are the design targets, and what they need that
  clanker does not ([OQ 46]).
- Service API auth when bound off loopback ([OQ 38]).
- C ABI for non-Zig hosts — roadmap.
- Whether clanker's stage-1 spike code is extracted or the integration starts
  clean ([OQ 30]).
