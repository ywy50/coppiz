# Investigation - the unslotted queue's drain I/O on a confirmation burst

## TL;DR

- **Question:** what does draining k confirmed entries one by one cost, and
  can the burst be made sub-quadratic without a format change?
- **Finding:** every confirmation rewrites the whole queue file
  (`Queue.remove`: read the file, scan every record, write the kept ones
  back). k confirmations are k full-file rewrites - O(k²) I/O and O(k)
  memory per confirmation. Measured on this machine: draining 10 / 100 / 500
  queued entries takes 1 / 15 / 168 ms (queue files 1.9 / 18.8 / 94 KB);
  extrapolating quadratically, a 5000-entry burst (~1 MB) takes on the order
  of tens of seconds of I/O. The burst is real: a follower queues every
  locally authored append while its leader is slow or down, then drains them
  one by one as the confirmations land.
- **Resolution:** handoff to a format/policy decision -
  [RFC 0004](../../rfcs/0004-queue-drain-shape.md) evaluates the
  alternatives (drained-up-to watermark, in-place tombstones, batched
  drain); this report is its linked evidence.

## Status

Resolved as an investigation - the mechanism and scale are measured and the
options are laid out in RFC 0004. No format change is implemented (the RFC
is for discussion).

## Trigger and scope

The 2026-08-29 runtime sweep deferred this as item 14: "`Queue.remove`
rewrites the whole file per trim (O(k²) I/O on a burst) - on-disk format
change (tombstone/watermark/batched drain) - separate RFC, linked from
RFC 0003's out-of-scope". This investigation provides that RFC's evidence:
the exact I/O pattern, its measured scaling, and the constraints any
replacement must respect (replay idempotency, the crash-then-reslot safety
from RFC 0003, no change to what an acknowledged write means).

## Evidence

### Mechanism (read, verified at `main` @ `d4c14d5`)

`Queue.remove` (`src/journal/queue.zig:165-209`):

1. reads the **whole file** (`file.length` + one `readPositionalAll`);
2. scans every record (header-only decode per record, raw-span copy of the
   kept ones);
3. rewrites the **whole file** (`writePositionalAll(kept)` + `setLength`).

Called once per confirmed write from `applyReplicated`
(`src/journal/journal.zig:612`) and from the reforward drain
(`src/cluster/node.zig:565`); the single-member path uses the whole-queue
`clear` (`journal.zig:271`) and is unaffected (k stays ~1 there).

With k entries queued and k confirmations, the total I/O is the sum of the
file sizes at each drain: roughly k²·s/2 bytes read and the same written
(s = the record size) - quadratic in the burst size.

### Measurement (this machine, 2026-08-29)

A scratch test filled the queue with k entries (16-byte payloads, ~188 B
per record) and drained them in order, one `remove` per entry:

| k | queue file | total drain time |
|---|---|---|
| 10 | 1.9 KB | 1 ms |
| 100 | 18.8 KB | 15 ms |
| 500 | 94 KB | 168 ms |

The 10x then 5x growth in k produced 15x then 11x in time - consistent
with the quadratic I/O. Extrapolating: a 5000-entry burst (~1 MB of queue)
drains in the tens of seconds of file I/O on this machine, and the memory
per confirmation is the whole file (the read buffer + the kept list).

### Constraints any replacement must respect

- **Replay idempotency** (RFC 0003, verified): a drained entry's slot is
  already stored, so a crash that loses the drain redelivers an entry the
  fold dedups. A drain that is not durable is safe - the current `remove`
  no longer syncs (RFC 0003, ADR 0008).
- **The queue is the redo record for unslotted entries**: an entry must
  survive until its slot lands. Only *drained* (slotted) entries may be
  skipped or reclaimed.
- **The append bound** (`unslotted_max_bytes`) governs *queued* (unslotted)
  bytes; a drain design that leaves drained residue in the file must not
  let the file grow without bound, and must define what happens when it
  does.
- **Crash-then-reslot**: the replay path (`reforwardQueue`, the open-time
  scan) must handle the new drain shape.

## Hypotheses and tests

- **Hypothesis A - the drain is O(k²) I/O.** The code reads and rewrites
  the whole file per confirmation. *Result:* supported by reading and by
  the measured 15x/11x scaling for 10x/5x growth.
- **Hypothesis B - the single-member path is unaffected.** It uses `clear`
  (one truncate per append), k stays ~1. *Result:* supported (the measured
  path is the cluster confirmation path).
- **Hypothesis C - a drained entry needs no durable removal.** The slot is
  stored before the drain; a lost drain replays a no-op (RFC 0003's
  verified idempotency). *Result:* supported - this is what makes a
  non-rewriting drain (watermark/tombstone/batched) safe without a sync.

## Finding

The confirmation path's per-entry drain is a whole-file rewrite, making a
leader-outage burst quadratic in file I/O. The fix must change *when* or
*how* the file is rewritten, not what durability an acknowledged write
carries - the idempotency argument from RFC 0003 already makes the drain
barrier-free, so the rewrite itself is the only remaining cost.

## Resolution or handoff

The options and a recommendation are in
[RFC 0004](../../rfcs/0004-queue-drain-shape.md) (tombstone vs watermark
vs batched drain vs the status quo). The RFC's acceptance would need a
format/version decision for the queue file and a compaction policy; no
format change is made here.

## References

- Code: `src/journal/queue.zig` (`remove`, `clear`, `open`'s torn-tail
  handling), `src/journal/journal.zig` (`applyReplicated`, the replay
  drain), `src/cluster/node.zig` (`reforwardQueue`)
- Prior decisions: [RFC 0003](../../rfcs/0003-append-durability-fsync-policy.md),
  [ADR 0008](../../adrs/0008-storage-fsync-governs-the-queue.md) (the
  drain no longer syncs)
- Sweep: [2026-08-29 - runtime speedup sweep findings](2026-08-29-runtime-sweep-findings.md)
  (item 14), [write-path data flow](2026-08-29-runtime-sweep-queue-wire.md)
- Measurement: scratch drain test on this machine, 2026-08-29
