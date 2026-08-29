# Research — Comparison benchmarks: which systems, which workloads, and how to run them fairly

## Status

Draft — searched 2026-08-28.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

coppiz is positioned as a library to "just use" the way SQLite, dqlite or
rqlite are ([docs/README.md](../README.md#hosts), [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)).
Which stores should the comparison benchmark suite pit against it, what
workloads and metrics make each comparison fair, and what is the current
state of each candidate — version, licence, durability semantics, benchmark
tooling — as of 2026-08-28?

This note answers the *how*: the harness design (workloads, metrics,
durability contract, fairness rules) and the evidence on each candidate. It
does not choose the final system list; that is a decision ([RFC 0004]
candidate). The internal measurement set that replaces the tier numbers is
[OQ 54](../open-questions.md); this suite shares its harness where possible
and adds the external comparison rows.

## TL;DR

- **The core trio is fixed by the product sentence, not by taste.** SQLite
  (single-node baseline, clanker's status quo), dqlite (embedded replicated
  library), rqlite (service replicated) are the three named comparators in
  [docs/README.md](../README.md#hosts). Everything else is an extension that
  must justify itself by the claim it tests — [Options found](#options-found).
- **No rigorous head-to-head benchmark of these systems exists in public.**
  The closest are a crude 2022 gcore wall-clock test (Litestream ≈10 s,
  dqlite ≈22 s, rqlite ≈61.5 s to import Chinook) and self-reported vendor
  numbers (rqlite docs, etcd 2016-era doc, LiteFS "~100 tps" FUSE ceiling,
  CR-SQLite "2.5× insert overhead"). A fair comparison is itself a
  contribution — `high`, absence-based after a broad sweep:
  [gcore](https://gcore.com/blog/comparing-litestream-rqlite-dqlite/),
  [evidence log](#evidence-log).
- **The single most common flaw in every published comparison is durability
  mismatch** — SQLite `synchronous=NORMAL` or OFF compared against raft
  systems that fsync every write. The suite must define a durability
  contract (DURABLE / BATCHED / ASYNC) and compare within a class only.
  [etcd's own guide](https://etcd.io/docs/v3.4/op-guide/performance/)
  states commit latency = fdatasync + RTT — `high`.
- **Each candidate has a different durability floor that must be pinned
  before benchmarking:** SQLite WAL `synchronous=FULL` (fsync WAL per
  commit), dqlite fixed O_DSYNC raft log (no knobs), rqlite raft log fsynced
  per write, etcd WAL fsync, TigerBeetle synchronous 3/6 quorum,
  JetStream `sync_interval=always` + R3 (PubAck ≠ fsync by default),
  LiteFS async by default (data-loss window on primary crash) — all verified
  at source, 2026-08-28, [evidence log](#evidence-log).
- **Two of the "modern entrants" are maintenance-risk rows, not fixtures:**
  libSQL's innovation has moved to the Turso rewrite (README banner, last
  `libsql-server` release 2025-02-14) and LiteFS has had no release since
  2025-04-22 plus a documented "no support" notice — both still benchmarkable,
  both flagged. CR-SQLite has no append/history semantics until its v2 —
  [Options found](#crsqlite).
- **The AP/CRDT family (Loro, Automerge, Yjs, Marmot) is a semantics
  comparison, not a throughput one:** published numbers are text-edit
  workloads (dmonad/crdt-benchmarks, Loro's perf page), none measure an
  append-log shape, and none show merge determinism. A partition/heal
  scenario row is the honest comparison; a throughput row is not —
  [Options found](#automerge-yjs-loro).

## Scope and method

- **Searched:** five parallel sweeps on 2026-08-28, each fetching primary
  sources directly (GitHub API/raw/releases, project docs, `sqlite.org`,
  `rqlite.io`, `dqlite.io`, `fly.io`, `turso.tech`, `postgresql.org`,
  `etcd.io`, `tigerbeetle.com`, `nats.io`, npm/crates.io registries, Wayback
  Machine CDX, HN Algolia API). The sweeps covered: the core trio; libSQL +
  LiteFS; the AP/CRDT family; etcd + TigerBeetle + NATS JetStream; and a
  survey of published cross-store benchmarks plus methodology references.
  The full query lists are in the [Appendix](#appendix).
- **Not searched / under-searched:** general web search engines were
  unreachable or bot-walled from the research environment all day, so
  everything was verified by direct fetch of named sources. Consequences:
  Hacker News threads with real measured numbers could not be enumerated
  (Algolia API was also down), and no 2024–2026 rigorous third-party
  head-to-head benchmark was found — these are listed under
  [Open questions](#open-questions) for a rerun with working search.
- **Freshness:** every claim read on 2026-08-28; the newest sources are
  nats-server v2.14.6 (2026-08-27) and Loro 1.15.0 (2026-08-27). Release
  cadence, licences and maintenance posture age fast — the versions quoted
  here are already a snapshot. Anything marked `absence-based` means the
  sweep searched and did not find it; treat it as evidence, not certainty.

## Benchmark harness design (how to do it)

This is the deliverable. It is written to be executable by a later
implementation pass; the operator decisions it still needs are in
[Open questions](#open-questions).

### Claims the suite exists to test

Each benchmark row must name the claim it tests, or it is noise:

| Claim | Tested against | Workload |
|---|---|---|
| C1 "Append is cheap at one node" | SQLite (baseline) | W1 single-node |
| C2 "Replication costs little" | dqlite, rqlite | W1, W2 at 3 nodes |
| C3 "Library, not a server" | rqlite, etcd, Postgres, NATS, LiteFS | packaging: memory, processes, join steps |
| C4 "Works at n = 2, survives a partition with no stall and no loss" | etcd, rqlite, dqlite, JetStream R3 | W6 partition scenario (behavioural) |
| C5 "Log-shaped reads" | SQLite, JetStream, libSQL replicas | W3, W4 |
| C6 "Batteries included" | LiteFS (FUSE+Consul), libSQL (needs primary), Postgres, NATS | ops/infra comparison |
| C7 "Deterministic merge, not convergence" | Loro/Automerge/Yjs, CR-SQLite, Marmot | W6 merge semantics (behavioural) |

Rows C1–C5 are throughput/latency rows; C3 and C6 are mostly observational;
C4 and C7 are behavioural scenario rows with pass/fail outcomes plus timing,
and must not be reduced to a throughput number.

### Workloads

Payload shape follows the first consumer ([PRD 0005](../prds/0005-embedding-the-library-as-the-product.md),
OQ 36): 1–2 KB entries in an append-log shape; a large-payload variant
(64 KB) as an outlier; session-size blobs (1.75 MB) are explicitly *not* a
first-consumer shape and stay out of v1 of the suite.

- **W1 — single-writer append (n = 1).** One writer appends N entries with
  exponential inter-arrival. Measures the floor: pure sequential append cost
  plus fsync policy. Run in both durability classes (see below).
- **W2 — multi-writer append (3 nodes).** 2–3 writers, one journal. For
  coppiz: writers land on different members, forward to the leader
  ([docs/README.md](../README.md#architecture)); for raft systems: clients
  hit the leader. Measures ordering contention and the leader write path.
- **W3 — read-your-writes / tail read.** Immediately after an append, read
  the latest k entries (k = 1, 64). Local reads for coppiz/SQLite/libSQL
  replicas; round-trip reads for services.
- **W4 — follow / stream.** A cursor consumer keeps up with the tail over
  time. Relevant rows: coppiz, JetStream (subscription), SQLite (poll).
  Optional in v1.
- **W5 — join/backfill.** A fresh member joins a cluster holding a 1 GB
  journal; measure time-to-head, MB/s, and peak network. [OQ 54](../open-questions.md)
  already names this; it is the number hosts actually feel.
- **W6 — partition and heal (3 nodes, behaviour).** Cut the leader (or one
  side) off for T seconds; record write availability on each side
  (CP: refused; coppiz `seniority`: both sides write), then heal. Outcomes:
  zero data loss, deterministic merge (both sides' appends present in a
  reproducible order), convergence time, and — for CP systems — the stall
  behaviour itself. This is where coppiz's `seniority` AP default
  ([PRD 0003](../prds/0003-membership-and-leadership.md)) is demonstrated or
  refuted; `configured`+`stall` is the same test with the opposite expected
  outcome.
- **W7 — memory and connections at n = 1, 3, 6.** RSS per member, fd count,
  connection count ([OQ 54](../open-questions.md) sibling). The "library vs
  server" claim (C3) mostly shows up here.
- **W8 — multi-process one-file (SQLite-only row).** SQLite's file-lock
  habit coppiz v1 lacks ([OQ 47](../open-questions.md)). Benchmark it anyway:
  the gap should be measured and tracked, not asserted.

### Metrics

- Append latency p50/p99/p999 (never means); sustained throughput at
  saturation; W5: backfill MB/s and time-to-head; W6: convergence time and
  pass/fail; W7: RSS/connections.
- Report percentiles from merged histograms, per [YCSB's own guidance]
  (https://raw.githubusercontent.com/brianfrankcooper/YCSB/master/README.md):
  percentiles cannot be averaged across runs; merge the histograms. A
  fixed-bucket or log-linear histogram is a small std-only Zig module
  ([ADR 0001](../adrs/0001-zig-0-16-standard-library-only-for-the-core.md)).

### The durability contract

The single most important rule. Define three classes and never compare
across them:

| Class | Meaning | Systems/configs |
|---|---|---|
| **DURABLE** | ack only after fsync (and, if replicated, after quorum) | SQLite WAL `synchronous=FULL`; dqlite (fixed); rqlite default (raft fsync per write); etcd default; TigerBeetle default; Postgres `synchronous_commit=on`; JetStream file store, `replicas=3`, `sync_interval=always`; coppiz `storage.fsync=every` |
| **BATCHED** | group-commit / periodic fsync; small data-loss window | SQLite WAL `synchronous=NORMAL`; rqlite queued writes; JetStream default file store (`async` persist); coppiz `storage.fsync=batched` |
| **ASYNC** | ack before stable storage; data-loss window on crash | LiteFS (async by default); rqlite queued writes; coppiz `write.ack=local` on a partitioned member |

Every published comparison surveyed broke this rule at least once
([evidence log](#evidence-log) — andrecasal, deployn, sqlite.org speed page
being the oldest examples).

### Topology matrix

- **Single node:** SQLite, coppiz n = 1, libSQL (embedded), Postgres
  (single server), LiteFS (single node — isolates the FUSE tax).
- **3-node cluster:** coppiz, dqlite, rqlite, etcd, JetStream R3, LiteFS
  (needs Consul), libSQL primary + replicas (replica *reads* are the point),
  TigerBeetle (fixed-schema mapping, see below).
- **Partition (3-node):** coppiz, etcd, rqlite, dqlite, JetStream R3 —
  behavioural only.

Never mix single-node and cluster numbers in one row.

### Fairness rules

1. **Same machine, same disk, same run window** for every system in a row;
   record CPU model, governor/turbo state, disk model and fs, kernel,
   OS, and every store's exact version. (etcd's guide and the PG wiki both
   require this; the survey showed its absence is the norm.)
2. **Durability class pinned per run** (above) and stated in the report.
3. **One driver per store, same logical workload spec.** The coppiz driver
   is a Zig binary embedding the library (this is also the OQ 54 harness
   seed). External stores use their native clients; the workload parameters
   (payload size distribution, inter-arrival, duration, concurrency) come
   from one shared spec so every driver runs the same logical workload.
   Run client and server on separate machines for service systems (PG wiki:
   watch for client CPU saturation).
4. **Warmup + steady state; ≥3 runs, report spread.** Single runs are
   directional only (the intuitem benchmark's own caveat).
5. **TigerBeetle's own warning:** its benchmark numbers are explicitly "not
   necessarily comparable across different TigerBeetle versions"
   ([benchmark_load.zig](https://raw.githubusercontent.com/tigerbeetle/tigerbeetle/main/src/tigerbeetle/benchmark_load.zig))
   — pin the version and say so. Same spirit for everything else.
6. **Behavioural rows are pass/fail + timing**, never ops/s.
7. **Harness code lives under the gate coverage** — a `.zig` harness outside
   `src/` needs its own test root or `checked_paths` entry
   ([AGENTS.md](../../AGENTS.md)); prefer `src/bench/` so the lint gates
   cover it.

### Driver notes per candidate

- SQLite: `speedtest1` for the official baseline; a small C driver (via the
  amalgamation) for the matched append workload. Pin ≥ 3.51.3 (WAL-reset
  corruption bug fixed in 3.51.3).
- dqlite: `dqlite-benchmark` from go-dqlite already has
  `kvwrite`/`kvreadwrite` workloads and a 1-node/3-node invocation shape.
- rqlite: official `rqbench` (`cmd/rqbench`) + `?timings`.
- etcd: official `benchmark` tool (`benchmark put --total --key-size
  --val-size --clients`); bbolt `bench` for the storage layer.
- TigerBeetle: `tigerbeetle benchmark` with default "canonical workload";
  an append-log shape must be mapped onto transfers (fixed schema — the
  comparison is on ordering/durability semantics, not payload flexibility).
- JetStream: `nats bench js pub --create` + `--throughput` (the flag exists
  for head-to-head against Kafka-style tools).
- Postgres: `pgbench -f append.sql -n -M prepared -T 120 -l` with a custom
  single-INSERT script.
- LiteFS: Linux + FUSE + a Consul server for dynamic failover; a static
  primary avoids Consul for the single-node FUSE-tax row.
- CRDT libs: Loro's harness (`zxch3n/crdt-benchmarks`) exists but measures
  text-edit workloads; a coppiz comparison would need an append-shaped
  scenario, which is the W6 semantics row, not a throughput row.

## Options found

Tier 1 is the named trio. Tiers 2–4 are extensions, each justified by the
claim it tests. Status figures were read on 2026-08-28 at the cited sources;
full claim-level tracing is in the [Evidence log](#evidence-log).

### Tier 1 — the named trio (claims C1, C2, C4)

#### SQLite — the single-node baseline and clanker's status quo

- **What it is:** embedded C library, serverless, WAL-mode append journal.
- **Status:** 3.53.4 (2026-07-24), public domain, full-time maintainers,
  "supported through 2050". Pin ≥ 3.51.3 for the WAL-reset corruption fix.
- **Benchmark fit:** W1/W3/W8 single-node; the durability floor for C1.
  `synchronous=FULL` = WAL fsynced per commit (DURABLE); `NORMAL` = synced
  only at checkpoints (BATCHED); `OFF` = nothing.
- **Pros:** trivial to run; official `speedtest1`; the honest n = 1
  reference for "what does replication cost".
- **Cons:** no replication (that is the point); its speed page is a retired
  historical artifact, so there are no official current numbers to cite.
- **Unknowns:** distro package versions not verified; the 2017
  "35% faster than files" figure is stale.

#### dqlite — the embedded replicated library (Canonical)

- **What it is:** embeddable C library, SQLite with a custom in-memory VFS
  + WAL mode; the *raft log* is what hits disk (O_DSYNC segments via Linux
  KAIO), not SQLite files. Committed = quorum persisted.
- **Status:** v1.18.7 (2026-07-02), LGPLv3 + static-linking exception,
  Canonical-maintained, LXD is the flagship user. Linux only.
- **Benchmark fit:** the direct head-to-head for C2: same packaging shape
  (embedded library), raft commit round-trip vs coppiz's forward + broadcast.
- **Pros:** closest structural peer; official `dqlite-benchmark` tool
  (go-dqlite); durability is fixed (no knob to get wrong).
- **Cons:** no fsync/durability knobs at all; CP (writes hang without
  quorum); stale reads up to ~an election timeout; no official published
  benchmark numbers anywhere.
- **Unknowns:** the fsync-before-ack ordering is inferred from source
  (write completion gates the raft append callback) rather than documented
  — medium confidence; MicroCeph/MicroCloud usage claimed but unverified.

#### rqlite — the service shape of the same idea

- **What it is:** standalone `rqlited` daemon, SQLite + Hashicorp raft,
  HTTP API. Not embedded; you write through HTTP.
- **Status:** v10.2.7 (2026-07-06), MIT, active (repo pushed 2026-08-28).
- **Benchmark fit:** quantifies the packaging tax (C3) that library-first
  claims to avoid; raft-fsync-per-write makes DURABLE the default.
- **Pros:** official `rqbench`; well-documented durability semantics
  (raft log fsynced per write; SQLite layer runs WAL `synchronous=OFF` with
  periodic FULL checkpoints — the raft log is authoritative).
- **Cons:** the historical `-raft-on-disk`-style fsync flags are gone from
  current docs and source (absence-based); "used in k0s" claim unverified;
  queued writes (the only non-raft write path) trade durability for speed.
- **Unknowns:** glibc requirement quoted inconsistently (2.32 vs 2.34) on
  rqlite's own pages.

### Tier 2 — same niche, modern entrants (claims C3, C5, C6, C7)

#### libSQL / Turso — the fork whose pitch is "SQLite as a library you ship"

- **What it is:** SQLite fork; embedded C library, `sqld` server, and
  "embedded replicas" (local file serves reads; writes go to the remote
  primary unless `offline: true`).
- **Status:** MIT (history: blessing → Apache-2.0 → MIT); last
  `libsql-server` release 2025-02-14; README banner says new features moved
  to the Turso rewrite (beta). **Maintenance mode signal.**
- **Benchmark fit:** replica *reads* (local) + write path to primary; the
  closest in spirit to coppiz's read-local design; C5/C6.
- **Pros:** three packaging shapes to compare; vendor microbench (~190 ns
  prepared SELECT) gives a cache-resident ceiling.
- **Cons:** single-writer; replicas lag (eventual consistency); the June
  2024 licence-change plan's outcome could not be verified at a primary
  source (repo still MIT, a Turso employee said so on HN 2025-03); no
  independent benchmarks exist.
- **Unknowns:** the C library's actual current SQLite base version; a
  versioned C-library release artifact (tags are `libsql-server-vX.Y.Z`).

#### LiteFS — SQLite replicated at the file layer (Fly.io)

- **What it is:** FUSE passthrough filesystem; captures per-transaction
  page sets into LTX files shipped over HTTP. Single primary (Consul lease
  or static); replicas serve reads locally.
- **Status:** v0.5.14 (2025-04-22), Apache-2.0, sole maintainer (Ben
  Johnson), docs say "no support", no releases since April 2025.
  **Low-active maintenance risk.**
- **Benchmark fit:** the FUSE tax row (author-reported ~250 µs per
  write+fsync; Fly FAQ states ~100 tps write ceiling) and the async-loss
  semantics comparison (C4/C6).
- **Pros:** easy single-node row (static primary, no Consul); documented
  consistency model (async by default; sync replication still "planned").
- **Cons:** Linux + FUSE only; write throughput ceiling is the number being
  measured, not an artifact; async default means a durability-class decision
  is forced; combining with Fly autostop is documented as risking data loss.
- **Unknowns:** one third-party measurement found (single-node, 62 rps) is
  disclaimed by its own author; no multi-node replication benchmark exists
  anywhere; write-forwarding PR was merged but never shipped in docs/code.

#### CR-SQLite — the AP SQLite extension

- **What it is:** SQLite loadable extension; tables become CRRs (conflict
  -free replicated relations); merges resolved by per-column CRDTs.
- **Status:** v0.16.3 (2024-01-17), MIT; commits since are build fixes only.
  The vlcn team is structurally at Fly.io but no acquisition was ever
  announced.
- **Benchmark fit:** semantics row (C7): its own README says inserts are
  "2.5× slower than regular SQLite tables" and, decisively, **it keeps no
  history** — the causal event-log design is "v2". An append-log comparison
  cannot be run against v1.
- **Pros:** the only CRDT layer on SQLite; measurable conflict-resolution
  semantics.
- **Cons:** no history, so no append-log shape; no numeric benchmarks; v2
  never landed.

### Tier 3 — positioning rows (claims C3, C4, C5, C6)

#### etcd — the CP quorum baseline

- **What it is:** consistent distributed KV, bbolt backend, Raft; designed
  for small in-memory datasets.
- **Status:** v3.7.1 (2026-07-23), Apache-2.0, CNCF; three maintenance
  branches cutting monthly.
- **Benchmark fit:** the partition scenario (C4) — docs confirm the
  majority side continues and the minority stalls; and a CP throughput
  reference. **Not** an append-log comparison: its API is current-state KV
  with compaction; the official benchmark doc is a 2016-era artifact
  (etcd 2.2.0, GCE n1-highcpu-2).
- **Pros:** official `benchmark` tool; explicit tuning guidance
  (commit = fdatasync + RTT; `wal_fsync_duration_seconds` p99 < 10 ms).
- **Cons:** KV shape; stale published numbers; "fsync before reply" is
  implied by the FAQ/tuning docs, not stated verbatim.

#### TigerBeetle — the Zig reference

- **What it is:** financial-transactions DB in Zig; fixed Account/Transfer
  schema; ground state is an immutable, hash-chained, append-only log of
  prepares over VSR; io_uring, single-threaded; deterministic simulation
  (VOPR).
- **Status:** 0.17.9 (2026-07-03), **Apache-2.0 since 2021-01 — the common
  "relicensed in 2024" belief is not supported by the repository record**;
  near-weekly cadence.
- **Benchmark fit:** closest in *spirit* to coppiz's write model (append
  -only, hash-chained, fsync-backed, total order) — a same-language sanity
  check that Zig is not the bottleneck. Data shape is fixed, so an
  append-log workload must be mapped onto transfers.
- **Pros:** official `tigerbeetle benchmark` (canonical workload, percentiles
  built in); explicit "not comparable across versions" caveat (a good
  discipline to copy).
- **Cons:** fixed schema (no payload flexibility); "1M TPS on a single
  core" and "1000× faster OLTP" are design claims; absolute numbers live in
  talk videos, not text; the DevHub performance page URL was not found.
- **Unknowns:** DevHub public URL; per-release absolute numbers in text.

#### NATS JetStream — the stream-shaped option

- **What it is:** persistence layer inside nats-server; a stream is
  literally a sequence-numbered append-only log with a read-back API; KV is
  a stream bucket. Raft-replicated (R1 default, R3 "production floor").
- **Status:** nats-server v2.14.6 (2026-08-27), Apache-2.0, CNCF, very
  active.
- **Benchmark fit:** the stream-shaped baseline (C5): most comparable data
  shape of all candidates. Durability must be pinned — **PubAck ≠ fsynced
  by default**; file storage syncs on `sync_interval` (`always` degrades
  throughput, documented).
- **Pros:** official `nats bench js pub` with a `--throughput` flag
  designed for head-to-head runs; R3 semantics documented (writes blocked
  without a majority).
- **Cons:** messaging semantics (consumers, acks, retention, dedup window)
  complicate a store-to-store comparison; single-leader writes; no official
  absolute benchmark table.
- **Unknowns:** CNCF graduation status (membership confirmed, graduation
  not).

#### PostgreSQL — the server baseline

- **What it is:** the default "just run a server" answer coppiz exists to
  avoid for small fleets.
- **Status:** 18.6 (2026-08-13), PostgreSQL License.
- **Benchmark fit:** one row only, to make the "no server" claim concrete
  (C3/C6): pgbench with a custom single-INSERT script
  (`pgbench -f append.sql -n -M prepared -T 120 -l`);
  `fsync=on` + `synchronous_commit=on` are the DURABLE defaults.
- **Pros:** pgbench is mature; the append script is three lines.
- **Cons:** every published PG-vs-embedded comparison found is DIY with at
  least one methodology flaw (durability mismatch is universal); none are
  citable as numbers.
- **Unknowns:** none material.

### Tier 4 — semantics only (claim C7)

#### Automerge, Yjs, Loro — CRDT libraries

- **What they are:** collaborative-data CRDT libraries (JSON/text types);
  all three are history-preserving to varying degrees. Loro is the best fit
  for a history-shaped workload — it markets version control, time travel
  and Git-like shallow snapshots as design goals.
- **Status:** Automerge 3.4.1 (2026-08-12, MIT); Yjs 13.6.32 (2026-08-04,
  MIT, solo maintainer "spare time"); Loro 1.15.0 (2026-08-27, MIT).
- **Benchmark fit:** the W6 merge-semantics row (deterministic re-slotting
  vs CRDT convergence), not a throughput row. Published numbers
  (dmonad/crdt-benchmarks; Loro's perf page) are text-edit workloads on
  versions that are already stale — e.g. Loro B4 replay 2,271 ms vs Yjs
  2,616 ms vs Automerge 7,109 ms (Loro 1.0.0-beta.2, Yjs 13.6.15, Automerge
  2.1.10) — none measure an append-log shape.
- **Pros:** Loro has a reproducible harness (`zxch3n/crdt-benchmarks`).
- **Cons:** all numbers need rerunning on current versions; no append-log
  workload exists for any of them; the semantics argument ("converge ≠
  correct", research 0001) is the actual point.

#### Marmot — the tunable-ack AP store

- **What it is:** leaderless distributed SQLite speaking MySQL wire
  protocol; 2PC with ONE/QUORUM/ALL acks; LWW + HLC conflict resolution
  (not CRDT — no merge semantics).
- **Status:** v2.9.13-beta (2026-04-26), MIT, independent; **beta only**.
- **Benchmark fit:** its ONE/QUORUM/ALL ack knob is a useful contrast to
  coppiz's `write.ack` (OQ 3), but there are zero published benchmarks and
  no stable release — semantics row only, if at all.
- **Cons:** no append-log/history semantics (LWW-by-write); no numbers.

#### Corrosion — no longer a store at all

- **What it is:** Fly.io's open-source gossip-based service discovery
  ("replacing Consul"), using cr-sqlite for conflict resolution. Originally
  conceived as the cr-sqlite sync daemon; it pivoted before first public
  release (v0.1.0, 2023-09-20 already had the service-discovery framing).
- **Benchmark fit:** none for coppiz — it is not a store. Listed so nobody
  re-adds it from the 2021-era survey rows.

## Out-of-the-box options

- **Already in the tree:** [OQ 54](../open-questions.md)'s internal
  measurement set (append latency at n = 1, memory/connections at 8/16/32,
  append-to-visible p50/p99, join/backfill of a 1 GB journal) is the seed —
  the coppiz driver doubles as the comparison driver. The e2e harness in
  `src/cluster/` (the in-memory hub transport with `drop`/`heal` edges, OQ
  19) already provides the partition-injection machinery W6 needs at the
  node-loop level.
- **Standard library / OS primitive:** a histogram, a JSON results writer
  and the workload spec are all small std-only Zig modules (ADR 0001). No
  external benchmark framework is needed for the coppiz side.
- **Do nothing:** keep citing the 2022 gcore test and vendor self-reports.
  Cost: every public number about coppiz's class of store is either absent
  or durability-mismatched; coppiz's own claims (C1–C7) would be
  unbacked.
- **Adjacent domain:** the CRDT benchmarks (dmonad/crdt-benchmarks, Loro's
  fork) are the only existing harnesses with published, reproducible
  numbers — they cover the wrong workload, which is itself a finding.
- **Buy, host, or delegate:** benchANT-style hosted benchmark vendors cover
  client-server DBs only — no coverage of SQLite/rqlite/dqlite/LiteFS/etcd
  exists there (absence-based). Nothing to buy.

## Comparison

| Option | Tier | Licence | Benchmark fit | Main risk |
|---|---|---|---|---|
| SQLite | 1 (baseline) | public domain | W1/W3/W8, n = 1 | none (the reference) |
| dqlite | 1 | LGPLv3+static | W1/W2/W4, 3-node | no published numbers; CP stall |
| rqlite | 1 | MIT | W1/W2/W4, 3-node + packaging | HTTP hop in the measurement; docs/version drift |
| libSQL | 2 | MIT | replica reads, C5/C6 | maintenance mode; single-writer |
| LiteFS | 2 | Apache-2.0 | FUSE tax, C4/C6 | stale releases; async-only; Linux+FUSE |
| CR-SQLite | 2 | MIT | semantics only (C7) | no history until v2 — cannot run W1 |
| etcd | 3 | Apache-2.0 | partition scenario (C4), CP ref | KV shape; stale official numbers |
| TigerBeetle | 3 | Apache-2.0 | ordering/durability ref | fixed schema; numbers not comparable across versions |
| NATS JetStream | 3 | Apache-2.0 | stream shape (C5) | messaging semantics; weak default durability |
| PostgreSQL | 3 | PostgreSQL | one server-baseline row | no citable PG-vs-embedded numbers |
| Loro/Automerge/Yjs | 4 | MIT | merge semantics (C7) | text-edit workloads; stale versions |
| Marmot | 4 | MIT | semantics only | beta; zero benchmarks |
| Corrosion | — | Apache-2.0 | none | not a store (dropped) |

## Evidence log

Read dates are 2026-08-28 throughout unless stated. `absence-based` rows
mean the sweep searched and did not find the thing; treat them as evidence,
not certainty.

| Claim | Source | Read on | Confidence |
|---|---|---|---|
| SQLite 3.53.4 released 2026-07-24; WAL-reset corruption bug fixed in 3.51.3 (2026-03-13) | https://sqlite.org/releaselog/3_53_4.html, https://sqlite.org/wal.html | 2026-08-28 | high |
| SQLite is public domain, full-time maintainers, support intent to 2050 | https://sqlite.org/about.html, https://sqlite.org/copyright.html | 2026-08-28 | high |
| WAL mode: commit = commit record appended to `-wal`; auto-checkpoint default 1000 pages | https://sqlite.org/wal.html | 2026-08-28 | high |
| `synchronous` semantics: FULL fsyncs WAL per commit (durable); NORMAL syncs at checkpoints only (may lose committed txns on power loss); OFF syncs nothing; EXTRA = FULL + dir sync (rollback mode) | https://sqlite.org/pragma.html#synchronous | 2026-08-28 | high |
| `speedtest1` is SQLite's official perf program; sqlite3 CLI has `.timer` | https://sqlite.org/src/file/test/speedtest1.c, https://sqlite.org/cli.html | 2026-08-28 | high |
| SQLite vs files: ~35% faster than individual files (2017-era, 3.19–3.20) | https://sqlite.org/fasterthanfs.html | 2026-08-28 | high (as published) |
| SQLite's official speed-comparison page is a retired historical artifact (2.7.6-era) | https://sqlite.org/speed.html | 2026-08-28 | high |
| dqlite v1.18.7 published 2026-07-02; repo active 2026-08-24 | GitHub API `repos/canonical/dqlite/releases/latest` | 2026-08-28 | high |
| dqlite is LGPLv3 with static-linking exception; Linux only (needs io_submit); LXD is the flagship user | https://github.com/canonical/dqlite, https://dqlite.io/docs/ | 2026-08-28 | high |
| dqlite: SQLite runs on a custom in-memory VFS; the raft log is what is persisted; commit = quorum has persisted the raft entries | https://raw.githubusercontent.com/canonical/dqlite-docs/main/explanation/replication.md | 2026-08-28 | high |
| dqlite raft log segments are opened O_DSYNC and appended via Linux KAIO; fsync/fdatasync also used for segment rename/truncate, snapshots, control files | https://raw.githubusercontent.com/canonical/dqlite/v1.18.7/src/raft/uv_writer.c, src/raft/uv_fs.c | 2026-08-28 | high |
| dqlite public API exposes no fsync/durability option (absence-based) | https://raw.githubusercontent.com/canonical/dqlite/v1.18.7/include/dqlite.h | 2026-08-28 | medium |
| dqlite is CP; transactions serializable but not linearizable; stale reads possible ~an election timeout | dqlite-docs `explanation/faq.md`, `explanation/consistency-model.md` | 2026-08-28 | high |
| dqlite-benchmark (go-dqlite `cmd/dqlite-benchmark`): `--duration --workers --workload kvwrite|kvreadwrite --kv-key-size --kv-value-size --disk-mode`; writes per-worker latency files | https://github.com/canonical/go-dqlite/tree/v3/cmd/dqlite-benchmark | 2026-08-28 | high |
| No official dqlite-published benchmark numbers exist (absence-based) | sweep of dqlite repos/docs | 2026-08-28 | high |
| gcore 2022: Chinook import Litestream ≈10 s, dqlite ≈22 s, rqlite ≈61.5 s; rough manual timing, no hardware disclosed | https://gcore.com/blog/comparing-litestream-rqlite-dqlite/ | 2026-08-28 | medium/low |
| rqlite v10.2.7 published 2026-07-06; MIT; repo pushed 2026-08-28; developed since 2014 | GitHub API `repos/rqlite/rqlite/releases/latest`, repo metadata | 2026-08-28 | high |
| rqlite: every write goes through raft and the raft log is fsynced after every write; disk I/O is the bottleneck | https://rqlite.io/docs/guides/performance/ | 2026-08-28 | high |
| rqlite runs SQLite in WAL mode with synchronous=OFF internally, switching to FULL at checkpoints; raft log is authoritative; journal/synchronous PRAGMAs are rejected | https://rqlite.io/docs/design/, https://rqlite.io/docs/api/api/, `db/db.go` @ v10.2.7 | 2026-08-28 | high |
| Current rqlite has no `-raft-on-disk`/raft-log-fsync flag; raft tuning flags are `-raft-snap*` + timeouts (absence-based) | https://rqlite.io/docs/guides/config/, source grep @ v10.2.7 | 2026-08-28 | medium |
| rqlite queued writes (`?queue`) batch and ack before raft persistence — data-loss window on crash; write `level=` names are read-consistency levels, not write levels | https://rqlite.io/docs/api/queued-writes/, https://rqlite.io/docs/api/read-consistency/ | 2026-08-28 | high |
| rqlite waits for quorum commit on every normal write; minority side unavailable on partition | https://rqlite.io/docs/faq/ | 2026-08-28 | high |
| rqbench (`cmd/rqbench`): `-a -n -b -p -x`, prints Requests/sec and Statements/sec; stress variant exists | https://raw.githubusercontent.com/rqlite/rqlite/v10.2.7/cmd/rqbench/README.md | 2026-08-28 | high |
| rqlite 2022 blog: ~220 INSERTs/s on a 3-node GCP cluster; queued writes ~15× higher (hardware unspecified, old version) | https://www.philipotoole.com/rqlite-trading-durability-for-performance/ | 2026-08-28 | medium |
| "rqlite is used in k0s" — claimed by gcore blog only; not found in k0s docs/README | gcore blog vs k0s sources | 2026-08-28 | low |
| libSQL: last `libsql-server` release v0.24.32 (2025-02-14); repo pushed 2026-08-26; README banner points new work to the Turso rewrite (beta) | GitHub API `repos/tursodatabase/libsql`, repo README | 2026-08-28 | high |
| libSQL licence history: SQLite blessing (2019-03) → Apache-2.0 (2022-09-30) → MIT (2022-10-06); LICENSE.md is MIT today | https://github.com/tursodatabase/libsql/commits/main/LICENSE.md, https://github.com/tursodatabase/libsql/issues/26 | 2026-08-28 | high |
| libSQL June-2024 licence-change plan: announced but not applied; outcome not verifiable at a primary source; a Turso employee stated "MIT" on HN (2025-03) | HN comment 43535943 (via Algolia); absence in repo/blog archives | 2026-08-28 | medium |
| libSQL embedded replicas: local file serves reads; writes go to the remote primary by default (`offline: true` opts into local writes); sync unit = one 4 kB page frame | https://docs.turso.tech/features/embedded-replicas | 2026-08-28 | high |
| libSQL consistency: primary ops linearizable; replicas may lag; per-connection monotonic reads | https://raw.githubusercontent.com/tursodatabase/libsql/main/docs/CONSISTENCY_MODEL.md | 2026-08-28 | high |
| Turso vendor microbench: prepared `SELECT … LIMIT 1` ≈ 190 ns / 5.2M elem/s (cache-resident, 2023) | https://web.archive.org/web/2024/https://turso.tech/blog/microsecond-level-sql-query-latency-with-libsql-local-replicas-5e4ae19b628b | 2026-08-28 | high as published / low as comparative |
| No independent third-party libSQL benchmark exists (absence-based) | sweep (HN Algolia, search) | 2026-08-28 | high |
| LiteFS v0.5.14 (2025-04-22); repo pushed 2026-05-11; Apache-2.0; Ben Johnson sole maintainer; docs: "not able to provide support"; no release since 2025-04 | GitHub API `repos/superfly/litefs`, releases, https://fly.io/docs/litefs/ | 2026-08-28 | high |
| LiteFS: FUSE passthrough; per-transaction page sets → LTX files over HTTP (port 20202); single primary via Consul lease (TTL ≥10 s) or static; replicas read locally | https://fly.io/docs/litefs/how-it-works/, https://fly.io/docs/litefs/config/ | 2026-08-28 | high |
| LiteFS replication is asynchronous by default; sync replication "planned for future development"; split-brain detected via XOR-of-CRC64 in LTX; diverged node resnapshots | https://fly.io/docs/litefs/how-it-works/ | 2026-08-28 | high |
| LiteFS autostop caveat: a stale machine winning the lease can discard newer changes, "risking rollback and data loss" | https://fly.io/docs/litefs/ | 2026-08-28 | high |
| LiteFS author: ~250 µs per write(2)+fsync(2), ~100 µs per read; "thousands of writes per second … probably isn't a good fit" | HN item 33204347 (via Algolia) | 2026-08-28 | medium (author-claimed) |
| LiteFS FAQ: FUSE limits write throughput to ~100 tps; target DB size ≤ 10 GB | https://fly.io/docs/litefs/faq/ | 2026-08-28 | high |
| Third-party LiteFS measurement (single-node, proxy, no replication exercised): 62 rps vs 244 rps without LiteFS (author disclaims) | https://web.archive.org/web/2024/https://maori.geek.nz/golang-sqlite-on-fly-io-with-litefs-a-quick-benchmark-9aa7aeee9561 | 2026-08-28 | high as published / low as cluster data |
| LiteFS requires Linux + FUSE (author confirms Linux-only) | HN item 33204347; https://fly.io/docs/litefs/getting-started/ | 2026-08-28 | high |
| CR-SQLite v0.16.3 (2024-01-17); MIT (npm declares Apache-2.0); recent commits are build fixes only | GitHub API `repos/vlcn-io/cr-sqlite`, npm `@vlcn.io/crsqlite` | 2026-08-28 | high |
| CR-SQLite: "inserts into CRRs are 2.5× slower than regular SQLite; reads the same" (vendor claim); no numeric benchmarks elsewhere | https://github.com/vlcn-io/cr-sqlite README + `py/perf/perf.ipynb` | 2026-08-28 | medium |
| CR-SQLite approach 1 "keeps no history"; the history/GC design is approach 2, "to be implemented in v2" — v2 has not landed | https://github.com/vlcn-io/cr-sqlite README | 2026-08-28 | high |
| vlcn↔Fly: no formal acquisition announcement found; inferred from repo transfer + contributors + Fly's corrosion blog | absence + https://fly.io/blog/corrosion/, contributor profiles | 2026-08-28 | medium |
| Corrosion is Fly.io's gossip service discovery ("replacing Consul") using cr-sqlite for conflicts; v1.0.0 (2026-05-14), Apache-2.0; no numeric benchmarks | https://github.com/superfly/corrosion, https://fly.io/blog/corrosion/ | 2026-08-28 | high |
| Marmot v2.9.13-beta (2026-04-26), MIT; 2PC ONE/QUORUM/ALL acks; LWW+HLC (not CRDT); zero published benchmarks; no stable release | https://github.com/maxpert/marmot, releases | 2026-08-28 | high |
| Automerge 3.4.1 (2026-08-12), MIT; 2.0-blog replay numbers 1,816 ms vs Yjs 1,074 ms (2023, Ryzen 9 7900X); no live perf docs page (404) | npm/GitHub API; https://automerge.org/blog/automerge-2/ | 2026-08-28 | high |
| Yjs 13.6.32 (2026-08-04), MIT, solo maintainer; canonical reference is dmonad/crdt-benchmarks (B1.1 append 6,000 chars: yjs 188 ms; B4 replay 259,778 ops: 5,714 ms — yjs 13.6.11, i5-8400) | npm/GitHub API; https://github.com/dmonad/crdt-benchmarks | 2026-08-28 | high |
| Loro 1.15.0 (2026-08-27), MIT; perf page (Loro 1.0.0-beta.2 vs Yjs 13.6.15 vs Automerge 2.1.10): B4 replay loro 2,271 ms / yjs 2,616 ms / automerge 7,109 ms; C1.1 loro 2,335 ms / yjs 27,138 ms / automerge 50,692 ms | https://github.com/loro-dev/loro-docs/blob/main/pages/docs/performance/index.md | 2026-08-28 | high (vendor-run, reproducible harness) |
| Loro markets version control / time travel / Git-like shallow snapshots — history-shaped workloads are a stated design goal | https://github.com/loro-dev/loro README, https://loro.dev/blog/v1.0 | 2026-08-28 | high |
| etcd v3.7.1 (2026-07-23), Apache-2.0, CNCF; maintenance lines v3.6.14 and v3.5.33 same month | GitHub API `repos/etcd-io/etcd/releases/latest` + releases page | 2026-08-28 | high |
| etcd: majority (n/2)+1 must agree before commit; minority side cannot commit during a partition | https://etcd.io/docs/v3.6/faq/ | 2026-08-28 | high |
| etcd tuning: `wal_fsync_duration_seconds` p99 should be < 10 ms; fsync on the write path | https://etcd.io/docs/v3.6/faq/, https://etcd.io/docs/v3.6/tuning/ | 2026-08-28 | high |
| etcd official `benchmark` tool: `benchmark put --endpoints --total --key-size --val-size --clients --conns` | https://github.com/etcd-io/etcd/tree/main/tools/benchmark | 2026-08-28 | high |
| bbolt `bench`: `bbolt bench db -batch-size 400 -key-size 16` (seq write/read modes) | https://github.com/etcd-io/bbolt/tree/main/cmd/bbolt | 2026-08-28 | high |
| etcd README "10,000 writes/sec" (undated); official benchmark doc is 2016-era (etcd 2.2.0, GCE n1-highcpu-2) — no current official table | https://github.com/etcd-io/etcd README, https://etcd.io/docs/v3.6/benchmarks/ | 2026-08-28 | high (as historical record) |
| TigerBeetle 0.17.9 (2026-07-03); Apache-2.0 with the LICENSE file unchanged since 2021-01 — no 2024 relicensing in the record | GitHub API `repos/tigerbeetle/tigerbeetle/commits?path=LICENSE`, releases | 2026-08-28 | high |
| TigerBeetle: VSR; ground state = immutable hash-chained append-only log of prepares (batches of 8,000); LSM forest, 0.5 MiB blocks; synchronous commit to WAL, flexible quorums 3/6 | https://raw.githubusercontent.com/tigerbeetle/tigerbeetle/main/ARCHITECTURE.md | 2026-08-28 | high |
| TigerBeetle VOPR: production cluster on one thread with fault injection, seed-reproducible | https://raw.githubusercontent.com/tigerbeetle/tigerbeetle/main/docs/internals/vopr.md | 2026-08-28 | high |
| `tigerbeetle benchmark`: canonical workload by default, prints throughput + p1/p50/p99/p100; "default benchmark numbers are not necessarily comparable across different TigerBeetle versions" | src/tigerbeetle/benchmark_driver.zig, benchmark_load.zig, docs/internals/HACKING.md | 2026-08-28 | high |
| TigerBeetle "A Trillion Transactions" scale test (2026-03-19); numbers in the talk video, not the text; DevHub public URL not found | https://tigerbeetle.com/blog/2026-03-19-a-trillion-transactions | 2026-08-28 | high (test's existence) |
| nats-server v2.14.6 (2026-08-27), Apache-2.0, CNCF project; JetStream GA since v2.2.0 | GitHub API `repos/nats-io/nats-server/releases/latest`, repo README | 2026-08-28 | high |
| JetStream: stream = sequence-numbered append-only log; KV is a stream bucket (`KV_<bucket>`, value = last message on the subject) | https://docs.nats.io/nats-concepts/jetstream/key-value-store | 2026-08-28 | high |
| JetStream: R1 default, R3 "production floor", R5 max; PubAck only after a majority has the message; writes blocked without a majority | https://docs.nats.io/nats-concepts/jetstream/streams, .../surviving-node-loss | 2026-08-28 | high |
| JetStream file storage does not fsync every write; `sync_interval` forces periodic fsync, `always` = every write ("will degrade the max throughput"); `no_ack` stream option | https://docs.nats.io/reference/jetstream/api/stream/create, https://docs.nats.io/reference/2.11/config/jetstream/sync_interval | 2026-08-28 | high |
| `nats bench js pub --create --msgs --clients`, `--throughput` flag "useful for head-to-head comparisons against Kafka's kafka-producer-perf-test.sh"; `nats latency` tool | https://github.com/nats-io/natscli | 2026-08-28 | high |
| No official absolute JetStream benchmark table (absence-based); natscli README sample numbers are machine-specific | sweep | 2026-08-28 | high |
| PostgreSQL 18.6 (2026-08-13); PostgreSQL License; pgbench default is a 7-statement TPC-B-inspired txn (update-dominated, one append); `-f -n -M prepared -c -j -T -P -l` flags; `fsync=on`/`synchronous_commit=on` defaults | https://www.postgresql.org/, https://www.postgresql.org/docs/current/pgbench.html, .../runtime-config-wal.html | 2026-08-28 | high |
| PG-vs-embedded comparisons found are all DIY with ≥1 methodology flaw (durability mismatch universal): andrecasal (SQLite NORMAL vs PG fsync), intuitem (tiny n, untuned PG, self-flagged), deployn (mixed hardware + durability off), PGlite (no disclosure) | https://github.com/andrecasal/sqlite-vs-postgres-benchmark, https://intuitem.com/postgresql-vs-sqlite-2026-benchmark/, https://deployn.de/en/blog/db-performance/, https://pglite.dev/benchmarks | 2026-08-28 | medium each |
| No rigorous SQLite vs dqlite vs rqlite benchmark exists publicly; no rqlite-vs-etcd head-to-head; no LiteFS vs dqlite vs CR-SQLite benchmark (Fly blog SQLite slugs enumerated via Wayback CDX — no such posts) | sweeps; http://web.archive.org/cdx/search/cdx?url=fly.io/blog/*&filter=urlkey:.*sqlite.* | 2026-08-28 | high (absence-based) |
| TyrantDB (datafuselabs) does not exist publicly (0 GitHub repos match; repo 404) | https://github.com/search?q=tyrantdb&type=repositories | 2026-08-28 | high (absence-based) |
| benchANT covers client-server DBs only; no coverage of SQLite/rqlite/dqlite/LiteFS/etcd | https://benchant.com/blog, https://benchant.com/more-solutions/benchmarking-platform | 2026-08-28 | medium (coverage claim) |
| sqg.dev driver-level benchmark (2026-01-19): insertUser turso 63,017 ops/s vs libSQL 28,385 vs better-sqlite3 53,693 (Node.js; driver-level, not engine; not distributed) | https://sqg.dev/blog/sqlite-driver-benchmark/ | 2026-08-28 | high as published |
| Methodology: percentiles can't be averaged across runs; merge histograms; focus p99/p99.9 | https://raw.githubusercontent.com/brianfrankcooper/YCSB/master/README.md | 2026-08-28 | high |
| Methodology: commit latency = fdatasync + network RTT; disclose hardware, versions, workload, commands; rerun in your own environment | https://etcd.io/docs/v3.4/op-guide/performance/ | 2026-08-28 | high |
| Methodology: pgbench scale factor should exceed client count; run the client from a separate machine; consider separate WAL filesystems | https://wiki.postgresql.org/wiki/Pgbench | 2026-08-28 | high |
| Methodology: report avg + p95 + p99 + ops/s + resource utilization + process audit trail | https://benchant.com/more-solutions/benchmarking-platform | 2026-08-28 | medium (vendor, standard practice) |
| Stanford CS244b "Distributed SQLite" project PDF exists but could not be opened from the research environment (fetch failed) | https://www.scs.stanford.edu/20sp-cs244b/projects/Distributed%20SQLite.pdf | 2026-08-28 | low (unread) |

## Open questions

Split into **what this sweep could not find** (for a later full rerun with
working search) and **decisions the operator must make** (which this doc
cannot settle).

### Not found in this sweep (rerun targets)

- **Hacker News threads with real measured numbers.** The Algolia API was
  unreachable; a rerun should search HN for "rqlite benchmark", "dqlite
  benchmark", "LiteFS benchmark", "libSQL benchmark", "TigerBeetle
  benchmark" and extract measured figures + hardware.
- **Any 2024–2026 rigorous third-party head-to-head benchmark** of the
  Tier-1/tier-2 systems. Only the crude 2022 gcore test and vendor
  self-reports exist in this sweep. A rerun should try: "replicated SQLite
  benchmark 2025", "dqlite vs rqlite benchmark", "LiteFS vs dqlite", recent
  YouTube/talk write-ups, and the [Stanford CS244b project PDF]
  (https://www.scs.stanford.edu/20sp-cs244b/projects/Distributed%20SQLite.pdf)
  which failed to fetch here.
- **TigerBeetle DevHub performance page** — referenced in repo docs, public
  URL not found. Rerun should also extract the "A Trillion Transactions"
  numbers from the talk video into text.
- **libSQL June-2024 licence-change outcome** — announced, not applied,
  no primary source found for the plan or its resolution. Rerun should check
  Turso's GitHub org issues and archived blog posts.
- **"rqlite used in k0s"** — only the gcore blog claims it. Rerun: k0s
  source/docs search.
- **NATS CNCF graduation status** — membership confirmed, graduation not.
- **dqlite official benchmark numbers** — none exist as of this sweep; a
  rerun should also confirm the fsync-before-ack ordering in the source
  (currently inferred, medium confidence).
- **Verified distro package versions** for SQLite; the 2022
  [SQLite-vs-filesystem study]
  (https://golangexample.com/an-unscientific-benchmark-of-sqlite-vs-the-file-system-btrfs/)
  (linked from sqlite.org, not opened).
- **rqlite glibc requirement inconsistency** (2.32 on one page, 2.34 on
  another) and whether historical `-raft-on-disk`-style flags existed.
- **Fly.io blog post enumeration was partial** (Wayback CDX only); a rerun
  with search should check for "LiteFS benchmark" posts after 2025-04.
- **Loro v1.0 announcement publication date** (page carries none).

### Decisions for the operator (block the harness, not the research)

- **What counts as "the benchmark machine"** (OQ 54 needs the same answer):
  a dev laptop, a cloud VM, a bare-metal box? The suite must pin one and
  record its fingerprint. Recommendation candidates: a fixed cloud VM type
  (reproducible) and the primary dev machine (representative of the first
  host).
- **Which tiers ship in v1 of the suite.** Tier 1 alone covers the named
  claims (C1, C2, C4); tiers 2–4 each add driver build/maintenance cost.
  Recommendation candidate: Tier 1 + etcd (partition row) + TigerBeetle
  (Zig reference) + LiteFS (FUSE tax, cheapest driver) in v1; libSQL,
  JetStream, Postgres, CRDT semantics in v2.
- **Whether the suite is a runbook or a gate.** Perf comparisons are flaky
  as CI gates; recommendation candidate: a manual runbook executed per
  release milestone, not a build gate.
- **Which `write.ack`/durability config is the coppiz DURABLE default** for
  the comparison (OQ 3 is still open) — the suite needs it pinned.
- **Whether TigerBeetle earns a row** given the fixed-schema mapping cost;
  and whether the CRDT family gets the W6 semantics row at all.

## What would change the answer

- **A rigorous third-party head-to-head benchmark appearing** — it would
  become the citation instead of this suite (and its methodology a reference).
- **dqlite publishing official numbers; rqlite/LiteFS/libSQL changing
  licence or maintenance posture** (libSQL's Turso rewrite shipping could
  move it from "maintenance mode" to "rewrite wins").
- **CR-SQLite v2 landing** (history semantics) — would reopen its
  append-log suitability.
- **coppiz's own claims changing** — a quorum mode (OQ 1) or a read
  consistency guarantee (OQ 31) would add rows, not remove them.
- **The tier numbers changing** ([OQ 54](../open-questions.md) measurements)
  — the comparison rows stay, the internal reference points move.

## References

- **coppiz records:** [docs/README.md](../README.md#architecture),
  [OQ 3, 19, 36, 47, 54](../open-questions.md),
  [PRD 0001](../prds/0001-journal-core.md), [PRD 0003](../prds/0003-membership-and-leadership.md),
  [PRD 0005](../prds/0005-embedding-the-library-as-the-product.md),
  [ADR 0001](../adrs/0001-zig-0-16-standard-library-only-for-the-core.md),
  [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md),
  [research 0001](0001-evidence-carried-from-the-state-store-survey.md).
- **Tier 1:** sqlite.org (releaselog, wal.html, pragma.html, speedtest1,
  speed.html, fasterthanfs.html), github.com/canonical/dqlite + go-dqlite +
  dqlite-docs, dqlite.io, gcore.com/blog/comparing-litestream-rqlite-dqlite/,
  github.com/rqlite/rqlite + rqlite.io (docs: performance, design, api,
  queued-writes, read-consistency, faq), philipotoole.com.
- **Tier 2:** github.com/tursodatabase/libsql + docs.turso.tech, turso.tech
  blog (via Wayback), github.com/superfly/litefs + fly.io/docs/litefs +
  fly.io/blog (introducing-litefs, wal-mode-in-litefs), maori.geek.nz (via
  Wayback), github.com/vlcn-io/cr-sqlite, fly.io/blog/corrosion.
- **Tier 3:** etcd.io/docs/v3.6 (faq, tuning, benchmarks) + v3.4
  (op-guide/performance), github.com/etcd-io/bbolt, tigerbeetle.com +
  github.com/tigerbeetle/tigerbeetle (ARCHITECTURE.md, vopr.md, HACKING.md,
  benchmark sources, blog), docs.nats.io (jetstream: streams, KV,
  surviving-node-loss, acknowledgment, config) + github.com/nats-io/natscli,
  postgresql.org (docs/current/pgbench, runtime-config-wal) +
  wiki.postgresql.org/wiki/Pgbench.
- **Tier 4:** github.com/dmonad/crdt-benchmarks, github.com/zxch3n/crdt-benchmarks,
  github.com/loro-dev/loro + loro-docs performance page, automerge.org
  (blog/automerge-2), yjs.dev, github.com/maxpert/marmot.
- **Survey & methodology:** YCSB README, andrecasal/sqlite-vs-postgres-benchmark,
  intuitem.com/postgresql-vs-sqlite-2026-benchmark, deployn.de, pglite.dev/benchmarks,
  sqg.dev/blog/sqlite-driver-benchmark, benchANT, scs.stanford.edu CS244b
  project page (unread).

## Appendix

### Per-system sweep scope (2026-08-28)

- **Agent A (trio):** SQLite (status, WAL/synchronous semantics, speedtest1,
  published numbers, distro packages), dqlite (status, licence, durability
  via source, knobs, benchmark tooling, published numbers), rqlite (status,
  licence, raft-fsync semantics, flags, rqbench, published numbers).
- **Agent B:** libSQL (status, licence history, embedded-replica semantics,
  sqld modes, benchmarks), LiteFS (status, FUSE/LTX/lease model, async
  semantics, requirements, benchmarks, gaps).
- **Agent C:** CR-SQLite (status, semantics, acquisition question, perf),
  Corrosion (status, pivot), Marmot (status, ack model, benchmarks),
  Automerge/Yjs/Loro (status, perf pages, append-log suitability).
- **Agent D:** etcd (status, quorum/partition, WAL, benchmark tool,
  published numbers), TigerBeetle (status, licence history, VSR/append-only
  model, benchmark tool, published numbers), NATS JetStream (status, stream
  semantics, durability knobs, nats bench).
- **Agent E:** PostgreSQL/pgbench (version, licence, append test, published
  comparisons), head-to-head survey (gcore, rqlite, etcd, LiteFS, CR-SQLite,
  Turso, sqg.dev, benchANT, TyrantDB, HN), methodology references (YCSB,
  etcd guide, PG wiki, benchANT).

### Sweep limitations

General web search and the HN Algolia API were unreachable or bot-walled
from the research environment for the whole day; all claims were verified by
direct fetch of named primary sources. Categories that depend on open search
(HN-measured numbers, recent third-party comparisons, forum posts) are
therefore under-covered and listed under
[Open questions](#open-questions). Absence-based claims are marked as such in
the evidence log; none should be read as "does not exist", only "not found
by this sweep".
