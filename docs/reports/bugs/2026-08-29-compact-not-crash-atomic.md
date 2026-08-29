# Bug - `compact` is not crash-atomic: an interrupted compaction leaves duplicate segments and the journal refuses to reopen

## TL;DR

- **What failed:** `compact` writes the new segment files while the old ones still exist, then closes and deletes the old ones. A crash (or an I/O error in the delete/rebuild walk) between those phases leaves both copies on disk; `loadJournal` scans both, folds the same slots twice, and the node refuses to open. The error path also leaves `jd.segments` empty, so the next append panics.
- **Impact:** A checkpoint-triggered compaction interrupted mid-way bricks the journal directory (no recovery path - a later compact cannot run because the store won't open).
- **Resolution:** Resolved - `compact`/`truncate` now swap the in-memory segments before deleting the old files (no failure points in the swap, so the empty-`jd.segments` append panic is gone), and `loadJournal` recovers the crashed-compaction on-disk state: a later file whose first record starts the chain marks the newer generation, which wins; the stale generation is deleted at open.

## Status

Resolved - `compact` (store.zig) writes and fsyncs the new generation,
adopts it in memory (the swap has no failure points, closing the
empty-`jd.segments` append panic), then deletes the stale old files;
`truncate` follows the same order with a fresh file at the next monotone
ordinal. `loadJournal` detects the both-generations crash state: every
generation's first file opens with the chain start (`prev = genesis_prev`),
so the last file whose first record starts the chain names the newest
generation — it is kept and the stale files before it are deleted at open.
A crash in any compaction/truncate window leaves either the old or the new
state, never an unfoldable mix.

## Symptom and impact

The sweep-1 fix made segment ordinals monotone (`next_ordinal`), closing the file-name collision, but the write-then-delete ordering was not made atomic. `store.zig:483-511`:

1. New files are written next to the old ones (the `first_new..` ordinals).
2. Old handles are closed (`:487`) and `jd.segments` is cleared (`:488`).
3. A directory walk deletes every `seg-*` file below `first_new` (`:491-506`) - `try jd.dir.deleteFile` can fail.
4. `rebuildIndex` (`:511`) can fail.

A crash between 1 and 3 leaves both sets on disk; `loadJournal` scans all `seg-*` files in name order, folds both copies of the same slots → `BadPrevHash`/`BadPosition` → `Node.open` refuses, permanently. An error at 3 or 4 additionally leaves `jd.segments` empty while old files are partially deleted - the store keeps running and the next `append` panics on `segments.items[len-1]` (`store.zig:236`).

## Reproduction

Not dynamically reproduced (crash/I/O-error timing); statically certain from the ordering.

## Root cause

The swap is not atomic: the files that make the new state are visible on disk before the old state is removed, and the in-memory segment list is cleared before the new list is adopted.

## Resolution

Fixed in store.zig. The suggested "temporary names + rename" direction
cannot be atomic across N files (renaming the new generation into place
while the old one still exists reproduces the both-generations window, and
deleting first opens a neither-state), so the fix takes the other half of
the suggestion plus an open-time recovery:

- `compact` reorders to write + fsync the new generation, swap it in memory
  (the swap has no failure points — `jd.segments` can never be left empty,
  closing the append panic), then delete the stale files.
- `truncate` reorders the same way, writing the fresh head at the next
  monotone ordinal (no more ordinal reset to 2).
- `loadJournal` recovers the crashed state: compact writes the new
  generation at ordinals contiguous with the old (monotone `next_ordinal`),
  so the two generations are indistinguishable by name — but every
  generation's first file opens with the chain start (`prev = genesis_prev`),
  which a single generation never repeats mid-chain. The last such file is
  the newer generation; it is kept and the stale files before it are
  deleted at open. A crash mid-write of the new generation leaves it a
  chain prefix that still folds (or, if its first record is torn, the old
  generation folds); the node re-syncs the tail from the leader.

Regression tests: "open recovers a crashed compaction: the newer generation
wins, stale files are deleted" (writes the old generation back below a
compacted one and asserts a single fold plus the stale files gone) and
"open keeps the older generation when the newer one is still being
written" (an empty new head folds as an empty segment). The store test
fixture `testSlot` now chains its prev hashes so the recovery signal is
exercised realistically.

## Verification

- Static: the write/close/clear/delete/rebuild ordering read; the empty-`jd.segments` panic path (`store.zig:236`) read.

## Follow-up

Related storage defect: the fold-before-store ordering (reported separately). Both are I/O-failure-window issues on the write path.

## References

- Code: `src/journal/store.zig:483-511` (`compact` swap), `:236` (append panic on empty segments)
- Fix: none
