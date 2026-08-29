# Bug - shutting the loop down strands every host thread parked on it

## TL;DR

- **What failed:** `ClusterNode.deinit` freed `pending_locals` without
  posting the completions in it, and dropped queued `.local_append` /
  `.local_read` events on its mailbox drain's `else` arm.
- **Impact:** an embedded host blocked in `localAppend` or `localReadRange`
  never wakes. The wait has no timeout, so the host thread is parked for the
  life of the process and the process cannot exit.
- **Resolution:** fixed. `releaseLocalWaiters` posts every waiter, from the
  loop's own exit and again from `deinit`.

## Status

Resolved. Found by reading `src/cluster/node.zig`; no investigation record.

## Symptom and impact

`localAppend` hands the loop a completion that lives on the *host's* stack
and blocks:

```zig
completion.sem.wait(io) catch return error.Canceled;
```

There is no timeout and no deadline. The contract is that the loop posts the
completion exactly once - and `completePendingFor` is called from every
place a slot lands (`onSlot`, `onSyncPage`, `reforwardQueue`,
`slotQueuedEntries`). Shutdown was not one of those places.

Two independent leaks of the same invariant:

1. `onLocalAppend`'s follower branch parks the completion in
   `pending_locals` and returns; the slot arrives later, from the leader.
   If the loop stops first - a leaderless window, a partition, a backfill, a
   merge - `deinit` did `self.pending_locals.deinit(self.allocator)` and the
   semaphore was never posted.
2. `loopMain` returns on the `.stop` event. Anything a host posted after
   that sat in `mailbox.events`, and `deinit`'s drain handles exactly the
   three variants that own memory or a connection:

   ```zig
   for (self.mailbox.events.items) |ev| switch (ev) {
       .frame => |f| self.allocator.free(f.body),
       .conn_ready => |ready| ready.conn.close(self.io),
       .dial_failed => |address| self.allocator.free(address),
       else => {},          // .local_append and .local_read land here
   };
   ```

The documented lifecycle is `stop(); waitForStop(); deinit();` - every test
does it, and so does `examples/embed-cluster`. `waitForStop` waits for
`loop_exited`, not for pending appends, so it reported a clean shutdown with
a host thread still parked.

## Reproduction

`shutdown wakes every host thread parked on the loop` in
`src/cluster/node.zig`. It parks one completion in `pending_locals`, posts
one `.local_append` and one `.local_read` the loop never reads, and calls
`deinit`.

The test reads `sem.permits` directly rather than waiting on the semaphore,
deliberately: a regression must fail an assertion, not hang the suite.

Before the fix:

```
error: 'cluster.node.test.shutdown wakes every host thread parked on the
loop' failed:
       expected 1, found 0
       src/cluster/node.zig:5544:5
           try std.testing.expectEqual(@as(usize, 1), parked.sem.permits);
```

## Root cause

The completion protocol was enumerated by *success* path. Every place a slot
can land posts the completion; teardown is not a place a slot lands, so it
was never added to the list. The mailbox drain has the same shape: it was
written for the variants that own an allocation, and a completion is not an
allocation.

## Resolution

`releaseLocalWaiters` posts every waiter with a `shutdown` marker and clears
both holders. It is called twice:

- from `loopMain`'s `defer`, sequenced *before* the `loop_exited` store, so
  a caller whose `waitForStop` has returned knows no host thread is still
  waiting on this loop;
- from `deinit`, which covers a host thread that posted while shutdown was
  already under way.

Removing mailbox events without touching the mailbox semaphore is safe only
because nothing calls `Mailbox.wait` after the loop returns; that is stated
at the function.

`localAppend` reports the shutdown marker as `error.Canceled`, not
`error.Refused`. The distinction is real and worth keeping: the cluster
refused nothing. The entry may still be in the durable queue and may slot on
a later start, so `Refused` would be a false statement about the write.

## Verification

- The new test fails with `expected 1, found 0` on the parked completion
  before the change and passes after.
- `zig build test` green on the branch.

## Follow-up

`localAppend`'s wait still has no timeout of its own. This fix removes the
one place the loop was guaranteed never to answer; it does not give a host a
bound on how long a reachable-but-slow cluster may take.

## References

- Code: `src/cluster/node.zig` (`releaseLocalWaiters`, `loopMain`, `deinit`,
  `localAppend`, `localReadRange`)
- PRD: [PRD 0005](../../prds/0005-embedding-the-library-as-the-product.md)
  step 1, the embedded write path
- Related: [2026-08-28 - `ClusterNode.localAppend` completions are lost
  during backfill/merge](2026-08-28-localappend-completion-lost.md) and
  [2026-08-29 - `reforwardQueue`'s leader-slot branches never complete
  `pending_locals`](2026-08-29-reforward-queue-loses-local-completion.md),
  which cover sites *while the loop runs*
- Fix: this PR
