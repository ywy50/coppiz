# Bug - three wire decoders orphan their first allocation when the second one fails

## TL;DR

- **What failed:** `decodeAppend`, `decodeReadPage` and `decodeSettings` each
  returned a struct literal holding two `try allocator.dupe` calls. Zig
  evaluates a literal's fields in written order, so a second `dupe` that
  returns `error.OutOfMemory` leaves the first allocation with nothing
  holding it and nothing freeing it.
- **Impact:** a leak on the decode error path. Latent for the two live
  callers, which decode through an arena that reclaims it, and real for any
  other caller of the public `message.decode` - `decodeReadPage`'s first
  allocation is a whole page of records, up to a frame, stranded by a
  refusal string of a few bytes.
- **Resolution:** fixed - each pair is hoisted out of the literal with an
  `errdefer` on the first, which is what `decodeSlot` and `decodeMembersPage`
  in the same file already did.

## Status

Resolved 2026-08-31.

## Symptom and impact

`src/net/message.zig`, before the fix, three times:

```zig
return .{
    .next = readPosition(bytes[0..16]),
    .records = try allocator.dupe(u8, bytes[20..off]),    // succeeds
    .refusal = try allocator.dupe(u8, bytes[off + 2 ..]),  // OOM -> records leaks
};
```

The other two decoders in the same file that allocate more than once do carry
the guard - `decodeSlot` has `errdefer allocator.free(record)` and
`decodeMembersPage` frees the addresses it has already duped - so this is a
divergence from the file's own established shape rather than a missing
convention.

**Reachability, stated plainly.** Both production callers hand `decode` an
arena: `onFrame` in `src/cluster/node.zig` (`defer arena.deinit()`) and
`Client.recv` in `src/net/client.zig`. The arena reclaims the orphan, so no
shipped path leaks today. `message.decode` is public API on a public module,
`Append.deinit`/`ReadPage.deinit`/`Settings.deinit` document the parts as
owned after decode, and the file's own tests decode through
`std.testing.allocator` - so the guarantee the signature makes is the one
that was broken, and the tests are where it shows.

`decodeReadPage` is the worst of the three by size: `records` is bounded only
by `framing.max_body_bytes` (17 MiB), and the allocation that can strand it
is a refusal name - `""` on success, a short identifier otherwise.

## Reproduction

Deterministic, in the pure codec. The test
`a decoder that fails part-way frees what it had already taken` in
`src/net/message.zig` encodes one message of each of the three kinds with
both fields non-empty, then decodes it through
`std.testing.FailingAllocator` with `fail_index = 1` - the second allocation:

```zig
var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 1 });
try std.testing.expectError(error.OutOfMemory, decode(failing.allocator(), buf));
try std.testing.expectEqual(failing.allocations, failing.deallocations);
```

- Expected: the decode fails and the allocator's counters balance.
- Actual (before the fix): `deallocations` is 0 against `allocations` of 1.
  Verified by reverting `decodeSettings` alone on this branch and running the
  `src/root.zig` test binary: `expected 1, found 0`, 258 passed, 1 failed.

`std.testing.allocator`'s own leak check does not catch this, because the
failing allocator wraps it and the wrapper's counters are what diverge.

## Root cause

`try` inside a struct literal has no place to put an `errdefer`. The literal
is not a scope, and the allocations it makes are not owned by anything until
the literal itself is complete, so the first one is unreachable the moment
the second fails.

## Resolution

Each decoder allocates into a local, registers `errdefer allocator.free(...)`
on it, allocates the second, and only then builds the literal. Nothing else
about the decoders changed: the same bytes are validated in the same order
and the same errors are returned.

## Verification

`zig build test` (the merge gate: unit tests plus the fmt, 100-column,
test-registration, refAllDecls-pairing and gate-coverage lint gates), green.

The new test asserts both counter pairs (`allocations`/`deallocations` and
`allocated_bytes`/`freed_bytes`) and, so the assertion cannot be vacuously
satisfied by a decode that allocated nothing, that exactly one allocation
happened.

## Follow-up

Every other decoder in the file allocates at most once, or already carries
its guard; `decodeMembersPage`'s `done`-counted `errdefer` and `decodeSlot`'s
single `errdefer` were checked and are correct. Nothing else changed.

## References

- Investigation: none
- Code: `src/net/message.zig` (`decodeAppend`, `decodeReadPage`,
  `decodeSettings`)
- Related: [2026-08-29 - `decodeValue` string_list leaks already-duped items on its error paths](2026-08-29-decode-value-string-list-leak.md)
  (the same shape in `src/config/local.zig`)
- Fix: this commit
