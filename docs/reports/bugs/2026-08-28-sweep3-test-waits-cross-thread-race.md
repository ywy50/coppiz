# Bug - 8695ee1's new test waits read node-loop state from the test thread without synchronization (data race)

## TL;DR

- **What failed:** The settle-sleep → wait conversion (commit `8695ee1`) polls `cn.syncing` (a plain bool) and `b/c.node.control.settings` (a fold map) from the test thread while the node loops run on `std.testing.io` worker threads and write them - unsynchronized cross-thread reads.
- **Impact:** Formal data race (UB) in the test suite; the fold reads can observe a torn value during the settings clone-swap. Intermittent failures or, in the worst case, a test-thread crash.
- **Resolution:** **Partly resolved 2026-08-31, after a false resolution on 2026-08-29.** The 2026-08-29 record claimed a fix no commit contained: `syncing` was still a plain `bool`. It is now `std.atomic.Value(bool)`, which closes five of the six poll sites. The sixth - the settings-landing poll - is still a race, and its fix is outside this change's territory. One mechanism claim in this record was also wrong; see *Reopened - what was checked*.

## Status

Partly resolved 2026-08-31, after a false resolution on 2026-08-29. The
settings-landing poll remains open.

Reopened and half-fixed in the same change. `8893ae1`
("docs(reports): mark the sweep fixes resolved (#116)") flipped this record
to `Resolved` in a commit that touched 29 report files and no source file;
the record's own TL;DR still read "Still open" and its References still read
`Fix: none`. See *Reopened - what was checked* for the evidence, including a
correction to this record's own reasoning.

## Symptom and impact

The commit replaced fixed sleeps with polls at `node.zig:2907, 3167-3178, 3337, 3667, 3762, 3853`. The node loops run on the `std.testing.io` worker threads (`cn.start()` → `group.async`); the polls read `cn.syncing` and `node.control.settings.getEnum(...)` from the test thread while the loop folds broadcasts into the same `FoldState.settings` (`values: []Value`). `getEnum` returns an interior slice of the map - if `applySettings`'s swap (`fold.zig:157-178`) replaces the value between the lookup and the use, the test thread reads stale/freed memory. Every earlier suite test reads folds only after `stop()` (verified pre-8695ee1); these are the first cross-thread fold reads.

## Reproduction

Not reproduced, then or now, and not reproducible with anything in the tree:
demonstrating a data race needs a thread sanitizer, and there is none wired
into the build. The pattern is textually certain - the write sites and the
read sites are enumerable and were enumerated - but no test asserts either
the defect or the fix, and none is claimed. That is the honest limit of this
record.

## Root cause

The waits observe loop-owned state without the synchronization every other observation uses (post-`stop()` reads, or the wire protocol).

## Reopened - what was checked

Checked at `34404d5` (2026-08-31), by reading and by search:

- `syncing` was declared `syncing: bool = false` in `src/cluster/node.zig` -
  a plain `bool`, exactly as reported. The five test waits still read
  `cn.syncing` / `b.cn.syncing` from the test thread.
- The settings-landing poll still read
  `b.node.control.settings.getEnum(mode_key)` directly from the test thread.
  `grep -rn local_read src/cluster/node.zig` shows the mailbox event and
  `localReadRange`; nothing reads settings through the loop, and no such API
  exists.

**A correction to this record's own reasoning.** The report said `getEnum`
"returns an interior slice of the map", so the test thread could read
"stale/freed memory" through the returned string. That is not so: an enum is
stored as a `u16` index (`schema.Value.enum_value`) and `getEnum` resolves it
through `enumName`, which returns a **comptime schema string**. The returned
slice is never allocated and never freed.

The race is nonetheless real, and by a different route that is no better:
`applySettings` commits with `std.mem.swap(SettingsState, state, &candidate)`
and its `defer candidate.deinit()` then frees what used to be `state`'s
`values` array. So a concurrent `self.values[key_index]` read - the load
inside `getEnum`, before any string lookup - can dereference a freed array.
The conclusion stands; the sentence naming the interior slice does not, and
is corrected here rather than left to mislead the next reader.

## Resolution (as recorded 2026-08-29 - not implemented)

Fixed: `syncing` is an atomic and the settings-landing poll observes through the loop's own `local_read`, removing the test-thread data races.

## Resolution

**`syncing`: fixed 2026-08-31.** It is `std.atomic.Value(bool)`, read and
written through `isSyncing`/`setSyncing` with `monotonic` ordering - the node
loop is the only writer and nothing is ordered against the flag, so nothing
stronger buys anything. All 28 call sites moved, the five test waits
included. That closes the five `cn.syncing` poll sites the report lists.

**The settings-landing poll: still open.** Neither available fix belongs in
`src/cluster/`:

- Make the commit not free an array a reader may hold: assign the validated
  candidate's values element-wise into the existing array instead of swapping
  the whole `SettingsState`. Each assignment is a union store that cannot
  fail, so the partial-commit property the swap exists for
  (2026-08-28-settings-apply-partial-commit) is kept. This lives in
  `src/settings/fold.zig`.
- Or give the loop the observation: a settings read on the mailbox, so the
  predicate is evaluated on the thread that owns the fold. That is new public
  API on the embedded surface (PRD 0005) and a decision rather than a repair -
  whether reading a cluster setting belongs in the host API at all.

The second is the one this record's original Resolution described. Whoever
takes it should decide between the two rather than assume; the first is
strictly smaller and fixes every reader, not only this test's.

## Verification

- Static, original: the poll sites and the fold-mutation paths read; the
  "only post-stop reads elsewhere" claim verified against the pre-8695ee1
  tree.
- Static, 2026-08-31: the search and re-read recorded under *Reopened*,
  including the `getEnum` correction (`schema.zig` - `Value.enum_value`,
  `getEnum`, `enumName`) and the swap-and-free (`fold.zig` -
  `applySettings`).
- Dynamic: none, and none possible here - see *Reproduction*. The atomic
  change is covered only by the suite continuing to pass
  (`Build Summary: 25/25 steps succeeded; 379/379 tests passed`), which
  proves it did not break the waits, not that it removed a race.

## Follow-up

The same commit's waits also depend on the joiner-syncing path (2026-08-28-sweep3-joiner-syncing-race): `!syncing` would pass instantly on the broken path, masking the production race.

## References

- Code (line numbers as of the original report): `src/cluster/node.zig:2907, 3167-3178, 3337, 3667, 3762, 3853` (waits), `src/settings/fold.zig:157-178` (swap commit)
- Code (current): `src/cluster/node.zig` - `syncing`, `isSyncing`, `setSyncing`; `src/settings/fold.zig` - `applySettings` (the swap); `src/settings/schema.zig` - `Value.enum_value`, `getEnum`
- False resolution: `8893ae1` (docs-only, 29 report files, no source change)
- Fix: this change, for the `syncing` half only
