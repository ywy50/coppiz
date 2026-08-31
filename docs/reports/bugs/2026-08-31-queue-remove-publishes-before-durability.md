# Bug - the queue's `remove` renames the temp file before its bytes are durable, and leaks its handle on every error path (open)

## TL;DR

- **What failed:** `Queue.remove` writes the kept records to
  `unslotted.queue.tmp` and renames it over `unslotted.queue` with no
  `sync` in between. A rename is atomic for the *name*, not for the data, so
  a crash can publish a directory entry pointing at a file whose bytes never
  reached disk. Separately, the temp file's handle is closed on no error path.
- **Impact:** the first defect can lose queued entries that `append`
  fsynced - the durability `append` promises under
  `storage.fsync = every`. If the published file lands shorter than the
  6-byte header, `Queue.open` treats it as brand new and rewrites it empty, so
  *every* queued entry is gone, not just the trimmed one; if it lands longer
  but truncated, the torn-tail rule drops the tail silently. The second
  defect leaks one descriptor per failed `remove`, and `applyReplicated`
  calls `remove` as `catch {}` on the replicated hot path, so the leak is
  silent.
- **Resolution:** **open.** Verified by reading; no fix in this change.

## Status

Open. Found 2026-08-31 by reading, while working on the neighbouring error
paths. Not observed in a run.

## Symptom and impact

```
const tmp = try self.dir.createFile(self.io, "unslotted.queue.tmp", .{ ... });
errdefer self.dir.deleteFile(self.io, "unslotted.queue.tmp") catch {};
try tmp.writePositionalAll(self.io, &header, 0);
try tmp.writePositionalAll(self.io, kept.items, header_len);
try std.Io.Dir.rename(self.dir, "unslotted.queue.tmp", self.dir, "unslotted.queue", self.io);
```

**The barrier.** The code's own comment states the reasoning: "No sync, per
Option A: a crash before the rename leaves the old file, and the trimmed
record's replay is an idempotent no-op." That covers a crash *before* the
rename. It does not cover the case where the rename is durable and the data is
not, which is the case a rename without a preceding fsync allows. The rename
was added by
[2026-08-30-queue-remove-not-atomic](2026-08-30-queue-remove-not-atomic.md) to
replace an in-place rewrite; it fixed the "partial prefix followed by intact
old records" state and left this one.

Why it matters more than the pre-fix state: the old failure was loud
(`Queue.open` refused as mid-file corruption). This one is quiet. A published
file under `header_len` is indistinguishable from a fresh queue, and
`Queue.open` rewrites it empty by design - the fix for
[2026-08-30-queue-fresh-header-window](2026-08-30-queue-fresh-header-window.md).

**The handle.** The `errdefer` unlinks the path and never closes `tmp`, so a
failing `writePositionalAll` or `rename` leaks one descriptor. On the success
path `tmp` becomes `self.file`, so the close belongs on the error path only.

## Reproduction

Neither half is reproduced.

- The barrier needs a crash between the rename reaching disk and the data
  doing so, which no fixture in the tree can produce; a `std.Io` seam that
  reorders or drops writes is the smallest thing that would.
- The handle leak needs a forced failure after `createFile`. The observable
  assertion exists - POSIX hands out the lowest free descriptor, the technique
  used in
  [2026-08-31-store-open-leaks-the-data-dir-on-refusal](2026-08-31-store-open-leaks-the-data-dir-on-refusal.md) -
  but forcing the `rename` to fail means building a fixture (replacing
  `unslotted.queue` with a directory behind the open handle) whose error
  depends on the platform's rename semantics. Filed rather than guessed.

## Root cause

Two independent ones: a durability barrier missing before a publish, and an
error path that releases the name but not the descriptor.

## Resolution

None yet. The shapes are:

- `try tmp.sync(self.io);` before the rename, gated on
  `self.fsync != .never` so the knob still means what `append` makes it mean
  (RFC 0003 Option A applies to *when* a barrier is taken, not to whether a
  publish may outrun its data).
- `errdefer tmp.close(self.io);` beside the existing unlink errdefer.

## Follow-up

`Queue.clear` truncates in place with the same "no sync" reasoning, and there
the reasoning holds: losing the truncate replays an entry the chain already
slotted, which is idempotent. It is not part of this report.

## References

- Investigation: none
- Code: `src/journal/queue.zig` (`remove`, `open`), `src/journal/journal.zig`
  (`applyReplicated`, the `catch {}` caller)
- Related: [2026-08-30-queue-remove-not-atomic](2026-08-30-queue-remove-not-atomic.md),
  [2026-08-30-queue-fresh-header-window](2026-08-30-queue-fresh-header-window.md),
  [RFC 0003](../../rfcs/0003-append-durability-fsync-policy.md)
