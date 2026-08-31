# Bug - a sync page whose cursor does not advance pins a member in `syncing` forever

## TL;DR

- **What failed:** `onSyncPage` stored the peer's `next` verbatim as the
  journal's backfill cursor, without checking that it advances past the
  position the page answers.
- **Impact:** a page whose cursor is at or behind that position makes
  `driveBackfill` re-issue exactly the same `sync_req` on every tick. Because
  `syncing` clears only once every cursor has drained, the member never
  becomes leader-eligible, never drains its durable queue, and pays a page
  round trip per tick indefinitely.
- **Resolution:** fixed - a non-advancing cursor is refused and the
  connection dropped, which is what `net/client.zig` already did for its own
  copy of this cursor.

## Status

Resolved 2026-08-31.

## Symptom and impact

`src/cluster/node.zig`, `onSyncPage`, before the fix:

```zig
if (self.syncing) {
    if (p.records.len > 0) {
        try self.sync_cursors.put(self.allocator, p.journal_id, p.next);
    } else { … }
}
```

`p.next` is whatever the peer put in the frame. `driveBackfill` reads the
cursor back and re-requests from it:

```zig
if (self.sync_cursors.get(control_id)) |from| {
    const conn_id = self.syncPeerConn() orelse return;
    _ = try self.requestSync(conn_id, control_id, from);
    return;
}
```

With a cursor that does not move, that request is identical on every tick.
The records the page carried are applied (or skipped as redelivery) the first
time and skipped every time after, so nothing advances and nothing errors.
Three consequences, all silent:

- `driveBackfill` clears `self.syncing` only after every cursor has drained,
  and `runElection` returns immediately while `syncing` is set. The member is
  permanently ineligible for leadership.
- `reforwardQueue` runs from the same place, so the member's durable queue is
  never drained: a client or host waiting on an entry queued here waits for
  as long as the loop runs.
- One `sync_req`/`sync_page` round trip per tick, for the life of the
  process.

This is the node-side sibling of
[the wire client asserts on the peer's read cursor](2026-08-29-client-read-cursor-assert.md).
That report fixed `src/net/client.zig`, whose loop now reads:

```zig
// The cursor comes from the peer, so it is checked, not
// asserted: a `next` that does not advance is an unbounded
// request loop in a release build and a panic in a safe one.
if (slot.Position.order(page.next, position) != .gt) {
    return error.ProtocolError;
}
```

The node's own cursor was not covered by it.

**Reachability, stated plainly.** The shipped `onSyncReq` always advances
`ctx.next` past each record it encodes, so a conforming member never sends
such a page. It takes a peer running different or broken code - and the trust
model is admission-time, not per-frame
([RFC 0009](../../rfcs/0009-trust-model.md)), so any admitted member's frames
are taken at face value. Nothing needs to be malicious for this to happen; a
version skew in the page builder is enough. The consequence is
disproportionate to the cause, which is why it is checked rather than
trusted.

## Reproduction

The test `a sync page whose cursor does not advance is refused, not looped on`
in `src/cluster/node.zig`: a founder with a chain, a stub connection,
`syncing` set with a cursor at `(1, 3)`, and a `sync_page` carrying the
genesis record (already folded, so the record loop skips it as a redelivery
and reaches the cursor bookkeeping). Two pages are delivered: one whose
`next` is `(1, 2)` - behind the cursor - and one whose `next` is `(1, 3)`,
standing still.

- Expected: both pages are refused, the cursor keeps `(1, 3)`, and the
  connection is dropped.
- Actual (before the fix): the cursor is rewritten - `expected 3, found 2` on
  the first page - and the connection stays up, so the next tick asks the
  same question again. Verified by removing the check alone on this branch.

## Root cause

A peer-supplied value used as loop state without being checked against the
progress it has to make. The record loop validates everything about the
records - chain continuity, epoch acceptance, the store write - and the
cursor beside them was taken on trust.

## Resolution

Before storing, `p.next` is compared against the cursor the page answers, and
a value that is not strictly greater closes the connection. The cursor is
left as it was, so a later page from a working peer still makes progress from
the right place. The empty-page branch is unchanged: a page that served
nothing still marks the journal done, which is how a backfill finishes.

## Verification

`zig build test` (the merge gate: unit tests plus the fmt, 100-column,
test-registration, refAllDecls-pairing and gate-coverage lint gates), green.

The new test asserts the refusal and, so the check is not a blanket one, that
a cursor which does advance is stored and the connection kept.

## Follow-up

`p.journal_id` is still unchecked against the outstanding request, so a peer
can seed a cursor for a journal id this member never asked about. That one is
inert rather than harmful - `driveBackfill` walks the control journal and the
journals the fold lists, so a cursor for anything else is never drained and
never blocks `syncing` - and fixing it means recording the in-flight
`(journal_id, from)` beside `sync_in_flight` rather than only a bool. Not
done here.

## References

- Investigation: none
- Code: `src/cluster/node.zig` (`onSyncPage`, `driveBackfill`)
- Related: [2026-08-29 - the wire client asserts on the peer's read cursor](2026-08-29-client-read-cursor-assert.md),
  [2026-08-28 - sweep3: backfill over a `retain = none` chain never terminates](2026-08-28-sweep3-backfill-compacted-chain-loop.md)
- Fix: this commit
