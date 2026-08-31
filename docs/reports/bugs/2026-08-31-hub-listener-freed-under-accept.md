# Bug - `Hub` listener destroyed under an in-flight accept: `zig build test` crashes in `acceptFn`

## TL;DR

- **What failed:** `HubListener.closeFn` ran `allocator.destroy(self)` while a
  concurrent `accept` on the same listener could still be about to read
  `self.endpoint`. `zig build test` crashed with a segmentation fault inside
  `acceptFn`, roughly 1% of runs.
- **Impact:** the gate only. `Hub` is the in-memory transport for the tests and
  the simulator; the production path is `TcpConn` / `TcpListener` and does not
  route through `HubListener`.
- **Resolution:** Resolved - the listener is retired into `hub.retired_listeners`
  and freed at `Hub.deinit`, exactly as its endpoint already was, so a racing
  accept always reads live memory and observes the close as
  `error.ConnectionRefused`.

## Status

Resolved. Found while gating merged `main` `b42ef54`, which is the commit the
crash below was captured on.

## Symptom and impact

`zig build test` on `b42ef54`, in a clean detached worktree on an idle machine:

```
Build Summary: 23/25 steps succeeded (1 failed); 378/379 tests passed (1 crashed)
```

```
error: 'net.transport.test.hub connect and listen never double-free on allocation failure'
       terminated with signal ABRT with stderr:
       Segmentation fault at address 0x108f40018
       src/net/transport.zig:771:40: in acceptFn
               return self.endpoint.acceptConn(io);
       src/net/transport.zig:68:30: in accept
       src/net/transport.zig:1049:31: in acceptAndClose
           var conn = listener.accept(tio) catch return;
       (spawned on a std.Io.Group, running on an Io.Threaded worker)
```

The failure is intermittent, which is why it reached `main`: the same SHA gated
green at `25/25 / 379/379` on another run. Measured rate on the unmodified
parent, the standalone `src/net/transport.zig` test binary run 200 times with
random seeds: **2 failures in 200**. Several green gates in a row are therefore
not evidence that this is absent.

## Reproduction

The race can be provoked directly, but not reliably enough to gate on. A
standalone harness spawning `acceptAndClose` on a `std.Io.Group` and closing
underneath it faulted **4 times in 20 runs** - on an `Io.Threaded` worker
thread, at the same `acceptFn` site and frame shape as the gate crash - and
**hung 16 times**. The hangs are the harness's own artifact rather than the
bug: `Io.Group.async` can resolve to `Io.Threaded.groupAsyncEager` and run the
task inline on the calling thread, which serialises the accept behind the close,
so the main thread blocks in `Listener.accept` and nothing reaches the close.

The underlying invariant is deterministic, though, and reproduces every time:

```zig
var hub = Hub.init(test_alloc);
defer hub.deinit(tio);
var listener = try hub.listen(tio, test_alloc, "node-a");
listener.close(tio);
try std.testing.expectError(error.ConnectionRefused, listener.accept(tio));
```

On the parent, via `zig test src/net/transport.zig`:

```
9/27 transport.test.a closed hub listener is still readable by an accept that
     races the close...Segmentation fault at address 0x107780018
src/net/transport.zig:771:40: 0x1029cbf6c in acceptFn (test)
        return self.endpoint.acceptConn(io);
```

Same frame and same fault shape as the intermittent gate crash.

## Root cause

`closeFn` took deliberate care over one half of the accept path and not the
other. It *retires* the `Endpoint` into `hub.retired` rather than destroying it,
with a comment noting that a dial "may still be inside `pushConn`", which runs
without the hub lock. It then ended with:

```zig
self.hub.allocator.free(self.address);
self.hub.allocator.destroy(self);
```

`HubListener.acceptFn` begins:

```zig
const self: *HubListener = @ptrCast(@alignCast(ctx));
return self.endpoint.acceptConn(io);
```

The listener is the *first* hop of the accept path and the endpoint the second.
Retirement protected the second and freed the first, so an accept that had been
scheduled but had not yet loaded `self.endpoint` read freed memory. The fault
address is that load.

This was not caller error. `Listener.close` was documented as "the sole
destructor, and safe exactly once", but `hubRound` - the helper of the test that
crashed - spawns an accept and then closes the listener in a `defer`, with the
comment "Closing the listener wakes the blocked accept with a refusal". Waking a
blocked accept by closing is the intended contract; it just was not safe.

## Resolution

- `Hub` gains `retired_listeners: std.ArrayListUnmanaged(*HubListener)`,
  documented as `retired` one hop earlier. `Hub.deinit` frees each listener's
  address and destroys it.
- `closeFn` appends `self` to that list under the hub lock instead of freeing
  and destroying it. The endpoint retirement, the unregistration that frees the
  address for a re-listen, and the `closed` flag under the endpoint mutex are
  all unchanged.
- `listen` reserves the retirement slot with `ensureUnusedCapacity(1)` before
  its last fallible step, so the append at close is infallible. `closeFn`
  returns `void` and has no way to report a failed append, and the only
  fallback available there - destroying the listener - is the use-after-free
  this list exists to prevent.
- `Listener.close`'s doc comment now states the requirement on every
  implementation: it may not free the listener out from under an accept already
  in flight; the accept must observe the close and refuse.

No wire, on-disk or configuration change. No production behaviour change.

## Verification

- The deterministic test above fails on the parent with the segfault quoted, and
  passes with the fix.
- A second test closes two listeners, re-listens on a freed address and calls
  `hub.deinit`, so `test_alloc`'s leak detector proves the retirement did not
  turn the old free into a leak.
- Standalone `src/net/transport.zig` binary, 200 runs with random seeds:
  **parent 2 failures, fixed tree 0 failures.**
- Full gate on the fix: `Build Summary: 25/25 steps succeeded; 381/381 tests
  passed`, exit 0. Baseline on `b42ef54` when it does not crash is 379; the two
  added tests account for the difference.

## Follow-up - not fixed here

`TcpListener.closeFn` has the identical shape on the **production** path:

```zig
self.server.deinit(io);
self.allocator.destroy(self);
```

while `acceptFn` dereferences `self.server`. The hub's remedy does not transfer -
there is no hub to own the retirement - so the fix is either for the owner to
join its accept task before closing, or for `TcpListener` to carry its own
liveness. Whether any current caller closes a TCP listener while an accept is
blocked on it has **not** been established, so this is recorded as unverified
rather than as a live defect.
