# Bug - `zig build test` never finishes: three-node tests deadlock the `Io` thread pool

## TL;DR

- **What failed:** every three-node test runs on an `std.Io.Threaded` with the default `async_limit`, which is `cpu_count - 1`. Three `ClusterNode`s need more async slots than that, so the third `start()` never returns and the test hangs forever. Two sites: `examples/embed-cluster` (its own `Io`) and `src/cluster/node.zig`'s `triNodeInit` (the shared `std.testing.io`).
- **Impact:** the merge gate does not fail, it hangs. On a 12-core machine `zig build test` sat at 0% CPU indefinitely; runs were still hanging 16 hours later.
- **Resolution:** Fixed - both sites ask for 64 async slots.

## Status

Resolved.

## Symptom and impact

`zig build test` printed the `embed-single` and `sidecar` example lines and
then stopped producing output, with the build runner and two test binaries
alive at 0% CPU. There is no failure message and no timeout, so the run looks
like a slow test rather than a hang.

Two different tests hang with the same shape. A `sample` of the first hung
test binary names it and the exact frame:

```
main.test.embed-cluster: three embedded nodes join, host appends, a partition heals into one chain
  main.runDemo (main.zig:212)
    main.spawnNode (main.zig:112)
      cluster.node.ClusterNode.start (node.zig:381)
        Io.Group.async
          Io.Threaded.groupAsync (Threaded.zig:2200)
            Io.Threaded.groupAsyncEager (Threaded.zig:2235)
              cluster.node.ClusterNode.timerMain (node.zig:700)
                Io.sleep -> nanosleep
```

The main thread is inside `start()`, running `timerMain` *itself*. Every other
thread in the pool is parked in `PipeConn.recvFrame`, `Hub.Endpoint.acceptConn`
or the loop's mailbox wait.

With the example fixed, the run gets further and hangs again in the same
frame from the other three-node site:

```
cluster.node.test.e2e (c): configured leadership with a stall fallback never elects without its authority
  cluster.node.triNodeInit (node.zig:3201)
    cluster.node.ClusterNode.start (node.zig:381)
      Io.Threaded.groupAsyncEager -> cluster.node.timerMain -> Io.sleep
```

## Reproduction

On a machine with 12 logical CPUs:

```sh
zig build test
```

It hangs after the `sidecar` line. `zig build examples` alone reproduces it in
less time, and was the loop used to verify the fix.

## Root cause

`std.Io.Threaded.init(gpa, .{})` leaves `async_limit` null, and `init`
defaults it to `.limited(cpu_count - 1)` - 11 slots here. Past the limit,
`groupAsync` falls through to `groupAsyncEager`, which runs the task on the
calling thread; a task that never returns therefore never returns from
`async` either.

Each `ClusterNode` holds three slots for the life of the node -
`loopMain`, `timerMain` and `acceptMain` (`ClusterNode.start`) - plus one
`readerMain` per connection and a transient `dialMain` per dial. A
three-member mesh is 9 permanent plus 6 readers, so it needs 15 before any
dial. The example asks for none of that.

The threshold is the machine's core count, which is why the example has run
green elsewhere: 17 or more logical CPUs leave enough slots. Nothing in the
example or the library states the requirement, so the failure moves with the
hardware.

## Resolution

Both `std.Io.Threaded.init` calls in `examples/embed-cluster/main.zig` (the
`main` entry point and the test) pass `.async_limit = .limited(64)`, and
`triNodeInit` calls `std.testing.io_instance.setAsyncLimit(.limited(64))`
before it starts a node - the node tests share the test runner's `Io`, which
is the only handle on it. Both carry a comment stating the per-node cost and
why the default is not enough. 64 is comfortably above three nodes' 15 and is
not a per-CPU quantity, so it does not reintroduce a hardware-dependent
threshold.

`src/cluster/` is not this change's usual territory; the one-line helper
change is included because the gate cannot be run to completion without it,
and it is confined to a test helper.

## Verification

- `zig build test` on an otherwise untouched `origin/main` (0ac56e7) hangs;
  `sample` of the hung binary names `embed-cluster` and, once that is fixed,
  `e2e (c)`.
- `zig build examples` with only the example's change applied completes and
  prints `embed-cluster: 3 members joined, host appended via leader and
  follower, healed`.
- `zig build test` green on the branch.

## Follow-up

The requirement belongs in the library, not only in one example: a host that
embeds `ClusterNode` on a default `Io` has the same ceiling, and PRD 0005 G5
("no thread exists before `run()`") is about the same resource without
naming a budget. Two things are left open here: whether `ClusterNode` should
document (or check) the async slots it needs, and whether the per-connection
`readerMain` should share a slot. Both are `src/cluster/` decisions.

## References

- Investigation: none
- Code: `examples/embed-cluster/main.zig`, `src/cluster/node.zig`
  (`triNodeInit`); the slot cost is `src/cluster/node.zig` (`start`,
  `spawnDial`, the reader spawn in `onConnReady`)
- Contract: [PRD 0005](../../prds/0005-embedding-the-library-as-the-product.md)
