# Changelog

This file records consumer-visible changes. It follows Keep a Changelog; version
numbers follow the policy in [RELEASES.md](RELEASES.md).

## [Unreleased]

### Fixed

- A journal whose TTL enforcement is turned off again now still removes the
  entries that were stamped for deletion while it was on. The fast path
  that skips computing a checkpoint's removal set read the current
  `ttl.enforce`, while the removal set itself decides from the expiry
  instant and action stamped on each entry when it was slotted. Those
  entries stayed hidden as expired, their bytes were never reclaimed, and
  the journal emitted no checkpoint at all.

- A data directory holding a segment whose header names a different
  journal now refuses to open with `journal_id_mismatch` instead of
  aborting the process. The branch that raises the refusal closed the
  segment file while the error handler that owns it was still live, so the
  descriptor was closed twice on the way out.

- A node that crashed while creating a segment file can reopen its data
  directory again. Every segment writer creates the file and writes its
  header as two calls, and the open-time scan subtracted the header length
  from the file length before checking the file was that long, so the
  leftover short file aborted the open with an integer overflow. Such a
  file holds no header and no records, so the open now drops it and
  continues.

- A member catching up no longer loses the newest record on a journal. A
  broadcast arriving while it was still backfilling was dropped, and once the
  backfill had passed that journal nothing ever asked for the record again,
  so the member served silently stale reads for good. A dropped broadcast now
  leaves a sync cursor at the missing position. This is the cause of the
  intermittent growth e2e timeout: the test failed 16 times in 20 runs before
  the fix and 0 times in 20 after.

- The connection reader task no longer reads the node's connection table
  from a pool thread while the loop thread inserts into it. It takes the
  connection value it needs at spawn time instead, so every access to that
  table is now on the loop thread.

- A member no longer carries on after a replicated record was folded but its
  store write was refused. The handler ignored every error the chain's own
  rules had not produced, so the fold could end one record ahead of the
  segment file: reads answered from a record no segment held, and the chain
  did not reopen. Chain refusals are still ignored; anything else stops the
  member.

- The survivor of a healed partition no longer records a merge whose request
  for the loser's branch was never sent. `requestSync` sends nothing while
  another sync is in flight, and the merge was committed regardless, which
  stopped the member folding replicated records until that connection died.
  It now commits only once the request is on the wire.

- The four transport closers that free themselves no longer carry a
  `closed: bool`. `TcpConn`, `TcpListener`, `PipeConn` and `HubListener`
  each read that flag at the top of `closeFn` and destroyed the allocation
  it lives in at the bottom, so a second close read it back out of freed
  memory: a recycled block reads `false` and the close runs again, freeing
  a block its new owner holds (reproduced). `Conn.close` and
  `Listener.close` now say the contract - sole destructor, exactly once -
  and a structural test keeps the guard from coming back. Nothing in the
  tree closes any of them twice; the flags promised a protection they could
  not provide (bug 2026-08-29-close-guard-in-freed-allocation).
- A member no longer discards a committed suffix of its chain because it once
  saw an ordinary failover. Every new epoch set the "my branch" facts and
  nothing cleared them, so the loser of any later divergence truncated back
  to the slot before that failover, even when it had no branch of its own.
  The loser now acts only when its branch opened at or after the epoch the
  divergence is about, and the facts are cleared when a merge ends.

- A member no longer truncates its data journals because an arbitrary peer
  asked it to. `merge_ack` carries no body, and the handler discarded the
  connection it arrived on, so any admitted member could roll every data
  journal on a peer back to the last slot of its common epoch. The loser of
  a merge now records the connection it sent its `merge_offer` on and acts
  on exactly one ack from exactly that connection.

- A member's redial backoff no longer ratchets. `backoff_ms` only ever
  doubled, so after a handful of dropped connections every member sat
  permanently at the 8 s ceiling - which is above the 5 s default
  `cluster.suspect_after_ms`, so any later blip, however brief, expired the
  suspect timer before the redial was attempted and dropped the member out
  of the election. The delay is now reset to its 250 ms floor as soon as a
  connection to that member is established, on both the inbound and the
  outbound handshake. Repeated failures still widen it to the same ceiling.

- A `members_page` frame carrying a 65535-byte address no longer aborts the
  node. The decoder's per-member cursor advance computed `34 + addr_len` in
  the length field's own `u16`, which overflows: a panic in a safe build, and
  in a release build a wrapped cursor that refuses a well-formed page. The
  frame is decoded before any role or admission check, so the abort needed
  nothing but a connection to the listen port. The earlier narrow-int sweep
  had excluded this decoder on the strength of its outer `usize` cursor.

### Added

- A fourth example host, `examples/short-process/`: the command-line shape
  that opens a data directory, appends, reads and closes once per
  invocation, instead of holding the node open for the life of the process.
  It is the shape the first host does not exercise, and it is checked
  rather than asserted - the example fails the build if a later invocation
  cannot see an earlier one's entries, if `author_seq` restarts across a
  close, or if the head does not advance by exactly one slot per
  invocation. `zig build examples` builds and runs it; `zig build test`
  runs it as a test.

- Election is now a function over an abstract member id, which is what PRD
  0006's "what the core must get right now" table asks the core to settle
  before a federation exists. `election.zig` exposes `Election(Id)` for any
  fixed-size id; the cluster is `Election([16]u8)`, exported as
  `election.Member`, and `election.leader`, `compareRank` and
  `authorityIndex` still name exactly those functions, so no caller changed.
  A federation elects over groups by instantiating it with a 32-byte group
  id, and gets the same ranking the merge rule uses rather than a copy of
  it. `election.isHexId` takes the id as a slice so one implementation
  serves every width.

- The library's thread behaviour is pinned by a test, not just documented
  (PRD 0005 G5): opening a node, appending and reading at size 1 spawns no
  thread, `ClusterNode.init` spawns none, and `start()` is the only call
  that puts work on the host's `Io`. An embedding host can therefore reason
  about when coppiz begins using its thread pool.
- The project-kit session workflow (install with the never-overwrite
  fix in the kit itself): `workflows/` (continue, fix, plan, review,
  handoff, deliver), the plans/handovers/reviews/postmortems/prompts/
  agent-rules directories with their templates, `docs/WORKFLOW.md`,
  `docs/locks.md`, the generated `docs/INDEX.md`, and `scripts/`
  (docs-index.sh, project-kit.py). `zig build docs-check` runs the kit's
  documentation checks - no em dashes in prose, no paragraph over 700
  characters, no broken local links, the generated index current - as a
  standalone step (not part of `zig build test`).
- Documentation now follows the kit's prose rules: every em dash in prose
  is a regular dash (fenced code keeps its own), and every paragraph is
  under 700 characters (split at sentence and thought boundaries; long
  roadmap bullets became sub-bullets). `docs-check` passes with zero
  failures.
- `coppiz doctor` reports whether the local `[genesis]` table still
  matches the chain (PRD 0004 *Bootstrap*). `coppiz init` reads `[genesis]`
  once and the chain is authoritative from then on, so an operator editing
  the file afterwards previously got no error and no effect. Doctor now
  warns per drifted key, naming the local value and the folded one, and
  stays an `ok` line when they agree. A drift is a warning, not a failure.
- The historical settings view PRD 0004 *Reading settings* names:
  `Node.settingsAt(position)` for cluster scope and
  `Node.journalSettingsAt(id, position)` for a journal's merged view. The
  live accessors read the fold at the head; these re-fold the chain and stop
  after the last slot at or before the position, so a caller can ask what
  was in force when a given slot was written without standing up a second
  node. A position before the genesis yields the schema defaults and one
  past the head yields the head state; the caller owns the returned state.

### Fixed

- A replicated `slot` frame is refused when its record does not fill the
  frame. `decodeSlot` checked the payload's own length prefix but not that
  the record inside it ended where the payload ends, and `decodeRecord`
  ignores whatever follows the record it decodes - so a valid record with
  bytes appended decoded as a valid slot. Those bytes are what the follower
  hands to the store verbatim, which refuses them with `BadRecord` after the
  fold has already advanced, leaving the fold one slot ahead of the segment
  file (bug 2026-08-29-slot-record-trailing-bytes).
- A `members_page` frame no longer buys the sender a multi-megabyte
  allocation for free. `decodeMembersPage` sized `alloc(MemberInfo, count)`
  from the sender's `u16` count before checking the body could hold that
  many members, so a 26-byte payload declaring 65535 members allocated and
  freed 3,145,680 bytes - 120,987x amplification, measured - on the node's
  single loop thread, which decodes every frame before it checks the
  sender's role. The frame was already refused; the guard every sibling
  decoder has now refuses it before allocating, at 54 ns instead of 1.6 ms
  (bug 2026-08-29-wire-length-checks-narrow-int, follow-up section).
- A `join` that runs out of memory no longer leaves the member in the fold.
  `applyJoin` added the member and then ran the whole-state rule; the rule's
  refusal rolled it back but an allocation failure did not, so the fold kept
  a member its chain has no entry for - a divergence from every peer whose
  allocation succeeded. The address dupe had the matching hole and was
  orphaned when the append that was to own it failed. Two smaller leaks on
  the same shape are gone with it: a seed peer named twice in `[[peers]]`
  leaked its second retry key, and a `ClusterNode.init` that failed its own
  setup freed the struct without freeing the tables it had built.
