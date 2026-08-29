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

Resolved as defensive hardening; OQ 62 remains open pending a root-cause
repro.

## Trigger and scope

OQ 62 ("what makes the cluster e2e spin a core for minutes, intermittently")
recorded its first captured stack on 2026-08-29: an io worker in
`Store.rebuildIndex`'s `jd.index.put` (the position->IndexEntry map) during
`compact` on the G4 e2e test. The `std.hash_map` probe loop is bounded by
table capacity, so a minutes-long `put` implies an overfull table - each
probe walking the whole capacity. This pass evaluates the one cheap
hardening that removes a plausible mechanism without changing semantics.

## Evidence

All observations are reads of the tree at `main` @ `527068e`, verified
before implementation.

1. **`rebuildIndex` reuses the map across rebuilds.** `store.zig:654-669`
   calls `jd.index.clearRetainingCapacity()` then re-puts every record.
   `clearRetainingCapacity` keeps the backing table and resets
   `available`, so a single rebuild is fine; the captured spin is consistent
   with the accounting drifting across many clear+refill cycles (compaction
   rebuilds the index on every checkpoint). The exact drift mechanism is
   unconfirmed (the OQ 62 entry records the evidence and the open
   questions).
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
index's reads. The OQ 62 entry is updated with this hardening's rationale.

## References

- Code: `src/journal/store.zig` (`rebuildIndex`, `compact`, `truncate`)
- [OQ 62 - the cluster e2e CPU spin](../../open-questions.md)
- Sweep: [2026-08-29 runtime speedup sweep findings](2026-08-29-runtime-sweep-findings.md)
