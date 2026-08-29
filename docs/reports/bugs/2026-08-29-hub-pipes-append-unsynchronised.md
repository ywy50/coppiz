# Bug - the in-memory hub's `pipes` list is appended without a lock: concurrent dials leak its backing buffer

## TL;DR

- **What failed:** `cluster.node.test.e2e (b)` intermittently fails the leak check with one leaked allocation, traced to `std.ArrayListUnmanaged.ensureTotalCapacityPrecise` under `HubDialer.connectFn`.
- **Impact:** `zig build test` is intermittently red with `1 leaks` and 0 failed tests. Observed twice in roughly ten local runs, on two different branches and two different bases.
- **Resolution:** Open. The mechanism is identified; the fix is in `src/net/transport.zig`, which this session does not own.

## Status

Open. Filed by the session working `src/journal/`, `src/settings/`,
`src/config/` and `src/main.zig`; the code is in `src/net/`, so the fix is
left to that file's owner.

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

Not fixed here. The shape a fix would take is a `std.Io.Mutex` on `Hub`
held across `pipes.append`, the `endpoints` lookup and the `dropped` check,
matching what `Endpoint` already does for `pending`. Confirming which of the
two mechanisms fires would need a run under a thread sanitizer or an
instrumented `append`.

## Verification

None - the defect is open.

## Follow-up

While it is open, a `1 leaks` line in `cluster.node` e2e (b) with all tests
passing is this bug rather than the change under test. Re-run before
investigating a diff, and gate an untouched base when it recurs.

## References

- Investigation: none
- Code: `src/net/transport.zig` (`Hub`, `HubDialer.connectFn`),
  `src/cluster/node.zig` (`dialMain`)
- Related: [2026-08-28 - `HubListener.closeFn` writes `endpoint.closed` without the endpoint mutex (latent)](2026-08-28-hub-listener-close-race.md)
