# Bug - the 1 → 2 → 3 growth e2e intermittently times out waiting for the last replicated entry

## TL;DR

- **What failed:** `main.test.process-level: a live cluster grows 1 → 2 → 3 members over TCP` intermittently fails at `pollRead(&c, "m2")` with `error.Timeout` after its 20 s deadline. Every other test in the run passes.
- **Impact:** `zig build test` is intermittently red. Observed three times in roughly a dozen local runs.
- **Resolution:** Open. A candidate mechanism is identified statically and is *not* confirmed to be what fires.

## Status

Open. Filed by the session working `src/journal/`, `src/settings/`,
`src/config/` and `src/main.zig`. The test lives in `src/main.zig`, but the
candidate mechanism is in `src/cluster/node.zig`, so no fix is attempted
here.

## Symptom and impact

```
error: 'main.test.process-level: a live cluster grows 1 → 2 → 3 members over
TCP, founder stays leader' failed:
       .../src/main.zig:1426:5: in pollRead (test)
           return error.Timeout;
       .../src/main.zig:1397:20: in test.process-level: a live cluster grows
           const read_c = try pollRead(&c, "m2");
Build Summary: 21/23 steps succeeded (1 failed); 291/292 tests passed
```

The step is the last one in the replication sequence: C has already joined,
folded A as leader, and read the pre-existing `m1` (so its backfill
completed); B, a follower, then appends `m2`, which A slots and broadcasts.
C never shows `m2` within 20 s of polling `coppiz read` every 150 ms.

Observed on three different working trees, and never on an untouched
`origin/main` in six consecutive baseline runs (three at 3456e14, three at
c0a5d55). That asymmetry is unexplained.

It is not caused by any code change: one occurrence was on the branch
carrying this report, whose entire diff is three Markdown files. Whatever
the trigger is, it is in the tree already.

## Reproduction

Not reliable. `zig build test` in a loop reproduces it in a minority of
runs.

## Root cause

Not established. One mechanism is statically consistent with the symptom and
is recorded here as a candidate, not a finding.

Data-journal replication is the leader's broadcast. Two recovery paths
exist, and neither covers a lost *final* record:

- `onHeartbeat`'s gap catch-up compares only the control head and requests a
  sync of `self.node.control.journal_id` (`src/cluster/node.zig`
  `onHeartbeat`). `message.Heartbeat` carries one head, the control one, so
  a data-journal gap is invisible to it.
- `onSlot`'s `BadPrevHash` branch does sync the affected data journal - the
  fix recorded in
  [2026-08-28-follower-data-gap-stale](2026-08-28-follower-data-gap-stale.md)
  - but it needs a *later* record on that journal to arrive and fail the
  fold. `m2` is the last write in the test, so if C misses its broadcast
  nothing subsequent triggers the branch.

That gives a shape in which C stays one record behind indefinitely and the
poll can only time out. Whether the broadcast is actually lost in the
failing runs was not established: no frame-level capture was taken, and the
serve logs were not inspected for the failing run.

Also plausible and not separated from the above: C is simply slower than
20 s under load. Against that, the deadline is 20 s for a single 100-byte
record on loopback, and the other polls in the same test complete quickly.

## Later observations (2026-08-29, `src/net/` session)

Frequency, on a different working set: **five occurrences in roughly a dozen
`zig build test` runs**, every one of them
`pollRead(&c, "m2") -> error.Timeout` at the same step, and every one of them
green on an immediate re-run of the same tree. That is more often than the
"three in roughly a dozen" above, and it happened while two worktrees were
building concurrently, which fits the report's note that load makes it more
likely.

One candidate was tested and is **not** the answer on its own.
[`2026-08-29-tcp-recvframe-drops-buffered-bytes.md`](2026-08-29-tcp-recvframe-drops-buffered-bytes.md)
found that `TcpConn.recvFrame` discarded every byte the socket had read past
the current frame. That is a concrete way a broadcast is lost with no gap the
receiver can see, and the leader sends its heartbeat and its slot broadcast
back to back on one connection, which is exactly the coalescing case. It is
also the only process-level TCP test in the suite, so it was the natural
suspect. The flake still fired twice after that fix was on the branch. So
either it is a second mechanism, or a lost frame is not what fires here at all.

Nothing about the recovery-gap analysis above changed: `onHeartbeat` still
compares only the control head, and `onSlot`'s `BadPrevHash` still needs a
later record on the same journal. Those remain the reason a *single* lost
final broadcast would never be recovered. What is now less likely is that the
loss comes from the framing layer.

The next step in *Resolution* below is still the right one, and is now the
only one left that separates the hypotheses: capture the three serve stderr
logs from a failing run.

## Resolution

Not fixed. The next step is to capture the failing run's three serve
stderr logs (`BinTest.serve_logs` already collects the paths) and read
whether A broadcast the slot and whether C's conn to A was live at that
moment. That separates "lost frame with no recovery trigger" from
"too slow", and only the first is a product defect.

## Verification

None - the defect is open.

## Follow-up

While it is open, a lone `pollRead ... error.Timeout` in this test with
every other test passing is this bug rather than the change under test.
Re-run and gate an untouched base before investigating a diff.

## References

- Investigation: none
- Code: `src/main.zig` (the growth e2e, `pollRead`),
  `src/cluster/node.zig` (`onHeartbeat`, `onSlot`, `requestSync`)
- Related: [2026-08-28 - a follower that misses one data-journal broadcast is permanently behind](2026-08-28-follower-data-gap-stale.md),
  [2026-08-29 - the in-memory hub's `pipes` list is appended without a lock](2026-08-29-hub-pipes-append-unsynchronised.md)
