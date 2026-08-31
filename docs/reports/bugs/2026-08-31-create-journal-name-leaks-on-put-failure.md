# Bug - a `create_journal` fold leaks the journal name when the registry insert fails

## TL;DR

- **What failed:** `applyCreateJournalValidated` duped the journal's name
  inline, as an argument to `self.journals.put(...)`. Zig evaluates arguments
  before the call, so an `OutOfMemory` in the map's own growth left the dupe
  owned by nobody.
- **Impact:** one leaked allocation per refused fold of a `create_journal`. A
  fold that OOMs is fatal to the node either way, so this is a leak on the
  way to a stop rather than an unbounded one - but it is also the reason the
  new apply-side OOM sweep could not go green, so it was masking a test.
- **Resolution:** fixed - the dupe is a separate step in its own scope with
  an `errdefer`, the way `membership.applyJoin` already does it.

## Status

Resolved 2026-08-31. Found by the regression test written for
[2026-08-31-apply-side-oom-read-as-a-refusal](2026-08-31-apply-side-oom-read-as-a-refusal.md),
which reported the leak as soon as the refusal half was fixed.

## Symptom and impact

```
try self.journals.put(payload.journal_id, .{
    .id = payload.journal_id,
    .name = try self.allocator.dupe(u8, payload.name),
    .created_at = sl.position(),
});
```

The `dupe` runs first. If `put` then fails - it grows an `AutoHashMap`, so
`OutOfMemory` is its failure mode - the function returns and nothing owns the
duped name. `FoldState.deinit` frees the names the map holds, and this one is
not in the map.

`membership.applyJoin` separates the two steps for exactly this reason, and
says so. The create_journal path did not.

The blast radius is small and worth stating plainly: an `OutOfMemory` out of
`applyControl` is fatal by the file's own contract (`registerEntry`'s
comment - the fold is partially advanced and the node cannot continue), so
the process is stopping anyway. What made this worth fixing rather than
noting is that it is a real ownership error on a path a test now drives, and
it kept that test red.

## Reproduction

`src/journal/chain.zig`, test *an apply-side allocation failure is fatal,
never a settings refusal*: the sweep folds a `genesis` then a
`create_journal` on a `std.testing.FailingAllocator`, calls `deinit`, and for
every index that failed asserts `fa.allocations == fa.deallocations`.

Expected: equal. Before the fix: `expected 16, found 15` at the index that
fails inside `journals.put`. Under `zig build test` the runner's own leak
check reports the same thing, naming the `dupe` call site.

## Root cause

An owning allocation evaluated as a call argument, so no scope owned it
between the allocation and the call taking ownership.

## Resolution

```
{
    const name = try self.allocator.dupe(u8, payload.name);
    errdefer self.allocator.free(name);
    try self.journals.put(payload.journal_id, .{ ... .name = name ... });
}
try self.registerEntry(sl, en);
```

The block scope matters: the `errdefer` must stop applying once `put` has
taken ownership, or a later failure in `registerEntry` would free a name the
map still references. Ending the scope at the `put` is what guarantees that.

## Verification

- The sweep's accounting assertion fails on the unpatched fold with
  `expected 16, found 15` and passes with the fix. Checked by reverting the
  block and re-running.
- `zig build test` green on the branch; the same run was red with `1 leaks`
  before the fix.

## Follow-up

None in this function. Two neighbouring allocations on the same path -
`FoldState.init`'s settings state and the `registerEntry` insert - are freed
by `deinit` and by the map respectively, so they carry no equivalent gap.

## References

- Investigation: none
- Code: `src/journal/chain.zig` (`applyCreateJournalValidated`),
  `src/cluster/membership.zig` (`applyJoin`, the pattern followed)
- Related: [2026-08-31-apply-side-oom-read-as-a-refusal](2026-08-31-apply-side-oom-read-as-a-refusal.md)