- The in-memory hub transport is safe to dial concurrently. `Hub` guarded
  none of its three fields while every node dialled from its own task, so
  two `pipes.append` calls that both grew the list orphaned one of the two
  backing buffers - an intermittent `1 leaks` on an otherwise green
  `zig build test`. `Hub` has a mutex now, held across the drop check, the
  endpoint lookup and the append. `Hub.listen`, `drop`, `heal` and
  `isDropped` take an `io` parameter as a result.

- A TCP connection no longer loses frames the kernel delivered together.
  `recvFrame` built its read buffer per call, so bytes the socket read past
  the current frame were consumed and then discarded - and TCP coalesces
  freely, so those bytes are routinely the next frame. Losing a whole frame
  was silent replication loss; losing part of one desynchronized the
  connection. The buffer and its reader belong to the connection now.

- A merge whose deferred `leave` re-slots refuse part way through no longer
  leaves freed payloads in the pending list. `reSlotDeferredLeaves` freed each
  payload in its loop but cleared the list only at the end, so an error left
  already-freed entries in it and the next free - node shutdown, a peer
  disconnect, or the next merge - was a double free. The loop drains from the
  front now, so an entry is in the list exactly while its payload is owned.
- The wire decoders no longer abort on a peer-supplied length near its type's
  maximum. Thirteen length checks across ten message kinds added a `u16` or
  `u32` field to the message's fixed size and computed the sum in the field's
  own type, which overflows. `hello` was reachable before admission, so an
  84-byte write to an open listen port aborted a node in a safe build; in
  `ReleaseFast` the sum wrapped and the malformed body passed the check. The
  sums are computed in `usize` now, and an over-long declared length is
  refused as `invalid_length`.

- `coppiz init` refuses a data directory that has already been bootstrapped,
  with `already_initialized`, instead of replacing its `member.key` and
  appending a second control chain. Replacing the key changed the member's
  derived id, so it was no longer the member its own control fold records:
  `admit` returned `not_leader` forever and the old secret was gone. The
  check runs before anything is written, and a directory that has journals
  but no key is refused too.
- `journal.init` now owns the data directory handle on every path and
  documents it; `cmdInit` no longer closes it as well. The store's plain
  `defer st.deinit()` closes the handle on the error path too, so any
  failure after `Store.open` succeeded closed the same descriptor twice.
- `zig build test` no longer hangs. Every three-node test ran on an
  `std.Io.Threaded` with the default `async_limit` (`cpu_count - 1`), and
  three `ClusterNode`s need 15 async slots, so on a machine with 16 or fewer
  logical CPUs the third `start()` ran its own task inline and never
  returned. Both sites - the `embed-cluster` example and the tri-node test
  helper - now ask for 64 slots, which is not a per-CPU quantity, so the
  threshold no longer moves with the hardware.
- Length-prefix arithmetic no longer computes in the prefix's own narrow
  type. Six checks added an untyped constant to a `u32`/`u16` length read
  off the wire or off disk, so the sum was evaluated in that narrow type and
  a length near its maximum overflowed it. `entry.decode` sits behind the
  replication wire, so one broadcast frame could abort the receiving node;
  the other five are reached from a corrupt queue or segment file. Every
  site now widens to `usize` first and refuses the record by name.
- The readability rules now reach the repository root: docs-check (from
  the project-kit kit) scans the root README, CHANGELOG, RELEASES and
  AGENTS for links, paragraph length and em dashes, not only `docs/`.
  The root README's shipped-state narrative and the long changelog and
  AGENTS entries are split to match; ADR 0008's em dashes are regular
  dashes. `zig build docs-check` uses the tracked script, so a fresh
  clone runs the same checks.
- The leader's checkpoint cadence treats `MergeSettling` as a skip, not a
  fatal error: after a healed merge the serving loop keeps running until
  `merge.settle_ms` passes, then the checkpoint can land.
- `encodeCreateJournalPayload` refuses a name longer than 65,535 bytes with
  `settings_too_large` instead of panicking (debug) or wrapping the u16
  length (release).
- Documentation sweep (2026-08-29): the root README's Status section no
  longer carries a superseded second "Shipped" paragraph; the full status
  narrative moved into a combined "Status and where things are" section at
  the end, with a short Status summary up top.
- The CLI list in
  PRD 0005 and the RELEASES version note match the shipped node binary
  (no `--version` flag exists yet); PRD 0005's API sketch and PRD 0001's
  write path reflect the shipped library surface (no `write.ack` knob;
  all write paths return at the slot).
- The roadmap's Planned section no
  longer lists shipped phases.
- The open-questions register records the
  decisions taken since (OQ 13, 35 resolved; OQ 2, 12, 32, 44 resolved;
  OQ 3, 36, 55, 56 updated to the shipped defaults, OQ 34 to the open
  create-journal bypass) and drops `Blocks:` pointers to finished phases.
- 26 broken internal links across the reports and RFC 0003 are fixed.
- Reads walk a journal in chain order (slot position), including the
  control journal named `__cluster__`. A checkpoint no longer removes
  TTL-reached entries while `ttl.action = mark_stale` and
  `stale.cleanup = keep`. A live append over the wire honours the
  journal's `journal.max_entry_bytes`. Epoch and wire decoders refuse a
  zero reason/kind instead of trapping. Authority hex ids match either
  letter case. `coppiz admit` skips a truncated `pending.admit` line; a
  refused wire append flushes the reason to stderr.
- A fatal error in the cluster loop now stops `coppiz serve` instead of
  leaving it waiting forever. Failed dials are retried with backoff, a
  leader drains its unslotted queue, and append/settings failures are
  acked instead of leaving the client hanging. An indexed record whose CRC
  fails is `Corrupt`, not silently missing; a `prompt` hello whose
  `pending.admit` write fails is refused rather than reported as queued.
- The cluster loop refuses operator and replication messages until hello
  completes, binds a hello's member id to the claimed public key (and to
  the key the chain already holds on reconnect), and ignores a heartbeat
  whose member id is not this connection's. `pending.admit` drops addresses
  that contain NUL, CR, or LF. Sync and read pages are capped at the frame
  body bound.
- `member.key` is created with owner-only permissions (0600).
- Hub frame sends refuse an oversized body the same way TCP framing does.
- The 2026-08-28 bug sweep's storage and replication defects are fixed: a
  compaction no longer collides with the journal's own segment names
  (`compact`/`sealHead` use fresh ordinals).
- The unslotted queue refuses
  mid-file corruption instead of truncating acknowledged entries.
- A
  settings value past the u16 codec cap is refused with `settings_too_large`
  instead of panicking.
- A settings entry commits atomically (an OOM cannot
  leave the fold half-applied).
- `ttl.retain = none` compactions reopen and fold.
- The checkpoint settle rule reads the cluster's merge fact.
- A re-slotted `create_journal` no longer stalls the merge.
- A redelivery no longer lowers the author's high-water mark.
- An embedded host's append completes during backfill instead of blocking forever.
- A follower that misses a data broadcast catches up via sync instead of reading stale data
  forever.
- A join that would strand the cluster leaderless is refused.
- The in-memory hub's allocation-failure paths no longer double-free, a
  duplicate `listen` is refused with `address_in_use`, partial `readInto`
  keeps every free on an allocation start, and closing a listener takes the
  endpoint lock. The `coppiz.toml` parser is quote-aware (`#` and `,`
  inside quoted values survive), and a peer `public_key` that is not 64 hex
  chars is refused at parse time instead of silently dropped from the join
  allowlist.
- `zig build test` is green again - the suite had not compiled since the
  review-stack merges (a `Hub.deinit` arity drift at three test sites, and
  the CLI test root requiring libc for `std.c.getpid()`); the shipped binary
  still links no libc.
- The in-memory hub no longer leaks the edge key when the same directed
  edge is dropped twice: `Hub.drop` probes before it allocates, and the
  owned key now comes from the allocator that `heal` and `deinit` free it
  with.
- The wire client refuses a `read_page` whose `next` cursor does not
  advance (`protocol_error`) instead of asserting on it: the cursor is the
  peer's, so a bad one was a panic in a safe build and an unbounded request
  loop in a release build.
- A chainless member no longer aborts on a peer's control record.
  `FoldState.applyControl` and `applyControlReslotted` read
  `self.epoch.?.leader` after a journal-id check that a member with no folded
  genesis passes: its control fold's journal id is all zeros, and so is the
  record's. Both now refuse with the new `no_epoch` refusal, before any
  signature is checked. `Node.epoch()` returns `?u64` instead of unwrapping,
  exactly as `Node.leader()` does, and `slotFor` turns the absent case into
  `error.NoEpoch` rather than a panic on the whole write path.
- `zig build test` is green again. The crashed-compaction recovery test
  formatted its snapshot paths into a `[64]u8` buffer and then passed the
  whole array to `createFile` instead of the 50-byte slice `bufPrint`
  returned, so 14 undefined bytes were part of the file name and macOS
  refused it with `BadPathName`. The test now keeps the returned slice.

### Changed

- The open-questions register (`docs/open-questions.md`) is gone. Every
  decision-shaped open question migrated into an [RFC](docs/rfcs/README.md)
  (0001–0039); the measurement questions moved to
  [research](docs/research/README.md) notes (0004–0009); the CPU-spin
  investigation lives in its [report](docs/reports/investigations/2026-08-29-oq62-index-rebuild-hardening.md).
  `OQ n` in older records is a historical ID - the glossary defines it, and
  citations now link to the record that settled the question.
