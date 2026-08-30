# Bug - the queue's `remove` rewrite is not atomic: a crash mid-write bricks the file

## TL;DR

- **What failed:** `Queue.remove` rewrites the queue file in place
  (`writePositionalAll` then `setLength`). A crash mid-rewrite persists an
  arbitrary prefix of the kept records followed by the intact old tail; the
  next open scans to the junction, finds valid old records after it, and
  refuses with `Corrupt` - on every restart.
- **Impact:** the node fails to open until the queue file is deleted by
  hand. The no-sync design (RFC 0003 Option A) covers only a crash that
  loses the trim (the old file survives); a crash that partially applies it
  produces a corrupt mix.
- **Resolution:** Resolved - `remove` now writes the kept bytes to a temp
  file and renames it over the queue file (atomic); a crash before the
  rename leaves the old file, per the Option A semantics.

## Status

Resolved.

## Symptom and impact

`Queue.remove` (queue.zig) reads the records, filters out the removed
entry, and rewrites the kept bytes in place, then truncates. A crash (or
I/O error) between the write and the truncate - or mid-write - leaves the
file as a partial kept prefix followed by the old records, whose intact
CRCs make `open`'s `findValidRecordAfter` see mid-file corruption and
return `error.Corrupt`. `remove` runs on the hot replicated path
(`applyReplicated`'s queue trim and `reforwardQueue`).

## Reproduction

Write records R1 R2 R3, remove R2, and crash after half of the copied R3
lands: the file is `R1 | R3-partial | R2 | R3`; the next open refuses.

## Root cause

The in-place rewrite mutates the file through a window in which a prefix of
the new state coexists with the old tail - the exact shape the store's
compaction/truncate were rebuilt to avoid.

## Resolution

Fixed: `remove` writes the kept bytes (plus the header) to
`unslotted.queue.tmp`, then renames it over the queue file. The rename is
atomic; a crash before it leaves the old file (the trimmed record's replay
is an idempotent no-op - the Option A semantics); a crash during the temp
write leaves a `.tmp` file the next open ignores. The queue's handle is
swapped to the renamed temp, whose inode the rename keeps.

## Verification

- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: src/journal/queue.zig (`Queue.remove`, `Queue.open`)
- Fix: this report's resolving commit
