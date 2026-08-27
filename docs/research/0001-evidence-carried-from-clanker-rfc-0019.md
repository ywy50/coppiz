# Research — Evidence carried from clanker's state-store survey (RFC 0019)

## Status

Draft — compiled 2026-08-21 from clanker's records; **nothing here was
re-verified at its original source for this note**. Every claim traces to a
clanker source named under Scope and method, all read there on 2026-08-21;
the evidence log gives the finer-grained source and date where one row covers
it. Reopen a source before quoting it as current.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

What did clanker's survey of shared/decentralized state stores establish that
constrains or informs coppiz's design, and which of its findings does coppiz
inherit as requirements?

## TL;DR

- **No general-purpose Zig-native replicated store exists.** TigerBeetle is
  the only Zig database of note and its schema is fixed to accounts and
  transfers — `high`, clanker research option P (read 2026-08-16).
- **The operator's direction is a standalone, public Zig project, embeddable
  library and/or small service API, designed with clanker in mind** —
  `high`, clanker RFC 0019 option T *Packaging* (2026-08-19). This repo is
  that project; [RFC 0001](../rfcs/0001-library-first-or-service-first.md)
  is the surface decision it names.
- **Append-only single-writer streams replicate with no consensus** —
  fan-out plus id-dedup plus a per-stream cursor; clanker's chat fan-out
  already does it — `medium` (design reasoning, spike not run), RFC 0019
  option T and the stage-1 spike note. This is why coppiz's content
  replication needs no consensus and only *order* needs a leader (PRD 0001).
- **BFT buys nothing under one operator; tamper evidence does.** The
  realistic bad writer is a correlated defect, which BFT cannot absorb; a hash
  chain is addable for one hash per record and clanker's improve ledger has
  already had a prefix silently rewritten — `high` on the reasoning, resting
  on the single-operator premise (research option R, 2026-08-19). coppiz
  adopts the chain and signatures and declines BFT; the premise is
  [OQ 1](../open-questions.md).
- **Quorum stores cannot serve n = 2 and stall a minority partition;
  gossip/CRDT stores converge but "converge ≠ correct".** etcd/Consul/
  rqlite/dqlite need a majority; Corrosion/Marmot accept writes everywhere and
  resolve by CRDT or HLC last-write-wins — `high`, verified at source by
  clanker 2026-08-18. coppiz's answer is append-only content (no conflict to
  resolve) plus mode-selectable leadership (PRD 0003), which is neither row.
- **clanker's data is four shapes, and only ~16 KB needs compare-and-swap.**
  Append logs, small mutable documents, single-owner blobs, claims — `high`,
  measured in clanker's tree 2026-08-16. The first coppiz consumer is the
  append-log shape (PRD 0005).

## Scope and method

- **Searched:** clanker's `docs/rfcs/0019-shared-state-store.md`,
  `docs/research/decentralized-state-store.md` (Draft 5),
  `docs/research/t-stage1-stream-replication-spike.md`, and PRD 0011 (mesh),
  all read in the clanker checkout on 2026-08-21.
- **Not searched:** the internet. Every external claim below is clanker's
  reading, dated in the evidence log.
- **Freshness:** clanker verified most external claims at source on
  2026-08-18 and 2026-08-19. Licences and release states age fast.

## Findings that become coppiz constraints

coppiz is general-purpose; these are the constraints of its *first* host,
kept because they are the strictest known, not because clanker is the
target. A row marked *general* would hold for any host; the rest are
clanker-specific and must not leak into the library's API.

