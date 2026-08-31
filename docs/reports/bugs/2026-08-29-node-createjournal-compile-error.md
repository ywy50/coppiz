# Bug - `Node.createJournal` is a dead public API with a latent compile error

## TL;DR

- **What failed:** `journal.Node.createJournal` (pub) reads `group_id.entry_hash` on a `[32]u8` - a compile error that no build gate catches, because nothing calls the function and the gate's `refAllDecls` does not analyze method bodies.
- **Impact:** The first host (PRD 0005: the library is the product) that calls the documented journal-creation API gets a build failure. Meanwhile the error is invisible in every gate run.
- **Resolution:** Fixed in `8c00ae8`. Originally validated statically.

## Status

Resolved.

## Symptom and impact

`src/journal/journal.zig:273-303`:

```zig
pub fn createJournal(self: *Node, name: []const u8, initial: []const validate.Change) ![16]u8 {
    ...
    const group_id = self.group_hash;                  // [32]u8 (journal.zig:90)
    try self.appendControl(.create_journal, payload, &self.control);
    try self.store.createJournal(journal_id, group_id.entry_hash);  // :296 — no such field
    ...
}
```

`[32]u8` has no `entry_hash` member; any compilation that analyzes the body fails with a field-access error. No code in `src/`, `examples/`, or `main.zig` calls it (grep-verified), and the registration gate's `refAllDecls` (`root.zig`) references top-level declarations without recursing into `Node`'s methods, so the body is never analyzed and every gate stays green. The correct call shape is visible at `journal.zig:601` (`self.store.createJournal(journal_id, self.group_hash)`).

## Reproduction

Not reproduced in-tree (the function is unreferenced); statically certain: the field access on a `[32]u8` is a compile error, and grep confirms zero callers. A trivial standalone (`var g: [32]u8 = undefined; _ = g.entry_hash;`) fails to compile.

## Root cause

A field-access typo in a never-analyzed method. The gate coverage that catches dead modules does not catch dead *methods*.

## Resolution

Fixed: `Node.createJournal` passes `group_hash` directly (the `.entry_hash` field access on a `[32]u8` was a compile error no gate analyzed); a new test calls the method, forcing its body through analysis and checking the journal registers and survives reopen.

## Verification

- Static: `group_hash` typed `[32]u8` (`journal.zig:90`); `.entry_hash` does not exist on it; no callers found.

## Follow-up

None beyond the fix. Worth noting for the gate design: `refAllDecls` covers declarations, not method bodies of dead APIs.

## References

- Code: `src/journal/journal.zig:273-303` (`createJournal`), `:90` (`group_hash` type), `:601` (correct shape)
- Fix: `8c00ae8` (PR #79) - the line became
  `try self.store.createJournal(journal_id, group_id);`, and the new test
  "Node.createJournal creates and registers a journal" calls the method, so
  the body is analyzed on every gate run.
- Re-checked 2026-08-31: the field access is gone and the test is present. It
  is the credited fix that closed this, not a later restructuring: `8c00ae8`
  changes exactly the one line this report names
  (`git show 8c00ae8 -- src/journal/journal.zig`), and the method is
  otherwise unchanged in shape. `zig build test` would now fail to compile
  if the typo came back, which is the point of the test.
- The "Still open" TL;DR line and the `Fix: none` reference above were left
  behind by `8893ae1`, which flipped 29 reports to `Resolved.` in a docs-only
  commit and did not update either line. The fix itself is real.
