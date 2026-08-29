# Bug - a refused `Store.open` leaks the journal state it had already built

## TL;DR

- **What failed:** `loadJournal` fills a `JournalDir` in place - index map,
  segment list, one descriptor per adopted segment - but its only cleanup
  was `destroy(jd)`. Every refusal on that path lost all three.
  `Store.open`'s own `errdefer` called `journals.deinit()`, which frees the
  map's table and not its values, so a journal already loaded was lost
  whole.
- **Impact:** each refused open leaks the index table, the segment-list
  backing, one file descriptor per already-loaded segment, and (for every
  journal loaded before the failing one) its directory handle and struct as
  well. The refusals are supported outcomes, not exotic ones: `Corrupt`
  (G3), `Truncated`, `UnsupportedVersion` (G5), `JournalIdMismatch`. A
  supervisor retrying `coppiz serve` against a damaged directory leaks a
  little more on every attempt.
- **Resolution:** fixed. `loadJournal` releases the `JournalDir` it built,
  and `open` shares `deinit`'s teardown instead of freeing the map alone.

## Status

Resolved - 2026-08-30. Found by reading; confirmed by
`std.testing.allocator`.

## Symptom and impact

```
error: 'journal.store.test.a refused open frees the journal state it had
already built' leaked 1 allocations:
  std/hash_map.zig:1477 in allocate
  …
  src/journal/store.zig:873 in loadJournal      // jd.index.put
```

The descriptors are not visible to the allocator's leak check but leak the
same way: `loadJournal` pushes each adopted segment's `std.Io.File` into
`jd.segments`, and nothing closed them on the way out.

## Reproduction

`a refused open frees the journal state it had already built` in
`src/journal/store.zig`: two journals, one of them with a byte flipped
inside its *second* record - late enough that the scan has indexed the
first record (so the index map is allocated), with a valid third record
after the break so the scan classifies it as mid-file corruption rather
than a torn tail.

- Expected: `error.Corrupt`, nothing leaked.
- Actual, before the fix: `error.Corrupt` and one leaked allocation.
  Confirmed by removing the two fix hunks and running `zig build test`
  (exit 1, `1 leaks`).

## Root cause

```zig
const jd = try self.allocator.create(JournalDir);
errdefer self.allocator.destroy(jd);
jd.* = .{ .dir = sub, .segments = .empty,
          .index = std.AutoHashMap(...).init(self.allocator), … };
```

`destroy(jd)` releases the struct and nothing it owns. `Store.deinit`
already knew the full teardown; the error path did not share it.

At the `open` level:

```zig
errdefer store.journals.deinit();
```

`AutoHashMap.deinit` frees the table, not the `*JournalDir` values.

## Resolution

`Store.deinit`'s loop becomes `destroyJournals`, and both `deinit` and
`open`'s `errdefer` call it - one teardown, so the two cannot drift again.

`loadJournal` gains an `errdefer` that closes the adopted segments and
frees the index and segment list. It deliberately does not close
`jd.dir`: that is the same handle as `sub`, whose own `errdefer` above
already owns it, and closing it here would be the double close this file
was fixed for elsewhere today.

## Verification

- The new test passes with the fix and reports `1 leaks` without it
  (`zig build test` exit 1), with the trace naming `jd.index.put` in
  `loadJournal`.
- Full gate `zig build test` exit 0 on the branch.
- Partly verified: the test pins the `loadJournal` half deterministically.
  The `open` half - an earlier journal lost whole - is reached only when
  the directory scan enumerates the healthy journal first, which the
  filesystem decides; the test creates two journals so it is exercised
  about half the time, and both halves are served by the same
  `destroyJournals`. The leaked descriptors are not observed by the
  allocator check either; that part is read, not measured.

## Follow-up

`compact` creates a segment file and adopts it into `new_segments` on the
next line: if that append fails with `OutOfMemory` the descriptor and the
new on-disk file are orphaned, because the shared `errdefer` only covers
the list's members. Not fixed here.

## References

- Investigation: none
- Code: `src/journal/store.zig` (`destroyJournals`, `deinit`, `open`,
  `loadJournal`)
- Related: [2026-08-30 - a segment header naming another journal closes the file twice](2026-08-30-journal-id-mismatch-double-close.md),
  whose follow-up named this defect;
  [2026-08-29 - three cluster allocations are owned by nobody when the step after them fails](2026-08-29-cluster-alloc-ownership-error-paths.md),
  the same ownership class in the cluster