- `storage.fsync` now governs the whole write path: the unslotted queue
  honors the knob like the store does, and the queue's drain barriers
  (`remove`/`clear`) no longer sync (a lost trim replays idempotently).
  An append pays 2 fsyncs under `every`, 1 under `batched`, 0 under
  `never` (was 3/2/2) - [ADR 0008](docs/adrs/0008-storage-fsync-governs-the-queue.md).
- `zig build test` installs only what the suite spawns - the `coppiz`
  binary and the `sidecar` example (the G2 process-level test runs the
  installed sidecar): the other example executables are no longer compiled
  as install targets no test runs, and `zig build examples` installs them
  (it previously only built and ran them).
- The cluster e2e tests' fixed settle/expiry waits sleep instead of busy
  spinning the main thread: the waits last the same wall-clock time, but no
  longer peg a CPU core.
- The process-level tests reap their killed serve processes instead of
  polling a zombie for 5 s each: `zig build test` dropped from ~75 s to
  ~31 s on an idle machine (all 244 tests unchanged).
- The cluster e2e tests wait for the actual backfill/broadcast state (a
  node's sync finished, a settings change landed) instead of fixed
  "settle" sleeps: `zig build test` dropped from ~31 s to ~20 s on an idle
  machine (all 261 tests unchanged; the waits are now robust on slow
  machines too, since they end when the state really holds).

### Added

- `coppiz members` - one line per member of the control fold, in fold
  order (seniority): id, join slot, advertised address, and a `leader`
  marker. Local against an unlocked data directory; over the wire when a
  serving node holds the lock, via a new `members_req`/`members_page`
  message pair (the node answers from its fold, so the CLI never re-folds
  membership).
- `coppiz doctor` - diagnoses a data directory (PRD 0005 *Failure
  modes*): the config, the member key, the lock, and the chain (epoch,
  members, journals and their heads). A directory locked by a serving
  node is a finding, not an error: doctor reports the lock and probes the
  node over the wire instead. Exits nonzero when any check fails;
  warnings (a configured listen with no node serving, an empty journal)
  do not.
- The embedded-host read path (PRD 0005): `cluster.ClusterNode.localReadRange`
  routes a host's synchronous read through its member's loop - the loop runs
  the range over its own state (atomic with respect to its own mutations: a
  merge's truncate-and-re-fold, a checkpoint's compaction) and copies the
  records, and the host's callback replays the copies on its own thread, so a
  host thread never touches the folds while the loop runs. A host that wants
  to stream a large journal page by page still reads through the wire client.
  `examples/embed-cluster` reads through the loop instead of its operator
  channel.
- The sidecar↔binary pairing (PRD 0005 acceptance criterion G2): the
  `examples/sidecar` host runs against a real `coppiz serve` over TCP
  (`zig-out/bin/sidecar --address 127.0.0.1:PORT --key-dir DATA`), speaking
  the same client code it uses for the embedded node - proof that the
  embedded library surface and the standalone binary surface are one
  protocol. The pairing is an e2e in the node binary's own tests.

- The embedded-host write path (PRD 0005): `cluster.ClusterNode.localAppend`
  runs a host's append through its member's loop - durable queue, then the
  leader slots or the follower forwards - and blocks until the slot folds
  back, so a host on a follower writes without touching the wire. The
  example hosts (`examples/embed-single`, `examples/embed-cluster`,
  `examples/sidecar`) build with `zig build examples` and each is a test
  run by `zig build test`; `build.zig.zon` gains no dependencies.
- The leader's checkpoint cadence (PRD 0002 phases 4–5): the leader
  checkpoints each journal on `checkpoint.every_ms`, or when
  `checkpoint.pending_bytes` of removable payload has accumulated (probed as
  data arrives), never with an empty removal set - and every member drops
  the removed payloads at the same chain position when the checkpoint folds,
  so the bytes, not just the fold marks, match. E2e: three members remove
  the same set at the same checkpoint slot under both `ttl.retain` values
  (G4), and a follower skewed ±1 h shows, not stores, differently (G6).
- The replication wire (PRD 0003 phase 4, [OQ
  19](docs/prds/0003-membership-and-leadership.md) decided - own binary framing over one TCP
  connection): `src/net/` - length-prefixed frames with a versioned body,
  the typed message set (hello/hello_ack, append/ack, forward, slot,
  sync_req/sync_page, heartbeat, read_req/read_page, settings,
  merge_offer), and a transport seam (`Conn`/`Listener`/`Transport`) with
  a TCP implementation and an in-memory hub whose directed edges drop and
  heal, so the same loop code runs under both. Disk and wire share the
  segment record codec. Fuzz tests cover the message decoder.
- The cluster node loop (PRD 0003 phase 5): `src/cluster/node.zig` - one
  event-processing task per member over the wire: the failure detector
  (heartbeat/suspect from chain settings), the election → epoch cycle, the
  leader write path (slot, broadcast, ack), forward/backfill over pages,
  admission (`allowlist`/`open`/`prompt`), eviction, and partition/merge:
  the losing branch truncates its store to the last common slot and re-folds
  the survivor's chain, which carries the `merge` entry and the loser's
  entries re-slotted (the fold infers a re-slot from author and epoch, so a
  merged chain replays identically after restart).
- `coppiz serve` and the wire-client fallback for `append`/`read`/`head`
  when the data directory is locked, plus `coppiz status` (epoch, leader),
  `coppiz settings set` (live, leader-appended), and `coppiz admit` (the
  offline half of `prompt` admission).
- Journal seams the loop builds on: `applyReplicated` (the single incoming
  slot path), replicated `create_journal` store/fold creation,
  `replay_forward` opens (a follower re-forwards its queue instead of
  re-slotting locally), `store.truncate` (the merge re-fold's storage
  half), and per-entry queue trimming.
- The e2e matrix (PRD 0003 phase 6): process-level 1 → 2 → 3 live joins
  with correct seniority leadership, live reconfiguration and its frozen
  refusal, and forged-chain refusal; in-process partition-heal-merge and
  `configured` + `stall` over the hub transport with real stores and real
  loops.
- The single-member journal core (PRD 0001 phases 1–4): entry and slot
  codecs with Ed25519 signing and SHA-256 chaining, the pure fold and
  validation rules (including the `create_journal` control kind), segments
  with CRC-checked records, torn-tail recovery and sealed-segment hashes,
  the position index, the bounded unslotted queue, and the node that ties
  them together - open, append, read, follow, createJournal, settings,
  stale marks, checkpoint and compaction. Fuzz tests cover the untrusted
  decoders (entry, slot, record).
- The settings schema as code (PRD 0004): every PRD 0002/0003 key with
  scope, type, default, live-changeability and a description, cross-key
  validation, the clone-validate-commit fold, `coppiz.toml` parsing with a
  closed key set, and `docs/configuration.md` generated by `zig build docs`
  and pinned by a test.
- TTL and staleness (PRD 0002 phases 1–3): the pure expiry predicates, the
  `stale`/`checkpoint` chain rules, and payload-drop compaction honouring
  `ttl.retain`, driven by a checkpoint that never emits an empty removal
  set.
- The tier-0 CLI: `coppiz init`, `coppiz append`, `coppiz read`,
  `coppiz head`, `coppiz settings schema`.
- The pure cluster core (PRD 0003 phases 1–3, on [RFC
  0002](docs/rfcs/0002-how-join-order-is-made-unspoofable.md) option A,
  [ADR 0005](docs/adrs/0005-join-order-is-slot-position.md)): the
  membership fold (`join`/`leave`, seniority = the join slot position).
- The election function (`leader(mode, settings, members, liveness)` for
  `seniority`/`configured`/`combined` with `stall`/`seniority` fallback and
  `seniority`/`freshest` tiebreak - a `syncing` member is never eligible).
- The epoch/merge rules: the `epoch` entry's two shapes (post-failure
  election, mode_change handover), the `merge` entry, the re-slot path
  (losing-side `settings`/`stale`/`checkpoint`/`epoch`/`merge` re-slot as
  no-ops, OQ 33; `join`/`leave`/`create_journal`/`data` with effect), and
  the survivor rule shared with election. The four control kinds fold in
  `chain.zig` instead of being refused as unimplemented, and the fold hash
  now covers the epoch, the last merge and member addresses.
- The deterministic simulator ([OQ 27](docs/prds/0003-membership-and-leadership.md)): a seeded,
  single-threaded world of in-memory nodes driving the pure
  fold/election/merge functions with injected partitions, crashes, clock
  skew and reordered delivery. Scenarios: partition-heal-merge (G7 core),
  partitioned joins with deterministic seniority (RFC 0002), leader crash,
  reorder, `configured` + `stall` (G4 core), and clock skew. It pins the
  merge discipline - on heal every node re-folds from the last common slot.
- The Apache-2.0 licence ([ADR 0006](docs/adrs/0006-the-library-is-apache-2-0-licensed.md),
  [OQ 18](docs/adrs/0006-the-library-is-apache-2-0-licensed.md) resolved): the `LICENSE` file and the
  `license` field in `build.zig.zon`, with `LICENSE` carried in the
  package's `.paths`. The external claims the README cites were reopened at
  their sources ([OQ 40](docs/research/0001-evidence-carried-from-the-state-store-survey.md)) resolved), recorded in
  [research 0001](docs/research/0001-evidence-carried-from-the-state-store-survey.md)'s
  evidence log with this repo's read dates.

### Changed

- The entry header magic is `CPPZ` (segment `CPSG`, seal `CPST`, queue
  `CPPQ`) - coppiz-derived rather than the draft's `SPNE`.
- Provisional defaults for `cluster.max_journals` (1024) and
  `journal.max_entry_bytes` (16 MiB) ship in the schema (OQ 36, OQ 55).
