# Bug - `Direction.readInto` waits for a frame with no deadline, so a hub read that never arrives hangs the whole test binary

## TL;DR

- **What failed:** `Direction.readInto` (`src/net/transport.zig`) blocked on
  an untimed `std.Io.Semaphore.wait` whenever its queue was empty and the
  peer had not closed. Nothing on that path carried a deadline, so a frame
  that never came parked the calling task forever.
- **Impact:** `zig build test`. `Direction` is the in-memory hub the unit
  tests and the simulator's transport run on, so the victim is the gate, not
  production: a `zig build test` on merged `main` (9765d30) sat for about two
  hours with the build runner and the test child both at 0% CPU and no output
  naming a culprit. The production TCP path is `TcpConn`, which reads through
  `std.Io.net`'s socket reader and is not affected.
- **Resolution:** fixed - the semaphore is replaced by a sequence counter
  waited on with `io.futexWaitTimeout` against an absolute deadline. A read
  that finds neither data nor a close within `read_timeout_ms` (default
  120 s) returns `error.Timeout`.

## Status

Resolved 2026-08-31.

This closes the second of the two causes named by
[`zig build test` randomly hangs: the e2e cluster tests fsync every record onto the host filesystem](2026-08-29-e2e-fsync-stall-hang.md),
whose resolution fixed only the first (the per-record fsync, via
`fsync = .never`) and left "the client's blocking `recvMessage` has no
deadline" as a stated follow-up. That report's evidence stands as written;
this one adds the structural half.

## Symptom and impact

`zig build test` does not finish. Observed on merged `main` (9765d30) on
2026-08-31: the run had been sitting for roughly two hours with the build
runner and the test child both at 0% CPU. `sample` on the test child gave
this main-thread stack, leaf last:

```
test_runner.mainServer                                    test_runner.zig:140
 cluster.node.test.e2e (b): partition a 2-member seniority cluster,
   write on both sides, heal, merge                              node.zig:3924
  cluster.node.bothPayloads                                      node.zig:3991
   net.client.Client.read                                        client.zig:175
    net.client.Client.recvMessage                                 client.zig:98
     net.transport.Conn.recv                                    transport.zig:30
      net.transport.PipeConn.recvFrame                          transport.zig:377
       net.transport.Direction.readInto                         transport.zig:352
        Io.Semaphore.wait                                       Semaphore.zig:21
         ... __ulock_wait2
```

The harness is written to tolerate a failed read. The `e2e (b)` test polls
for convergence against a 20 s wall-clock deadline, and `bothPayloads` does
`client.read(...) catch return false` - a read error means "not converged
yet, poll again". The untimed wait defeats that, because the poll deadline is
checked only *between* reads and never *during* one: a single stalled read
bypasses the 20 s bound entirely.

The cost is the whole run, not one test. The build has to be killed, and a
killed run leaves nothing in the log saying which test stalled - both
processes are at 0% CPU, so even "it is busy" is not visible. Two abandoned
runs of this shape pegged two cores for six hours during the session that
found this.

## Reproduction

The live hang is timing-dependent (it needs a frame that genuinely never
arrives, which on the hub means a lost or never-sent message under load), so
the mechanism was reproduced directly rather than by re-provoking the e2e
test. A standalone program holding the pre-fix loop and the post-fix loop
side by side, each with a 3 s watchdog task:

```
=== OLD (untimed sem.wait) ===
WATCHDOG: readInto still blocked after 3000 ms
exit=3
=== NEW (futexWaitTimeout + deadline) ===
new returned error.Timeout
exit=0
```

The same thing is now pinned in-tree by the test *a read with no data and no
close times out rather than blocking forever* (`src/net/transport.zig`),
which uses a 50 ms `read_timeout_ms` so it costs the suite milliseconds.
Under the pre-fix code that test does not fail - it hangs, which is the
reason it is worth having.

## Root cause

`Direction` is one direction of a hub pipe: a mutex, a queue of frame
bodies, a `closed` flag, and - before this change - an `std.Io.Semaphore`
posted once per push and once on close. `readInto` looped:

```zig
const closed = self.closed;
self.mutex.unlock(io);
if (closed) return 0;
try self.sem.wait(io);
```

`std.Io.Semaphore` has exactly `wait`, `waitUncancelable` and `post`. There
is no timed wait, and `std.Io.Condition` has none either, so the primitive
chosen for the queue could not express a bound even if a caller wanted one.
Cancelation is not a substitute: nothing in the test harness cancels that
task, and the caller that would want to give up (`bothPayloads`) is the
thread that is blocked.

The only caller in anger is `PipeConn.recvFrame`, which reads a 4-byte
header and then the body, so the stall can land at either of two points and
in both cases the frame is half-read and the task is parked. `Hub.drop`
closes the affected direction, so a partition still wakes a reader with
`EndOfStream`; the unbounded case is a direction that is open and simply
silent.

