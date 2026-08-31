# Investigation - Two sighted hub defects that are not defects: `drop`'s directedness and `isDroppedLocked`'s OOM answer

## TL;DR

- **Question:** Two claims were handed over as sighted defects in `src/net/transport.zig`: that `Hub.isDroppedLocked` "reads a dropped edge as open", and that `Hub.drop` "is asymmetric - it does not affect both directions the way callers assume". Are they real?
- **Finding:** Neither is a defect. `isDroppedLocked` answers "not dropped" on exactly one path - `allocPrint` failing - which is documented in the function and was the deliberate outcome of an already-resolved bug. `drop` is a *directed* edge operation by its own contract, and all twelve non-transport call sites drop both directions in a pair; callers assume nothing.
- **Resolution:** Not applicable. No code change, and none recommended. Recorded so the next sweep does not re-sight them.

## Status

Closed - not a bug.

Reopening either would need something this pass did not find: for
`isDroppedLocked`, a caller that can reach the OOM path with a non-empty
`dropped` map and would be misled by the answer; for `drop`, a caller that
drops one direction and then behaves as though both were dropped.

## Trigger and scope

Both claims arrived second-hand, as line-number sightings ("~line 661",
"~line 602") from an earlier pass that filed nothing. They were checked at
`4cbf4c7`, together with two other claims from the same batch that **were**
real and are fixed separately:

- [2026-08-31-hub-push-drops-frame-on-oom.md](../bugs/2026-08-31-hub-push-drops-frame-on-oom.md)
- [2026-08-31-hub-listen-dialer-allocator-mismatch.md](../bugs/2026-08-31-hub-listen-dialer-allocator-mismatch.md)

Scope is the in-memory hub only. It is the fabric the tests and the simulator
run on; the served path is `TcpConn`/`tcpListen`.

## Evidence

**`isDroppedLocked`** (observed, by reading):

```zig
fn isDroppedLocked(self: *Hub, from: []const u8, to: []const u8) bool {
    const key = std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ from, to }) catch
        return false;
    defer self.allocator.free(key);
    return self.dropped.contains(key);
}
```

- The format string is byte-identical to `edgeKey`'s, which is what `drop`
  and `heal` use to write and remove the entry. Compared directly; the keys
  match, `\x00` separator included. So a *successful* check cannot miss a
  dropped edge.
- The single `false` that is not a map answer is the `catch`. The function's
  own doc comment names it, and so does the Resolution of bug
  2026-08-30-hub-dropped-edge-long-address: "OOM on the check still degrades
  to 'not dropped', which is the safe direction for a test-only transport."
- Argument order at the one production caller matches the writer's:
  `connectFn` calls `isDroppedLocked(self.from, to)`; `drop` stores
  `key(from, to)`. Checked against `node.zig:3907` (`drop("a","b")`) and a
  dialer bound to `"a"` dialing `"b"`.
- Reachability of the OOM path (inferred, not reproduced): the hub's one
  `FailingAllocator` sweep, `hubRound`, never calls `drop`, so `dropped` is
  empty on every iteration and `false` is the correct answer there anyway.

**`Hub.drop`** (observed, by reading and by grep):

- Its doc comment states the contract: "Partitions the directed edge
  `from -> to` ... Only the named direction is affected; a symmetric
  partition drops both ways."
- Within the named direction it is complete, handling both pipe
  orientations: for a pipe whose `from`/`to` match the edge it closes
  `pipe.out` (dialer -> endpoint), and for a pipe in the reverse orientation
  it closes `pipe.in`, which is the same sender's direction. Neither
  orientation is missed.
- Every call site outside `transport.zig` drops both directions in an
  adjacent pair: `src/cluster/node.zig:3907-3908`, `:4196-4199`,
  `:4810-4811`, and `examples/embed-cluster/main.zig:275-278`. Twelve calls,
  six symmetric partitions, no single-direction call among them.
- The three single-direction calls in `transport.zig` are the tests that
  exist to pin single-direction behaviour ("a dropped edge refuses dials and
  ends live connections", the long-address variant, and the double-drop
  key-leak test).

## Hypotheses and tests

| Hypothesis | Test | Result |
| --- | --- | --- |
| `isDroppedLocked`'s key differs from `edgeKey`'s, so a dropped edge is missed | Compared both format strings and allocators | Rejected - identical format, and the allocator only affects who frees |
| The check is called with `from`/`to` swapped relative to `drop` | Traced `connectFn` against `drop` and a real call pair in `node.zig` | Rejected - same order |
| The OOM `false` misleads a real caller | Looked for a caller that can OOM here with a non-empty `dropped` map | Not found; the one failing-allocator sweep never drops an edge |
| Callers assume `drop` is symmetric | Grepped every call site | Rejected - all twelve non-transport calls are explicit pairs |
| `drop` misses one pipe orientation within the named direction | Read the loop | Rejected - both orientations handled |

Rejected hypotheses are kept because "the dropped-edge check can answer
wrongly" and "drop only goes one way" both read as defects from a line
number alone, and both are one grep from being closed.

## Finding

The `isDroppedLocked` sighting is a re-sighting of the documented residual of
an already-resolved bug, not a new one. Changing it - propagating
`OutOfMemory` out of `connectFn`, say - would be speculative hardening on an
unreachable path, and it would reverse a decision this repository already
made and wrote down, with no new evidence to justify that.

The `drop` sighting mistakes an explicit contract for an oversight. `drop`
takes a directed edge because a one-way partition is a scenario worth
building, and a symmetric one is two calls; the tree only ever writes the two
calls.

Worth carrying forward: the sighting the previous pass got right, and the two
it got wrong, are indistinguishable from a line number and a one-line claim.
All four needed the same treatment - read the function, read its doc comment,
grep its callers, and look for the resolved report that already covers it.

## Resolution or handoff

No change. The two real defects from the same batch are fixed under the bug
reports linked above.

## References

- Related bugs: [2026-08-30-hub-dropped-edge-long-address.md](../bugs/2026-08-30-hub-dropped-edge-long-address.md) (the resolved report whose documented residual is the `isDroppedLocked` sighting), [2026-08-31-hub-push-drops-frame-on-oom.md](../bugs/2026-08-31-hub-push-drops-frame-on-oom.md), [2026-08-31-hub-listen-dialer-allocator-mismatch.md](../bugs/2026-08-31-hub-listen-dialer-allocator-mismatch.md)
- Code: `src/net/transport.zig` (`Hub.drop`, `Hub.heal`, `Hub.isDroppedLocked`, `Hub.edgeKey`, `HubDialer.connectFn`), `src/cluster/node.zig` (`drop`/`heal` call pairs), `examples/embed-cluster/main.zig`
- Logs or run: none; static, at `4cbf4c7`
