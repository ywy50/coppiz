# Bug - `compact` is not crash-atomic: an interrupted compaction leaves duplicate segments and the journal refuses to reopen

## TL;DR

- **What failed:** `compact` writes the new segment files while the old ones still exist, then closes and deletes the old ones. A crash (or an I/O error in the delete/rebuild walk) between those phases leaves both copies on disk; `loadJournal` scans both, folds the same slots twice, and the node refuses to open. The error path also leaves `jd.segments` empty, so the next append panics.
- **Impact:** A checkpoint-triggered compaction interrupted mid-way bricks the journal directory (no recovery path - a later compact cannot run because the store won't open).
- **Resolution:** Still open. Statically validated.

## Status

Open.

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

Not yet fixed. Suggested direction: write the new segments under temporary names and atomically rename them over the old ones (or write-then-delete with the in-memory swap held until every filesystem step succeeded, with an errdefer that restores a coherent state). A crash-injection test should kill the process mid-compact and assert the journal still opens (old or new state, never both).

## Verification

- Static: the write/close/clear/delete/rebuild ordering read; the empty-`jd.segments` panic path (`store.zig:236`) read.

## Follow-up

Related storage defect: the fold-before-store ordering (reported separately). Both are I/O-failure-window issues on the write path.

## References

- Code: `src/journal/store.zig:483-511` (`compact` swap), `:236` (append panic on empty segments)
- Fix: none
