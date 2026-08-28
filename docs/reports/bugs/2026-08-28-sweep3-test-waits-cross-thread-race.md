# Bug — 8695ee1's new test waits read node-loop state from the test thread without synchronization (data race)

## TL;DR

- **What failed:** The settle-sleep → wait conversion (commit `8695ee1`) polls `cn.syncing` (a plain bool) and `b/c.node.control.settings` (a fold map) from the test thread while the node loops run on `std.testing.io` worker threads and write them — unsynchronized cross-thread reads.
- **Impact:** Formal data race (UB) in the test suite; the fold reads can observe a torn value during the settings clone-swap. Intermittent failures or, in the worst case, a test-thread crash.
- **Resolution:** Still open. Statically validated (corroborated by three independent reviews).

## Status

Open.

## Symptom and impact

The commit replaced fixed sleeps with polls at `node.zig:2907, 3167-3178, 3337, 3667, 3762, 3853`. The node loops run on the `std.testing.io` worker threads (`cn.start()` → `group.async`); the polls read `cn.syncing` and `node.control.settings.getEnum(...)` from the test thread while the loop folds broadcasts into the same `FoldState.settings` (`values: []Value`). `getEnum` returns an interior slice of the map — if `applySettings`'s swap (`fold.zig:157-178`) replaces the value between the lookup and the use, the test thread reads stale/freed memory. Every earlier suite test reads folds only after `stop()` (verified pre-8695ee1); these are the first cross-thread fold reads.

## Reproduction

Not deterministically reproduced (timing-dependent — a settings broadcast landing exactly while the poll reads); the pattern is textually certain.

## Root cause

The waits observe loop-owned state without the synchronization every other observation uses (post-`stop()` reads, or the wire protocol).

## Resolution

Not yet fixed. Suggested direction: observe via the wire (`client.hello()`/`status`) or via a fold hash captured after synchronization, or add an explicit sync point (a completion the loop posts when the entry folds). A regression check is the suite under ThreadSanitizer.

## Verification

- Static: the poll sites and the fold-mutation paths read; the "only post-stop reads elsewhere" claim verified against the pre-8695ee1 tree.

## Follow-up

The same commit's waits also depend on the joiner-syncing path (2026-08-28-sweep3-joiner-syncing-race): `!syncing` would pass instantly on the broken path, masking the production race.

## References

- Code: `src/cluster/node.zig:2907, 3167-3178, 3337, 3667, 3762, 3853` (waits), `src/settings/fold.zig:157-178` (swap commit)
- Fix: none
