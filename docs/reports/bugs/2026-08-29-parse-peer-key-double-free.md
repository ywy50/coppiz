# Bug - `parsePeerKey` frees the old `public_key` before validating the new one: a malformed second key is a double-free

## TL;DR

- **What failed:** On a `public_key` line, the parser frees the peer's existing key first, then hex-validates the new value. A malformed second `public_key` (duplicate key, bad length/hex) returns `error.InvalidValue` with the field dangling; the caller's `errdefer config.deinit()` frees it again.
- **Impact:** Double-free/UB on a reachable, non-OOM operator error - a typo'd second key in a `[[peers]]` block. Debug allocators abort; release builds corrupt the heap silently.
- **Resolution:** Fixed in `773af4d` (2026-08-29). Reproduced dynamically before the fix; the regression came from `f401606`, which added the hex check between the free and the dupe. The fix is confirmed present in the tree by the 2026-08-31 audit below.

## Status

Resolved 2026-08-29 (audited 2026-08-31).

## Symptom and impact

The strictness fix for `cmdserve-silent-allowlist-drop` placed the 64-hex validation after the free of the previous value:

```zig
// src/config/local.zig:244-257
if (peer.public_key) |old| allocator.free(old);   // :245 — frees, pointer dangles
const hex = unquote(value);
if (hex.len != 64) return error.InvalidValue;      // :253 — refuses with dangle
for (hex) |c| { if (!std.ascii.isHex(c)) return error.InvalidValue; }  // :254-256
peer.public_key = try allocator.dupe(u8, hex);
```

`Config.deinit` (`local.zig:47-60`) frees `peer.public_key` again. The CLI path (`loadConfig`, `main.zig:120-121`) runs `errdefer cfg.deinit()` on any parse error. The `address` branch (`local.zig:240-242`) has the same free-then-dupe shape, but only OOM at the dupe reaches it; the `public_key` branch's error is a plain operator typo.

## Reproduction

Dynamically reproduced with a throwaway test: `parse` a config with `[[peers]]`, a valid 64-hex `public_key`, then a second `public_key = "bad"`. `parse` returns `error.InvalidValue`; the test's `config.deinit()` aborts (SIGABRT) in `local.zig:50` - the debug allocator's double-free trap. No OOM involved.

## Root cause

Free-before-validate: the field must be re-assigned (or cleared) before any refusal can leave the function with a dangling pointer.

## Resolution

Fixed: `parsePeerKey` validates and dupes the new value before freeing the old one, so a refusal leaves no dangling pointer; regression test covers the duplicate-key-with-malformed-second-value case.

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

Both branches of `parsePeerKey` now dupe into a local `fresh` and free the old
value only afterwards, so no refusal can leave a dangling pointer for
`Config.deinit`; the test *a malformed peer public_key is refused at parse
time* covers it. The follow-up this report named - refusing duplicate keys
outright - landed in the same commit, as
[2026-08-28-sweep3-duplicate-toml-key-leak](2026-08-28-sweep3-duplicate-toml-key-leak.md)
records.

Only the `## TL;DR` resolution bullet, the `## Status` line and the `- Fix:`
reference were corrected; the symptom, reproduction, root cause and resolution
are unchanged.

## Verification

- Dynamic: the repro above aborts in `deinit` as described.
- Static: `Allocator.free`'s empty-slice no-op does not apply here (the pointer is non-null and was freed); the dangling assignment is unambiguous.

## Follow-up

The duplicate-key acceptance (the parser does not reject repeated keys) is what makes the trigger reachable; refusing duplicates outright would also close it.

## References

- Code: `src/config/local.zig:244-257` (`parsePeerKey`), `:47-60` (`Config.deinit`), `src/main.zig:120-121` (`loadConfig`)
- Fix: `773af4d` (PR #90)
