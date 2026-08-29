# Bug - a segment header naming another journal closes the file twice

## TL;DR

- **What failed:** `loadJournal`'s `JournalIdMismatch` branch closed the
  segment file by hand while the `errdefer` that owns it was still live, so
  the same descriptor was closed twice on the way out.
- **Impact:** `Store.open` aborts instead of returning
  `error.JournalIdMismatch`. In debug and ReleaseSafe builds the second
  close is an `EBADF` the Io layer reports as a non-recoverable OS bug
  (`panic: reached unreachable code`); in ReleaseFast it closes whatever
  descriptor that number now names, which in a serving node can be a live
  socket or another segment.
- **Resolution:** fixed. The explicit close is removed; the `errdefer` is
  the single owner, as it already is on every other error exit in the loop.

## Status

Resolved - 2026-08-30. Found by reading; no incident preceded it.

## Symptom and impact

```
thread 7235320 panic: reached unreachable code
src/journal/store.zig:827:32: in loadJournal
src/journal/store.zig:753:33: in loadAll
src/journal/store.zig:139:26: in open
```

`error.JournalIdMismatch` was unreachable in practice: nothing in the tree
had a test that produced it, and the one branch that raises it aborted
first. The condition it guards - a segment whose header names a different
journal than the directory it sits in - is what a hand-renamed journal
directory, a segment copied between journals, or a restore that mixed two
backups looks like. Those are exactly the cases where an operator needs a
named refusal rather than a crash.

## Reproduction

`a segment header naming another journal refuses the open once` in
`src/journal/store.zig`: build a journal with two records, close it,
rewrite bytes 6..22 of `data/<hex>/seg-00000001` (the header's `journal_id`
field, `segment.encodeHeader`) to a different id, and reopen.

- Expected: `error.JournalIdMismatch`.
- Actual, before the fix: `panic: reached unreachable code`, confirmed by
  reverting the fix hunk and running `zig build test` (exit 1).

## Root cause

```zig
const file = try sub.openFile(self.io, seg_name, .{ .mode = .read_write });
errdefer file.close(self.io);
...
if (!std.mem.eql(u8, &header.journal_id, &journal_id)) {
    file.close(self.io);            // <- and then the errdefer fires too
    return error.JournalIdMismatch;
}
```

`errdefer` runs on every error return from the enclosing block, so the
explicit close and the deferred one both ran. `std.Io.File.close` reaches
`Threaded.closeFd`, which treats `EBADF` as a bug in the caller:
`recoverableOsBugDetected()` is `unreachable` in debug builds.

Every other error exit in the same loop (`UnsupportedVersion`, `Corrupt`,
`Truncated`) relies on the `errdefer` alone. This branch was the only one
that also closed by hand.

## Resolution

Delete the explicit `file.close`. One owner, one close. A comment beside
the branch names the `errdefer` as the owner so the pattern is not
reintroduced.

## Verification

- The new test returns `error.JournalIdMismatch` with the fix and panics
  without it (`zig build test` exit 1, panic at `store.zig:827`).
- Full gate `zig build test` exit 0 on the branch.

## Follow-up

The mismatch error path still leaves `loadJournal`'s partially built
`JournalDir` (its index map, its segment list, and the descriptors of
segments loaded before the mismatching one) unfreed - the `errdefer` there
only destroys the struct. That is a separate ownership defect on the same
error path, not fixed here.

## References

- Investigation: none
- Code: `src/journal/store.zig` (`loadJournal`)
- Related: [2026-08-28 - sweep3: `truncate`'s errdefer double-closes the adopted segment on `rebuildIndex` failure](2026-08-28-sweep3-truncate-errdefer-double-close.md)
  and [2026-08-29 - `cmdInit`'s `errdefer data_dir.close(io)` closes a descriptor the store already closed](2026-08-29-init-data-dir-double-close.md),
  the same double-close class at other sites