- A checkpoint within `merge.settle_ms` of the last merge is refused
  `merge_settling` (PRD 0002's settle rule was vacuous while merge entries
  could not exist).

### Fixed

- Sync and read pages include a record that exceeds the page byte bound
  when it is the first on the page, so an entry larger than the bound is
  still replicated and readable.
- Journal-scoped settings could not be set over the wire: `onSettings`
  authored them into the control journal's chain, where every member
  refused the non-cluster scope. Journal-scoped `settings` entries now land
  in the journal's own chain (PRD 0004's rule).
- A newly elected leader's own queued entries could sit in the durable
  queue forever (its forwards had no leader connection to send to); the
  leader now slots its own queue and acks the waiting client.
- `store.compact` error paths could leave the journal's segment list owning
  already-closed handles (a double close at `deinit`) or empty (an
  overflow on the next append); the swap now mirrors `truncate`'s ownership
  rule, and the rewrite adopts each new segment before writing so an error
  closes it exactly once.
- Node teardown cancelled the loop's in-flight store work (a cancelled
  compaction could leave a journal unusable); `waitForStop` now waits for
  the loop to exit on the stop event before cancelling the remaining tasks.
- A new epoch's first data slot continued the old seq (`bad_position` on
  any post-failover write to a journal with pre-failover slots); `slotFor`
  now starts the seq at 1 when the epoch changes, matching the chain's
  dense rule.
- In-memory hub teardown leaked dial connections and unprocessed frames;
  they are now closed and freed on deinit.


- The product is named `coppiz` ([ADR 0004](docs/adrs/0004-the-product-is-named-coppiz.md)).
  The library module, the node binary, `build.zig.zon` `.name` and the
  local-config file (`coppiz.toml`) use that identifier. `spine` remains
  the origin quote from clanker's RFC 0019. The placeholder node banner
  is `coppiz {version}`.

### Added

- The test-registration gate walks every gated Zig file instead of only
  `src/`: a source directory added to `checked_paths` used to gain
  formatter and column-cap coverage while its modules' tests stayed
  silently uncollected (Zig refuses an `@import` out of a module's root,
  so no test root under `src/` could ever reach them). Such a module now
  fails the gate by name until it has a real test root. `build.zig` joins
  `src/root.zig` and `src/main.zig` in `test_roots` - it already compiles
  as its own plain-module test binary - and owes the same `refAllDecls`
  pairing for any bare import it holds; `build.zig.zon` rides the same
  enumeration but is filtered back out as the non-Zig file it is.

- Wrong-case `.zig` sources are no longer invisible to every analysis gate:
  a file like `Legacy.ZIG` classified as other in both lint-gate walks and
  in `zig fmt`'s own directory walk (verified on 0.16.0: `zig fmt --check`
  over a directory leaves such a file untouched), so it reached no
  formatter, column cap, registration walk or test binary while `zig build
  lint` stayed green - demonstrated end-to-end with a planted `src/Evil.ZIG`.
- The gate-coverage walk now collects files whose name carries a `.zig`
  suffix in any letter case as candidates the covering set can never match,
  so the gate fails naming the file until it carries the lowercase spelling
  every gate applies. Listing the wrong-case path in `checked_paths` does not
  silence the report either: a wrong-case source is named whatever the
  allowlist holds.

- Near-miss `.zig` names are no longer invisible either: a file whose name
  keeps ".zig" mid-name ("root.zig~" editor backups, "a.zig.bak",
  "b.zig.rej", emacs's "c.zig.~1.2~") classified as other exactly like the
  wrong-case suffix and reached no gate while `zig build lint` stayed green.
  The coverage walk collects such files beside the wrong-case ones and fails
  naming each until it is renamed to the lowercase spelling or deleted.
  Package manifests are exempt: any ".zon" suffix keeps ".zig" mid-name by
  its own convention (`build.zig.zon`) without carrying a source obligation.

- Wrong-case `@import` strings are no longer invisible to the test-registration
  gate: an import like `@import("Helper.zig")` when the walked file is
  `helper.zig` resolved on a case-insensitive filesystem (macOS's default
  APFS, Windows NTFS) and failed to resolve on a case-sensitive one (Linux -
  the musl static binary is the strictest declared host, ADR 0001), and when
  any other chain reached the target module neither gate half said anything.
  The gate now matches every gated module's imports against the walked files
  case-folded as well as exactly, and a spelling that resolves only where the
  filesystem ignores case fails the gate naming importer, target and the
  exact-case spelling.

### Fixed

- OQ 56's blocking pointer names the phase backfill actually lands in:
  it cited "PRD 0001 phase 3 (backfill)", whose phase is segments, CRC
  and torn-tail recovery - PRD 0001's own phase list puts backfill in
  phase 5, landing with PRD 0003 because it needs a leader to exist.

- The test-registration step's section assembly gains its last missing subset:
  declaration-analysis and case-mismatch findings with a silent reachability
  half (every module reachable - one through its `refAllDecls` wrapper, one
  through the bare import that is itself its chain). A blank-line join keyed
  on the *first* section having found something passed every shape where
  reachability fired - the single-section pins, the {1,2} and all-three
  assemblies and the outer-join pin - while dropping this report's separator.
  Confirmed to bite by keying the separator on the reachability section and
  watching only the new test fail.

- The README's Quick start no longer describes `zig build test` as only
  "build and run the tests": it is the merge gate (OQ 45) and carries the
  analysis gates - formatting, the 100-column cap, test registration and
  forced declaration analysis, gate-coverage completeness - and the gates'
  standalone entry point, `zig build lint`, was absent from the README
  altogether. Both are now named with what they run.

- Two more lint-gate test repairs, each confirmed to bite by temporarily
  breaking the branch it guards: the case-mismatch report's
  once-per-distinct-import-string dedup is now pinned (the fixture repeats a
  wrong-case spelling from one importer - dropping the dedup doubled the
  tally behind a green suite, the same hole the declaration-analysis half
  had already closed for its repeated bare import), and the test-registration
  step's section assembly gains its missing subset - reachability and
  case-mismatch findings with a silent declaration-analysis half - where a
  blank-line join keyed on whether the previous section found something
  passed every existing shape while mangling this report.

- A linked directory listed in `checked_paths` no longer fails the
  gate-coverage walk that the covering gates themselves bless. `checkedFiles`
  follows a listed path that symlinks a directory so its subtree reaches every
  covering gate (pinned by its own test), but the coverage-completeness walk
  rejected *every* linked directory it met - including that same listed link -
  so no spelling of the allowlist admitted a symlinked library directory:
  unlisted, the rejection named it ("cannot walk 'linked-lib':
  LinkedDirectoryNotWalked"); listed, the coverage walk hit the link again and
  rejected the very tree the allowlist blessed, with `zig build test` failing
  either way.
- The coverage walk now follows a linked directory exactly where
  its walked path names a gate path - one hop through the same
  `appendZigFilesUnder` call the covering gates use, so both sides of the
  covered/candidate comparison derive from one policy - and keeps the loud
  rejection for unlisted links, whose subtree would otherwise escape every
  gate silently and whose blanket following would need cycle protection no
  tree justifies. Near-miss `.zig` names behind a followed link are collected
  beside its sources (`appendZigFilesUnder` gained an include-near-miss arm
  the covering gates leave off), matching how such names behave behind a
  listed real directory.

- Stale gate counts in build.zig's comments: `checked_paths`'s doc listed
  only three of the four surfaces sharing it (the test-registration walk was
  missing) and said a vanished path fails "both gates" where every consumer
  fails loudly; fmtArgs' doc called the column-cap and registration walks
  "the other two file-covering gates", a set no other comment agrees on; and
  the coverage step's make() and the linked-directory test spoke of "the two
  file-covering gates" where three other gates expand the listed paths. The
  comments now name or count the consumers as the code has them; no behavior
  changed.

- A walk failure inside a listed directory now names the walked entry that
  stopped it instead of the whole gate path: a rejected linked directory
  inside `src/` used to report "cannot enumerate 'src':
  LinkedDirectoryNotWalked", leaving the operator to find which link under
  `src/` owned the error by hand. `appendZigFilesUnder` carries the failing
  entry out to `checkedFiles` the same way the coverage walk already named
  its own ("cannot walk 'tools/vendor': …"), so both tree walks attribute
  an entry-specific failure at the same granularity; a failure belonging to
  no single entry still falls back to the gate path.

- The glossary defines **brief**: seven records cite "the brief (2026-08-21)"
  and only docs/README's prose named what that is (the operator's founding
  notes, [brief.md](docs/brief.md)) - a reader starting from a PRD or RFC
  had no pointer to the file the quotes come from, against the
  define-once rule the glossary itself states.

- The lint-gate fixtures that link directories (`symLinkOrSkip` call sites
  for the linked-directory and dangling-link cases) created them with
  default `SymLinkFlags`, which std spells out is ignored everywhere but
  Windows and load-bearing there: without `.is_directory = true` the link
  cannot be traversed as a directory, so those tests died in setup on
  exactly the link-capable Windows hosts (Developer Mode) where the skip
  logic's other direction is meant to run. The helper now forwards flags to
  the creation call, every directory-linking fixture spells the flag, and a
  test pins a directory link through the helper beside the file-link one.

- PRD 0001's acceptance criterion G6 now cites [OQ
  36](docs/research/0006-max-entry-size.md) for `journal.max_entry_bytes`, whose default is
  unset there: the criterion demands the bound be enforced with a trip test,
  but its open question was reachable only from the register and the roadmap,
  while the criterion's other two bounds both cited OQ 55 from the same PRD.

