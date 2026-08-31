# Bug - An accepted append between ~8 MB and 16 MB can never be replicated: broadcast, sync and read all exceed the frame bound

## TL;DR

- **What failed:** `journal.max_entry_bytes` defaults to 16 MB but the wire frame cap is 8 MB (`framing.max_body_bytes`). A payload in (≈8 MB, 16 MB] is accepted and slotted, then every replication path fails: the slot broadcast is dropped, sync pages and wire reads close the connection, and a joiner's backfill never completes.
- **Impact:** Accepted appends that no member ever receives (leader-side acked but replicated to nobody; follower-side clients hang unacked); a follower that misses the broadcast enters an infinite reconnect loop; backfill never terminates; `coppiz read` over the wire fails while the local read works.
- **Resolution:** Fixed. Re-verified in the tree 2026-08-31: the frame cap clears the 16 MiB `max_entry_bytes` default by 1 MiB, and `validateState` refuses a setting that would not fit a frame.

## Status

Resolved.

**Verified in the tree 2026-08-31.** This record was one of the 29 flipped
to `Resolved` by `8893ae1` ("docs(reports): mark the sweep fixes resolved
(#116)"), a commit that touched 29 report files and no source file, and it
kept a TL;DR reading "Still open" and a `Fix: none` reference line. Both
were stale, not evidence: the fix is present.

`framing.max_body_bytes` is `16 * 1024 * 1024 + 1024 * 1024` and names this
report in its doc comment; `validate.zig` refuses `journal.max_entry_bytes >
max_body_bytes - 4096`, with the test "max_entry_bytes must leave room for
the record in a frame" naming this report.

## Symptom and impact

Size facts: `framing.max_body_bytes = 8 MiB` (`framing.zig:25`); `journal.max_entry_bytes` default 16 MiB (`schema.zig:66`); record size ≈ `348 + payload.len` (segment 59 + slot 25 + entry 34 + payload). A payload in (8 MiB − 348, 16 MiB] passes every accept check:

- `onAppend` checks only the 16 MiB fold setting; the queue bound (64 MiB) also passes.
- **Broadcast:** the slot body is `2 + 1 + 4 + recordSize` ≈ 9 MiB for a 9 MiB payload → `writeFrame` returns `OversizedFrame` → `broadcastToMembers` swallows it (`catch {}`, `node.zig:1139`). No member receives the slot; a follower-side client's forward is never acked (`pending_clients` waits forever - no `peer_gone`, no `reforwardQueue`).
- **Sync:** `onSyncReq`'s "first record is always encoded" rule (`node.zig:1115-1130`) puts the big record into the page regardless of `max_bytes` → page exceeds 8 MiB → `sendMessage` fails → `onFrame` closes the conn (`node.zig:619`) → the requester redials and re-requests the same page forever.
- **Backfill:** a joiner over such a journal stays `syncing` forever.
- **Read:** `coppiz read` of the journal over the wire hits the same oversized frame and the conn closes.

## Reproduction

Not dynamically reproduced (needs a multi-member cluster and a ~9 MiB append); statically certain from the sizes and the swallow/close paths.

## Root cause

The accept bound (16 MiB fold setting) and the wire bound (8 MiB frame) are not reconciled. The fold cannot even represent a record larger than the frame.

## Resolution

Fixed: the frame cap now clears the 16 MiB `max_entry_bytes` default plus record overhead, and `validateState` refuses a `max_entry_bytes` that leaves no room in a frame.

## Verification

- Static: size arithmetic verified (`framing.zig:25,31,48`; `schema.zig:66,174`; record sizes); the swallow at `node.zig:1139` and the close at `:619` verified by reading.

## Follow-up

The frame cap is also the floor for the sync-page "first record always encoded" rule - a page that must contain an oversized record can never be served.

## References

- Code: `src/net/framing.zig:25,31,48`, `src/settings/schema.zig:66,174`, `src/cluster/node.zig:1115-1130, 1132-1141, 1552-1590`, `src/net/transport.zig:31` (`OversizedFrame`)
- Fix: in the tree - `src/net/framing.zig` `max_body_bytes`; `src/settings/validate.zig` (the `max_entry_bytes` room check and its test)
