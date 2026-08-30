# Operational reports

This directory preserves the evidence, diagnosis, resolution, and verification
of bugs and investigations that would otherwise be lost in a run log or a pull
request discussion. It complements PRDs: a PRD describes intended behavior; a
report explains an observed failure and the work that resolved it.

## Start here

- Use [bugs/TEMPLATE.md](bugs/TEMPLATE.md) for a confirmed defect that needs a
  durable record, including its resolution.
- Use [investigations/TEMPLATE.md](investigations/TEMPLATE.md) while tracing a
  symptom, even if the eventual result is "not a bug".
- Every report starts with `## TL;DR`, then gives the detail needed to repeat
  the reasoning without reconstructing it from logs.
- Name reports `YYYY-MM-DD-<short-topic>.md`, keep the file in the matching
  subdirectory, and add it to the inventory below when it is created.
- When an investigation confirms a defect, link its bug report both ways. When
  the defect is resolved, keep the original evidence and add the fix commit,
  tests, and any remaining risk instead of rewriting the incident away.
- When the resolution is a repeatable recovery procedure, create or update its
  companion [runbook](../runbooks/) as well.

Write only what you checked: give the mechanism and the command, not the
motive; mark unverified as unverified, or omit it.

## Inventory

### Bugs

- [2026-08-28 - `zig build test` is red: the CLI test root uses `std.c.getpid()` without linking libc](bugs/2026-08-28-build-test-red-libc-getpid.md)
- [2026-08-28 - `zig build test` is red: `Hub.deinit(self, io)` called with no arguments at three test sites](bugs/2026-08-28-build-test-red-hub-deinit-arity.md)
- [2026-08-28 - segment ordinal arithmetic collides after compaction; `sealHead` truncates the journal's own first segment](bugs/2026-08-28-segment-ordinal-collision-after-compact.md)
- [2026-08-28 - settings codec truncates u16 length fields: a value ≥ 64 KiB panics the leader in debug builds](bugs/2026-08-28-settings-codec-u16-overflow.md)
- [2026-08-28 - the `coppiz.toml` subset parser is quote-unaware: `#` and `,` inside quoted values silently corrupt them](bugs/2026-08-28-toml-parser-quote-unaware.md)
- [2026-08-28 - simulator `growLinks` reopens a closed partition every time a member joins](bugs/2026-08-28-sim-growlinks-reopens-partition.md)
- [2026-08-28 - `ttl.retain = none` compaction makes a journal unfoldable on reopen](bugs/2026-08-28-retain-none-reopen-badprevhash.md)
- [2026-08-28 - the checkpoint merge-settle rule reads the data fold's `last_merge`, which is never set](bugs/2026-08-28-merge-settle-rule-dead.md)
- [2026-08-28 - a re-slotted `create_journal` is always refused: the merge stalls](bugs/2026-08-28-reslotted-create-journal-refused.md)
- [2026-08-28 - `ClusterNode.localAppend` completions are lost during backfill/merge: the embedded host's write blocks forever](bugs/2026-08-28-localappend-completion-lost.md)
- [2026-08-28 - a follower that misses one data-journal broadcast is permanently behind (silent stale reads)](bugs/2026-08-28-follower-data-gap-stale.md)
- [2026-08-28 - hub `connectFn`/`listen` errdefer double-free on allocation failure](bugs/2026-08-28-hub-errdefer-double-free.md)
- [2026-08-28 - `Hub.listen` on a duplicate address silently replaces the first endpoint](bugs/2026-08-28-hub-listen-duplicate-address.md)
- [2026-08-28 - `Queue.open` truncates the queue on any decode failure, dropping acknowledged entries](bugs/2026-08-28-queue-open-truncates-on-corruption.md)
- [2026-08-28 - `applySettings` can commit part of a settings entry before failing: the replicated fold diverges on OOM](bugs/2026-08-28-settings-apply-partial-commit.md)
- [2026-08-28 - `cmdServe` silently drops a malformed `[[peers]] public_key` from the allowlist](bugs/2026-08-28-cmdserve-silent-allowlist-drop.md)
- [2026-08-28 - the process-level e2e tests race the install step](bugs/2026-08-28-process-tests-race-install.md)
- [2026-08-28 - one process-level e2e test hardcodes a port, defeating the pid-derived port design](bugs/2026-08-28-e2e-hardcoded-port.md)
- [2026-08-28 - a join can silently strand the cluster leaderless: `configured` + `stall` with empty authorities](bugs/2026-08-28-join-can-strand-cluster-leaderless.md)
- [2026-08-28 - a re-slot redelivery lowers `authors.last_seq`, bypassing the `DuplicateConflict` rule](bugs/2026-08-28-redelivery-lowers-author-seq.md)
- [2026-08-28 - `Direction.readInto` frees an interior pointer on a partial read (latent)](bugs/2026-08-28-direction-partial-read-free.md)
- [2026-08-28 - `HubListener.closeFn` writes `endpoint.closed` without the endpoint mutex (latent)](bugs/2026-08-28-hub-listener-close-race.md)
- [2026-08-28 - PR #19's install-only-coppiz wiring broke the G2 sidecar test; `zig build test` was red on `main` again](bugs/2026-08-28-g2-sidecar-needs-install.md)
- [2026-08-28 - `ServingProc.stop` burns 5 s per killed serve: the process-level tests spent ~60 s of the gate on zombie polls](bugs/2026-08-28-servingproc-stop-zombie-poll.md)
- [2026-08-29 - `reforwardQueue`'s leader-slot branches never complete `pending_locals`: an embedded host's `localAppend` hangs forever on election](bugs/2026-08-29-reforward-queue-loses-local-completion.md)
- [2026-08-29 - merge data re-slots refuse `settings`/`checkpoint`/`stale` records: the heal never completes (and a `leave` before data can lose the branch)](bugs/2026-08-29-merge-data-reslot-refusals.md)
- [2026-08-29 - `zig build test` randomly hangs: the e2e cluster tests fsync every record onto the host filesystem, and a stalled fsync blocks the suite forever](bugs/2026-08-29-e2e-fsync-stall-hang.md)
- [2026-08-30 - an authority array item with a trailing bare token is stored verbatim, quotes included](bugs/2026-08-30-config-array-trailing-token.md)
- [2026-08-30 - `SettingsState.clone` leaks already-cloned values when a later clone fails](bugs/2026-08-30-settings-clone-leak.md)
- [2026-08-30 - `tcpListen` leaks the listening socket when the listener allocation fails](bugs/2026-08-30-tcp-listen-fd-leak-on-oom.md)
- [2026-08-30 - the hub's dropped-edge check overflows its fixed buffer for long address pairs](bugs/2026-08-30-hub-dropped-edge-long-address.md)
- [2026-08-30 - the loop sim's fixed convergence window flakes: the threaded io's completion ordering is not fixed](bugs/2026-08-30-loopworld-convergence-window.md)
- [2026-08-30 - a suspected member is never redialed: the suspect branch shadows the dial branch](bugs/2026-08-30-lost-member-never-redialed.md)
- [2026-08-30 - the open-time generation recovery deletes the complete old generation for a partial new one](bugs/2026-08-30-generation-recovery-partial-new.md)
- [2026-08-30 - the wire encoders cast a journal name's length to u16 unchecked: a 64 KiB name panics the CLI](bugs/2026-08-30-wire-name-len-unchecked.md)
- [2026-08-29 - a chainless member panics on a peer's control record: the fold unwraps a null epoch](bugs/2026-08-29-chainless-member-null-epoch-panic.md)
- [2026-08-29 - `zig build test` is red on main: a crashed-compaction test builds its path out of an undefined buffer tail](bugs/2026-08-29-store-recovery-test-undefined-path.md)
- [2026-08-29 - the now-live merge settle rule kills the leader's checkpoint cadence: `MergeSettling` is fatal to the loop after every heal](bugs/2026-08-29-settle-rule-kills-checkpoint-cadence.md)
- [2026-08-29 - the re-slotted `create_journal` variant is reachable live: any member can create journals via the forward path](bugs/2026-08-29-live-create-journal-bypass.md)
- [2026-08-29 - `parsePeerKey` frees the old `public_key` before validating the new one: a malformed second key is a double-free](bugs/2026-08-29-parse-peer-key-double-free.md)
- [2026-08-29 - `Node.createJournal` is a dead public API with a latent compile error](bugs/2026-08-29-node-createjournal-compile-error.md)
- [2026-08-29 - control/checkpoint writes fold before the store write: an I/O error leaves the fold one record ahead and the chain unreopenable](bugs/2026-08-29-fold-before-store-order.md)
- [2026-08-29 - wire reads silently drop compacted (retain=none) records; the local read shows them as `(removed)`](bugs/2026-08-29-wire-read-drops-compacted-slots.md)
- [2026-08-29 - merge re-slots do not clamp the slot timestamp: a clock regression stalls the heal with `BadTimestamp`](bugs/2026-08-29-merge-reslot-timestamp-unclamped.md)
- [2026-08-29 - TCP accept/connect leak the OS socket when the `TcpConn` allocation fails](bugs/2026-08-29-tcp-conn-fd-leak-on-oom.md)
- [2026-08-29 - `decodeValue` string_list leaks already-duped items on its error paths](bugs/2026-08-29-decode-value-string-list-leak.md)
- [2026-08-29 - the quote-aware TOML scanner ignores the `\"` escape and accepts unterminated quotes](bugs/2026-08-29-toml-parser-escapes-and-unterminated.md)
- [2026-08-29 - `encodeCreateJournalPayload` writes the journal name with an unchecked u16 cast: a 64 KiB name panics in debug](bugs/2026-08-29-create-journal-name-codec-overflow.md)
- [2026-08-29 - `compact` is not crash-atomic: an interrupted compaction leaves duplicate segments and the journal refuses to reopen](bugs/2026-08-29-compact-not-crash-atomic.md)
- [2026-08-29 - the simulator's `heal` discards losing-side messages still in inboxes](bugs/2026-08-29-sim-heal-drops-inbox.md)
- [2026-08-29 - `zig build test` never finishes: three-node tests deadlock the `Io` thread pool](bugs/2026-08-29-embed-cluster-async-limit-deadlock.md)
- [2026-08-29 - length-prefix arithmetic computes in the prefix's own narrow type: a peer-chosen `payload_len` panics the decoder](bugs/2026-08-29-entry-decode-payload-len-overflow.md)
- [2026-08-29 - `coppiz init` on an already-initialized directory replaces `member.key` and writes a second control chain](bugs/2026-08-29-init-overwrites-member-key.md)
- [2026-08-29 - `cmdInit`'s `errdefer data_dir.close(io)` closes a descriptor the store already closed](bugs/2026-08-29-init-data-dir-double-close.md)
- [2026-08-29 - `Hub.drop` leaks the edge key every time an already-dropped edge is dropped again](bugs/2026-08-29-hub-drop-duplicate-edge-key-leak.md)
- [2026-08-29 - the wire client asserts on the peer's read cursor: a non-advancing `next` panics or loops forever](bugs/2026-08-29-client-read-cursor-assert.md)
- [2026-08-29 - wire length checks compute in the peer's own narrow int type: an 84-byte hello aborts an unadmitted node](bugs/2026-08-29-wire-length-checks-narrow-int.md)
- [2026-08-29 - a deferred `leave` that refuses leaves a freed payload in the merge list, and the next free of it is a double free](bugs/2026-08-29-merge-deferred-leaves-double-free.md)
- [2026-08-29 - `TcpConn.recvFrame` throws away every byte the socket read past the current frame](bugs/2026-08-29-tcp-recvframe-drops-buffered-bytes.md)
- [2026-08-29 - three cluster allocations are owned by nobody when the step after them fails](bugs/2026-08-29-cluster-alloc-ownership-error-paths.md)
- [2026-08-28 - sweep3: a chainless joiner whose first tick fires before admission never backfills](bugs/2026-08-28-sweep3-joiner-syncing-race.md)
- [2026-08-28 - sweep3: an accepted append between ~8 MB and 16 MB can never be replicated](bugs/2026-08-28-sweep3-oversized-entry-unreplicable.md)
- [2026-08-28 - sweep3: `decodeRecord` length-prefix arithmetic overflows u32 - remote crash](bugs/2026-08-28-sweep3-record-length-overflow.md)
- [2026-08-28 - sweep3: header-only (`payload_omitted`) records accepted as live entries](bugs/2026-08-28-sweep3-header-only-entry-accepted.md)
- [2026-08-28 - sweep3: `hasSeal` conflates "seal invalid" with "no seal" - sealed data silently truncated](bugs/2026-08-28-sweep3-hasseal-conflation.md)
- [2026-08-28 - sweep3: the `freshest` tiebreak is dead; node/simulator survivors can disagree](bugs/2026-08-28-sweep3-freshest-tiebreak-dead.md)
- [2026-08-28 - sweep3: pre-failover journal `settings`/`checkpoint` records refuse on reopen](bugs/2026-08-28-sweep3-pre-failover-settings-replay.md)
- [2026-08-28 - sweep3: backfill over a `retain = none` chain never terminates](bugs/2026-08-28-sweep3-backfill-compacted-chain-loop.md)
- [2026-08-28 - sweep3: a hello landing on a non-leader is answered "admitted", then refused forever](bugs/2026-08-28-sweep3-follower-admitter-join-fails.md)
- [2026-08-28 - sweep3: members learned from the fold after startup are never dialed (star topology)](bugs/2026-08-28-sweep3-fold-members-never-dialed.md)
- [2026-08-28 - sweep3: `truncate`'s errdefer double-closes the adopted segment on `rebuildIndex` failure](bugs/2026-08-28-sweep3-truncate-errdefer-double-close.md)
- [2026-08-28 - sweep3: a non-empty authority list matching no member strands the cluster](bugs/2026-08-28-sweep3-ghost-authority-strand.md)
- [2026-08-28 - sweep3: 8695ee1's test waits read node-loop state cross-thread (data race)](bugs/2026-08-28-sweep3-test-waits-cross-thread-race.md)
- [2026-08-28 - sweep3: the simulator's `heal` truncates a side whose leader crashed mid-partition](bugs/2026-08-28-sweep3-sim-heal-crashed-leader.md)
- [2026-08-28 - sweep3: `leaderHex` makes a single un-retried status call (flaky suite)](bugs/2026-08-28-sweep3-leaderhex-flaky-status.md)
- [2026-08-28 - sweep3: `coppiz admit` panics on a chainless directory](bugs/2026-08-28-sweep3-cmdadmit-chainless-panic.md)
- [2026-08-28 - sweep3: wire read of an unknown journal silently succeeds with empty output](bugs/2026-08-28-sweep3-wire-read-unknown-journal.md)
- [2026-08-28 - sweep3: duplicate top-level `coppiz.toml` keys leak the previous value](bugs/2026-08-28-sweep3-duplicate-toml-key-leak.md)
- [2026-08-28 - sweep3: settings/join/create-journal decode OOM folded into a normal refusal](bugs/2026-08-28-sweep3-decode-oom-mapped-to-refusal.md)
- [2026-08-28 - sweep3: `slotQueuedEntries` propagates a per-entry refusal to `fatal()`](bugs/2026-08-28-sweep3-slotqueued-refusal-fatal.md)
- [2026-08-29 - the in-memory hub's `pipes` list is appended without a lock: concurrent dials leak its backing buffer](bugs/2026-08-29-hub-pipes-append-unsynchronised.md)
- [2026-08-29 - the 1 -> 2 -> 3 growth e2e intermittently times out waiting for the last replicated entry](bugs/2026-08-29-growth-e2e-last-broadcast-timeout.md)
- [2026-08-29 - a backfilling member drops the newest broadcast and never asks for it again](bugs/2026-08-29-syncing-drops-the-newest-broadcast.md)
- [2026-08-29 - `onMergeAck` truncates every data journal for any peer that asks](bugs/2026-08-29-merge-ack-unauthenticated.md)
- [2026-08-29 - a `slot` whose record carries trailing junk decodes as valid, and the follower's fold advances past the store write that refuses it](bugs/2026-08-29-slot-record-trailing-bytes.md)
- [2026-08-29 - `onSlot` swallows a refused store write, leaving the fold ahead of the segment file](bugs/2026-08-29-onslot-swallows-store-write-failure.md)
- [2026-08-29 - an ordinary failover leaves `becomeLoser` truncating a committed suffix](bugs/2026-08-29-branch-facts-never-reset.md)
- [2026-08-29 - `beginMerge` records a merge whose branch request never went out](bugs/2026-08-29-begin-merge-commits-on-a-dropped-sync.md)
- [2026-08-29 - four `closeFn`s guard against a second close with a flag that lives in the allocation the first close freed (latent)](bugs/2026-08-29-close-guard-in-freed-allocation.md)
- [2026-08-29 - `readerMain` reads the `conns` map from a pool thread while the loop thread mutates it (latent, not fixed)](bugs/2026-08-29-readermain-conns-map-race.md)
- [2026-08-30 - a segment file left shorter than its header panics `Store.open`](bugs/2026-08-30-segment-shorter-than-header-panics-open.md)
- [2026-08-30 - a segment header naming another journal closes the file twice](bugs/2026-08-30-journal-id-mismatch-double-close.md)
- [2026-08-30 - the removal-set fast path reads live settings, so turning TTL off strands expired entries forever](bugs/2026-08-30-removal-guard-reads-live-settings.md)
- [2026-08-30 - a member's redial backoff ratchets to 8 s and never comes back down](bugs/2026-08-30-redial-backoff-never-resets.md)
- [2026-08-30 - a `members_page` address at the u16 maximum aborts the node before admission](bugs/2026-08-30-members-page-addr-len-narrow-int.md)
- [2026-08-30 - a member can occupy another member's id-named authority slot by advertising its id as an address](bugs/2026-08-30-authority-address-id-collision.md)
- [2026-08-30 - one `merge_offer` frame aborts a member that has not finished its first backfill](bugs/2026-08-30-chainless-merge-offer-panic.md)
- [2026-08-30 - the survivor broadcasts its merge re-slots as live records, so every other member refuses them](bugs/2026-08-30-merge-data-broadcast-reslotted-false.md)
- [2026-08-30 - shutting the loop down strands every host thread parked on it](bugs/2026-08-30-shutdown-strands-local-completions.md)
- [2026-08-30 - a three-member merge strands the losing branch's follower (open)](bugs/2026-08-30-three-member-merge-strands-the-losing-follower.md)

### Investigations

- [2026-08-29 - the unslotted queue's drain I/O on a confirmation burst](investigations/2026-08-29-queue-drain-burst-io.md)
- [2026-08-29 - OQ 62 defensive hardening: the rebuilt index's fresh map](investigations/2026-08-29-oq62-index-rebuild-hardening.md)
- [2026-08-29 - steady-state allocation churn: heartbeats and per-tick views](investigations/2026-08-29-steady-state-allocations.md)
- [2026-08-29 - the leader encodes each replicated slot twice](investigations/2026-08-29-leader-encode-once.md)
- [2026-08-29 - verification of the test-build speedup reports and their remaining open topics](investigations/2026-08-29-test-build-sweep-verification.md)
- [2026-08-29 - runtime speedup sweep: findings and disposition](investigations/2026-08-29-runtime-sweep-findings.md)
- [2026-08-29 - simulator leader evaluation and TCP page writes](investigations/2026-08-29-runtime-sweep-sim-micro.md)
- [2026-08-29 - write-path data flow: queue drains, replication re-encodes, and per-frame overhead](investigations/2026-08-29-runtime-sweep-queue-wire.md)
- [2026-08-29 - range reads and open-time discovery on the journal read paths](investigations/2026-08-29-runtime-sweep-journal-read.md)
- [2026-08-29 - settings key resolution and checkpoint removal sets on the control paths](investigations/2026-08-29-runtime-sweep-settings-checkpoint.md)
- [2026-08-28 - making `zig build test` faster without dropping tests](investigations/2026-08-28-test-suite-quick-wins.md)
- [2026-08-30 - a scalar `coppiz.toml` value with unbalanced quotes is stored verbatim, quote included](bugs/2026-08-30-toml-scalar-unbalanced-quote.md)
- [2026-08-30 - an allowlist-only `[[peers]]` entry is dialed forever at the empty address](bugs/2026-08-30-allowlist-only-peer-dialed-forever.md)
- [2026-08-30 - a refused `Store.open` leaks the journal state it had already built](bugs/2026-08-30-store-open-refusal-leaks-journal-state.md)
- [2026-08-30 - an already-removed entry re-enters every later removal set, so an idle journal emits a checkpoint per interval](bugs/2026-08-30-removed-entries-re-enter-the-removal-set.md) - **open**
