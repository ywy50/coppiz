# Bug — `zig build test` is red: `Hub.deinit(self, io)` called with no arguments at three test sites

## TL;DR

- **What failed:** `zig build test` fails to compile the `src/root.zig` test root: `Hub.deinit` takes `(self, io)` but three test blocks call `hub.deinit()`.
- **Impact:** The blocking CI gate is red; every unit test under `src/root.zig` (78 tests) is unreachable until fixed.
- **Resolution:** Still open.

## Status

Resolved — the three call sites pass the test's `io` (`hub.deinit(tio)`),
implemented in the test-build speedup work (investigation
[2026-08-28 — making `zig build test` faster without dropping tests](../investigations/2026-08-28-test-suite-quick-wins.md)).

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

Fixed as suggested: `defer hub.deinit(tio);` at all three sites
(`src/cluster/node.zig:2486,2535`, `src/net/transport.zig:706`; `tio =
std.testing.io` is in scope in each test). The signature change itself
(`51caeb09`, `deinit(self, io)`) is the correct API — the hub closes its
directions through the io.

## Verification

`zig build test --summary all`: `Build Summary: 21/21 steps succeeded;
242/242 tests passed`, exit 0 (three consecutive full runs; the two
root-required compile failures were the other red-suite bug
[2026-08-28 — `zig build test` is red: the CLI test root uses `std.c.getpid()` without linking libc](2026-08-28-build-test-red-libc-getpid.md)
plus this one). The `src/root.zig` test root compiles and all 152 library
tests run, including the cluster e2e suite at node.zig:2399-3553.

## Follow-up

None — this is a straight arity fix. Prevention: the review stacks that produced `5dd066ce` were merged without a green `zig build test`; the test-build speedup work (the investigation this fix belongs to) makes full runs practical again.

## References

- Code: `src/net/transport.zig:438` (signature), `src/cluster/node.zig:2486,2535`, `src/net/transport.zig:706` (call sites)
- Fix: working tree (see the investigation 2026-08-28 test-build speedup; not yet committed)
