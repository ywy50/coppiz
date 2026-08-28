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

- [2026-08-28 — `zig build test` is red: the CLI test root uses `std.c.getpid()` without linking libc](bugs/2026-08-28-build-test-red-libc-getpid.md)
- [2026-08-28 — `zig build test` is red: `Hub.deinit(self, io)` called with no arguments at three test sites](bugs/2026-08-28-build-test-red-hub-deinit-arity.md)
- [2026-08-28 — segment ordinal arithmetic collides after compaction; `sealHead` truncates the journal's own first segment](bugs/2026-08-28-segment-ordinal-collision-after-compact.md)
- [2026-08-28 — settings codec truncates u16 length fields: a value ≥ 64 KiB panics the leader in debug builds](bugs/2026-08-28-settings-codec-u16-overflow.md)
- [2026-08-28 — the `coppiz.toml` subset parser is quote-unaware: `#` and `,` inside quoted values silently corrupt them](bugs/2026-08-28-toml-parser-quote-unaware.md)
- [2026-08-28 — simulator `growLinks` reopens a closed partition every time a member joins](bugs/2026-08-28-sim-growlinks-reopens-partition.md)
- [2026-08-28 — `ttl.retain = none` compaction makes a journal unfoldable on reopen](bugs/2026-08-28-retain-none-reopen-badprevhash.md)
- [2026-08-28 — the checkpoint merge-settle rule reads the data fold's `last_merge`, which is never set](bugs/2026-08-28-merge-settle-rule-dead.md)
- [2026-08-28 — a re-slotted `create_journal` is always refused: the merge stalls](bugs/2026-08-28-reslotted-create-journal-refused.md)
- [2026-08-28 — `ClusterNode.localAppend` completions are lost during backfill/merge: the embedded host's write blocks forever](bugs/2026-08-28-localappend-completion-lost.md)
- [2026-08-28 — a follower that misses one data-journal broadcast is permanently behind (silent stale reads)](bugs/2026-08-28-follower-data-gap-stale.md)
- [2026-08-28 — hub `connectFn`/`listen` errdefer double-free on allocation failure](bugs/2026-08-28-hub-errdefer-double-free.md)
- [2026-08-28 — `Hub.listen` on a duplicate address silently replaces the first endpoint](bugs/2026-08-28-hub-listen-duplicate-address.md)
- [2026-08-28 — `Queue.open` truncates the queue on any decode failure, dropping acknowledged entries](bugs/2026-08-28-queue-open-truncates-on-corruption.md)
- [2026-08-28 — `applySettings` can commit part of a settings entry before failing: the replicated fold diverges on OOM](bugs/2026-08-28-settings-apply-partial-commit.md)
- [2026-08-28 — `cmdServe` silently drops a malformed `[[peers]] public_key` from the allowlist](bugs/2026-08-28-cmdserve-silent-allowlist-drop.md)
- [2026-08-28 — the process-level e2e tests race the install step](bugs/2026-08-28-process-tests-race-install.md)
- [2026-08-28 — one process-level e2e test hardcodes a port, defeating the pid-derived port design](bugs/2026-08-28-e2e-hardcoded-port.md)
- [2026-08-28 — a join can silently strand the cluster leaderless: `configured` + `stall` with empty authorities](bugs/2026-08-28-join-can-strand-cluster-leaderless.md)
- [2026-08-28 — a re-slot redelivery lowers `authors.last_seq`, bypassing the `DuplicateConflict` rule](bugs/2026-08-28-redelivery-lowers-author-seq.md)
- [2026-08-28 — `Direction.readInto` frees an interior pointer on a partial read (latent)](bugs/2026-08-28-direction-partial-read-free.md)
- [2026-08-28 — `HubListener.closeFn` writes `endpoint.closed` without the endpoint mutex (latent)](bugs/2026-08-28-hub-listener-close-race.md)
- [2026-08-28 — PR #19's install-only-coppiz wiring broke the G2 sidecar test; `zig build test` was red on `main` again](bugs/2026-08-28-g2-sidecar-needs-install.md)
- [2026-08-28 — `ServingProc.stop` burns 5 s per killed serve: the process-level tests spent ~60 s of the gate on zombie polls](bugs/2026-08-28-servingproc-stop-zombie-poll.md)

### Investigations

- [2026-08-28 — making `zig build test` faster without dropping tests](investigations/2026-08-28-test-suite-quick-wins.md)
