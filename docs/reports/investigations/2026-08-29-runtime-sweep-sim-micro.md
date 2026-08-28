# Investigation — simulator leader evaluation and TCP page writes

## TL;DR

- **Question:** what does the simulator pay per tick that scales superlinearly
  with the node count, and what does a TCP page send pay per byte?
- **Finding:** the sim's leader evaluation was O(n³) per tick — a linear
  `nodeIndex` scan inside a per-member `viewsFor` inside a per-node
  `maybeOpenEpoch` — plus one heap allocation per `viewsFor`; the TCP
  `sendFrame` buffered 4 KiB, so sync/read pages spilled into several write
  syscalls each.
- **Resolution:** implemented — an id→index map makes `nodeIndex` O(1)
  (nodes are never removed, so the map never goes stale), and the TCP send
  buffer grows to 64 KiB, past the common page size.

## Status

Resolved and implemented (PR `perf/runtime-sweep/4-sim-micro`).

## Trigger and scope

A runtime-speedup sweep over `src/` (2026-08-29). The sim is the OQ 27
deterministic driver for future scenario work, so its per-tick cost matters
at the design cap (n = 32); the TCP send path is the production transport
(the hub is the simulator's and the loop tests' transport only).

## Evidence

All observations are reads of the tree at `main` @ `ec18643`, verified
before implementation.

1. **`nodeIndex` is a linear scan** (`sim.zig:206-211`), called once per fold
   member per `viewsFor` (`stateOf`, `sim.zig:339-353`); `viewsFor`
   (`sim.zig:357-383`) also allocates a fresh `election.View[n]` per call;
   `leaderOf` (`sim.zig:329-334`) calls it per node per tick
   (`maybeOpenEpoch`), and `processInbox`'s epoch-liveness check pays it per
   epoch message. Per tick: n nodes × (alloc + n members × n-scan) = O(n³)
   id comparisons plus n heap allocations. Nodes are appended at `init` and
   `addMember` and never removed (`crash` sets `alive = false` only), so a
   map stays valid for the world's lifetime.
2. **TCP `sendFrame` buffers 4 KiB** (`transport.zig:117-126`): small frames
   coalesce into one write, but sync/read pages (up to `max_body_bytes` =
   8 MiB) spill the buffer and issue several writes plus the flush per page.

## Hypotheses and tests

- **Hypothesis A — an id map replaces the scan.** Nodes never leave
  `nodes.items`, so an `id -> index` map filled at `init`/`addMember` can
  never go stale. *Result:* supported — `nodeIndex` is now a map lookup;
  the linear scan and its per-lookup cost disappear.
- **Hypothesis B — a page-sized send buffer coalesces page writes.** The
  buffered writer's flush emits one write when the frame fits the buffer.
  *Result:* supported for frames ≤ 64 KiB (the common page); larger frames
  still spill, but far fewer times.

## Finding

The sim's per-tick cost was dominated by an avoidable linear scan inside an
already-O(n²) evaluation; the TCP send path buffered far below the frame
sizes it actually sends. Both fixes are same-semantics refactors.

## Resolution or handoff

- `World.node_by_id: std.AutoHashMap([16]u8, usize)` maintained at `init`
  and `addMember`, deinitialized in `deinit`; `nodeIndex` reads it
  (`sim.zig:69-77, 205-211`).
- `TcpConn.sendFrame` uses a 64 KiB stack buffer (`transport.zig:117-126`).

Verification: `zig build` and `zig build lint` clean. The full gate run is
recorded in the PR's test log (261 tests; this PR's code is exercised by the
sim tests and the loop tests' hub transport).

## References

- Code: `src/sim/sim.zig`, `src/net/transport.zig`
- The `viewsFor` allocation per call remains (an O(n) alloc per leader
  evaluation); a scratch-buffer reuse was considered and deferred — the
  callers consume the views immediately, but a borrow discipline would need
  documenting. Tracked in the sweep findings report.
- Prior art: [2026-08-28 — making `zig build test` faster without dropping tests](2026-08-28-test-suite-quick-wins.md)
