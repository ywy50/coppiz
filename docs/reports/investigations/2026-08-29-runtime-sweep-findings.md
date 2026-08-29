# Investigation - runtime speedup sweep: findings and disposition

## TL;DR

- **Question:** where does the coppiz runtime spend CPU and I/O that it does
  not need to, without changing behavior?
- **Finding:** a sweep of `src/` found 18 concrete waste sites. Eight are
  pure same-semantics refactors and are implemented across four stacked PRs
  (this report links each to its investigation report); the rest are
  durability, format, or contract trade-offs that need an RFC or a reviewer -
  led by the append fsync discipline ([RFC 0003](../../rfcs/0003-append-durability-fsync-policy.md)).
- **Resolution:** four implementation PRs, one RFC PR, plus this record of
  the full sweep.

## Status

Resolved for the implemented subset; the deferred items are tracked below
with their required next step. Environment findings (flaky gate, OQ 62
spin) are recorded - not closed.

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

## Findings - implemented (same semantics, verified green)

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

## Findings - deferred, with required next step

| # | Site | Why deferred | Next step |
|---|---|---|---|
| 13 | append pays 3 fsyncs; queue ignores `storage.fsync`; `clear` barrier redundant | durability trade-off | Implemented 2026-08-29 - [ADR 0008](../../adrs/0008-storage-fsync-governs-the-queue.md) (RFC 0003 Option A): the queue honors the knob, `remove`/`clear` never sync; barriers 3/2/2 → 2/1/0 (strace-verified) |
| 14 | `Queue.remove` rewrites the whole file per trim (O(k²) I/O on a burst) | on-disk format change (tombstone/watermark/batched drain) | [RFC 0004](../../rfcs/0004-queue-drain-shape.md), evidence in [the burst-I/O investigation](2026-08-29-queue-drain-burst-io.md) (measured 1/15/168 ms for 10/100/500 queued); recommends the batched drain (no format change) |
| 15 | per-frame decode dupes every variable-length part | the owning-decoder contract is a documented invariant (`message.zig:6-8`) with tests | [RFC 0005](../../rfcs/0005-decode-ownership.md) opened 2026-08-29 - recommends zero-copy records (owned scalars); the copy-cost benchmark is its pre-implementation gate |
| 16 | leader re-encodes for broadcast what it wrote to store | touches every broadcast call site; the follower-side win (#7) landed first | Implemented 2026-08-29 - the leader encodes once and shares the bytes between the store write and the broadcast ([investigation](2026-08-29-leader-encode-once.md)); the checkpoint/merge broadcast sites are noted as follow-ups |
| 17 | leader verifies its own just-written entry + slot (2 Ed25519 verifies/append) | changes where validation happens | The redundant-`entryHash` half was evaluated and **rejected** 2026-08-29: the fold's local recompute is the integrity gate (the slot-attested `entry_hash` is never cross-validated against the entry, so storing it would weaken divergence detection). The self-verify skip stays a reviewer decision. |
| 18 | `store.read` two positional reads per record (`readById`) | the prefix probe is load-bearing for compacted records | only meaningful with a sized-read API; low value until reads matter |
| 19 | `applySettings` deep-clones the whole state per settings entry | control-plane frequency; ownership-safe shallow-clone needs a deinit contract change | low priority - revisit with the ownership work in #15 |
| 20 | sim `viewsFor` allocates per leader evaluation | callers consume immediately, but a scratch buffer needs a documented borrow discipline | Evaluated and **rejected** 2026-08-29: a retained-slice footgun outweighs one small allocation per tick ([investigation](2026-08-29-steady-state-allocations.md)) |
| 21 | heartbeat body allocated per member per interval | tiny constant, most frequent message | Implemented 2026-08-29 - the fixed-size body is built on the stack ([investigation](2026-08-29-steady-state-allocations.md)) |
| 22 | sim `processInbox` rescans from 0 per applied message | the rescan is load-bearing (chainability + epoch drops) | careful cursor work; inboxes are small today |

## Findings - environment (this machine, 2026-08-29)

- **The gate is flaky under `zig build test`:** the process-level `status`
  test (via `waitStatus`) intermittently cannot reach the serve within its
  30 s poll; direct runs of the same binary pass. Runs 1, 2, 3, 5 failed;
  run 4 was green. The serve children's stderr is now captured to a
  per-spawn log and dumped on a wait timeout (the 2026-08-29 follow-up
  stack), so a serve crash is no longer invisible; the fsync-contention
  suspect was directly addressed by implementing RFC 0003 (item 13 above) -
  every e2e append now pays 2 barriers under `.every` instead of 3. Still
  not reproduced on the follow-up machine; the next occurrence should carry
  the serve logs.
- **OQ 62 reproduced once:** a lib_tests binary spun at 112% CPU for 9+
  minutes after a failed `zig build test` run (run 2). No stack was
  captured. The report's prior evidence (~20 clean direct runs) stands; the
  gate-run reproduction is new.
- **lib_tests is ~3.5 min here vs ~30 s on the 2026-08-28 machine** - the
  e2e cluster tests dominate; the fixed wall-clock waits are unchanged, so
  the delta is the polls converging at this machine's speed.

## References

- Per-topic reports:
  [settings and checkpoint](2026-08-29-runtime-sweep-settings-checkpoint.md),
  [journal read](2026-08-29-runtime-sweep-journal-read.md),
  [queue and wire](2026-08-29-runtime-sweep-queue-wire.md),
  [sim and micro](2026-08-29-runtime-sweep-sim-micro.md)
- [RFC 0003 - what does `storage.fsync` govern?](../../rfcs/0003-append-durability-fsync-policy.md)
- [OQ 62 - the cluster e2e CPU spin](../../open-questions.md)
- Prior art: [2026-08-28 - making `zig build test` faster without dropping tests](2026-08-28-test-suite-quick-wins.md)