- Conforming trees no longer fail every gate on filesystems whose directory
  iteration answers no kind (XFS with `ftype=0`, some NFS and FUSE mounts).
  The `statFile` probe taught the walks to resolve such entries, but a
  probed *directory* was rejected exactly like a linked one - and since
  neither std walker descends on its own into an entry not reported as a
  directory (`Walker` auto-enters only `.directory` kinds;
  `SelectiveWalker.enter` refuses any other), on such a mount every real
  subdirectory under `src/` failed both file-covering gates
  ("cannot enumerate 'src': LinkedDirectoryNotWalked") and the coverage
  gate ("cannot walk 'src': …"), so `zig build test` could not pass at all.
- The classifier now separates the two cases: a link resolving to a
  directory stays the loud rejection, while an unclassifiable entry the
  probe reveals as a directory classifies as the plain `.directory`
  variant and is entered with the probed kind forced - the subtree behind
  it is analyzed like any other's, which is what the probe existed for.

- The two load-bearing `statFile` probes in build.zig spell
  `.follow_symlinks = true` explicitly instead of inheriting it as the
  default: symlink-following is the documented contract both gate walks
  depend on (a listed path linking a directory must contribute its subtree;
  the probe behind a link reveals the target's kind), and a default flipped
  upstream would otherwise have changed that behavior silently. `symLink`'s
  empty flags stay defaulted; nothing load-bearing lives there.

- `zigNearMissName`'s doc comment no longer claims the exact-lowercase
  suffix "never reaches a caller": its two callers narrow it per role -
  `appendProjectZigFiles`' `.other` branch has already claimed
  exact-lowercase names as `.zig_source`, and
  `GateCoverageStep.violationLines`' near-miss arm applies it only to
  names the covered set already holds.

- Nine lint-gate tests hard-required symlink creation in their fixtures
  (`try tmp.dir.symLink(...)`), so on a host that cannot make symlinks -
  Windows denies it to unprivileged users unless Developer Mode is enabled,
  and some mounted filesystems refuse it outright - `zig build test` died in
  fixture setup instead of testing the gates' link handling (links followed
  as sources, linked directories rejected, dangling links named).
- The calls now go through `symLinkOrSkip`, which decides the skip by capability, not
  by OS name: when the requested link fails, a control link with known-good
  arguments is attempted beside it, and only if even that fails does the test
  return `error.SkipZigTest`; where links work, a broken fixture's own error
  still propagates and fails loudly. A test pins both the created link and
  the loud-failure direction; the skip direction has no portable way to
  synthesize a link-less environment and is exercised by running the suite
  on such a host.

- The gate-coverage report survives listing a wrong-case `.zig` path in
  `checked_paths`. The coverage walk collects such a file as a candidate,
  but `checkedFiles` takes a listed plain entry whole, so the listing joined
  the covered set and the equality match in `violationLines` silenced the
  report - the exact escape the wrong-case collection exists to close,
  reproduced end-to-end with a planted `Legacy.ZIG` named in `checked_paths`
  (the gate passed; without the listing it failed naming the file). make()
  now appends a report line for every wrong-case candidate the covered set
  absorbed, through the I/O-free core `violationLines`; a
  wrong-case candidate outside the covered set keeps its single line, so no
  tally doubles.

- Ten lint-gate tests built their expected walked paths with `/` literals
  while the paths they compare against come from `std.fs.path.join` and the
  walker, which use the platform separator (`src\root.zig`, not
  `src/root.zig`, on Windows - the same mismatch class the byte-equal
  `test_roots` comparison hit before it learned to normalize). Nineteen
  assertions therefore failed against correct gate output on any host whose
  separator is not `/`. The expectations now concatenate
  `std.fs.path.sep_str`, so they pin the same report text as the platform
  actually produces; import-string tests keep their literal `/`, the one
  form an @import may spell.

- The `zig fmt --check --ast-check` gate now runs over the expanded file
  list the shared dispatcher produces instead of the raw checked paths, so
  a symlinked `.zig` source under a checked path is format-checked like a
  real one. zig fmt's own directory walk does not follow symlinks (verified
  on 0.16.0: with `src/link.zig` pointing at an unformatted real source and
  imported from `src/root.zig`, `zig build test` stayed green while
  `zig fmt --check src/link.zig` failed), so of the two file-covering gates
  only the column cap saw such a file - exactly the drift the shared
  `checked_paths` list exists to prevent.
- The expansion reuses
  `checkedFiles`, keeping zig fmt's coverage identical to the other gates':
  wrong-case `.ZIG` names stay excluded, and a missing checked path falls
  back to the raw paths, which zig fmt then fails on loudly at make time.

