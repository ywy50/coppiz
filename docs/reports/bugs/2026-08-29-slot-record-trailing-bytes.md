# Bug - a `slot` whose record carries trailing junk decodes as valid, and the follower's fold advances past the store write that refuses it

## TL;DR

- **What failed:** `message.decodeSlot` checked the payload's own length
  prefix but never checked that the record inside it *ended* where the
  payload ends. `segment.decodeRecord` reads the record's own length prefix
  and ignores everything after it, so a valid record with bytes appended
  decoded as a valid slot message.
- **Impact:** `SlotMsg.record` is the slice `Node.applyReplicated` hands to
  `Store.appendRecord` verbatim. That call refuses a slice longer than its
  length prefix with `error.BadRecord` - but only after the fold has already
  applied the slot, and `ClusterNode.onSlot` swallows the error. The
  follower's in-memory fold ends one slot ahead of its store.
- **Resolution:** Fixed. `decodeSlot` now requires
  `rec.next_offset == record.len` and returns `error.InvalidLength`
  otherwise.

## Status

Resolved.

## Symptom and impact

`src/net/message.zig`, before the fix:

```zig
const rec_len: usize = std.mem.readInt(u32, bytes[1..5], .little);
if (5 + rec_len != bytes.len) return error.InvalidLength;
const record = try allocator.dupe(u8, bytes[5..]);
errdefer allocator.free(record);
const rec = segment.decodeRecord(record) catch return error.InvalidValue;
```

`rec_len` is the sender's number. It is checked against the frame, not
against the record: set it to `recordSize + 3` and append three bytes, and
both the frame check and the record check pass. `segment.decodeRecord`
returns `next_offset` precisely so a caller can tell where the record ended,
and this caller ignored it.

The bytes then travel: `ClusterNode.onSlot` calls
`Node.applyReplicated(jid, &m.sl, &en, m.reslotted, m.record)`
(`src/cluster/node.zig`), which folds first
(`applyControl` / `applyData`) and only then writes:

```zig
if (record) |raw| {
    try self.store.appendRecord(journal_id, sl.position(), raw);
}
```

`Store.appendRecord` re-derives the size from the record's prefix and
refuses a mismatch:

```zig
const size = @as(usize, std.mem.readInt(u32, record[0..4], .little)) +
    segment.record_prefix_len;
if (size != record.len) return error.BadRecord;
```

`onSlot` maps `BadPrevHash` and `OutOfMemory` explicitly and drops
everything else through an `else =>` branch that does nothing, so
`BadRecord` is silent. The fold has the slot, the segment file does not.
That is the same divergence class as
[fold-before-store ordering](2026-08-29-fold-before-store-order.md), reached
from the wire instead of from an I/O error.

Reachability: `onFrame` decodes every frame before `frameAllowed` runs, and
`slot` frames are accepted from any connection whose role is `member`.

## Reproduction

New test in `src/net/message.zig`:
`a slot carrying bytes past the end of its record is refused`. It encodes a
real signed slot message, appends three `0xAA` bytes, and raises the
payload's `rec_len` by three so the frame-level length check still passes.

- Expected: `error.InvalidLength` from `decode`.
- Actual, before the fix: `decode` returns a `SlotMsg`. The failure output
  shows the junk inside the accepted record:

```
expected error.InvalidLength, found .{ .slot = .{ .reslotted = false,
  .record = { 78, 1, 0, 0, ... 104, 105, 170, 170, 170 }, ...
FAIL (TestExpectedError)
0 passed; 0 skipped; 1 failed.
1 tests leaked memory.
```

The leak line is the same defect from the other side: the caller expected an
error, so nobody deinits the message it got instead.

Both halves were run with a filtered root over `src/net/` only
(`zig test src/.tmp_net_root.zig --test-filter "slot carrying"`, temp root
not committed): fails on the pre-fix decoder, passes on the fixed one.

The store half of the impact was confirmed separately with a throwaway test
in `src/journal/store.zig` (not committed): `appendRecord` with a
`recordSize + 3` byte slice returns `error.BadRecord`, and the same bytes
truncated to `recordSize` are accepted.

## Root cause

`segment.decodeRecord`'s contract is "decode *one* record from the start of
this region"; it is written for sequential scanning and reports where the
record ended in `next_offset`. Every other caller uses that: `onSyncPage`
walks `p.records` with `off += rec.next_offset` and slices
`p.records[off .. off + rec.next_offset]` for the store write.
`decodeSlot` was the one caller that passed the whole remaining region and
kept the whole remaining region.

## Resolution

```zig
if (rec.next_offset != record.len) return error.InvalidLength;
```

placed immediately after `decodeRecord`, under the existing `errdefer` that
frees `record`. A slot message is one record and nothing else, so the record
must end at the payload's end. No accepted input changes: for a
well-formed slot, `next_offset` is exactly `record.len` already.

`error.InvalidLength` rather than `error.InvalidValue` because the failure is
a length disagreement, and because `onFrame` treats every decode error the
same way (drop the connection).

## Verification

- New test above; control run confirmed it fails on the pre-fix decoder with
  `TestExpectedError` and passes after.
- The round-trip test `slot round-trips a signed slot with its entry` still
  passes, so the check does not refuse well-formed slots.
- `zig build test` green (see the PR).

## Follow-up

Two related weaknesses are recorded rather than fixed here:

- `onSlot`'s `else => {}` branch swallows every `applyReplicated` error that
  is not `BadPrevHash` or `OutOfMemory`, including `BadRecord`. A fold that
  advanced past a refused store write is not something the member can
  continue from. That is in `src/cluster/node.zig`.
- `applyReplicated` folds before it writes on the replicated path too, so
  any `appendRecord` failure - not only this one - leaves the same
  divergence. `2026-08-29-fold-before-store-order.md` covers the local
  paths.

## References

- Investigation: none
- Code: `src/net/message.zig` (`decodeSlot`), `src/journal/segment.zig`
  (`decodeRecord`, `next_offset`), `src/journal/journal.zig`
  (`applyReplicated`), `src/journal/store.zig` (`appendRecord`),
  `src/cluster/node.zig` (`onFrame`, `onSlot`)
- Related: [2026-08-29-fold-before-store-order.md](2026-08-29-fold-before-store-order.md),
  [2026-08-29-wire-length-checks-narrow-int.md](2026-08-29-wire-length-checks-narrow-int.md)
- Fix: this change
