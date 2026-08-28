# Bug — `zig build test` is red: `Hub.deinit(self, io)` called with no arguments at three test sites

## TL;DR

- **What failed:** `zig build test` fails to compile the `src/root.zig` test root: `Hub.deinit` takes `(self, io)` but three test blocks call `hub.deinit()`.
- **Impact:** The blocking CI gate is red; every unit test under `src/root.zig` (78 tests) is unreachable until fixed.
- **Resolution:** Still open.

## Status

Open. The arity change is from `51caeb09`; the three 0-arg call sites are from `5dd066ce` ("chore(sec): apply review findings", merged via the 65e review stack).

## Symptom and impact

`zig build test` exits 1 with:

```
src/cluster/node.zig:2486:14: error: member function expected 1 argument(s), found 0
    defer hub.deinit();
          ~~~^~~~~~~
src/net/transport.zig:438:9: note: function declared here
    pub fn deinit(self: *Hub, io: std.Io) void {
referenced by:
    test.all public declarations analyze: src/root.zig:91:37
```

Three call sites are affected:
- `src/cluster/node.zig:2486` (test "append without hello is dropped and does not write")
- `src/cluster/node.zig:2535` (test "hello whose member id does not derive from the key is refused")
- `src/net/transport.zig:706` (test "hub send refuses an oversized frame")

Because the `root.zig` test root fails to compile, none of the library's unit tests run under the gate.

## Reproduction

```bash
zig build test
```

Expected: 78+ unit tests run and the gate exits 0. Actual: the compile error above, exit 1. (`zig build lint` passes; the examples' test binaries pass when run directly.)

## Root cause

`51caeb09` changed `Hub.deinit` from 0-arg to `(self: *Hub, io: std.Io)` — the io is needed to close the hub's pipes/directions. The later `5dd066ce` added three test blocks (in `node.zig` and `transport.zig`) whose `defer hub.deinit();` lines were written (or copy-pasted) against the old signature. The other call sites in the same files were updated correctly (`hub.deinit(tio)` at `transport.zig:623, 666, 725` and `node.zig:2411, 2618, 2907, 3122, 3300, 3405, 3494`), so only the three new tests from that commit are wrong — which is why the suite was never green after the merge.

## Resolution

Not yet fixed. Suggested fix: pass the test's `io` at each of the three sites — `defer hub.deinit(tio);` (both `node.zig` tests and the `transport.zig` test have `tio = std.testing.io` in scope). Then `zig build test` must compile and run the full root test root.

## Verification

Confirmed by reproduction on a clean worktree. The `root.zig` compile step fails with the exact message above; the three locations are the only mismatched call sites (grep for `hub.deinit(` confirms all other sites pass `tio`).

## Follow-up

None — this is a straight arity fix. Prevention: the review stacks that produced `5dd066ce` were merged without a green `zig build test`; consider gating merges on it.

## References

- Code: `src/net/transport.zig:438` (signature), `src/cluster/node.zig:2486,2535`, `src/net/transport.zig:706` (call sites)
- Fix: none
