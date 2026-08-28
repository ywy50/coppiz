# Bug — `truncate`'s `errdefer` double-closes the adopted segment when `rebuildIndex` fails after the swap

## TL;DR

- **What failed:** `truncate` registers `errdefer file.close(self.io)` for the fresh head file and never disarms it; the segment is adopted into `jd.segments` before `rebuildIndex`, whose failure runs the errdefer and closes a file the journal now owns — `Store.deinit` closes it again (double-close).
- **Impact:** Error-path only: an OOM/IO failure in `rebuildIndex` during a merge truncate leaves the journal with a closed head handle and a deinit panic.
- **Resolution:** Still open. Statically validated.

## Status

Open.

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

Not dynamically reproduced (needs `rebuildIndex` to fail — OOM in `readRecordRegion`'s alloc, or an IO error); statically certain.

## Root cause

The errdefer remains armed past the point the file's ownership moved into `jd.segments`.

## Resolution

Not yet fixed. Suggested fix: set an `adopted` flag before the swap and gate the errdefer on it, mirroring `compact`. A regression test should fail `rebuildIndex` and assert the store still deinits cleanly.

## Verification

- Static: `truncate` (`store.zig:553-586`) vs `compact`'s `adopted` guard (`store.zig:404-410, 510`) read; the asymmetry is direct evidence of intent.

## Follow-up

Related storage defects reported separately: `hasSeal` conflation and the interrupted-compact window.

## References

- Code: `src/journal/store.zig:553-586` (`truncate`), `:404-410` (`compact`'s adopted guard)
- Fix: none
