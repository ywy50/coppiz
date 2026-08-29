# Bug - `zig build test` is red on main: a crashed-compaction test builds its path out of an undefined buffer tail

## TL;DR

- **What failed:** `journal.store.test.open recovers a crashed compaction` passed the whole `[64]u8` name buffer to `createFile`, not the 50-byte path `bufPrint` wrote into it, so the path carried 14 undefined bytes and the call refused with `error.BadPathName`.
- **Impact:** `zig build test` was red on `main` for every checkout: 1 failed test of 285, and the gate exits 1.
- **Resolution:** Fixed - the test keeps the slice `bufPrint` returns and passes that.

## Status

Resolved.

## Symptom and impact

`zig build test` on an untouched `origin/main` at `6a351b2`:

```
error: 'journal.store.test.open recovers a crashed compaction: the newer
generation wins, stale files are deleted' failed:
  .../lib/std/Io/Threaded.zig:4297:35: in dirCreateFilePosix
      .ILSEQ => return error.BadPathName,
  .../src/journal/store.zig:1359:22: in test.open recovers a crashed compaction
      const file = try env.tmp.dir.createFile(tio, &snap_names[i], .{
Build Summary: 21/23 steps succeeded (1 failed); 284/285 tests passed (1 failed)
```

The failure is deterministic and independent of any working-tree change: it
reproduces on a detached worktree of `origin/main` with no diff. It arrived
with the crash-atomic compaction work in
[#126](https://github.com/ywy50/coppiz/pull/126).

## Reproduction

```sh
git worktree add ../coppiz-wt-base origin/main --detach
cd ../coppiz-wt-base && zig build test
```

Expected: exit 0. Actual: exit 1 with the failure above.

## Root cause

The test snapshots the pre-compaction segment files so it can write them back
and simulate a crash between "new generation written" and "old generation
deleted". It formats each snapshot's path into a fixed buffer:

```zig
var snap_names: [8][64]u8 = undefined;
...
snap_names[i] = undefined;
_ = try std.fmt.bufPrint(&snap_names[i], "data/{x}/seg-{d:0>8}", .{ journal_id, i + 1 });
```

`bufPrint` returns the slice it wrote and the return value was discarded. The
formatted path is 50 bytes (`data/` + 32 hex digits of the 16-byte journal id
+ `/seg-` + 8 digits), so 14 bytes of the buffer stay undefined. Passing
`&snap_names[i]` coerces the whole `*[64]u8` to a 64-byte slice, so those 14
bytes became part of the file name. In a Debug build `undefined` is `0xaa`
fill, which is not valid UTF-8, and macOS returns `ILSEQ` for it - mapped to
`error.BadPathName`.

Nothing about the code under test is wrong; the recovery path the test covers
is never reached, because the test aborts while staging its own fixture.

## Resolution

The test keeps the slice `bufPrint` returns in a parallel `snap_paths:
[8][]const u8` and passes `snap_paths[i]` to `createFile`. The redundant
`snap_names[i] = undefined;` line is gone. This is the only `bufPrint` call
in `store.zig`, so there is no second site with the same shape.

## Verification

- `zig build test` on the fix branch: exit 0, `Build Summary: 23/23 steps
  succeeded; 285/285 tests passed`.
- The same gate on the untouched base worktree: exit 1, 284/285. The two runs
  differ only in this commit.

## Follow-up

The failure would have been caught by gating the merge rather than the branch:
#126 was one of a stack of branches whose file lists accumulated, and the
green run that preceded the merge was not re-established against the merged
tree. None beyond that.

## References

- Investigation: none
- Code: `src/journal/store.zig` (the crashed-compaction recovery test)
- Related: [2026-08-29 - `compact` is not crash-atomic](2026-08-29-compact-not-crash-atomic.md)
