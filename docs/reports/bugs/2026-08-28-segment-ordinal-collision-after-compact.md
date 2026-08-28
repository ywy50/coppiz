# Bug — Segment ordinal arithmetic collides after compaction; `sealHead` truncates the journal's own first segment

## TL;DR

- **What failed:** After a compaction, `sealHead` computes the next segment's file name from the segment *count*, which now collides with the journal's own first segment file and truncates it (`createFile` truncates by default). A second compaction has the same collision on its rewrite path.
- **Impact:** Data loss of acknowledged, fsynced records; the store is left unopenable/corrupt. The routine production cycle — checkpoint → compact → keep appending until the head seals — is exactly the trigger.
- **Resolution:** Still open. Reproduced dynamically with a failing test.

## Status

Open.

## Symptom and impact

`append` after a compact + seal fails with `error.Truncated` (from `sealHead` reading the journal's own first segment header), and the journal's first segment file has been truncated to zero: its records are gone. If the truncation is ever allowed to complete, two `Segment` entries in `jd.segments` alias one inode and the scan/fold misreads the journal. No shipped test combines compact with seal, so the suite is green.

## Reproduction

Validated by a standalone repro (store level, mirroring the shipped "small seal threshold" test at `store.zig:1018`): open a store with `seal_threshold = 200`, create a journal, append 5 records (each segment seals at ~387 bytes), `compact` out record 3 (`retain = .none`), append 2 more. The second append triggers `sealHead`, which fails with `Truncated` — the journal's first segment file was truncated by `createFile` before its header could be read back:

```
src/journal/store.zig:269:24: 0x... in sealHead
        const header = try self.readSegmentHeader(&jd.segments.items[0]);
```

Expected on a correct store: the append succeeds and `scan` still sees 6 records (1, 2, 4, 5, 6, 7). Actual: the append errors and segment 1's records are destroyed.

## Root cause

`store.zig` names segment files from the *count* of segments, but `compact` renumbers the files to `old_count + 1 .. old_count + N` and deletes the originals:

- `sealHead` (`store.zig:263`): `const ordinal = jd.segments.items.len + 1;` — after a compact of N segments this equals `old_count + 1`, the name of the journal's **first** (oldest, sealed, still-open) segment file. `createFile(name_buf, .{ .read = true })` at `:266` **truncates by default** (`std.Io.Dir.CreateFileOptions.truncate` defaults to `true`, verified in the installed `std/Io/Dir.zig`); `createJournal` (`:195`) and `Queue.open` explicitly pass `.truncate = false`, showing the default is not relied on elsewhere.
- `compact` (`store.zig:398`): `ordinal = old_count + new_segments.items.len + 1` with `.truncate = true` — on the **second** compaction the names are exactly the journal's own currently-open segment files. On success each file happens to be fully rewritten, but any error mid-rewrite (ENOSPC/EIO/OOM) leaves the old handles in `jd.segments` pointing at truncated files, and the errdefer only closes the *new* handles — the old records are gone.

Both defects share one root cause: segment ordinal numbering assumes files are always `1..N`, which compaction invalidates.

## Resolution

Not yet fixed. Suggested direction: derive the ordinal from the maximum existing ordinal (or track a counter in the journal dir), and pass `.truncate = false` semantics explicitly where a fresh file is intended — or better, make `sealHead`/`compact` allocate a fresh ordinal that cannot collide with an in-use file. A regression test should combine compact with seal (and a second compact), then reopen and scan.

## Verification

- Dynamic: the standalone repro above fails exactly as described (`error.Truncated` from `append`; first segment truncated).
- Static: `createFile` truncate default verified in std source; ordinal arithmetic verified against the compact renumbering loop (`store.zig:394-463`) and the swap/delete walk (`:465-480`, "Old ordinals are all below the first new one" — true only before any compaction).

## Follow-up

Related but weaker variant in the same family: the mid-compaction error path (see Root cause). Also, `Queue.open` shares the truncation-on-error shape — reported separately.

## References

- Code: `src/journal/store.zig:263-281` (`sealHead`), `:368-463` (`compact`), `:404-407` (truncate on rewrite)
- Fix: none
