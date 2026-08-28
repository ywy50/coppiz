# Investigation — range reads and open-time discovery on the journal read paths

## TL;DR

- **Question:** what does a range read and a store open pay that scales with
  the whole journal, not with the read's window?
- **Finding:** every `readRange` call sorted the fold's entire entries map
  (O(n log n) comparisons, O(n) allocation) and issued two positional file
  reads per delivered record; the open-time control-journal discovery
  scanned every journal in full to learn what its first record was.
- **Resolution:** implemented — `readRange` now walks the store in chain
  order (`scanFrom`: one region read per segment, windowed, early-stop at
  `to`), sampling `now` once per call so one range read is one consistent
  snapshot; discovery reads only each journal's first record
  (`Store.firstRecordKind`).

## Status

Resolved and implemented (PR `perf/runtime-sweep/2-journal-read`).

## Trigger and scope

A runtime-speedup sweep over `src/` (2026-08-29) flagged the journal read
path: `readRange` is the general read hot path (`coppiz read`, `follow`'s
init backfill, the wire read server), and the open fold (`foldAll`) runs on
every `Node.open` and every merge `refold`.

## Evidence

All observations are reads of the tree at `main` @ `ec18643`, verified
before implementation.

1. **`readRange` sorted the whole entries map per call.**
   `journal.zig:771-781` built `sortedEntryIds` (`journal.zig:807-823`): one
   allocation of every entry id, then an O(n log n) sort whose comparator
   does two map lookups per comparison — for a 10-record window from a
   million-entry journal. Then `readRecord` (`journal.zig:792-805`)
   allocated a fresh buffer per record and `store.read` (`store.zig:299-319`)
   did **two** positional reads per record (8-byte prefix, then the body).
   A 10-record read was O(n log n) CPU plus 2 syscalls per record; the
   prefix probe is load-bearing for compacted records (the caller's fold
   size is the *original* payload length, which over-sizes the buffer), so
   it cannot be dropped without a format change, but the per-record read
   disappears entirely when the range walks the store's decoded regions.
2. **`foldAll` scanned every journal in full for discovery.**
   `journal.zig:637-651` ran `store.scan` — which reads every segment region
   and decodes every record (`store.zig:324-341`) — over each journal just
   to learn whether its first record is a genesis, then `foldJournal`
   scanned the control journal and every data journal again. Open cost was
   ~2 full chain reads per journal, all to classify the first record.

## Hypotheses and tests

- **Hypothesis A — a windowed read can walk the store instead of sorting
  the fold.** `scanFrom` (`store.zig:347-370`) iterates records in chain
  order from an indexed cursor, delivering the same `(slot, entry)` pair the
  old path decoded per record; the fold's entries map supplies the
  visibility facts per id. *Result:* supported. The fold filter is
  preserved: a slot-only record (entry `null`) is a removed entry and is
  invisible under every flag (`expiry.isVisible` returns false on `removed`),
  so skipping it matches the old output exactly.
- **Hypothesis B — discovery needs only the first record.** A genesis is
  always a journal's first record (enforced by `checkChainContinuity` and
  `applyGenesis`'s head-refusal). *Result:* supported — a
  `Store.firstRecordKind` that reads the first segment's first record
  replaces the full scan.

## Finding

The read and open paths paid whole-journal costs for windowed or
first-record questions. Both fixes are same-semantics refactors; the only
observable difference is deliberate — a range read now samples `now` once
and applies one visibility snapshot to the whole range instead of re-reading
the clock per record (the old behavior could flip visibility mid-range).

## Resolution or handoff

- `readRange` (`journal.zig:756-811`) walks `store.scanFrom` with a position
  window, early-stop past `to`, a single `now` sample, and the same
  `visible()` fold filter per record. `sortedEntryIds` deleted (no remaining
  callers).
- `Store.firstRecordKind` (`store.zig:373-395`) reads the first record of
  the first segment (2 small positional reads, no region read); `foldAll`
  discovery uses it. `readById`'s `readRecord` path is unchanged.

Verification: `zig build test` on this machine — 261/261 pass, exit 0
(lib_tests 170, exe_tests 13, build_tests 75, examples 3). No gate-duration
change expected: the read path is exercised by the suite but the gate's
wall clock is the cluster e2e waits (measured 2026-08-28).

## References

- Code: `src/journal/journal.zig` (`readRange`, `readById`, `foldAll`),
  `src/journal/store.zig` (`scan`, `scanFrom`, `firstRecordKind`, `read`)
- Follow-up: `store.read`'s per-record prefix probe is format-bound; a
  sized single read would need a format or API change (see the RFC
  companion report).
- Prior art: [2026-08-28 — making `zig build test` faster without dropping tests](2026-08-28-test-suite-quick-wins.md)
