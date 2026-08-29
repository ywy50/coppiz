# Investigation — the leader encodes each replicated slot twice

## TL;DR

- **Question:** on the leader's write path, how many times is a slot's
  record encoded before it is stored and broadcast, and can one encode serve
  both?
- **Finding:** every leader-authored slot was encoded twice: once by
  `Store.append` for the on-disk record, once by the broadcast's
  `encodeSlot` for the wire — an extra encode and CRC over the same bytes
  per replicated slot, per leader. The wire record is byte-identical to the
  store record by construction (`segment.encodeRecord` is the only encoder),
  and the follower already appends those wire bytes verbatim
  (2026-08-29 sweep item 7).
- **Resolution:** implemented — `slotAndBroadcast` and `appendEpoch` encode
  once and share the bytes between the store write (`applyReplicated`'s
  raw-record path) and the broadcast (`encodeSlotRecord`).

## Status

Resolved and implemented (this PR, stacked as `perf/runtime-sweep-2/1-leader-encode-once`).

## Trigger and scope

The 2026-08-29 runtime sweep deferred this as findings item 16 ("leader
re-encodes for broadcast what it wrote to store ... touches every broadcast
call site; the follower-side win (#7) landed first"). This pass evaluates
and implements it. The same mechanism applies to the checkpoint broadcast
(`driveCheckpoints`) and the merge re-slot broadcasts, which are periodic /
rare; they are noted as follow-ups, not changed here.

## Evidence

All observations are reads of the tree at `main` @ `527068e`, verified
before implementation.

1. **Two encodes per leader slot.** `slotAndBroadcast`
   (`node.zig:1665-1689`) called `applyReplicated(..., null)`, whose
   `store.append` encodes the record (`store.zig:283-300`), then
   `broadcastToMembers` → `message.encode` → `encodeSlot`
   (`message.zig:337-341`), which re-encodes the same `sl`/`en`
   (`segment.encodeRecord` — one CRC pass over the whole record). Same shape
   in `appendEpoch` (`node.zig:1717-1750`).
2. **The two byte streams are identical.** `store.append` and `encodeSlot`
   both call `segment.encodeRecord(sl, en, buf)` on the same values; the
   follower's `decodeSlot` hands the received record to
   `applyReplicated(..., record)` → `Store.appendRecord`, which writes them
   verbatim — so the wire bytes *are* the on-disk form, and reusing one
   encode on the leader changes neither.
3. **The message already carries the record.** `SlotMsg.record`
   (`message.zig:327-333`) is the raw record bytes; every broadcast call
   site passes `&.{}` (empty), and `message.encode`'s slot branch ignores it
   and re-encodes.

## Hypotheses and tests

- **Hypothesis A — one encode can serve store and wire.** If the leader
  encodes first, `applyReplicated(..., record)` writes those bytes to the
  store, and the broadcast copies them (a `len | crc`-aware
  `encodeSlotRecord`). *Result:* supported — byte-identical output on both
  paths, verified by reading; the change removes exactly one
  `segment.encodeRecord` (and its CRC) per leader-authored slot.
- **Hypothesis B — all other broadcast call sites are unaffected.** The
  `message.encode` slot branch falls back to `encodeSlot` when
  `record.len == 0` (the `&.{}` default). *Result:* supported — only
  `slotAndBroadcast` and `appendEpoch` pass a non-empty record.

## Finding

The leader's write path encoded the same record twice; the second encode is
pure overhead that the wire/disk formats make unnecessary. The fix is a
same-semantics refactor: identical bytes on the wire and on disk, and the
follower path is untouched (it already appends the wire bytes verbatim).

## Resolution or handoff

- `message.encodeSlotRecord` (`message.zig:343-350`) copies a pre-encoded
  record into the slot message; `message.encode` uses it when
  `record.len > 0`, else the existing `encodeSlot` (all other call sites
  unchanged).
- `slotAndBroadcast` and `appendEpoch` encode the record once, pass it to
  `applyReplicated` (raw store append) and to `broadcastToMembers`.

Verification: `zig build` clean; the full gate and direct test-binary runs
are recorded in the stack's final verification (this PR's broadcast change
is exercised by every cluster e2e test — G4, G6, the partition/merge tests).

## References

- Code: `src/cluster/node.zig` (`slotAndBroadcast`, `appendEpoch`),
  `src/net/message.zig` (`encodeSlot`, `encodeSlotRecord`, `encode`)
- Sweep: [2026-08-29 runtime speedup sweep findings](2026-08-29-runtime-sweep-findings.md)
  (item 16), [write-path data flow](2026-08-29-runtime-sweep-queue-wire.md)
  (item 7, the follower-side raw append this builds on)
- Follow-up: the checkpoint broadcast (`driveCheckpoints` → the
  `checkpointForBroadcast` result) and the merge re-slot broadcasts still
  re-encode; periodic/rare, noted here for completeness.
