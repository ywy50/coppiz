# Bug - `Queue.open` truncates the queue on any decode failure, silently dropping acknowledged entries on mid-file corruption

## TL;DR

- **What failed:** `Queue.open` breaks its record scan on *any* decode error and truncates the queue file. A single flipped byte in the middle of the file silently discards every later queued entry - acknowledged, fsynced writes - where the store refuses the identical situation as `Corrupt`.
- **Impact:** Lost acknowledged appends under partial corruption; the queue's own doc comment ("torn tail = unacknowledged") is wrong for mid-file damage.
- **Resolution:** Still open. Statically validated.

## Status

Resolved - `Queue.open` mirrors the store's torn-tail test: a valid
record after the break refuses with `Corrupt`; regression test flips a
byte mid-file.

## Symptom and impact

The unslotted queue is durable (`src/journal/queue.zig`); entries the node accepted from clients sit here until slotted. On restart, `Queue.open` replays the file. If any record mid-file fails to decode (bit rot, partial overwrite, torn write beyond the tail), the open path truncates the file at the failure point and **drops every queued entry after it** - including ones that were fsynced before the corruption happened. The store, by contrast, distinguishes a torn tail from mid-file corruption (`findValidRecordAfter`, `store.zig:743`) and refuses mid-file damage with `Corrupt` ([G3](../../glossary.md)).

## Reproduction

Not dynamically reproduced; statically certain. The open loop (queue.zig:90-96) decodes records in order; the first `decodeRecord` error exits the loop and the file is truncated at the current offset. Any record whose bytes are damaged mid-file triggers it; the entries after it are gone.

## Root cause

The queue's open scan has no equivalent of the store's torn-tail handling: it treats every decode failure as "the tail was never acknowledged" and truncates. The doc comment asserts the truncation is safe ("torn tail = unacknowledged") without checking *where* the failure is.

## Resolution

Fixed as suggested: the open scan's break now runs `validRecordAfter`
(a byte-wise scan for any decodable record at or after the break, the
store's own `findValidRecordAfter` pattern). A valid record after the
failure point is mid-file corruption and the open refuses with
`error.Corrupt`; a clean end-of-file after the break is a torn tail and
is truncated as before.

Regression test ("mid-file corruption is refused at open, not truncated
away"): two records, one flipped byte inside the first record's payload
- open now refuses with `Corrupt` instead of silently dropping the
acknowledged second entry. Verified to fail (the old code truncated and
returned success) against the pre-fix scan.

## Verification

- Static: open loop and truncation verified line-by-line; store's torn-tail handling read for comparison.

## Follow-up

None. Related storage-path defect: the segment-ordinal collision after compact (reported separately).

## References

- Code: `src/journal/queue.zig:90-96` (open scan + truncate), `src/journal/store.zig:743` (`findValidRecordAfter`)
- Fix: `src/journal/queue.zig` (open scan + `validRecordAfter`); regression test in the same file. `zig build test` green.
