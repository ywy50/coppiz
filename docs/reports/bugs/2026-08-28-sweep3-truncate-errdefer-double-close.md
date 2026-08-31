# Bug - `truncate`'s `errdefer` double-closes the adopted segment when `rebuildIndex` fails after the swap

## TL;DR

- **What failed:** `truncate` registers `errdefer file.close(self.io)` for the fresh head file and never disarms it; the segment is adopted into `jd.segments` before `rebuildIndex`, whose failure runs the errdefer and closes a file the journal now owns - `Store.deinit` closes it again (double-close).
- **Impact:** Error-path only: an OOM/IO failure in `rebuildIndex` during a merge truncate leaves the journal with a closed head handle and a deinit panic.
- **Resolution:** Fixed in `773af4d`. Originally validated statically.

## Status

Resolved.

## Symptom and impact

`store.zig:566-585`:

```zig
const file = try jd.dir.createFile(self.io, "seg-00000001", .{ .read = true });
errdefer file.close(self.io);          // :567 — armed to the end of the function
...
jd.segments.deinit(self.allocator);
jd.segments = segments;                 // :582-583 — file now owned by jd.segments
jd.head_records_len = @intCast(kept.items.len);
try self.rebuildIndex(jd);              // :585 — OOM/IO here → errdefer closes the file
```

`compact` guards the identical situation with the `adopted` flag ("after that an error is this store's problem, not the errdefer's", `store.zig:404-410`); `truncate` has no such guard. The comment at `:554-555` ("a rebuild error must not leave them for deinit to close again") covers only the *old* segments (cleared at `:556`); the new file's errdefer is the gap.

## Reproduction

Not dynamically reproduced (needs `rebuildIndex` to fail - OOM in `readRecordRegion`'s alloc, or an IO error); statically certain.

## Root cause

The errdefer remains armed past the point the file's ownership moved into `jd.segments`.

## Resolution

Fixed: `Store.truncate` disarms its errdefer once the fresh head file is adopted into `jd.segments`, so a `rebuildIndex` failure cannot double-close it.

## Verification

- Static: `truncate` (`store.zig:553-586`) vs `compact`'s `adopted` guard (`store.zig:404-410, 510`) read; the asymmetry is direct evidence of intent.

## Follow-up

Related storage defects reported separately: `hasSeal` conflation and the interrupted-compact window.

## References

- Code: `src/journal/store.zig:553-586` (`truncate`), `:404-410` (`compact`'s adopted guard)
- Fix: `773af4d` - `Store.truncate` gained the `adopted` flag
  (`var adopted = false; errdefer if (!adopted) file.close(self.io);`), armed
  over the fresh head file and disarmed once it is in `jd.segments`, matching
  `compact`.
- Re-checked 2026-08-31: the guard is present. `truncate` has since been
  restructured by `f9ec38c` (crash-atomicity), so the fresh head is written
  before anything is touched and `adopted = true` follows the in-memory swap
  rather than preceding `rebuildIndex`; the errdefer still cannot fire after
  adoption, which is what this report asked for.
- The "Still open" TL;DR line and the `Fix: none` reference above were left
  behind by `8893ae1`, which flipped 29 reports to `Resolved.` in a docs-only
  commit and did not update either line. The fix itself is real.
