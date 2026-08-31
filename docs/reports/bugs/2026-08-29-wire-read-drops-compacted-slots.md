# Bug - Wire reads silently drop compacted (retain=none) records; the local read shows them as `(removed)`

## TL;DR

- **What failed:** `onReadReq`'s callback does `const e = en orelse return;` - a `retain=none` compacted record (slot-only, no entry) is never encoded into a `read_page`. The same records are served to local reads and rendered `(removed)`.
- **Impact:** `coppiz read`/`coppiz head` over the wire show a position gap with no marker, while the identical read on a locked directory shows `(removed)` - inconsistent output for the same command, with no note (the sync path documents the drop explicitly).
- **Resolution:** Still open. Statically validated.

## Status

Reopened 2026-08-31. `8893ae1` set this to `Resolved.` in a docs-only commit;
the TL;DR and References below were left reading "Still open" and `Fix: none`,
and they were the accurate half. The behaviour is unchanged: the arms that were
supposed to render a compacted slot over the wire cannot run, because
`readWhere` drops slot-only records before any callback fires. So
`onReadReq`'s slot-only arm and `printRecord`'s `(removed)` arm are both dead
code, and a wire read still shows an unmarked position gap where a local read
shows `(removed)`.

Fixing it needs a decision that is not yet made - may a read show a removed
slot at all? PRD 0002 G5 and this report point opposite ways - so it is
recorded rather than patched. See
[the 2026-08-31 investigation](../investigations/2026-08-31-wire-and-local-reads-still-disagree.md),
which also covers `coppiz head`'s wire/local divergence, and RFC 0018.

## Symptom and impact

`read_page` records are full slot+entry records, and the client's `on_record` supports null entries (`client.zig:183`), as does the local read callback (`journal.zig:756-805` hands `en == null`). The wire path alone skips them (`node.zig:2442`). Under `ttl.retain = none` with enforcement enabled, `coppiz read` over the wire omits the removed positions; `coppiz read` against a locked data dir (local read) renders them `(removed)` (`main.zig:426`).

## Reproduction

Not dynamically reproduced; statically certain. A journal with enforcement + `retain = none` that has compacted entries, served by a running node, read over the wire: the removed slots are absent from the page, and `next` advances past them with no marker.

## Root cause

`onReadReq`'s callback (`node.zig:2440-2448`) returns on `en == null` instead of emitting the slot-only marker the rest of the pipeline already supports. The sync path's comment ("compacted records are not served (OQ 43)", `node.zig:1939`) documents a *different* path; the read path has no equivalent rationale.

## Resolution

Fixed: `onReadReq` encodes slot-only markers for `retain = none` compacted slots, so wire reads render them like the local read's `(removed)` rows.

## Verification

- Static: `onReadReq` callback read; local read + `printRecord` (`main.zig:426`) read; client null-entry support verified.

## Follow-up

None - output-consistency issue, no data loss.

## References

- Code: `src/cluster/node.zig:2440-2448` (`onReadReq`), `src/net/client.zig:183`, `src/main.zig:426`
- Fix: none. Still none as of 2026-08-31 - see Status.
- Investigation: [2026-08-31 - the wire read and the local read still disagree, and one recorded fix cannot run](../investigations/2026-08-31-wire-and-local-reads-still-disagree.md)
