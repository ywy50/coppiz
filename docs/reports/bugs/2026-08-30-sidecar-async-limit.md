# Bug - the sidecar example deadlocks on 1-CPU hosts

## TL;DR

- **What failed:** the sidecar example and its test start a `ClusterNode`
  (loop, timer, accept and reader tasks) on a default
  `std.Io.Threaded` io. The default async limit is `cpu_count - 1`, which
  is zero on a 1-CPU host, where `groupAsync` runs tasks eagerly and
  `start()` never returns.
- **Impact:** the example and its test hang on 1-CPU machines (common in
  CI containers). `embed-cluster` hit and fixed exactly this (bug
  2026-08-29-embed-cluster-async-limit-deadlock); the sidecar was missed.
- **Resolution:** Resolved - the sidecar test sets the same explicit
  async limit embed-cluster uses.

## Status

Resolved.

## Symptom and impact

`examples/sidecar/main.zig` (test "sidecar: a host speaks to a node over
the wire"):

```zig
var io_state = std.Io.Threaded.init(gpa, .{});
```

`Threaded` defaults `async_limit` to `.limited(cpu_count - 1)`
(std/Io/Threaded.zig); on a 1-CPU host that is `.limited(0)`, and
`groupAsync` then runs every task eagerly on the calling thread - so
`cn.start()`'s first `group.async` never returns. The embed-cluster
example fixed this with `.limited(64)` (cited as bug
2026-08-29-embed-cluster-async-limit-deadlock); the sidecar kept the
default.

## Reproduction

Run the sidecar test on a 1-CPU host: it hangs.

## Root cause

The Threaded io's default async limit is CPU-dependent and zero on
single-CPU hosts, where the async machinery degrades to eager execution and
`start()` blocks forever.

## Resolution

Fixed: the sidecar test inits the io with `.async_limit = .limited(64)`,
matching embed-cluster.

## Verification

- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: examples/sidecar/main.zig
- Fix: this report's resolving commit
