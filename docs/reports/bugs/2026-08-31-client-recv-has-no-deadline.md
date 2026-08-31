# Bug - the wire client's `recvMessage` has no deadline over TCP: a peer that accepts and then answers nothing parks the caller forever

## TL;DR

- **What failed:** `Client.recvMessage` (`src/net/client.zig`) blocked in
  `Conn.recv` with no bound of its own. Over the in-memory hub `Direction`
  supplies one; over TCP - the production path - nothing did, so a peer that
  completes the handshake and then answers nothing leaves the caller blocked
  in `readv` at 0% CPU with nothing in the log naming a culprit.
- **Impact:** every `coppiz` CLI command that falls back to the wire
  (`append`, `read`, `head`, `status`, `members`, `settings set`, `admit`)
  and every embedded caller of `net.client.Client`. A wedged serving node, or
  a half-open connection whose peer host vanished without an RST, hangs the
  command until the operator kills it - TCP's own keepalive default is two
  hours.
- **Resolution:** fixed - the read runs as a concurrent task and the caller
  waits on its completion event against an absolute deadline
  (`recv_timeout_ms`, default 120 s). On expiry `Conn.shutdown` ends the read
  and `recvMessage` returns `error.Timeout`.

## Status

Resolved 2026-08-31.

This is the follow-up
[`Direction.readInto` waits for a frame with no deadline](2026-08-31-hub-read-has-no-deadline.md)
recorded and did not attempt: "`net/client.zig`'s `recvMessage` still has no
deadline of its own. Over the hub it now inherits one; over TCP it does not."
That report fixed the hub half, whose victim was the test binary. This one is
the production half.

## Symptom and impact

Reproduced directly (below) rather than observed in the field. The stack is
the TCP twin of the hub stack that report quotes - leaf last, from `sample`
on a test child that had been sitting for 40 s at 0% CPU:

```
net.client.test.a client request a live peer never answers times out over TCP
 net.client.Client.members                                     client.zig:206
  net.client.Client.recvMessage                                 client.zig:98
   net.transport.Conn.recv                                    transport.zig:30
    net.transport.TcpConn.recvFrame                           transport.zig:136
     net.framing.readFrame                                      framing.zig:62
      Io.Reader.readSliceAll                                     Reader.zig:661
       Io.Reader.readSliceShort                                  Reader.zig:688
        Io.Reader.readVec                                        Reader.zig:429
         Io.net.Stream.Reader.readVec                                net.zig:1305
          Io.Threaded.netReadPosix                              Threaded.zig:12604
           readv  (in libsystem_kernel.dylib)
```

Nothing above `readv` carries a bound. `TcpConn` has no timeout field, the
`Io.Reader` it reads through has none, and `Io.Threaded.netReadPosix` blocks
in `readv` until the kernel has bytes, a FIN, or an RST. A peer that is alive
at the TCP layer and simply silent produces none of the three.

The failure mode is worse than the hub one it mirrors, because the victim is
an operator at a terminal rather than a test run: `coppiz status --dir DIR`
against a node whose loop is wedged never returns and never says why.

## Reproduction

A unit test over a real loopback socket, in-tree as *a client request a live
peer never answers times out over TCP* (`src/net/client.zig`). A server task
accepts, answers the hello, then reads every subsequent frame and answers
none of them, holding the connection open - so the client's read has neither
data nor a close. The client sends `members_req` and waits.

On the parent commit (`c6983b9`) that test does not fail, it hangs: run alone
it sat at `1/1 net.client.test.a client request a live peer never answers
times out over TCP...` with the child at 0.0% CPU, and produced the stack
quoted above. It had to be killed. With the fix, and `recv_timeout_ms` pinned
to 100 ms, it passes in milliseconds:

```
1/1 net.client.test.a client request a live peer never answers times out over TCP...OK
All 1 tests passed.
```

(Both runs used a temporary throwaway test root under `src/` with
`--test-filter`, since `zig build test` has no filter option. The root was
deleted; the test itself lives in `src/net/client.zig` and runs in the gate.)

## Root cause

`recvMessage` was three lines: reset the arena, `conn.recv`, decode. The
`Conn` vtable's `recv_frame` is where the blocking happens, and neither
implementation of it took a deadline from the caller - `Direction` acquired
one of its own in the hub fix, and `TcpConn` has none.

The bound cannot come from the socket, which is the shape a reader would
reach for first:

- `std.Io.net` exposes no receive-timeout option. `Socket.receiveTimeout`
  exists but is a `recvmsg` on a `Socket`, not a read through
  `Stream.Reader`; swapping to it would discard the connection-owned read
  buffer that bug 2026-08-29-tcp-recvframe-drops-buffered-bytes exists to
  keep. There is no `net_read` variant of `Io.Operation`, so
  `io.operateTimeout` cannot bound a stream read either.
- Setting `SO_RCVTIMEO` on `stream.socket.handle` behind `std.Io`'s back does
  not work. The option makes a blocked read fail with `EAGAIN`, and
  `Io.Threaded.netReadPosix` maps `.AGAIN` to `errnoBug`, which is
  `std.debug.panic("programmer bug caused syscall error: {t}")` in a debug
  build; `Io.Kqueue.netRead` maps `.AGAIN` to "register an `EVFILT.READ`
  filter and yield", which ignores the option entirely. So the same
  `setsockopt` either panics or does nothing depending on which `Io` the
  program runs - checked by reading both implementations, not by setting it.

