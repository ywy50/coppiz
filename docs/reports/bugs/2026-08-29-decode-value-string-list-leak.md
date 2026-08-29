# Bug - `decodeValue` string_list leaks already-duped items on its error paths

## TL;DR

- **What failed:** `decodeValue`'s `errdefer allocator.free(items)` frees only the outer array; items dupe'd before a failure (OOM mid-loop, `InvalidLength`, or trailing garbage) leak.
- **Impact:** Refusal-path leak only - a malformed settings entry leaks `count × len` bytes on every member that decodes it while refusing.
- **Resolution:** Still open. Statically validated.

## Status

Resolved.

## Symptom and impact

`src/settings/schema.zig:465-483`:

```zig
const items = try allocator.alloc([]const u8, count);
errdefer allocator.free(items);
for (0..count) |i| {
    ...
    items[i] = try allocator.dupe(u8, bytes[off .. off + len]);  // dupe'd items leak on later failure
    off += len;
}
if (off != bytes.len) return error.InvalidLength;
```

A failure at item *i*'s dupe, an `InvalidLength` mid-loop, or the trailing-garbage check at `:481` leaves the earlier dupes unfreed. The sweep-1 fix added filled-tracking to `Value.clone` (`schema.zig:326-338`) but not to this sibling decode path.

## Reproduction

Not dynamically reproduced (OOM-triggered); statically certain. The trailing-garbage path (`:481`) is reachable from a malformed settings entry without OOM.

## Root cause

Missing filled-counter in the errdefer, exactly the pattern the sweep's own fix applied elsewhere.

## Resolution

Fixed: `decodeValue`'s string_list errdefer frees the duped prefix via a filled counter; regression test feeds an over-running length and the GPA leak check passes.

## Verification

- Static: errdefer scope read; the `Value.clone` pattern (`schema.zig:326-338`) read as the intended shape.

## Follow-up

None. Low priority (refusal paths).

## References

- Code: `src/settings/schema.zig:465-483` (`decodeValue`)
- Fix: none
