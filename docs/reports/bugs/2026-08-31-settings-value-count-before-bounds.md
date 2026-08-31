# Bug - `decodeValue` sizes a string_list from a count it has not checked

## TL;DR

- **What failed:** the settings value decoder read a `string_list`'s u16 item
  count out of the first two bytes of the value and allocated for it before
  looking at whether the value could hold that many items.
- **Impact:** a two-byte value claiming 65,535 items committed 65,535
  `[]const u8` slots (about 1 MiB) on a decode that was going to be refused
  on its first iteration. The value decoder runs under every settings
  decode: a `settings` entry, a genesis's initial settings, and a
  `create_journal`'s journal settings.
- **Resolution:** fixed - the value must be at least `2 + count * 2` bytes,
  the minimum the count implies, before anything is allocated.

## Status

Resolved 2026-08-31. Found by reading, while checking whether the sibling
fix in [`decodeChanges`](2026-08-31-settings-count-before-bounds.md) had
covered the whole payload. It had not: that fix bounded the *change* count
one level up and left the *value* count untouched.

## Symptom and impact

A `string_list` value is `count u16` followed by `count` records of
`len u16 | bytes`, so an item is never smaller than two bytes. The decoder
took the count on trust:

```
if (bytes.len < 2) return error.InvalidLength;
const count = std.mem.readInt(u16, bytes[0..2], .little);
const items = try allocator.alloc([]const u8, count);
```

The per-item loop below it bounds-checks properly (`if (off + 2 > bytes.len)
return error.InvalidLength`), so a short value was always going to be
refused - after the allocation, on the first iteration.

The amplification is the finding: two bytes of input decide an allocation of
`count * @sizeOf([]const u8)`, up to 65,535 x 16 = 1,048,560 bytes. It is
bounded - the count is a u16 - so this is a disproportion, not an unbounded
commit, and coppiz's trust model is crash faults and tamper evidence rather
than BFT ([RFC 0009](../../rfcs/0009-trust-model.md)). A corrupted or
truncated payload reaches this path as readily as a hostile one.

`leadership.authorities` is the only `string_list` key in the schema today,
so that is the key a value of this shape has to name to get here.

## Reproduction

`src/settings/schema.zig`, test *a string_list item count is sized against
the body, not trusted from it*: hand `decodeValue` a two-byte value whose
count is `maxInt(u16)`, together with `std.testing.failing_allocator`.

Expected: `error.InvalidLength` - the value cannot hold 65,535 items, and
that is knowable without allocating. Before the fix the failing allocator is
reached first and the answer is `error.OutOfMemory`, which states the defect
precisely: the decoder asked for memory before it had established that the
input was worth any.

The test's second case (`count = 2` with room for one length prefix) pins the
bound rather than only the extreme, so a guard that checks `bytes.len < 2`
twice cannot pass it.

## Root cause

A length prefix was used to size an allocation without first being checked
against the length of the buffer that carried it - the same
count-before-bounds shape as
[2026-08-31-settings-count-before-bounds](2026-08-31-settings-count-before-bounds.md),
one level further in. The two counts are decoded by different functions in
different files (`fold.decodeChanges`, `schema.decodeValue`), which is why
fixing one did not fix the other.

## Resolution

```
const min_bytes = 2 + @as(usize, count) * 2;
if (bytes.len < min_bytes) return error.InvalidLength;
```

before the `alloc`. The count is widened to `usize` so the multiplication
cannot wrap. The refusal is the same `InvalidLength` the per-item loop would
have produced, so no caller sees a new error.

## Verification

- The new test fails on the unpatched decoder with `expected
  error.InvalidLength, found error.OutOfMemory` and passes with the bound.
  Checked by deleting the two guard lines and re-running
  `zig test src/settings/schema.zig`.
- The existing test *decodeValue string_list frees partially-duped items on
  refusal* (count 2, 14-byte value) still reaches its intended item-1
  overrun: `2 + 2 * 2 = 6` is under 14, so the new guard does not shadow it.
- `zig build test` green on the branch.

## Follow-up

None known in this codec. Both settings counts are now bounded before they
are allocated for; the remaining count-before-bounds case recorded in this
store, `framing.readFrame`, was fixed separately
([2026-08-31-frame-body-committed-before-delivery](2026-08-31-frame-body-committed-before-delivery.md)).

## References

- Investigation: none
- Code: `src/settings/schema.zig` (`decodeValue`)
- Related: [2026-08-31-settings-count-before-bounds](2026-08-31-settings-count-before-bounds.md),
  [2026-08-29-decode-value-string-list-leak](2026-08-29-decode-value-string-list-leak.md)