That leaves composing the bound out of `Io`'s own concurrency, which is what
`std`'s own timed net operations do: `Socket.ReceiveTimeoutError` includes
`Io.ConcurrentError`, because `operateTimeout` is `Batch.awaitConcurrent`.

## Resolution

`Client` grows `recv_timeout_ms` (default `default_recv_timeout_ms`, 120 s)
and `recvMessage` reads through `recvBounded`:

- The frame read runs as a `RecvTask` via `io.concurrent`. The task writes
  `result`, then `done.set(io)`; `set` releases, so a waiter that observes
  the event observes the result.
- The caller converts the budget to an absolute deadline **once, on entry**
  (`Io.Timeout.toDeadline`) and waits on `done` with
  `Io.Event.waitTimeout`. That call reports a spurious wakeup as
  `error.Timeout` exactly like a real expiry - it does not loop internally -
  so expiry is decided by re-reading the clock after every return, the way
  `Direction.readInto` decides its own.
- On anything other than a clean completion the read is ended with
  `Conn.shutdown`, not `Future.cancel`. `shutdown` exists for precisely this
  ("tears the byte stream down (waking a blocked reader) without freeing the
  connection"), and it works the same on both implementations: `TcpConn`
  shuts the socket down so the blocked `readv` returns 0, `PipeConn` closes
  both directions so `readInto` returns 0. Whether `cancel` can interrupt a
  blocked `readv` is implementation-dependent, and this path must not depend
  on it.
- The task is **always** awaited before `recvBounded` returns, because it
  writes into a `RecvTask` on that frame. The `shutdown` is what makes the
  await finite.
- The task's own result wins even on expiry: a frame that landed in the same
  instant is returned as data rather than reported as a timeout, the
  last-look shape `Direction.expired` uses.
- `io.concurrent` can refuse (`ConcurrencyUnavailable`: a single-threaded
  build, or a pool at its limit). It then falls back to the inline,
  unbounded read - exactly the pre-fix behaviour. Degrading openly is the
  honest option; a bound that silently is not there would be worse than
  none. `recv_timeout_ms <= 0` selects the same branch deliberately.

120 s is a backstop, not an SLA, and the number is chosen to be unable to
make the suite flakier: the longest legitimate in-suite waits are the e2e
convergence polls at 20 s and the CLI status polls at 30 s. It equals
`transport.default_read_timeout_ms`, so the hub and TCP halves of the same
path carry the same figure. Over the hub both bounds are live and whichever
fires first wins; the hub's surfaces as `error.ReadFailed` through
`PipeConn.recvFrame`'s existing mapping, the client's as `error.Timeout`.
Both are bounded and diagnosable, which is the property being bought.

There is no CLI-visible policy flag, because there is no caller that
legitimately blocks for minutes: `Client` is used by the short-lived CLI
commands, the two examples, and the tests. The `follow` mode the hub report
named as a reason to want an opt-in policy does not exist - `src/main.zig`
has no such command - so the blanket bound is correct today, and
`recv_timeout_ms` is the per-connection escape hatch if one appears.

## Verification

- `zig build test --summary all` from the worktree root, exit code read
  directly and not through a pipe: `Build Summary: 25/25 steps succeeded;
  374/374 tests passed`, exit 0. The baseline on merged `main` `c6983b9` -
  `25/25 steps succeeded; 372/372 tests passed` - was measured earlier the
  same day and is not re-measured here; the two tests added below account for
  the difference exactly.
- The parent commit hangs on the new test, with the `sample` stack quoted
  under *Symptom and impact*; the fixed tree passes it in milliseconds. Both
  runs are quoted under *Reproduction*.
- A second new test (*a zero recv timeout reads inline, with no bound and no
  task*) covers the disabling branch, which is also the
  `ConcurrencyUnavailable` fallback path.
- The pre-existing client tests (*a read page whose cursor does not advance
  is refused, not looped*, *a journal name past the wire's u16 length cap is
  refused before encoding*) were already green and still are; the first now
  exercises `recvBounded`'s success path at the default timeout.

## Follow-up

- The `SO_RCVTIMEO` conclusion is from reading `Io.Threaded.netReadPosix` and
  `Io.Kqueue.netRead`, not from setting the option and observing the panic.
  The mapping (`.AGAIN => errnoBug` / `.AGAIN => yield`) is unambiguous, but
  the panic itself is unverified.
- `Hub.Endpoint.acceptConn` is still an untimed wait, for the reason the hub
  report gives: blocking until a dialer arrives is what an accept is for.
- One concurrent task per received frame is a real cost on the `read` path,
  which pages. It has not been measured; the CLI's page size is 64 KiB, so
  the task count is small in every current caller.
- The 120 s constant is unverified against any workload larger than this
  suite, exactly as its hub twin is.

## References

- Investigation: none; the stack above and the two `Io` implementations were
  the whole diagnosis.
- Code: `src/net/client.zig` (`recvMessage`, `recvBounded`, `RecvTask`,
  `waitRecv`, `default_recv_timeout_ms`), `src/net/transport.zig`
  (`Conn.shutdown`, `TcpConn.recvFrame`, `Direction`)
- Prior half of the same defect:
  [2026-08-31-hub-read-has-no-deadline](2026-08-31-hub-read-has-no-deadline.md)
- Fix: this report's resolving commit
