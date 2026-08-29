# Bug - `SettingsState.clone` leaks already-cloned values when a later clone fails

## TL;DR

- **What failed:** `SettingsState.clone` (schema.zig) freed only the outer
  `values` array on error; a mid-loop clone failure (OOM on a `string_list`
  dupe) left the values cloned so far owned by nothing.
- **Impact:** Bounded memory leak on the replicated fold path - the fold
  clones the whole settings state on every settings entry and genesis
  (`applySettings`, `applyGenesis`), and an allocator failure part-way
  through a clone leaks the partial state on every retried entry.
- **Resolution:** Resolved - an errdefer now deinits the already-cloned
  values before the array free runs.

## Status

Resolved.

## Symptom and impact

`SettingsState.clone` (src/settings/schema.zig):

```zig
const values = try self.allocator.alloc(Value, key_count);
errdefer self.allocator.free(values);
for (0..key_count) |i| {
    values[i] = try self.values[i].clone(self.allocator);
}
```

If `values[i].clone` fails at `i = k > 0`, the clones at `values[0..k]` are
never deinit'ed - `Value.clone`'s own errdefer frees only its own partial
work for the failing value. The codebase already fixed the sibling defect in
`decodeValue` (bug 2026-08-29-decode-value-string-list-leak) with the same
careful errdefer; `clone` was missed.

## Reproduction

Not dynamically reproduced; statically certain. A `FailingAllocator` whose
failure lands in a `string_list` dupe after an earlier value was cloned
leaks under the GPA leak check.

## Root cause

The errdefer frees the array but not its contents: `Value` owns its
`string_list` slices, and the loop hands each successfully cloned value to
the array before the next clone can fail.

## Resolution

Fixed: the loop tracks `cloned`, and a second errdefer deinits
`values[0..cloned]` before the array free runs (errdefers run in reverse
order).

## Verification

- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: src/settings/schema.zig (`SettingsState.clone`)
- Fix: this report's resolving commit