- The four record-store quick-start commands (the adrs, rfcs, prds and
  research inventories' READMEs) quote their `cp` destination around the
  placeholder (`"docs/adrs/0004-<slug>.md"`). Unquoted, a POSIX shell read
  `<slug>` as input and output redirections: where no file named `slug`
  existed the documented copy failed outright ("slug: No such file or
  directory"), and where one did it ran as a copy to `0004-` while creating
  a stray empty `.md` - never the numbered copy the instructions describe.

- Four end-to-end pins in the lint-gate tests, each run against a gate
  step's make() function over a temporary tree: the test-registration
  report's two single-section shapes (reachability findings alone carry no
  trailing section and declaration-analysis findings alone start at their
  own header - a join that appended its separator unconditionally mangled
  both while the two-section pin stayed green).
- The gate-coverage walk's failure naming the walked entry (`cannot walk 'dangling.zig':
  FileNotFound`, the report half of the failed_path contract
  appendProjectZigFiles' core tests already pin; the link sits outside the
  checked paths because inside them the covering walk fails the step one
  branch earlier).
- A conforming tree that all three gates must pass
  recording nothing - until now every make() test fed a violating tree, so
  a gate regression that started rejecting legitimate trees would have
  passed them all.
- Each pin was confirmed to bite by temporarily breaking
  the branch it guards.

- A sixth lint-gate end-to-end pin: the test-registration step's failure
  report with all three sections firing at once - reachability,
  declaration analysis and case-mismatch together, one finding each so the
  shape stays independent of the walker's order. Every prior make() test
  fed a tree where at most two sections fired, so nothing pinned the
  section order or the blank-line join between consecutive sections;
  reordering the assembled halves mangled the operator-facing report
  behind a green suite (confirmed: the new test fails under a swapped
  order and passes under the documented one).

- A fifth lint gate, coverage completeness: the analysis gates cover an
  explicit allowlist (`checked_paths` in build.zig) that fails loudly when a
  listed path stops existing but stayed silent about its complement - a
  stray or newly added `.zig` file outside those paths reached no formatter,
  no column cap and no test binary while `zig build test` stayed green. The
  new step walks the build root (skipping leading-dot tooling entries and
  the root-level `zig-out` install prefix; a linked directory is rejected
  like the covering gates' walks) and fails naming each uncovered file, so
  coverage can only change by editing `checked_paths`.

- Declaration-analysis enforcement in the test-registration lint gate: a
  `src/` module a test root imports but that root never wraps in a
  `std.testing.refAllDecls` (or `refAllDeclsRecursive`) call fails the build
  with the module and root named.
- Registration alone collects a module's
  tests; its unreferenced `pub` declarations are compiled into nothing and
  checked by nothing, so registering without the refAllDecls line hid a
  whole public surface from every semantic check behind a green `zig build
  test` (the gap the "all public declarations analyze" tests closed by hand,
  now gated). The gate constrains only the two test roots, where the
  documented convention puts both halves, and ignores imports resolving to
  no walked module (`std`, `build_options`, the `coppiz` package).

- Two boundary pins in the lint-gate tests: the column-cap test now feeds its
  second over-limit line as the file's last line with no trailing '\n' (a
  file not ending in a newline must still have that final line checked),
  and the toolchain-floor test pins the metadata mirror on the floor side -
  a plain toolchain satisfies a floor carrying build metadata.

- A third boundary pin in the lint-gate tests: the column-cap test now feeds
  a line of exactly the cap in code points while over it in bytes (100 wide
  characters, 200 bytes). The decoded side of the cap was one comparison away
  from an off-by-one ('<' for '<=') that would have flagged such a line -
  conforming wide-character source - and no existing case caught it, because a
  sub-cap byte count skips the decode entirely, so the ASCII exact-limit pin
  exercises a different branch.

- Two more lint-gate test repairs: the import-cycle classification test now
  also pins that modules reachable only through an unreachable importer are
  reported beside it (the walk seeds from test roots only), and
  importBetween's climb-out is checked two directories deep - one "../" per
  level left under the importing file's directory.

- Two coverage repairs in the lint-gate tests: the toolchain-floor test now
  pins the complementary prerelease boundary (a release toolchain satisfies
  a prerelease floor of the same release; build metadata orders equal), and
  the test-registration gate's decision core is exercised on an import
  cycle - two reachable modules importing each other are both classified as
  reached, the walk terminates, and the orphan outside the cycle is still
  the only module reported.

- The declaration-analysis test with two active roots now pins that wrapping
  is scoped per root: a `refAllDecls` in one test root excuses only that
  root's own imports, so the other root's bare import of the same module is
  still reported - each test root compiles into its own test binary, and a
  wrapper in one analyzes nothing for the other. The fixture orders the
  wrapping root first (main.zig before root.zig, the walk's real order),
  the direction where merging the wrapper sets across roots would silently
  drop a report line; verified by temporarily hoisting the set out of the
  per-root loop and watching the new pin fail.

- The three lint-gate tests that asserted an empty report no longer pass
  vacuously: each carries a control case the gate must still name, so a
  regression that silenced the walk or the declaration-analysis report
  altogether fails them instead of slipping through. The redundant-spelling
  registration test and the constrained-roots declaration-analysis test add
  an orphan module to their fixtures; the wrapped-spelling test adds a bare,
  never-wrapped import expected as the one reported module. normalizeImportPath's
  table also pins its trailing-empty-component boundary ("sub/" collapses to
  "sub"), the same rule "sub//x.zig" exercises mid-path.

- The README's `src/` row no longer calls both source files placeholders:
  the same audit that corrected `src/root.zig`'s module doc and PRD 0001's
  Status missed this row, and `root.zig` carries the implemented,
  test-pinned package version, so "placeholders today" understated it.

- Two accuracy repairs from a documentation audit: `src/root.zig`'s module
  doc no longer says nothing is implemented in the file - the package version
  declaration it sits above is implemented, compile-checked and pinned by a
  test - and PRD 0001's Status no longer calls `src/root.zig` a placeholder
  for the same reason.

- RFC 0001's *Current state* no longer presents clanker's shared state as
  JSON/JSONL files in the present tense: its own evidence record (research
  0001) and [PRD 0005](docs/prds/0005-embedding-the-library-as-the-product.md)
  carry clanker ADR 0033 (2026-08-20), which moved sessions to per-session
  SQLite with an append-only replicated `events` stream while the JSONL
  streams stayed unreplicated - verified in clanker's tree before editing.

- Three accuracy repairs from a documentation audit: RELEASES.md and this
  changelog describe the version mechanism that actually landed - the
  library parses the raw `build.zig.zon` value and fails compilation on
  non-Semantic-Versioning input, where both still said the build parsed (or
  pinned) the value, a path commit "Parse the package version in the
  library" removed; and the glossary's `checkpoint` definition no longer
  says stale entries are always removed - they join the removal set only
  under `stale.cleanup = delete`, as PRD 0002 states.

- PRD 0001's Storage section now names what keys a journal's on-disk
  subdirectory: the journal id in lowercase hex, not its name. The name was
  already a mutable setting while the id is the identity, so a name-keyed
  directory would have to migrate on rename; worse, a host-chosen string as
  a directory name imports filesystem naming rules into journal identity -
  on case-insensitive filesystems such as Windows NTFS and macOS's default
  APFS, journals named `Foo` and `foo` would silently share one directory
  and one chain, Windows refuses reserved device names (`con`, `nul`) and
  trailing-dot/space names outright, and a name carrying `/` or `\`
  escapes the member directory. Hex digits spell none of that.

- `checkedFiles`'s doc comment in build.zig names its callers again: it
  claimed to serve "every step that enumerates files" but listed only the
  two file-covering gates and the test-registration walk - the enumeration
  the coverage-completeness gate performs through the same dispatcher was
  missing, while `zig fmt`, named by "the two file-covering gates", reads
  its files without the dispatcher.

- Two accuracy repairs from a documentation audit: `src/root.zig`'s
  registration guidance no longer says registering a module keeps its public
  declarations covered by the "all public declarations analyze" test - that
  is the refAllDecls line's doing, as the comment's own next paragraph and
  the lint gate already state; and PRD 0003's failure-mode row no longer
  hardcodes seniority semantics ("the later-joining branch is archived") for
  which branch a merge archives, when the mode's ranking decides (*Partition
  and merge*) - under `configured`, an earlier-joining branch can lose.

- Both lint-gate walks (the covering gates' `appendZigFilesUnder` and the
  coverage gate's `appendProjectZigFiles`) now resolve an entry the
  filesystem could not classify instead of skipping it. On filesystems whose
  `getdents64`/`readdir` d_type answers nothing - XFS with `ftype=0`, some
  NFS and FUSE mounts - every entry reaches the walker as `.unknown`
  (verified on 0.16.0 in std.Io.Threaded's `dirReadLinux`), so a plain
  `.zig` source file fell out of the formatter, the column cap, the test
  binary and the coverage gate while `zig build test` stayed green.
- Such an entry now takes the same `statFile` probe a symlink takes; one that only
  the probe reveals as a directory is rejected loudly like a linked
  directory, since the walker has already declined to descend into it.

- The test-registration and declaration-analysis gates now match `@import`
  strings in their resolved form instead of byte-for-byte. Zig accepts
  spellings the exact comparison rejected or mismatched - a comptime
  `_ = @import("./sub/x.zig")` from a test root collected the target's
  tests (verified on 0.16.0 with a deliberately failing probe test) while
  the registration gate failed the tree as "not reachable from a test
  root"; a wrapper spelled `refAllDecls(@import(".//a.zig"))` did not
  silence a bare `@import("a.zig")` beside it; and interior `"name/.."`
  pairs matched nothing.
- Import strings are canonicalized where they enter
  the gates (`collectImports`' recorded paths, `importBetween`'s computed
  ones): empty components ("a//b"), "." components and resolvable "name/.."
  pairs collapse; leading ".." runs survive, there being no parent above
  them to pop into.

- Two accuracy repairs from this audit: docs/README no longer says every PRD
  cites the brief - PRD
  [0006](docs/prds/0006-scaling-to-groups-sharding-and-parity.md) postdates
  the clarification and does not quote it - and the `lint` step's changelog
  entry no longer pins its description at "four checks", a count the fifth
  gate's arrival had already made stale.

- The gate-coverage walk's failures now name the entry they stopped on
  (`cannot walk 'tools/vendor': LinkedDirectoryNotWalked`, not a bare
  `cannot walk the project tree: …`): a linked directory rejected by the
  walk or a symlink that no longer resolves failed the step with an error
  name alone, leaving the operator to find which of every walked entry was
  at fault - the same repair `checkedFiles` already made for its gate-path
  enumeration failures.

- Three accuracy repairs from a documentation audit: PRD 0001's control-entry
  table now names the `epoch` reason list PRD 0003 defines (`leader_lost`,
  `mode_change`, `merge`, `manual`) where it paraphrased three of the four
  values under different spellings, and its `checkpoint` row no longer
  describes removal as covering only TTL-expired payloads - author-staled
  entries join the same removal set when `stale.cleanup = delete`
  ([PRD 0002](docs/prds/0002-ttl-and-staleness.md), the glossary); and PRD
  0002's Status drops an ambiguous "host tested" qualifier from its
  `src/journal/expiry.zig` source-of-truth line.

- Three accuracy repairs from a documentation audit: the README's
  append-only bullet now scopes full replication to a member's group (the
  same unscoped claim an earlier pass fixed in docs/README's architecture
  summary, and contradicted by
  [PRD 0006](docs/prds/0006-scaling-to-groups-sharding-and-parity.md)'s
  ownership-and-routing overlay); `src/main.zig`'s doc comment no longer
  calls the file a placeholder "until RFC 0001 is decided" - that decision
  only picks which surface leads
  ([PRD 0005](docs/prds/0005-embedding-the-library-as-the-product.md)), and
  the placeholder ends when the library API and node CLI land; and PRD
  0003's Status reads "the design the RFC recommends", restoring a dropped
  article.

- The `lint` step's description names its gates again instead of stopping at
  "test registration": the string behind `zig build --help` still read
  "test registration" as the last gate after declaration-analysis enforcement
  joined it (the coverage-completeness entry under Added extends the same
  string).

- The `test` step's description says what it runs again: the string behind
  `zig build --help` still read "Run unit tests" after the lint gates were
  wired into `zig build test`; it now reads "Run unit tests and the lint
  gates", matching AGENTS.md's description of the step.

- Two accuracy repairs from a documentation audit: docs/README's
  architecture summary now scopes full replication to the group - the
  unscoped "every member holds every journal in full" contradicted both
  [PRD 0001](docs/prds/0001-journal-core.md)'s own constraint wording and
  the ownership-and-routing overlay of
  [PRD 0006](docs/prds/0006-scaling-to-groups-sharding-and-parity.md)
  described later in the same section; and the registration guidance in
  `src/root.zig` no longer says the lint gate fails *only* when no import
  chain reaches a module - it also fails a test-root import no refAllDecls
  call wraps, which that comment's next paragraph, `src/main.zig`'s, and
  build.zig already state.

- The 100-column cap's enumeration failure now names the checked path it
  stopped on (`cannot enumerate 'src': FileNotFound`, not a bare
  `FileNotFound`): `checkedFiles` can fail on any of its three entries, and
  every other file-access failure in the gates already reported which file
  it was reading.

- Symlink handling in the two file-covering lint gates: directory iteration
  reports a link as `.sym_link` - the walker never resolves it (verified on
  0.16.0: Linux's `getdents64` `d_type` reaches the filter untouched), so a
  symlinked `.zig` file under a checked path was silently outside both gates
  while they stayed green, and a symlinked directory's subtree went unwalked,
  against build.zig's own claim that "a linked-in source tree is analyzed
  like a real one". A walked entry that is a link is now resolved through
  `statFile`, which follows it (a linked `.zig` file is collected like a
  real one), and a linked directory fails both gates loudly instead of
  half-checking - following it would need cycle protection no current tree
  justifies.

- PRD 0003's `merge.settle_ms` default (30 s) is now registered as a
  placeholder with its bounds stated both ways (OQ 60) and cited from the
  settings table and PRD 0002's settle rule, matching every other timing
  default in the PRDs, each of which already named its open question.

- "All public declarations analyze" tests in both test roots
  (`src/root.zig`, `src/main.zig`): Zig's analyzer is lazy, so an
  unreferenced `pub` declaration was compiled into nothing and checked by
  nothing - a type error inside one reached a green build (demonstrated:
  an unreferenced function assigning a string to a `u32` passed
  `zig build test`). The tests reference every public declaration through
  `std.testing.refAllDecls`; each module registered for test collection now
  also gets a line there, so its declarations are semantically checked too.

- Toolchain-floor enforcement in the build: `zig build` now fails loudly when
  the running Zig is older than `minimum_zig_version` in build.zig.zon. Zig
  checks that field only for consumers fetching coppiz as a dependency, never
  for a tree built directly, so every analysis gate (`zig fmt --check`,
  the 100-column cap, test registration - the latter lexing with
  `std.zig.Tokenizer`) could otherwise run under undeclared toolchain
  semantics.

- Spec-consistency fourth pass: PRD 0001's duplicate acceptance-criterion id
  (two criteria labelled G3) is renumbered - the forgery negative test is now
  G7, and the roadmap's single-member gate cites G3–G7; PRD 0001's
  "No multi-cluster federation" non-goal is scoped to v1 with a cross-reference
  to PRD 0006, whose federation overlay it previously contradicted outright;
  OQ 3's layer note now records accurately where `write.ack` is called a
  setting (PRDs 0001 and 0006) versus assumed (PRD 0003) or passed per call
  (PRD 0005).

- Spec-consistency pass over the design records: PRD 0002's effective-TTL
  table and state diagram now match their own prose (`ttl.max_ms` clamps
  under `per_entry` too; author-staled entries remove only under
  `stale.cleanup = delete`); PRD 0004's empty-`authorities[]` validation rule
  carves out PRD 0003's one-member case.
- PRD 0001 G6's unnamed bounds get
  keys (`cluster.max_journals`, `sync.unslotted_max_bytes`) with values parked as OQ 55.
- A follow-up pass repaired research 0001's broken admission row
  (unescaped pipes split the Markdown table) and aligned ADR 0003's
  growth-path consequence with PRD 0006 and the roadmap (groups past 32,
  topology inside large groups; quorum stays a later mode option). A second
  pass corrected PRD 0001's `storage.fsync` classification (local config per
  PRD 0004's layer rule, not a chain setting) and the test-registration
  guidance in `src/root.zig`/`build.zig` (either test root counts), and made
  the PRD inventory row for 0003 match its title exactly.

- Spec-consistency follow-up: the `sync.*` knobs named across PRDs 0001–0003
  (`sync.page_bytes`, `sync.lag_slots`, `sync.gap_timeout_ms`) are now cited
  to a registered unknown (OQ 56) instead of silently lacking a layer and a
  default; PRD 0005's CLI list gains `settings` and `migrate` (named by PRD
  0004 and PRD 0005's own failure modes); RFC 0002 no longer claims PRD 0003
  documents the admitter-ordering caveat (that is the RFC's own open
  question); docs/README's planned source layout lists `src/config/`,
  `src/cli/` and `src/api/`.

- Spec-consistency third pass: ADR 0002's Decision names the `expired`
  transition (`live → expired → removed` under `ttl.action = delete`) that
  PRD 0002's diagram and the glossary already define; the `write.ack` layer
  (setting in PRDs 0001/0003/0006, per-call argument in PRD 0005's sketch)
  is registered in OQ 3 instead of silently ambiguous; and the glossary
  defines `cursor`, `follow`, `snapshot` and `control journal`, which PRDs
  0001/0004/0005/0006 used undefined.

- Lint gates wired into `zig build test` (and a standalone `zig build lint`
  step): canonical formatting via `zig fmt --check --ast-check`, run with the
  toolchain executing the build, a hard 100-column cap over `src/`,
  `build.zig` and `build.zig.zon`, and a test-registration check that fails
  when a `src/` module is not imported from a test root (its tests would
  otherwise silently never run). What CI gates once it exists stays open as
  OQ 45; until then the tests are the blocking entry point.

- Repository founded: Zig 0.16 skeleton (`coppiz` library module and node
  binary, both placeholders), clanker's documentation taxonomy under `docs/`,
  draft PRDs 0001–0005, RFCs 0001–0002, ADRs 0001–0002, research note 0001,
  the open-questions register and the glossary.

- OQ 49 resolved: groups use the same leadership modes and concurrency
  model as members; no uneven group count is required. PRD 0006 gains the
  two federation rules that follow (representative validated against the
  group's own chain; federation suspect timeout exceeds group election time).

- PRD 0006 (scaling 1 → n → groups: recursive groups, ownership and
  sharding, parity) with the list of what the core must get right now;
  scale tiers in the roadmap; OQ 48–54; federation settings scope reserved
  in PRD 0004; chain-per-journal and self-describing sealed segments in PRD
  0001.

- ADR 0003 (batteries included, no external infrastructure at any size),
  after the brief was clarified to be general-purpose; PRD 0005 reframed
  with clanker as a worked example host rather than the target; OQ 46–47.

- `.gitattributes` declaring LF for all text files, working trees included:
  `zig fmt --check` inside `zig build test` compares bytes and fails a
  CRLF checkout or commit, so the policy the build enforces is now pinned
  where checkouts and commits are made.

- PRD 0002's open-questions list now cites [OQ
  57](docs/prds/0002-ttl-and-staleness.md), which concerns that PRD's own schema - whether
  the `stale` cause is switchable per journal as ADR 0002 records - but was
  reachable only from the ADR and the register, not from the schema it is
  about.

- The test-registration lint gate now follows imports transitively. Zig
  0.16 collects a module's tests whenever a chain of analyzed imports
  reaches it from a test root, not only when a root imports it directly
  (verified on 0.16.0: with `src/root.zig` importing `a.zig` importing
  `b.zig`, `zig build test` runs b's tests), but the gate compared only
  direct root imports - a helper imported solely by another module failed
  the build as "no test root imports it" although its tests ran, and each
  such module had to be registered twice for no effect.
- The gate now walks
  real `@import` calls from the roots across every walked module, resolving
  import strings relative to the importing file's directory (`b.zig`
  beside the importer, `../other/x.zig` across branches); the report names
  the surviving failure precisely: "not reachable from a test root".

- Documentation-currency pass: PRD 0002's Design no longer opens with
  "three states" - its own diagram, the glossary and ADR 0002 all carry four
  (`live`, `stale`, `expired`, `removed`), so the prose now does too;
  seniority is no longer described as "position 0" for the founder -
  *position* is defined as `(epoch, seq)` and no slot has `seq = 0`, so both
  mentions say seniority rank 0.
- PRD 0001 counts clanker's survey as
  seventeen *candidates*, matching README and research 0001.
- ROADMAP's founding line lists five draft PRDs and two accepted ADRs (PRD 0006 and
  ADR 0003 landed after founding); the roadmap schedules the RFC 0001
  decision before PRD 0001 phase 4, the deadline RFC 0001's own comment
  period sets.
- OQ 29/30/38 cite the PRD 0005 phases that actually contain
  their work (3, 5 and 4, not 2, 4 and 3); PRD 0006's dependency list names
  OQ 48 alongside its siblings and its G1 cites OQ 54's measurement set
  instead of a roadmap section that does not exist.
- Research 0001's status
  no longer promises an evidence-log row for every claim (the findings table
  traces to the Scope-and-method sources) and References names clanker ADR
  0033, which the findings table cites.
- The glossary defines *sharding* and
  *instance*, used across PRD 0006 and the roadmap without definition.
- RFC 0002's driver 5 concedes merge's deterministic re-slotting, which its own
  option-A cons describe.

- Documentation audit: the codename is lowercase everywhere, sentence start
  included, as every other record writes it - four sentences in research 0001
  and OQ 41 capitalized it.

- PRD 0001's segment index is keyed by position `(epoch, seq)`, not bare
  `seq`: the slot layout makes `seq` dense within an epoch and restarting at
  1, so any segment spanning an `epoch` boundary holds two `seq = 1…k` runs
  and a `seq`-keyed index is ambiguous - against the glossary's own
  definition of *position*.

- Documentation-currency pass: PRD 0001 no longer says a `stale` mark names
  the `entry_hash` - [PRD 0002](docs/prds/0002-ttl-and-staleness.md) defines
  the payload as naming the target entry id `(author, author_seq)`, whose
  author field is what every member validates against; and its write-path
  step 4 clears the unslotted queue on receivers too, not only the author
  (the glossary defines the queue as holding received entries, and the
  optimistic-accept paragraph depends on that).

- Documentation-currency pass: PRD 0002's soft-expiry sentence no longer
  calls a TTL-reached entry "expired" under `mark_stale` - its own state
  diagram routes live → stale there, and *expired* is defined for
  `ttl.action = delete`.
- PRD 0003 cites OQ 43 where the brief's "definitely
  has the full state" is made a state; PRD 0004 gains criterion G6 for goal
  2's founder clause (`coppiz init` validates the initial settings),
  closing the goals↔criteria gap.
- The glossary defines `archived branch`,
  which PRD 0003 and RFC 0002 used without definition.
- Research 0001 no longer claims every row carries its read date (the findings table does
  not; the evidence log does, and now says so); the README counts clanker's
  survey as seventeen *candidates*, matching research 0001, whose option
  list includes libraries that are not stores.

- Spec-currency pass: PRD 0003's `epoch` entry shape now says its
  `reason` list (`leader_lost | mode_change | merge | manual`) is tier-1's
  and that [PRD 0006](docs/prds/0006-scaling-to-groups-sharding-and-parity.md)
  extends it with `ownership_transfer`, which the PRD used without noting the
  extension; and the failure-detector defaults (`cluster.heartbeat_ms` 1 s,
  `cluster.suspect_after_ms` 5 s) now carry their inline citation to
  [OQ 37](docs/rfcs/0034-leader-lease.md), where they are registered as placeholders -
  every other placeholder default in the PRDs already named its open question.

- Spec-currency pass: PRD 0004's acceptance criteria now cover the second
  half of its goal 4 - that a settings change takes effect at a defined slot
  (G4 also asserts effect from the slot after the `settings` entry, per its
  Design validation rule 4), closing the goals↔criteria gap the PRD template
  flags; and RFC 0002's option-A cons paragraph lost a stray three-space
  indent that broke its bullet's continuation alignment.

- Documentation-currency pass: the slot-growth mechanism parked at [OQ
  24](docs/rfcs/0032-archival-checkpoint.md) was named three ways across records - *chain
  checkpoint* (PRD 0002), *archival chain checkpoint* (ADR 0002, the
  roadmap) and *archival checkpoint* (the register). Every mention now says
  *archival checkpoint*, and the glossary defines it: four records used the
  term and none defined it, against the define-once rule. A `build.zig`
  test comment also stopped saying "the textual matcher admits" in the
  present tense - the matcher it means is the text-stripping one the
  tokenizer gate removed, so the present tense read as if the current gate
  were textual.

- The test-registration lint gate now matches real `@import` calls on each
  root's token stream instead of text after comment-stripping. The textual
  matcher admitted one false-pass direction beyond the multiline-string one
  fixed earlier: the literal characters `@import("sub/x.zig")` inside an
  ordinary string literal counted as registration while importing nothing,
  leaving that module's tests silently never run behind a green build. And
  stripping cut at the first `//` anywhere in a line, so an import sharing
  a line with an earlier `//` inside a string literal failed loudly though
  it was real.
- The tokenizer decides both directions: comments and every
  kind of string literal register nothing, a real import counts whatever
  shares its line, and a different builtin taking the same path
  (`@embedFile`) is not registration.

### Changed

- The unit of data is renamed from **ledger** to **journal**, and coppiz
  itself is described as a replicated, append-only *store* rather than a
  ledger: consumers fold a journal into whatever view (even a ledger) they
  need. Renames the PRD 0001 file and slug (`0001-journal-core.md`), the
  planned `src/journal/` layout, the settings keys (`journal.max_entry_bytes`,
  `cluster.max_journals`), the API sketch (`node.journal(name)`), and the
  glossary term. The brief's own word is kept in docs/brief.md and in verbatim
  citations of the brief; clanker's "improve ledger" and the industry "ledger
  family" are untouched.

- TTL and author-marked staleness are now a hard opt-in per journal and **off
  by default**: `ttl.enforce` defaults to `off` (was `per_entry`), a new
  `stale.enforce` key (`off | author`, default `off`) gates the staleness
  cause, and `stale.cleanup` defaults to `keep` (was `delete`). A journal
  whose settings never enabled a cause removes nothing and hides nothing;
  enabling one is a `settings` entry that applies only to entries slotted
  after it, so nothing already appended is ever removed retroactively. ADR
  0002's claim that both mutations are opt-in now matches the schema (OQ 57
  resolved 2026-08-27).

