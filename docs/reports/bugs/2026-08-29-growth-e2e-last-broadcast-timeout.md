# Bug - the 1 → 2 → 3 growth e2e intermittently times out waiting for the last replicated entry

## TL;DR

- **What failed:** `main.test.process-level: a live cluster grows 1 → 2 → 3 members over TCP` intermittently fails at `pollRead(&c, "m2")` with `error.Timeout` after its 20 s deadline. Every other test in the run passes.
- **Impact:** `zig build test` is intermittently red. Observed three times in roughly a dozen local runs.
- **Resolution:** Fixed. The candidate mechanism was the mechanism: a broadcast dropped while the receiver is still `syncing`, with nothing that re-requests it. See [2026-08-29-syncing-drops-the-newest-broadcast](2026-08-29-syncing-drops-the-newest-broadcast.md).

## Status

Resolved. Filed by the session working `src/journal/`, `src/settings/`,
`src/config/` and `src/main.zig`; root-caused and fixed by the
`src/cluster/` session on 2026-08-29. The defect record is
[2026-08-29-syncing-drops-the-newest-broadcast](2026-08-29-syncing-drops-the-newest-broadcast.md);
this record keeps the symptom, its history, and the hypotheses that were
ruled out.

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

## A second step can time out too (2026-08-29, `src/net/` wire sweep)

One occurrence in seven `zig build test` runs across three worktrees, and it
was **not** at `pollRead(&c, "m2")`:

```
error: 'main.test.process-level: a live cluster grows 1 → 2 → 3 members over
TCP, founder stays leader' failed:
       .../src/main.zig:1426:5: in pollRead (test)
           return error.Timeout;
       .../src/main.zig:1372:20: in test.process-level: a live cluster grows
           const read_b = try pollRead(&b, "m1");
Build Summary: 21/23 steps succeeded (1 failed); 303/304 tests passed
```

An immediate re-run of the same tree was green (304/304), as with every
other recorded occurrence. So the symptom is "a joiner never sees the newest
record", not specifically "C never sees `m2`", and any explanation has to
cover both steps.

The `m1` step has a candidate the `m2` step does not, recorded as a
candidate and **not** established here - no serve logs were captured:

- `onSlot` returns early while the member is backfilling
  (`if (self.syncing or self.merging_from != null) return;`), and the report
  above establishes that nothing re-requests a dropped *newest* record.
- The test guards C against exactly that. Its own comment says so: "C's
  leader view updates once its control chain folds; its data backfill may
  still be running, and a broadcast during it is dropped", and it polls
  `m1` on C before appending `m2`.
- B has no equivalent guard. Between `waitStatus(&b, "leader <a>")` and
  A's `append m1` there is nothing that proves B's data backfill has
  finished, so a `syncing` B can drop the `m1` broadcast and then wait out
  the 20 s.

If that is what fires at the `m1` step, it is a defect in the test's
sequencing there and a product defect in the missing recovery - the same
missing recovery the report already names. It says nothing about the `m2`
step, where C's backfill is proven complete before the append.

## What the capture showed (2026-08-29, `src/cluster/` session)

The recorded next step was run. Two things came out of it, one of them a
correction to the step itself.

**The serve logs cannot answer the question, and never could.** `serve`
writes nothing to stderr in normal operation: the only writes in `cmdServe`
are a startup config error, and a panic. All three logs were empty in every
failing run. So the capture separates "a serve died" from "everything else"
and nothing finer. Do not spend another session on it.

**What did separate the hypotheses was polling past the deadline.** With the
test's own poll extended by 120 s and every node's `read` and `status`
dumped at the moment of timeout, three failing runs were identical:

```
[A(leader)] read: 1:1 ... data m1 / 1:2 ... data m2
[B(appender)] read: 1:1 ... data m1 / 1:2 ... data m2
[C(target)] read: 1:1 ... data m1
[C(target)] status: epoch 1, leader <a>
[A] serve stderr: EMPTY   [B] EMPTY   [C] EMPTY
NEVER ARRIVED: m2 absent 120 s past the deadline
```

C is alive, agrees on the epoch and the leader, and is permanently one
record short. **"Too slow" is dead.** It is a lost record with no recovery,
which is the shape this report already named as a candidate.

The mechanism is `onSlot` dropping the broadcast while `syncing` is still
set - `syncing` is cleared by the next tick, not by the empty sync page that
drained the last cursor - and it is written up as its own defect in
[2026-08-29-syncing-drops-the-newest-broadcast](2026-08-29-syncing-drops-the-newest-broadcast.md).
That also explains the `m1` variant recorded above: B has no guard against
the same window, which is why it is in fact the *more* common of the two.

## Resolution

Fixed by
[2026-08-29-syncing-drops-the-newest-broadcast](2026-08-29-syncing-drops-the-newest-broadcast.md):
a broadcast dropped while backfilling now leaves a sync cursor at the missing
position, so the next `driveBackfill` fetches it.

## Verification

The growth e2e built alone and run in a loop, one run at a time, nothing else
on the machine:

| tree | runs | failures |
|---|---|---|
| `origin/main` at 70c77ee | 20 | 16 (14 at `m1`, 2 at `m2`) |
| the same tree with the fix | 20 | 0 |

## Follow-up

None. The reproduction recipe (build the test alone with `--test-filter` and
loop it) is in the defect record, and it is far faster than looping
`zig build test`.

## References

- Investigation: none
- Code: `src/main.zig` (the growth e2e, `pollRead`),
  `src/cluster/node.zig` (`onHeartbeat`, `onSlot`, `requestSync`)
- Fix: [2026-08-29 - a backfilling member drops the newest broadcast and never asks for it again](2026-08-29-syncing-drops-the-newest-broadcast.md)
- Related: [2026-08-28 - a follower that misses one data-journal broadcast is permanently behind](2026-08-28-follower-data-gap-stale.md),
  [2026-08-29 - the in-memory hub's `pipes` list is appended without a lock](2026-08-29-hub-pipes-append-unsynchronised.md)
