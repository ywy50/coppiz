# Bug — `decodeRecord` length-prefix arithmetic overflows u32: a crafted length prefix crashes the process

## TL;DR

- **What failed:** `segment.decodeRecord` computes `record_prefix_len + body_len` in u32; a `body_len ≥ 0xFFFFFFF8` wraps the sum, passes the bounds check, and produces a start > end slice — a panic in Debug/ReleaseSafe, an out-of-bounds read in ReleaseFast.
- **Impact:** Remote crash/DoS from any TCP peer (the prefix is attacker-controlled and the 8 MiB frame cap does not constrain it), plus a local panic on a bit-flipped length prefix in a segment or queue file, instead of the intended `Truncated`/`Corrupt`.
- **Resolution:** Still open. Statically validated; the u32 coercion was verified empirically.

## Status

Open.

## Symptom and impact

`segment.zig:143-147`:

```zig
const body_len = std.mem.readInt(u32, bytes[0..4], .little);
if (body_len < slot.encoded_len) return error.BadCrc;
if (record_prefix_len + body_len > bytes.len) return error.Truncated;   // u32 add wraps
const body = bytes[record_prefix_len .. record_prefix_len + body_len];  // start > end
```

`record_prefix_len` is comptime 8; the add coerces to u32. For `body_len ≥ 0xFFFFFFF8` the sum wraps to ≤ 7, the check passes, and the slice `bytes[8 .. small]` panics (Debug/ReleaseSafe) or reads out of bounds (ReleaseFast). The wire reachability: `decodeSlot` (`message.zig:350`, its own outer length check passes because the *outer* field is honest and the *record-internal* field is not), `onSyncPage` (`node.zig:1964`), the merge-branch decodes (`:2280, :2354`), and the client read path (`client.zig:181`). Locally: `store.read` (`store.zig:312`) and the queue scan (`queue.zig:239`) panic on a corrupted prefix instead of refusing.

Same shape, u16: `decodeCreateJournalPayload` (`chain.zig:999`, `18 + name_len` in u16 — a crafted `name_len ≥ 65518` panics). Distinct from the already-reported *encode*-side name cast.

## Reproduction

Not dynamically reproduced in-tree (needs a crafted frame); the u32 coercion was verified empirically: `8 + 0xFFFFFFF8` in u32 arithmetic panics at runtime in Debug/ReleaseSafe and wraps in ReleaseFast.

## Root cause

The length check and the slice are computed in the same overflowing type instead of widening to `usize` (or checking before adding).

## Resolution

Not yet fixed. Suggested fix: `if (body_len > bytes.len -| record_prefix_len) return error.Truncated;` (or widen the sum to usize) at every decode site — `segment.zig:146`, `queue.zig:239-243`, `store.zig:312`, `chain.zig:999`, `message.zig` slot decode. A regression test should feed a length prefix of `0xFFFFFFF8` and expect `error.Truncated`.

## Verification

- Static: every decode site read; the wrap arithmetic and slice bounds confirmed.
- The overflow semantics were empirically confirmed by the reviewer (Debug panic / ReleaseFast wrap).

## Follow-up

None beyond the fix — this is the same class as the fuzz-test invariant ("untrusted-input decoders get a fuzz test"): a fuzz case covering prefix lengths near `u32::MAX` would have caught it.

## References

- Code: `src/journal/segment.zig:143-147`, `src/journal/queue.zig:239-243`, `src/journal/store.zig:312`, `src/journal/chain.zig:999`, `src/net/message.zig:350`
- Fix: none
