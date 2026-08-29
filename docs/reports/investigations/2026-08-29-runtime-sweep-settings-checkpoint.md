# Investigation - settings key resolution and checkpoint removal sets on the control paths

## TL;DR

- **Question:** what does the settings/checkpoint machinery redo on every tick,
  every append, and every checkpoint, and which of it is comptime-known?
- **Finding:** the settings key table is comptime-known, yet `schema.keyIndex`
  re-ran a linear string scan on the runtime hot paths (per tick, per append,
  per checkpoint), and every checkpoint materialized the journal's *entire*
  entries table 1–3× to compute a removal set that is guaranteed empty under
  the default configuration (`ttl.enforce = off`, `stale.cleanup = keep`).
- **Resolution:** implemented - `keyIndex` now resolves at comptime for every
  literal call site (a runtime variant serves the three user-input lookups),
  `encodeCanonical` no longer allocates a scratch buffer per key, and a
  `canRemoveAnything` guard skips the O(entries) candidates pass when no
  removal is possible.

## Status

Resolved and implemented (PR `perf/runtime-sweep/1-settings-checkpoint`).

## Trigger and scope

A runtime-speedup sweep over `src/` (2026-08-29) flagged three waste sites on
the control-plane hot paths. The suite's wall clock is e2e waits (measured
2026-08-28), so none of these change the gate's duration; they cut the
per-tick and per-checkpoint CPU that scales with cluster size and journal
size.

## Evidence

All observations are reads of the tree at `main` @ `ec18643`, verified
against the code before implementation.

1. **`schema.keyIndex` is a runtime linear scan of a comptime table.**
   `schema.zig:343-348` iterates `keys` (25 entries, ~20-byte names) with
   `std.mem.eql` on every call. Runtime call sites with real frequency:
   - per node tick: `onTick` ×3 (`node.zig:839-841`), `updateTick` ×2
     (`node.zig:1217-1218`), `driveCheckpoints` up to ×4 per journal
     (`node.zig:1021-1029`), `electionInputs` ×4 (`node.zig:2556-2562`);
     tick period is `min(heartbeat, suspect)/4` (`node.zig:1216-1222`);
   - per append: `journal.max_entry_bytes` (`node.zig:1474`,
     `journal.zig:238`);
   - per checkpoint fold: `chain.zig:670, 704`; per settings entry:
     `validate.zig:75-88`.
   The repo already used the comptime-const pattern at the worst offenders
   (`expiry.zig:35-39`, `validate.zig:38`), confirming the intent.

2. **`encodeCanonical` allocates a scratch buffer per key.**
   `schema.zig:560-574` allocates `valueLen(value)` bytes, encodes, appends,
   frees - 25 alloc/free pairs per call. Called from `SettingsState.hash`,
   which runs per store-reopen hash compare and per fold hash
   (`chain.zig:761`).

3. **Checkpoint removal sets materialize the whole entries table, even when
   the set is provably empty.** `applyCheckpoint` (`chain.zig:707-716`) and
   `removalIds` (`journal.zig:428-447`) each call `expiryCandidates`
   (`chain.zig:729-750`), which allocates and copies one `SlottedEntry` per
   journal entry, then `expiry.removalSet`. With the default settings the
   set can never match anything: `removalSet` only removes TTL-expired
   entries (impossible when `ttl.enforce = off` - `expiry.effectiveTtl`
   returns null, `expiry.zig:43-45`) or stale entries under
   `stale.cleanup = delete` (the default is `keep`).

   The leader computes the
   set up to 3× per checkpoint per journal (`checkpointRemovalSet` for the
   G7/pending-bytes gate, `applyCheckpoint` in the fold, `removalIds` for
   compaction), each a full-table allocation on every member.

## Hypotheses and tests

- **Hypothesis A - key resolution can be comptime.** The `keys` table is
  `comptime`, and every hot call site passes a string literal; only three
  sites pass user input (`config/local.zig:161, 226`; `main.zig:678`).
  *Result:* supported. `keyIndex(comptime name)` with `inline for` resolves
  at comptime; the three input sites use a new `keyIndexRuntime`.
- **Hypothesis B - the removal set is computable without the candidates
  pass under the defaults.** `removalSet`'s only removal predicates are TTL
  expiry and `stale.cleanup = delete`. *Result:* supported - under
  `cleanup = keep` + `ttl.enforce = off` the set is always empty.

## Finding

The control paths redo comptime-known lookups and full-table materializations
whose outcome is determined by configuration. The fixes are pure
same-semantics refactors: byte-identical settings hashing, the same key
indices at the same call sites, and an identical (empty) removal set.

## Resolution or handoff

- `schema.keyIndex` takes `comptime name` and uses `inline for`, so all
  literal call sites resolve to constants at compile time; the runtime
  lookups moved to `schema.keyIndexRuntime`. `settingU64/U16/Enum` in
  `node.zig` mark their `name` parameter comptime (all callers pass
  literals).
- `encodeCanonical` encodes each value in place into the output buffer
  (`appendNTimes` reserve + tail write) - no scratch allocations.
- `expiry.canRemoveAnything` guards `applyCheckpoint` and `removalIds`:
  under `stale.cleanup = keep` with `ttl.enforce = off` the candidates pass
  is skipped and the empty set returned (a zero-length free is a no-op in
  `std.mem.Allocator.free`, so the existing callers' deinit paths are
  unchanged).

Verification: `zig build test` on this machine - 261/261 pass, exit 0
(lib_tests 170, exe_tests 13, build_tests 75, examples 3). Gate duration
unchanged (~3.5 min on this machine, dominated by e2e waits as measured on
2026-08-28; the removed work is per-tick/per-checkpoint CPU, not wall-clock
waits).

## References

- Code: `src/settings/schema.zig`, `src/settings/fold.zig`,
  `src/settings/validate.zig`, `src/journal/expiry.zig`,
  `src/journal/chain.zig`, `src/journal/journal.zig`,
  `src/cluster/node.zig`, `src/config/local.zig`, `src/main.zig`
- Prior art: [2026-08-28 - making `zig build test` faster without dropping tests](2026-08-28-test-suite-quick-wins.md)
