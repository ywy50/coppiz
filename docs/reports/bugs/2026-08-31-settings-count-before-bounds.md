# Bug - `decodeChanges` sizes its allocation from a count it has not checked

## TL;DR

- **What failed:** `decodeChanges` read a u16 change count out of the first
  two bytes of a settings payload and allocated for it before looking at
  whether the body could hold that many changes.
- **Impact:** a two-byte body claiming 65,535 changes committed 65,535
  `validate.Change` slots, on a decode that was going to be refused on its
  first iteration. The decode runs on `settings` entries, a genesis's
  initial settings and a `create_journal`'s journal settings.
- **Resolution:** fixed - the body must be at least `2 + count * 4` bytes,
  the minimum the count implies, before anything is allocated.

## Status

Resolved 2026-08-31. Found by reading; no occurrence in a log is known.

## Symptom and impact

The change list is `count u16` followed by `count` records of `key u16 |
vlen u16 | value`, so a change is never smaller than four bytes. The decoder
took the count on trust:

```
const count = std.mem.readInt(u16, bytes[0..2], .little);
const changes = try allocator.alloc(validate.Change, count);
```

The per-change loop below it does bounds-check properly (`if (off + 4 >
bytes.len) return error.InvalidLength`), so a short body was always going to
be refused - after the allocation, on the first iteration.

The amplification is the whole finding: two bytes of input decide an
allocation of `count * @sizeOf(validate.Change)`. It is bounded - the count
is a u16 - so this is a disproportion, not an unbounded commit, and coppiz's
trust model is crash faults and tamper evidence rather than BFT
([RFC 0009](../../rfcs/0009-trust-model.md)). A corrupted or truncated
payload reaches this path as readily as a hostile one.

## Reproduction

`src/settings/fold.zig`, test *a change count is sized against the body, not
trusted from it*: hand `decodeChanges` a two-byte body whose count is
`maxInt(u16)`, together with `std.testing.failing_allocator`.

Expected: `error.InvalidLength` - the body cannot hold 65,535 changes, and
that is knowable without allocating. Before the fix the failing allocator is
reached first and the answer is `error.OutOfMemory`, which is the defect
stated precisely: the decoder asked for memory before it had established
that the input was worth any.

## Root cause

A length prefix was used to size an allocation without first being checked
against the length of the buffer that carried it - the ordinary
count-before-bounds shape.

## Resolution

```
const min_bytes = 2 + @as(usize, count) * 4;
if (bytes.len < min_bytes) return error.InvalidLength;
```

before the `alloc`. The count is widened to `usize` so the multiplication
cannot wrap. The refusal is the same `InvalidLength` the per-change loop
would have produced, so no caller sees a new error.

## Verification

- The test fails on the unpatched decoder with `expected
  error.InvalidLength, found error.OutOfMemory` and passes with the bound.
- `zig build test` green on the branch: `Build Summary: 25/25 steps
  succeeded; 339/339 tests passed`.

## Follow-up

`framing.readFrame` has the same shape at a larger scale: it allocates the
whole declared body, up to `max_body_bytes` (17 MiB), before reading any of
it, so the memory a connection commits tracks what the header claims rather
than what has arrived. Reported separately.
