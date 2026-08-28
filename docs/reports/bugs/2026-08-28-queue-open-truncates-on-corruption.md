# Bug — `Queue.open` truncates the queue on any decode failure, silently dropping acknowledged entries on mid-file corruption

## TL;DR

- **What failed:** `Queue.open` breaks its record scan on *any* decode error and truncates the queue file. A single flipped byte in the middle of the file silently discards every later queued entry — acknowledged, fsynced writes — where the store refuses the identical situation as `Corrupt`.
- **Impact:** Lost acknowledged appends under partial corruption; the queue's own doc comment ("torn tail = unacknowledged") is wrong for mid-file damage.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

The unslotted queue is durable (`src/journal/queue.zig`); entries the node accepted from clients sit here until slotted. On restart, `Queue.open` replays the file. If any record mid-file fails to decode (bit rot, partial overwrite, torn write beyond the tail), the open path truncates the file at the failure point and **drops every queued entry after it** — including ones that were fsynced before the corruption happened. The store, by contrast, distinguishes a torn tail from mid-file corruption (`findValidRecordAfter`, `store.zig:743`) and refuses mid-file damage with `Corrupt` ([G3](docs/glossary.md)).

## Reproduction

Not dynamically reproduced; statically certain. The open loop (queue.zig:90-96) decodes records in order; the first `decodeRecord` error exits the loop and the file is truncated at the current offset. Any record whose bytes are damaged mid-file triggers it; the entries after it are gone.

## Root cause

The queue's open scan has no equivalent of the store's torn-tail handling: it treats every decode failure as "the tail was never acknowledged" and truncates. The doc comment asserts the truncation is safe ("torn tail = unacknowledged") without checking *where* the failure is.

## Resolution

Not yet fixed. Suggested direction: mirror the store's `findValidRecordAfter` behavior — a valid record after the failure point is mid-file corruption and must refuse to open (or repair conservatively), while a clean end-of-file after the failure is a torn tail and may truncate. A regression test should flip a byte mid-file and assert the queue refuses to open rather than dropping later entries.

## Verification

- Static: open loop and truncation verified line-by-line; store's torn-tail handling read for comparison.

## Follow-up

None. Related storage-path defect: the segment-ordinal collision after compact (reported separately).

## References

- Code: `src/journal/queue.zig:90-96` (open scan + truncate), `src/journal/store.zig:743` (`findValidRecordAfter`)
- Fix: none
