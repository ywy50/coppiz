# RFC 0004 - what shape should the queue drain take?

## Status

Discussion - opened 2026-08-29.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Every confirmed cluster write drains one entry from the unslotted queue by
rewriting the whole queue file (`Queue.remove`: read the file, scan every
record, write the kept records back). k confirmations after a leader-outage
burst are k whole-file rewrites - O(k²) I/O (measured: 10/100/500 queued
entries drain in 1/15/168 ms; a 5000-entry burst is tens of seconds of I/O -
[investigation 2026-08-29](../reports/investigations/2026-08-29-queue-drain-burst-io.md)).

**Decision to make.** When a confirmation drains an entry, what happens to
the queue file - and what reclaims the drained bytes?

**Why now.** The write path is the runtime hot path (PRD 0001 *Write path*).
The queue's per-confirmation drain is now the only remaining per-write cost
after RFC 0003 removed the drain's fsync barrier: the rewrite itself. The
burst case (a slow or down leader) is exactly when the queue is large and
the quadratic cost is worst.

**Drivers.** Any acceptable option must:

- keep the queue as the redo record for unslotted entries: an entry must
  survive until its slot lands, and only drained (slotted) entries may be
  skipped or reclaimed;
- preserve crash-then-reslot safety: a lost drain replays an idempotent
  no-op (the fold dedups a redelivered slot - the argument RFC 0003/ADR 0008
  already relies on for the barrier-free drain);
- not change what an acknowledged write means (PRD 0001 G3 is unaffected:
  the store write and its fsync are untouched by every option here);
