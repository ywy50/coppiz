# Bug - `changeSettings` unwraps a journal the chain names and the store lost

## TL;DR

- **What failed:** `Node.changeSettings` reached the journal's fold with
  `self.journals.get(journal_id).?.fold`. A journal name resolves through the
  folded registry while that map is built from the store's directories, so
  the two can name different sets - and the unwrap then aborts the process.
- **Impact:** an abort ("attempt to use null value") on ordinary input,
  where every sibling method on the same lookup refuses cleanly. The state
  it needs is reachable: `init`, `Node.createJournal` and `applyReplicated`
  all record the `create_journal` before creating the directory, and the
  reopen after a crash in that window is clean because discovery enumerates
  directories.
- **Resolution:** fixed - `orelse return error.UnknownJournal`, which is
  what `append`, `markStale`, `checkpointForBroadcast`,
  `checkpointRemovalSet`, `compactAfterCheckpoint` and `applyReplicated`
  already return for the same lookup.

## Status

Resolved 2026-08-31. Found by reading; reproduced as a unit test.

## Symptom and impact

Two structures name journals and are built from different sources:

- `control.journals` - the folded registry, written by the `create_journal`
  control entry. `journalIdByName` scans it.
- `Node.journals` - one `FoldState` per journal, built by `foldAll` from
  `store.journalIds`, i.e. from the subdirectories on disk.

`changeSettings` was the only method that treated the second as implied by
the first:

```
const target: *chain.FoldState = if (is_control)
    &self.control
else
    &self.journals.get(journal_id).?.fold;
```

Three code paths create the divergence, all of them recording the journal in
the chain before it exists in the store:

- `journal.init` appends the `create_journal` control record and then creates
  the directory.
- `Node.createJournal` does the same in the same order.
- `applyReplicated` folds the control entry and then calls
  `ensureJournalDir`.

A crash - or an `ENOSPC`/`EIO` on the `mkdir` - between the two leaves a
control chain that names the journal with no directory for it. Nothing
notices on reopen, because `foldAll` enumerates directories. An operator or
restore that loses one journal subdirectory lands in the same state.

## Reproduction

`src/journal/journal.zig`, test *a journal the chain names but the store lost
is refused, not unwrapped*:

1. `init` with `first_journal = "main"`; open once to learn the journal id.
2. `deleteTree` the journal's `data/<id-hex>/` directory.
3. Reopen. `journalIdByName("main")` still resolves.
4. `node.append(jid, "x", 0)` - refuses with `UnknownJournal` (already
   correct, and the control for the assertion).
5. `node.changeSettings(jid, changes)`.

Expected: `error.UnknownJournal`. Actual, before the fix: `thread panic:
attempt to use null value` at `changeSettings`, which takes the whole process
down rather than failing the call.

## Root cause

An `.?` on a lookup that has a legitimate `null` case, in the one method that
did not carry the `orelse return error.UnknownJournal` its siblings all do.

## Resolution

```
&(self.journals.get(journal_id) orelse return error.UnknownJournal).fold;
```

with a comment naming the three windows that produce the state, so the next
reader does not restore the unwrap on the grounds that a resolved name
implies a folded journal.

## Verification

- The new test aborts the test binary on the unpatched node with `attempt to
  use null value` at `journal.zig:437`, and passes with the `orelse`. Checked
  by restoring the unwrap and re-running.
- 174/174 with the fix, in a module test root over `src/journal/journal.zig`.
- `zig build test` green on the branch.

## Follow-up

`src/cluster/node.zig`'s `onSettings` has the same unwrap
(`&self.node.journals.get(jid).?.fold`), on the wire path a `coppiz settings
set --journal NAME` takes - so the same state aborts the **leader** on client
input, which is worse than the library case fixed here. It is left for a
change scoped to `src/cluster/`; this report is the record that it is known.

The ordering itself (chain record before directory) is the deeper cause and
is not addressed here: making the directory first would trade this state for
an orphan directory, which `foldAll` would then try to fold. Which order is
right is a question about `create_journal`'s durability contract rather than
about this lookup.

## References

- Investigation: none
- Code: `src/journal/journal.zig` (`changeSettings`, `foldAll`,
  `journalIdByName`, `init`, `createJournal`, `applyReplicated`),
  `src/cluster/node.zig` (`onSettings`, the unfixed twin)
