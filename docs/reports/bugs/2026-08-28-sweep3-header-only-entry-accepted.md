# Bug — Header-only (`payload_omitted`) records are accepted as live entries: payload integrity and `max_entry_bytes` are bypassable

## TL;DR

- **What failed:** Any record whose body is exactly `slot + header` with `payload_len > 0` decodes as the compacted shape, and nothing verifies that shape is a genuine checkpoint compaction: the payload hash is skipped for omitted payloads, the size guard checks `payload.len` (0), and the slot's `entry_hash` (which pins the true content) is never cross-checked against the entry.
- **Impact:** A misbehaving peer can deliver payload-stripped records (or forge header-only entries with arbitrary `payload_len`/`payload_hash`) that every fold accepts as live: payloads silently vanish, and the `max_entry_bytes` cap is bypassed.
- **Resolution:** Still open. Statically validated (corroborated by two independent reviews).

## Status

Open.

## Symptom and impact

The compacted shape is detected purely from the record's byte length (`segment.zig:151-156`, `entry.zig:211-225`: `bytes.len == header_len and payload_len > 0`). Three guards all pass for a stripped entry:

- `checkEntrySignature` (`chain.zig:471-475`) skips the payload-hash comparison when `payload_omitted` ("bytes are gone by design" — true for checkpoint compactions, but nothing checks this was a checkpoint).
- `applyData`'s `TooLarge` check uses `en.payload.len` (0), not `en.payload_len` (`chain.zig:413`) — a header claiming `payload_len = 0xFFFFFFFF` sails through.
- **No code cross-checks `sl.entry_hash` against `entry.entryHash(en)`** (grep: the field is written at slot creation, `node.zig:1703`/`journal.zig:480`, and never verified in `applyControl`/`applyData`/the reslotted paths). The slot's `entry_hash` pins the true content; the fold never reads it against the entry.

A peer that has seen an entry's header+slot can strip the payload (both remain signature-valid — the signature covers the header, which keeps `payload_len`/`payload_hash` unchanged), recompute the record CRC, and deliver it; receivers accept it as a new entry, store it durably, and serve an empty payload forever (later full copies are skipped as redeliveries, `node.zig:1980-1986`). Legit compaction is only safe incidentally (the checkpoint precedes it in chain order); the codec has no way to distinguish.

## Reproduction

Not dynamically reproduced (needs a misbehaving peer); statically certain. The acceptance path: `onSyncPage` (`node.zig:1968`) and `journal.zig:574` apply such records; nothing in `applyControl`/`applyData`/`applyControlReslotted` rejects the shape.

## Root cause

The compacted shape's legitimacy is inferred from the record shape alone, and the one field that could pin it (the slot's `entry_hash`) is never validated against the entry.

## Resolution

Not yet fixed. Suggested direction: verify `sl.entry_hash == entry.entryHash(en)` in the fold (this alone rejects stripped records — the hash includes the payload), and/or check `payload_len` against `max_entry_bytes` even for omitted payloads. A regression test should deliver a payload-stripped record for an unknown entry and expect a refusal.

## Verification

- Static: `entry.decode` shape detection, `checkEntrySignature` skip, `TooLarge` on `payload.len`, and the absence of any `sl.entry_hash` cross-check (grep across `src/`) all verified.

## Follow-up

The same gap weakens the compaction invariant: a stripped record persisted as "live" is indistinguishable from a checkpoint-compacted one on reopen.

## References

- Code: `src/journal/segment.zig:151-156`, `src/journal/entry.zig:211-225`, `src/journal/chain.zig:413, 471-475`, `src/cluster/node.zig:1968, 1980-1986`, `src/journal/journal.zig:574`
- Fix: none