- bound the queue file: a design that leaves drained residue must reclaim
  it, and must define the bound (the append bound `unslotted_max_bytes`
  governs queued bytes, not the file's residue);
- keep the open-time recovery correct (a torn tail truncates; the scan must
  skip or tolerate the drained shape).

## Current state

`Queue.remove` (queue.zig:165-209) is the only drain on the cluster
confirmation path (`applyReplicated`, journal.zig:612; the reforward drain,
node.zig:565); the single-member path uses the whole-queue `clear`
(journal.zig:271), which is one `setLength` per append and is not part of
this problem. The queue file is `magic (4) | version u16 | records`; a
record is `len u32 | crc u32 | entry bytes` (queue.zig:22-25). `remove` no
longer syncs (RFC 0003), so a non-rewriting drain needs no barrier either.

## Options considered

### Option A - drained-up-to watermark

- **What it is:** the header gains a "drained through offset" cursor.
  Draining advances the cursor (one small header write, O(1) I/O per
  confirmation). The drained prefix stays in the file until a compaction
  rewrites the file without it (when the prefix is large - a threshold such
  as "prefix > queued bytes" or "> 1 MiB" - or on `clear`).
- **Format:** the queue version bumps (or a backward-compatible header
  extension); old files open with the cursor at zero.
- **Replay/scan:** starts at the cursor, so the drained prefix is never
  scanned. A torn tail still truncates at open.
- **Durability:** the cursor advance need not sync (a lost advance
  redelivers drained entries - idempotent, per RFC 0003's argument).
- **Pros:** O(1) per confirmation; the compaction is amortized and uses the
  existing rewrite machinery; the replay path is a one-line change (start
  offset).
- **Cons:** the file grows during a burst (drained residue until the
  compaction); a compaction threshold must be chosen; the header changes.
- **Maturity:** the cursor is a new durable field; the compaction reuses
  `remove`'s rewrite.

### Option B - in-place tombstones

- **What it is:** a drained record is marked in place (a tombstone state in
  the record prefix, or a flag byte). Draining is one small write per
  record (O(1) I/O per confirmation, no file rewrite). Tombstones accumulate
  until a compaction reclaims them.
- **Format:** the record prefix gains a tombstone state; version bump.
- **Replay/scan:** skips tombstoned records (a decode-time check).
- **Durability:** the tombstone write need not sync (same idempotency).
- **Pros:** O(1) per confirmation; the drained records are individually
  marked (no cursor arithmetic); compaction is the existing rewrite.
- **Cons:** one write per record rather than one per drain (a drain of one
  entry is one tombstone - same as the watermark's one header write; the
  difference is only in what is written); the prefix format changes.
- **Maturity:** same class as A (format change + compaction), slightly more
  per-record surgery.

### Option C - batched drain (no per-confirmation file touch)

- **What it is:** a confirmation does not touch the file at all - the entry
  stays until a drain point: `clear` (the queue is empty) or a compaction
  when the drained residue exceeds a threshold. The in-memory `queued_bytes`
  still tracks unslotted entries.
- **Format:** none - this is a policy change on when the existing
  rewrite/truncate runs.
- **Replay/scan:** unchanged (the file holds drained + queued entries; the
  replay redelivers drained ones as no-ops - already the case for any
  crash between slot and drain today).
- **Durability:** unchanged; a crash simply replays more no-ops.
- **Pros:** zero format change; the per-confirmation cost is O(0); the
  compaction is amortized; the crash safety is exactly today's.
- **Cons:** the file grows during a burst (drained residue until the
  compaction) - same as A/B, but without even the O(1) drain write; the
  queue file can carry a large stale prefix for a long time (the replay
  scans it on every open); the threshold must be chosen.
- **Maturity:** smallest change of the three; no version bump.

### Option D - status quo

- **What it is:** the whole-file rewrite per confirmation.
- **Pros:** nothing to change; the file is always minimal.
- **Cons:** O(k²) I/O on the burst (the measured 168 ms at k=500, tens of
  seconds at k=5000).

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A or B:** the burst drain becomes amortized O(k) (the compactions)
  with O(1) per confirmation; the queue file can grow to the residue
  threshold during a burst.
- **If C:** same amortized behaviour with zero format change; the file's
  stale prefix grows until the threshold and every open scans it.
- **If D:** the burst cost stays quadratic.

### Medium term (3-12 months)

- A's cursor and B's tombstones both need a compaction policy and a bound;
  C's policy needs the same bound, and a "drain on open if the prefix is
  large" rule keeps the open-time scan bounded.

### Long term (12+ months)

- The queue's on-disk format is internal (no external consumers read it);
  a version bump today has no compatibility cost beyond the open-time
  migration.

## Recommendation

**Recommended option:** C - the batched drain, with a residue threshold -
because it delivers the amortized win with **no format change**, the
smallest correctness surface (the crash safety is exactly today's replay
idempotency), and it keeps the door open for A or B later if the file's
stale-prefix behaviour ever matters.

**Confidence:** 6/10.

**Why this confidence.** The mechanism and scale are measured; C's safety is
the already-verified replay idempotency. What would move it up: a decision
on the residue threshold (and whether a large drained prefix should be
compacted lazily on open), and the observation that the replay scan reads
the whole file on every open - so C's stale prefix must be bounded or the
open cost grows. A/B would move it down only if the stale-prefix open cost
proves material and the header change is wanted anyway.

**Rationale.** Against the drivers: C keeps the redo record semantics
(unslotted entries survive; drained ones replay as no-ops - the same as a
crash between slot and drain today), preserves crash-then-reslot, does not
change the ack contract, bounds the file by the chosen threshold plus the
append bound, and keeps the open-time recovery unchanged. It beats A/B on
format surface (none) and D on the burst cost. Its weakness - the stale
prefix scanned on open - is bounded and observable.

**Reversibility.** C is fully reversible (a policy change; revert to the
per-confirmation drain by restoring one call). A/B are format changes with
an open-time migration.

## Open questions

- What is the residue threshold (absolute bytes, or relative to
  `unslotted_max_bytes`)? *Answerable by:* the burst measurement at the
  queue's realistic sizes; default proposal: compact when the drained
  prefix exceeds the queued bytes, or on `clear`.
- Should a large drained prefix be compacted on open (amortize the replay
  scan)? *Answerable by:* measuring the open-time scan on a stale-prefix
  file.
- Does any consumer read the queue file outside the process (backup,
  inspection)? The format is internal today; a version bump's cost is
  otherwise zero. *Answerable by:* the operator.

## Next steps / action items

- [ ] Decide the drain shape (this RFC); if C, choose the threshold.
- [ ] Implement: confirmation paths stop calling `remove`; a drain/compact
      point (clear, or threshold-crossing) calls the existing machinery.
- [ ] Regression: the queue's trim tests plus a burst test asserting the
      file stays bounded and the replay skips no unslotted entry.

## References

- Investigation: [2026-08-29 - the unslotted queue's drain I/O on a confirmation burst](../reports/investigations/2026-08-29-queue-drain-burst-io.md)
- Prior decisions: [RFC 0003](../rfcs/0003-append-durability-fsync-policy.md)
  and [ADR 0008](../adrs/0008-storage-fsync-governs-the-queue.md) - the
  drain no longer syncs, which is what makes every option here barrier-free
- Sweep: [2026-08-29 - runtime speedup sweep findings](../reports/investigations/2026-08-29-runtime-sweep-findings.md)
  (item 14)
- Code: `src/journal/queue.zig` (`remove`, `clear`, `open`),
  `src/journal/journal.zig` (`applyReplicated`), `src/cluster/node.zig`
  (`reforwardQueue`)
