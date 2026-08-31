# Bug - `decodeValue` string_list leaks already-duped items on its error paths

## TL;DR

- **What failed:** `decodeValue`'s `errdefer allocator.free(items)` frees only the outer array; items dupe'd before a failure (OOM mid-loop, `InvalidLength`, or trailing garbage) leak.
- **Impact:** Refusal-path leak only - a malformed settings entry leaks `count × len` bytes on every member that decodes it while refusing.
- **Resolution:** Fixed in `773af4d` (2026-08-29). Statically validated; the fix is confirmed present in the tree by the 2026-08-31 audit below.

## Status

Resolved 2026-08-29 (audited 2026-08-31).

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

## Correction - what the 2026-08-31 audit checked

`8893ae1` ("docs(reports): mark the sweep fixes resolved", 2026-08-29) flipped
this report's `## Status` to `Resolved` and rewrote its `## Resolution` in a
commit that touched 29 report files and no source. It left the `## TL;DR`
resolution bullet reading "Still open" and the `- Fix:` reference reading
"none", so the record contradicted itself and gave a reader no way to tell
whether the fix existed. Five other reports flipped by that commit were
audited on 2026-08-31 and found to have no fix in the tree at all.

This one does. Audited 2026-08-31 by reading the shipped code and the history
of the symbol the resolution credits. The fix landed in `773af4d`, whose
subject ("fix(wire): a read of an unknown journal refuses with a named error
(#90)") names only the last of the twelve fixes it carries. `8893ae1` has that
commit as an ancestor, so its status flip was right - only the two metadata
lines were left behind.

`decodeValue`'s `string_list` arm keeps a `filled` counter and its `errdefer`
frees `items[0..filled]` before the outer array; the test *decodeValue
string_list frees partially-duped items on refusal* covers it. A separate
defect in the same block - the item count being trusted to size the allocation
before any bounds check - was found and fixed independently in `156f69b` (PR
#206) and is recorded as
[2026-08-31-settings-value-count-before-bounds](2026-08-31-settings-value-count-before-bounds.md).
That is a sibling, not this leak: the two guards sit three lines apart and
neither implies the other.

Only the `## TL;DR` resolution bullet, the `## Status` line and the `- Fix:`
reference were corrected; the symptom, reproduction, root cause and resolution
are unchanged.

## Verification

- Static: errdefer scope read; the `Value.clone` pattern (`schema.zig:326-338`) read as the intended shape.

## Follow-up

None. Low priority (refusal paths).

## References

- Code: `src/settings/schema.zig:465-483` (`decodeValue`)
- Fix: `773af4d` (PR #90)
