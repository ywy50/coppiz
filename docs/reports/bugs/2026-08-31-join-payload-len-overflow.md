# Bug - a `join` entry's address length is added in its own u16, so a large value panics every member

## TL;DR

- **What failed:** `membership.decodeJoinPayload` validated its length with
  `50 + addr_len` computed in the `u16` the length prefix was read into. An
  `addr_len` within 50 of the type's maximum overflowed and panicked in Debug
  and ReleaseSafe before the value was ever compared against the record's
  real size.
- **Impact:** the fold of a `join` control entry. Every member folds the same
  bytes with the same rule, and folds them again on replay from disk at
  restart, so one such record aborts every member and the control chain
  cannot be reopened.
- **Resolution:** fixed - the sum is computed in `usize`, and the record is
  refused `InvalidLength`.

## Status

Resolved 2026-08-31. No investigation preceded it; the site was named as
unfixed in an earlier report's *Follow-up* (see below) and confirmed by
reading it.

## Symptom and impact

`src/cluster/membership.zig`:

```zig
const addr_len = std.mem.readInt(u16, bytes[48..50], .little);
if (50 + addr_len != bytes.len) return error.InvalidLength;
```

`readInt(u16, …)` types `addr_len` as `u16`, and the literal `50` coerces to
it, so the addition is a `u16` addition. For `addr_len >= 65_486` the sum
leaves the type: in Debug and ReleaseSafe that is an
`integer overflow` panic, in ReleaseFast a wrapped value that then compares
against `bytes.len` as if it were the real length.

The panic happens inside `applyJoin`, which runs from `chain.applyControl` -
the pure fold rule every member applies to every control record it accepts,
including on `Store.open`'s replay. So the blast radius is not one member
answering one frame: it is every member that ever folds that slot, on every
start.

This is the shape [an earlier report](2026-08-29-entry-decode-payload-len-overflow.md)
fixed for `entry` records and `decodeCreateJournalPayload`. That report's own
text names this site as left over:

> `src/cluster/membership.zig:59` … is not fixed here.

## Reproduction

Deterministic, no cluster needed - the codec is pure:

```zig
var buf: [50]u8 = undefined;
@memset(&buf, 0);
std.mem.writeInt(u16, buf[48..50], std.math.maxInt(u16), .little);
_ = try decodeJoinPayload(std.testing.allocator, &buf);
```

- Expected: `error.InvalidLength` - a 50-byte record cannot carry a 65,535
  byte address.
- Actual (before the fix): `panic: integer overflow` at the length check.

Reaching it over the wire needs a leader-signed record, because
`applyControl` verifies the slot signature and the entry signature before it
decodes the payload. So the actor is a compromised or buggy leader rather
than any peer - which is the trust model coppiz claims
([RFC 0009](../../rfcs/0009-trust-model.md)) - but the consequence is a
cluster-wide abort rather than a lie confined to that leader's own entries,
which is why it is worth refusing rather than trusting.

## Root cause

Length-prefix arithmetic performed in the prefix's own narrow type. The
prefix bounds the *field*, not the sum of the field and the fixed header, and
Zig's integer literals take the type of the other operand. `usize` is the
type the comparison against `bytes.len` needs.

## Resolution

`addr_len` is declared `usize`, so `50 + addr_len` cannot overflow and the
comparison against `bytes.len` decides. Every over-long value is refused
`InvalidLength`, which `applyControl` already maps to a refusal rather than a
crash.

## Verification

`zig build test` (the merge gate: unit tests plus the fmt, 100-column,
test-registration, refAllDecls-pairing and gate-coverage lint gates), green.

The new test `a join payload's address length is refused, not added in its
own u16` in `src/cluster/membership.zig` covers four values: the type's
maximum, the first value whose sum leaves the type (65,486), the last value
that does not (65,485, still refused because the record is 50 bytes), and a
matching value that must still decode - so the check remains a comparison
rather than becoming an unconditional refusal. It panics on the first two
before the fix.

## Follow-up

`joinPayloadLen`/`encodeJoinPayload` still cast `payload.address.len` to
`u16` unchecked. That side is bounded before it is reached - `max_address_len`
is 300 in `src/cluster/node.zig` and the wire's own `Hello.address` is u16 -
so no input reaches it; not changed here.

## References

- Investigation: none
- Code: `src/cluster/membership.zig`
- Related: [2026-08-29 - length-prefix arithmetic computes in the prefix's own narrow type](2026-08-29-entry-decode-payload-len-overflow.md),
  [2026-08-29 - wire length checks compute in the peer's own narrow int type](2026-08-29-wire-length-checks-narrow-int.md)
- Fix: this commit