## Resolution

`Direction` now waits with a deadline:

- The semaphore is replaced by `seq: u32`, bumped under the mutex by `push`,
  `pushFramed` and `close` and published with `io.futexWake`.
- `readInto` snapshots `seq` **while still holding the mutex**, unlocks, then
  calls `io.futexWaitTimeout(u32, &self.seq, expected, deadline)`. That
  ordering is what makes the wait lost-wakeup-free: a writer that bumps `seq`
  between the unlock and the wait has already changed the value the wait
  compares against, so the wait returns immediately instead of sleeping on a
  post that has been and gone.
- The timeout is converted to an absolute deadline **once, on entry**
  (`Io.Timeout.toDeadline`), so the budget is the total wait rather than a
  fresh allowance per wakeup.
- `futexWaitTimeout` returns `Cancelable!void`: expiry is reported as a plain
  return, indistinguishable from a spurious wakeup. The deadline is therefore
  re-checked after every return, the way `Io.Event.waitTimeout` does it. On
  expiry the queue and the `closed` flag get one last look under the mutex,
  so data or a close arriving in the same instant is delivered rather than
  reported as a timeout.

`default_read_timeout_ms` is 120 s. It is a backstop, not an SLA: the point
is to turn an unbounded hang into a bounded, diagnosable failure, so the
number sits far above every legitimate in-suite wait (the e2e convergence
polls allow 20 s, and two e2e tests sleep 2.5 s at a stretch) and far below
"forever". `read_timeout_ms` is a per-`Direction` field, so a test can pin
the behaviour in milliseconds instead of minutes.

For the caller, an expiry surfaces through `PipeConn.recvFrame`'s existing
`catch return error.ReadFailed`, which is what the e2e harness already
tolerates - so the 20 s convergence deadline is now actually the bound on
that test.

`Hub.Endpoint.acceptConn` keeps its own separate semaphore and its own
untimed wait, deliberately: blocking until a dialer arrives is what an accept
is for, and `HubListener.closeFn` sets `closed` and posts, so a closing
listener already wakes it with `error.ConnectionRefused`. Whether it wants a
bound too is a separate question and was not changed here.

## Verification

- `zig build test --summary all` from the worktree root, exit code read
  directly and not through a pipe: `Build Summary: 25/25 steps succeeded;
  365/365 tests passed`. The baseline this is compared against - `25/25 steps
  succeeded; 362/362 tests passed` on merged `main` 9765d30 - was measured
  earlier the same day and is not re-measured here; the three tests added
  below account for the difference exactly.
- The pre-fix loop was confirmed to block, and the post-fix loop to return
  `error.Timeout`, by the side-by-side watchdog program quoted under
  *Reproduction*.
- The three pre-existing `readInto` semantics each keep a test that was
  already green and still is: a clean close with nothing left returns 0 (*a
  clean close with nothing left still reads as 0, not a timeout*, added here
  to state it explicitly), a legal zero-length frame body is data rather
  than a close (*an empty pushed body is data, not a close*), and a partial
  read re-bases its remainder into its own allocation (*a partial read
  leaves a freeable remainder*, the regression test of
  [2026-08-28-direction-partial-read-free](2026-08-28-direction-partial-read-free.md)).
- A new test (*a frame pushed while a reader waits still wakes it*) pushes
  from another task 30 ms into a 5 s wait, covering the lost-wakeup ordering
  the sequence counter exists for.

## Follow-up

- `Hub.Endpoint.acceptConn` is still an untimed wait, by the reasoning above.
- `net/client.zig`'s `recvMessage` still has no deadline of its own. Over the
  hub it now inherits one; over TCP it does not, and the follow-up the
  fsync report named is still the right shape - the CLI's follow mode
  legitimately blocks for a long time, so a client-side deadline needs an
  opt-in policy rather than a blanket timeout. Not attempted here.
- The 120 s constant is unverified against any workload larger than this
  suite. It is deliberately loose; a real hang is diagnosed by the
  `error.Timeout` reaching a caller, not by the number being tight.

## References

- Investigation: none; the stack above was the whole diagnosis.
- Code: `src/net/transport.zig` (`Direction`, `default_read_timeout_ms`,
  `PipeConn.recvFrame`, `Hub.Endpoint.acceptConn`), `src/cluster/node.zig`
  (`e2e (b)`, `bothPayloads`), `src/net/client.zig` (`recvMessage`)
- Prior half of the same defect:
  [2026-08-29-e2e-fsync-stall-hang](2026-08-29-e2e-fsync-stall-hang.md)
- Fix: this report's resolving commit
