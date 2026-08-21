# PRD 0005 — Embedding: the library, the node binary, and plugging into clanker

## Status

Draft — 2026-08-21. Depends on every other PRD for what is being exposed,
and on [RFC 0001](../rfcs/0001-library-first-or-service-first.md) for which
surface leads. The clanker side is [RFC 0019](https://github.com/maci0/clanker/blob/main/docs/rfcs/0019-shared-state-store.md)
(tier 1: `ck_state`; tier 2 option T: this project). Source of truth once
shipped: `src/root.zig` (library API), `src/main.zig` (node), `src/api/`
(service API if RFC 0001 keeps one).

## Problem

The brief's roadmap item: the store must plug into clanker (and programs like
it) "easily, like SQLite can". What makes SQLite easy to embed is specific and
worth naming, because it is the bar:

- it is a library, linked into the host, with no process to run;
- its whole state is a file the host names;
- the API is small and synchronous from the caller's point of view;
- it needs no network, no identity, no configuration to be useful at size 1.

A replicated ledger cannot be *that* simple — it has peers, a key, a
listener — but it can be that simple *at size 1* and grow from there, which is
the same property PRD 0003 gives the cluster. The embedding question is how
the host reaches it, and for clanker specifically how a *sandboxed WASM
guest* reaches it when guests never get a filesystem path or a socket.

## Goals

1. A Zig host adds spine as a `build.zig.zon` dependency and opens a ledger
   with a data directory and nothing else; no peers means a one-member
   cluster.
2. The same library, wrapped, is the `spine` node binary: a host that does
   not want to link it runs it and speaks to it over a small API.
3. clanker reaches the ledger through a host function (`ck_state` or a
   dedicated `ck_ledger`) in its `serve` process, and its guests never see a
   path, a socket or a key.
4. The library exposes follow/subscribe so a host can react to new slots
   without polling.
5. The host controls threading: the library does not spawn threads the host
   did not ask for.

## Non-goals

- **No language bindings in v1.** A C ABI for non-Zig hosts is roadmap; the
  service API covers them meanwhile.
- **No ORM, no schema on payloads.** Payloads are bytes; clanker's JSON lines
  go in as they are.
- **No replacing clanker's `state/` wholesale.** The first clanker consumer is
  RFC 0019's stage-1 stream (the improvements ledger); sessions and blobs stay
  where they are until a measurement says otherwise — the "narrow the
  requirement" staging RFC 0019 recommends.

## Design

**The library API** (sketch; names will move, shape should not):

```zig
const spine = @import("spine");

var node = try spine.Node.open(io, gpa, .{ .data_dir = "state/spine" });
defer node.close();

const ledger = try node.ledger("improvements");      // by name; creates if allowed
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
calling `node.run()` (or on the host's own loop by calling `node.tick()`).
Nothing runs until the host says so, which is what lets clanker keep its
rule that `serve` owns sockets and everyone else is a loopback client.

**The node binary** is `src/main.zig`: the library plus a TOML config, a
CLI (`init`, `run`, `status`, `members`, `admit`, `deny`, `append`, `read`,
`follow`, `reconfigure`, `doctor`), and — if RFC 0001 keeps it — a service
API on a listen address. Which leads is that RFC's decision; the build makes
both from one tree either way.

**Service API shape** (if kept): HTTP/1.1 + JSON on a separate port from
replication, for non-Zig hosts and for operators. One resource per ledger,
cursors as `epoch:seq`, follow as SSE. It is a thin wrapper that calls the
library — never a second implementation of any rule — the same principle
clanker states for its CLI and web UI over one tool.

**Plugging into clanker.** Two routes, and RFC 0019 already chose the first
as tier 1:

| Route | How a guest reaches the ledger | clanker change | Trade |
|---|---|---|---|
| **A. library inside `serve`, behind `ck_state`** (RFC 0019 option A + T) | guest calls `ck_state` (name-gated privileged channel, like `ck_chat`); host calls the library in-process | one host channel + serve routes; spine as a third `build.zig.zon` dependency | single static binary kept; keys and sockets never in the sandbox; the path RFC 0019 recommends |
| **B. `spine` node as a sidecar process, WASM guest speaks the service API** | guest granted `network_allow` to loopback, calls HTTP | none to the harness; a tool manifest + guest | zero harness change, so it works today for experiments; but `network_allow` admits any local port, and a second daemon is what clanker's PRD 0011 rules out |

Route B is how the first experiments can run before clanker's tier-1
channel exists; route A is the destination. Both speak to the same library,
so nothing written for B is lost.

**What clanker puts in first.** RFC 0019's stage 1: owner streams that today
are JSONL files (`improvements.jsonl`, `token_stats.jsonl`, `autolearn.jsonl`,
`reasoning.jsonl`) — each becomes a ledger with `author` = the clanker
instance, payload = the JSONL line, `ttl` per clanker's retention. Those
streams are single-writer by construction (clanker's home-instance rule), so
they exercise replication and backfill without exercising leadership under
contention — the cheapest first consumer. Then the ~16 KB of contended
documents (goals, cards) as a ledger folded into state, which is what
clanker's board already is (its ADR 0001). Sessions and blobs stay out.

**Dependencies.** All other PRDs; RFC 0001; on the clanker side RFC 0019 and
its stage-1 spike note (which decides whether the spike's code or a clean
start becomes the integration).

**Implementation.**

1. `src/root.zig` — the public API surface over `src/ledger/` and
   `src/cluster/`; an example host under `examples/embed/` built by
   `zig build examples`.
2. `src/main.zig` + `src/cli/` — the node CLI over the library.
3. `src/api/` — the service API (conditional on RFC 0001).
4. A clanker branch that fetches spine, adds `ck_state`, and routes
   `improvements.jsonl` appends through it behind a flag; measured against
   the spike note's three journeys (burst, backfill, hostile wire).

## Failure modes

| Condition | Behaviour |
|---|---|
| Host opens a data directory another process holds | `open` fails `locked` (flock on `<data_dir>/lock`); never two nodes on one directory |
| Host never calls `run()`/`tick()` | local appends work at size 1; with peers, nothing replicates and the failure detector never runs — `doctor` names it |
| Library version and on-disk version differ | `open` refuses unknown newer formats; older formats are migrated only by an explicit `spine migrate` |
| Service API reachable without auth | v1 binds loopback by default; a non-loopback bind without the auth setting is a startup warning ([open question 38](../open-questions.md)) |

## Acceptance criteria

- [ ] (G1) `examples/embed/` opens, appends, reads and follows with no
  config beyond a directory; builds from a fresh checkout with
  `zig build examples`.
- [ ] (G2) The `spine` binary and the example host replicate to each other
  (one embedded, one standalone) — proof that the two surfaces are one
  library.
- [ ] (G3) A clanker guest appends and reads through `ck_state` with no
  filesystem grant and no `network_allow`.
- [ ] (G4) `follow` delivers a new slot to a callback without the host
  polling.
- [ ] (G5) No thread exists before `run()`; a test counts them.

## Open questions / future work

- Library-first or service-first ([RFC 0001](../rfcs/0001-library-first-or-service-first.md), [OQ 15](../open-questions.md)).
- Service API auth when bound off loopback ([OQ 38]).
- C ABI for non-Zig hosts — roadmap.
- Whether clanker's stage-1 spike code is extracted or the integration starts
  clean ([OQ 30]).
