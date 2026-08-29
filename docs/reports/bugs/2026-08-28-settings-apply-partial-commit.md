# Bug - `applySettings` can commit part of a settings entry before failing: the replicated fold diverges on OOM

## TL;DR

- **What failed:** The settings fold's documented atomicity ("On refusal, the fold is untouched") holds for *validation*, but the commit loop re-applies each change to the state via `set`, which clones and can fail on OOM mid-loop. A two-change entry that OOMs on its second `set` is refused *and* half-applied.
- **Impact:** One member's settings state diverges from every other member's; all subsequent folds differ. For a replicated deterministic fold, that is the worst failure mode.
- **Resolution:** Still open. Statically validated.

## Status

Resolved - the commit is a swap of the validated candidate, not a
per-change re-apply; regression test fails the second change's clone and
asserts the state is unchanged. A pre-existing leak in `Value.clone`'s
partial-failure path surfaced under the same test and was fixed too.

## Symptom and impact

The fold contract is stated in the module docs (`fold.zig:9-10`) and at `chain.zig:286-288`: "On refusal, the fold is untouched." Validation runs on a candidate clone, but the commit (`fold.zig:161-163`) applies changes one at a time with `state.set`, which deep-clones the value and can fail. If change 1 commits and change 2's clone fails, `applySettings` returns an error (the entry is refused) yet the state holds change 1 - a partially-applied settings entry. Because every member runs the same fold on the same chain, a member that OOM'd at the same point diverges from members that didn't (or that OOM'd at a different point).

## Reproduction

Not dynamically reproduced (needs an injected allocation failure between two changes of one settings entry - e.g. a `ttl.default_ms` change followed by a large `leadership.authorities` list whose clone fails). Statically certain: the only failing point in the commit loop is `set`'s clone (`schema.zig:540-544`), and there is no rollback.

## Root cause

The candidate-clone validates the entry as a whole, but the commit re-applies changes one by one with a mutating API (`set`) that can fail mid-way. Atomicity needs either (a) a transactional apply (validate-and-commit against a working copy, then swap), or (b) a rollback of already-applied changes on failure.

## Resolution

Fixed. `applySettings` (and `applyGenesis`, which had the same
re-apply shape) now deinit the old state and swap the validated
candidate in with `state.* = candidate` - the commit is infallible, so
an OOM can no longer leave the fold half-applied. The candidate clone
still isolates every failing point (clone, `set`, `validateState`).

Regression test ("applySettings commit is atomic: an OOM on the second
change leaves the state untouched"): a `ttl.default_ms` change followed
by an authority-list change, applied under one-failing-allocation-at-a-
time; every failure must leave the state byte-identical (hash-compared),
and the success case applies both changes. Verified to fail against the
old re-apply loop (the state hash diverged after the injected OOM).
The same sweep exposed a leak in `schema.Value.clone`'s string_list
partial-failure path (a failed `dupe` mid-loop leaked the earlier
items) - fixed with an errdefer over the filled prefix.

## Verification

- Static: `fold.zig:143-163` (candidate clone, validate, commit loop); `schema.zig:540-544` (`set` clone); no rollback on the commit path. Verified by reading the code.

## Follow-up

None. Note the same replicated-fold path carries the u16 codec overflow (reported separately).

## References

- Code: `src/settings/fold.zig:143-163` (`applySettings`), `src/settings/schema.zig:540-544` (`SettingsState.set` clone)
- Fix: `src/settings/fold.zig` (`applySettings`, `applyGenesis`), `src/settings/schema.zig` (`Value.clone` leak); regression test in `fold.zig`. `zig build test` green.