- The two lint-gate helpers taking a same-typed path pair - `symLinkOrSkip`
  (target/link) and `importBetween` (importer/target) - wrap each pair in a
  named struct so the two paths cannot be swapped at a call site, the
  convention `Source` already states for its own path/text pair; creating a
  link backwards or computing an import string between reversed endpoints
  both succeed silently otherwise. No gate outcome changes.

- The test-registration lint step enumerates `src/` through the same
  dispatcher as the 100-column cap (`checkedFiles`) instead of carrying its
  own copy of the enumerate-and-read scaffolding, and its failures now name
  what they stopped on like the column cap's (`cannot enumerate 'src': …`,
  `cannot read 'x.zig': …`, not "the src/ modules"). No gate outcome
  changes.

- The lint gates' file-access failures now name what they were reading: a
  checked path that could not be read surfaced as a bare OS error
  (`FileNotFound`) with no path, leaving the operator to re-derive the gate's
  file list by hand before the failure could be fixed. Each failure point in
  the 100-column-cap and test-registration steps reports the operation, the
  path and the OS error instead; both gates still fail loudly, never skip a
  file silently.

- Spec-currency pass: clanker's RFC 0019 was reopened at source (2026-08-24)
  and the claims README and PRD 0001 cite from it hold - the survey scope
  (17 candidates at Draft 4 plus R/S/T at Draft 5), option T *Packaging*
  naming this project, the still-unrun stage-1 spike, the port-blind
  `networkAllowed`, and the improve-ledger rewrite. Research 0001's evidence
  log now carries that row with its read date, so the "seventeen stores"
  figure is traceable in-repo instead of resting on the carried note alone
  ([OQ 40](docs/research/0001-evidence-carried-from-the-state-store-survey.md)) stays open for the remaining rows); the
  glossary defines `genesis` and `segment`, which every record used and only
  their derivatives (`founder`, `sealed segment`) defined.

