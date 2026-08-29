# Bug - `coppiz admit` panics on a key-only (chainless) directory instead of failing cleanly

## TL;DR

- **What failed:** `cmdAdmit` calls `node.leader()`, which unwraps `control.epoch.?` - null for a directory holding only `member.key` (no chain) - a panic.
- **Impact:** `coppiz admit` on a dir whose serve never joined a chain crashes with a stack trace instead of a clean refusal (`error.NotLeader`-style). Reachable in the `admission = prompt` flow, which records `pending.admit` on just such a node.
- **Resolution:** Still open. Statically validated.

## Status

Resolved.

## Symptom and impact

`Node.open` succeeds on a dir with only `member.key` (the store opens, the queue is created on demand, `foldAll` folds nothing) leaving `control.epoch == null`. `cmdAdmit` (`main.zig:712`) calls `node.leader()` → `journal.zig:175-177` `return self.control.epoch.?.leader;` → panic (`attempt to unwrap null`), exit 1 with a traceback. The intended behavior is the clean `error.NotLeader`-style refusal the code already handles for the post-check.

## Reproduction

Not dynamically reproduced (needs a built binary and a key-only dir); statically certain: `Node.open`'s success path on a chainless dir traced, and the `.?` on the nullable field confirmed.

## Root cause

`node.leader()` dereferences the epoch unconditionally; the CLI's `admit` path assumes a chain.

## Resolution

Fixed: `Node.leader()` returns null before any epoch folds and `coppiz admit` maps it to `NotLeader` instead of unwrapping a null epoch on a chainless directory.

## Verification

- Static: `journal.zig:175-177` (`leader()`), `main.zig:712` (`cmdAdmit`), and `Node.open`'s chainless-dir path read.

## Follow-up

None. Low severity (loud failure, no corruption).

## References

- Code: `src/main.zig:712` (`cmdAdmit`), `src/journal/journal.zig:175-177` (`leader()`)
- Fix: none
