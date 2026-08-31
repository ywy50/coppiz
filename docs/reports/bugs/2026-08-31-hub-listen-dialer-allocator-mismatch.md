# Bug - `Hub.listen`/`Hub.dialer` allocate from the caller's allocator and free through the hub's (latent)

## TL;DR

- **What failed:** `listen` took the endpoint, the listener, its address, the map key and the `endpoints` map growth from its `allocator` *parameter*; `Hub.deinit` and `HubListener.closeFn` free all of it through `hub.allocator`. `dialer` had the same split against `HubDialer.deinitFn`. Seven allocations per listen+dial pair go to one allocator and come back from another.
- **Impact:** Test and simulator fabric only (`Hub`), and **latent**: every caller in the tree - `src/cluster/node.zig`, `src/net/client.zig`, `examples/sidecar`, `examples/embed-cluster` and the hub's own tests - passes the same allocator it built the hub with, so the mismatch has never fired. It is not benign when it does: an arena as the hub's allocator aborts with `attempt to use null value` inside `ArenaAllocator.free` (observed, see Reproduction).
- **Resolution:** Fixed 2026-08-31. Both functions ignore the parameter and use `self.allocator`, the way `HubDialer.connectFn` already does.

## Status

Resolved 2026-08-31.

## Symptom and impact

The split, on `4cbf4c7`:

| allocated in | with | freed in | with |
| --- | --- | --- | --- |
| `listen` - `Endpoint` | `allocator` | `Hub.deinit` | `self.allocator` |
| `listen` - `HubListener` | `allocator` | `HubListener.closeFn` | `self.hub.allocator` |
| `listen` - listener address | `allocator` | `HubListener.closeFn` | `self.hub.allocator` |
| `listen` - `endpoints` key | `allocator` | `Hub.deinit` / `closeFn` | `self.allocator` |
| `listen` - `endpoints` growth | `allocator` | `Hub.deinit` | `self.allocator` |
| `dialer` - `HubDialer` | `allocator` | `HubDialer.deinitFn` | `self.hub.allocator` |
| `dialer` - `from` copy | `allocator` | `HubDialer.deinitFn` | `self.hub.allocator` |

`HubDialer.connectFn` - the third entry point, and the one whose signature is
fixed by the `Transport` vtable - had already decided the other way, and says
so: `_ = allocator; // connections are hub-owned; the caller's allocator is
unused`. Everything a `Hub` hands out is hub-owned and outlives the call, so
the hub is the only thing that can own the memory. The parameter on `listen`
and `dialer` was a claim the implementation could not keep.

Severity, stated plainly: `Hub` is the in-memory transport the tests and the
simulator run on. The production transport is `TcpConn`/`tcpListen`, which
takes no such parameter and is untouched. And it is latent even there: no
caller in the tree mismatches the two allocators.

## Reproduction

Two experiments, both on `4cbf4c7`.

**Graceful, and the shipped regression test.** A `FailingAllocator`
configured never to fail is a counter. Put the hub on `test_alloc`, hand the
counter to `listen` and `dialer`, and ask how much the hub took from its
caller:

```zig
var counting = std.testing.FailingAllocator.init(test_alloc, .{});
var hub = Hub.init(test_alloc);
var listener = try hub.listen(tio, counting.allocator(), "node-a");
var dialer = try hub.dialer(counting.allocator(), "node-b");
try std.testing.expectEqual(@as(usize, 0), counting.allocations);
```

Observed: `expected 0, found 7`. Both pointers land in `test_alloc` either
way here, which is what keeps this graceful rather than a crash.

**Not graceful, which is the point about severity.** The same shape with a
real second allocator - the hub on a `std.heap.ArenaAllocator`, `test_alloc`
handed to `listen`/`dialer` - does not leak quietly. It aborts:

```
thread panic: attempt to use null value
  .../std/heap/ArenaAllocator.zig:615:39 in free
    const node = arena.loadFirstNode().?;
  src/net/transport.zig:871 in deinitFn
    self.hub.allocator.free(self.from);
```

The arena has no node yet - nothing was ever allocated *from* it - so its
`free` unwraps a null. That is one allocator's reaction; `FixedBufferAllocator`
asserts slice ownership, and a debug GPA reports an invalid free. None of them
is a leak you would find later.

## Root cause

Two functions that take an allocator parameter, for objects whose lifetime is
the hub's and whose frees are therefore written against `hub.allocator`. The
parameter reads as a choice the caller gets to make, and the teardown paths -
in three different functions, none of them next to the allocation - do not
honour it.

## Resolution

Fixed 2026-08-31. `listen` and `dialer` take the parameter as `_` and use
`self.allocator` throughout, including `endpoints.put(self.allocator, ...)`
and `ep.allocator`, so `Endpoint.deinit` matches too.

The parameter is kept rather than removed, for two reasons: no call site has
to change (fourteen of them, several in files other agents are working in),
and `connectFn` cannot drop its own parameter anyway, so the ignored-parameter
shape already exists here and is now consistent across all three entry
points. Both doc comments say it is ignored and why.

## Verification

- Regression test "hub listen and dialer allocate from the hub's allocator,
  not the caller's" (`src/net/transport.zig`). Seen to fail on the parent
  `4cbf4c7` with `expected 0, found 7`, which is the mismatch measured rather
  than inferred.
- The arena experiment above was run once by hand on the parent to establish
  that the mismatch aborts rather than leaks. It is **not** shipped as a test:
  a panic is not a graceful failure, and it would abort the whole test binary
  rather than fail one test.
- Full `zig build test --summary all` green - see the resolving PR for the
  quoted `Build Summary` line.

## Follow-up

The stronger check - that the hub takes *nothing* from a caller-supplied
allocator on any path - is what the shipped test asserts for `listen` and
`dialer`. `connectFn` is covered by inspection only (it discards its
parameter explicitly and takes `hub_alloc` for every allocation); no test
counts its caller's allocator.

## References

- Code: `src/net/transport.zig` (`Hub.listen`, `Hub.dialer`, `Hub.deinit`, `HubListener.closeFn`, `HubDialer.connectFn`, `HubDialer.deinitFn`)
- Fix: this report's resolving commit
