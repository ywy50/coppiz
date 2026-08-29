# Bug - a deferred `leave` that refuses leaves a freed payload in the merge list, and the next free of it is a double free

## TL;DR

- **What failed:** `ClusterNode.reSlotDeferredLeaves` freed each entry's payload inside its loop but cleared `merge_pending_leaves` only after the loop finished. An error part way through returned with the already-freed entries still in the list.
- **Impact:** The next free of that list - `ClusterNode.deinit`, `onPeerGone`, or the next `doMergeControl` - is a double free. Under the debug allocator the node aborts; in a release build it is heap corruption. The trigger is a shape a real merge produces, not a contrived one: two `leave` entries on the losing branch where the first removes their author.
- **Resolution:** Fixed. The loop drains from the front, so an entry is in the list exactly while its payload is still owned.

## Status

Resolved.

## Symptom and impact

`src/cluster/node.zig`, before the fix:

```zig
for (self.merge_pending_leaves.items) |en| {
    const sl = try self.reslot(&en, prev_hash, seq, ...);
    try self.node.applyReplicated(control_id, &sl, &en, true, null);
    ...
    self.allocator.free(en.payload);   // freed, but the item stays in the list
}
self.merge_pending_leaves.clearRetainingCapacity();
```

Both `try`s can fail, and `reSlotDeferredLeaves` re-slots several entries in
one call. A failure at iteration `k > 0` returns with items `0..k-1` in
`merge_pending_leaves` holding dangling payload pointers.

The error is then swallowed. It propagates `reSlotDeferredLeaves` ->
`mergeNextData` -> `mergePage` -> `onSyncPage` -> `onFrame`, and the loop's
frame handler catches it and closes the connection. The node keeps running
with the dangling entries, and the fault surfaces later at whichever of the
three frees reaches them first.

## Reproduction

New test `a deferred leave that refuses leaves no freed payload in the list`
in `src/cluster/node.zig`. A founder node, no loop started, with two
self-authored `leave` entries handed to `merge_pending_leaves` the way
`doMergeControl` hands them over.

The first re-slot removes the founder, who is also the fold's leader. The
second then has no leader to validate its slot signature against and is
refused with `error.NotLeader`.

- Expected: one entry left in the list (the refused one), still owning its
  payload, freed once by `deinit`.
- Actual, before the fix, from a control run with the fix reverted:

```
error: 'cluster.node.test.a deferred leave that refuses leaves no freed payload in the list' failed:
       expected 1, found 2
       [DebugAllocator] (err): Double free detected.
```

## Root cause

Two different things tracked the same ownership and only one of them advanced
inside the loop. `free(en.payload)` ran per iteration; `clearRetainingCapacity`
ran once, after. On the success path the two agree, so nothing was ever wrong
in a merge that completed - and no test drove one that did not.

The refusal at issue is documented behaviour, not an edge case:
`membership.applyLeaveReslotted` is deliberately idempotent for a target that
is already gone, and `chain.applyControlReslotted` still validates the slot
signature and the entry signature against the *survivor's* member table. A
losing branch whose leaves remove their own author therefore refuses on the
second one by design.

## Resolution

The loop drains from the front instead of iterating a list it mutates only at
the end:

```zig
while (self.merge_pending_leaves.items.len > 0) {
    const en = self.merge_pending_leaves.items[0];
    ... // re-slot, apply, broadcast
    _ = self.merge_pending_leaves.orderedRemove(0);
    self.allocator.free(en.payload);
}
```

The invariant is now one thing: an entry is in `merge_pending_leaves` exactly
while its payload is still owned. An error returns with the failing entry and
everything after it still in the list and still owned, which is what `deinit`,
`onPeerGone` and `doMergeControl` all expect. On success the list ends empty,
as before.

`doMergeControl`'s hand-over got an `errdefer` in the same change: it duped a
leave's payload and then appended to the list, so an allocation failure in the
append leaked the dupe.

## Verification

- New test above.
- Control: with the drain reverted and the test kept, the gate reports
  `expected 1, found 2` and the debug allocator reports a double free.
- `zig build test --summary all` green.

## Follow-up

None for this list. The same "allocate, then insert into a container that can
fail" shape exists elsewhere in the node and the membership fold and is
recorded separately.

## References

- Code: `src/cluster/node.zig` (`reSlotDeferredLeaves`, `doMergeControl`, `deinit`, `onPeerGone`), `src/journal/chain.zig` (`applyControlReslotted`), `src/cluster/membership.zig` (`applyLeaveReslotted`)
- Related: [`2026-08-29-merge-data-reslot-refusals.md`](2026-08-29-merge-data-reslot-refusals.md), which introduced the deferred-leaves list
- Fix: this change
