# Bug - `beginMerge` records a merge whose branch request never went out

## TL;DR

- **What failed:** `beginMerge` set `merging_from` and then called
  `requestSync`, which is a silent no-op while another sync is in flight and
  fails quietly on a dead conn. The survivor was then "merging" with nothing
  outstanding to advance it.
- **Impact:** replication stops on that member for as long as the conn lives -
  `onSlot` drops every record while `merging_from` is set - and if the earlier
  sync's page arrives on the same conn it is read as branch records.
- **Resolution:** fixed. `requestSync` reports whether the request went out,
  and `beginMerge` commits `merging_from` only then.

## Status

Resolved. Found by reading `src/cluster/node.zig`; no investigation record.

## Symptom and impact

```zig
fn beginMerge(self: *ClusterNode, conn_id: u64, branch_epoch: u64) !void {
    if (self.merging_from != null) return;
    self.merging_from = conn_id;
    const from: slot.Position = .{ .epoch = branch_epoch, .seq = 1 };
    try self.requestSync(conn_id, self.node.control.journal_id, from);
}
```

`requestSync` allows one sync at a time and returned without sending when one
was already outstanding. It also swallowed a send failure, clearing
`sync_in_flight` and returning normally. Neither outcome reached the caller:
its declared `!void` had an empty inferred error set, so `try` there could
never fire.

Committing `merging_from` regardless has two consequences.

`onSlot` opens with `if (self.syncing or self.merging_from != null) return;`,
so the member stops folding broadcasts entirely. Nothing clears
`merging_from` except the merge finishing, which needs a sync page that was
never requested, or `onPeerGone` for that conn. A healthy conn therefore
wedges replication indefinitely.

The reachable interleaving is not exotic: `onHeartbeat`'s gap catch-up issues
a sync when a peer's advertised head is ahead, and a diverging broadcast
landing before that page returns takes `onDivergence` straight into
`beginMerge`.

When the outstanding sync was to the same conn, its page is worse than lost:
`onSyncPage` sees `merging_from == conn_id` and routes it to `mergePage`,
which buffers ordinary chain records as though they were the loser's branch,
and re-slots them once an empty page closes the buffer.

## Reproduction

Reliable, as a unit test in `src/cluster/node.zig`:
`beginMerge commits nothing when the branch request never goes out`. It sets
`sync_in_flight` on a solo node and calls `beginMerge`.

Expected: no merge is recorded. Actual, before the fix: `merging_from` was 9.
The test's `expectEqual(@as(?u64, null), cn.merging_from)` failed with
`expected null, found 9`. Verified by restoring the original statement order
on the fixed tree and re-running.

## Root cause

A caller committed state on the strength of a call whose contract was "best
effort" and whose signature said nothing about it.

## Resolution

`requestSync` returns `!bool` - whether the `sync_req` went out. The
declaration says so, and the six call sites that do not care discard it
explicitly. `beginMerge` returns without touching `merging_from` when the
request did not go out; the divergence that triggered it will be seen again
on the next diverging record, with no sync in flight by then.

## Verification

- The new unit test fails as quoted above with the original statement order
  and passes with the fix.
- It also covers the dead-conn path (a conn id that does not exist: the send
  fails, `sync_in_flight` is cleared, no merge is recorded) and the success
  path (`merging_from` set, `sync_in_flight` true).
- `e2e (b): partition a 2-member seniority cluster, write on both sides,
  heal, merge` passes.
- `zig build test`: green.

## Follow-up

`mergeNextData` requests each data branch the same way and does not check
either. It is not exposed today: every path into it runs from `mergePage`,
which `onSyncPage` reaches only after clearing `sync_in_flight`, so no sync
is ever outstanding there. Left as is rather than adding a branch no test
can reach; recorded here because the invariant is now load-bearing.

## References

- Investigation: none
- Code: `src/cluster/node.zig` (`beginMerge`, `requestSync`, `onSyncPage`,
  `mergePage`, `onHeartbeat`, `onSlot`)
- Related: [2026-08-29 - an ordinary failover leaves `becomeLoser` truncating a committed suffix](2026-08-29-branch-facts-never-reset.md)
- Fix: this commit
