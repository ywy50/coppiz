# Bug - a segment file left shorter than its header panics `Store.open`

## TL;DR

- **What failed:** `fileStartsChain` subtracts the segment header length
  from the file length before checking the file is that long, so a `seg-*`
  file shorter than 54 bytes traps on the unsigned underflow and aborts
  `Store.open`.
- **Impact:** a node that crashed between `createFile` and the header write
  - the window in `createJournal`, `sealHead`, `compact` and `truncate` -
  cannot reopen its data directory. The process aborts with
  `panic: integer overflow` in Debug and ReleaseSafe builds; in ReleaseFast
  the same expression yields a ~1.8e19 length that is `@intCast` into an
  `alloc`.
- **Resolution:** fixed. `loadJournal` drops a `seg-*` file shorter than one
  header before loading it, and `fileStartsChain` returns `false` for such a
  file, which is what its own doc comment already promised.

## Status

Resolved - 2026-08-30. Found by reading, not by an incident; no
investigation record precedes it.

## Symptom and impact

`Store.open` aborts:

```
thread 7223413 panic: integer overflow
src/journal/store.zig:925:33: in fileStartsChain
src/journal/store.zig:812:41: in loadJournal
src/journal/store.zig:753:33: in loadAll
src/journal/store.zig:139:26: in open
```

Line 925 is `const records_len = len - segment.header_len - ...`.

The precondition is a `seg-*` file with fewer than `segment.header_len`
(54) bytes in a journal directory that has at least one other segment -
`fileStartsChain` runs from `loadJournal`'s generation-recovery scan, which
skips index 0. Every segment writer has the window that produces one:
`createJournal` (`createFile` at :200, header write at :211), `sealHead`,
`compact` and `truncate` all create the file and then write the header as a
separate call. A crash in between leaves 0 bytes; a crash during the header
write itself leaves 1-53.

Reopening is the only recovery path a crashed node has, so the effect is a
node that cannot start, with a panic rather than a named refusal.

## Reproduction

`open drops a segment file left shorter than its header by a crashed
create` in `src/journal/store.zig`. It builds a journal with five records,
then creates the next ordinal's file with 0 bytes and, in a second
iteration, with the first 20 bytes of a header. Expected: the open recovers
and scans five records. Actual, before the fix: `panic: integer overflow`
in `fileStartsChain`, observed by reverting the two fix hunks and running
`zig build test` (exit 1).

## Root cause

`len` is `u64` and `segment.header_len` is a comptime integer, so
`len - segment.header_len` is unsigned arithmetic with no guard.
`sealStatus`, called one line earlier, returns `.absent` for a short file
and does not constrain `len`. Unlike `loadJournal`'s main loop -  which
calls `readSegmentHeader` first and so bails with `Truncated` -
`fileStartsChain` reads no header before doing the arithmetic.

The doc comment on `fileStartsChain` already states the intended answer for
this input ("A torn or empty file is not a generation start"); the code did
not implement it.

Removing only the trap is not enough: with `fileStartsChain` returning
`false`, `loadJournal`'s main loop then calls `readSegmentHeader` on the
same file and refuses the whole open with `Truncated` - for a file that
provably carries neither a header nor a record.

## Resolution

Two changes in `src/journal/store.zig`:

1. `loadJournal`'s segment-name scan drops any `seg-*` file shorter than
   `segment.header_len`: it holds no header and no records, so there is
   nothing to load and nothing to lose, and its ordinal becomes free again.
   A new `segmentFileLen` helper reads the length without adopting the file.
2. `fileStartsChain` returns `false` when the file is shorter than one
   header, before the subtraction. `loadJournal` now drops such files
   before they reach it; the guard keeps the function total for any other
   caller.

No format change and no operator action: the recovery happens at open.

## Verification

- The new test passes with the fix and panics without it (both hunks
  reverted, `zig build test` exit 1, panic at `store.zig:925`).
- Full gate `zig build test` exit 0 on the branch.
- The sibling test `open keeps the older generation when the newer one is
  still being written` (a 54-byte header-only file) is unchanged and still
  passes, so the header-written half of the crash window is not affected.

## Follow-up

None outstanding for this window. A file of 54 bytes or more whose header
is intact but whose records are torn is a different case, already covered
by the torn-tail truncate in `loadJournal`.

## References

- Investigation: none
- Code: `src/journal/store.zig` (`loadJournal`, `fileStartsChain`,
  `segmentFileLen`)
- Related: [2026-08-29 - `compact` is not crash-atomic](2026-08-29-compact-not-crash-atomic.md),
  which introduced `fileStartsChain` and whose regression test covers the
  header-written empty file only
