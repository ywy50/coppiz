# Bug - `onMergeAck` truncates every data journal for any peer that asks

## TL;DR

- **What failed:** `ClusterNode.onMergeAck` discarded its `conn_id` and acted
  on `common_tail` alone. Any admitted member could truncate every data
  journal on a peer by sending one zero-length `merge_ack` frame.
- **Impact:** remote data loss on a member that has ever elected. The frame
  carries no body, so there was nothing else to check and nothing to forge.
- **Resolution:** fixed. The loser records the conn it sent its `merge_offer`
  on, and only that conn's ack is actionable, once.

## Status

Resolved. Found by reading `src/cluster/node.zig`; no investigation record.

## Symptom and impact

`merge_ack` is the survivor telling the loser of a healed partition that the
loser's branch has been fetched and re-slotted, so the loser may now truncate
its own data journals and re-sync them. The handler was:

```zig
fn onMergeAck(self: *ClusterNode, conn_id: u64) !void {
    _ = conn_id;
    const tail = self.common_tail orelse return;
    ...
    try self.node.store.truncate(jid, pos);
```

The dispatcher admits the frame from any member (`.merge_offer, .merge_ack =>
role == .member` in `frameAllowed`), and `message.merge_ack` has a zero-length
body, so the sender is the only fact that could bind an ack to an offer. It
was thrown away.

The precondition on the receiver is `common_tail != null`, which every member
that has folded a new epoch satisfies (`appendEpoch`, `slotAndBroadcast` and
`onSlot` all set it). It is not limited to members mid-merge.

The effect is a truncation of every journal in the fold back to the last slot
of `common_tail.epoch`, a re-fold, and `syncing = true`. On a member whose
current epoch is past the common one, that discards committed, acknowledged
records.

## Reproduction

Reliable, as a unit test in `src/cluster/node.zig`:
`an unsolicited merge_ack truncates nothing: the ack is bound to the offer`.
It builds a solo founder, slots one data record in epoch 1, fails over to
epoch 2, slots a second data record, and then calls `onMergeAck(4242)` with
no merge in progress and no such conn.

Expected: nothing happens. Actual, before the fix: the data journal's head
went from `(2, 1)` back to `(1, 1)` and `syncing` was set. The test's
`expectEqual(head_before, cn.headFor(data_id))` failed with
`expected 2, found 1` on the head's `epoch` field.

## Root cause

`merge_ack` is a reply, and the protocol has no request id. `becomeLoser` sent
the `merge_offer` and kept no record of where it went, so `onMergeAck` had no
pending-offer state to check the sender against and checked nothing.

## Resolution

`ClusterNode` gains `merging_to: ?u64`, the loser's counterpart to the
survivor's `merging_from`:

- `becomeLoser` sets it to the conn the `merge_offer` was sent on.
- `onMergeAck` returns unless it is set and equals `conn_id`, and clears it
  before acting, so one offer admits exactly one ack.
- `onPeerGone` clears it when that conn dies, next to the existing release of
  `sync_in_flight` and `merging_from`.

No wire change: the check is local state, so a mixed-version cluster behaves
as before for the legitimate exchange.

## Verification

- The new unit test fails on the unfixed tree as quoted above and passes with
  the fix.
- It also asserts the positive direction: an ack on a different conn while an
  offer is outstanding is still inert, the offered-to conn's ack does truncate
  the epoch-2 branch and keep the epoch-1 prefix, and `merging_to` is null
  afterwards.
- `e2e (b): partition a 2-member seniority cluster, write on both sides, heal,
  merge` still passes, which is the real merge path end to end.
- `zig build test`: green.

## Follow-up

The dispatcher's `frameAllowed` still admits `merge_offer` from any member.
That path is not equally exposed: `onMergeOffer` runs `survivorVs`, which
refuses a branch leader that is not a member, and the two outcomes are
`becomeLoser` or `beginMerge`. Not changed here.

`becomeLoser` has a separate defect of its own: `common_tail` is never reset,
so a member that has only ever seen an ordinary failover still truncates to
it. That is filed and fixed separately.

## References

- Investigation: none
- Code: `src/cluster/node.zig` (`onMergeAck`, `becomeLoser`, `onPeerGone`),
  `src/net/message.zig` (`merge_ack`)
- Fix: this commit
