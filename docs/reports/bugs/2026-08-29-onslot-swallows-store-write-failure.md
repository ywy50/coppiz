# Bug - `onSlot` swallows a refused store write, leaving the fold ahead of the segment file

## TL;DR

- **What failed:** `onSlot`'s `else => {}` branch ignored every
  `applyReplicated` error that was not `BadPrevHash` or `OutOfMemory`. That
  set includes the store's own failures, and `Node.applyReplicated` folds
  *before* it writes.
- **Impact:** the member carries a fold one record ahead of its segment file.
  It serves a record that is not on disk, and the chain does not reopen.
- **Resolution:** fixed. A chain refusal is still ignored; anything else
  stops the member and propagates.

## Status

Resolved. Recorded as a follow-up on
[2026-08-29-slot-record-trailing-bytes](2026-08-29-slot-record-trailing-bytes.md),
whose decode-side fix closed the one route that made this reachable from the
wire; this is the other half of it.

## Symptom and impact

`Node.applyReplicated` folds first and writes second:

```zig
        }
        // The store write uses the wire's own record bytes ...
        if (record) |raw| {
            try self.store.appendRecord(journal_id, sl.position(), raw);
```

so every failure after the fold call leaves the fold advanced and the file
not. `Store.appendRecord` refuses a record whose encoded size does not match
its slice with `error.BadRecord`; the same shape covers a disk error, and
`ensureJournalDir`/`createJournal` failures on the control path.

`onSlot` then discarded it:

```zig
            else => {
                // NotLeader (a stale leader's broadcast), DuplicateConflict,
                // etc. — the chain's own rules decide; nothing to do.
            },
```

The comment is right about refusals and wrong about everything else. A
refusal is the fold's own decision and leaves it untouched; a store failure
is not, and the member has no way back from it. Its reads answer from the
fold, so it serves a record no segment holds, and a restart cannot rebuild
that fold from the file.

## Reproduction

Reliable, as a unit test in `src/cluster/node.zig`:
`a replicated slot whose store write is refused stops the member`. It hands
`onSlot` a well-formed, correctly signed slot whose record bytes carry three
bytes too many, which the fold accepts and `Store.appendRecord` refuses with
`error.BadRecord`.

Expected: the failure surfaces. Actual, before the fix: `onSlot` returned
normally. The test's `expectError(error.BadRecord, ...)` failed with
`expected error.BadRecord, found void`. Verified by neutralising the new
branch on the fixed tree and re-running.

## Root cause

The `else` prong classified by exclusion (everything that is not
`BadPrevHash` or `OutOfMemory`) when the distinction it needed was between
*fold refusals* and *everything else*. `chain.refusalName` already draws
exactly that line - it returns a name for each of the 31 `chain.Refusal`
members and null for anything else - and was not used here.

## Resolution

The prong now tests `chain.refusalName(e) != null`. A refusal returns as
before. Anything else calls `fatal()` and propagates:

- `error.UnknownJournal` is listed separately and still ignored. It is
  raised by `applyReplicated`'s journal lookup, before any fold mutation, and
  is normal for a data record that overtakes the `create_journal` naming its
  journal.
- Everything remaining came from after the fold advanced, so the member stops
  rather than serving a fold its store does not back. This is the convention
  the `OutOfMemory` prong already states in its comment.

## Verification

- The new unit test fails as quoted above with the guard removed and passes
  with it.
- The same test also pins the negative direction: a slot whose leader is not
  a member is refused by the fold and still leaves the member running.
- `zig build test`: green, including the process-level e2e tests, so no
  refusal that occurs in normal operation is now being treated as fatal.

## Follow-up

The fold-before-write order is untouched and is the deeper defect: nothing
here makes the write atomic with the fold, it only stops the member from
carrying on past a divergence it cannot repair. `src/journal/journal.zig` is
outside this session's territory.
[2026-08-29-fold-before-store-order](2026-08-29-fold-before-store-order.md)
covers the local paths; the replicated path in `applyReplicated` has the same
ordering and is still open.

Separately, `onFrame`'s caller is `self.onFrame(...) catch self.closeConn(...)`,
so an error returned from `onSlot` only drops the connection. The
`OutOfMemory` prong's comment says the member "must stop serving", which
returning the error alone does not achieve. That is why this branch calls
`fatal()` explicitly rather than relying on the return.

## References

- Investigation: none
- Code: `src/cluster/node.zig` (`onSlot`, `onFrame`),
  `src/journal/journal.zig` (`applyReplicated`),
  `src/journal/store.zig` (`appendRecord`),
  `src/journal/chain.zig` (`Refusal`, `refusalName`)
- Related: [2026-08-29 - a `slot` whose record carries trailing junk decodes as valid](2026-08-29-slot-record-trailing-bytes.md),
  [2026-08-29 - control/checkpoint writes fold before the store write](2026-08-29-fold-before-store-order.md)
- Fix: this commit
