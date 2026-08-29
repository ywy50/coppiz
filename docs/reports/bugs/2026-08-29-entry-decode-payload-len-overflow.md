# Bug - length-prefix arithmetic computes in the prefix's own narrow type: a peer-chosen `payload_len` panics the decoder

## TL;DR

- **What failed:** Six length checks add an untyped constant to a `u32`/`u16` length read off the wire or off disk. Zig resolves the literal *down* to the narrow peer type, so the sum is computed in `u32`/`u16` and a length near that type's maximum overflows it - a panic in Debug/ReleaseSafe, a wrap past the bounds check in ReleaseFast.
- **Impact:** `entry.decode` and `chain.decodeCreateJournalPayload` sit behind the replication wire, so one frame from any peer aborts the receiving node. The four remaining sites are reached from a corrupt queue or segment file.
- **Resolution:** Fixed - every site widens the length to `usize` before adding.

## Status

Resolved.

## Symptom and impact

The already-fixed [`2026-08-28-sweep3-record-length-overflow`](2026-08-28-sweep3-record-length-overflow.md)
closed this exact hazard in `segment.decodeRecord` and left a comment naming
the mechanism. The same shape survived in six other places:

| Site | Expression | Narrow type |
|---|---|---|
| `src/journal/entry.zig` `decode` | `bytes.len != header_len + payload_len` | u32 |
| `src/journal/chain.zig` `decodeCreateJournalPayload` | `18 + name_len > bytes.len` | u16 |
| `src/journal/queue.zig` `scanRecord` | `record_prefix_len + body_len > bytes.len` | u32 |
| `src/journal/store.zig` `appendRecord` | `record_prefix_len + readInt(u32, ...)` | u32 |
| `src/journal/store.zig` `read` | `record_prefix_len + body_len` | u32 |
| `src/journal/store.zig` `firstRecordKind` | `record_prefix_len + body_len` | u32 |
| `src/journal/journal.zig` `storeRecordSizeFor` | `8 + slot.encoded_len + entry.header_len + info.payload_len` | u32 |

`entry.decode` is the one that a remote peer reaches unaided.
`message.decodeSlot` (`src/net/message.zig:361`) hands every broadcast slot to
`segment.decodeRecord`, which - after its own (now safe) bounds check - calls
`entry.decode` on the record's entry region. A record whose body is 333 bytes
or more gives `entry.decode` at least 165 bytes, so the compacted
header-only branch is skipped and the `header_len + payload_len` comparison
runs with a `payload_len` the sender chose. At `0xFFFF_FFFF` the sum
overflows `u32` and the member aborts.

`chain.decodeCreateJournalPayload` is reached from `applyControl` on any
`create_journal` a member folds, and again from `Node.applyReplicated`; a
`name_len` of `0xFFFF` overflows the `u16` sum before the fold's 256-byte
`max_journal_name` rule ever runs.

## Reproduction

The arithmetic rule is demonstrable on its own:

```zig
const header_len = 164;
fn f(bytes_len: usize, payload_len: u32) bool {
    return bytes_len != header_len + payload_len;
}
// @TypeOf(header_len + @as(u32, 1)) == u32; f(200, 0xFFFF_FFFF) panics:
// "integer overflow" at the `+`.
```

Run under `zig 0.16.0 test`, that program aborts with `thread ... panic:
integer overflow` pointing at the `+`. The regression tests added with the fix
drive the same input through the real decoders:

- `entry.zig` - "a payload_len near max u32 is refused, not an overflowing sum"
- `chain.zig` - "a create_journal name_len near max u16 is refused, not an overflowing sum"
- `queue.zig` - "a queue record length near max u32 is Truncated, not a wrap-around slice"

Each fails with a panic before the fix and returns the named refusal after it.

## Root cause

Zig resolves `comptime_int + u32` to `u32`: the peer type of the *addition*
is decided by the addition's own operands, not by the `usize` the result is
later compared to or returned as. Every constant here (`header_len`,
`record_prefix_len`, the literal `18`, the literal `8`) is an untyped
declaration, so each sum inherits the narrow type of the length field it is
added to. Where the check is `sum > bytes.len`, the wrap also makes the check
pass, so ReleaseFast slices with a start past its end instead of aborting.

## Resolution

Every site widens the untrusted length with `@as(usize, ...)` before adding,
and the check and the subsequent slice both use that `usize` value - the same
shape `segment.decodeRecord` already used. No refusal name changes: an
over-long entry record is still `Truncated`, an over-long `create_journal`
payload is still `InvalidLength`, an over-long queue record is still
`Truncated`.

## Verification

- `zig build test` green on the branch (unit tests plus the fmt, 100-column,
  test-registration, refAllDecls and gate-coverage lint gates).
- The three regression tests above fail with an integer-overflow panic when
  reverted onto the unfixed decoders.

## Follow-up

`src/cluster/membership.zig:59` (`if (50 + addr_len != bytes.len)`) has the
same `u16` shape in the join-payload decoder. It is outside this change's
scope and is not fixed here.

## References

- Investigation: none
- Code: `src/journal/entry.zig` (`decode`), `src/journal/chain.zig`
  (`decodeCreateJournalPayload`), `src/journal/queue.zig` (`scanRecord`),
  `src/journal/store.zig` (`appendRecord`, `read`, `firstRecordKind`),
  `src/journal/journal.zig` (`storeRecordSizeFor`)
- Prior art: [2026-08-28-sweep3-record-length-overflow](2026-08-28-sweep3-record-length-overflow.md)