| Finding (clanker's) | What coppiz does with it | Where |
|---|---|---|
| clanker vendors the SQLite amalgamation and writes per-session databases directly in-process; cross-process contention is SQLite file locking plus a 5 s busy timeout (read 2026-08-21: its ADR 0033, `src/util/sqlite.zig`) | the "several processes, one file" property is the one SQLite habit coppiz v1 lacks — *general* | PRD 0005, OQ 47 |
| clanker's mesh already replicates a session's `events` stream to peers at `cursor + 1` over loopback HTTP (ADR 0033) | that stream is a one-author coppiz journal; the first consumer shape — *general* (any single-writer stream) | PRD 0005 |
| Guests reach state only through a `ck_*` host function under a manifest grant, never a path or socket | The library runs inside the host's `serve`; guests never see coppiz | PRD 0005 route A |
| `networkAllowed` matches hostname and never port, so a loopback grant admits any local service | A sidecar + HTTP route is for experiments only | PRD 0005 route B, RFC 0001 |
| "No second daemon" (PRD 0011 non-goal) | Library-first | RFC 0001 |
| Home-instance rule: every stream has one writing host | Author = member; `(author, author_seq)` is the stable id | PRD 0001 |
| `max_members = 32`, full mesh O(n²) | Same cap, same topology in v1 | PRD 0003, OQ 25 |
| Admission `allowlist`/`prompt`/`open`, receiver-only | Reused as designed | PRD 0003 |
| Two serves on one host are two members (distinct ids, ports, dirs) | Same rule; one data dir per node, flocked | PRD 0005 |
| Guest arena / `max_fs_bytes` 1 MiB | Backfill pages bounded by `sync.page_bytes` | PRD 0001 |
| Improve ledger prefix silently rewritten once | Hash chain + signatures from v1, not later | PRD 0001, ADR 0002 |
| Stage-1 spike: three journeys — burst, backfill, hostile wire | Adopted as coppiz's first e2e shape | PRD 0005 |

## Options found (as clanker assessed them, carried)

| Option | Topology / partition | What it taught coppiz | Read by clanker |
|---|---|---|---|
| PostgreSQL (+ pg.zig) | central, CP | the default "just run a server" answer coppiz exists to avoid for small fleets | 2026-08-16/18 |
| etcd | full per host, CP | best lease/CAS primitives; 1.5 MiB request cap; quorum stalls minority | 2026-08-18 |
| rqlite / dqlite | full per host, CP | the two packaging shapes (service / embedded library); single writer through Raft leader | 2026-08-16 |
| Corrosion + cr-sqlite | full per host, AP | full replication at fleet scale is real; Rust daemon; CRDT converge ≠ correct | 2026-08-18 |
| Marmot | full per host, AP tunable | per-write ONE/QUORUM/ALL is a useful knob; rows may sync out of order — bad for logs | 2026-08-16 |
| NATS JetStream KV | per-stream replicas | streams + watch + KV; pre-1.0 Zig client | 2026-08-18 |
| TigerBeetle | central replicated, CP | the Zig blueprint: fixed-width records, deterministic fold, bounded allocation, deterministic simulation testing; not the engine | 2026-08-19 |
| CometBFT / Fabric / immudb / Hypercore / OrbitDB | ledger family | decomposed: total order and tamper evidence survive; BFT and PKI do not; p2p logs show single-owner logs + fold extend to multi-writer with Merkle integrity | 2026-08-19 |
| FoundationDB | sharded, CP | ruled out on value size; not relevant to coppiz | 2026-08-18 |
| CRDTs (Automerge/Yjs/Loro) | library, AP | logs need ordering not merging; Loro perf page unverified (403) | 2026-08-16 |

## Out-of-the-box options

- **Already in the tree (clanker's):** `chatrooms.fanOut` — at-least-once
  fan-out with id-dedup; the spike generalizes it with a cursor. coppiz's
  replication is that design with a leader-assigned total order on top.
- **Standard library / OS primitive:** Zig `std.crypto` has Ed25519 and
  SHA-256; `std.Io` has files and sockets. No dependency needed for the core
  (ADR 0001).
- **Do nothing:** clanker keeps files; RFC 0019's current-state costs stand.
- **Adjacent domain:** Raft's membership-change-as-log-entry is the model for
  `join`/`leave` as chain entries (RFC 0002).
- **Buy, host, or delegate:** every hosted/server option above; rejected for
  the small-fleet starting point by the operator (2026-08-19).

## Evidence log

| Claim | Source | Read on | Confidence |
|---|---|---|---|
| No general-purpose Zig-native replicated store exists | clanker research option P | 2026-08-16 (clanker) | high |
| Operator direction: standalone public Zig project | clanker RFC 0019 option T *Packaging* | 2026-08-19 | high |
| BFT verdict under single operator | clanker research option R | 2026-08-19 | high (reasoning) |
| Quorum rows stall minority; n = 2 cannot elect | etcd/rqlite/dqlite docs via clanker | 2026-08-18 | high |
| Corrosion fleet scale "thousands of servers", "in seconds" | Fly blog via clanker | 2026-08-18 | medium |
| `networkAllowed` ignores port | clanker `src/sandbox/host.zig` per RFC 0019 | 2026-08-19 | high |
| Improve ledger prefix rewritten | clanker bug report 2026-08-17 | 2026-08-17 | high |
| Spike journeys and 1 MiB page bound | clanker spike note | 2026-08-19 | high |
| Survey scope: 17 candidates at Draft 4, plus R/S/T at Draft 5; option T *Packaging* names the standalone public project and "which leads is the new project's first design decision"; the stage-1 spike still unrun; `networkAllowed` port blind; improve-ledger rewrite named at open question 14 | clanker `docs/rfcs/0019-shared-state-store.md`, reopened at source (README and PRD 0001 cite the survey; [OQ 40](../open-questions.md)) | 2026-08-24 (this repo) | high |

## Open questions

- Every row above should be reopened at source before coppiz cites it
  publicly (README, release notes). Tracked as [OQ 40](../open-questions.md).
- Whether clanker's stage-1 spike runs before or after coppiz's core exists,
  and which code survives ([OQ 30](../open-questions.md)).

## What would change the answer

- A general-purpose Zig replicated store appearing (option P's gap closing).
- The operator adopting a server-based store for clanker after all.
- The single-operator premise failing (multi-party clusters), which would
  reopen BFT.

## References

- clanker `docs/rfcs/0019-shared-state-store.md` (Discussion, 2026-08-19).
- clanker `docs/research/decentralized-state-store.md` (Draft 5).
- clanker `docs/research/t-stage1-stream-replication-spike.md` (Draft).
- clanker `docs/prds/0011-clanker-mesh.md` (In progress).
- clanker `docs/adrs/0001-board-is-a-chatroom.md`, `0031-compare-and-swap-locks-live-in-state-locks-keyed-by-a-hash.md`.
- clanker `docs/adrs/0033-sessions-are-per-session-sqlite-databases-with-an-append.md`
  (cited from the findings table; read in clanker's checkout 2026-08-21).
