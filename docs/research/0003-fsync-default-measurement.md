# Research - Per-append fsync cost at the leader (OQ 14)

## Status

Resolved for the question asked - measured 2026-08-29.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Is `storage.fsync = every` on the leader acceptable at clanker's write rates
(tens of appends per second, not thousands)? OQ 14
blocks no phase - the default shipped with PRD 0001 phase 3 - but whether the
default is right stayed open for measurement. What the knob governs is
decided separately ([ADR 0008](../adrs/0008-storage-fsync-governs-the-queue.md)).

## TL;DR

- A synchronous append (write + fsync) costs ~5-10 ms p50-p99 on this
  machine (4 KiB payload, btrfs on NVMe, under load) - `medium`, one
  machine and one filesystem.
- The leader's serial write path therefore sustains ~100-200 durable
  appends/s before fsync is the bottleneck. clanker's tens-per-second rate
  (10-50 appends/s) uses a small fraction of that, so `every` on the leader
  is acceptable - `medium`.
- `batched` on followers stays safe: a follower that loses its tail
  re-backfills, so its durability barrier is a performance choice, not a
  safety one.

## Harness

- Machine: AMD Ryzen 9 7950X, 32 cores, Linux 7.2.0-1-cachyos x86_64, Zig
  0.16.0.
- Filesystem: btrfs on /dev/nvme0n1p3 (NVMe). The machine's /tmp is tmpfs,
  where sync reports ~1 us and is meaningless; the benchmark must run on a
  disk-backed path.
- Method: the program in the Appendix appends N fixed-size records to a
  fresh file, calling `file.sync` after each, and reports the write+sync
  time distribution.
- Load: the machine was under concurrent build load (load average ~4-6)
  during the run, so the numbers are upper-bound-ish for this disk.
- Runs: 4 KiB x 200, 64 KiB x 200, 4 KiB x 200 repeat (warm), 2026-08-29.

## Results

| Run | Mean | p50 | p90 | p99 | Max |
|---|---|---|---|---|---|
| 4 KiB, 200 appends | 7.2 ms | 5.2 ms | 10.0 ms | 10.2 ms | 10.3 ms |
| 64 KiB, 200 appends | 9.3 ms | 9.9 ms | 10.1 ms | 10.5 ms | 14.8 ms |
| 4 KiB, 200 (warm repeat) | 8.3 ms | 9.8 ms | 10.1 ms | 11.2 ms | 11.8 ms |

## Analysis

The leader's append path does one fsync per accepted append under `every`.
At the measured ~5-10 ms per-op barrier, one leader serializes at ~100-200
durable appends/s. clanker's rate is tens per second, so the leader spends
well under half its write-path time on fsync and keeps headroom. `every`
on the leader stands as the default; the knob's own shape is ADR 0008's
decision, and this measurement is what OQ 14 asked for.

## Open questions

None for the question asked. The follower-side `batched` path has no
batching point in the loop yet (RFC 0003's option A noted the same); when
one lands, `.batched` becomes a real choice and this measurement bounds
its value.

## What would change the answer

- clanker measuring more than ~100 appends/s on a single leader.
- A deployment where per-op fsync is an order of magnitude worse: a
  spinning disk, a network filesystem, or zfs with sync=always.
- The write path gaining a batch point, which changes what `batched` means
  on the leader too.

## References

- OQ 14 - the question this measurement settles.
- [ADR 0008](../adrs/0008-storage-fsync-governs-the-queue.md) - what the
  knob governs.
- [PRD 0001](../prds/0001-journal-core.md) - the write path and the fsync
  default.

## Appendix

The benchmark program, verbatim (run on a disk-backed path):

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(gpa);
    while (args.next()) |a| try argv.append(gpa, a);
    const payload: usize = if (argv.items.len > 1) try std.fmt.parseInt(usize, argv.items[1], 10) else 4096;
    const n: usize = if (argv.items.len > 2) try std.fmt.parseInt(usize, argv.items[2], 10) else 100;

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, "bench-data") catch {};
    try cwd.createDirPath(io, "bench-data");
    var dir = try cwd.openDir(io, "bench-data", .{});
    defer dir.deleteTree(io, "bench-data") catch {};
    var file = try dir.createFile(io, "tail", .{ .read = false, .truncate = true });
    defer file.close(io);
    const payload_bytes = try gpa.alloc(u8, payload);
    defer gpa.free(payload_bytes);
    @memset(payload_bytes, 0xab);

    const times = try gpa.alloc(u64, n);
    defer gpa.free(times);
    var off: u64 = 0;
    for (0..n) |i| {
        const t0 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        try file.writePositionalAll(io, payload_bytes, off);
        off += payload;
        try file.sync(io);
        const t1 = std.Io.Timestamp.now(io, .awake).toNanoseconds();
        times[i] = @intCast(t1 - t0);
    }
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    const p50 = times[times.len * 50 / 100];
    const p90 = times[times.len * 90 / 100];
    const p99 = times[times.len * 99 / 100];
    var s: u64 = 0;
    for (times) |t| s +|= t;
    std.debug.print("payload={d} appends={d}\n", .{ payload, n });
    std.debug.print("mean {d}us p50 {d}us p90 {d}us p99 {d}us max {d}us\n",
        .{ s / n / 1000, p50 / 1000, p90 / 1000, p99 / 1000, times[times.len - 1] / 1000 });
}
```
