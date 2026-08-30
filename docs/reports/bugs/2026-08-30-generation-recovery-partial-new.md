# Bug - the open-time generation recovery deletes the complete old generation for a partial new one

## TL;DR

- **What failed:** `loadJournal`'s crashed-compaction recovery kept the last
  file whose first record starts the chain. Compact writes the new segments
  one at a time (fsyncing each), so a crash after the first new segment -
  which always starts the chain - made the recovery keep that single
  segment and delete the complete old generation.
- **Impact:** every acknowledged slot that lived in the old generation's
  later segments silently vanished; the journal reopened as a one-segment
  chain with no re-sync source (a single node, or all nodes crashed during
  their own compactions). The exact crash class the recovery was built for.
- **Resolution:** Resolved - a new generation is kept only when it is
  complete (its file count matches the previous generation's, and its head
  segment is not torn); a partial new generation is deleted and the old one
  survives.

## Status

Resolved.

## Symptom and impact

The recovery (store.zig, `loadJournal`) scanned for the last file that
starts the chain (`prev_slot_hash == genesis_prev` - every generation's
first file does) and deleted everything before it. The reasoning "the new
one has the higher ordinals" assumes the new generation is complete, but a
crash can leave only its first segment: compact writes and fsyncs each new
segment before the next (store.zig, the compact loop), so a crash after the
first write leaves the old generation complete plus one complete new first
segment.

The recovery kept that segment and deleted the old generation. The
surviving records chain cleanly (they are byte-identical to the old first
segment), so nothing detected the loss: the fold accepted the truncated
chain as head.

## Reproduction

A journal with two or more segments; a crash after the first new segment of
a compaction is written. On reopen, the chain head regresses to the first
segment's last slot and the old files are gone. The existing recovery tests
covered only the two end windows (complete new generation; empty first new
file).

## Root cause

The recovery's completeness test was "the file starts the chain", which
every generation's first file satisfies - including a partial new
generation's first file. Nothing compared the new generation's extent
against what a complete compaction would produce.

## Resolution

Fixed: the recovery now finds every chain-start boundary and keeps the
newest generation that is *complete* - its file count equals the previous
generation's (compact rewrites one segment per segment) and its head
segment decodes fully (not torn). When no newer generation is complete, the
first generation wins and the partial newer files are deleted with the
stale ones - a partial generation left in place would fold on top of the
winner and refuse the open. A crash mid-truncate keeps the old generation,
which the loser re-truncates on its next divergence attempt - recoverable.

## Verification

- Regression test "open keeps the complete old generation when a crash left
  only the new one's first segment": the crash state (old generation plus
  the new first segment) reopens with every old slot present and the
  partial segment deleted.
- The existing recovery tests still pass (complete new generation wins;
  empty new first file keeps the old).
- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: src/journal/store.zig (`loadJournal` recovery, `fileStartsChain`,
  `fileDecodesFully`)
- Fix: this report's resolving commit
