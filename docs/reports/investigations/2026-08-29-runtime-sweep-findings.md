# Investigation — runtime speedup sweep: findings and disposition

## TL;DR

- **Question:** where does the coppiz runtime spend CPU and I/O that it does
  not need to, without changing behavior?
- **Finding:** a sweep of `src/` found 18 concrete waste sites. Eight are
  pure same-semantics refactors and are implemented across four stacked PRs
  (this report links each to its investigation report); the rest are
  durability, format, or contract trade-offs that need an RFC or a reviewer —
  led by the append fsync discipline ([RFC 0003](../../rfcs/0003-append-durability-fsync-policy.md)).
- **Resolution:** four implementation PRs, one RFC PR, plus this record of
  the full sweep.

## Status

Resolved for the implemented subset; the deferred items are tracked below
with their required next step. Environment findings (flaky gate, OQ 62
spin) are recorded — not closed.

## Trigger and scope

Tasked with speeding up the execution runtime without dropping features,
bug fixes, or stability. A read sweep of `src/` (all 23.5k lines across the
journal, cluster, net, settings, config, sim, and CLI modules) produced the
findings below; each was verified by reading the code before being acted
on. The gate was also observed on this machine: green when clean
(261/261), but lib_tests runs ~3.5 min here (vs ~30 s on the machine the
2026-08-28 investigation measured), the process-level `status` test flakes
intermittently under `zig build test`, and the OQ 62 CPU spin reproduced
once (a lib_tests binary at 112% CPU for 9+ minutes after a failed run).

## Findings — implemented (same semantics, verified green)

| # | Site | Fix | PR | Report |
|---|---|---|---|---|
| 1 | `schema.keyIndex` runtime linear scan on tick/append/checkpoint paths | comptime resolution via `inline for`; runtime variant for user input | 1 | [settings and checkpoint](2026-08-29-runtime-sweep-settings-checkpoint.md) |
| 2 | `SettingsState.encodeCanonical` 25 scratch alloc/free per hash | encode in place into the output buffer | 1 | same |
| 3 | checkpoint removal set materialized 1–3×/checkpoint, provably empty under defaults | `expiry.canRemoveAnything` guard | 1 | same |
| 4 | `readRange` sorted the whole entries map per call | walk the store (`scanFrom`), windowed, early-stop, one `now` snapshot | 2 | [journal read](2026-08-29-runtime-sweep-journal-read.md) |
| 5 | `foldAll` scanned every journal in full to classify its first record | `Store.firstRecordKind` | 2 | same |
| 6 | `Queue.remove` re-encoded every kept record per trim | raw-span copy; header-only decode for the match | 3 | [queue and wire](2026-08-29-runtime-sweep-queue-wire.md) |
| 7 | replicated slots re-encoded on every follower after decode | `Store.appendRecord` appends the wire bytes verbatim | 3 | same |
| 8 | `sendForward` double-allocated | one frame-body allocation | 3 | same |
| 9 | hub pushed header+body as two chunks per frame | `Direction.pushFramed` | 3 | same |
| 10 | `reforwardQueue` scanned the whole file on every hello | early-exit on an empty queue | 3 | same |
| 11 | sim `nodeIndex` linear scan made leader evaluation O(n³)/tick | id→index map (nodes never removed) | 4 | [sim and micro](2026-08-29-runtime-sweep-sim-micro.md) |
| 12 | TCP `sendFrame` 4 KiB buffer spilled per page | 64 KiB buffer | 4 | same |

Each PR ran `zig build test` on this machine: 261/261 pass, exit 0, lint
green (PR 3's first run failed only the 100-column cap on one wrapped call,
fixed before merge).

## Findings — deferred, with required next step

| # | Site | Why deferred | Next step |
|---|---|---|---|
| 13 | append pays 3 fsyncs; queue ignores `storage.fsync`; `clear` barrier redundant | durability trade-off | [RFC 0003](../../rfcs/0003-append-durability-fsync-policy.md) — recommended: knob governs the queue, `clear` never syncs |
| 14 | `Queue.remove` rewrites the whole file per trim (O(k²) I/O on a burst) | on-disk format change (tombstone/watermark/batched drain) | separate RFC, linked from RFC 0003's out-of-scope |
| 15 | per-frame decode dupes every variable-length part | the owning-decoder contract is a documented invariant (`message.zig:6-8`) with tests | RFC; benchmark the win before proposing the borrow change |
| 16 | leader re-encodes for broadcast what it wrote to store | touches every broadcast call site; the follower-side win (#7) landed first | reviewer pass, or fold into the message-layer work in #15 |
| 17 | leader verifies its own just-written entry + slot (2 Ed25519 verifies/append) | changes where validation happens | reviewer decision; the redundant `entryHash`/`slotHash` recompute is trivially safe on its own |
| 18 | `store.read` two positional reads per record (`readById`) | the prefix probe is load-bearing for compacted records | only meaningful with a sized-read API; low value until reads matter |
| 19 | `applySettings` deep-clones the whole state per settings entry | control-plane frequency; ownership-safe shallow-clone needs a deinit contract change | low priority — revisit with the ownership work in #15 |
| 20 | sim `viewsFor` allocates per leader evaluation | callers consume immediately, but a scratch buffer needs a documented borrow discipline | easy once #11 is in; not yet needed |
| 21 | heartbeat body allocated per member per interval | tiny constant, most frequent message | skip unless profiling shows it |
| 22 | sim `processInbox` rescans from 0 per applied message | the rescan is load-bearing (chainability + epoch drops) | careful cursor work; inboxes are small today |

## Findings — environment (this machine, 2026-08-29)

- **The gate is flaky under `zig build test`:** the process-level `status`
  test (via `waitStatus`) intermittently cannot reach the serve within its
  30 s poll; direct runs of the same binary pass. Runs 1, 2, 3, 5 failed;
  run 4 was green. The serve children's stderr is `.ignore`
  (`main.zig:922-927`), so a serve crash would be invisible — the leading
  suspect is startup delay under fsync-heavy concurrent load (every e2e
  append pays 3 barriers under `.every`), which RFC 0003 directly addresses.
  Not confirmed; a serve-side stderr capture is the next diagnostic.
- **OQ 62 reproduced once:** a lib_tests binary spun at 112% CPU for 9+
  minutes after a failed `zig build test` run (run 2). No stack was
  captured. The report's prior evidence (~20 clean direct runs) stands; the
  gate-run reproduction is new.
- **lib_tests is ~3.5 min here vs ~30 s on the 2026-08-28 machine** — the
  e2e cluster tests dominate; the fixed wall-clock waits are unchanged, so
  the delta is the polls converging at this machine's speed.

## References

- Per-topic reports:
  [settings and checkpoint](2026-08-29-runtime-sweep-settings-checkpoint.md),
  [journal read](2026-08-29-runtime-sweep-journal-read.md),
  [queue and wire](2026-08-29-runtime-sweep-queue-wire.md),
  [sim and micro](2026-08-29-runtime-sweep-sim-micro.md)
- [RFC 0003 — what does `storage.fsync` govern?](../../rfcs/0003-append-durability-fsync-policy.md)
- [OQ 62 — the cluster e2e CPU spin](../../open-questions.md)
- Prior art: [2026-08-28 — making `zig build test` faster without dropping tests](2026-08-28-test-suite-quick-wins.md)
