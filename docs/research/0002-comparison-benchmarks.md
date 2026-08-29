# Research - Comparison benchmarks: which systems, which workloads, and how to run them fairly

## Status

Draft - re-read 2026-08-29. Live web search first, then direct primary-source
fetch of every cited host. Search was reachable this run (it was not on
2026-08-28). Every evidence-log row and every prior rerun target carries
this run's date and a verdict.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

coppiz is positioned as a library to "just use" the way SQLite, dqlite or
rqlite are ([docs/README.md](../README.md#hosts), [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)).
Which stores should the comparison benchmark suite pit against it, what
workloads and metrics make each comparison fair, and what is the current
state of each candidate - version, licence, durability semantics, benchmark
tooling - as of 2026-08-29?

This note answers the *how*: the harness design (workloads, metrics,
durability contract, fairness rules) and the evidence on each candidate. It
does not choose the final system list; that is a decision ([RFC 0004]
candidate). The internal measurement set that replaces the tier numbers is
[OQ 54](../open-questions.md#oq-54); this suite shares its harness where possible
and adds the external comparison rows.

## TL;DR

- **The core trio is fixed by the product sentence, not by taste.** SQLite
  (single-node baseline, clanker's status quo), dqlite (embedded replicated
  library), rqlite (service replicated) are the three named comparators in
  [docs/README.md](../README.md#hosts). Everything else is an extension that
  must justify itself by the claim it tests - [Options found](#options-found).
- **No rigorous head-to-head benchmark of these systems exists in public.**
  The closest remain a crude 2022 gcore wall-clock test (Litestream ≈10 s,
  dqlite ≈22 s, rqlite ≈61.5 s to import Chinook; URL moved to
  `/learning/`), a qualitative 2020 Stanford student project, vendor
  self-reports, a 2025 Aalto thesis that cites those vendor ceilings
  rather than measuring them, and a 2026 SoftwareMill TigerBeetle-vs-Postgres
  run (wrong data shape for this suite). A fair comparison is itself a
  contribution - `high`, absence-based after search-first plus fetch:
  [gcore](https://gcore.com/learning/comparing-litestream-rqlite-dqlite/),
  [evidence log](#evidence-log).
- **The single most common flaw in every published comparison is durability
  mismatch** - SQLite `synchronous=NORMAL` or OFF compared against raft
  systems that fsync every write. The suite must define a durability
  contract (DURABLE / BATCHED / ASYNC) and compare within a class only.
  [etcd's own guide](https://etcd.io/docs/v3.4/op-guide/performance/)
  states commit latency = fdatasync + RTT - `high`.
- **Each candidate has a different durability floor that must be pinned
  before benchmarking:** SQLite WAL `synchronous=FULL` (fsync WAL per
  commit), dqlite fixed O_DSYNC raft log (no knobs), rqlite raft log fsynced
  per write, etcd WAL fsync, TigerBeetle synchronous 3/6 quorum,
  JetStream `sync_interval=always` + R3 (PubAck ≠ fsync by default),
  LiteFS async by default (data-loss window on primary crash) - all verified
  at source, 2026-08-29, [evidence log](#evidence-log).
- **Two of the "modern entrants" are maintenance-risk rows, not fixtures:**
  libSQL's innovation has moved to the Turso rewrite (README banner, last
  `libsql-server` *release* still 2025-02-14; Turso 0.7.0 blog
  ([turso.tech/blog/turso-0.7.0](https://turso.tech/blog/turso-0.7.0),
  2026-07-13) dropped its beta warning; the libSQL README still says Turso
  is in beta) and LiteFS has had no release since 2025-04-22 plus a
  documented "no support" notice - both still benchmarkable, both flagged.
  CR-SQLite has no append/history semantics until its v2 -
  [Options found](#cr-sqlite---the-ap-sqlite-extension).
- **The AP/CRDT family (Loro, Automerge, Yjs, Marmot) is a semantics
  comparison, not a throughput one:** published numbers are text-edit
  workloads (dmonad/crdt-benchmarks, Loro's perf page), none measure an
  append-log shape, and none show merge determinism. A partition/heal
  scenario row is the honest comparison; a throughput row is not -
  [Options found](#automerge-yjs-loro---crdt-libraries).

## Scope and method

- **Searched (2026-08-29, this run):** live web search first (~25 queries:
  current versions/licences of the named stores; "rqlite/dqlite/LiteFS/libSQL/
  TigerBeetle benchmark"; "dqlite vs rqlite 2025/2026"; DevHub / Trillion
  Transactions; libSQL June-2024 licence; NATS CNCF graduation; dqlite official
  numbers; Loro v1.0 date; rqlite glibc / `-raft-on-disk`; SQLite distro
  versions; sqlite-vs-filesystem; Fly.io LiteFS posts after 2025-04; HN /
  lobste.rs / Reddit measured numbers).

  Then direct fetch of every cited
  primary host: GitHub API/raw/releases, `sqlite.org`, `rqlite.io`,
  `dqlite.io` (redirects to `canonical.com/dqlite/docs`), `fly.io`,
  `docs.turso.tech`, `postgresql.org`, `etcd.io`, `tigerbeetle.com`,
  `docs.nats.io` (several paths redirected), `nats.io`, `cncf.io`, npm and
  crates.io registries, Wayback CDX, HN Algolia API, Debian/Ubuntu package
  pages, the CS244b PDF, loro.dev. Query list: scratch `search-log.md` and
  the [Appendix](#appendix).
- **Not searched / limits:** GitHub *code* search for `tyrantdb` returned
  HTTP 429 this run (the absence claim is therefore not re-confirmed by
  search). Video contents of the Trillion Transactions talk were not
  re-watched; a YouTube transcript from web search was used as a lead, not
  as a substitute for the blog's own text. The June-2024 libSQL
  licence-change *announcement* was searched and not found - recorded as
  unresolved, not as proof it never existed.
- **Freshness:** every evidence-log row re-stamped 2026-08-29. Newest
  sources this run: nats-server v2.14.6 (2026-08-27) and Loro 1.15.0
  (2026-08-27); rqlite repo pushed 2026-08-28; Turso rewrite repo pushed
  2026-08-28. Release cadence, licences and maintenance posture age fast -
  the versions quoted here are a snapshot. `absence-based` means this run
  searched *and* fetched named sources and did not find the thing.
- **Prior sweeps:** 2026-08-28 (direct fetch only; search walled) and the
  same-day shell follow-up (*sweep 2*). Those dates stay in the history;
  they are not this run's read date. New or corrected evidence is marked
  *2026-08-29* in the evidence log.

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

- **W1 - single-writer append (n = 1).** One writer appends N entries with
  exponential inter-arrival. Measures the floor: pure sequential append cost
  plus fsync policy. Run in both durability classes (see below).
- **W2 - multi-writer append (3 nodes).** 2–3 writers, one journal. For
  coppiz: writers land on different members, forward to the leader
  ([docs/README.md](../README.md)); for raft systems: clients
  hit the leader. Measures ordering contention and the leader write path.
- **W3 - read-your-writes / tail read.** Immediately after an append, read
  the latest k entries (k = 1, 64). Local reads for coppiz/SQLite/libSQL
  replicas; round-trip reads for services.
- **W4 - follow / stream.** A cursor consumer keeps up with the tail over
  time. Relevant rows: coppiz, JetStream (subscription), SQLite (poll).
  Optional in v1.
- **W5 - join/backfill.** A fresh member joins a cluster holding a 1 GB
  journal; measure time-to-head, MB/s, and peak network. [OQ 54](../open-questions.md#oq-54)
  already names this; it is the number hosts actually feel.
- **W6 - partition and heal (3 nodes, behaviour).** Cut the leader (or one
  side) off for T seconds; record write availability on each side
  (CP: refused; coppiz `seniority`: both sides write), then heal. Outcomes:
  zero data loss, deterministic merge (both sides' appends present in a
  reproducible order), convergence time, and - for CP systems - the stall
  behaviour itself. This is where coppiz's `seniority` AP default
  ([PRD 0003](../prds/0003-membership-and-leadership.md)) is demonstrated or
  refuted; `configured`+`stall` is the same test with the opposite expected
  outcome.
- **W7 - memory and connections at n = 1, 3, 6.** RSS per member, fd count,
  connection count ([OQ 54](../open-questions.md#oq-54) sibling). The "library vs
  server" claim (C3) mostly shows up here.
- **W8 - multi-process one-file (SQLite-only row).** SQLite's file-lock
  habit coppiz v1 lacks ([OQ 47](../open-questions.md#oq-47)). Benchmark it anyway:
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
([evidence log](#evidence-log) - andrecasal, deployn, sqlite.org speed page
being the oldest examples).

### Topology matrix

- **Single node:** SQLite, coppiz n = 1, libSQL (embedded), Postgres
  (single server), LiteFS (single node - isolates the FUSE tax).
- **3-node cluster:** coppiz, dqlite, rqlite, etcd, JetStream R3, LiteFS
  (needs Consul), libSQL primary + replicas (replica *reads* are the point),
  TigerBeetle (fixed-schema mapping, see below).
- **Partition (3-node):** coppiz, etcd, rqlite, dqlite, JetStream R3 -
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
   - pin the version and say so. Same spirit for everything else.
6. **Behavioural rows are pass/fail + timing**, never ops/s.
7. **Harness code lives under the gate coverage** - a `.zig` harness outside
   `src/` needs its own test root or `checked_paths` entry
   ([AGENTS.md](../../AGENTS.md)); prefer `src/bench/` so the lint gates
   cover it.

### Driver notes per candidate

- SQLite: `speedtest1` for the official baseline; a small C driver (via the
  amalgamation) for the matched append workload. Pin ≥ 3.51.3 (WAL-reset
  corruption bug fixed in 3.51.3).
- dqlite: `dqlite-benchmark` from go-dqlite already has
  `kvwrite`/`kvreadwrite` workloads and a `--disk` experimental flag.
- rqlite: official `rqbench` (`cmd/rqbench`) + `?timings`.
- etcd: official `benchmark` tool (`benchmark put --total --key-size
  --val-size --clients`); bbolt `bench` for the storage layer.
- TigerBeetle: `tigerbeetle benchmark` with default "canonical workload";
  an append-log shape must be mapped onto transfers (fixed schema - the
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
claim it tests. Status figures were read on 2026-08-29 at the cited sources;
full claim-level tracing is in the [Evidence log](#evidence-log). Verdicts
from that re-read are in the log.

### Tier 1 - the named trio (claims C1, C2, C4)

#### SQLite - the single-node baseline and clanker's status quo

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
- **Unknowns:** none material for versions. Distro packages as of 2026-08-29:
  Debian stable (trixie) 3.46.1-7+deb13u1; Debian sid 3.53.4-2; Ubuntu noble
  3.45.1-1ubuntu2.7; Ubuntu resolute 3.46.1-9ubuntu0.2. Current LTS/stable
  packages are **below** the 3.51.3 WAL-reset floor - pin the amalgamation,
  not the distro. The 2017 "35% faster than files" figure is still the
  sqlite.org page; the linked 2022 study is github.com/chrisdavies/dbench.

#### dqlite - the embedded replicated library (Canonical)

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
- **Unknowns:** the fsync-before-ack ordering is still inferred from source
  (O_DSYNC on segment files in `uv_fs.c`; `RWF_DSYNC` is present but
  commented out in `uv_writer.c`) rather than documented - medium
  confidence, unchanged. MicroCeph/MicroCloud usage claimed but not
  re-verified this run. No official published numbers still.

#### rqlite - the service shape of the same idea

- **What it is:** standalone `rqlited` daemon, SQLite + Hashicorp raft,
  HTTP API. Not embedded; you write through HTTP.
- **Status:** v10.2.7 (2026-07-06), MIT, active (repo pushed 2026-08-28).
- **Benchmark fit:** quantifies the packaging tax (C3) that library-first
  claims to avoid; raft-fsync-per-write makes DURABLE the default.
- **Pros:** official `rqbench`; well-documented durability semantics
  (raft log fsynced per write; SQLite layer runs WAL `synchronous=OFF` with
  periodic FULL checkpoints - the raft log is authoritative).
- **Cons:** queued writes (the only non-raft write path) trade durability
  for speed. Historical `-on-disk`/`-ondisk` selected a SQLite *file* vs
  in-memory database (v4-era README); it was not a raft-log fsync knob.
  Current docs have `-raft-snap*` + timeouts only. "used in k0s" remains
  unsubstantiated (k0s README and stable docs have no rqlite mention).
- **Unknowns:** none for the glibc floor as a *single* number - rqlite's
  own pages still disagree: FAQ says glibc ≥ 2.34, building-from-source
  says 2.32 or later (error sample still mentions `GLIBC_2.33`). Pin the
  page you built from.

### Tier 2 - same niche, modern entrants (claims C3, C5, C6, C7)

#### libSQL / Turso - the fork whose pitch is "SQLite as a library you ship"

- **What it is:** SQLite fork; embedded C library, `sqld` server, and
  "embedded replicas" (local file serves reads; writes go to the remote
  primary unless `offline: true`).
- **Status:** MIT (history: blessing 2019-03 → Apache-2.0 2022-09-30 → MIT
  2022-10-06); last `libsql-server` GitHub *release* still v0.24.32
  (2025-02-14); repo pushed 2026-08-26. README banner (2026-08-29) says new
  features are in the Turso rewrite and "If you're starting a new project,
  you probably want to look into Turso." Turso 0.7.0 blog
  (https://turso.tech/blog/turso-0.7.0, published 2026-07-13) dropped the
  rewrite's beta warning; the libSQL README still calls Turso "currently
  in beta". **Maintenance mode signal for libSQL; rewrite is the active
  tree.**
- **Benchmark fit:** replica *reads* (local) + write path to primary; the
  closest in spirit to coppiz's read-local design; C5/C6.
- **Pros:** three packaging shapes to compare; vendor microbench (~190 ns
  prepared SELECT) gives a cache-resident ceiling.
- **Cons:** single-writer; replicas lag (eventual consistency); the June
  2024 licence-change *announcement* is still not found at a primary source
  (searched 2026-08-29); current MIT is confirmed by LICENSE.md, GitHub
  licence metadata, and the 2025-03-31 HN statement. No independent
  *engine* benchmarks exist (sqg.dev is driver-level).
- **Unknowns:** a versioned C-library release artifact (GitHub *releases*
  are `libsql-server-vX.Y.Z`; sqlite-base tags like `version-3.39.4` exist
  but are not the advertised C-library product). The June-2024 plan text.

#### LiteFS - SQLite replicated at the file layer (Fly.io)

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
- **Unknowns:** no multi-node replication benchmark found this run either
  (Wayback CDX of fly.io/blog/* litefs after 2025-04-22 is re-crawls of
  introducing-litefs and litefs-cloud, not new measurements). The
  single-node 62 rps vs 244 rps page is still on Wayback. Write-forwarding
  PR shipped-or-not was not re-opened in source this run.

#### CR-SQLite - the AP SQLite extension

- **What it is:** SQLite loadable extension; tables become CRRs (conflict
  -free replicated relations); merges resolved by per-column CRDTs.
- **Status:** v0.16.3 (2024-01-17), MIT in the repo (npm `@vlcn.io/crsqlite`
  still declares Apache-2.0). Repo pushed 2026-08-10; recent commits are
  still build fixes. Fly.io maintains a breaking fork
  (`superfly/cr-sqlite` 0.17.0) for Corrosion. No acquisition was ever
  announced.
- **Benchmark fit:** semantics row (C7): its own README says inserts are
  "2.5× slower than regular SQLite tables" and, decisively, **it keeps no
  history** - the causal event-log design is "v2". An append-log comparison
  cannot be run against v1.
- **Pros:** the only CRDT layer on SQLite; measurable conflict-resolution
  semantics.
- **Cons:** no history, so no append-log shape; no numeric benchmarks; v2
  never landed.

### Tier 3 - positioning rows (claims C3, C4, C5, C6)

#### etcd - the CP quorum baseline

- **What it is:** consistent distributed KV, bbolt backend, Raft; designed
  for small in-memory datasets.
- **Status:** v3.7.1 (2026-07-23), Apache-2.0, CNCF; three maintenance
  branches cutting monthly.
- **Benchmark fit:** the partition scenario (C4) - quorum is (n/2)+1;
  updates pause until quorum is restored (v3.6 FAQ). And a CP throughput
  reference. **Not** an append-log comparison: its API is current-state KV
  with compaction; the official benchmark doc is a 2016-era artifact
  (etcd 2.2.0, GCE n1-highcpu-2).
- **Pros:** official `benchmark` tool; explicit tuning guidance
  (commit = fdatasync + RTT; `wal_fsync_duration_seconds` p99 < 10 ms).
- **Cons:** KV shape; README still says "benchmarked 10,000 writes/sec"
  (undated); official benchmark doc is still the 2016-era artifact; "fsync
  before reply" is implied by FAQ/tuning (`wal_fsync_duration_seconds` p99
  < 10 ms), not stated verbatim.

#### TigerBeetle - the Zig reference

- **What it is:** financial-transactions DB in Zig; fixed Account/Transfer
  schema; ground state is an immutable, hash-chained, append-only log of
  prepares over VSR; io_uring, single-threaded; deterministic simulation
  (VOPR).
- **Status:** 0.17.9 (GitHub release 2026-07-06; CHANGELOG date 2026-07-03),
  **Apache-2.0 since 2021-01 - the common "relicensed in 2024" belief is
  not supported by the repository record**; near-weekly cadence; repo
  pushed 2026-08-25.
- **Benchmark fit:** closest in *spirit* to coppiz's write model (append
  -only, hash-chained, fsync-backed, total order) - a same-language sanity
  check that Zig is not the bottleneck. Data shape is fixed, so an
  append-log workload must be mapped onto transfers.
- **Pros:** official `tigerbeetle benchmark` (canonical workload, percentiles
  built in); explicit "not comparable across versions" caveat (a good
  discipline to copy).
- **Cons:** fixed schema (no payload flexibility); "1M TPS on a single
  core" and "1000× faster OLTP" are design claims. The Trillion
  Transactions blog still defers numbers to the talk video; a YouTube
  transcript lead (not the blog text) quotes ~400k TPS then ~800k with
  eight clients. The homepage live counter this run showed 896,429 TPS /
  256,011,126,080 transactions - a dashboard, not a pinned table.
- **Unknowns:** per-release absolute numbers in text. DevHub: CI script
  `src/scripts/devhub.zig` writes JSON to github.com/tigerbeetle/devhubdb
  and comments that results display at `https://tigerbeetle.github.io`
  (that URL 404 this run). `docs.tigerbeetle.com/concepts/performance/`
  is a design page, not a results table.

#### NATS JetStream - the stream-shaped option

- **What it is:** persistence layer inside nats-server; a stream is
  literally a sequence-numbered append-only log with a read-back API; KV is
  a stream bucket. Raft-replicated (R1 default, R3 "production floor").
- **Status:** nats-server v2.14.6 (2026-08-27), Apache-2.0, **CNCF
  Incubating** since 2018-03-15 (cncf.io/projects/nats/, 2026-08-29).
  Graduation application [cncf/toc#2042](https://github.com/cncf/toc/issues/2042)
  opened 2026-02-17, still Open. Very active (repo pushed 2026-08-28).
- **Benchmark fit:** the stream-shaped baseline (C5): most comparable data
  shape of all candidates. Durability must be pinned - **PubAck ≠ fsynced
  by default**; file storage syncs on `sync_interval` (`always` degrades
  throughput, documented).
- **Pros:** official `nats bench js pub` with a `--throughput` flag
  designed for head-to-head runs; R3 semantics documented (writes blocked
  without a majority).
- **Cons:** messaging semantics (consumers, acks, retention, dedup window)
  complicate a store-to-store comparison; single-leader writes; no official
  absolute benchmark table.
- **Unknowns:** none for CNCF level - it is Incubating, not Graduated.
  Whether #2042 will be accepted is out of scope.

#### PostgreSQL - the server baseline

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

### Tier 4 - semantics only (claim C7)

#### Automerge, Yjs, Loro - CRDT libraries

- **What they are:** collaborative-data CRDT libraries (JSON/text types);
  all three are history-preserving to varying degrees. Loro is the best fit
  for a history-shaped workload - it markets version control, time travel
  and Git-like shallow snapshots as design goals.
- **Status:** Automerge 3.4.1 (2026-08-12, MIT); Yjs 13.6.32 (npm 2026-08-04,
  MIT; GitHub yjs/yjs pushed 2026-08-06); Loro 1.15.0 (npm 2026-08-27, MIT;
  crates.io max 1.13.9 as of 2026-08-01). The Loro 1.0 blog post is dated
  **2025-09-22** on loro.dev/blog; a Reddit announcement of the same title
  is 2024-10-24; the article body still has no in-page date.
- **Benchmark fit:** the W6 merge-semantics row (deterministic re-slotting
  vs CRDT convergence), not a throughput row. Published numbers
  (dmonad/crdt-benchmarks; Loro's perf page) are text-edit workloads on
  versions that are already stale - e.g. Loro B4 replay 2,271 ms vs Yjs
  2,616 ms vs Automerge 7,109 ms (Loro 1.0.0-beta.2, Yjs 13.6.15, Automerge
  2.1.10) - none measure an append-log shape.
- **Pros:** Loro has a reproducible harness (`zxch3n/crdt-benchmarks`).
- **Cons:** all numbers need rerunning on current versions; no append-log
  workload exists for any of them; the semantics argument ("converge ≠
  correct", research 0001) is the actual point.

#### Marmot - the tunable-ack AP store

- **What it is:** leaderless distributed SQLite speaking MySQL wire
  protocol; 2PC with ONE/QUORUM/ALL acks; LWW + HLC conflict resolution
  (not CRDT - no merge semantics).
- **Status:** v2.9.13-beta (2026-04-26, GitHub prerelease), MIT,
  independent; latest *stable* GitHub release is v2.8.0 (2026-01-26).
  README is on the tag, not `main`. **beta only.**
- **Benchmark fit:** its ONE/QUORUM/ALL ack knob is a useful contrast to
  coppiz's `write.ack` (OQ 3), but there are zero published benchmarks and
  no stable release - semantics row only, if at all.
- **Cons:** no append-log/history semantics (LWW-by-write); no numbers.

#### Corrosion - no longer a store at all

- **What it is:** Fly.io's open-source gossip-based service discovery
  ("replacing Consul"), using cr-sqlite for conflict resolution. Originally
  conceived as the cr-sqlite sync daemon; it pivoted before first public
  release (v0.1.0, 2023-09-20 already had the service-discovery framing).
- **Benchmark fit:** none for coppiz - it is not a store. Listed so nobody
  re-adds it from the 2021-era survey rows.

## Out-of-the-box options

- **Already in the tree:** [OQ 54](../open-questions.md#oq-54)'s internal
  measurement set (append latency at n = 1, memory/connections at 8/16/32,
  append-to-visible p50/p99, join/backfill of a 1 GB journal) is the seed -
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
  numbers - they cover the wrong workload, which is itself a finding.
- **Buy, host, or delegate:** benchANT-style hosted benchmark vendors cover
  client-server DBs only - no coverage of SQLite/rqlite/dqlite/LiteFS/etcd
  exists there (absence-based). Nothing to buy.

## Comparison

| Option | Tier | Licence | Benchmark fit | Main risk |
|---|---|---|---|---|
| SQLite | 1 (baseline) | public domain | W1/W3/W8, n = 1 | none (the reference) |
| dqlite | 1 | LGPLv3+static | W1/W2/W4, 3-node | no published numbers; CP stall |
| rqlite | 1 | MIT | W1/W2/W4, 3-node + packaging | HTTP hop in the measurement; docs/version drift |
| libSQL | 2 | MIT | replica reads, C5/C6 | maintenance mode; single-writer |
| LiteFS | 2 | Apache-2.0 | FUSE tax, C4/C6 | stale releases; async-only; Linux+FUSE |
| CR-SQLite | 2 | MIT | semantics only (C7) | no history until v2 - cannot run W1 |
| etcd | 3 | Apache-2.0 | partition scenario (C4), CP ref | KV shape; stale official numbers |
| TigerBeetle | 3 | Apache-2.0 | ordering/durability ref | fixed schema; numbers not comparable across versions |
| NATS JetStream | 3 | Apache-2.0 | stream shape (C5) | messaging semantics; weak default durability |
| PostgreSQL | 3 | PostgreSQL | one server-baseline row | no citable PG-vs-embedded numbers |
| Loro/Automerge/Yjs | 4 | MIT | merge semantics (C7) | text-edit workloads; stale versions |
| Marmot | 4 | MIT | semantics only | beta; zero benchmarks |
| Corrosion | - | Apache-2.0 | none | not a store (dropped) |

## Evidence log

Every row below was re-opened at the cited URL (or the redirected URL) on
**2026-08-29**. Verdict is one of: **confirmed** / **corrected** / **source
gone or moved** / **still unverifiable**. `absence-based` means this run
searched and fetched named sources and did not find the thing.

| Claim | Source | Read on | Verdict | Confidence |
|---|---|---|---|---|
| SQLite 3.53.4 released 2026-07-24; WAL-reset corruption bug fixed in 3.51.3 (2026-03-13) | https://sqlite.org/releaselog/3_53_4.html, https://sqlite.org/releaselog/3_51_3.html | 2026-08-29 | confirmed | high |
| SQLite is public domain, full-time maintainers, support intent to 2050 | https://sqlite.org/about.html, https://sqlite.org/copyright.html | 2026-08-29 | confirmed | high |
| WAL mode: commit = commit record appended to `-wal`; auto-checkpoint default 1000 pages | https://sqlite.org/wal.html | 2026-08-29 | confirmed | high |
| `synchronous` semantics: FULL fsyncs WAL per commit (durable); NORMAL syncs at checkpoints only (may lose committed txns on power loss); OFF syncs nothing; EXTRA = FULL + dir sync (rollback mode) | https://sqlite.org/pragma.html#synchronous | 2026-08-29 | confirmed | high |
| `speedtest1` is SQLite's official perf program; sqlite3 CLI has `.timer` | https://www.sqlite.org/src/file/test/speedtest1.c, https://sqlite.org/cli.html | 2026-08-29 | confirmed | high |
| SQLite vs files: ~35% faster than individual files (2017-era, 3.19–3.20) | https://sqlite.org/fasterthanfs.html | 2026-08-29 | confirmed | high (as published) |
| SQLite's official speed-comparison page is a retired historical artifact (2.7.6-era) | https://sqlite.org/speed.html | 2026-08-29 | confirmed | high |
| Distro SQLite: Debian stable (trixie) 3.46.1-7+deb13u1; Debian sid 3.53.4-2; Ubuntu noble 3.45.1-1ubuntu2.7; Ubuntu resolute 3.46.1-9ubuntu0.2. Stable/LTS packages are below the 3.51.3 WAL-reset floor | packages.debian.org, packages.ubuntu.com | 2026-08-29 | confirmed | high |
| The 2022 "SQLite vs filesystem" study linked from sqlite.org is github.com/chrisdavies/dbench (golangexample.com is a wrapper) | https://sqlite.org/fasterthanfs.html, https://github.com/chrisdavies/dbench | 2026-08-29 | confirmed | high |
| dqlite v1.18.7 published 2026-07-02; repo pushed 2026-08-24 | GitHub API `repos/canonical/dqlite/releases/latest` | 2026-08-29 | confirmed | high |
| dqlite is LGPLv3 with static-linking exception; LXD is the flagship user; Linux (io_submit) | LICENSE @ v1.18.7; https://canonical.com/dqlite (dqlite.io/docs redirects here) | 2026-08-29 | confirmed (docs URL moved) | high |
| dqlite: SQLite runs on a custom in-memory VFS; the raft log is what is persisted; commit = quorum has persisted the raft entries | https://raw.githubusercontent.com/canonical/dqlite-docs/main/explanation/replication.md | 2026-08-29 | confirmed | high |
| dqlite raft log segments are opened O_DSYNC and appended via Linux KAIO; fsync/fdatasync also used for segment rename/truncate, snapshots, control files | `src/raft/uv_writer.c`, `src/raft/uv_fs.c` @ v1.18.7 | 2026-08-29 | confirmed | high |
| dqlite public API exposes no fsync/durability option (absence-based) | include/dqlite.h @ v1.18.7 | 2026-08-29 | confirmed | medium |
| dqlite is CP; transactions serializable but not linearizable; stale reads possible ~an election timeout | dqlite-docs `explanation/faq.md`, `explanation/consistency-model.md` | 2026-08-29 | confirmed | high |
| dqlite-benchmark (go-dqlite `cmd/dqlite-benchmark`): `--duration --workers --workload kvwrite\|kvreadwrite`; experimental flag is `--disk` (not `--disk-mode`) | https://github.com/canonical/go-dqlite/tree/v3/cmd/dqlite-benchmark | 2026-08-29 | corrected | high |
| No official dqlite-published benchmark numbers exist (absence-based) | search + dqlite repos/docs | 2026-08-29 | confirmed | high |
| gcore 2022: Chinook import Litestream ≈10 s, dqlite ≈22 s, rqlite ≈61.5 s; rough manual timing, no hardware disclosed | old URL `/blog/` **redirects** to https://gcore.com/learning/comparing-litestream-rqlite-dqlite/ | 2026-08-29 | source gone or moved (content confirmed at new URL) | medium/low |
| rqlite v10.2.7 published 2026-07-06; MIT; repo pushed 2026-08-28; developed since 2014 | GitHub API `repos/rqlite/rqlite/releases/latest`; rqlite.io/docs/design/ | 2026-08-29 | confirmed | high |
| rqlite: every write goes through raft and the raft log is fsynced after every write; disk I/O is the bottleneck | https://rqlite.io/docs/guides/performance/ | 2026-08-29 | confirmed | high |
| rqlite runs SQLite in WAL mode with synchronous=OFF internally, switching to FULL at checkpoints; raft log is authoritative | https://rqlite.io/docs/design/, https://rqlite.io/docs/api/api/ | 2026-08-29 | confirmed | high |
| Current rqlite has no `-raft-on-disk`/raft-log-fsync flag; raft tuning flags are `-raft-snap*` + timeouts. Historical `-on-disk`/`-ondisk` selected a SQLite *file* vs in-memory DB (v4 README), not raft fsync | https://rqlite.io/docs/guides/config/; v4.0.0 README | 2026-08-29 | confirmed (historical flag identified) | high |
| rqlite queued writes (`?queue`) batch and ack before raft persistence - data-loss window on crash; write `level=` names are read-consistency levels, not write levels | https://rqlite.io/docs/api/queued-writes/, https://rqlite.io/docs/api/read-consistency/ | 2026-08-29 | confirmed | high |
| rqlite waits for quorum commit on every normal write; minority side unavailable on partition | https://rqlite.io/docs/faq/ | 2026-08-29 | confirmed | high |
| rqbench (`cmd/rqbench`): `-a -n -b -p -x` (also `-m -t -o`); prints Requests/sec and Statements/sec. "Stress variant" is not in the v10.2.7 README | https://raw.githubusercontent.com/rqlite/rqlite/v10.2.7/cmd/rqbench/README.md | 2026-08-29 | corrected (stress variant dropped) | high |
| rqlite 2022 blog: ~220 INSERTs/s on a 3-node GCP cluster; queued writes ~15× higher (hardware unspecified, old version) | https://www.philipotoole.com/rqlite-trading-durability-for-performance/ | 2026-08-29 | confirmed | medium |
| "rqlite is used in k0s" - claimed by gcore only; k0s README and stable docs contain no rqlite mention | gcore vs https://raw.githubusercontent.com/k0sproject/k0s/main/README.md, https://docs.k0sproject.io/stable/ | 2026-08-29 | confirmed (absence) | high |
| rqlite glibc: FAQ says ≥ 2.34; building-from-source says 2.32 or later; error sample mentions GLIBC_2.33 | https://rqlite.io/docs/faq/, https://rqlite.io/docs/install-rqlite/building-from-source/ | 2026-08-29 | confirmed (documented inconsistency) | high |
| libSQL: last `libsql-server` *release* v0.24.32 (2025-02-14); repo pushed 2026-08-26; README banner points new work to the Turso rewrite | GitHub API `repos/tursodatabase/libsql`, repo README | 2026-08-29 | confirmed | high |
| libSQL licence history: SQLite blessing (2019-03-19) → Apache-2.0 (2022-09-30) → MIT (2022-10-06); LICENSE.md is MIT today | GitHub commits `LICENSE.md`; LICENSE.md | 2026-08-29 | confirmed | high |
| libSQL June-2024 licence-change *announcement* still not found at a primary source. Current state is MIT (repo + HN 43535943 2025-03-31). Jan 2025 Turso post: new server is closed-source, "not a relicensing of libSQL" | search; HN 43535943; https://turso.tech/blog/upcoming-changes-to-the-turso-platform-and-roadmap | 2026-08-29 | still unverifiable (the 2024 announcement) | medium (current MIT: high) |
| libSQL embedded replicas: local file serves reads; writes go to the remote primary by default (`offline: true` opts into local writes) | https://docs.turso.tech/features/embedded-replicas → `/introduction` | 2026-08-29 | confirmed (URL redirected) | high |
| libSQL consistency: primary ops linearizable; replicas may lag; per-connection monotonic reads | https://raw.githubusercontent.com/tursodatabase/libsql/main/docs/CONSISTENCY_MODEL.md | 2026-08-29 | confirmed | high |
| Turso vendor microbench: prepared `SELECT … LIMIT 1` ≈ 190 ns / 5.2M elem/s (cache-resident, 2023) | Wayback 2025-01-24 capture of turso.tech/blog/microsecond-level-sql-query-latency-… | 2026-08-29 | confirmed | high as published / low as comparative |
| No independent third-party *engine* libSQL benchmark exists (absence-based). sqg.dev 2026-01-19 is Node driver-level (insertUser turso 63,017 vs libSQL 28,385 vs better-sqlite3 53,693) | search; https://sqg.dev/blog/sqlite-driver-benchmark/ | 2026-08-29 | confirmed | high |
| LiteFS v0.5.14 (2025-04-22); repo pushed 2026-05-11; Apache-2.0; Ben Johnson sole maintainer; docs: "not able to provide support"; no release since 2025-04 | GitHub API; https://fly.io/docs/litefs/ | 2026-08-29 | confirmed | high |
| LiteFS: FUSE passthrough; per-transaction page sets → LTX files over HTTP; single primary via Consul lease or static; replicas read locally | https://fly.io/docs/litefs/how-it-works/, https://fly.io/docs/litefs/config/ | 2026-08-29 | confirmed | high |
| LiteFS replication is asynchronous by default; sync replication "planned for future development" | https://fly.io/docs/litefs/how-it-works/ | 2026-08-29 | confirmed | high |
| LiteFS autostop caveat: a stale machine winning the lease can discard newer changes, "risking rollback and data loss" | https://fly.io/docs/litefs/ | 2026-08-29 | confirmed | high |
| LiteFS author: ~250 µs per write(2)+fsync(2) | HN item 33206196 (sibling of 33204347), 2022-10-14 | 2026-08-29 | confirmed | medium (author-claimed) |
| LiteFS FAQ: FUSE limits write throughput to ~100 tps; target DB size ≤ 10 GB | https://fly.io/docs/litefs/faq/ | 2026-08-29 | confirmed | high |
| Third-party LiteFS measurement (single-node, proxy, no replication exercised): 62 rps vs 244 rps without LiteFS | Wayback 2025-09-16 of maori.geek.nz/…-litefs-a-quick-benchmark-… | 2026-08-29 | confirmed | high as published / low as cluster data |
| LiteFS requires Linux + FUSE | https://fly.io/docs/litefs/getting-started/ → getting-started-fly | 2026-08-29 | confirmed (URL redirected) | high |
| No Fly.io LiteFS *benchmark* blog posts after 2025-04 (Wayback CDX of fly.io/blog/* litefs: re-crawls of introducing-litefs and litefs-cloud only) | Wayback CDX + web search | 2026-08-29 | confirmed (absence) | high |
| CR-SQLite v0.16.3 (2024-01-17); MIT in repo; npm `@vlcn.io/crsqlite` declares Apache-2.0; repo pushed 2026-08-10 | GitHub API; npm | 2026-08-29 | confirmed | high |
| CR-SQLite: "inserts into CRRs are 2.5× slower than regular SQLite; reads the same" (vendor claim) | https://github.com/vlcn-io/cr-sqlite README | 2026-08-29 | confirmed | medium |
| CR-SQLite approach 1 "keeps no history"; history/GC is approach 2, "to be implemented in v2" - v2 has not landed | README | 2026-08-29 | confirmed | high |
| vlcn↔Fly: no formal acquisition announcement found; Fly.io maintains superfly/cr-sqlite 0.17.0 as a breaking fork for Corrosion | absence + https://github.com/superfly/cr-sqlite + https://fly.io/blog/corrosion/ | 2026-08-29 | confirmed | medium |
| Corrosion is Fly.io's gossip service discovery ("replacing Consul") using cr-sqlite; v1.0.0 (2026-05-14), Apache-2.0; repo pushed 2026-08-26 | GitHub API; README; fly.io/blog/corrosion/ | 2026-08-29 | confirmed | high |
| Marmot v2.9.13-beta (2026-04-26 prerelease), MIT; latest stable GitHub release v2.8.0 (2026-01-26); 2PC ONE/QUORUM/ALL; LWW+HLC; README lives on the tag not `main` | GitHub tags/releases; README @ v2.9.13-beta | 2026-08-29 | confirmed | high |
| Automerge 3.4.1 (2026-08-12), MIT; 2.0-blog replay numbers 1,816 ms vs Yjs 1,074 ms (2023); no live perf docs page | npm; https://automerge.org/blog/automerge-2/ | 2026-08-29 | confirmed | high |
| Yjs 13.6.32 (npm 2026-08-04), MIT; GitHub yjs/yjs pushed 2026-08-06; canonical reference is dmonad/crdt-benchmarks | npm; GitHub API; https://github.com/dmonad/crdt-benchmarks | 2026-08-29 | confirmed | high |
| Loro 1.15.0 (npm 2026-08-27), MIT; crates.io max 1.13.9 (2026-08-01); perf page B4 replay loro 2,271 ms / yjs 2,616 ms / automerge 7,109 ms; C1.1 loro 2,335 / yjs 27,138 / automerge 50,692 (Loro 1.0.0-beta.2, Yjs 13.6.15, Automerge 2.1.10) | npm; https://raw.githubusercontent.com/loro-dev/loro-docs/main/pages/docs/performance/index.md | 2026-08-29 | confirmed | high (vendor-run, reproducible harness) |
| Loro markets version control / time travel / Git-like shallow snapshots | README; https://loro.dev/blog/v1.0 | 2026-08-29 | confirmed | high |
| Loro 1.0 blog: loro.dev/blog index dates the post **2025-09-22**; Reddit announced the same title 2024-10-24; article body has no in-page date | https://loro.dev/blog, https://loro.dev/blog/v1.0, Reddit 2024-10-24 | 2026-08-29 | confirmed (index date); contemporaneous announcement is 2024-10-24 | medium (two dates) |
| etcd v3.7.1 (2026-07-23), Apache-2.0, CNCF; maintenance lines v3.6.14 and v3.5.33 same month | GitHub API; etcd.io/blog/2026/july-23-patch-release/ | 2026-08-29 | confirmed | high |
| etcd: majority (n/2)+1 must agree before commit. v3.6 FAQ does not use the verbatim "minority side cannot commit"; it says quorum loss (e.g. partitions) pauses updates until quorum is restored | https://etcd.io/docs/v3.6/faq/ | 2026-08-29 | corrected (wording) | high |
| etcd tuning: `wal_fsync_duration_seconds` p99 should be < 10 ms | https://etcd.io/docs/v3.6/faq/, https://etcd.io/docs/v3.6/tuning/ | 2026-08-29 | confirmed | high |
| etcd official `benchmark` tool still at tools/benchmark (`benchmark put --endpoints --total --key-size --val-size --clients --conns`) | https://github.com/etcd-io/etcd/tree/main/tools/benchmark | 2026-08-29 | confirmed | high |
| bbolt `bench`: `bbolt bench db -batch-size 400 -key-size 16` (seq write/read modes; `--key-size` default 8) | https://raw.githubusercontent.com/etcd-io/bbolt/main/cmd/bbolt/README.md | 2026-08-29 | confirmed | high |
| etcd README "benchmarked 10,000 writes/sec" (undated); official benchmark doc is 2016-era | README; https://etcd.io/docs/v3.6/benchmarks/ | 2026-08-29 | confirmed | high (as historical record) |
| TigerBeetle 0.17.9: GitHub release 2026-07-06, CHANGELOG 2026-07-03; Apache-2.0 LICENSE unchanged since 2021-01 | GitHub API; CHANGELOG.md; commits?path=LICENSE | 2026-08-29 | confirmed (release date vs changelog date) | high |
| TigerBeetle: VSR; ground state = immutable hash-chained append-only log of prepares (batches of 8,000); LSM forest; synchronous commit to WAL; flexible quorums 3/6 | https://raw.githubusercontent.com/tigerbeetle/tigerbeetle/main/docs/ARCHITECTURE.md (moved off repo-root ARCHITECTURE.md) | 2026-08-29 | source gone or moved (content confirmed at new path) | high |
| TigerBeetle VOPR: production cluster on one thread with fault injection, seed-reproducible | https://raw.githubusercontent.com/tigerbeetle/tigerbeetle/main/docs/internals/vopr.md | 2026-08-29 | confirmed | high |
| `tigerbeetle benchmark`: canonical workload; "default benchmark numbers are not necessarily comparable across different TigerBeetle versions" | src/tigerbeetle/benchmark_load.zig | 2026-08-29 | confirmed | high |
| Cited `docs/internals/HACKING.md` 404 this run | https://raw.githubusercontent.com/tigerbeetle/tigerbeetle/main/docs/HACKING.md | 2026-08-29 | source gone or moved | high (for the 404) |
| TigerBeetle "A Trillion Transactions" (2026-03-19): blog still defers numbers to the talk video. Homepage live counter this run: 896,429 TPS / 256,011,126,080 tx. DevHub: script comments https://tigerbeetle.github.io (404); store is github.com/tigerbeetle/devhubdb | https://tigerbeetle.com/blog/2026-03-19-a-trillion-transactions/; tigerbeetle.com; src/scripts/devhub.zig | 2026-08-29 | confirmed (test's existence); numbers still not in the blog text | high (existence) / low (absolute figures) |
| nats-server v2.14.6 (2026-08-27), Apache-2.0; JetStream GA since v2.2.0 | GitHub API | 2026-08-29 | confirmed | high |
| NATS is CNCF **Incubating** since 2018-03-15; graduation application cncf/toc#2042 opened 2026-02-17, still Open | https://www.cncf.io/projects/nats/; https://github.com/cncf/toc/issues/2042 | 2026-08-29 | confirmed | high |
| JetStream: stream = sequence-numbered append-only log; KV is a stream bucket | docs.nats.io (cited `/nats-concepts/jetstream/key-value-store` redirects to `/learn/key-value/`) | 2026-08-29 | confirmed (URL redirected) | high |
| JetStream: R1 default, R3 production floor; PubAck after majority; writes blocked without majority | docs.nats.io (cited streams / surviving-node-loss paths redirected) | 2026-08-29 | confirmed (URL redirected) | high |
| JetStream file storage does not fsync every write; `sync_interval` `always` = every write ("will degrade" throughput) | https://docs.nats.io/reference/2.11/config/jetstream/sync_interval | 2026-08-29 | confirmed | high |
| `nats bench` `--throughput` flag "useful for head-to-head comparisons against Kafka's kafka-producer-perf-test.sh" | natscli README | 2026-08-29 | confirmed | high |
| No official absolute JetStream benchmark table (absence-based) | search + docs sweep | 2026-08-29 | confirmed | high |
| PostgreSQL 18.6 (2026-08-13); PostgreSQL License; pgbench default is a 7-statement TPC-B-inspired txn; `fsync=on`/`synchronous_commit=on` defaults | https://www.postgresql.org/, docs/current/pgbench.html, runtime-config-wal.html | 2026-08-29 | confirmed | high |
| PG wiki: scale factor should exceed client count; run pgbench from a separate system; separate WAL (pg_xlog) to a different filesystem | https://wiki.postgresql.org/wiki/Pgbench | 2026-08-29 | confirmed | high |
| PG-vs-embedded comparisons found are all DIY with ≥1 methodology flaw (durability mismatch universal): andrecasal, intuitem, deployn, PGlite | those four URLs, all 200 this run | 2026-08-29 | confirmed | medium each |
| No rigorous SQLite vs dqlite vs rqlite benchmark exists publicly. 2024–2026 search found: Aalto 2025 thesis (qualitative, cites vendor 100 tps / 10 writes/s); Onidel 2025-10-01 qualitative VPS post; SoftwareMill 2026-01-20 TB vs PG (42k vs 15k TPS, M1 Max - wrong shape for this suite) | search + listed URLs | 2026-08-29 | confirmed (absence of a trio table); new adjacent comparisons listed | high (absence-based) |
| Stanford CS244b spring-2020 PDF: 3-node single-host vs rqlite and SQLite; hardware 16 GB / 3.1 GHz i7 vs rqlite; 1,500-INSERT loop; text layer still garbled (e.g. "DSQ 0.772 4.004 33.71…"); qualitative "outperforms / twice faster than Rqlite"; durability not discussed | https://www.scs.stanford.edu/20sp-cs244b/projects/Distributed%20SQLite.pdf | 2026-08-29 | confirmed (qualitative); exact table still garbled | low |
| TyrantDB (datafuselabs) public existence: GitHub search HTTP 429 this run - not re-confirmed | https://github.com/search?q=tyrantdb&type=repositories | 2026-08-29 | still unverifiable | - |
| benchANT covers client-server DBs; no SQLite/rqlite/dqlite/LiteFS/etcd coverage found on the fetched pages | https://benchant.com/blog | 2026-08-29 | confirmed | medium |
| Methodology: percentiles can't be averaged across runs; merge histograms; focus p99 | https://raw.githubusercontent.com/brianfrankcooper/YCSB/master/README.md | 2026-08-29 | confirmed | high |
| Methodology: commit latency = fdatasync + network RTT; disclose hardware, versions, workload, commands | https://etcd.io/docs/v3.4/op-guide/performance/ | 2026-08-29 | confirmed | high |
| SQLite WAL on NVMe: ~10–20k serialized INSERTs/s - HN item 36208568, 2023-06-06 | https://hn.algolia.com/api/v1/items/36208568 | 2026-08-29 | confirmed | medium |
| "libSQL is open source (MIT license)" - Turso engineer `avinassh`, HN item 43535943, 2025-03-31 | https://hn.algolia.com/api/v1/items/43535943 | 2026-08-29 | confirmed | high |
| HN/lobste.rs measured head-to-head of the named trio: Algolia comment search for rqlite/dqlite/LiteFS/libSQL/TigerBeetle benchmark returned no trio table. lobste.rs "rqlite benchmark" → 1 story (SQLite for Everything, 2026-08-19), not a measurement | HN Algolia; https://lobste.rs/search?q=rqlite+benchmark | 2026-08-29 | confirmed (absence) | high |
| SoftwareMill (Adam Warski): TigerBeetle 42k TPS vs Postgres-batched 15k TPS on M1 Max 64 GB; **published 2026-01-20**, `dateModified` 2026-08-28. Durability class not matched to this suite's DURABLE contract | https://softwaremill.com/tigerbeetle-vs-postgresql-performance-benchmark-setup-local-tests/ | 2026-08-29 | corrected (publication date was the page's modified date, not the article date) | medium (wrong shape; laptop) |
| Turso 0.7.0 blog (Pekka Enberg, published 2026-07-13): "we feel comfortable enough to officially drop the beta warning"; some features remain experimental | https://turso.tech/blog/turso-0.7.0 | 2026-08-29 | confirmed | high |

## Open questions

Split into **what this run settled or left open after a documented attempt**
and **decisions the operator must make** (which this doc cannot settle).

### Not found in this sweep (rerun targets)

None remaining without a documented 2026-08-29 attempt. Prior items moved
below.

### Resolved or narrowed (this run and sweep 2)

- **"rqlite used in k0s"** - k0s README and stable docs contain no rqlite
  mention. The gcore claim stays unsubstantiated.
- **libSQL current licence** - MIT (LICENSE.md + HN 43535943). The 2024
  plan's own announcement is still missing (see still-unresolved).
- **CS244b PDF** - fetched; 2020 student project; hardware 16 GB / 3.1 GHz
  i7 vs rqlite; 1,500-INSERT loop; text layer still garbled; qualitative
  "twice faster than Rqlite"; not a table to cite.
- **Hacker News / lobste.rs / Reddit measured numbers.** Algolia was
  reachable. Queries: rqlite/dqlite/LiteFS/libSQL/TigerBeetle benchmark
  (comments). No trio head-to-head. Reconfirmed: LiteFS ~250 µs
  (33206196), SQLite NVMe 10–20k inserts (36208568), Turso MIT (43535943).
  lobste.rs: 1 non-measurement story. Reddit search did not return usable
  threads (mostly non-thread pages).
- **2024–2026 third-party head-to-head of Tier-1/2.** Searched
  "replicated SQLite benchmark 2025", "dqlite vs rqlite benchmark",
  "LiteFS vs dqlite". Closest: Aalto 2025 thesis (qualitative; LiteFS
  "100 writes/sec" and rqlite "10 writes/sec" are vendor citations);
  Onidel 2025-10-01 qualitative VPS post; SoftwareMill 2026-01-20 TB vs
  PG (page last modified 2026-08-28). No rigorous SQLite vs dqlite vs
  rqlite table. gcore URL moved to
  `/learning/`.
- **TigerBeetle DevHub + Trillion text.** DevHub is
  `src/scripts/devhub.zig` + github.com/tigerbeetle/devhubdb; public HTML
  at tigerbeetle.github.io is 404. Trillion blog still has no numbers in
  text. Homepage live counter this run: 896,429 TPS. YouTube transcript
  lead (~400k then ~800k TPS) is not the blog.
- **NATS CNCF graduation.** Incubating since 2018-03-15. Graduation
  application cncf/toc#2042 opened 2026-02-17, still Open.
- **dqlite official numbers.** Still none. fsync-before-ack still
  inferred; O_DSYNC confirmed in `uv_fs.c`; `RWF_DSYNC` commented out in
  `uv_writer.c`. Unofficial tmpfs QPS exists in cowsql/raft#192 (not
  official).
- **SQLite distro versions + sqlite-vs-filesystem.** Distro versions
  listed in the evidence log. The 2022 study is github.com/chrisdavies/dbench.
- **rqlite glibc + historical `-raft-on-disk`.** FAQ ≥ 2.34 vs
  building-from-source 2.32. Historical flag was `-on-disk` (SQLite file
  vs memory), not raft fsync.
- **Fly.io LiteFS posts after 2025-04.** Wayback CDX + search: no new
  *benchmark* posts; only re-crawls of introducing-litefs and litefs-cloud.
- **Loro v1.0 announcement date.** Blog index: 2025-09-22. Reddit
  2024-10-24. crates.io ~2024-10-22. Article body still has no in-page
  date. Do not use npm `1.0.0` 2023-03-23 (different 1.0).

### Still unresolved after this run

- **libSQL June-2024 licence-change announcement text.** Tried: web search
  for "libSQL license change June 2024", "Turso source available dual
  license 2024 June", GitHub org/issues lead (issue 26 is the 2022 MIT
  switch), turso.tech/blog (2023 "not changing the license"; 2025-01
  closed-source *new* server, "not a relicensing of libSQL"). Current MIT
  is confirmed. The 2024 plan post itself was not found.
- **TyrantDB public existence.** GitHub search returned HTTP 429. Not
  re-confirmed.
- **Trillion Transactions talk video** was not re-watched; blog text
  still has no table. Homepage counter and a search-indexed YouTube
  transcript are leads only.
- **Reddit threads with measured trio numbers** - the search operator did
  not return usable thread pages; treated as under-covered, not as
  "does not exist".

### Decisions for the operator (block the harness, not the research)

These stay **open**. New evidence that bears on them, not a choice:

- **What counts as "the benchmark machine"** (OQ 54 needs the same answer):
  a dev laptop, a cloud VM, a bare-metal box? The suite must pin one and
  record its fingerprint. Recommendation candidates: a fixed cloud VM type
  (reproducible) and the primary dev machine (representative of the first
  host). New evidence: SoftwareMill's 2026-01-20 TB vs PG run (page last
  modified 2026-08-28) used an M1 Max 64 GB laptop and said so - that is
  the kind of fingerprint the suite must record, not a reason to pick a
  laptop.
- **Which tiers ship in v1 of the suite.** Tier 1 alone covers the named
  claims (C1, C2, C4); tiers 2–4 each add driver build/maintenance cost.
  Recommendation candidate: Tier 1 + etcd (partition row) + TigerBeetle
  (Zig reference) + LiteFS (FUSE tax, cheapest driver) in v1; libSQL,
  JetStream, Postgres, CRDT semantics in v2. New evidence: Ubuntu/Debian
  stable SQLite is still < 3.51.3, so the SQLite driver must pin the
  amalgamation; LiteFS still has no post-2025-04 release; libSQL-server
  still has no 2025-02-14-later *release*; NATS is still Incubating;
  Marmot is still beta-only.
- **Whether the suite is a runbook or a gate.** Perf comparisons are flaky
  as CI gates; recommendation candidate: a manual runbook executed per
  release milestone, not a build gate. No new evidence that would flip
  this.
- **Which `write.ack`/durability config is the coppiz DURABLE default** for
  the comparison (OQ 3 is still open) - the suite needs it pinned. New
  evidence: rqlite/dqlite/etcd/TB/LiteFS/JetStream durability floors were
  re-confirmed; they do not pick coppiz's default.
- **Whether TigerBeetle earns a row** given the fixed-schema mapping cost;
  and whether the CRDT family gets the W6 semantics row at all. New
  evidence: SoftwareMill measured TB vs PG (wrong shape, useful as a
  "someone else ran a driver" existence proof); Loro 1.15.0 is current;
  CR-SQLite v2 still has not landed.

## What would change the answer

- **A rigorous third-party head-to-head benchmark appearing** - it would
  become the citation instead of this suite (and its methodology a reference).
- **dqlite publishing official numbers; rqlite/LiteFS/libSQL changing
  licence or maintenance posture** (libSQL's Turso rewrite shipping could
  move it from "maintenance mode" to "rewrite wins").
- **CR-SQLite v2 landing** (history semantics) - would reopen its
  append-log suitability.
- **coppiz's own claims changing** - a quorum mode (OQ 1) or a read
  consistency guarantee (OQ 31) would add rows, not remove them.
- **The tier numbers changing** ([OQ 54](../open-questions.md#oq-54) measurements)
  - the comparison rows stay, the internal reference points move.

## References

- **coppiz records:** [docs/README.md](../README.md),
  [OQ 3, 19, 36, 47, 54](../open-questions.md),
  [PRD 0001](../prds/0001-journal-core.md), [PRD 0003](../prds/0003-membership-and-leadership.md),
  [PRD 0005](../prds/0005-embedding-the-library-as-the-product.md),
  [ADR 0001](../adrs/0001-zig-0-16-standard-library-only-for-the-core.md),
  [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md),
  [research 0001](0001-evidence-carried-from-the-state-store-survey.md).
- **Tier 1:** sqlite.org (releaselog, wal.html, pragma.html, speedtest1,
  speed.html, fasterthanfs.html), github.com/canonical/dqlite + go-dqlite +
  dqlite-docs, canonical.com/dqlite (dqlite.io/docs redirects), 
  gcore.com/learning/comparing-litestream-rqlite-dqlite/ (old `/blog/` URL
  redirects here), github.com/rqlite/rqlite + rqlite.io (docs: performance,
  design, api, queued-writes, read-consistency, faq, building-from-source),
  philipotoole.com, packages.debian.org, packages.ubuntu.com.
- **Tier 2:** github.com/tursodatabase/libsql + docs.turso.tech, turso.tech
  blog (via Wayback) + https://turso.tech/blog/turso-0.7.0 (2026-07-13),
  github.com/superfly/litefs + fly.io/docs/litefs +
  fly.io/blog (introducing-litefs, litefs-cloud - no new posts after
  2025-04), maori.geek.nz (via Wayback), github.com/vlcn-io/cr-sqlite,
  github.com/superfly/cr-sqlite, fly.io/blog/corrosion.
- **Tier 3:** etcd.io/docs/v3.6 (faq, tuning, benchmarks) + v3.4
  (op-guide/performance), github.com/etcd-io/bbolt, tigerbeetle.com +
  github.com/tigerbeetle/tigerbeetle (`docs/ARCHITECTURE.md` - moved off
  repo root; vopr.md; `src/scripts/devhub.zig`; github.com/tigerbeetle/devhubdb;
  benchmark_load.zig; blog), docs.nats.io (several cited jetstream paths
  redirected 2026-08-29) + github.com/nats-io/natscli +
  cncf.io/projects/nats + cncf/toc#2042, postgresql.org
  (docs/current/pgbench, runtime-config-wal) +
  wiki.postgresql.org/wiki/Pgbench.
- **Tier 4:** github.com/dmonad/crdt-benchmarks, github.com/zxch3n/crdt-benchmarks,
  github.com/loro-dev/loro + loro-docs performance page, automerge.org
  (blog/automerge-2), yjs.dev, github.com/maxpert/marmot.
- **Survey & methodology:** YCSB README, andrecasal/sqlite-vs-postgres-benchmark,
  intuitem.com/postgresql-vs-sqlite-2026-benchmark, deployn.de, pglite.dev/benchmarks,
  sqg.dev/blog/sqlite-driver-benchmark, benchANT, scs.stanford.edu CS244b
  project PDF (re-read 2026-08-29; qualitative rqlite comparison - see
  evidence log), github.com/chrisdavies/dbench, aaltodoc 2025 thesis,
  softwaremill.com TB-vs-PG (published 2026-01-20), onidel.com 2025 VPS
  comparison.

## Appendix

### This run (2026-08-29)

Live web search first, then curl of GitHub API/raw, project docs, npm/crates,
Wayback CDX, HN Algolia, Debian/Ubuntu package pages, CS244b PDF. Query list
and fetch transcripts: implementer scratch `search-log.md` and `fetches/`.
Search was reachable (unlike 2026-08-28). Search-only gaps are recorded as
unresolved, not forced confirmed.

### Per-system sweep scope (2026-08-28, prior)

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

### Sweep limitations (2026-08-28, prior)

The 2026-08-28 sweeps could not use general web search (bot-walled). This
2026-08-29 run did. Remaining gaps that only search could settle and that
this run still missed (June-2024 licence announcement text; GitHub search
429 for TyrantDB; Reddit thread pages) are listed under
[Open questions](#open-questions) as still unresolved. Absence-based claims
are marked as such; none should be read as "does not exist", only "not found
by this sweep".
