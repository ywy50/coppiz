# Bug - wire length checks compute in the peer's own narrow int type: an 84-byte hello aborts an unadmitted node

## TL;DR

- **What failed:** Thirteen length validations across `src/net/message.zig` added a peer-supplied `u16` or `u32` length to the message's fixed size, and Zig computed that sum in the *field's* type. A length near the type's maximum overflows.
- **Impact:** In a safe build the decoder aborts the process. `decodeHello` is the worst case: `node.zig`'s `onFrame` decodes every frame before admission runs, so an 84-byte write to any open listen port kills a node with no key, no genesis hash and no allowlist entry. In `ReleaseFast` the sum wraps instead and the malformed body passes the length check.
- **Resolution:** Fixed. Every one of the thirteen length fields is read into a `usize`, so the checks compute in 64 bits and no input can overflow them.

## Status

Resolved.

## Symptom and impact

`src/net/message.zig`, before the fix:

```zig
pub fn decodeHello(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Hello {
    if (bytes.len < 82) return error.InvalidLength;
    const addr_len = std.mem.readInt(u16, bytes[80..82], .little);
    if (82 + addr_len != bytes.len) return error.InvalidLength;
```

`addr_len` is a `u16`. The literal `82` coerces to `u16`, so the sum is `u16`
arithmetic and overflows for any `addr_len >= 65454`.

The reachability is what makes this one serious rather than theoretical.
`ClusterNode.onFrame` calls `message.decode` on every frame the moment it
arrives; `onHello` - which is where the allowlist, the genesis hash and the
member-id derivation are checked - runs afterwards. So the attacker needs only
a TCP connection to the listen port.

The two prior length-overflow reports in this store
([`2026-08-28-sweep3-record-length-overflow.md`](2026-08-28-sweep3-record-length-overflow.md),
[`2026-08-29-entry-decode-payload-len-overflow.md`](2026-08-29-entry-decode-payload-len-overflow.md))
established the rule and fixed the sites they found in `src/journal/`. Neither
swept `src/net/`, and the latter's follow-up names only
`cluster/membership.zig` as the remaining sibling.

## Reproduction

New test `a length field at its type's maximum is refused, not overflowed` in
`src/net/message.zig`. It drives the real `decode` entry point - the same call
`onFrame` makes - with the smallest body each decoder accepts and that body's
length field set to all ones.

- Expected: `error.InvalidLength` from each of the ten kinds that carry a
  length field.
- Actual, before the fix: the first case aborts the test binary with
  `panic: integer overflow`.

Confirmed by a control run: with the fix reverted and the test kept, the gate
fails in this test; with both in place it passes.

## Root cause

`std.mem.readInt(u16, ...)` returns a `u16`, and an untyped integer literal
added to it takes *its* type rather than widening. Every decoder in the file
was written the same way, so the same mistake is at thirteen sites across ten
message kinds:

| Function | Expression | Type | Overflows at |
|---|---|---|---|
| `decodeHello` | `82 + addr_len` | u16 | `addr_len >= 65454` |
| `decodeHelloAck` | `20 + addr_len`, `off + 56` | u16 | `addr_len >= 65460` |
| `decodeAppend` | `2 + name_len`, `payload_off + 12` | u16 | `name_len >= 65522` |
| `decodeAppend` | `payload_off + 4 + payload_len + 8` | u32 | `payload_len >= 0xFFFF_FFF6` |
| `decodeAck` | `42 + refusal_len` | u16 | `refusal_len >= 65494` |
| `decodeForward` | `4 + len` | u32 | `len >= 0xFFFF_FFFC` |
| `decodeSlot` | `5 + rec_len` | u32 | `rec_len >= 0xFFFF_FFFB` |
| `decodeSyncPage` | `36 + rec_len` | u32 | `rec_len >= 0xFFFF_FFDC` |
| `decodeReadReq` | `2 + name_len`, `off + 22` | u16 | `name_len >= 65514` |
| `decodeReadPage` | `20 + rec_len`, `off + 2 + refusal_len` | u32 | `rec_len >= 0xFFFF_FFEC` |
| `decodeSettings` | `2 + name_len`, `off + 4 + changes_len` | u16 / u32 | `name_len >= 65530` |

`decodeMembersPage` is the one decoder in the file that was already right: it
declares `var off: usize = 26`, so every later sum promotes to `usize`.

The in-file fuzz test did not find this. `std.testing.Smith.slice` fills a
512-byte buffer, and the trigger needs a specific two- or four-byte field set
near its type maximum while the surrounding bytes stay in range, which random
bytes reach only by chance.

## Resolution

Each length field is now read into an explicitly `usize` const:

```zig
const addr_len: usize = std.mem.readInt(u16, bytes[80..82], .little);
```

`u16` and `u32` both widen to `usize` without a cast, so no other line changed
and no accepted input decodes differently: the checks are the same comparisons
in an integer type wide enough to hold every sum they can produce. A body whose
declared length exceeds what it carries is still refused as `InvalidLength`,
which is what the callers already handle.

## Verification

- New test above, run through `decode` rather than the individual functions,
  so it exercises the path `onFrame` takes.
- Control: the test fails on the pre-fix arithmetic (integer-overflow panic)
  and passes after.
- `zig build test --summary all` green.

## Follow-up

One related weakness in the same file is **not** fixed here, to keep the
change to one mechanism: `decodeMembersPage` reads a `u16` `count` and
immediately does `allocator.alloc(MemberInfo, count)` before checking that the
body could hold that many members. `MemberInfo` is 48 bytes, so a 26-byte frame
can force a ~3.1 MiB allocation - about 120,000x amplification, repeatable per
frame. The `errdefer` frees correctly, so it is bounded churn and not a leak,
but the cheap guard (`26 + count * 34 > bytes.len`) that every sibling decoder
has is missing.

## References

- Code: `src/net/message.zig` (ten `decode*` functions), `src/cluster/node.zig` (`onFrame`, the caller that decodes before admission)
- Prior reports on the same mechanism elsewhere: [`2026-08-28-sweep3-record-length-overflow.md`](2026-08-28-sweep3-record-length-overflow.md), [`2026-08-29-entry-decode-payload-len-overflow.md`](2026-08-29-entry-decode-payload-len-overflow.md)
- Fix: this change
