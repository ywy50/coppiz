# Investigation - OQ 62 defensive hardening: the rebuilt index's fresh map

## TL;DR

- **Question:** can the compaction index rebuild be made robust against the
  state-carrying path behind OQ 62's captured spin, without changing
  behavior?
- **Finding:** `rebuildIndex` reused the journal's position map across
  rebuilds via `clearRetainingCapacity`; the captured OQ 62 stack showed a
  put probing at O(capacity) inside that rebuild - consistent with the
  map's `available` accounting drifting across clear+refill cycles. A fresh
  map per rebuild removes the state-carrying path entirely, at the cost of
  one map allocation per compaction.
- **Resolution:** implemented - `rebuildIndex` deinitializes and
  re-initializes the index map instead of clearing it in place. Same
  contents, same lookups; explicitly defensive, not a claimed root-cause
  fix (the OQ 62 mechanism is still open).

## Status

Resolved as defensive hardening; the CPU-spin question it addresses (OQ 62,
historical) remains open pending a root-cause repro.

## Trigger and scope

OQ 62 ("what makes the cluster e2e spin a core for minutes, intermittently")
recorded its first captured stack on 2026-08-29: an io worker in
`Store.rebuildIndex`'s `jd.index.put` (the position->IndexEntry map) during
`compact` on the G4 e2e test. The `std.hash_map` probe loop is bounded by
table capacity, so a minutes-long `put` implies an overfull table - each
probe walking the whole capacity. This pass evaluates the one cheap
hardening that removes a plausible mechanism without changing semantics.

## Observations timeline

The register entry that this report supersedes recorded the full history;
it is preserved here so the report stands alone.

1. **Original observations (3/3, direct runs).** Running a test binary
   directly (not through `zig build test`'s protocol) stuck three times at
   ~100% CPU for 10+ minutes in three io worker threads - twice at
   `e2e (G4)` (node.zig:3118) and once at the journal member-key test -
   while the gate runs stayed green (3/3). The loop, mailbox and hub
   transport are all semaphore-based (no busy-poll found by reading; stacks
   could not be captured, ptrace blocked). If a node loop livelocks, the
   same path could burn a production core. Trigger: the investigation
   2026-08-28 (test-build speedup).
2. **No direct reproduction.** Two gdb-launched repro attempts ran the
   direct binary to completion without the spin; no reproduction in ~20
   direct runs since the pass-2 busy-spin removal (the 3/3 original was
   observed with the busy-spins still in) - consistent with that change
   having removed the trigger, but no root cause established. The 2026-08-29
   sweep reproduced it once inside a gate run (112% CPU, 9+ minutes; no
   stack) - the only gate-run reproduction to date.
3. **First stack captured (2026-08-29).** Reproduced twice in the same day
   under `zig build test` on a machine running the suite twice concurrently
   (an overlapping run duplicated the command): a lib_tests binary at
   112-146% CPU for 8-18 minutes at `e2e (G4)`. SIGABRT + systemd-coredump
   + gdb (no ptrace needed on the core) captured the spinning thread: an io
   worker in `Store.rebuildIndex` -> `jd.index.put` (the position->IndexEntry
   AutoHashMap) inside `Store.compact` <- `compactRemoved` <-
   `checkpointForBroadcast` <- `driveCheckpoints` <- `onTick` <- `loopMain`
   (the G4 TTL-trio leader, teardown in progress: main thread in
   `waitForStop`).
   
   `std.hash_map`'s probe loop is bounded by table capacity,
   so a long `put` means an overfull table (every probe walks the whole
   capacity) - the observed burn is consistent with the index map's
   `available` accounting going wrong under repeated
   `clearRetainingCapacity` + refill (compaction rebuilds the index on
   every checkpoint), degrading each insert to O(capacity). The
   compact/rebuildIndex path is unchanged by the 2026-08-29 speedup PRs;
   the original 3/3 observations were also at G4.

   Next planned: a repro
   script that runs the G4 test under doubled load, then a bisect of
   `clearRetainingCapacity`/`available` accounting or a switch of the store
   index to `ensureTotalCapacity`-pre-sized rebuilds with an explicit
   assertion that `available` is never exhausted mid-rebuild.
4. **Second stack (2026-08-29).** An io worker in `checkpointForBroadcast`
   -> `Store.append` -> `fsync` reads as the G4 leader's normal checkpoint
   cadence under load, not a second spin mechanism. The repro + bisect
   above still stands as the way to close the question.
5. **Defensive hardening (this report).** `Store.rebuildIndex` now
   deinitializes and re-initializes the position map instead of
   `clearRetainingCapacity`-and-refill, eliminating the cross-rebuild
   state-carrying path the captured stack implicated. Hardening, not a
   claimed fix: the root cause is still unconfirmed.

## Evidence

All observations are reads of the tree at `main` @ `527068e`, verified
before implementation.

1. **`rebuildIndex` reuses the map across rebuilds.** `store.zig:654-669`
   calls `jd.index.clearRetainingCapacity()` then re-puts every record.
   `clearRetainingCapacity` keeps the backing table and resets
   `available`, so a single rebuild is fine; the captured spin is consistent
   with the accounting drifting across many clear+refill cycles (compaction
   rebuilds the index on every checkpoint). The exact drift mechanism is
   unconfirmed (the Observations timeline above records the evidence and
   the open questions).
2. **A fresh map starts from known-good state.** `jd.index.deinit()` +
   `init` discards whatever the previous rebuild's accounting left behind.
   The map is not read while `rebuildIndex` runs (single-threaded loop,
   called after the segment swap), so the swap is transparent to every
   lookup site (`store.read`, `scanFrom`, `readById`).

## Hypotheses and tests

- **Hypothesis A - the fresh map changes no behavior.** The rebuilt map has
  the same entries as the cleared-and-refilled one (same puts over the same
  records). *Result:* supported by reading; the compaction/truncate tests
  exercise the rebuilt index's lookups.
- **Hypothesis B - the fresh map removes the state-carrying path.** It does
  - whether that path is OQ 62's actual cause is unconfirmed. *Result:*
  defensive only; the OQ 62 repro (the G4 spin under the runner) has not
  been reproduced deterministically on this machine since the 2026-08-29
  observations.

## Finding

The rebuild path's only cross-rebuild mutable state is the index map itself.
Recreating it is a zero-semantics-change hardening that eliminates a
plausible mechanism for the captured OQ 62 spin, at a cost (one map
allocation per compaction) dwarfed by the segment rewrites that surround it.

## Resolution or handoff

- `rebuildIndex` (`store.zig:654-671`) deinitializes and re-initializes
  `jd.index` instead of `clearRetainingCapacity`.

Verification: `zig build` and `zig build lint` clean; the compaction and
truncate tests (including G4's both-retain-values e2e) exercise the rebuilt
index's reads.

## References

- Code: `src/journal/store.zig` (`rebuildIndex`, `compact`, `truncate`)
- Sweep: [2026-08-29 runtime speedup sweep findings](2026-08-29-runtime-sweep-findings.md)
