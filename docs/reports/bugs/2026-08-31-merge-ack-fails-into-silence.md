# Bug - a `merge_ack` that fails part-way strands the member silently

## TL;DR

- **What failed:** `onMergeAck` was the only frame handler whose error the
  dispatch discarded (`catch {}`), and it consumed the pending merge offer
  on its first line. A failure anywhere in the rest of it left the member
  half-merged and unable to accept the ack again.
- **Impact:** the losing side of a partition stays on its dead branch with
  no retry path and nothing logged - the failure mode the merge is supposed
  to end.
- **Resolution:** fixed - the error propagates like every other handler's,
  and the pending offer is consumed only once the work it authorises has
  succeeded.

## Status

Resolved 2026-08-31. Found by reading the dispatch; the partial-failure
behaviour is reproduced by the test below.

## Symptom and impact

`onMergeAck` is the losing side's half of a merge. It truncates every data
journal back to the common tail, re-folds, resets the author sequence, and
re-arms the sync cursors so the survivor's chain can be fetched. Every step
is fallible.

The dispatch in `onFrame` ran it like this:

```
.merge_ack => self.onMergeAck(conn_id) catch {},
```

Every other arm in that switch is a `try`. An error from any of them reaches
`onFrame`'s caller, which closes the connection:

```
self.onFrame(conn_id, body) catch self.closeConn(conn_id);
```

Closing is the recovery: `onPeerGone` clears `merging_to`, the peer redials,
the divergence is recomputed and the branch is offered again. `merge_ack`
opted out of that, so a failure produced no connection close, no log, and no
retry.

It was compounded by the order inside the handler. The pending offer was
consumed on the way in:

```
const offered_to = self.merging_to orelse return;
if (offered_to != conn_id) return;
self.merging_to = null;
```

so even a survivor that re-sent the ack on the same connection was answered
by the `orelse return` on the first line. The member kept its dead branch.

## Reproduction

`src/cluster/node.zig`, test *a merge_ack that fails part-way leaves the
offer outstanding*: build the shape a losing branch has while it waits (a
slot in epoch 1, a failover, a slot in epoch 2), mark an offer outstanding
on a connection, then answer it with an allocator that fails.

Expected: the offer survives a failed answer. Before the fix `merging_to` is
`null` - consumed by an attempt that did not complete.

## Root cause

Two independent decisions that are each defensible for an advisory message
and neither of which holds for this one: discarding the handler's error, and
taking the "only once" guard on entry rather than on success. `merge_ack`
carries no body - the pending offer *is* the whole authentication (bug
2026-08-29-merge-ack-unauthenticated) - which is probably why it reads as
advisory. It is not: it is the trigger for a destructive, stateful sequence.

## Resolution

- The dispatch arm is `try self.onMergeAck(conn_id)`, like its fourteen
  siblings. A failure now closes the connection, which is the existing
  recovery path.
- `self.merging_to = null` moved to the end, beside the other branch facts
  that are cleared on success. "One ack per offer" still holds: the handler
  runs on the loop thread, so no second ack can interleave with the first.

## Verification

- The test above fails with the clear on entry (`expected 7, found null`)
  and passes with it at the end.
- `zig build test` green on the branch: `Build Summary: 25/25 steps
  succeeded; 338/338 tests passed`.
- The dispatch line itself is covered by inspection, not by a test: driving
  a failure through `onFrame` needs a whole framed connection, and the
  behaviour it restores - close, then re-offer on redial - is the path every
  other handler already takes.

## Follow-up

The sequence is still not atomic. A failure after the truncate but before
the re-fold leaves the fold ahead of the store on that member; the closed
connection and the retained offer make it recoverable and visible, but they
do not undo the partial work. Making the truncate/re-fold pair atomic is
larger than this fix and is not attempted here.
