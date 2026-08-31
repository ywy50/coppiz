# Bug - a merge re-slot on a data journal cannot be read back off disk

## TL;DR

- **What failed:** `doMergeData` folds the losing branch's journal-scoped
  `settings`/`checkpoint` records as re-slots and writes them to the store,
  but nothing marks them on disk. Every path that reads a record back folds
  it as live, and the live rule refuses them `NotLeader`.
- **Impact:** after such a merge the survivor cannot reopen its own data
  directory (`Node.open` and `refold` both fail), and no peer can backfill
  that journal - `onSyncPage` folds pages with the same live rule.
- **Resolution:** fixed - `applyDataChecked` now infers the re-slot from
  authorship for the two leader-authored kinds, the way `applyControl` has
  always done for the control chain.

## Status

Resolved 2026-08-31. Found by reading the merge path, then reproduced.

## Symptom and impact

`doMergeData` (`src/cluster/node.zig`) re-slots each record of the losing
data branch: a new slot signed by the survivor, the *same* entry, folded
with `reslotted = true`. Under that flag a journal-scoped `settings` or
`checkpoint` is a no-op, because its author is the losing branch's leader
and the live rule requires the current one
(`checkAuthorIsLeader`). That much works, and is
[bug 2026-08-29-merge-data-reslot-refusals](2026-08-29-merge-data-reslot-refusals.md)'s
fix.

`Node.applyReplicated` then appends the record to the store, exactly as it
does for a live one. The flag is not part of the record:

- `Node.foldJournal` folds every data record it scans with
  `fold.applyData` - the live rule - on open and on `refold`;
- `ClusterNode.onSyncPage` folds a backfill page's records with
  `applyReplicated(..., false)`.

So the record the survivor accepted a moment earlier is refused the next
time anything reads it. The survivor's own directory no longer opens, which
also means a `refold` inside the merge path itself (`onMergeAck`) fails.

## Reproduction

`src/cluster/node.zig`, test *a re-slotted journal-scoped entry replays from
the store it was written to*: admit a second member, then apply a
`checkpoint` entry authored by that member under a slot signed by this one -
the exact shape `doMergeData` produces - with `reslotted = true`, and call
`node.refold()`.

Expected: the fold comes back to the same head. Actual, before the fix:

```
error: 'cluster.node.test.a re-slotted journal-scoped entry replays from
       the store it was written to' failed:
       if (!std.mem.eql(u8, &en.author, &leader)) return error.NotLeader;
```

thrown from `refold`, not from the apply.

## Root cause

The re-slot was represented only in memory and on the wire, never in the
record. The control chain never had this problem because `applyControl`
*infers* a re-slot rather than being told about one:

```
const reslotted_entry = en.kind != .epoch and !std.mem.eql(u8, &en.author, &leader);
```

with the soundness argument stated in place - an entry the live rule accepts
is leader-authored, so it never matches the test. The data path was given the
wire flag instead of the same inference, and a flag does not survive a write
to disk.

## Resolution

`applyDataChecked` applies the same inference, restricted to the two kinds
that are leader-authored under the live rule:

- `settings` and `checkpoint` whose author is not the current leader fold as
  no-ops;
- `data` and `stale` are author-authored, so the inference does not apply to
  them and they are unchanged.

The slot signature, the entry signature and the member check all run before
this point and are untouched, so the inference admits nothing a re-slot
could not already carry.

One existing assertion changed with it. The test *a re-slotted data entry
folds journal settings/checkpoint/stale as no-ops* required `applyData` to
answer `NotLeader` for such an entry; that refusal is the defect, since the
same bytes must fold the same way whether they arrive on the wire or off
disk. It now asserts that both paths reach the no-op and that the survivor's
setting value is unchanged - the property the refusal was standing in for.

## Verification

- The new test fails on unpatched `chain.zig` with the `NotLeader` quoted
  above and passes with the fix.
- `zig build test` green on the branch: `Build Summary: 25/25 steps
  succeeded; 337/337 tests passed`.

## Follow-up

`stale` keeps a narrower version of the same gap: a re-slotted `stale`
folds as a no-op under the flag, but on replay it runs `applyStale`, which
refuses `StalenessDisabled` when the surviving journal has `stale.enforce`
off. It cannot use this inference - a `stale` mark is author-authored, so a
non-leader author is normal and proves nothing. Not reproduced here, and not
fixed; it needs the enforce settings to differ across the two branches.
