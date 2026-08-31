# Bug - `Direction.push`/`pushFramed` swallow `OutOfMemory`: a hub send reports success for a frame that was never queued

## TL;DR

- **What failed:** Both push paths on the in-memory hub's `Direction` caught their allocation failures with `catch return` and returned `void`. `PipeConn.sendFrame` therefore reported success, so `Conn.send` told the sender the frame had been sent while nothing was queued.
- **Impact:** Test and simulator fabric only (`Hub`/`Direction`); the served path is `TcpConn`, which is untouched. Under memory pressure - and, concretely, inside the `FailingAllocator` sweep the hub already runs - a send silently vanishes: no retry, no error, and the receiver just never sees the message.
- **Resolution:** Fixed 2026-08-31. Both paths return `error.OutOfMemory`; `sendFrame` maps it to `error.SendFailed`.

## Status

Resolved 2026-08-31.

## Symptom and impact

`Direction.push` and `Direction.pushFramed` each have two fallible steps: the
copy of the frame bytes into hub memory, and the `chunks.append` that stores
it. Both were written as

```zig
const copy = self.allocator.dupe(u8, body) catch return;
self.chunks.append(self.allocator, copy) catch {
    self.allocator.free(copy);
    return;
};
```

Both functions returned `void`, so neither failure could reach a caller.
`PipeConn.sendFrame` - the only non-test caller - calls `pushFramed` as its
last statement and then returns success, and `Conn.send`'s declared
`SendError!void` therefore resolved to "sent".

This is the hardest failure shape to diagnose: nothing reports anything. The
sender's retry and error handling never run, and the symptom surfaces
somewhere else entirely, as a peer that is inexplicably behind - or, since
the read deadline landed (bug 2026-08-31-hub-read-has-no-deadline), as a
`Timeout` on a receiver waiting for a frame no one will ever send.

Severity, stated plainly: `Hub` and `Direction` are the in-memory transport
the tests and the simulator run on. The production transport is `TcpConn`,
whose `sendFrame` writes through `std.Io` and reports its failures. Nothing a
deployment does reaches this code. What it costs is trust in the harness: a
hub-based test running under an injected allocation failure can pass for the
wrong reason.

## Reproduction

```zig
var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 0 });
var out = Direction{ .allocator = failing.allocator() };
var in = Direction{ .allocator = failing.allocator() };
var pc = PipeConn{ .allocator = test_alloc, .in = &in, .out = &out };
var c = pc.conn();
try c.send(tio, "hello"); // succeeds; out.chunks.items.len == 0
```

Observed on `375497d`, through the regression test below:
`expected error.SendFailed, found void`. Expected: the send is refused.
Actual: the send returns success and the queue is empty.

`fail_index = 1` reproduces the second path, where the copy succeeds and the
list growth fails.

## Root cause

Two `void`-returning functions with fallible bodies. `catch return` is a
correct *memory* decision at both sites - the copy is freed, nothing leaks,
nothing double-frees - which is presumably why it survived the hub's
`FailingAllocator` sweep: that test asserts the absence of leaks and
double-frees, and says nothing about whether the send happened.

## Resolution

Fixed 2026-08-31. `push` and `pushFramed` are now
`error{OutOfMemory}!void`: the copy is `try`, an `errdefer` frees it, and the
`chunks.append` is `try`. `PipeConn.sendFrame` maps the failure to
`error.SendFailed`, which is already in `SendError` and is what a failing
socket write on the TCP path reports - so no caller sees a new error class.

What deliberately did **not** change: a push to a *closed* direction is still
a silent no-op returning success. That is the documented close semantics
("later sends are discarded"), and a peer learns about a close from its own
read returning `EndOfStream`, not from its send. Only the allocation failures
are reported.

## Verification

- Regression test "a hub send that cannot allocate is refused, not reported
  as sent" (`src/net/transport.zig`), over both `fail_index` 0 and 1. Seen to
  fail on the parent `375497d` with `expected error.SendFailed, found void`
  at the `expectError`, which is the silent-success shape itself rather than
  a crash. It also asserts the queue is empty after a refusal, so a future
  half-landed frame fails too.
- Full `zig build test --summary all` green - see the resolving PR for the
  quoted `Build Summary` line.

## Follow-up

The existing "hub connect and listen never double-free on allocation failure"
sweep cannot catch this class: it asserts that no path leaks or double-frees,
and treats any error from `hubRound` as an acceptable outcome. A silent drop
is neither a leak nor an error, so it passes. Worth remembering when a
`FailingAllocator` sweep is offered as coverage - it proves memory
discipline, not that the operation happened.

## References

- Code: `src/net/transport.zig` (`Direction.push`, `Direction.pushFramed`, `PipeConn.sendFrame`)
- Related: [2026-08-31-hub-read-has-no-deadline.md](2026-08-31-hub-read-has-no-deadline.md) (the other end of the same pipe; a dropped send now surfaces there as a `Timeout`)
- Fix: this report's resolving commit
