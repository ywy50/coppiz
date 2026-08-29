# Bug - the survivor broadcasts its merge re-slots as live records, so every other member refuses them

## TL;DR

- **What failed:** `doMergeData` applies the losing branch locally with
  `reslotted = true` and broadcast the same records with `reslotted = false`.
- **Impact:** on a heal, every member except the survivor folds the
  re-slotted records through the live rule. A journal-scoped `settings`,
  `checkpoint` or `stale` from the losing branch is then refused
  `NotLeader` - its author is the *losing* leader - and `onSlot` drops it as
  an ordinary chain refusal. The survivor's data fold advances and no other
  member's does.
- **Resolution:** fixed. The broadcast carries `true`, matching the local
  apply and the two sibling re-slot loops.

## Status

Resolved. Found by reading `src/cluster/node.zig`; no investigation record.

## Symptom and impact

The merge has three re-slot loops. `doMergeControl` and
`reSlotDeferredLeaves` apply with `reslotted = true` and broadcast `true`.
`doMergeData` does not:

```zig
// reslotted = true: `data` folds normally, while journal-scoped
// settings/checkpoint/stale re-slot as no-ops (OQ 33) instead
// of refusing on the author check (bug 2026-08-29-merge-data-reslot-refusals).
try self.node.applyReplicated(jid, &sl, &e, true, null);
self.broadcastToMembers(.{ .slot = .{
    .reslotted = false,
```

The comment describes the line above it and contradicts the line below it.

`SlotMsg.reslotted` is the wire field that picks the receiver's fold rule:
`onSlot` passes `m.reslotted` straight to `applyReplicated`, which routes to
`applyDataReslotted` or `applyData`. In `applyDataChecked` the two differ
exactly where it matters:

```zig
if (reslotted) {
    switch (en.kind) {
        // Journal-scoped settings, checkpoints and stale marks from
        // the losing branch re-slot as no-ops (OQ 33).
        .data, .settings, .stale, .checkpoint => {},
        else => return error.WrongJournalType,
    }
} else {
    switch (en.kind) {
        .data => {},
        .settings => try self.applyJournalSettings(sl, en, cluster),
        .stale => try self.applyStale(sl, en),
        .checkpoint => try self.applyCheckpoint(sl, en, cluster),
        ...
```

`applyJournalSettings` and `applyCheckpoint` both check the author is the
current leader. A re-slotted entry's author is the losing branch's leader,
never the survivor, so both refuse `NotLeader`, and `onSlot` treats a chain
refusal as the fold's own decision and returns. The follower's fold does not
advance; the survivor's did.

The control chain escapes this only by accident: `applyControl` *infers* a
re-slot from `en.author != leader`, so the flag is redundant there.
`applyDataChecked` has no such inference, which makes the flag on the wire
the only signal a data journal has.

Reachability is ordinary rather than exotic: any partition and heal whose
losing side wrote a journal-scoped settings change, or emitted a checkpoint -
routine on any journal with `ttl.enforce` or `stale.enforce` on. The merge
e2e writes only `.data` entries during its partition, which is why the suite
never saw it - the same coverage gap the earlier report called out.

## Reproduction

`a merge data re-slot is broadcast as a re-slot, not as a live record` in
`src/cluster/node.zig`. It registers a connection that records what the loop
sends, puts one on-disk record into `merge_buffers`, runs `doMergeData`, and
decodes the broadcast back off the wire.

Before the fix the test fails at

```
src/cluster/node.zig:5415:5
    try std.testing.expect(msg.slot.reslotted);
```

After the fix the flag on the wire matches the local apply. The assertion is
on the flag rather than on a follower's fold so that the test pins the one
thing that was wrong, without standing up a third member.

## Root cause

A literal, not a variable. The three loops each write the flag out by hand,
and this one was written `false` while its apply was written `true`. Nothing
ties the two together, and no test read the flag off the wire.

## Resolution

`.reslotted = true` in `doMergeData`'s broadcast, with a comment stating why
the data path cannot recover the flag by inference the way the control path
can.

## Verification

- The new test fails on the flag before the change and passes after.
- `zig build test` green on the branch.

## Follow-up

Two related gaps are **not** fixed here and are worth their own work:

- `onSyncPage` applies every record with a hardcoded `reslotted = false`, and
  the on-disk record does not carry the flag, so a member that backfills a
  merged data chain - or a survivor that re-folds its own store on reopen -
  hits the same refusal. The durable fix is to give `applyDataChecked` the
  author-based inference `applyControl` already has, which is a change to
  the fold rule rather than to the loop.
- The three merge loops still write the flag as a literal each.

## References

- Code: `src/cluster/node.zig` (`doMergeData`, `doMergeControl`,
  `reSlotDeferredLeaves`, `onSlot`), `src/journal/chain.zig`
  (`applyDataChecked`)
- Related: [2026-08-29 - merge data re-slots refuse
  `settings`/`checkpoint`/`stale`](2026-08-29-merge-data-reslot-refusals.md),
  which fixed the survivor's own apply and left the wire copy saying
  otherwise
- Fix: this PR
