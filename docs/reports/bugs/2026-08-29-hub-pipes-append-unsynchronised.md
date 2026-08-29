# Bug - the in-memory hub's `pipes` list is appended without a lock: concurrent dials leak its backing buffer

## TL;DR

- **What failed:** `cluster.node.test.e2e (b)` intermittently fails the leak check with one leaked allocation, traced to `std.ArrayListUnmanaged.ensureTotalCapacityPrecise` under `HubDialer.connectFn`.
- **Impact:** `zig build test` is intermittently red with `1 leaks` and 0 failed tests. Observed twice in roughly ten local runs, on two different branches and two different bases.
- **Resolution:** Fixed. `Hub` has a mutex, and `connectFn` holds it across the drop check, the endpoint lookup and the `pipes` append.

## Status

Resolved. Filed by the session working `src/journal/`, `src/settings/`,
`src/config/` and `src/main.zig`; fixed by the session owning `src/net/`.

## Symptom and impact

```
test
+- run test 195 pass (195 total); 1 leaks
error: 'cluster.node.test.e2e (b): partition a 2-member seniority cluster,
write on both sides, heal, merge' leaked 1 allocations:
  [DebugAllocator] (err): memory address 0x106a80d00 leaked:
  .../lib/std/array_list.zig:1235:56: in ensureTotalCapacityPrecise (test)
  .../lib/std/array_list.zig:1211:51: in ensureTotalCapacity (test)
  .../lib/std/array_list.zig:1265:41: in addOne (test)
  .../lib/std/array_list.zig:904:49: in append (test)
  .../src/net/transport.zig:657:34: in connectFn (test)
      try self.hub.pipes.append(hub_alloc, pipe);
  .../src/net/transport.zig:91:31: in connect (test)
  .../src/cluster/node.zig:733:52: in dialMain (test)
  .../lib/std/Io/Threaded.zig:552:22: in start (test)
```

Every test passes; only the leak check fails, so the build exits 1 with a
green-looking test line. The leaked address is the array list's *backing
buffer*, not a `Pipe`, which is what points at the growth path rather than
at pipe ownership.

Observed on `fix/chainless-null-epoch` at 411db85 and again on
`feat/settings-at-slot` cut from 3456e14 - that is, it survives
[#135](https://github.com/ywy50/coppiz/pull/135), which fixed a different
hub leak (the duplicate drop edge key). Three consecutive runs of an
untouched `origin/main` at 3456e14 were green, so it is timing-dependent,
not a property of any one tree.

## Reproduction

Not reliable on demand. `zig build test` in a loop reproduces it in a
minority of runs; it appeared more readily when the machine was also
building in another worktree, which is consistent with a thread-interleaving
race.

## Root cause

`Hub` guards nothing:

```zig
pub const Hub = struct {
    allocator: std.mem.Allocator,
    endpoints: std.StringHashMapUnmanaged(*Endpoint) = .empty,
    dropped: std.StringHashMapUnmanaged(void) = .empty,
    pipes: std.ArrayListUnmanaged(*Pipe) = .empty,
```

`Endpoint` has its own mutex and uses it for `pending`, but `Hub`'s three
fields have none. `HubDialer.connectFn` runs on the dialing node's own
thread (`cluster/node.zig` `dialMain`, spawned per peer), and the e2e (b)
scenario has several nodes dialling at once. Two `pipes.append` calls that
both need to grow each allocate a fresh backing buffer through
`ensureTotalCapacityPrecise` and then write `self.items.ptr`; the write that
lands second wins, and the loser's buffer has no owner left. That is exactly
one leaked allocation from that call site, with every `Pipe` still reachable
- which matches the report.

The same absence of synchronisation covers `self.hub.endpoints.get(to)` and
`self.hub.isDropped(self.from, to)` in the same function, which read hash
maps that `Hub.listen` and `Hub.drop` mutate. Those have not been observed
to fail; they are named here because they are the same class and the same
fix covers them.

Unverified: whether the leak can instead come from a dial that lands after
`Hub.deinit` has freed the list. It is possible on the same reasoning and
was not separated from the growth race by the evidence collected.

## Resolution

`Hub` gained a `std.Io.Mutex`, taken across every access to `endpoints`,
`dropped` and `pipes`:

- `HubDialer.connectFn` holds it from the drop check through the endpoint
  lookup to `pipes.append`, and releases it before `ep.pushConn`. The hub
  lock is never held across an `Endpoint` call, so the two mutexes cannot
  form a cycle.
- `listen`, `drop`, `heal` and `isDropped` take it too. Those four grew an
  `io` parameter, since `std.Io.Mutex` needs one; every call site is a test
  or an example.
- `isDroppedLocked` exists because the mutex is not recursive and
  `connectFn` needs the check while already holding it.

`Hub.deinit` is left unlocked: it runs at teardown, after every dialer and
listener is done, and it sets `self.* = undefined`.

The predicted mechanism is not *proven* to be the one that fired - the
original leak was never reproduced on demand, so there is nothing to
re-run as a control. What is established is that the concurrent access was
real and is now serialized. The honest claim is that the race is gone, not
that this specific leak has been observed to stop.

## Verification

- `zig build test --summary all` green: 23/23 steps, 295/295 tests, with the
  lock in and every call site updated.
- Not verified by reproduction: the leak is intermittent and was not
  reproducible on demand before the fix, so its absence in any one run
  proves nothing. See the caveat under *Resolution*.

## Follow-up

The follow-up note that a `1 leaks` line in e2e (b) is this bug no longer
applies; a leak there is now a real finding again.

## References

- Investigation: none
- Code: `src/net/transport.zig` (`Hub`, `HubDialer.connectFn`),
  `src/cluster/node.zig` (`dialMain`)
- Related: [2026-08-28 - `HubListener.closeFn` writes `endpoint.closed` without the endpoint mutex (latent)](2026-08-28-hub-listener-close-race.md)
