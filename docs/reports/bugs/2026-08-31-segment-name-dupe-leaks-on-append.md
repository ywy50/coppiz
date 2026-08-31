# Bug - a segment name leaks when the name list's growth fails

## TL;DR

- **What failed:** `loadJournal` collected segment file names with
  `try names.append(self.allocator, try self.allocator.dupe(u8, f.name))`.
  The dupe is an argument, so it is evaluated first; an `OutOfMemory` in the
  list's own growth left it owned by nobody, because the `defer` that frees
  the names walks `names.items` - which the failed append never joined.
- **Impact:** one leaked name per journal directory whose first
  capacity-growing append fails. `loadJournal` runs once per journal on every
  open, so a host retrying an open under memory pressure leaks once per
  journal per attempt.
- **Resolution:** fixed - the dupe is its own step with an `errdefer`.

## Status

Resolved 2026-08-31. Found by the failure-index sweep written for
[2026-08-31-journal-state-fold-leaks-before-the-put](2026-08-31-journal-state-fold-leaks-before-the-put.md),
which reported leaks at three low indices that the fold fix did not explain.

## Symptom and impact

```
var names = std.ArrayListUnmanaged([]u8).empty;
defer {
    for (names.items) |n| self.allocator.free(n);
    names.deinit(self.allocator);
}
...
try names.append(self.allocator, try self.allocator.dupe(u8, f.name));
```

Zig evaluates the argument before the call, so the order on the failing path
is: dupe succeeds, `append` fails growing the list, the function returns, and
the `defer` frees the names that are *in* the list. The one just duped is not.

This is the third instance of one shape in this tree - an owning allocation
evaluated as a call argument - after
[2026-08-31-create-journal-name-leaks-on-put-failure](2026-08-31-create-journal-name-leaks-on-put-failure.md)
and the pattern `membership.applyJoin` documents avoiding.

## Reproduction

`src/journal/journal.zig`, test *an open refused part-way through a journal's
fold owns nothing*: the same sweep as the companion bug. With the fold leak
fixed and this one not, it reports `LEAK at fail_index=6 allocs=6 deallocs=5`,
then again at 17 and at 27 - one per journal directory in the fixture, each
the index where that journal's first `append` grows the list right after a
successful dupe.

Expected: `fa.allocations == fa.deallocations` after every refusal.

## Root cause

As above: an owning allocation passed as a call argument, with no scope owning
it between the allocation and the call that would have taken ownership.

## Resolution

```
const dup = try self.allocator.dupe(u8, f.name);
errdefer self.allocator.free(dup);
try names.append(self.allocator, dup);
```

The `errdefer` is scoped to the loop body, so it is discharged as soon as the
append succeeds and cannot free a name the list holds.

## Verification

- The sweep fails on the unpatched store at `fail_index = 6` and passes with
  the errdefer. Checked by restoring the argument form and re-running.
- `zig build test` green on the branch.

## Follow-up

The shape is now recorded three times. A lint rule ("no `try alloc...` inside
a call's argument list") is the obvious prevention and is not proposed here:
the gate's lint step is an in-tree marker scan, and this needs the AST.

## References

- Investigation: none
- Code: `src/journal/store.zig` (`loadJournal`)
- Related: [2026-08-31-journal-state-fold-leaks-before-the-put](2026-08-31-journal-state-fold-leaks-before-the-put.md),
  [2026-08-31-create-journal-name-leaks-on-put-failure](2026-08-31-create-journal-name-leaks-on-put-failure.md)
