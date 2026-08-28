# Bug — Wire reads silently drop compacted (retain=none) records; the local read shows them as `(removed)`

## TL;DR

- **What failed:** `onReadReq`'s callback does `const e = en orelse return;` — a `retain=none` compacted record (slot-only, no entry) is never encoded into a `read_page`. The same records are served to local reads and rendered `(removed)`.
- **Impact:** `coppiz read`/`coppiz head` over the wire show a position gap with no marker, while the identical read on a locked directory shows `(removed)` — inconsistent output for the same command, with no note (the sync path documents the drop explicitly).
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

`read_page` records are full slot+entry records, and the client's `on_record` supports null entries (`client.zig:183`), as does the local read callback (`journal.zig:756-805` hands `en == null`). The wire path alone skips them (`node.zig:2442`). Under `ttl.retain = none` with enforcement enabled, `coppiz read` over the wire omits the removed positions; `coppiz read` against a locked data dir (local read) renders them `(removed)` (`main.zig:426`).

## Reproduction

Not dynamically reproduced; statically certain. A journal with enforcement + `retain = none` that has compacted entries, served by a running node, read over the wire: the removed slots are absent from the page, and `next` advances past them with no marker.

## Root cause

`onReadReq`'s callback (`node.zig:2440-2448`) returns on `en == null` instead of emitting the slot-only marker the rest of the pipeline already supports. The sync path's comment ("compacted records are not served (OQ 43)", `node.zig:1939`) documents a *different* path; the read path has no equivalent rationale.

## Resolution

Not yet fixed. Suggested direction: encode a slot-only record into the page (or a `(removed)` marker) so wire and local reads agree. A regression test should read over the wire after a `retain = none` compaction and compare with the local read.

## Verification

- Static: `onReadReq` callback read; local read + `printRecord` (`main.zig:426`) read; client null-entry support verified.

## Follow-up

None — output-consistency issue, no data loss.

## References

- Code: `src/cluster/node.zig:2440-2448` (`onReadReq`), `src/net/client.zig:183`, `src/main.zig:426`
- Fix: none
