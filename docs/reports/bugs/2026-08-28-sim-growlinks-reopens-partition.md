# Bug — Simulator `growLinks` reopens a closed partition every time a member joins

## TL;DR

- **What failed:** `World.growLinks` (called from `addMember`) fills the **entire** n×n link matrix with `true`, so every link that `partition` closed is silently reopened — while `partition_head`/`partition_sides` stay set.
- **Impact:** The simulator's core state model contradicts its own contracts: after `partition` + `addMember`, the two sides can hear each other again and broadcasts cross the partition, so any scenario relying on isolation (message counting, `.lost` views, a stall side that must stay authority-less) sees a healed world.
- **Resolution:** Still open. Reproduced dynamically.

## Status

Resolved — `growLinks` rebuilds the link matrix at the new stride,
preserving every link `partition` closed; regression test added.

## Symptom and impact

The simulator is the deterministic driver for pure logic ([OQ 27](docs/open-questions.md)); its liveness views (`stateOf` → `.lost`), the broadcast gate (`linkOpen`, used by `slotAndBroadcast`), and `heal` all key off `links`. `growLinks` silently heals the world underneath them.

## Reproduction

Validated by a temporary test added to `sim.zig` (reverted after the run):

```zig
const a: usize = 0;
const b = try world.addMember(memberKey(1), "node-b", a);
try world.assertConverged();
try world.partition(&.{ &[_]usize{a}, &[_]usize{b} });
try world.tick();
try world.tick();
_ = try world.addMember(memberKey(2), "node-c", b);
try std.testing.expect(!world.linkOpen(a, b)); // FAILS: linkOpen(a,b) == true
```

The test fails with `TestUnexpectedResult` — `linkOpen(a, b)` is `true` after the add, i.e. the partition is gone. This contradicts `addMember`'s docstring ("Works during a partition: the leader of a side admits, so the newcomer joins *that* side") and `partition`'s contract ("links across sets close, so each side can only hear itself"). The shipped tests don't trip because cross-side messages are unchainable (`prev_slot_hash` references a slot the other side dropped) and get discarded at `heal` — the isolation loss is masked, not absent.

## Root cause

`src/sim/sim.zig:168-179`:

```zig
fn growLinks(self: *World, n: usize) !void {
    while (self.links.items.len < n * n) {
        try self.links.append(self.allocator, false);
    }
    // New links start open; a partition closes the cross links and heal
    // reopens everything.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j: usize = 0;
        while (j < n) : (j += 1) self.links.items[i * n + j] = true;
    }
}
```

It only needed to initialize the *new* node's row and column (the appended `false` cells). As written it sets every cell to `true`, including cells that `partition` explicitly closed. `heal`'s "reopens everything" comment refers to the heal-time contract, not to member addition.

## Resolution

Fixed. The matrix width changes with the member count, so a flat
extension would shift every existing cell's (row, column) meaning — the
report's simpler "init only the new row/column" suggestion would still
misplace closed links. `growLinks` now copies the old matrix, resizes to
`n × n`, rewrites the old cells at the new stride, and explicitly opens
the newcomer's row and column (some of those cells sit in the old
matrix's flat range, so they must be set, not left to the resize).

Regression test ("growLinks keeps a partition's closed links closed when
a member joins"): partition a 2-node world, add a member, and assert the
cross links (`a → b`, `b → a`) stay closed while the newcomer can reach
its admitting side — the report's repro, previously
`TestUnexpectedResult`. The existing "partitioned joins merge" scenario
still passes with the links genuinely closed (the sides self-elect under
the default mode).

## Verification

- Dynamic: the temp test above fails exactly as described (`linkOpen(a, b)` returns true after `addMember` following a partition).
- Static: the full-matrix write is unambiguous in `growLinks`; `partition` (`sim.zig:439-462`) and the broadcast gate (`linkOpen`, `:182-184`) read the same matrix.

## Follow-up

None — contained to the simulator. Worth a test because the shipped "partitioned joins merge" scenario (sim.zig:852-883) exercises the exact sequence but never asserts isolation.

## References

- Code: `src/sim/sim.zig:168-179` (`growLinks`), `:182-184` (`linkOpen`), `:380+` (`addMember`), `:439-462` (`partition`)
- Fix: `src/sim/sim.zig` (`growLinks`); regression test in the same file. `zig build test` green.