- Spec-currency pass: ADR 0002's claim that a setting gates each mutation
  cause is reconciled with PRD 0002's actual schema, which turns the `stale`
  cause off nowhere (`stale.cleanup` governs only removal) - registered as
  OQ 57 and cross-cited from the ADR instead of silently contradicting an
  accepted record; RFC 0002's admitter-discretion open question is
  registered as OQ 58 and cited from the RFC; OQ 46–47 move to the
  register's Embedding section, where its own placement rule puts them; the
  ADR inventory row for 0003 matches that ADR's title exactly.

- Documentation audit: PRD 0002's `ttl.max_ms` prose no longer calls the cap
  advisory under `per_entry` (its own table clamps there too) and states
  header retention as 164 bytes per removed entry, the exact sum of PRD
  0001's draft header layout; PRD 0006 no longer cites acceptance criterion
  G6 for the dead-owner blast radius and no longer lists resolved OQ 49
  among its undecided dependencies; the ADR inventory row for 0002 matches
  that ADR's title.

- PRD 0001 pins byte order once for every fixed layout: "all integers
  little-endian" lived only in the entry-header parenthetical, leaving the
  slot table and the segment record prefix, header and index silent - a codec
  written from those sections alone had nothing ruling out the writing host's
  native order. A Byte order note now covers entry, slot and segment layouts.

- The lint gates no longer depend on the working directory `zig build` was
  invoked from: they read files and ran `zig fmt` relative to the process
  cwd, while the build runner walks up from a subdirectory to find
  `build.zig` without changing directory - so `zig build test` run anywhere
  under the project failed all three gates with FileNotFound. Every gate is
  now anchored to the build root (`fmt --check` via the run step's cwd, the
  other two via the build root's directory handle).

- The test-registration lint gate now matches its own test-root list
  regardless of platform: `src/root.zig` and `src/main.zig` were compared
  byte-for-byte against paths joined with the platform separator, so on
  Windows (`src\root.zig`) neither root was recognized - both were checked
  as ordinary modules nothing imports, and every module would have failed
  the gate. The walked path's separators are normalized before the
  comparison; unit-tested via the host-target module compiled from
  `build.zig`.

- The test-registration lint gate now matches import paths in `/` form
  regardless of platform: it compared filesystem paths from
  `std.fs.path.join` (backslash-separated on Windows) against
  `@import("sub/x.zig")` strings, which are always slash-separated, so on
  Windows every module would have failed the gate once the first submodule
  existed. Separators are translated before matching; unit-tested via the
  host-target module compiled from `build.zig`.

- Two cross-reference repairs in the design records: PRD 0002's
  per-entry-expiry-action non-goal cited OQ 6, which is the question of who
  may mark stale beyond the author - no registered question covers per-entry
  overrides, so the false citation is dropped; PRD 0003's epoch paragraph
  called epoch numbers unique per leader change in the sentence explaining
  how two branches end up with the same number, and now says each branch
  advances its own counter.

- The two file-covering lint gates (`zig fmt --check --ast-check` and the
  100-column cap) now derive their checked-path set from one shared list in
  `build.zig`, where each previously wrote its own: adding a source file or
  directory meant editing both lists, and missing one left the new file
  outside a gate silently. Coverage over the current tree is unchanged.

- The package version is parsed by the library, not the build script:
  `build.zig` hands over only the raw `build.zig.zon` declaration and
  `src/root.zig` parses it into `coppiz.version`, so the single-source-of-truth
  value is never carried twice in lockstep, and a value that is not valid
  Semantic Versioning fails compiling `src/root.zig` instead of surfacing only
  when the build script runs.

- Test-registration lint gate no longer counts `@import("...")` mentions
  inside comments: roots are matched with line comments stripped, so a
  commented-out reference cannot mask a module whose tests never run. The
  stripping only removes text, so the failure mode stays loud (a real
  import sharing a line after a `//` fails the gate until it gets its own
  line). The gate's matching logic now carries unit tests of its own, run
  by `zig build test` via a host-target test module compiled from
  `build.zig`.

- The same gate also drops multiline-string lines before matching:
  `@import("...")` written as text inside a `\`-string literal counted as
  registration while importing nothing - the false-pass direction, unlike
  every other stripping artifact. Unit-tested with the gate's own tests.
