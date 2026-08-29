# Bug - `parsePeerKey` frees the old `public_key` before validating the new one: a malformed second key is a double-free

## TL;DR

- **What failed:** On a `public_key` line, the parser frees the peer's existing key first, then hex-validates the new value. A malformed second `public_key` (duplicate key, bad length/hex) returns `error.InvalidValue` with the field dangling; the caller's `errdefer config.deinit()` frees it again.
- **Impact:** Double-free/UB on a reachable, non-OOM operator error - a typo'd second key in a `[[peers]]` block. Debug allocators abort; release builds corrupt the heap silently.
- **Resolution:** Still open. Reproduced dynamically. Fix regression introduced by `f401606` (the hex check was added between the free and the dupe).

## Status

Resolved.

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

## Verification

- Dynamic: the repro above aborts in `deinit` as described.
- Static: `Allocator.free`'s empty-slice no-op does not apply here (the pointer is non-null and was freed); the dangling assignment is unambiguous.

## Follow-up

The duplicate-key acceptance (the parser does not reject repeated keys) is what makes the trigger reachable; refusing duplicates outright would also close it.

## References

- Code: `src/config/local.zig:244-257` (`parsePeerKey`), `:47-60` (`Config.deinit`), `src/main.zig:120-121` (`loadConfig`)
- Fix: none
