# Bug - a cancelled `localReadRange` leaks the whole range the loop copied for it

## TL;DR

- **What failed:** `ClusterNode.localReadRange` armed `defer deinitLocalRead(&completion, ...)` *after* the `completion.sem.wait(io) catch return error.Canceled`, so the one exit that skipped the cleanup was the one where the loop had most likely already filled the completion.
- **Impact:** An embedded host whose read task is cancelled leaks the record list plus one heap allocation per entry payload in the range - the whole range, not a fixed overhead. A host that cancels reads (a request deadline, a shutting-down worker) leaks per cancelled read for the life of the process.
- **Resolution:** Fixed 2026-08-31: the `defer` is armed before the wait.

## Status

Resolved.

## Symptom and impact

`localReadRange` (PRD 0005) is the embedded-host read path: it posts a `local_read` event and blocks on the completion's semaphore while the loop runs the range over its own state and copies every visible record in. The copies are the waiter's to free - `LocalReadCompletion`'s own doc comment says so ("`records` is owned by the completion and freed by whoever waits on it"), and `deinitLocalRead` frees each `rec.entry.payload` and then the list.

On `9765d30` the order was:

```zig
var completion = LocalReadCompletion{ .allocator = self.allocator };
if (!self.mailbox.post(io, .{ .local_read = .{ ... } })) {
    completion.err = error.MailboxFull;
} else {
    completion.sem.wait(io) catch return error.Canceled;   // returns before the defer exists
}
defer deinitLocalRead(&completion, self.allocator);
if (completion.err) |err| return err;
```

A `defer` is registered when control reaches it, so the `error.Canceled` return above it runs no cleanup. Nothing else can: once the host's frame is gone, the only pointer to `completion` is gone with it.

The size of the leak is the size of the answer. Every record costs a `LocalRecord` slot in the list, and every record that still has its payload costs a `dupe` of that payload (`onLocalRead`). A cancelled read of a large page therefore leaks that whole page.

`localAppend`'s completion holds no allocations, so the same early return there leaks nothing.

## Reproduction

Preconditions: a `ClusterNode` whose loop is not running, so the test can play the loop's part deterministically instead of racing it.

1. Call `localReadRange` on its own `std.Io.Group` task, so the wait can be cancelled. It posts the `local_read` event and parks on the completion.
2. Take that event off the mailbox, exactly as the loop does before handling it. (This also keeps `deinit`'s `releaseLocalWaiters` off the task's frame afterwards.)
3. Do `onLocalRead`'s copy step by hand - append one `LocalRecord` with a duped payload - and *not* its `completeLocalRead` post. That is the state the loop leaves behind whenever the host's wait loses the race to a cancellation.
4. Cancel the group and await it.

Expected: the host returns `error.Canceled` and the record list and its payload are freed. Actual, before the fix: the host returns `error.Canceled` and both allocations are still live, which `std.testing.allocator` reports.

The window in production is the ordinary one for two threads: `Io.Semaphore.wait` is `mutex.lock(io)` then `while (permits == 0) cond.wait(io, &mutex)`, and a cancellation that lands on the parked `cond.wait` returns `error.Canceled` whether or not `onLocalRead` has already posted a permit. Not observed in a live run - the test drives the state, not the race.

## Root cause

The `defer` was placed after the early `return` it needed to cover. Read top to bottom the function looks like it cleans up on every path, because the `defer` precedes both remaining returns; the cancellation return is the one that jumps out above it.

## Resolution

Arm the `defer` immediately after `completion` is initialised, before the post and the wait. Every exit from that point on frees the records: the `MailboxFull` path (nothing to free), the cancellation path (whatever the loop copied), the `completion.err` path, and the normal path after `on_entry` has replayed the copies. No other behaviour changes - the callback still runs on the host's thread over the copies, and the returned errors are unchanged.

## Verification

- `cluster.node.test."a cancelled localReadRange frees the records the loop already copied"`, the reproduction above. Observed failing on `9765d30` for the intended reason - two leaks, at the two allocation sites the loop uses:

  ```
  error: 'cluster.node.test.a cancelled localReadRange frees the records the loop already copied' leaked 2 allocations:
    [DebugAllocator] (err): memory address 0x10fb80000 leaked:
      ... in dupe__anon_8301
      src/cluster/node.zig:6893: .payload = try read.completion.allocator.dupe(u8, "x"),
    [DebugAllocator] (err): memory address 0x10fae2400 leaked:
      ... in addOne
      src/cluster/node.zig:6880: const rec = try read.completion.records.addOne(...)
  ```

  Passing after the fix. The assertion is the testing allocator's own leak check plus `error.Canceled` on the host's return, so the test cannot pass by not reaching the cancellation.
- `zig build test --summary all` green; the `Build Summary` line is in the pull request.

## Follow-up

A cancelled `localReadRange` leaves its `local_read` event in the mailbox holding a pointer to the returned frame, and `localAppend`'s cancellation path leaves the same dangling `*LocalCompletion` in `pending_locals`. `releaseLocalWaiters` writes through both during shutdown. That is a separate defect from this leak - it is about the completion outliving its waiter, not about who frees the records - and it is not addressed here.

## References

- Investigation: none
- Code: `src/cluster/node.zig` (`localReadRange`, `LocalReadCompletion`, `deinitLocalRead`, `onLocalRead`)
- PRD: [PRD 0005](../../prds/0005-embedding-the-library-as-the-product.md) (the embedded-host read path)
- Fix: this change
