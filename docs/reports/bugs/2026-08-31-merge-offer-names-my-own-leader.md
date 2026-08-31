# Bug - one `merge_offer` naming a member's own leader freezes its replication for the life of the connection

## TL;DR

- **What failed:** `onMergeOffer` had no "a branch led by my own leader is
  not a partition branch" guard. `epoch.survivor` ranks the peer's branch
  leader against this member's through `election.compareRank`, which answers
  `.eq` for one leader compared with itself, and `.eq` maps to "I survive" -
  so the member began a merge against its own branch.
- **Impact:** `beginMerge` sets `merging_from`, and `onSlot` returns early for
  every broadcast while it is set. Nothing releases it on a timer, so one
  32-byte frame from any admitted peer stopped a healthy member folding
  anything for as long as the connection stayed open - while it went on
  heartbeating and serving reads, so the staleness was silent.
- **Resolution:** fixed - the offer is dropped when its branch leader is this
  member's current leader, mirroring `onDivergence`.

## Status

Resolved 2026-08-31.

## Symptom and impact

`src/cluster/node.zig`, before the fix:

```zig
fn onMergeOffer(self: *ClusterNode, conn_id: u64, offer: message.MergeOffer) !void {
    const winner = self.survivorVs(offer.branch_leader) orelse { … };
    if (winner == .b) { try self.becomeLoser(…); return; }
    try self.beginMerge(conn_id, offer.branch_head.epoch);
}
```

`onDivergence`, the other entry to the same machinery, carries the check this
one lacks:

```zig
// A record from my own current leader is a redelivery, not a
// partition branch; only a *different* elected leader diverges.
if (std.mem.eql(u8, &peer_branch_leader, &self.node.control.epoch.?.leader)) return;
```

With `offer.branch_leader` equal to the member's own leader, `survivorVs`
looks the same view up twice and hands `epoch.survivor` two branches with
identical leaders. `survivor` is
`switch (compareRank(inputs, a.leader_view, b.leader_view)) { .lt, .eq => .a, .gt => .b }`,
so the answer is `.a` and the member takes the survivor path.

`beginMerge` sends one `sync_req` on the offerer's connection and sets
`merging_from = conn_id`. From that point `onSlot` begins with
`if (self.merging_from != null) return;`, so every replicated slot is
discarded. `merging_from` is cleared in exactly two places - `onPeerGone` and
the merge completion - and there is no watchdog on it, unlike
`sync_in_flight`, which `onTick` releases after `sync_response_timeout_ms`. An
offerer that keeps the connection open and never answers the `sync_req`
therefore freezes the victim's fold indefinitely.

Two secondary consequences of the same path, both reachable once the offer is
accepted:

- The victim keeps heartbeating and answering reads, so it looks healthy and
  serves a frozen prefix. No error is logged anywhere.
- If the offerer answers with one *empty* page, `mergePage` →
  `doMergeControl` → `mergeNextData` clears `branch_start` and `common_tail`.
  A later genuine divergence then returns early at
  `const branch_start = self.branch_start orelse return;`, so the member is
  stranded in a real heal.

`frameAllowed` admits `.merge_offer` from any connection whose hello
completed as a member, which is the trust boundary the design intends -
admission, not per-frame authority
([RFC 0009](../../rfcs/0009-trust-model.md)). A buggy or confused peer is
enough; nothing needs to be malicious. The nearest existing record,
[an unsolicited `merge_ack` truncates nothing](2026-08-29-merge-ack-unauthenticated.md),
noted that `merge_offer` is admitted the same way and dismissed it - "that
path is not equally exposed: `onMergeOffer` runs `survivorVs`" - without
following what `survivorVs` answers for a leader compared with itself.

## Reproduction

The test `a merge_offer naming my own leader is dropped, not begun as a merge`
in `src/cluster/node.zig`: a founder with a chain and one data slot, a stub
connection, then `onMergeOffer` naming `control.epoch.?.leader` - the
member's own id.

- Expected: the offer is dropped; no merge state, no sync in flight, the
  connection left alone.
- Actual (before the fix): `merging_from` is the offerer's connection id.
  Verified by replacing the guard with `_ = my_epoch;` on this branch:
  `expected null, found 9`, 260 passed, 1 failed.

## Root cause

The two entry points into the divergence machinery were written separately,
and the invariant "a branch is only a branch if a *different* leader signed
it" lived at one of them. `epoch.survivor`'s `.eq => .a` is correct for its
own contract - two distinct branch leaders of equal rank - and silently
wrong when handed one leader twice, which is a caller's obligation to
prevent.

## Resolution

`onMergeOffer` reads `control.epoch` itself - closing the connection when
there is none, exactly as `survivorVs` returning null already did - and
returns without acting when the offer's branch leader is the current leader.

## Verification

`zig build test` (the merge gate: unit tests plus the fmt, 100-column,
test-registration, refAllDecls-pairing and gate-coverage lint gates), green.

The new test asserts the drop, that `sync_in_flight` is untouched, and that
the connection is not closed - a peer's confusion, not a protocol violation.
It also asserts the guard is not a blanket drop: an offer naming a leader the
member has never folded still costs the connection, which is the pre-existing
forged-chain response. The chainless case keeps its own test
([2026-08-30](2026-08-30-chainless-merge-offer-panic.md)).

## Follow-up

`merging_from` still has no watchdog. A survivor whose `sync_req` for the
branch is answered by nothing - a peer that dies without its `peer_gone`
being observed, or one that stalls - stops folding until the connection is
reaped. `sync_in_flight` has exactly this release in `onTick` and
`merging_from` does not; adding one is a change to the merge's own liveness
rather than to this guard, and is not attempted here.

## References

- Investigation: none
- Code: `src/cluster/node.zig` (`onMergeOffer`, `survivorVs`, `beginMerge`,
  `onSlot`), `src/cluster/epoch.zig` (`survivor`)
- Related: [2026-08-29 - `onMergeAck` truncates every data journal for any peer that asks](2026-08-29-merge-ack-unauthenticated.md),
  [2026-08-30 - one `merge_offer` frame aborts a member that has not finished its first backfill](2026-08-30-chainless-merge-offer-panic.md)
- Fix: this commit
