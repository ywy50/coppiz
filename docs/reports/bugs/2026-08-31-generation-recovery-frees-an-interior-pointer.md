# Bug - the generation recovery re-slices its name list, so `deinit` frees an interior pointer (open)

## TL;DR

- **What failed:** `loadJournal`'s crashed-compaction recovery narrows its
  name list with `names.items = names.items[winner_start..winner_end];`.
  `ArrayListUnmanaged.deinit` frees `allocatedSlice()`, which is
  `items.ptr[0..capacity]` - so once `winner_start > 0` the free is handed a
  pointer that is not the start of the allocation, with the original capacity
  as its length.
- **Impact:** heap corruption under a release allocator. The path is the one
  the recovery exists for: any open where a newer segment generation wins,
  i.e. after a crashed `compact` or `truncate`.
- **Resolution:** **open.** Verified by reading; no fix and no regression test
  in this change. See *Why this is open* for what a test needs.

## Status

Open. Found 2026-08-31 by reading, while working on the neighbouring error
paths. Not observed in a run.

## Symptom and impact

```
for (names.items[0..winner_start]) |n| self.allocator.free(n);
for (names.items[winner_end..]) |n| self.allocator.free(n);
names.items = names.items[winner_start..winner_end];
```

with, earlier in the function:

```
defer {
    for (names.items) |n| self.allocator.free(n);
    names.deinit(self.allocator);
}
```

The element frees are correct - the names outside the winning generation are
released, the ones inside are kept and later freed by the `defer`. The defect
is the third line: `names.capacity` is untouched while `names.items.ptr` moves
forward by `winner_start * @sizeOf([]u8)`, and `deinit` computes the freed
slice from both.

Checked against this toolchain's standard library:
`std.array_list.Aligned(T, null).deinit` calls
`gpa.free(self.allocatedSlice())`, and `allocatedSlice` returns
`self.items.ptr[0..self.capacity]`
(`lib/std/array_list.zig`, `deinit` at 623 and `allocatedSlice` at 1385 of the
copy Zig 0.16.0 ships).

`std.testing.allocator` does not catch it, which is why the existing recovery
test (*open recovers a crashed compaction: the newer generation wins*, where
`winner_start = 5`) passes: `DebugAllocator` resolves a pointer back to its
slot by page offset divided by size class, and the offset here stays inside
the same slot. Under the shipped binary's allocator
(`std.process.Init.gpa`) a free of an interior pointer is not recoverable.

Stated precisely, because the difference matters: the *consequence* is
inferred from the allocator contract, not observed. What is confirmed is the
mechanism - the pointer given to `free` is not the pointer `alloc` returned.

## Reproduction

Not reproduced. The path is exercised today by
`src/journal/store.zig`'s test *open recovers a crashed compaction: the newer
generation wins*, which reaches the re-slice with `winner_start = 5` and
passes, because the testing allocator tolerates it.

## Root cause

`ArrayListUnmanaged` has no "narrow from the front" operation, and assigning
a sub-slice to `items` silently desynchronises `items.ptr` from `capacity`,
which only `deinit` reads.

## Resolution

None yet. The fix is to keep the backing pointer where it is - shift the
winning names to the front and set `names.items.len`, or copy the winner out
and let the list free the whole allocation:

```
const kept = winner_end - winner_start;
std.mem.copyForwards([]u8, names.items[0..kept], names.items[winner_start..winner_end]);
names.items.len = kept;
```

## Why this is open

A regression test needs an allocator that refuses a `free` of a pointer it did
not hand out, since neither `std.testing.allocator` nor
`std.testing.FailingAllocator` checks that - the pointer is *freed*, just the
wrong one, so allocation accounting balances. A ~40-line tracking wrapper over
`std.mem.Allocator` would do it, and shipping the fix without it would leave
the next reader unable to tell the re-slice was ever wrong. Filed rather than
fixed on that basis.

## Follow-up

This is the only `.items = ` assignment in the tree: `grep -rn "\.items = " src/`
matches this line and nothing else, so no sibling instance needs the same fix.

## References

- Investigation: none
- Code: `src/journal/store.zig` (`loadJournal`, the generation recovery)
- Related: [2026-08-30-generation-recovery-partial-new](2026-08-30-generation-recovery-partial-new.md),
  [2026-08-29-compact-not-crash-atomic](2026-08-29-compact-not-crash-atomic.md)
